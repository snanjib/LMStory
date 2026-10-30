import 'dart:async';

import 'package:lmstory/core/agent/agent_events.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/agent/agent_runner.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/services/agent_log_recovery.dart';

/// 持久事件出口：live 事件 → durable 事件（缓冲 → flush 落库）
///
/// 写入时机（设计报告 §7.3）：
/// - turn 边界 flush（控制器在轮结束时 await flush）
/// - 语义检查点：request 钩子在每次 LLM 请求前 await flush，
///   保证"进模型的必已入日志"
///
/// 事件映射：
/// - turn/begin / turn/end / step/begin / step/end：log-only
/// - assistant/message、tool/result、user/message（harness 注入）：
///   surface append
/// - assistant/chunk：流式正文分片 log-only——最小粒度聚合落盘
///   （[chunkThreshold] 字符一批，默认开），[fullChunkEvents] = true 时
///   每 delta 一事件（全量落盘，默认关）；中断恢复经
///   rebuildInterruptedAssistantText 消费；思考增量不落库（只需正文）
class DurableAgentEventSink implements AgentEventSink {
  DurableAgentEventSink({
    required AgentEventLogStore repository,
    required this.sessionId,
    this.turnNumber,
    this.chunkThreshold = 200,
    this.fullChunkEvents = false,
    Logger? logger,
  })  : _repository = repository,
        _logger = logger;

  final AgentEventLogStore _repository;
  final String sessionId;

  /// 本轮序号（用于事件日志按轮分组，供载入时反推工作过程；null = 未关联轮次）
  final int? turnNumber;

  /// 分片聚合阈值（字符）：缓冲累计 ≥ 此值落一条 assistant/chunk。
  /// ≤0 = 关闭阈值聚合档；全量档由 [fullChunkEvents] 独立控制（两开关
  /// 任一开启分片即落盘，见 [_chunkEventsEnabled]）。
  final int chunkThreshold;

  /// 全量落盘开关（每个文本 delta 一条 assistant/chunk）。默认关——
  /// 存储成本高，最小粒度（阈值聚合）已满足中断重建。
  final bool fullChunkEvents;

  final Logger? _logger;

  final List<AgentDurableEvent> _buffer = [];
  Future<void>? _flushFuture;

  /// 各 step 的分片聚合缓冲（：中断重建素材；不足阈值的尾段在
  /// flush 前随 _flushTrailingChunks 一并落账）
  final Map<int, String> _chunkBuffers = {};

  /// 缓冲是否为空
  bool get isEmpty => _buffer.isEmpty;

  @override
  void emit(AgentRunEvent event) {
    if (event is AgentTextDeltaEvent && _chunkEventsEnabled) {
      _accumulateChunk(event);
    }
    if (event is AgentStepStarted && event.attempt > 0) {
      // 契约 §7.1：重试丢弃半截流——chunk 重建口径同步清空（reset 标记）
      _emitChunkReset(event.stepIndex);
    }
    if (event is AgentAssistantMessageEvent) {
      // 完整 assistant 消息入账即取代该 step 的全部分片
      _chunkBuffers.remove(event.stepIndex);
    }
    final durable = _map(event);
    if (durable != null) {
      if (turnNumber != null) durable.data['turn'] = turnNumber;
      _buffer.add(durable);
    }
  }

  bool get _chunkEventsEnabled => fullChunkEvents || chunkThreshold > 0;

  void _accumulateChunk(AgentTextDeltaEvent event) {
    final stepIndex = event.stepIndex;
    if (fullChunkEvents) {
      _appendChunkEvent(stepIndex, event.delta);
      return;
    }
    final buffered = (_chunkBuffers[stepIndex] ?? '') + event.delta;
    if (buffered.length >= chunkThreshold) {
      _chunkBuffers.remove(stepIndex);
      _appendChunkEvent(stepIndex, buffered);
    } else {
      _chunkBuffers[stepIndex] = buffered;
    }
  }

  void _emitChunkReset(int stepIndex) {
    if (!_chunkEventsEnabled) return;
    _chunkBuffers.remove(stepIndex);
    _appendBuffered(
      AgentDurableEvent(
        type: AgentEventTypes.assistantChunk,
        data: {'stepIndex': stepIndex, 'reset': true},
      ),
    );
  }

  void _appendChunkEvent(int stepIndex, String text) {
    if (text.isEmpty) return;
    _appendBuffered(
      AgentDurableEvent(
        type: AgentEventTypes.assistantChunk,
        data: {'stepIndex': stepIndex, 'text': text},
      ),
    );
  }

  void _appendBuffered(AgentDurableEvent durable) {
    if (turnNumber != null) durable.data['turn'] = turnNumber;
    _buffer.add(durable);
  }

  /// 子代理事件中继（：spawn 内部可观测，log-only）
  ///
  /// 子代理是独立上下文——其 surface 事件（assistant/tool 结果）若带
  /// surfaceOp 进主会话日志会污染投影（与主轮实际 outgoing 不符），
  /// 统一剥离 surface 语义落 log-only：步数/usage/工具产出在日志与
  /// 轨迹页可查，投影不动。
  void relaySubagentEvent(AgentRunEvent event) {
    final durable = _map(event);
    if (durable != null) {
      _appendBuffered(
        AgentDurableEvent(
          type: durable.type,
          data: {...durable.data, 'subagent': true},
        ),
      );
    }
  }

  /// 直接入队并落库（控制器写用户消息/system 事件用，保证"进模型的必已入日志"）
  Future<void> appendNow(AgentDurableEvent event) async {
    _buffer.add(event);
    await flush();
  }

  /// 落库全部缓冲事件（幂等；并发调用合并为一次）
  Future<void> flush() {
    _flushTrailingChunks();
    if (_buffer.isEmpty) return Future.value();
    return _flushFuture ??= _doFlush().whenComplete(() {
      _flushFuture = null;
    });
  }

  /// 尾段分片落库：不足阈值的残留缓冲随 flush 一并落账
  ///
  /// 调用时机与语义检查点一致（每次 flush 前清空 _chunkBuffers 进
  /// _buffer）——中断前的最后一次 flush 已包含当时的全部正文进度，
  /// 重建损失窗口 ≈ 最后一个网络分片（而非 chunkThreshold 字符）。
  void _flushTrailingChunks() {
    if (!_chunkEventsEnabled || _chunkBuffers.isEmpty) return;
    final steps = _chunkBuffers.keys.toList()..sort();
    for (final step in steps) {
      final text = _chunkBuffers.remove(step);
      if (text != null && text.isNotEmpty) {
        _appendChunkEvent(step, text);
      }
    }
  }

  Future<void> _doFlush() async {
    while (_buffer.isNotEmpty) {
      final batch = List<AgentDurableEvent>.of(_buffer);
      try {
        await _repository.appendAll(sessionId, batch);
        _buffer.removeRange(0, batch.length);
      } on Exception catch (e) {
        // 落库失败：保留缓冲等待下次 flush；日志可见（不静默丢事件）
        _logger?.error(
          'Agent durable event flush failed',
          detail: 'sessionId=$sessionId, pending=${_buffer.length}, error=$e',
        );
        rethrow;
      }
    }
  }

  /// live 事件 → durable 事件（null = 不落库）
  AgentDurableEvent? _map(AgentRunEvent event) {
    return switch (event) {
      AgentTurnStarted(:final maxSteps, :final resumed) => AgentDurableEvent(
          type: AgentEventTypes.turnBegin,
          // resumed=true 标记失败后的续跑段（同 turn 多段时轨迹可辨）
          data: {'maxSteps': maxSteps, if (resumed) 'resumed': true},
        ),
      AgentTurnFinished(
        :final reason,
        :final steps,
        :final usage,
        :final errorMessage
      ) =>
        AgentDurableEvent(
          type: AgentEventTypes.turnEnd,
          data: {
            'reason': reason.name,
            'steps': steps,
            'promptTokens': usage.promptTokens,
            'completionTokens': usage.completionTokens,
            'totalTokens': usage.totalTokens,
            // cache 分项进 durable（旧日志缺键读取侧按 0 处理）
            'cacheReadTokens': usage.cacheReadTokens,
            'cacheCreationTokens': usage.cacheCreationTokens,
            if (errorMessage != null) 'error': errorMessage,
          },
        ),
      AgentStepStarted(:final stepIndex, :final attempt) => AgentDurableEvent(
          type: AgentEventTypes.stepBegin,
          data: {
            'stepIndex': stepIndex,
            // attempt 仅落日志字段（重试诊断）；恢复逻辑不消费（契约 §7.1）
            if (attempt > 0) 'attempt': attempt,
          },
        ),
      AgentStepFinished(
        :final stepIndex,
        :final stopKind,
        :final promptTokens,
        :final completionTokens,
        :final totalTokens,
        :final cacheReadTokens,
        :final cacheCreationTokens,
      ) =>
        AgentDurableEvent(
          type: AgentEventTypes.stepEnd,
          data: {
            'stepIndex': stepIndex,
            'stopKind': stopKind.name,
            'promptTokens': promptTokens,
            'completionTokens': completionTokens,
            'totalTokens': totalTokens,
            // cache 分项进 durable（null 端点不上报时不落键，读取侧
            // 兼容旧日志与无缓存端点两种缺键形态）
            if (cacheReadTokens != null) 'cacheReadTokens': cacheReadTokens,
            if (cacheCreationTokens != null)
              'cacheCreationTokens': cacheCreationTokens,
          },
        ),
      AgentAssistantMessageEvent(:final stepIndex, :final message) =>
        AgentDurableEvent(
          type: AgentEventTypes.assistantMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: _assistantData(message, stepIndex),
        ),
      AgentToolExecutionFinished(
        :final callId,
        :final toolName,
        :final output,
        :final isError,
        :final title,
        :final duration,
      ) =>
        AgentDurableEvent(
          type: AgentEventTypes.toolResult,
          surfaceOp: AgentSurfaceOpKind.append,
          data: AgentToolResultData(
            callId: callId,
            toolName: toolName,
            output: output,
            isError: isError,
            title: title,
            // 工具耗时进 durable 层（轮轨迹步时间线；此前仅内存 live 事件有）
            durationMs: duration.inMilliseconds,
          ).toJson(),
        ),
      //  补账：轮内 harness 注入（最后通牒/续跑提示/执笔重述）落为
      // user/message（source=注入来源），日志从此可重建每步消息序列
      AgentInjectedMessageEvent(:final message, :final kind) =>
        AgentDurableEvent(
          type: AgentEventTypes.userMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: AgentUserMessageData(
            content: message.content ?? '',
            source: kind,
          ).toJson(),
        ),
      AgentDoomLoopDetected(:final toolName, :final consecutiveCalls) =>
        AgentDurableEvent(
          type: AgentEventTypes.doomLoop,
          data: {'toolName': toolName, 'consecutiveCalls': consecutiveCalls},
        ),
      // 溢出压缩结果落日志（surface/replace），投影可反映压缩后序列
      AgentSurfaceReplaced(
        :final messages,
        :final replaceStart,
        :final replaceEnd
      ) =>
        AgentDurableEvent(
          type: AgentEventTypes.surfaceReplace,
          surfaceOp: AgentSurfaceOpKind.replace,
          replaceStart: replaceStart,
          replaceEnd: replaceEnd,
          data: {
            'messages': [
              for (final m in messages) agentMessageToSurfaceData(m),
            ],
          },
        ),
      AgentTextDeltaEvent() ||
      AgentThinkingDeltaEvent() ||
      AgentToolCallReceived() ||
      AgentToolExecutionStarted() ||
      // 重试等待是瞬态 UI 状态（等待结束即失效），不落 durable 日志
      AgentRetryScheduled() =>
        null,
    };
  }

  Map<String, dynamic> _assistantData(AgentMessage message, int stepIndex) {
    return AgentAssistantMessageData(
      text: message.content,
      reasoningContent: message.reasoningContent,
      stepIndex: stepIndex,
      toolCalls: (message.toolCalls ?? const [])
          .map(
            (tc) => {
              'id': tc.id,
              'name': tc.name,
              'args': tc.arguments,
              if (tc.thoughtSignature != null)
                'thoughtSignature': tc.thoughtSignature,
            },
          )
          .toList(),
      thinkingBlocks: (message.thinkingBlocks ?? const [])
          .map(
            (b) => {'thinking': b.thinking, 'signature': b.signature},
          )
          .toList(),
    ).toJson();
  }
}
