import 'dart:async';

import 'package:lmstory/core/config/output_token_policy.dart';
import 'package:lmstory/core/llm/tool_calling/tool_call.dart';
import 'package:lmstory/core/network/llm_adapters/llm_protocol_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/sampling_params.dart';
import 'package:lmstory/core/network/llm_adapters/thinking_param_builder.dart';
import 'package:lmstory/core/network/sse/sse_parser.dart';
import 'package:lmstory/core/utils/api_url_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// OpenAI Chat Completions 兼容协议适配器
///
/// 适用供应商：OpenAI、DeepSeek、OpenRouter、各类第三方 OpenAI 兼容端点
///
/// 端点：`POST {baseUrl}/chat/completions`（版本号由 ApiUrlResolver 管理）
/// 认证：`Authorization: Bearer {apiKey}`
/// SSE：`data: {json}\n\n`，结束标记 `data: [DONE]`
///
/// 复用现有 [SseParser] 的 5 状态机逻辑处理 tool_calls 交错。
///
/// 实现依据：DOC-12 §5.2 + §5.4.1。
class OpenAiAdapter implements LlmProtocolAdapter {
  /// [sseParserFactory] 用于创建每次流式解析所需的 [SseParser] 实例。
  ///
  /// **必须每次调用创建新实例**（XC-3，与 Anthropic/Gemini 适配器对齐）：
  /// [SseParser] 内部维护可变状态（`_toolCallTracker` / `_lastUsage` /
  /// `_lastFinishReason` / `_streamEnded`），在 `parse()` 入口重置。
  /// 适配器经 LlmAdapterFactory 以单例形式持有，若多个流式请求共享
  /// 同一解析器实例，并发流的 `parse()` 会互相清状态——工具分片跨流丢失、
  /// usage/finishReason 被污染。默认工厂 `SseParser.new` 保证每流一实例。
  OpenAiAdapter({SseParser Function()? sseParserFactory})
      : _sseParserFactory = sseParserFactory ?? SseParser.new;

  final SseParser Function() _sseParserFactory;

  @override
  String buildUrl(String baseUrl, String modelId, {required bool stream}) {
    return ApiUrlResolver.resolve(baseUrl, '/chat/completions');
  }

  @override
  Map<String, String> buildHeaders(
    LlmRequest request, {
    Map<String, String>? extra,
  }) {
    final apiKey = request.apiKey;
    // 从 providerOptions 提取协议特有 header（如 OpenRouter 的 HTTP-Referer/X-Title）
    // 2026-07-28 修复：原用 cast<String, String>() 是惰性 cast，若用户配置的值
    // 不是 String（如数字），运行时展开会抛 _TypeError。改用显式 toString 转换提升容错。
    final rawHeaders = request.providerOptions?['extra_headers'];
    final providerHeaders = <String, String>{};
    if (rawHeaders is Map<String, dynamic>) {
      rawHeaders.forEach((k, v) => providerHeaders[k] = v.toString());
    }
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (apiKey != null && apiKey.isNotEmpty)
        'Authorization': 'Bearer $apiKey',
      ...providerHeaders,
      ...?extra,
    };
  }

  @override
  Map<String, dynamic> buildRequestBody(
    LlmRequest request, {
    required bool stream,
  }) {
    final format = request.responseFormat;
    final modelId = request.modelId;
    final maxTokens = OutputTokenPolicy.clampToModel(
      request.maxTokens,
      request.modelMaxOutputTokens,
    );

    // o-series 模型参数过滤（DOC-12 §5.4.1 + §11 风险表）
    // o1/o3/o4 系列不支持 temperature/top_p/presence_penalty/frequency_penalty
    // 传这些参数会导致 400 错误
    final isOSeries = modelId.startsWith('o1') ||
        modelId.startsWith('o3') ||
        modelId.startsWith('o4');

    // 2026-07-27 重构：思考参数统一交由 ThinkingParamBuilder 构建
    // 适配 OpenAI/DeepSeek/Qwen3/GLM/Kimi/OpenRouter 6 套厂商，Simple 和故事模式共用
    final thinkingParams = ThinkingParamBuilder.build(
      modelId: modelId,
      reasoningEffort: request.reasoningEffort,
      providerOptions: request.providerOptions,
      baseUrl: request.baseUrl,
    );

    return {
      'model': modelId,
      'messages': request.messages,
      'stream': stream,
      // o-series 不传 temperature/top_p（API 会返回 400）
      // 采样参数出网前统一取整：滑块离散化会留下浮点尾差（如
      // 0.5700000000000001），部分厂商按小数位数校验并直接 400
      if (!isOSeries && request.temperature != null)
        'temperature': sanitizeSamplingParam(request.temperature),
      if (!isOSeries && request.topP != null)
        'top_p': sanitizeSamplingParam(request.topP),
      // 0 = 不设置应用层上限：不向 OpenAI 兼容端点发送 token 上限。
      // o-series 不兼容已废弃的 max_tokens，改用 max_completion_tokens。
      if (maxTokens != null && maxTokens > 0 && isOSeries)
        'max_completion_tokens': maxTokens,
      if (maxTokens != null && maxTokens > 0 && !isOSeries)
        'max_tokens': maxTokens,
      // o-series 也不支持 presence_penalty/frequency_penalty
      if (!isOSeries && request.presencePenalty != null)
        'presence_penalty': sanitizeSamplingParam(request.presencePenalty),
      if (!isOSeries && request.frequencyPenalty != null)
        'frequency_penalty': sanitizeSamplingParam(request.frequencyPenalty),
      if (stream && request.includeUsage)
        'stream_options': {'include_usage': true},
      if (format != null) 'response_format': _responseFormatToJson(format),
      if (request.tools != null)
        'tools': request.tools!.map((t) => t.toRequestBody()).toList(),
      if (request.toolChoice != null)
        'tool_choice': request.toolChoice!.toRequestBody(),
      // 2026-07-26 修复：显式启用 parallel_tool_calls
      // OpenAI 协议下默认值因模型而异，agnes 2.0 flash 默认 false 串行调用，
      // 导致只调用 extract_event_summary 跳过 extract_facts。
      // 显式设为 true 强制 LLM 在单次响应内并行调用所有工具。
      // 注意：DeepSeek 端点的兼容性降级由 DeepSeekAdapter 处理（见 DOC-12 §5.4.2）
      //
      // 2026-08-15（v0.3）：providerOptions['parallel_tool_calls'] 可显式
      // 覆盖（bool）——Agent Loop 按 capability registry 对 GLM/Qwen/中转站
      // 强制串行；中级模式不传该 key，行为不变。
      if (request.tools != null && request.toolChoice != null)
        'parallel_tool_calls':
            request.providerOptions?['parallel_tool_calls'] is! bool ||
                request.providerOptions!['parallel_tool_calls'] as bool,
      // 2026-08-15（v0.3）：extra_body 透传——承载无法用统一字段表达的
      // 请求体级参数（如 GLM 直连流式工具的 tool_stream=true）。
      // 值必须是 Map<String, dynamic>，展开在最后（允许覆盖已设字段）。
      if (request.providerOptions?['extra_body'] is Map<String, dynamic>)
        ...(request.providerOptions!['extra_body'] as Map<String, dynamic>),
      // 思考/推理参数（2026-07-27 重构：统一由 ThinkingParamBuilder 适配 6 套厂商）
      ...thinkingParams,
    };
  }

  @override
  Stream<LlmStreamEvent> parseStream(Stream<String> rawStream) async* {
    // 每次调用创建新的解析器实例，避免并发流共享可变状态（XC-3）。
    // 适配器本身是单例（LlmAdapterFactory 持有），若复用同一解析器实例，
    // 两个并发的流式请求会互相覆盖 _toolCallTracker / _lastUsage 等状态。
    await for (final event in _sseParserFactory().parse(rawStream)) {
      if (event is TextDelta) {
        yield LlmTextDelta(event.content);
      } else if (event is ThinkingDelta) {
        yield LlmThinkingDelta(event.content);
      } else if (event is ToolCallStart) {
        yield LlmToolCallStart(event.toolCallId, event.toolName);
      } else if (event is ToolCallArgs) {
        yield LlmToolCallArgs(event.toolCallId, event.argsChunk);
      } else if (event is ToolCallComplete) {
        // arguments 为累积后的原始 JSON 字符串，复用 ToolCall.fromRawArgs 容错解析
        final toolCall = ToolCall.fromRawArgs(
          id: event.toolCallId,
          name: event.toolName,
          rawArguments: event.arguments,
        );
        yield LlmToolCallComplete(
          toolCallId: toolCall.id,
          name: toolCall.name,
          arguments: toolCall.arguments,
        );
      } else if (event is StreamEnd) {
        yield LlmStreamDone(
          usage: _toLlmUsage(event.usage),
          finishReason: event.finishReason,
        );
      } else if (event is StreamError) {
        yield LlmStreamError(
          event.message,
          code: event.code,
          retryAfter: event.retryAfter,
        );
      }
    }
  }

  @override
  LlmResponse parseResponse(Map<String, dynamic> body) {
    final choices = body['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) {
      return const LlmResponse(content: '');
    }
    final choice = choices[0] as Map<String, dynamic>;
    final message = choice['message'] as Map<String, dynamic>?;
    final content = (message?['content'] as String?) ?? '';
    // 结束原因（length/content_filter 等需要调用方区分，2026-08-17）
    final finishReason = choice['finish_reason'] as String?;
    // 思维链字段：DeepSeek 系用 reasoning_content；SenseNova 等端点用
    // reasoning（与流式 SseParser 的双字段容错对齐）
    final reasoningContent = (message?['reasoning_content'] as String?) ??
        (message?['reasoning'] as String?);

    // 解析非流式响应的 tool_calls
    List<ToolCall>? toolCalls;
    final rawToolCalls = message?['tool_calls'] as List<dynamic>?;
    if (rawToolCalls != null && rawToolCalls.isNotEmpty) {
      toolCalls = rawToolCalls.map((tc) {
        final tcMap = tc as Map<String, dynamic>;
        final function = tcMap['function'] as Map<String, dynamic>?;
        return ToolCall.fromRawArgs(
          id: (tcMap['id'] as String?) ?? '',
          name: (function?['name'] as String?) ?? '',
          rawArguments: (function?['arguments'] as String?) ?? '',
        );
      }).toList();
    }

    return LlmResponse(
      content: content,
      usage: _toLlmUsage(body['usage']),
      toolCalls: toolCalls,
      reasoningContent: reasoningContent,
      finishReason: finishReason,
    );
  }

  @override
  String buildModelsUrl(String baseUrl) {
    return ApiUrlResolver.resolve(baseUrl, '/models');
  }

  /// 把 [LlmResponseFormat] 转为 OpenAI API 的 `response_format` 字段
  Map<String, dynamic> _responseFormatToJson(LlmResponseFormat format) {
    return switch (format) {
      LlmResponseFormatJsonObject() => {'type': 'json_object'},
      LlmResponseFormatJsonSchema(:final name, :final schema, :final strict) =>
        {
          'type': 'json_schema',
          'json_schema': {
            'name': name,
            'schema': schema,
            'strict': strict,
          },
        },
    };
  }

  LlmUsage? _toLlmUsage(Object? raw) {
    if (raw == null) return null;
    if (raw is SseUsage) {
      return LlmUsage(
        promptTokens: raw.promptTokens,
        completionTokens: raw.completionTokens,
        totalTokens: raw.totalTokens,
        cacheReadTokens: raw.cacheReadTokens,
      );
    }
    if (raw is Map<String, dynamic>) {
      final promptDetails = raw['prompt_tokens_details'];
      return LlmUsage(
        promptTokens: raw['prompt_tokens'] as int?,
        completionTokens: raw['completion_tokens'] as int?,
        totalTokens: raw['total_tokens'] as int?,
        cacheReadTokens: promptDetails is Map<String, dynamic>
            ? promptDetails['cached_tokens'] as int?
            : null,
      );
    }
    return null;
  }
}
