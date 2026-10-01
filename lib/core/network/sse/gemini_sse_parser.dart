import 'dart:async';
import 'dart:convert';

import 'package:lmstory/core/network/retry_after.dart';
import 'package:lmstory/core/network/sse/raw_sse_chunk_parser.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// Gemini SSE 解析器（DOC-12 §6.2 + §5.4.5）
///
/// Gemini 流式响应与 OpenAI/Anthropic 差异较大：
/// - 无 `event:` 字段，所有事件都是 `data: {json}`
/// - 无 `[DONE]` 结束标记，靠流自然关闭判断结束
/// - 每个 chunk 是一个完整的 `GenerateContentResponse`，包含 `candidates` 数组
/// - 文本增量在 `candidates[0].content.parts[].text`
/// - 推理内容通过 `parts[].thought: true` 标识（Gemini 2.5+ 特性）
/// - 工具调用 `functionCall` 完整返回（不增量），含 name + args 对象
/// - usage 在最后一个 chunk 的 `usageMetadata` 字段
///
/// 状态机设计：
/// - 无复杂状态机，每个 chunk 独立解析
/// - 维护 `_toolCallIds` 去重，避免同一 functionCall 在多个 chunk 中重复发出
///   （Gemini 偶尔会在后续 chunk 中重复携带已完成的 functionCall）
///
/// 实现依据：DOC-12 §6.2 + §5.4.5 + Google Gemini 官方文档（2026-07-24 调研）。
class GeminiSseParser {
  GeminiSseParser({RawSseChunkParser? rawParser})
      : _rawParser = rawParser ?? RawSseChunkParser();

  final RawSseChunkParser _rawParser;

  /// 已发出的工具调用去重 key 集合
  ///
  /// Gemini 的 functionCall 没有 id 字段。2026-08-15（v0.3）：
  /// 去重 key 从"工具名"改为"工具名 + 参数 JSON"——同一 functionCall 在
  /// 后续 chunk 重复携带仍被去重，但同名不同参数的并行/连续调用不再被
  /// 误丢弃（Agent Loop 同名多次调用是常态）。
  final Set<String> _emittedCallKeys = {};

  /// 同名工具的第 N 次出现计数（用于生成本地唯一 id：`gemini_<name>__<n>`）
  final Map<String, int> _nameCallCounts = {};

  /// 流是否已发出 LlmStreamDone（防止重复）
  bool _streamEnded = false;

  /// 缓存的 usage 数据（最后随 LlmStreamDone 发出）
  LlmUsage? _lastUsage;

  /// 缓存的 finishReason（：随 LlmStreamDone 上抛——STOP/MAX_TOKENS/
  /// SAFETY 等，runner 的 length 截断诊断据此对 Gemini 生效）
  String? _lastFinishReason;

  /// 解析原始 SSE 字符串流为统一事件流
  ///
  /// 实例可复用：每次调用 [parse] 会重置内部状态。
  /// Gemini 错误 status/code → 语义码（体系：限流/鉴权/服务端）
  static String? _semanticCodeOf(String? raw) {
    switch (raw) {
      case 'RESOURCE_EXHAUSTED':
      case '429':
        return 'RATE_LIMIT';
      case 'UNAUTHENTICATED':
      case 'PERMISSION_DENIED':
      case '401':
      case '403':
        return 'AUTH';
      case 'INTERNAL':
      case 'UNAVAILABLE':
      case '500':
      case '502':
      case '503':
      case '504':
        return 'SERVER';
      default:
        return raw?.isEmpty ?? false ? null : (raw ?? 'STREAM_ERROR');
    }
  }

  Stream<LlmStreamEvent> parse(Stream<String> rawStream) async* {
    _emittedCallKeys.clear();
    _nameCallCounts.clear();
    _streamEnded = false;
    _lastUsage = null;
    _lastFinishReason = null;

    try {
      await for (final chunk in _rawParser.parse(rawStream)) {
        // Gemini SSE 无 event 字段，data 是 JSON
        final data = chunk.data;
        if (data.isEmpty) continue;

        // Gemini 无 [DONE] 标记，但兼容性处理（某些代理可能添加）
        if (data == '[DONE]') {
          if (!_streamEnded) {
            _streamEnded = true;
            yield LlmStreamDone(
              usage: _lastUsage,
              finishReason: _lastFinishReason,
            );
          }
          continue;
        }

        try {
          final json = jsonDecode(data) as Map<String, dynamic>;
          yield* _handleChunk(json);
        } catch (e) {
          yield LlmStreamError(
            'Failed to parse Gemini SSE data: $e',
            code: 'PARSE_ERROR',
          );
        }
      }
    } catch (e) {
      // 连接期 HTTP 错误按状态码映射语义码并携带 Retry-After（同 sse_parser）
      yield LlmStreamError(
        'Gemini stream interrupted: $e',
        code: streamErrorCodeOf(e),
        retryAfter: streamErrorRetryAfterOf(e),
      );
    }

    // 流自然关闭时发出 LlmStreamDone（Gemini 无显式结束标记）
    if (!_streamEnded) {
      _streamEnded = true;
      yield LlmStreamDone(usage: _lastUsage, finishReason: _lastFinishReason);
    }
  }

  Stream<LlmStreamEvent> _handleChunk(Map<String, dynamic> json) async* {
    // 审查收官 ：流内 error 块检测（代理/中转下 Gemini 常以
    // 200 + {"error":{...}} 承载错误）。此前静默丢弃并以空内容 Done 收尾——故事路
    // 产出空稿、导演路触发空响应 nudge。照 anthropic 解析器 XC-1 模式：
    // 发 LlmStreamError（带语义码）并置 _streamEnded 抑制兜底 Done
    final errorJson = json['error'];
    if (errorJson != null) {
      String message;
      String? code;
      if (errorJson is Map<String, dynamic>) {
        final rawMessage = errorJson['message'] ?? errorJson['status'];
        message = rawMessage is String && rawMessage.isNotEmpty
            ? rawMessage
            : 'Unknown Gemini stream error';
        final rawCode = errorJson['code'] ?? errorJson['status'];
        code = _semanticCodeOf(rawCode?.toString());
      } else {
        message = errorJson.toString();
        code = 'STREAM_ERROR';
      }
      _streamEnded = true;
      yield LlmStreamError(message, code: code);
      return;
    }

    // 2026-09-08（用户报告排查）：promptFeedback.blockReason 是官方的
    // prompt 级拦截形态——无 candidates，此前被空 candidates 分支静默
    // 跳过，流以「干净空响应」收尾（上层 CH-1 只清 busy 态，无任何
    // 可见反馈，即「生成消息静默消失」的一条真实链路）。
    final promptFeedback = json['promptFeedback'];
    if (promptFeedback is Map<String, dynamic>) {
      final blockReason = promptFeedback['blockReason'];
      if (blockReason is String && blockReason.isNotEmpty) {
        _streamEnded = true;
        yield LlmStreamError(
          'Gemini prompt blocked by safety filter ($blockReason)',
          code: switch (blockReason) {
            'SAFETY' => 'SAFETY_BLOCKED',
            'RECITATION' => 'RECITATION_BLOCKED',
            _ => 'PROMPT_BLOCKED',
          },
        );
        return;
      }
    }

    // 提取 usageMetadata（最后一个 chunk 携带）
    final usageMetadata = json['usageMetadata'] as Map<String, dynamic>?;
    if (usageMetadata != null) {
      _lastUsage = _parseUsage(usageMetadata);
    }

    final candidates = json['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) return;

    final candidate = candidates[0] as Map<String, dynamic>? ?? {};

    // 检测 finishReason
    final finishReason = candidate['finishReason'] as String?;
    if (finishReason != null) _lastFinishReason = finishReason;

    // 提取 content.parts（先处理 parts 再处理 finishReason，保证已生成内容能发出）
    final content = candidate['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List<dynamic>?;

    // 遍历 parts，按类型发出对应事件
    if (parts != null && parts.isNotEmpty) {
      for (final part in parts) {
        if (part is! Map<String, dynamic>) continue;

        // 1. 文本内容（可能同时是 thought）
        final text = part['text'] as String?;
        final isThought = part['thought'] == true;

        if (text != null && text.isNotEmpty) {
          if (isThought) {
            // Gemini thinking 内容（thought:true 标识）
            yield LlmThinkingDelta(text);
          } else {
            // 普通文本
            yield LlmTextDelta(text);
          }
        }

        // 2. 函数调用（Gemini 完整返回，不增量）
        final functionCall = part['functionCall'] as Map<String, dynamic>?;
        if (functionCall != null) {
          final name = functionCall['name'] as String? ?? '';
          final args = functionCall['args'];

          if (name.isNotEmpty) {
            final arguments =
                args is Map<String, dynamic> ? args : <String, dynamic>{};
            // 去重：同一 name+args 的 functionCall 只发出一次
            // （Gemini 偶尔在后续 chunk 重复携带已完成的 functionCall）
            final dedupKey = '$name|${jsonEncode(arguments)}';
            if (!_emittedCallKeys.contains(dedupKey)) {
              _emittedCallKeys.add(dedupKey);

              // 生成工具调用 ID（Gemini 不返回 id，按 name + 序号本地生成）
              // 首次调用为 `gemini_<name>`（与 v0.2 约定一致），
              // 同名第 N 次为 `gemini_<name>__<N>`（适配器按 __ 前缀剥离序号）
              final count =
                  _nameCallCounts.update(name, (v) => v + 1, ifAbsent: () => 0);
              final toolCallId =
                  count == 0 ? 'gemini_$name' : 'gemini_${name}__$count';

              // Gemini 3 的思考签名（part 级 thoughtSignature，base64），
              // 多轮回传必需（设计报告 §4.3）
              final thoughtSignature = part['thoughtSignature'] as String?;

              // Gemini functionCall 完整返回，直接发 Start + Complete
              yield LlmToolCallStart(toolCallId, name);
              yield LlmToolCallComplete(
                toolCallId: toolCallId,
                name: name,
                arguments: arguments,
                thoughtSignature: thoughtSignature,
              );
            }
          }
        }

        // 3. 函数响应（functionResponse，出现在历史消息回放中，流式响应不发）
        // 忽略，不发出事件
      }
    }

    // finishReason 处理（parts 处理后再检查）
    if (finishReason == 'SAFETY') {
      // 内容被安全过滤拦截
      if (!_streamEnded) {
        yield const LlmStreamError(
          'Content blocked by Gemini safety settings',
          code: 'SAFETY_BLOCKED',
        );
        _streamEnded = true;
        yield LlmStreamDone(usage: _lastUsage, finishReason: _lastFinishReason);
      }
      return;
    }

    if (finishReason == 'RECITATION') {
      // 内容触发版权引用过滤
      if (!_streamEnded) {
        yield const LlmStreamError(
          'Content blocked by Gemini recitation filter',
          code: 'RECITATION_BLOCKED',
        );
        _streamEnded = true;
        yield LlmStreamDone(usage: _lastUsage, finishReason: _lastFinishReason);
      }
      return;
    }

    if (finishReason == 'STOP' && !_streamEnded) {
      _streamEnded = true;
      yield LlmStreamDone(usage: _lastUsage, finishReason: _lastFinishReason);
    } else if (finishReason == 'MAX_TOKENS' && !_streamEnded) {
      _streamEnded = true;
      yield LlmStreamDone(usage: _lastUsage, finishReason: _lastFinishReason);
    } else if (finishReason != null &&
        finishReason.isNotEmpty &&
        !_streamEnded) {
      // 2026-09-08（用户报告排查）：STOP/MAX_TOKENS/SAFETY/RECITATION 之外
      // 的 finishReason（BLOCKLIST/PROHIBITED_CONTENT/SPII/OTHER/
      // MALFORMED_FUNCTION_CALL…）均为终止性拦截/异常——此前静默跳过，
      // 流以空 Done 收尾（上层无任何可见反馈）。统一发可见错误并抑制
      // 兜底 Done；已流出的正文由上层错误路径保留（半截 + 错误标注）。
      _streamEnded = true;
      yield LlmStreamError(
        'Gemini response terminated abnormally (finishReason: $finishReason)',
        code: 'STREAM_ERROR',
      );
    }
  }

  /// 解析 Gemini usageMetadata
  ///
  /// Gemini 字段名与 OpenAI/Anthropic 不同：
  /// - `promptTokenCount`（非 prompt_tokens / input_tokens）
  /// - `candidatesTokenCount`（非 completion_tokens / output_tokens）
  /// - `totalTokenCount`（非 total_tokens）
  /// - `thoughtsTokenCount`（Gemini 特有，思考 token 数，不计入 candidatesTokenCount）
  LlmUsage _parseUsage(Map<String, dynamic> usageMetadata) {
    final prompt = usageMetadata['promptTokenCount'] as int? ?? 0;
    final completion = usageMetadata['candidatesTokenCount'] as int? ?? 0;
    final total =
        usageMetadata['totalTokenCount'] as int? ?? (prompt + completion);
    return LlmUsage(
      promptTokens: prompt,
      completionTokens: completion,
      totalTokens: total,
    );
  }
}
