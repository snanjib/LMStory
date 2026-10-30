import 'dart:async';
import 'dart:convert';

import 'package:lmstory/core/network/retry_after.dart';
import 'package:lmstory/core/network/sse/raw_sse_chunk_parser.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// Anthropic SSE 事件类型（DOC-12 §6.3）
///
/// Anthropic 流式响应使用 6 种顶层事件类型，每种携带不同 data payload。
/// 与 OpenAI 兼容协议的差异：
/// - 无 `data: [DONE]` 结束标记，靠 `message_stop` 事件判断流结束
/// - 增量数据嵌套在 `delta` 字段内，按 `delta.type` 区分 4 种 delta
/// - 工具调用参数通过 `input_json_delta.partial_json` 分片累积
/// - thinking 块含 `signature_delta`，需完整累积用于多轮回传
enum AnthropicEventType {
  messageStart,
  contentBlockStart,
  contentBlockDelta,
  contentBlockStop,
  messageDelta,
  messageStop,
  error,
  unknown;

  static AnthropicEventType fromString(String? value) {
    return switch (value) {
      'message_start' => messageStart,
      'content_block_start' => contentBlockStart,
      'content_block_delta' => contentBlockDelta,
      'content_block_stop' => contentBlockStop,
      'message_delta' => messageDelta,
      'message_stop' => messageStop,
      'error' => error,
      _ => unknown,
    };
  }
}

/// Anthropic content block 类型
///
/// 一个 message 由多个 content block 组成，每个 block 类型不同：
/// - [text]：普通文本回复
/// - [thinking]：思考内容（含 signature，跨轮回传必需）
/// - [toolUse]：工具调用（含 id/name/input）
enum AnthropicBlockType {
  text,
  thinking,
  toolUse,
  unknown;

  static AnthropicBlockType fromString(String? value) {
    return switch (value) {
      'text' => text,
      'thinking' => thinking,
      'tool_use' => toolUse,
      _ => unknown,
    };
  }
}

/// Anthropic content_block_delta 的 delta 子类型（4 种）
///
/// - [textDelta]：文本增量 `{"type":"text_delta","text":"..."}`
/// - [inputJsonDelta]：工具参数 JSON 增量 `{"type":"input_json_delta","partial_json":"..."}`
/// - [thinkingDelta]：思考内容增量 `{"type":"thinking_delta","thinking":"..."}`
/// - [signatureDelta]：思考签名增量 `{"type":"signature_delta","signature":"..."}`
enum AnthropicDeltaType {
  textDelta,
  inputJsonDelta,
  thinkingDelta,
  signatureDelta,
  unknown;

  static AnthropicDeltaType fromString(String? value) {
    return switch (value) {
      'text_delta' => textDelta,
      'input_json_delta' => inputJsonDelta,
      'thinking_delta' => thinkingDelta,
      'signature_delta' => signatureDelta,
      _ => unknown,
    };
  }
}

/// Anthropic 流式解析过程中维护的单个 content block 状态
class _ContentBlockState {
  _ContentBlockState({
    required this.index,
    required this.type,
    this.toolUseId,
    this.toolName,
  });

  final int index;
  final AnthropicBlockType type;

  /// 工具调用 ID（仅 [AnthropicBlockType.toolUse] 使用）
  String? toolUseId;

  /// 工具名（仅 [AnthropicBlockType.toolUse] 使用）
  String? toolName;

  /// 累积的工具参数 JSON 分片（toolUse 类型，在 content_block_stop 时解析）
  final StringBuffer _argsBuffer = StringBuffer();

  /// 累积的思考内容（thinking 类型）
  final StringBuffer _thinkingBuffer = StringBuffer();

  /// 累积的思考签名（thinking 类型，signature_delta 分片累积）
  final StringBuffer _signatureBuffer = StringBuffer();

  void appendArgs(String chunk) => _argsBuffer.write(chunk);

  void appendThinking(String chunk) => _thinkingBuffer.write(chunk);

  void appendSignature(String chunk) => _signatureBuffer.write(chunk);

  String get thinkingText => _thinkingBuffer.toString();

  String get signature => _signatureBuffer.toString();

  String get rawArgs => _argsBuffer.toString();
}

/// Anthropic SSE 解析器（DOC-12 §6.3 + §5.4.4）
///
/// 状态机设计：
/// - 维护 `Map<int, _ContentBlockState>` 按 index 跟踪每个 content block
/// - `content_block_start` 时创建新 block 状态
/// - `content_block_delta` 时按 delta.type 累积到对应 buffer
/// - `content_block_stop` 时根据 block 类型发出对应完成事件：
///   - text：无特殊处理（文本已在每个 delta 发出）
///   - thinking：发出 [LlmThinkingBlockComplete]（含完整 thinking + signature）
///   - tool_use：发出 [LlmToolCallComplete]（解析累积的 args JSON）
/// - `message_stop` 时发出 [LlmStreamDone]
///
/// 关键差异处理：
/// 1. system 字段已在适配器层提取到顶层，解析器只处理 messages
/// 2. 工具调用参数是 `partial_json` 字符串分片，需累积后整体解析
/// 3. thinking signature 必须完整累积，不能丢失任何分片
/// 4. 无 `[DONE]` 标记，靠 `message_stop` 事件结束流
///
/// 实现依据：DOC-12 §6.3 + Anthropic 官方文档（2026-07-24 调研）。
class AnthropicSseParser {
  AnthropicSseParser({RawSseChunkParser? rawParser})
      : _rawParser = rawParser ?? RawSseChunkParser();

  final RawSseChunkParser _rawParser;

  /// 按 index 跟踪所有活跃的 content block
  final Map<int, _ContentBlockState> _blocks = {};

  /// 流是否已发出 message_stop（防止重复发出 LlmStreamDone）
  bool _streamStopped = false;

  /// message_start 事件携带的 input_tokens（首事件 usage）
  int? _inputTokens;

  /// message_delta 事件携带的 output_tokens（末尾 usage）
  int? _outputTokens;

  /// Anthropic 缓存计量（message_start usage 携带）
  int? _cacheReadTokens;
  int? _cacheCreationTokens;

  /// message_delta 携带的 stop_reason（XC-2：映射后随 LlmStreamDone 上抛）
  String? _finishReason;

  /// Anthropic stop_reason → 统一 finishReason（OpenAI 词表）
  ///
  /// 消费方（截断/安全终止诊断，如 agent_runner 的 `finishReason == 'length'`）
  /// 按 OpenAI finish_reason 词表判断，Anthropic 原生 stop_reason 需映射后
  /// 上抛；未识别的值原样透传（向前兼容服务端新增枚举）。
  static String? mapStopReasonToFinishReason(String? stopReason) {
    if (stopReason == null) return null;
    return switch (stopReason) {
      'end_turn' || 'stop_sequence' => 'stop',
      'max_tokens' => 'length',
      'tool_use' => 'tool_calls',
      'refusal' => 'content_filter',
      _ => stopReason,
    };
  }

  /// Anthropic 流中 error 事件的 error.type → wire 层语义错误码
  ///
  /// 与 [semanticCodeForStatus] 的状态码语义对齐（RATE_LIMIT/AUTH/SERVER/
  /// BAD_REQUEST），未识别的类型原样透传（保留供应商诊断信息）。
  static String? _semanticCodeForErrorType(String? type) {
    if (type == null) return null;
    return switch (type) {
      'rate_limit_error' => 'RATE_LIMIT',
      'authentication_error' || 'permission_error' => 'AUTH',
      'overloaded_error' || 'api_error' => 'SERVER',
      'invalid_request_error' ||
      'not_found_error' ||
      'request_too_large' =>
        'BAD_REQUEST',
      _ => type,
    };
  }

  /// 解析原始 SSE 字符串流为统一事件流
  ///
  /// 输入为 HTTP 响应 body 的字符串流（可能跨 chunk 切分），
  /// 输出为 [LlmStreamEvent] 统一事件（调用方零感知 Anthropic 协议差异）。
  ///
  /// 实例可复用：每次调用 [parse] 会重置内部状态。
  Stream<LlmStreamEvent> parse(Stream<String> rawStream) async* {
    // 重置状态（实例复用安全）
    _blocks.clear();
    _streamStopped = false;
    _inputTokens = null;
    _outputTokens = null;
    _cacheReadTokens = null;
    _cacheCreationTokens = null;
    _finishReason = null;

    try {
      await for (final chunk in _rawParser.parse(rawStream)) {
        final event = chunk.event;
        final data = chunk.data;

        // Anthropic 事件类型由 event 字段决定，data 中也有 type 字段冗余
        final eventType = AnthropicEventType.fromString(event);

        if (eventType == AnthropicEventType.unknown) {
          // 无 event 字段时尝试从 data.type 推断
          final dataType = _extractDataType(data);
          if (dataType != null) {
            final inferred = AnthropicEventType.fromString(dataType);
            if (inferred != AnthropicEventType.unknown) {
              yield* _handleEvent(inferred, data);
              continue;
            }
          }
          // 忽略未知事件（如 ping）；error 事件已由枚举显式处理（XC-1）
          continue;
        }

        yield* _handleEvent(eventType, data);
      }
    } catch (e) {
      // 连接期 HTTP 错误按状态码映射语义码并携带 Retry-After（同 sse_parser）
      yield LlmStreamError(
        'Anthropic stream interrupted: $e',
        code: streamErrorCodeOf(e),
        retryAfter: streamErrorRetryAfterOf(e),
      );
    }

    // 流自然结束时若未收到 message_stop，仍发出 LlmStreamDone 兜底
    // （error 事件已置 _streamStopped，失败流不会被兜底 Done 当成功收尾）
    if (!_streamStopped) {
      yield LlmStreamDone(usage: _buildUsage(), finishReason: _finishReason);
    }
  }

  Stream<LlmStreamEvent> _handleEvent(
    AnthropicEventType eventType,
    String data,
  ) async* {
    Map<String, dynamic> json;
    try {
      json = jsonDecode(data) as Map<String, dynamic>;
    } catch (e) {
      yield LlmStreamError(
        'Failed to parse Anthropic SSE data: $e',
        code: 'FORMAT_ERROR',
      );
      return;
    }

    switch (eventType) {
      case AnthropicEventType.messageStart:
        // message_start 携带首事件 usage（input_tokens）
        final message = json['message'] as Map<String, dynamic>?;
        if (message != null) {
          final usage = message['usage'] as Map<String, dynamic>?;
          if (usage != null) {
            _inputTokens = usage['input_tokens'] as int?;
            _cacheReadTokens = usage['cache_read_input_tokens'] as int?;
            _cacheCreationTokens = usage['cache_creation_input_tokens'] as int?;
          }
        }
        return;

      case AnthropicEventType.contentBlockStart:
        final index = json['index'] as int? ?? 0;
        final contentBlock =
            json['content_block'] as Map<String, dynamic>? ?? {};
        final blockType = AnthropicBlockType.fromString(
          contentBlock['type'] as String?,
        );

        final block = _ContentBlockState(
          index: index,
          type: blockType,
          toolUseId: contentBlock['id'] as String?,
          toolName: contentBlock['name'] as String?,
        );
        _blocks[index] = block;

        // tool_use block 开始时发出 LlmToolCallStart
        if (blockType == AnthropicBlockType.toolUse) {
          yield LlmToolCallStart(
            block.toolUseId ?? '',
            block.toolName ?? '',
          );
        }
        return;

      case AnthropicEventType.contentBlockDelta:
        final index = json['index'] as int? ?? 0;
        final delta = json['delta'] as Map<String, dynamic>? ?? {};
        final deltaType = AnthropicDeltaType.fromString(
          delta['type'] as String?,
        );
        final block = _blocks[index];
        if (block == null) return;

        switch (deltaType) {
          case AnthropicDeltaType.textDelta:
            final text = delta['text'] as String? ?? '';
            if (text.isNotEmpty) {
              yield LlmTextDelta(text);
            }
          case AnthropicDeltaType.inputJsonDelta:
            // 工具参数分片累积，同时发出 LlmToolCallArgs 供 UI 实时展示
            final partialJson = delta['partial_json'] as String? ?? '';
            if (partialJson.isNotEmpty) {
              block.appendArgs(partialJson);
              yield LlmToolCallArgs(block.toolUseId ?? '', partialJson);
            }
          case AnthropicDeltaType.thinkingDelta:
            // 思考内容累积，发出 LlmThinkingDelta 供 UI 实时展示
            final thinking = delta['thinking'] as String? ?? '';
            if (thinking.isNotEmpty) {
              block.appendThinking(thinking);
              yield LlmThinkingDelta(thinking);
            }
          case AnthropicDeltaType.signatureDelta:
            // signature 分片累积，不发出独立事件（在 content_block_stop 时
            // 通过 LlmThinkingBlockComplete 一次性携带完整 signature）
            final signature = delta['signature'] as String? ?? '';
            if (signature.isNotEmpty) {
              block.appendSignature(signature);
            }
          case AnthropicDeltaType.unknown:
            // 忽略未知 delta 类型（向前兼容）
            return;
        }
        return;

      case AnthropicEventType.contentBlockStop:
        final index = json['index'] as int? ?? 0;
        final block = _blocks.remove(index);
        if (block == null) return;

        switch (block.type) {
          case AnthropicBlockType.text:
            // 文本已在每个 text_delta 事件中发出，无需额外处理
            return;
          case AnthropicBlockType.thinking:
            // thinking block 结束时发出 LlmThinkingBlockComplete
            // 携带完整 thinking 文本 + signature（多轮回传必需）
            yield LlmThinkingBlockComplete(
              thinking: block.thinkingText,
              signature: block.signature,
            );
          case AnthropicBlockType.toolUse:
            // tool_use block 结束时解析完整参数，发出 LlmToolCallComplete
            final arguments = _parseArgs(block.rawArgs);
            yield LlmToolCallComplete(
              toolCallId: block.toolUseId ?? '',
              name: block.toolName ?? '',
              arguments: arguments,
            );
          case AnthropicBlockType.unknown:
            return;
        }
        return;

      case AnthropicEventType.messageDelta:
        // message_delta 携带 stop_reason 和累计 output_tokens
        final usage = json['usage'] as Map<String, dynamic>?;
        if (usage != null) {
          _outputTokens = usage['output_tokens'] as int?;
        }
        // XC-2：stop_reason 映射为统一 finishReason，随 LlmStreamDone 上抛
        // （截断诊断对 Anthropic 端点生效）
        final delta = json['delta'] as Map<String, dynamic>?;
        final stopReason = delta?['stop_reason'] as String?;
        if (stopReason != null) {
          _finishReason = mapStopReasonToFinishReason(stopReason);
        }
        return;

      case AnthropicEventType.messageStop:
        _streamStopped = true;
        yield LlmStreamDone(
          usage: _buildUsage(),
          finishReason: _finishReason,
        );
        return;

      case AnthropicEventType.error:
        // Anthropic 官方协议允许在 200 流中发 error 事件（如 overloaded_error）
        // ——不能只依赖 HTTP 状态码。必须上抛 LlmStreamError 并抑制兜底
        // LlmStreamDone，否则流中途失败被当成功截断落库（XC-1）。
        final errorJson = json['error'];
        String message;
        String? code;
        if (errorJson is Map<String, dynamic>) {
          message =
              (errorJson['message'] as String?) ?? 'Anthropic stream error';
          code = _semanticCodeForErrorType(errorJson['type'] as String?);
        } else {
          message = errorJson?.toString() ?? 'Anthropic stream error';
        }
        _streamStopped = true;
        yield LlmStreamError(message, code: code);
        return;

      case AnthropicEventType.unknown:
        return;
    }
  }

  /// 从 data JSON 中提取 type 字段（用于无 event 字段时推断）
  String? _extractDataType(String data) {
    try {
      final json = jsonDecode(data) as Map<String, dynamic>;
      return json['type'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// 解析工具调用参数 JSON（容错：解析失败返回空 Map）
  Map<String, dynamic> _parseArgs(String rawArgs) {
    if (rawArgs.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(rawArgs);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
    } catch (_) {
      // 容错：参数 JSON 非法时返回空 Map，由调用方决定是否重试
    }
    return <String, dynamic>{};
  }

  /// 构建 usage 对象（input_tokens 来自 message_start，output_tokens 来自 message_delta）
  ///
  /// Anthropic 的 usage 拆分在两个事件中返回，与 OpenAI 的单次返回不同。
  LlmUsage? _buildUsage() {
    if (_inputTokens == null && _outputTokens == null) return null;
    final input = _inputTokens ?? 0;
    final output = _outputTokens ?? 0;
    return LlmUsage(
      promptTokens: input,
      completionTokens: output,
      totalTokens: input + output,
      cacheReadTokens: _cacheReadTokens,
      cacheCreationTokens: _cacheCreationTokens,
    );
  }
}
