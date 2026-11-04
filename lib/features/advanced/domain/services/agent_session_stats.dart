import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';

/// 单工具聚合（观测聚合）
class AgentToolStat {
  const AgentToolStat({required this.calls, required this.errors});

  final int calls;
  final int errors;

  double get failureRate => calls == 0 ? 0 : errors / calls;
}

/// 单轮缓存命中（趋势点；hitRate null = 该轮无缓存上报）
class AgentTurnCachePoint {
  const AgentTurnCachePoint({
    required this.turn,
    required this.cacheReadTokens,
    required this.promptTokens,
  });

  final int turn;
  final int cacheReadTokens;
  final int promptTokens;

  /// 命中率口径 = cacheRead /（cacheRead + prompt）：
  /// Anthropic promptTokens 不含 cache 读、OpenAI cachedTokens 含在
  /// promptTokens 内——分母统一取两者之和，两协议同式近似可比
  double? get hitRate {
    final base = cacheReadTokens + promptTokens;
    if (base <= 0) return null;
    return cacheReadTokens / base;
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

  /// 会话加权命中率（各轮 hitRate 的 token 加权平均；无数据为 null）
  double? get weightedCacheHitRate {
    var cached = 0;
    var base = 0;
    for (final point in cacheTrend) {
      cached += point.cacheReadTokens;
      base += point.cacheReadTokens + point.promptTokens;
    }
    if (base <= 0) return null;
    return cached / base;
  }
}

/// 从 durable 事件流计算会话聚合（纯函数，只读）
///
/// 数据源约定（与写入侧 agent_durable_event_sink 对齐）：
/// - turn/end：reason/steps/token 分项（cache 分项  起写入；旧日志
///   缺键按 0 计）
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
  final turnCacheRead = <int, int>{};
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
          turnCacheRead[turn] =
              (event.data['cacheReadTokens'] as num?)?.toInt() ?? 0;
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

  final sortedTurns = stepsByTurn.keys.toList()..sort();
  final cacheTrend = [
    for (final turn in sortedTurns)
      AgentTurnCachePoint(
        turn: turn,
        cacheReadTokens: turnCacheRead[turn] ?? 0,
        promptTokens: turnPrompt[turn] ?? 0,
      ),
  ];

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
  );
}
