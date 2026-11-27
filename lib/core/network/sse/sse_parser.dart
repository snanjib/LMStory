import 'dart:convert';

import 'package:lmstory/core/network/retry_after.dart';
import 'package:lmstory/core/network/sse/streaming_tool_call_tracker.dart';
import 'package:lmstory/core/utils/logger.dart';

/// SSE 解析器状态
enum SseParserState {
  idle,
  streamingText,
  toolCallDetected,
  accumulatingArgs,
  executingTool,
}

/// SSE 事件类型
sealed class SseEvent {
  const SseEvent();
}

class TextDelta extends SseEvent {
  const TextDelta(this.content);

  final String content;
}

/// 思考/推理内容增量事件
///
/// 用于 OpenAI 兼容格式的思考内容字段：
/// - DeepSeek-R1 / 部分供应商：`delta.reasoning_content`
/// - OpenAI o-series / OpenRouter：`delta.reasoning`
///
/// 与 TextDelta 分开，便于 UI 分别展示思考过程和正式回复。
class ThinkingDelta extends SseEvent {
  const ThinkingDelta(this.content);

  final String content;
}

class ToolCallStart extends SseEvent {
  const ToolCallStart(this.toolCallId, this.toolName);

  final String toolCallId;
  final String toolName;
}

class ToolCallArgs extends SseEvent {
  const ToolCallArgs(this.toolCallId, this.argsChunk);

  final String toolCallId;
  final String argsChunk;
}

class ToolCallComplete extends SseEvent {
  const ToolCallComplete(
    this.toolCallId,
    this.toolName,
    this.arguments,
  );

  final String toolCallId;
  final String toolName;
  final String arguments;
}

class StreamEnd extends SseEvent {
  const StreamEnd({this.usage, this.finishReason});

  /// 流式响应的 usage 数据（来自最后一个 chunk 的 usage 字段）
  /// 包含 total_tokens 等，用于在消息下方显示 tokens 使用量
  final SseUsage? usage;

  /// 最后一次收到的 finish_reason（stop/tool_calls/length/content_filter…）
  ///
  /// 2026-08-17 新增：推理型模型可能把输出预算全部花在思维链上，
  /// `finish_reason=length` 且 content 为空——调用方需要区分
  /// 「被截断」与「模型主动返回空」。
  final String? finishReason;
}

/// SSE 流式响应的 usage 数据
///
/// 对应 OpenAI API 响应中的 usage 字段。
/// 仅在请求中设置 `stream_options: {include_usage: true}` 时才会返回。
class SseUsage {
  const SseUsage({
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
    this.cacheReadTokens,
    this.cacheMissTokens,
    this.reasoningTokens,
    this.warnings = const [],
  });

  /// 从 JSON Map 创建
  ///
  /// 兼容 DeepSeek 的两套缓存字段：
  /// - 标准：`prompt_tokens_details.cached_tokens`
  /// - DeepSeek 原生：`prompt_cache_hit_tokens` / `prompt_cache_miss_tokens`
  ///
  /// 两者同时出现且冲突时保留标准字段并在 [warnings] 记录——不静默挑一个
  /// 当作精确值（详情面板/诊断据此标注计量异常）。
  factory SseUsage.fromJson(Map<String, dynamic> json) {
    final promptDetails = json['prompt_tokens_details'];
    final cached = promptDetails is Map<String, dynamic>
        ? promptDetails['cached_tokens'] as int?
        : null;
    final cacheHit = json['prompt_cache_hit_tokens'] as int?;
    final cacheMiss = json['prompt_cache_miss_tokens'] as int?;
    final prompt = json['prompt_tokens'] as int? ??
        ((cacheHit != null && cacheMiss != null) ? cacheHit + cacheMiss : null);
    final completionDetails = json['completion_tokens_details'];
    final reasoning = completionDetails is Map<String, dynamic>
        ? completionDetails['reasoning_tokens'] as int?
        : null;

    final warnings = <String>[];
    if (cached != null && cacheHit != null && cached != cacheHit) {
      warnings.add(
        'cached_tokens($cached) != prompt_cache_hit_tokens($cacheHit)',
      );
    }
    if (prompt != null &&
        cacheHit != null &&
        cacheMiss != null &&
        prompt != cacheHit + cacheMiss) {
      warnings.add(
        'prompt_tokens($prompt) != cache_hit+miss(${cacheHit + cacheMiss})',
      );
    }

    return SseUsage(
      promptTokens: prompt,
      completionTokens: json['completion_tokens'] as int?,
      totalTokens: json['total_tokens'] as int?,
      cacheReadTokens: cached ?? cacheHit,
      cacheMissTokens: cached != null
          ? (prompt != null && cached <= prompt ? prompt - cached : cacheMiss)
          : cacheMiss,
      reasoningTokens: reasoning,
      warnings: warnings,
    );
  }

  /// 提示词 tokens 数
  final int? promptTokens;

  /// 完成 tokens 数
  final int? completionTokens;

  /// 总 tokens 数（prompt + completion）
  final int? totalTokens;

  /// 缓存命中读 token（OpenAI prompt_tokens_details.cached_tokens /
  /// DeepSeek prompt_cache_hit_tokens）
  final int? cacheReadTokens;

  /// 缓存未命中输入 token（DeepSeek prompt_cache_miss_tokens；无则 null）
  final int? cacheMissTokens;

  /// 思考/推理 token（OpenAI completion_tokens_details.reasoning_tokens）
  final int? reasoningTokens;

  /// 计量字段冲突说明（空 = 无异常）
  final List<String> warnings;
}

class StreamError extends SseEvent {
  const StreamError(this.message, {this.code, this.retryAfter});

  final String message;
  final String? code;

  /// Retry-After 冷却时长（：wire 层 AppHttpException 头解析产物；
  /// null=无指示，调用方走本地退避）
  final Duration? retryAfter;
}

/// SSE 5 状态机解析器
/// 解析 OpenAI 兼容格式的 SSE 流，处理交错文本和 tool_calls
///
/// 2026-08-15（v0.3）：tool_calls 累积改用 [StreamingToolCallTracker]
/// per-index 状态机，支持多工具并行/交错分片与中转站容错
/// （缺 index / 缺 id / 一次性 arguments / 无 finish_reason / 截断 JSON）。
/// 文本与工具分片交错时不再报错（部分供应商 assistant 消息可同时携带
/// 文本与工具调用），文本增量照常发出，由调用方自行组装消息。
class SseParser {
  SseParserState _state = SseParserState.idle;

  /// per-index 工具调用追踪器（多工具并行累积）
  StreamingToolCallTracker _toolCallTracker = StreamingToolCallTracker();

  // 是否已发出 StreamEnd（防止双重 StreamEnd）
  bool _streamEnded = false;

  // 最后一个 chunk 的 usage 数据（stream_options.include_usage=true 时返回）
  // 在发出 StreamEnd 时携带，供 Controller 写入消息的 tokensUsed 字段
  SseUsage? _lastUsage;

  // 最后一次收到的 finish_reason（StreamEnd 携带上抛，见 [StreamEnd]）
  String? _lastFinishReason;

  SseParserState get state => _state;

  /// 解析 SSE 原始文本流，输出 SseEvent 流
  Stream<SseEvent> parse(Stream<String> rawStream) async* {
    // 每次 parse 调用重置状态，确保实例可复用
    _reset();
    _streamEnded = false;
    _lastUsage = null;

    final buffer = StringBuffer();

    try {
      await for (final chunk in rawStream) {
        // 审查收官 ：行尾归一化（CRLF/CR → LF）——部分中转端点以
        // CRLFCRLF 分隔事件，不含 LFLF 子串会全部积压到流尾拼成单块，
        // 解析必炸（Gemini CRLF 修复 3d6fca00 只落到底层 RawSseChunkParser，
        // 本解析器自带缓冲切分未受益）。跨 chunk 断行也能正确归一
        // （尾部孤立 CR 转为 LF，与后续 chunk 的 LF 组成边界）
        final normalized =
            chunk.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
        buffer.write(normalized);

        var bufferStr = buffer.toString();
        // 按双换行分割 SSE 事件
        while (bufferStr.contains('\n\n')) {
          final eventEndIndex = bufferStr.indexOf('\n\n');
          final eventBlock = bufferStr.substring(0, eventEndIndex);
          bufferStr = bufferStr.substring(eventEndIndex + 2);

          final events = _parseEventBlock(eventBlock);
          for (final event in events) {
            yield event;
          }
        }
        buffer
          ..clear()
          ..write(bufferStr);
      }

      // 处理缓冲区中剩余内容
      final remaining = buffer.toString();
      if (remaining.trim().isNotEmpty) {
        final events = _parseEventBlock(remaining);
        for (final event in events) {
          yield event;
        }
      }

      // 流结束时，如果有未完成的 tool call，尝试 JSON 修复后完成它
      // （中转站常见：无 finish_reason 也无 [DONE] 直接断流）
      for (final event in _finishPendingToolCalls()) {
        yield event;
      }
    } catch (e) {
      // 流异常时发出 StreamError 而非直接传播。
      // 连接期 HTTP 错误（AppHttpException）按状态码映射语义码
      // （RATE_LIMIT/AUTH/SERVER/BAD_REQUEST）并携带 Retry-After，
      // 不再把状态码信息字符串化丢失；其余保持 STREAM_ERROR。
      yield StreamError(
        'Stream interrupted: $e',
        code: streamErrorCodeOf(e),
        retryAfter: streamErrorRetryAfterOf(e),
      );
    }

    if (!_streamEnded) {
      yield StreamEnd(usage: _lastUsage, finishReason: _lastFinishReason);
    }
  }

  /// 解析单个 SSE 事件块
  List<SseEvent> _parseEventBlock(String eventBlock) {
    final events = <SseEvent>[];
    final lines = eventBlock.split('\n');

    // SSE 规范：多个 data: 行的值应以 \n 拼接为一个完整 payload。
    // 修复 P0-B：原实现每次覆盖只保留最后一个 data 行，导致含换行的
    // JSON payload（如 OpenAI o1 多行 reasoning_content）解析失败。
    final dataBuffer = StringBuffer();
    var hasData = false;

    for (final line in lines) {
      if (line.startsWith('data:')) {
        final chunk = line.substring(5).trim();
        if (hasData) {
          dataBuffer.write('\n');
        }
        dataBuffer.write(chunk);
        hasData = true;
      }
    }

    final data = hasData ? dataBuffer.toString() : null;

    if (data == null || data.isEmpty) return events;

    // [DONE] 信号
    if (data == '[DONE]') {
      // 中转站容错：未收到 finish_reason=tool_calls 也要完成累积中的调用
      events
        ..addAll(_finishPendingToolCalls())
        ..add(StreamEnd(usage: _lastUsage, finishReason: _lastFinishReason));
      _streamEnded = true;
      _resetToolCallState();
      return events;
    }

    // 解析 JSON
    try {
      final json = jsonDecode(data) as Map<String, dynamic>;
      events.addAll(_handleJsonChunk(json));
    } catch (e) {
      // FORMAT_ERROR（2026-10-15 批 D 归一）：JSON 解析失败/HTML 挑战页
      // 伪装 200 同走此路——立即重试通道（免费站典型病）
      events.add(
        StreamError('Failed to parse SSE data: $e', code: 'FORMAT_ERROR'),
      );
    }

    return events;
  }

  /// 处理 JSON chunk
  List<SseEvent> _handleJsonChunk(Map<String, dynamic> json) {
    final events = <SseEvent>[];

    // 优先检测 error 字段（DOC-12 §5.4.1 P0 缺口）
    // 部分供应商（如 DeepSeek、OpenRouter、NVIDIA NIM）在流式响应中遇到错误时，
    // 不会使用 HTTP 状态码，而是返回 200 + 含 error 字段的 JSON chunk。
    // 若不检测，会被当作普通 chunk 处理（choices 为空），导致错误被静默吞掉。
    //
    // 2026-07-29 修复：供应商 error 字段类型不统一，message/code/type 可能是
    // 任意类型（部分供应商 code 用 int 如 500/429，而非字符串 "500"）。
    // 原代码 `as String?` 强转 int 会抛 _TypeError，导致原始错误信息被外层
    // try/catch 包装为 "Failed to parse SSE data: ..."，掩盖供应商真实错误。
    // 改用 `?.toString()` 容错转换，并输出原始 error JSON 便于诊断。
    final errorJson = json['error'];
    if (errorJson != null) {
      String message;
      String? code;
      if (errorJson is Map<String, dynamic>) {
        final rawMessage = errorJson['message'];
        message = rawMessage is String && rawMessage.isNotEmpty
            ? rawMessage
            : 'Unknown stream error';
        final rawCode = errorJson['code'] ?? errorJson['type'];
        code = rawCode?.toString();
        // 输出原始 error JSON 便于诊断供应商真实错误（限流/超时/参数等），
        // warn 级别确保在默认日志配置下可见。
        const Logger('SseParser').warn(
          'SSE error chunk received from upstream',
          detail: 'rawErrorJson=${jsonEncode(errorJson)}, '
              'parsedMessage=$message, parsedCode=$code',
        );
      } else {
        message = errorJson.toString();
        const Logger('SseParser').warn(
          'SSE error chunk received (non-map)',
          detail: 'rawError=$message',
        );
      }
      events.add(StreamError(message, code: code));
      return events;
    }

    // 提取 usage 数据（stream_options.include_usage=true 时，最后一个 chunk 会包含 usage）
    // 此 chunk 的 choices 通常为空数组
    final usageJson = json['usage'] as Map<String, dynamic>?;
    if (usageJson != null) {
      _lastUsage = SseUsage.fromJson(usageJson);
    }

    final choices = json['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) return events;

    final choice = choices[0] as Map<String, dynamic>;
    final delta = choice['delta'] as Map<String, dynamic>?;
    if (delta == null) return events;

    // 2026-07-29 修复：同 content，finish_reason 也用 `is String` 检查容错。
    // OpenAI 协议规定为字符串，但个别供应商可能返回 null 或非字符串。
    final rawFinishReason = choice['finish_reason'];
    final finishReason = rawFinishReason is String ? rawFinishReason : null;
    if (finishReason != null) {
      _lastFinishReason = finishReason;
    }

    // 处理文本内容
    // 2026-07-29 修复：部分供应商在结束帧可能返回非字符串 content
    // （如 null/false/0），原 `as String?` 强转会抛 _TypeError。改用
    // `is String` 类型检查，仅接受字符串，其他类型视为无内容（与 null 等价）。
    //
    // 2026-08-15（v0.3）：工具分片累积中收到文本不再报错——
    // assistant 消息同时携带文本与工具调用是合法形态（Anthropic 常见、
    // 部分中转的 OpenAI 兼容流也会交错），文本照常发出。
    final rawContent = delta['content'];
    final content = rawContent is String ? rawContent : null;
    if (content != null && content.isNotEmpty) {
      if (_state == SseParserState.toolCallDetected ||
          _state == SseParserState.accumulatingArgs) {
        _state = SseParserState.accumulatingArgs;
      } else {
        _state = SseParserState.streamingText;
      }
      events.add(TextDelta(content));
    }

    // 处理推理/思考内容
    //
    // 兼容两种 OpenAI 兼容格式：
    // - DeepSeek-R1 / 部分供应商：`delta.reasoning_content`
    // - OpenAI o-series / OpenRouter：`delta.reasoning`
    //
    // 2026-07-29 修复：同 content，reasoning_content 也用 `is String` 检查
    // 容错非字符串类型（部分供应商可能返回 null/false/0 表示无思考内容）。
    final rawReasoningContent = delta['reasoning_content'];
    final reasoningContent =
        rawReasoningContent is String ? rawReasoningContent : null;
    if (reasoningContent != null && reasoningContent.isNotEmpty) {
      events.add(ThinkingDelta(reasoningContent));
    }
    // 2026-07-29 修复：同 reasoning_content，reasoning 也用 `is String` 检查。
    final rawReasoning = delta['reasoning'];
    final reasoning = rawReasoning is String ? rawReasoning : null;
    if (reasoning != null && reasoning.isNotEmpty) {
      events.add(ThinkingDelta(reasoning));
    }

    // 处理 tool_calls（per-index 多工具并行累积）
    final toolCalls = delta['tool_calls'] as List<dynamic>?;
    if (toolCalls != null) {
      for (final tc in toolCalls) {
        if (tc is! Map<String, dynamic>) continue;
        final function = tc['function'] as Map<String, dynamic>?;
        final fragmentEvents = _toolCallTracker.handleFragment(
          index: tc['index'] as int?,
          id: tc['id'] as String?,
          name: function?['name'] as String?,
          argsDelta: function?['arguments'] as String?,
        );
        for (final event in fragmentEvents) {
          switch (event) {
            case StreamingToolCallStart():
              events.add(ToolCallStart(event.callId, event.name));
              _state = SseParserState.toolCallDetected;
            case StreamingToolCallArgsDelta():
              events.add(ToolCallArgs(event.callId, event.delta));
              _state = SseParserState.accumulatingArgs;
            case StreamingToolCallFinish():
              // finishAll 之外的完成不会从这里出现（tracker 只在 finishAll 完成调用）
              events.add(
                ToolCallComplete(event.callId, event.name, event.arguments),
              );
          }
        }
      }
    }

    // finish_reason 处理
    if (finishReason == 'tool_calls') {
      // 完成全部累积中的调用（部分供应商不带此标记，见 [DONE]/流结束兜底）
      final hadTracks = _toolCallTracker.hasAnyTrack;
      events.addAll(_finishPendingToolCalls());
      _resetToolCallState();
      if (hadTracks) {
        _state = SseParserState.executingTool;
      } else {
        _state = SseParserState.idle;
      }
    } else if (finishReason == 'stop') {
      // 中转站容错：stop 早于 tool_calls 标记到达时（vLLM/SGLang 实测变体），
      // 仍完成累积中的调用而非报错丢弃——loop 由"是否收到 tool_calls"驱动，
      // 不信任 finish_reason（设计报告 §4.3）。
      events.addAll(_finishPendingToolCalls());
      _resetToolCallState();
      _state = SseParserState.idle;
    } else if (finishReason != null) {
      // length / content_filter 等：同样完成累积中的调用，避免丢失
      events.addAll(_finishPendingToolCalls());
      _resetToolCallState();
      _state = SseParserState.idle;
    }

    return events;
  }

  /// 完成全部累积中的 tool call（带 JSON 修复），返回完成事件列表
  List<SseEvent> _finishPendingToolCalls() {
    if (!_toolCallTracker.hasPending) return const [];
    final events = <SseEvent>[];
    for (final finish in _toolCallTracker.finishAll()) {
      events.add(
        ToolCallComplete(finish.callId, finish.name, finish.arguments),
      );
    }
    return events;
  }

  void _resetToolCallState() {
    _toolCallTracker = StreamingToolCallTracker();
  }

  void _reset() {
    _state = SseParserState.idle;
    _lastFinishReason = null;
    _resetToolCallState();
    // Note: _streamEnded is NOT reset here — it must persist across _reset()
    // to prevent duplicate StreamEnd at the end of parse()
  }
}
