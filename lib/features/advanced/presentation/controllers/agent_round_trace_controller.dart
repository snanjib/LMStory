import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/services/agent_log_recovery.dart';

/// 轮轨迹步时间线条目（L2 展示行）
class AgentStepTrace {
  const AgentStepTrace({
    required this.stepIndex,
    required this.beginMs,
    required this.toolCalls,
    required this.tools,
    this.endMs,
    this.stopKind,
    this.promptTokens,
    this.completionTokens,
    this.assistantTextPreview,
    this.label,
  });

  final int stepIndex;

  /// 非 null = 非 LLM 步的展示行（：注入面/doom 触发；负 stepIndex
  /// 防与真实步的详情水位线冲突），时间线按 label 原文展示
  final String? label;
  final int beginMs;
  final int? endMs;
  final String? stopKind;
  final int? promptTokens;
  final int? completionTokens;

  /// 本步模型发起的工具调用（name + 参数预览）
  final List<({String name, String argsPreview})> toolCalls;

  /// 本步执行完成的工具（含耗时/成败；来自 tool/result 事件）
  final List<
      ({
        String callId,
        String toolName,
        String title,
        int? durationMs,
        bool isError,
      })> tools;

  /// assistant 文本预览（截断）
  final String? assistantTextPreview;
}

/// 轮摘要（L1）
class AgentTurnTraceSummary {
  const AgentTurnTraceSummary({
    required this.turnNumber,
    required this.reason,
    required this.steps,
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
    this.errorMessage,
    this.durationMs,
  });

  final int turnNumber;
  final String? reason;
  final int steps;
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  final String? errorMessage;
  final int? durationMs;
}

/// 单步详情（L3，点开才计算）
class AgentStepTraceDetail {
  const AgentStepTraceDetail({
    required this.requestMessages,
    required this.responseText,
    required this.toolResults,
  });

  /// 重建的请求消息序列（deriveAgentSurface 投影到本步 assistant 消息前）
  final List<AgentMessage> requestMessages;

  /// 本步 assistant 输出全文（含工具调用参数）
  final String responseText;

  /// 本步工具结果全文
  final List<({String toolName, String callId, String output, bool isError})>
      toolResults;
}

class AgentRoundTraceState {
  const AgentRoundTraceState({
    this.isLoading = true,
    this.error,
    this.summary,
    this.steps = const [],
    this.stepDetails = const {},
    this.firstAvailableTurn,
  });

  final bool isLoading;
  final String? error;
  final AgentTurnTraceSummary? summary;
  final List<AgentStepTrace> steps;

  /// stepIndex → 详情（点击才计算，不一次全载）
  final Map<int, AgentStepTraceDetail> stepDetails;

  /// 日志中最早带 turn 戳的轮号（null=无带戳事件）。>1 说明更早轮
  /// 的事件已不在日志（滚动保留裁剪/截断），轨迹页据此标注历史缺失。
  final int? firstAvailableTurn;

  AgentRoundTraceState copyWith({
    bool? isLoading,
    String? error,
    AgentTurnTraceSummary? summary,
    List<AgentStepTrace>? steps,
    Map<int, AgentStepTraceDetail>? stepDetails,
    int? firstAvailableTurn,
  }) {
    return AgentRoundTraceState(
      isLoading: isLoading ?? this.isLoading,
      error: error,
      summary: summary ?? this.summary,
      steps: steps ?? this.steps,
      stepDetails: stepDetails ?? this.stepDetails,
      firstAvailableTurn: firstAvailableTurn ?? this.firstAvailableTurn,
    );
  }
}

/// 轮轨迹控制器
///
/// 按会话+轮从 agent_event_log_repository 读事件，三层展示：
/// ①轮摘要 ②步时间线 ③单步详情（deriveAgentSurface 投影重建请求序列）。
/// 纯只读——不改任何会话状态。
/// 技术标签（步名/原因等）为英文字面量； 的裁剪标注走 slang
///（advanced.roundTrace.trimmedNotice），由页面渲染。
class AgentRoundTraceController extends StateNotifier<AgentRoundTraceState> {
  AgentRoundTraceController({
    required AgentEventLogStore repository,
    required this.sessionId,
    required this.turnNumber,
  })  : _repository = repository,
        super(const AgentRoundTraceState()) {
    load();
  }

  final AgentEventLogStore _repository;
  final String sessionId;
  final int turnNumber;

  List<AgentDurableEvent> _allEvents = const [];

  /// 步首事件在 _allEvents 中的下标（详情重建的水位线）
  final Map<int, int> _stepAssistantIndex = {};

  Future<void> load() async {
    try {
      final events = await _repository.readEvents(sessionId);
      _allEvents = events;
      state = AgentRoundTraceState(
        isLoading: false,
        summary: _buildSummary(events),
        steps: _buildSteps(events),
        firstAvailableTurn: _firstTurnOf(events),
      );
    } catch (e) {
      state = AgentRoundTraceState(isLoading: false, error: e.toString());
    }
  }

  /// 日志中最早带 turn 戳的轮号（无带戳事件返回 null）
  static int? _firstTurnOf(List<AgentDurableEvent> events) {
    int? first;
    for (final event in events) {
      final turn = event.data['turn'];
      if (turn is int && (first == null || turn < first)) first = turn;
    }
    return first;
  }

  /// L3：点开单步时才计算请求重建与全文
  Future<void> loadStepDetail(int stepIndex) async {
    if (state.stepDetails.containsKey(stepIndex)) return;
    final assistantIndex = _stepAssistantIndex[stepIndex];
    if (assistantIndex == null) return;

    // 请求 = 本步 assistant 消息之前的全部事件投影（含历史轮与轮首消息）。
    //  起尾部装配面（契约/铁律/节奏/漂移/挪尾 coreBlocks）与 round-work
    // 痕迹已落日志，重建尽量精确；跨轮残留的旧尾部为已知近似项。
    final requestProjection =
        deriveAgentSurface(_allEvents.sublist(0, assistantIndex));

    final responseBuffer = StringBuffer();
    final toolResults =
        <({String toolName, String callId, String output, bool isError})>[];
    for (final event in _allEvents.skip(assistantIndex)) {
      final turn = event.data['turn'];
      if (turn is int && turn != turnNumber) break;
      if (event.type == AgentEventTypes.assistantMessage) {
        final text = event.data['text'] as String?;
        if (text != null && text.isNotEmpty) {
          responseBuffer.writeln(text);
        }
        final toolCalls = event.data['toolCalls'] as List<dynamic>? ?? const [];
        for (final tc in toolCalls) {
          if (tc is Map<String, dynamic>) {
            responseBuffer.writeln(
              '[tool_call] ${tc['name']} ${tc['args']}',
            );
          }
        }
      } else if (event.type == AgentEventTypes.toolResult) {
        toolResults.add(
          (
            toolName: (event.data['toolName'] as String?) ?? '',
            callId: (event.data['callId'] as String?) ?? '',
            output: (event.data['output'] as String?) ?? '',
            isError: event.data['isError'] == true,
          ),
        );
        // 本步工具结果之后遇到下一 step 事件即止
      } else if (event.type == AgentEventTypes.stepBegin) {
        final idx = event.data['stepIndex'];
        if (idx is int && idx > stepIndex) break;
      } else if (event.type == AgentEventTypes.stepEnd) {
        final idx = event.data['stepIndex'];
        if (idx is int && idx > stepIndex) break;
      }
    }

    state = state.copyWith(
      stepDetails: {
        ...state.stepDetails,
        stepIndex: AgentStepTraceDetail(
          requestMessages: requestProjection.messages,
          responseText: responseBuffer.toString(),
          toolResults: toolResults,
        ),
      },
    );
  }

  AgentTurnTraceSummary? _buildSummary(List<AgentDurableEvent> events) {
    int? beginMs;
    int? endMs;
    String? reason;
    var steps = 0;
    var promptTokens = 0;
    var completionTokens = 0;
    var totalTokens = 0;
    String? errorMessage;

    for (final event in events) {
      final turn = event.data['turn'];
      if (turn is! int || turn != turnNumber) continue;
      // 子代理中继事件不并入主轮摘要——turnBegin
      // 会被子代理的晚到 begin 覆盖（时长从子代理启动起算、时长少算），
      // stepEnd/分项把子代理步数并进主轮（steps 与时间线行数不一致）。
      // 与 _buildSteps 的  过滤同款。
      if (event.data['subagent'] == true) continue;
      switch (event.type) {
        case AgentEventTypes.turnBegin:
          beginMs = event.time.millisecondsSinceEpoch;
        case AgentEventTypes.turnEnd:
          endMs = event.time.millisecondsSinceEpoch;
          reason = event.data['reason'] as String?;
          errorMessage = event.data['error'] as String?;
        case AgentEventTypes.stepEnd:
          steps++;
          promptTokens += (event.data['promptTokens'] as int?) ?? 0;
          completionTokens += (event.data['completionTokens'] as int?) ?? 0;
          totalTokens += (event.data['totalTokens'] as int?) ?? 0;
        default:
          break;
      }
    }
    if (beginMs == null && endMs == null) return null;
    return AgentTurnTraceSummary(
      turnNumber: turnNumber,
      reason: reason,
      steps: steps,
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      totalTokens: totalTokens,
      errorMessage: errorMessage,
      durationMs: beginMs != null && endMs != null ? endMs - beginMs : null,
    );
  }

  List<AgentStepTrace> _buildSteps(List<AgentDurableEvent> events) {
    // 审查收官 ：子代理中继事件（data.subagent=true）不并入主轮
    // 时间线——同号 stepBegin 会造重复步行、stepEnd 并错账、详情被截断
    final turnEvents = <AgentDurableEvent>[
      for (final event in events)
        if (event.data['turn'] == turnNumber && event.data['subagent'] != true)
          event,
    ];

    // 先建索引：assistant/message 事件的 stepIndex → 事件下标（全局）
    for (var i = 0; i < events.length; i++) {
      final event = events[i];
      if (event.type != AgentEventTypes.assistantMessage) continue;
      final stepIndex = (event.data['stepIndex'] as int?) ?? 0;
      _stepAssistantIndex.putIfAbsent(stepIndex, () => i);
    }

    final stepAssistantArgs = <int, List<AgentToolCall>>{};
    // 审查收官 ：assistant/message 事件的 stepIndex→参数 先全量
    // 建索引（durable 顺序 step/begin 早于 assistant/message，单遍扫描时
    // stepBegin 行拿不到当步参数，toolCalls 恒空）
    for (final event in turnEvents) {
      if (event.type != AgentEventTypes.assistantMessage) continue;
      final stepIndex = (event.data['stepIndex'] as int?) ?? 0;
      stepAssistantArgs.putIfAbsent(
        stepIndex,
        () => _toolCallsFromData(event.data),
      );
    }
    final result = <AgentStepTrace>[];
    for (final event in turnEvents) {
      switch (event.type) {
        // 注入面消息（尾部契约/节奏/漂移/痕迹等）入时间线展示
        case AgentEventTypes.userMessage:
          final source = event.data['source'] as String?;
          if (source == null || source == 'user') break;
          result.add(
            AgentStepTrace(
              stepIndex: -(result.length + 1),
              beginMs: event.time.millisecondsSinceEpoch,
              toolCalls: const [],
              tools: const [],
              label: 'inject:$source',
            ),
          );
        // doom 触发展示（此前只在轮摘要 reason 里体现）
        case AgentEventTypes.doomLoop:
          result.add(
            AgentStepTrace(
              stepIndex: -(result.length + 1),
              beginMs: event.time.millisecondsSinceEpoch,
              toolCalls: [
                (
                  name: (event.data['toolName'] as String?) ?? '',
                  argsPreview: 'consecutive=${event.data['consecutiveCalls']}',
                ),
              ],
              tools: const [],
              label: 'doom-loop',
            ),
          );
        // persist 嵌入降级 durable 留痕「只写
        // 不读」——轨迹页补渲染一行（此前仅诊断页原始事件流可见，
        // 「本轮嵌入已降级、语义检索缺席」对用户不可达）。
        case AgentEventTypes.persistEmbeddingDegraded:
          result.add(
            AgentStepTrace(
              stepIndex: -(result.length + 1),
              beginMs: event.time.millisecondsSinceEpoch,
              toolCalls: const [],
              tools: const [],
              label: 'persist/embedding-degraded',
            ),
          );
        case AgentEventTypes.stepBegin:
          final stepIndex = (event.data['stepIndex'] as int?) ?? 0;
          result.add(
            AgentStepTrace(
              stepIndex: stepIndex,
              beginMs: event.time.millisecondsSinceEpoch,
              toolCalls: [
                for (final AgentToolCall call
                    in stepAssistantArgs[stepIndex] ?? const <AgentToolCall>[])
                  (
                    name: call.name,
                    argsPreview: call.arguments.toString(),
                  ),
              ],
              tools: const [],
            ),
          );
        case AgentEventTypes.assistantMessage:
        // 参数已在扫描前全量建索引（两遍扫描）
        case AgentEventTypes.stepEnd:
          final stepIndex = (event.data['stepIndex'] as int?) ?? 0;
          final index = result.indexWhere((s) => s.stepIndex == stepIndex);
          if (index >= 0) {
            final old = result[index];
            result[index] = AgentStepTrace(
              stepIndex: old.stepIndex,
              beginMs: old.beginMs,
              endMs: event.time.millisecondsSinceEpoch,
              stopKind: event.data['stopKind'] as String?,
              promptTokens: event.data['promptTokens'] as int?,
              completionTokens: event.data['completionTokens'] as int?,
              toolCalls: old.toolCalls,
              tools: old.tools,
            );
          }
        case AgentEventTypes.toolResult:
          final entry = (
            callId: (event.data['callId'] as String?) ?? '',
            toolName: (event.data['toolName'] as String?) ?? '',
            title: (event.data['title'] as String?) ?? '',
            durationMs: event.data['durationMs'] as int?,
            isError: event.data['isError'] == true,
          );
          // 归并到最近一个步（工具执行总发生在其发起步的下一条
          // StepStarted 之前；简单追加到当前最后一个未完结步）
          if (result.isNotEmpty) {
            final index = result.lastIndexWhere((s) => s.endMs == null);
            final target = index >= 0 ? index : result.length - 1;
            final old = result[target];
            result[target] = AgentStepTrace(
              stepIndex: old.stepIndex,
              beginMs: old.beginMs,
              endMs: old.endMs,
              stopKind: old.stopKind,
              promptTokens: old.promptTokens,
              completionTokens: old.completionTokens,
              toolCalls: old.toolCalls,
              tools: [...old.tools, entry],
            );
          }
        default:
          break;
      }
    }
    return result;
  }

  static List<AgentToolCall> _toolCallsFromData(Map<String, dynamic> data) {
    return (data['toolCalls'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(
          (tc) => AgentToolCall(
            id: (tc['id'] as String?) ?? '',
            name: (tc['name'] as String?) ?? '',
            arguments:
                (tc['args'] as Map?)?.cast<String, dynamic>() ?? const {},
            thoughtSignature: tc['thoughtSignature'] as String?,
          ),
        )
        .toList();
  }
}

/// 会话+轮 → 控制器 provider（入口页传参构造）
final agentRoundTraceControllerProvider = StateNotifierProvider.family<
    AgentRoundTraceController,
    AgentRoundTraceState,
    ({String sessionId, int turnNumber})>(
  (ref, params) {
    return AgentRoundTraceController(
      // 散建收口——统一读组合根 provider
      repository: ref.read(agentEventLogRepositoryProvider),
      sessionId: params.sessionId,
      turnNumber: params.turnNumber,
    );
  },
);

// AgentEventTypes/AgentStopReason 的 reason 标签映射（英文字面量，开发者标签）
String agentStopReasonLabel(String? reason) => reason ?? 'unknown';
