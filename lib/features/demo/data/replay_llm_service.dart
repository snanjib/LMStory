import 'dart:async';

import 'package:lmstory/core/llm/llm_content_block.dart';
import 'package:lmstory/core/llm/tool_calling/tool_call.dart';
import 'package:lmstory/core/network/http_client_types.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/demo/data/demo_network_guard.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';
import 'package:lmstory/features/demo/domain/demo_replay_timing.dart';

/// 回放未匹配本地失败异常（chat 通道）
class DemoReplayUnmatchedException implements Exception {
  const DemoReplayUnmatchedException(this.purpose);

  final String? purpose;

  @override
  String toString() => 'DemoReplayUnmatchedException(purpose: $purpose)';
}

/// 演示回放 LlmService：按（purpose × turn × purpose 内步序）供给包内
/// 预置领域事件，零网络依赖。
///
/// 匹配与消耗规则（契约 §6）：
/// - `streamChat`：purpose 未标注/包内耗尽 → 发
///   `LlmStreamError(code: demo_replay_unmatched)` 并计入守卫，绝不
///   回退联网（本类无任何网络出口）。
/// - 步「完整送达 done 且监听端正常完成」才消耗；中途取消/异常不消耗，
///   同一请求重试从该步头部重放——取消、重复发送、重试、并行辅助调用
///   不会串流或消耗错误响应。
/// - `chat`：命中构造 [LlmResponse]；未匹配抛 [DemoReplayUnmatchedException]。
/// - 回放事件间让出事件循环（流式 UI 有调度点；取消检查有生效窗口）。
class DemoReplayLlmService implements LlmService {
  DemoReplayLlmService({
    required DemoPack pack,
    required DemoNetworkGuard guard,
    this.interEventDelay = Duration.zero,
    this.timing = const DemoReplayTiming(),
    this.onRoundStarted,
  })  : _pack = pack,
        _guard = guard;

  /// 额外的事件间调度窗口，仅测试取消语义时使用。
  /// 生产播放速度由 [timing] 决定，不依赖录制分片。
  final Duration interEventDelay;

  final DemoReplayTiming timing;

  /// 首轮回放开始回调（演示装配注入 `selection.lock`）：首次叙事步
  /// （agent_step）调用即触发——首轮开始即锁定候选绑定，不依赖后续
  /// agent_events 轮询。仅触发一次；[attachPack] 不复位
  /// （锁定语义单调，换包后同样保持）。辅助通道（标题/建议/摘要等）
  /// 不触发——它们不是回合开始的证据。
  final void Function()? onRoundStarted;
  bool _roundStartedNotified = false;

  DemoPack _pack;
  final DemoNetworkGuard _guard;

  /// 当前绑定数据包（多仿真候选选择绑定的换包入口见 [attachPack]）
  DemoPack get pack => _pack;

  /// 当前演示回合号（本场景恒 1；resetTurn 由桥在重发/新 run 时调用）
  final int _turn = 1;

  /// purpose → 下一个未消费流式步的索引（包内顺序）
  final Map<String, int> _streamCursor = {};

  /// purpose → 下一个未消费非流式条目索引
  final Map<String, int> _chatCursor = {};

  /// 已消费流式步总数（诊断）
  int get consumedStreamSteps => _streamCursor.values.fold(0, (a, b) => a + b);

  void resetTurn() {
    _streamCursor.clear();
    _chatCursor.clear();
  }

  /// 换绑数据包（多仿真候选选择）：原子替换消费源并重置回放游标——
  /// 换包后同 purpose 请求从新包头部回放，不会串到旧包残余。
  void attachPack(DemoPack pack) {
    _pack = pack;
    resetTurn();
  }

  void _recordUnmatched(String? purpose, String channel) {
    _guard.record(
      'replayUnmatched',
      '$channel purpose=${purpose ?? 'null'} turn=$_turn',
    );
  }

  /// 首次叙事步调用即视为回合开始（见 [onRoundStarted]）
  void _notifyRoundStarted(String? purpose) {
    if (_roundStartedNotified || purpose != LlmPurposes.agentStep) return;
    _roundStartedNotified = true;
    onRoundStarted?.call();
  }

  @override
  Stream<LlmStreamEvent> streamChat(LlmRequest request) async* {
    final purpose = request.purpose;
    if (purpose == null) {
      _recordUnmatched(purpose, 'stream');
      yield const LlmStreamError(
        '演示回放：请求未标注用途（purpose），无法匹配预置响应',
        code: 'demo_replay_unmatched',
      );
      return;
    }
    _notifyRoundStarted(purpose);
    final steps = _pack.streamSteps
        .where((s) => s.purpose == purpose && s.turn == _turn)
        .toList();
    final cursor = _streamCursor[purpose] ?? 0;
    if (cursor >= steps.length) {
      _recordUnmatched(purpose, 'stream');
      yield LlmStreamError(
        '演示回放：purpose=$purpose 的预置响应已耗尽（第 ${cursor + 1} 步不存在）',
        code: 'demo_replay_unmatched',
      );
      return;
    }

    await _wait(request, _requestDelay(request));
    final step = steps[cursor];
    final shouldCoalesce =
        timing.textRunesPerSecond > 0 && timing.tickInterval > Duration.zero;
    final eventsToReplay =
        shouldCoalesce ? _coalesceAdjacentDeltas(step.events) : step.events;
    for (final raw in eventsToReplay) {
      await _wait(request, interEventDelay);
      final event = _mapEvent(raw);
      // 按码点重分片与调度：不同供应商的原始分片大小不影响播放速度。
      // 生产按 text 240 runes/s, thinking 480 runes/s 与 ~40ms 调度；
      // 工具参数及结构化块保持原样，避免给内部步骤叠加逐字等待。
      if (event is LlmTextDelta || event is LlmThinkingDelta) {
        final isThinking = event is LlmThinkingDelta;
        final rate = isThinking
            ? timing.thinkingRunesPerSecond
            : timing.textRunesPerSecond;

        if (rate <= 0 || timing.tickInterval <= Duration.zero) {
          yield event;
          continue;
        }

        final content = event is LlmThinkingDelta
            ? event.content
            : (event as LlmTextDelta).content;
        final runes = content.runes.toList(growable: false);
        if (runes.isEmpty) {
          yield event;
          continue;
        }

        final runesPerTick =
            ((timing.tickInterval.inMicroseconds * rate) / 1000000).ceil();
        final chunkSize = runesPerTick < 1 ? 1 : runesPerTick;

        for (var offset = 0; offset < runes.length; offset += chunkSize) {
          await _wait(request, timing.tickInterval);
          final end = (offset + chunkSize < runes.length)
              ? offset + chunkSize
              : runes.length;
          final chunkText = String.fromCharCodes(runes.sublist(offset, end));
          yield isThinking
              ? LlmThinkingDelta(chunkText)
              : LlmTextDelta(chunkText);
        }
        continue;
      }
      if (event is LlmStreamError) {
        // 预置 error 事件：按原语义发出，且该步视为已送达（不消耗
        // 语义由「done 才消耗」放宽为「终止事件送达即消耗」——error
        // 事件本身就是该步的完整终止）
        _consume(purpose, cursor);
        yield event;
        return;
      }
      if (event is LlmStreamDone) {
        _consume(purpose, cursor);
        yield event;
        return;
      }
      yield event;
    }
    _throwIfCancelled(request);
    _consume(purpose, cursor);
  }

  void _consume(String purpose, int cursorIndex) {
    _streamCursor[purpose] = cursorIndex + 1;
  }

  void _throwIfCancelled(LlmRequest request) {
    final token = request.cancelToken;
    if (token != null && token.isCancelled) {
      throw const CancelledException('demo replay cancelled');
    }
  }

  Duration _requestDelay(LlmRequest request) =>
      request.purpose == LlmPurposes.sessionTitle
          ? Duration.zero
          : timing.requestDelay;

  Future<void> _wait(LlmRequest request, Duration duration) async {
    _throwIfCancelled(request);
    if (duration == Duration.zero) {
      await null;
    } else {
      await Future<void>.delayed(duration);
    }
    _throwIfCancelled(request);
  }

  @override
  Future<LlmResponse> chat(LlmRequest request) async {
    final purpose = request.purpose;
    if (purpose == null) {
      _recordUnmatched(purpose, 'chat');
      throw DemoReplayUnmatchedException(purpose);
    }
    _notifyRoundStarted(purpose);
    final entries =
        _pack.chatEntriesOf(purpose).where((c) => c.turn == _turn).toList();
    final cursor = _chatCursor[purpose] ?? 0;
    if (cursor >= entries.length) {
      _recordUnmatched(purpose, 'chat');
      throw DemoReplayUnmatchedException(purpose);
    }
    await _wait(request, _requestDelay(request));
    final resp = entries[cursor].response;
    _chatCursor[purpose] = cursor + 1;
    return LlmResponse(
      content: resp['content'] as String? ?? '',
      finishReason: resp['finishReason'] as String?,
      usage: _mapUsage(resp['usage']),
      reasoningContent: resp['reasoningContent'] as String?,
      toolCalls: _mapToolCalls(resp['toolCalls']),
    );
  }

  LlmUsage? _mapUsage(Object? raw) {
    if (raw is! Map) return null;
    return LlmUsage(
      promptTokens: raw['promptTokens'] as int?,
      completionTokens: raw['completionTokens'] as int?,
      totalTokens: raw['totalTokens'] as int?,
      totalInputTokens: raw['totalInputTokens'] as int?,
      cacheReadTokens: raw['cacheReadTokens'] as int?,
      cacheCreationTokens: raw['cacheCreationTokens'] as int?,
    );
  }

  List<ToolCall>? _mapToolCalls(Object? raw) {
    if (raw is! List) return null;
    final calls = <ToolCall>[];
    for (final tc in raw) {
      if (tc is! Map) continue;
      calls.add(
        ToolCall(
          id: tc['toolCallId'] as String? ?? '',
          name: tc['name'] as String? ?? '',
          arguments: Map<String, dynamic>.from(tc['arguments'] as Map? ?? {}),
          thoughtSignature: tc['thoughtSignature'] as String?,
        ),
      );
    }
    return calls.isEmpty ? null : calls;
  }

  /// 跨相邻同类 delta 累计合并，消除不同供应商分片颗粒度对调度时长的干扰。
  List<Map<String, dynamic>> _coalesceAdjacentDeltas(
    List<Map<String, dynamic>> rawEvents,
  ) {
    if (rawEvents.length <= 1) return rawEvents;
    final merged = <Map<String, dynamic>>[];
    for (final raw in rawEvents) {
      final type = raw['type'] as String?;
      if (type == 'text_delta' || type == 'thinking_delta') {
        final content = raw['content'] as String? ?? '';
        if (content.isEmpty) continue;
        if (merged.isNotEmpty && merged.last['type'] == type) {
          final prevContent = merged.last['content'] as String? ?? '';
          merged.last = {
            ...merged.last,
            'content': prevContent + content,
          };
          continue;
        }
      }
      merged.add(raw);
    }
    return merged;
  }

  LlmStreamEvent _mapEvent(Map<String, dynamic> e) {
    switch (e['type'] as String) {
      case 'text_delta':
        return LlmTextDelta(e['content'] as String);
      case 'thinking_delta':
        return LlmThinkingDelta(e['content'] as String);
      case 'tool_call_start':
        return LlmToolCallStart(
          e['toolCallId'] as String,
          e['name'] as String,
        );
      case 'tool_call_args':
        return LlmToolCallArgs(
          e['toolCallId'] as String,
          e['argsDelta'] as String,
        );
      case 'tool_call_complete':
        return LlmToolCallComplete(
          toolCallId: e['toolCallId'] as String,
          name: e['name'] as String,
          arguments: Map<String, dynamic>.from(e['arguments'] as Map),
          thoughtSignature: e['thoughtSignature'] as String?,
        );
      case 'content_block_complete':
        final block = LlmContentBlock.fromJson(
          Map<String, dynamic>.from(e['block'] as Map),
        );
        return LlmContentBlockComplete(
          block ?? const LlmTextContentBlock(text: ''),
        );
      case 'thinking_block_complete':
        return LlmThinkingBlockComplete(
          thinking: e['thinking'] as String,
          signature: e['signature'] as String,
        );
      case 'done':
        return LlmStreamDone(
          usage: _mapUsage(e['usage']),
          finishReason: e['finishReason'] as String?,
        );
      case 'error':
        final retryMs = e['retryAfterMs'] as int?;
        return LlmStreamError(
          e['message'] as String,
          code: e['code'] as String?,
          retryAfter: retryMs == null ? null : Duration(milliseconds: retryMs),
        );
      default:
        // parse 已限定事件类型；此处不可达
        return LlmStreamError('演示回放：未知事件 ${e['type']}');
    }
  }
}
