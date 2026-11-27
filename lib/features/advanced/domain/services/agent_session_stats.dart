import 'package:lmstory/core/llm/llm_usage.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';

/// 单工具聚合（观测聚合）
class AgentToolStat {
  const AgentToolStat({required this.calls, required this.errors});

  final int calls;
  final int errors;

  double get failureRate => calls == 0 ? 0 : errors / calls;
}

/// 单轮缓存命中（趋势点；hitRate null = 该轮无可用缓存样本）
class AgentTurnCachePoint {
  const AgentTurnCachePoint({
    required this.turn,
    required this.cacheReadTokens,
    required this.promptTokens,
    this.inputTokens,
    this.cacheInputTokens,
    this.cacheSampleComplete = true,
  });

  final int turn;

  /// 缓存读取 token；null = 该轮日志未上报缓存分项（不可比样本）
  final int? cacheReadTokens;
  final int promptTokens;

  /// 完整输入 token（新日志才有；旧日志缺键为 null）
  final int? inputTokens;

  /// 命中率分母：只含「完整输入 + 命中分项都有效」的可比样本
  ///
  /// 旧日志无此键时回退 [inputTokens]（历史口径）。部分请求
  /// 未上报缓存时不能用全量输入做分母，否则把未知当零命中。
  final int? cacheInputTokens;

  /// 该轮所有请求是否都有可比缓存样本（false = 部分请求未上报）
  final bool cacheSampleComplete;

  /// 命中率口径 = cacheRead / 可比完整输入（Anthropic/OpenAI 同式）。
  ///
  /// 缺完整输入面的旧样本返回 null——不得退化成 cacheRead/(cacheRead+prompt)
  /// （OpenAI prompt 已含缓存，会把命中率系统性算低）。
  /// 样本不完整且没有可比分母时同样返回 null：不能用全量输入回退。
  double? get hitRate {
    if (!cacheSampleComplete && cacheInputTokens == null) return null;
    return LlmUsage.hitRateOf(
      cacheReadTokens: cacheReadTokens,
      inputTokens: cacheInputTokens ?? inputTokens,
    );
  }
}

/// 会话级聚合（：durable 事件流懒计算，诊断页聚合卡数据源）
class AgentSessionStats {
  const AgentSessionStats({
    required this.turns,
    required this.steps,
    required this.stepsByTurn,
    required this.toolStats,
    required this.promptTokens,
    required this.completionTokens,
    required this.cacheReadTokens,
    required this.cacheCreationTokens,
    required this.cacheTrend,
    this.cacheSampleTurns = 0,
    this.cacheCoveredInputTokens = 0,
  });

  final int turns;
  final int steps;

  /// 每轮步数（轮号升序；步数分布的数据源）
  final Map<int, int> stepsByTurn;

  /// 工具名 → 调用/失败统计（失败率按工具分）
  final Map<String, AgentToolStat> toolStats;

  final int promptTokens;
  final int completionTokens;
  final int cacheReadTokens;
  final int cacheCreationTokens;

  /// 每轮缓存命中（趋势）
  final List<AgentTurnCachePoint> cacheTrend;

  /// 命中率累计覆盖的轮数（仅有完整输入面+缓存分项的样本）
  final int cacheSampleTurns;

  /// 命中率累计覆盖的输入 token（可追溯口径）
  final int cacheCoveredInputTokens;

  /// 会话加权命中率（cacheRead 总量 / 覆盖样本的完整输入总量）
  double? get weightedCacheHitRate => LlmUsage.hitRateOf(
        cacheReadTokens: cacheSampleTurns == 0 ? null : _coveredCacheReadTokens,
        inputTokens: cacheCoveredInputTokens,
      );

  int get _coveredCacheReadTokens {
    var cached = 0;
    for (final point in cacheTrend) {
      if (point.hitRate == null) continue;
      cached += point.cacheReadTokens!;
    }
    return cached;
  }
}

/// 从 durable 事件流计算会话聚合（纯函数，只读）
///
/// 数据源约定（与写入侧 agent_durable_event_sink 对齐）：
/// - turn/end：reason/steps/token 分项（cache 分项  起写入；
///   `totalInputTokens`  起写入；旧日志缺键按不可用样本处理）
/// - step/end：步数（含重试后成功步）
/// - tool/result：toolName/isError（synthetic 占位也计入——它们本就是
///   失败形态的一部分）
AgentSessionStats agentSessionStatsFrom(List<AgentDurableEvent> events) {
  // 审查收官 ：子代理事件（起 log-only 中继，data.subagent=true）
  // 的 usage 已由 spawn 并账进父轮 turn/end——聚合必须跳过，否则双计
  final mainEvents =
      events.where((e) => e.data['subagent'] != true).toList(growable: false);
  return _agentSessionStatsFromMain(mainEvents);
}

AgentSessionStats _agentSessionStatsFromMain(List<AgentDurableEvent> events) {
  final stepsByTurn = <int, int>{};
  final turnPrompt = <int, int>{};
  final turnInput = <int, int>{};
  final turnCacheRead = <int, int>{};
  final turnCacheReadKnown = <int>{};
  final turnCacheInput = <int, int>{};
  final turnCacheComplete = <int, bool>{};
  final toolCalls = <String, int>{};
  final toolErrors = <String, int>{};
  var promptTokens = 0;
  var completionTokens = 0;
  var cacheReadTokens = 0;
  var cacheCreationTokens = 0;

  for (final event in events) {
    switch (event.type) {
      case AgentEventTypes.turnEnd:
        final turn = event.data['turn'];
        if (turn is int) {
          turnPrompt[turn] = (event.data['promptTokens'] as num?)?.toInt() ?? 0;
          turnInput[turn] =
              (event.data['totalInputTokens'] as num?)?.toInt() ?? 0;
          if (event.data.containsKey('cacheReadTokens')) {
            turnCacheRead[turn] =
                (event.data['cacheReadTokens'] as num?)?.toInt() ?? 0;
            turnCacheReadKnown.add(turn);
          }
          // 新日志：命中分子/分母都来自可比样本；缺键回退旧日志口径。
          final comparableRead =
              (event.data['cacheComparableReadTokens'] as num?)?.toInt();
          if (comparableRead != null) {
            turnCacheRead[turn] = comparableRead;
            turnCacheReadKnown.add(turn);
          }
          final comparableInput =
              (event.data['cacheComparableInputTokens'] as num?)?.toInt();
          if (comparableInput != null && comparableInput > 0) {
            turnCacheInput[turn] = comparableInput;
          }
          turnCacheComplete[turn] = event.data['cacheSampleComplete'] != false;
        }
        promptTokens += (event.data['promptTokens'] as num?)?.toInt() ?? 0;
        completionTokens +=
            (event.data['completionTokens'] as num?)?.toInt() ?? 0;
        cacheReadTokens +=
            (event.data['cacheReadTokens'] as num?)?.toInt() ?? 0;
        cacheCreationTokens +=
            (event.data['cacheCreationTokens'] as num?)?.toInt() ?? 0;
      case AgentEventTypes.stepEnd:
        final turn = event.data['turn'];
        if (turn is int) {
          stepsByTurn[turn] = (stepsByTurn[turn] ?? 0) + 1;
        }
      case AgentEventTypes.toolResult:
        final toolName = event.data['toolName'] as String?;
        if (toolName == null || toolName.isEmpty) break;
        toolCalls[toolName] = (toolCalls[toolName] ?? 0) + 1;
        if (event.data['isError'] == true) {
          toolErrors[toolName] = (toolErrors[toolName] ?? 0) + 1;
        }
      default:
        break;
    }
  }

  // 轮集合取 step 与 turn/end 的并集：无步事件的轮（合成/截断日志）
  // 也应有缓存点，否则加权命中率会因缺轮而变 null。
  final turnKeys = <int>{...stepsByTurn.keys, ...turnPrompt.keys};
  final sortedTurns = turnKeys.toList()..sort();
  final cacheTrend = [
    for (final turn in sortedTurns)
      AgentTurnCachePoint(
        turn: turn,
        cacheReadTokens:
            turnCacheReadKnown.contains(turn) ? turnCacheRead[turn] ?? 0 : null,
        promptTokens: turnPrompt[turn] ?? 0,
        inputTokens: (turnInput[turn] ?? 0) > 0 ? turnInput[turn] : null,
        cacheInputTokens:
            (turnCacheInput[turn] ?? 0) > 0 ? turnCacheInput[turn] : null,
        cacheSampleComplete: turnCacheComplete[turn] ?? true,
      ),
  ];

  var cacheSampleTurns = 0;
  var cacheCoveredInputTokens = 0;
  for (final point in cacheTrend) {
    if (point.hitRate == null) continue;
    cacheSampleTurns++;
    // 只累计可比样本的输入（旧日志回退完整输入）
    cacheCoveredInputTokens += point.cacheInputTokens ?? point.inputTokens!;
  }

  return AgentSessionStats(
    turns: turnPrompt.length,
    steps: stepsByTurn.values.fold(0, (a, b) => a + b),
    stepsByTurn: stepsByTurn,
    toolStats: {
      for (final entry in toolCalls.entries)
        entry.key: AgentToolStat(
          calls: entry.value,
          errors: toolErrors[entry.key] ?? 0,
        ),
    },
    promptTokens: promptTokens,
    completionTokens: completionTokens,
    cacheReadTokens: cacheReadTokens,
    cacheCreationTokens: cacheCreationTokens,
    cacheTrend: cacheTrend,
    cacheSampleTurns: cacheSampleTurns,
    cacheCoveredInputTokens: cacheCoveredInputTokens,
  );
}
