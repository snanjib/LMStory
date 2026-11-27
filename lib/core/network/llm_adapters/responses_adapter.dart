import 'dart:convert';

import 'package:lmstory/core/config/output_token_policy.dart';
import 'package:lmstory/core/llm/reasoning_effort.dart';
import 'package:lmstory/core/llm/tool_calling/tool_call.dart';
import 'package:lmstory/core/network/llm_adapters/llm_protocol_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/sampling_params.dart';
import 'package:lmstory/core/network/sse/responses_sse_parser.dart';
import 'package:lmstory/core/utils/api_url_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// OpenAI Responses API 适配器
///
/// 适用供应商：OpenAI 官方 Responses API、OpenRouter（`/api/v1/responses`）
/// 等提供 Responses 端点的服务。
///
/// 端点：`POST {baseUrl}/responses`（版本号由 ApiUrlResolver 管理）
/// 认证：`Authorization: Bearer {apiKey}`
/// SSE：`event:` + `data:` 双行，终止信号为 `response.completed` 事件（无 DONE 哨兵）
///
/// 与 Chat Completions 的关键结构差异：
/// 1. **input items**：messages → input 数组。system 提取到顶层 `instructions`；
///    工具调用消息是独立 item（`function_call` / `function_call_output`，
///    按 call_id 关联），非 role:"tool" 消息
/// 2. **工具定义扁平**：`{type:'function', name, description, parameters}`
///    （CC 是嵌套 function 对象）
/// 3. **max_output_tokens**：无 max_tokens / max_completion_tokens
/// 4. **无 penalties / stop / seed / n**；`stream_options` 仅含
///    include_obfuscation（usage 恒随 completed 事件返回，无需请求）
/// 5. **结构化输出**：response_format → `text.format`
/// 6. **usage 命名**：input_tokens / output_tokens（详情字段
///    input_tokens_details.cached_tokens、output_tokens_details.reasoning_tokens）
///
/// 官方要求推理档位非 none 时移除 temperature / top_p——启用档位
/// （low/medium/high）时采样参数一律不发。
///
/// 实现依据：OpenAI Responses API 官方参考与迁移指南（2026-11-02 复核）。
class ResponsesAdapter implements LlmProtocolAdapter {
  /// 每次流式解析创建新实例（与 OpenAI/Gemini 适配器一致，防并发流共享状态）
  ResponsesAdapter({ResponsesSseParser Function()? sseParserFactory})
      : _sseParserFactory = sseParserFactory ?? ResponsesSseParser.new;

  /// 最终 wire 输出上限（单源）：基础钳制（clampToModel；0/null=不设置
  /// 应用层上限）+ providerOptions.extra_body 末位覆盖——extra_body 在
  /// [buildRequestBody] 里于基础字段之后展开，能覆盖 max_output_tokens，
  /// 预算面必须看到同一结果。返回 null=本次请求不携带输出上限
  ///（API 未指定）。
  static int? effectiveOutputTokens({
    required int? configured,
    required int? modelMaxOutputTokens,
    Map<String, dynamic>? providerOptions,
  }) {
    final base =
        OutputTokenPolicy.clampToModel(configured, modelMaxOutputTokens);
    final effective = base != null && base > 0 ? base : null;
    final extra = providerOptions?['extra_body'];
    if (extra is Map<String, dynamic>) {
      final override = extra['max_output_tokens'];
      if (override is int && override > 0) return override;
    }
    return effective;
  }

  final ResponsesSseParser Function() _sseParserFactory;

  @override
  String buildUrl(String baseUrl, String modelId, {required bool stream}) {
    return ApiUrlResolver.resolve(baseUrl, '/responses');
  }

  @override
  Map<String, String> buildHeaders(
    LlmRequest request, {
    Map<String, String>? extra,
  }) {
    final apiKey = request.apiKey;
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
    // 输出上限单源解析（基础钳制 + extra_body 末位覆盖，与下方展开
    // 顺序一致）；effectiveOutputTokens 与预算面共用
    final maxTokens = effectiveOutputTokens(
      configured: request.maxTokens,
      modelMaxOutputTokens: request.modelMaxOutputTokens,
      providerOptions: request.providerOptions,
    );

    // 推理档位启用（low/medium/high 均非 none）时不发采样参数（官方规则）；
    // 供应商开关、moonshot 端点家族或模型能力命中（o 系 / GPT-5 / GPT-6 等）同样省略
    final effort = request.reasoningEffort;
    final reasoningActive =
        effort != null && effort != ReasoningEffort.disabled;
    final omitSampling = shouldOmitSamplingParams(
      modelId: modelId,
      providerOptions: request.providerOptions,
      baseUrl: request.baseUrl,
    );

    final instructions = _extractInstructions(request.messages);
    final input = _convertMessagesToInput(request.messages);

    return {
      'model': modelId,
      if (instructions != null) 'instructions': instructions,
      'input': input,
      'stream': stream,
      if (maxTokens != null && maxTokens > 0) 'max_output_tokens': maxTokens,
      if (!omitSampling && !reasoningActive && request.temperature != null)
        'temperature': sanitizeSamplingParam(request.temperature),
      if (!omitSampling && !reasoningActive && request.topP != null)
        'top_p': sanitizeSamplingParam(request.topP),
      if (reasoningActive) 'reasoning': {'effort': effort.toJson()},
      if (request.tools != null)
        'tools': request.tools!
            .map(
              (t) => {
                'type': 'function',
                'name': t.name,
                'description': t.description,
                'parameters': t.parameters,
              },
            )
            .toList(),
      if (request.toolChoice != null)
        'tool_choice': request.toolChoice!.toRequestBody(),
      // 与 CC 适配器同口径：显式启用并行工具调用（可被 providerOptions 覆盖）
      if (request.tools != null && request.toolChoice != null)
        'parallel_tool_calls':
            request.providerOptions?['parallel_tool_calls'] is! bool ||
                request.providerOptions!['parallel_tool_calls'] as bool,
      if (format != null) 'text': {'format': _responseFormatToJson(format)},
      // extra_body 透传（与 CC 适配器一致，展开在最后允许覆盖）
      if (request.providerOptions?['extra_body'] is Map<String, dynamic>)
        ...(request.providerOptions!['extra_body'] as Map<String, dynamic>),
    };
  }

  @override
  Stream<LlmStreamEvent> parseStream(Stream<String> rawStream) {
    return _sseParserFactory().parse(rawStream);
  }

  @override
  LlmResponse parseResponse(Map<String, dynamic> body) {
    final output = body['output'] as List<dynamic>? ?? [];

    final textBuffer = StringBuffer();
    final reasoningBuffer = StringBuffer();
    final toolCalls = <ToolCall>[];

    for (final item in output) {
      if (item is! Map<String, dynamic>) continue;
      switch (item['type']) {
        case 'message':
          final content = item['content'];
          if (content is List) {
            for (final part in content) {
              if (part is Map<String, dynamic> &&
                  part['type'] == 'output_text') {
                final text = part['text'] as String?;
                if (text != null && text.isNotEmpty) {
                  textBuffer.write(text);
                }
              }
            }
          }
        case 'reasoning':
          // 推理摘要（明文可见部分）——映射到思考内容供 UI 展示
          final summary = item['summary'];
          if (summary is List) {
            for (final part in summary) {
              if (part is Map<String, dynamic> &&
                  part['type'] == 'summary_text') {
                final text = part['text'] as String?;
                if (text != null && text.isNotEmpty) {
                  reasoningBuffer.write(text);
                }
              }
            }
          }
        case 'function_call':
          toolCalls.add(
            ToolCall.fromRawArgs(
              id: (item['call_id'] ?? item['id'] ?? '') as String,
              name: item['name'] as String? ?? '',
              rawArguments: item['arguments'] as String? ?? '',
            ),
          );
        default:
          break;
      }
    }

    // failed 状态：内容按已产出部分返回，finishReason 上抛供调用方判错
    final status = body['status'] as String?;
    final String? finishReason;
    if (status == 'incomplete') {
      final details = body['incomplete_details'];
      final reason =
          details is Map<String, dynamic> ? details['reason'] as String? : null;
      // 归一到 CC 词表（max_output_tokens → length），消费方截断诊断统一
      finishReason =
          reason == 'max_output_tokens' ? 'length' : (reason ?? 'length');
    } else if (status == 'failed') {
      finishReason = 'failed';
    } else {
      finishReason = null;
    }

    return LlmResponse(
      content: textBuffer.toString(),
      usage: _parseUsage(body['usage']),
      toolCalls: toolCalls.isEmpty ? null : toolCalls,
      reasoningContent:
          reasoningBuffer.isEmpty ? null : reasoningBuffer.toString(),
      finishReason: finishReason,
    );
  }

  @override
  String buildModelsUrl(String baseUrl) {
    return ApiUrlResolver.resolve(baseUrl, '/models');
  }

  /// 提取 system 消息为顶层 instructions（Responses 无 role:"system" input item
  /// 的常规用法；多条 system 以空行拼接，与 Gemini systemInstruction 同构）
  static String? _extractInstructions(List<Map<String, dynamic>> messages) {
    final systemParts = <String>[];
    for (final msg in messages) {
      if (msg['role'] != 'system') continue;
      final content = msg['content'];
      if (content is String && content.isNotEmpty) {
        systemParts.add(content);
      } else if (content is List) {
        for (final part in content) {
          if (part is Map<String, dynamic> && part['type'] == 'text') {
            final text = part['text'] as String?;
            if (text != null && text.isNotEmpty) systemParts.add(text);
          }
        }
      }
    }
    if (systemParts.isEmpty) return null;
    return systemParts.join('\n\n');
  }

  /// messages（OpenAI CC 风格）→ Responses input items
  static List<Map<String, dynamic>> _convertMessagesToInput(
    List<Map<String, dynamic>> messages,
  ) {
    final input = <Map<String, dynamic>>[];
    for (final msg in messages) {
      final role = msg['role'] as String?;
      final content = msg['content'];

      switch (role) {
        // system 已提取到 instructions，跳过
        case 'system':
          continue;

        case 'user':
          if (content is String) {
            input.add({'role': 'user', 'content': content});
          } else if (content is List) {
            final parts = <Map<String, dynamic>>[];
            for (final part in content) {
              if (part is! Map<String, dynamic>) continue;
              if (part['type'] == 'text') {
                final text = part['text'] as String?;
                if (text != null && text.isNotEmpty) {
                  parts.add({'type': 'input_text', 'text': text});
                }
              } else if (part['type'] == 'image_url') {
                final imageUrl = part['image_url'];
                final url = imageUrl is Map<String, dynamic>
                    ? imageUrl['url'] as String?
                    : null;
                if (url != null && url.isNotEmpty) {
                  // data: 与 https:// 均为 input_image 合法取值
                  parts.add({'type': 'input_image', 'image_url': url});
                }
              }
            }
            if (parts.isNotEmpty) {
              input.add({'role': 'user', 'content': parts});
            }
          }

        case 'assistant':
          // 正文 → assistant message item
          // 已知边界（HAR-02）：空正文 assistant（无 content 无 tool_calls）
          // 在此整条消失——不虚构 item。若后续 function_call_output 引用
          // 消失轮的 call_id 会孤儿化；Responses 的 input 数组允许 assistant
          // item 缺失，OpenAI 网关对此宽容（实测不因孤儿 output 拒绝请求）。
          if (content is String && content.isNotEmpty) {
            input.add({'role': 'assistant', 'content': content});
          }
          // 工具调用 → 独立 function_call items（call_id 关联结果）
          final toolCalls = msg['tool_calls'];
          if (toolCalls is List) {
            for (final tc in toolCalls) {
              if (tc is! Map<String, dynamic>) continue;
              final function = tc['function'] as Map<String, dynamic>?;
              input.add({
                'type': 'function_call',
                'call_id': tc['id'] as String? ?? '',
                'name': function?['name'] as String? ?? '',
                'arguments': function?['arguments'] as String? ?? '{}',
              });
            }
          }
        // reasoning_content 不回放：Responses 的 reasoning item 携带服务端
        // 加密内容，无法从明文字符串重建；省略后模型自行重新推理（可用，
        // 损失推理连续性——与多数客户端的 store:false 简化口径一致）

        case 'tool':
          input.add({
            'type': 'function_call_output',
            'call_id': msg['tool_call_id'] as String? ?? '',
            'output': content is String ? content : jsonEncode(content ?? ''),
          });

        default:
          break;
      }
    }
    return input;
  }

  /// LlmResponseFormat → Responses `text.format`
  static Map<String, dynamic> _responseFormatToJson(LlmResponseFormat format) {
    return switch (format) {
      LlmResponseFormatJsonObject() => {'type': 'json_object'},
      LlmResponseFormatJsonSchema(:final name, :final schema, :final strict) =>
        {
          'type': 'json_schema',
          'name': name,
          'schema': schema,
          'strict': strict,
        },
    };
  }

  /// Responses usage（input_tokens/output_tokens 命名）→ LlmUsage
  static LlmUsage? _parseUsage(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final inputDetails = raw['input_tokens_details'];
    final outputDetails = raw['output_tokens_details'];
    final input = raw['input_tokens'] as int?;
    return LlmUsage(
      promptTokens: input,
      completionTokens: raw['output_tokens'] as int?,
      totalTokens: raw['total_tokens'] as int?,
      // Responses 的 input_tokens 已含缓存命中部分，即完整输入
      totalInputTokens: input,
      cacheReadTokens: inputDetails is Map<String, dynamic>
          ? inputDetails['cached_tokens'] as int?
          : null,
      reasoningTokens: outputDetails is Map<String, dynamic>
          ? outputDetails['reasoning_tokens'] as int?
          : null,
    );
  }
}
