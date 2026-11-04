import 'dart:async';
import 'dart:convert';

import 'package:lmstory/core/network/retry_after.dart';
import 'package:lmstory/core/network/sse/raw_sse_chunk_parser.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// OpenAI Responses API 流式解析器
///
/// 与 Chat Completions 的差异：
/// - 事件为 `event:` + `data:` 双行（CC 仅 `data:` 行），复用底层
///   RawSseChunkParser 的 event 字段提取
/// - 无 `[DONE]` 哨兵，终止信号是 `response.completed` 事件（部分中转
///   可能追加 DONE 哨兵行，做兼容容错）
/// - 文本增量在 `response.output_text.delta` 的 `delta` 字段
/// - 工具调用按 output item 组织：`response.output_item.added`
///   （item.type=function_call，含 call_id/name）→
///   `response.function_call_arguments.delta|done`（按 item_id 关联）
/// - usage 恒随 `response.completed` 返回（Responses 无
///   stream_options.include_usage），字段为 input_tokens/output_tokens
///   （与 CC 的 prompt_tokens/completion_tokens 命名不同）
///
/// 实现依据：OpenAI Responses API 官方 streaming events 参考（2026-11-02 复核）。
class ResponsesSseParser {
  ResponsesSseParser({RawSseChunkParser? rawParser})
      : _rawParser = rawParser ?? RawSseChunkParser();

  final RawSseChunkParser _rawParser;

  /// 进行中的 function_call 追踪（item_id → 状态）
  ///
  /// Responses 的参数增量按 item_id 关联，call_id/name 在
  /// output_item.added 事件上；done 事件携带完整 arguments 字符串。
  final Map<String, _FunctionCallTrack> _tracksById = {};

  /// 已发出 ToolCallComplete 的 item_id 集合（防 done 后 output_item.done 重复完成）
  final Set<String> _completedIds = {};

  bool _streamEnded = false;

  Stream<LlmStreamEvent> parse(Stream<String> rawStream) async* {
    _tracksById.clear();
    _completedIds.clear();
    _streamEnded = false;

    try {
      await for (final chunk in _rawParser.parse(rawStream)) {
        final data = chunk.data;
        if (data.isEmpty) continue;

        // 无 [DONE] 哨兵，但部分中转会追加——兼容
        if (data == '[DONE]') {
          if (!_streamEnded) {
            _streamEnded = true;
            yield* _finishPendingTracks();
            yield const LlmStreamDone();
          }
          continue;
        }

        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          yield* _handleEvent(chunk.event, json);
        } catch (e) {
          yield LlmStreamError(
            'Failed to parse Responses SSE data: $e',
            code: 'FORMAT_ERROR',
          );
        }
      }
    } catch (e) {
      // 连接期 HTTP 错误按状态码映射语义码并携带 Retry-After（同 sse_parser）
      yield LlmStreamError(
        'Responses stream interrupted: $e',
        code: streamErrorCodeOf(e),
        retryAfter: streamErrorRetryAfterOf(e),
      );
    }

    if (!_streamEnded) {
      // 流自然关闭（无 completed 事件，中转断流等）——完成累积中的工具调用
      // 并兜底 Done，与 CC 解析器的断流容错对齐
      _streamEnded = true;
      yield* _finishPendingTracks();
      yield const LlmStreamDone();
    }
  }

  Stream<LlmStreamEvent> _handleEvent(
    String? event,
    Map<String, dynamic> json,
  ) async* {
    // 流内 error 事件（与 CC 的 200+error chunk 同病，NIM/中转常见）
    final errorJson = json['error'];
    if (errorJson != null) {
      _streamEnded = true;
      yield _toStreamError(errorJson);
      return;
    }

    switch (event ?? json['type'] as String?) {
      case 'response.output_text.delta':
        final delta = json['delta'] as String?;
        if (delta != null && delta.isNotEmpty) {
          yield LlmTextDelta(delta);
        }

      case 'response.reasoning_summary_text.delta':
        // 推理摘要增量：映射到思考增量（与 CC 的 reasoning_content 展示对齐）
        final delta = json['delta'] as String?;
        if (delta != null && delta.isNotEmpty) {
          yield LlmThinkingDelta(delta);
        }

      case 'response.output_item.added':
        final item = json['item'];
        if (item is Map<String, dynamic> && item['type'] == 'function_call') {
          final itemId = (item['id'] ?? item['call_id'] ?? '') as String;
          final callId = (item['call_id'] ?? item['id'] ?? '') as String;
          final name = item['name'] as String? ?? '';
          _tracksById[itemId] = _FunctionCallTrack(callId: callId, name: name);
          yield LlmToolCallStart(callId, name);
        }

      case 'response.function_call_arguments.delta':
        final itemId = json['item_id'] as String? ?? '';
        final delta = json['delta'] as String?;
        final track = _tracksById[itemId];
        if (track != null && delta != null && delta.isNotEmpty) {
          track.arguments.write(delta);
          yield LlmToolCallArgs(track.callId, delta);
        }

      case 'response.function_call_arguments.done':
        final itemId = json['item_id'] as String? ?? '';
        final track = _tracksById[itemId];
        if (track != null && !_completedIds.contains(itemId)) {
          // done 事件携带完整 arguments 字符串（不依赖增量累积）
          final full = json['arguments'] as String?;
          if (full != null && full.isNotEmpty) {
            track.arguments
              ..clear()
              ..write(full);
          }
          _completedIds.add(itemId);
          yield _completeOf(track);
        }

      case 'response.output_item.done':
        // done 事件兜底：部分实现不发 function_call_arguments.done
        final item = json['item'];
        if (item is Map<String, dynamic> && item['type'] == 'function_call') {
          final itemId = (item['id'] ?? item['call_id'] ?? '') as String;
          final track = _tracksById[itemId];
          if (track != null && !_completedIds.contains(itemId)) {
            final full = item['arguments'] as String?;
            if (full != null && full.isNotEmpty) {
              track.arguments
                ..clear()
                ..write(full);
            }
            _completedIds.add(itemId);
            yield _completeOf(track);
          }
        }

      case 'response.completed':
        if (!_streamEnded) {
          _streamEnded = true;
          yield* _finishPendingTracks();
          yield LlmStreamDone(
            usage: _parseUsage(json['response']),
            finishReason: _finishReasonOf(json['response']),
          );
        }

      case 'response.incomplete':
        // 输出预算耗尽或内容过滤导致的不完整——按截断语义收尾
        if (!_streamEnded) {
          _streamEnded = true;
          yield* _finishPendingTracks();
          yield LlmStreamDone(
            usage: _parseUsage(json['response']),
            finishReason: _finishReasonOf(json['response']) ?? 'length',
          );
        }

      case 'response.failed':
        if (!_streamEnded) {
          _streamEnded = true;
          final response = json['response'];
          final error =
              response is Map<String, dynamic> ? response['error'] : null;
          yield error != null
              ? _toStreamError(error)
              : const LlmStreamError(
                  'Responses request failed',
                  code: 'STREAM_ERROR',
                );
        }

      case 'error':
        if (!_streamEnded) {
          _streamEnded = true;
          yield _toStreamError(json);
        }

      // response.created / response.in_progress / response.output_item.added(非工具)
      // / response.output_text.done / response.output_item.done(非工具) 等
      // 状态事件不产生用户可见事件，忽略
      default:
        break;
    }
  }

  /// 完成全部仍在累积的工具调用（断流/兜底路径，带容错解析）
  Stream<LlmStreamEvent> _finishPendingTracks() async* {
    for (final entry in _tracksById.entries) {
      if (_completedIds.contains(entry.key)) continue;
      _completedIds.add(entry.key);
      yield _completeOf(entry.value);
    }
  }

  LlmToolCallComplete _completeOf(_FunctionCallTrack track) {
    return LlmToolCallComplete(
      toolCallId: track.callId,
      name: track.name,
      arguments: _decodeArgs(track.arguments.toString()),
    );
  }

  static Map<String, dynamic> _decodeArgs(String raw) {
    if (raw.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static LlmStreamError _toStreamError(Object? errorJson) {
    if (errorJson is Map<String, dynamic>) {
      final message = errorJson['message'];
      final code = errorJson['code'] ?? errorJson['type'];
      return LlmStreamError(
        message is String && message.isNotEmpty
            ? message
            : 'Unknown Responses stream error',
        code: code?.toString(),
      );
    }
    return LlmStreamError(
      errorJson?.toString() ?? 'Unknown Responses stream error',
      code: 'STREAM_ERROR',
    );
  }

  /// Responses usage → LlmUsage（命名与 CC 不同：input/output tokens）
  static LlmUsage? _parseUsage(Object? response) {
    if (response is! Map<String, dynamic>) return null;
    final usage = response['usage'];
    if (usage is! Map<String, dynamic>) return null;
    final inputDetails = usage['input_tokens_details'];
    return LlmUsage(
      promptTokens: usage['input_tokens'] as int?,
      completionTokens: usage['output_tokens'] as int?,
      totalTokens: usage['total_tokens'] as int?,
      cacheReadTokens: inputDetails is Map<String, dynamic>
          ? inputDetails['cached_tokens'] as int?
          : null,
    );
  }

  /// response.status/incomplete_details → CC 风格 finishReason（消费方词表统一）
  static String? _finishReasonOf(Object? response) {
    if (response is! Map<String, dynamic>) return null;
    final status = response['status'];
    if (status == 'incomplete') {
      final details = response['incomplete_details'];
      final reason =
          details is Map<String, dynamic> ? details['reason'] as String? : null;
      // 归一到 CC 词表：max_output_tokens 即 length（截断诊断消费方词表统一），
      // content_filter 等其余原样透传（与 CC 同名）
      if (reason == 'max_output_tokens') return 'length';
      return reason ?? 'length';
    }
    return null;
  }
}

/// 单个 function_call 的累积状态
class _FunctionCallTrack {
  _FunctionCallTrack({required this.callId, required this.name});

  final String callId;
  final String name;
  final StringBuffer arguments = StringBuffer();
}
