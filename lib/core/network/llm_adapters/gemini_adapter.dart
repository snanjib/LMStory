import 'dart:async';
import 'dart:convert';

import 'package:lmstory/core/config/output_token_policy.dart';
import 'package:lmstory/core/llm/reasoning_effort.dart';
import 'package:lmstory/core/llm/tool_calling/tool_call.dart';
import 'package:lmstory/core/llm/tool_calling/tool_choice.dart';
import 'package:lmstory/core/network/llm_adapters/gemini_schema.dart';
import 'package:lmstory/core/network/llm_adapters/llm_protocol_adapter.dart';
import 'package:lmstory/core/network/sse/gemini_sse_parser.dart';
import 'package:lmstory/core/utils/api_url_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// Google Gemini 原生协议适配器
///
/// 适用供应商：Google Gemini 系列（gemini-3.6-flash / gemini-3.6-pro /
/// gemini-2.5-pro / gemini-2.5-flash 等）
///
/// 端点：
/// - 非流式：`POST /v1beta/models/{model}:generateContent`
/// - 流式：`POST /v1beta/models/{model}:streamGenerateContent?alt=sse`
///
/// 认证：`x-goog-api-key: {apiKey}`（非 Bearer）
///
/// SSE：`data: {json}\n\n`，无 `event:` 字段，无 `[DONE]`，
/// 靠流自然关闭判断结束。
///
/// 关键差异处理（DOC-12 §5.4.5）：
/// 1. **role 映射**：`assistant` → `model`，`system` 提取到 `systemInstruction`
/// 2. **contents/parts 结构**：messages → contents，content → parts 数组
/// 3. **generationConfig 包裹**：采样参数包在 `generationConfig` 对象内
/// 4. **safetySettings 默认宽松**：角色扮演场景需主动设置 BLOCK_ONLY_HIGH
/// 5. **thinkingConfig 双轨制**：Gemini 3 用 `thinkingLevel`，Gemini 2.5 用 `thinkingBudget`
/// 6. **functionCall args 对象**：args 是对象（非 JSON 字符串）
/// 7. **functionResponse 位置**：工具结果用 `functionResponse` 字段（非 role:"tool"）
/// 8. **不支持 response_format**：用 `responseMimeType: application/json` +
///    `responseSchema` 替代（Gemini 原生结构化输出方式）
/// 9. **不支持 presence_penalty/frequency_penalty**：忽略这两个参数
/// 10. **functionDeclarations/responseSchema 只接受 Schema proto 子集**：
///    `additionalProperties` 等 JSON Schema 关键字会让整个请求 400
///    INVALID_ARGUMENT，出网前统一经 [toGeminiSchema] 白名单裁剪
///
/// 实现依据：DOC-12 §5.2 + §5.4.5 + §5.5 + Google Gemini 官方文档（2026-07-24 调研）。
class GeminiAdapter implements LlmProtocolAdapter {
  /// [sseParserFactory] 用于创建每次流式解析所需的 [GeminiSseParser] 实例。
  ///
  /// **必须每次调用创建新实例**：[GeminiSseParser] 内部维护可变状态
  /// （`_emittedToolCallNames` / `_streamEnded` / `_lastUsage`），在 `parse()`
  /// 入口重置。若多个流式请求共享同一实例（适配器是工厂单例），并发流的
  /// `parse()` 会互相重置状态，导致工具调用去重失效、重复 Done 事件、
  /// usage 数据污染。默认工厂 `GeminiSseParser.new` 保证每流一实例。
  GeminiAdapter({GeminiSseParser Function()? sseParserFactory})
      : _sseParserFactory = sseParserFactory ?? GeminiSseParser.new;

  /// 最终 wire 输出上限（单源）：基础钳制（clampToModel；0/null=不设置
  /// 应用层上限——generationConfig 省略 maxOutputTokens 字段）。Gemini
  /// 无 extra_body 式末位覆盖通道。返回 null=本次请求不携带输出上限
  ///（API 未指定）。
  static int? effectiveOutputTokens({
    required int? configured,
    required int? modelMaxOutputTokens,
  }) {
    final base =
        OutputTokenPolicy.clampToModel(configured, modelMaxOutputTokens);
    return base != null && base > 0 ? base : null;
  }

  final GeminiSseParser Function() _sseParserFactory;

  /// 非流式响应解析期间的同名工具调用计数（生成本地唯一 id，与流式一致）
  final Map<String, int> _nameCallCounts = {};

  /// 从 tool_call_id 剥离本地序号后缀，还原工具名
  ///
  /// `gemini_search` → `search`；`gemini_search__2` → `search`；
  /// 非 gemini 前缀的 id（跨协议回传场景）原样返回。
  static String _toolNameFromCallId(String toolCallId) {
    if (!toolCallId.startsWith('gemini_')) return toolCallId;
    final namePart = toolCallId.substring(7);
    final seqIndex = namePart.indexOf('__');
    return seqIndex == -1 ? namePart : namePart.substring(0, seqIndex);
  }

  /// thinking 合法所需的 maxOutputTokens 下限（与 Anthropic S-2
  /// 护栏同构）：正数 thinkingBudget 协议下限为 128 且须小于
  /// maxOutputTokens，maxTokens ≤ 128 时任何 thinking 配置都可能冲突。
  /// 调用方应尽量通过 [LlmRequest.maxTokens] 显式传入。
  static const int _minThinkingMaxTokens = 128;

  /// 默认宽松 safetySettings（角色扮演场景需要）
  ///
  /// Gemini 默认安全过滤较严格，角色扮演场景中的冲突、暴力描写等会被误判拦截。
  /// 设置为 BLOCK_ONLY_HIGH（仅拦截高确定性有害内容），允许大部分创作内容通过。
  static const List<Map<String, String>> _defaultSafetySettings = [
    {'category': 'HARM_CATEGORY_HARASSMENT', 'threshold': 'BLOCK_ONLY_HIGH'},
    {'category': 'HARM_CATEGORY_HATE_SPEECH', 'threshold': 'BLOCK_ONLY_HIGH'},
    {
      'category': 'HARM_CATEGORY_SEXUALLY_EXPLICIT',
      'threshold': 'BLOCK_ONLY_HIGH',
    },
    {
      'category': 'HARM_CATEGORY_DANGEROUS_CONTENT',
      'threshold': 'BLOCK_ONLY_HIGH',
    },
  ];

  @override
  String buildUrl(String baseUrl, String modelId, {required bool stream}) {
    // Gemini 把 modelId 拼到路径里，端点形式特殊
    // 非流式: /v1beta/models/{model}:generateContent
    // 流式: /v1beta/models/{model}:streamGenerateContent?alt=sse
    //
    // 流式必须加 ?alt=sse 才能返回 SSE 格式，否则返回 JSON 数组（非 SSE）。
    // Gemini 的端点结构特殊（modelId 拼进路径 + 方法后缀），不能用
    // ApiUrlResolver.resolve（它只拼接固定端点后缀，如 /chat/completions）。
    // Gemini 自行按官方格式构建：{base}/v1beta/models/{model}:generateContent
    // raw: 前缀先剥掉（OpenAI/Anthropic 走 ApiUrlResolver 会剥，
    // Gemini 因端点结构特殊自行拼 URL，此前 raw 模式产出 `raw:https://...`
    // 必然失败）。剥后仍按官方结构拼——raw+Gemini 的自定义诉求由
    // /v1beta 归一化规则兜底。
    final rawStripped = baseUrl.startsWith(ApiUrlResolver.rawPrefix)
        ? baseUrl.substring(ApiUrlResolver.rawPrefix.length)
        : baseUrl;
    final cleanBaseUrl = rawStripped.endsWith('/')
        ? rawStripped.substring(0, rawStripped.length - 1)
        : rawStripped;

    // 标准化 baseUrl 到 /v1beta 根（去掉 /v1beta 后的任何路径）
    final v1betaRoot = cleanBaseUrl.contains('/v1beta')
        ? cleanBaseUrl.replaceAll(RegExp(r'/v1beta(/.*)?$'), '/v1beta')
        : '$cleanBaseUrl/v1beta';

    final action = stream ? 'streamGenerateContent' : 'generateContent';
    final suffix = stream ? '?alt=sse' : '';

    return _wrapWithProxyIfNeeded(
      '$v1betaRoot/models/$modelId:$action$suffix',
    );
  }

  @override
  Map<String, String> buildHeaders(
    LlmRequest request, {
    Map<String, String>? extra,
  }) {
    final apiKey = request.apiKey;
    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      if (apiKey != null && apiKey.isNotEmpty) 'x-goog-api-key': apiKey,
      ...?extra,
    };
  }

  @override
  Map<String, dynamic> buildRequestBody(
    LlmRequest request, {
    required bool stream,
  }) {
    // 提取 system 消息到 systemInstruction 顶层字段
    final messages = request.messages;
    final systemInstruction = _extractSystemInstruction(messages);
    final filteredMessages = _filterNonSystemMessages(messages);

    // 转换 OpenAI 风格 messages 为 Gemini contents 数组
    final contents = _convertMessagesToContents(filteredMessages);

    final body = <String, dynamic>{
      'contents': contents,
    };

    // systemInstruction 顶层字段
    if (systemInstruction != null) {
      body['systemInstruction'] = systemInstruction;
    }

    // generationConfig（Gemini 特有结构）
    // 协议级停发采样参数：官方对 Gemini 3.6+ 明文忽略自定义 temperature/
    // topP/topK 并警告未来 400，新 API 形态已移除采样字段；老代系一并停发。
    // temperature/topP 不再出网，其余配置照常下发。
    final generationConfig = <String, dynamic>{};
    // 输出上限单源解析（effectiveOutputTokens 与预算面共用）
    final maxTokens = effectiveOutputTokens(
      configured: request.maxTokens,
      modelMaxOutputTokens: request.modelMaxOutputTokens,
    );
    if (maxTokens != null) {
      generationConfig['maxOutputTokens'] = maxTokens;
    }

    // response_format → responseMimeType + responseSchema
    // Gemini 不支持 OpenAI 的 response_format，但有原生结构化输出方式
    if (request.responseFormat != null) {
      final structuredConfig = _convertResponseFormat(request.responseFormat!);
      generationConfig.addAll(structuredConfig);
    }

    // thinkingConfig（Gemini thinking 双轨制）
    final thinkingConfig = _buildThinkingConfig(request);
    if (thinkingConfig != null) {
      generationConfig['thinkingConfig'] = thinkingConfig;
    }

    if (generationConfig.isNotEmpty) {
      body['generationConfig'] = generationConfig;
    }

    // safetySettings 默认宽松（角色扮演场景需要）
    body['safetySettings'] = _defaultSafetySettings;

    // Gemini 的 tools 是数组，函数声明集中在一个 Tool 对象中。
    final tools = request.tools;
    if (tools != null && tools.isNotEmpty) {
      body['tools'] = [
        {
          'functionDeclarations': [
            for (final tool in tools)
              {
                'name': tool.name,
                'description': tool.description,
                'parameters': toGeminiSchema(tool.parameters),
              },
          ],
        },
      ];
    }

    // 工具选择策略（Gemini 用 toolConfig.functionCallingConfig.mode）
    if (request.toolChoice != null) {
      body['toolConfig'] = {
        'functionCallingConfig': _convertToolChoice(request.toolChoice!),
      };
    }

    // 注意：Gemini 流式通过 URL 端点区分（streamGenerateContent），
    // 不在请求体中传 stream 参数
    // Gemini 不支持 presence_penalty/frequency_penalty，忽略

    return body;
  }

  @override
  Stream<LlmStreamEvent> parseStream(Stream<String> rawStream) {
    // 每次调用创建新的解析器实例，避免并发流共享可变状态。
    // 适配器本身是单例（LlmAdapterFactory 持有），若复用同一解析器实例，
    // 两个并发的流式请求会互相覆盖 _emittedToolCallNames / _streamEnded 等状态。
    return _sseParserFactory().parse(rawStream);
  }

  @override
  LlmResponse parseResponse(Map<String, dynamic> body) {
    // Gemini 非流式响应结构：
    // {
    //   "candidates": [{
    //     "content": {
    //       "parts": [
    //         {"text": "..."},
    //         {"thought": true, "text": "..."},
    //         {"functionCall": {"name": "...", "args": {...}}}
    //       ],
    //       "role": "model"
    //     },
    //     "finishReason": "STOP"|"MAX_TOKENS"|"SAFETY"|...,
    //     "index": 0
    //   }],
    //   "usageMetadata": {
    //     "promptTokenCount": 10,
    //     "candidatesTokenCount": 20,
    //     "totalTokenCount": 30,
    //     "thoughtsTokenCount": 5
    //   }
    // }

    final candidates = body['candidates'] as List<dynamic>? ?? [];
    _nameCallCounts.clear();
    if (candidates.isEmpty) {
      return const LlmResponse(content: '');
    }

    final candidate = candidates[0] as Map<String, dynamic>? ?? {};
    final content = candidate['content'] as Map<String, dynamic>? ?? {};
    final parts = content['parts'] as List<dynamic>? ?? [];

    final textBuffer = StringBuffer();
    final thinkingBuffer = StringBuffer();
    final thinkingBlocks = <LlmThinkingBlock>[];
    final toolCalls = <ToolCall>[];

    for (final part in parts) {
      if (part is! Map<String, dynamic>) continue;

      final text = part['text'] as String?;
      final isThought = part['thought'] == true;

      if (text != null && text.isNotEmpty) {
        if (isThought) {
          thinkingBuffer.write(text);
          // thoughtSignature 定义在 Part 层级，thought part 可携带签名；
          // 官方要求多轮原样回传全部 thought 块（含签名），不可删改
          final signature = part['thoughtSignature'] as String?;
          if (signature != null && signature.isNotEmpty) {
            thinkingBlocks.add(
              LlmThinkingBlock(thinking: text, signature: signature),
            );
          }
        } else {
          textBuffer.write(text);
        }
      }

      final functionCall = part['functionCall'] as Map<String, dynamic>?;
      if (functionCall != null) {
        final name = functionCall['name'] as String? ?? '';
        final args = functionCall['args'];
        final arguments =
            args is Map<String, dynamic> ? args : <String, dynamic>{};
        // Gemini 不返回 toolCallId，按 name + 序号生成（与流式解析器一致）
        final count =
            _nameCallCounts.update(name, (v) => v + 1, ifAbsent: () => 0);
        toolCalls.add(
          ToolCall(
            id: count == 0 ? 'gemini_$name' : 'gemini_${name}__$count',
            name: name,
            arguments: arguments,
            thoughtSignature: part['thoughtSignature'] as String?,
          ),
        );
      }
    }

    // 解析 usageMetadata
    final usageMetadata = body['usageMetadata'] as Map<String, dynamic>?;
    LlmUsage? usage;
    if (usageMetadata != null) {
      final prompt = usageMetadata['promptTokenCount'] as int? ?? 0;
      final completion = usageMetadata['candidatesTokenCount'] as int? ?? 0;
      final total =
          usageMetadata['totalTokenCount'] as int? ?? (prompt + completion);
      usage = LlmUsage(
        promptTokens: prompt,
        completionTokens: completion,
        totalTokens: total,
        // Gemini 的 promptTokenCount 已含 cachedContentTokenCount
        totalInputTokens: prompt,
        cacheReadTokens: usageMetadata['cachedContentTokenCount'] as int?,
        reasoningTokens: usageMetadata['thoughtsTokenCount'] as int?,
      );
    }

    // 检测 SAFETY finishReason
    final finishReason = candidate['finishReason'] as String?;
    if (finishReason == 'SAFETY') {
      // 安全过滤拦截，返回空内容 + 在 content 中标注
      // 调用方可通过 content 为空 + finishReason 判断
      return LlmResponse(
        content: '',
        usage: usage,
        finishReason: finishReason,
      );
    }

    return LlmResponse(
      content: textBuffer.toString(),
      usage: usage,
      toolCalls: toolCalls.isEmpty ? null : toolCalls,
      // finishReason 上抛（原样协议值，与流式  词表一致），
      // 截断诊断等消费方据此区分终止语义，不再读后即弃
      finishReason: finishReason,
      // thought 明文仍以 reasoningContent（String）供调用方使用；
      // 带签名的 thought 块以结构化 thinkingBlocks 供多轮原样回传
      reasoningContent:
          thinkingBuffer.isEmpty ? null : thinkingBuffer.toString(),
      thinkingBlocks: thinkingBlocks.isEmpty ? null : thinkingBlocks,
    );
  }

  @override
  String buildModelsUrl(String baseUrl) {
    // Gemini 模型列表端点：{baseUrl}/v1beta/models（同 buildUrl 剥 raw:）
    final rawStripped = baseUrl.startsWith(ApiUrlResolver.rawPrefix)
        ? baseUrl.substring(ApiUrlResolver.rawPrefix.length)
        : baseUrl;
    final cleanBaseUrl = rawStripped.endsWith('/')
        ? rawStripped.substring(0, rawStripped.length - 1)
        : rawStripped;
    final v1betaRoot = cleanBaseUrl.contains('/v1beta')
        ? cleanBaseUrl.replaceAll(RegExp(r'/v1beta(/.*)?$'), '/v1beta')
        : '$cleanBaseUrl/v1beta';
    return _wrapWithProxyIfNeeded('$v1betaRoot/models');
  }

  /// 从 messages 数组中提取 system 消息为 systemInstruction
  ///
  /// Gemini 要求 system 在顶层 `systemInstruction` 字段，不能在 contents 中用
  /// role:"system"。多个 system 消息的文本按顺序拼接（用 \n\n 分隔）。
  ///
  /// 返回格式：`{parts: [{text: "..."}]}`（Gemini 标准结构）
  Map<String, dynamic>? _extractSystemInstruction(
    List<Map<String, dynamic>> messages,
  ) {
    final systemParts = <String>[];
    for (final msg in messages) {
      if (msg['role'] != 'system') continue;
      final content = msg['content'];
      if (content is String && content.isNotEmpty) {
        systemParts.add(content);
      } else if (content is List) {
        final parts = <String>[];
        for (final part in content) {
          if (part is Map<String, dynamic> && part['type'] == 'text') {
            final text = part['text'] as String?;
            if (text != null && text.isNotEmpty) parts.add(text);
          }
        }
        if (parts.isNotEmpty) systemParts.add(parts.join('\n'));
      }
    }
    if (systemParts.isEmpty) return null;
    return {
      'parts': [
        {'text': systemParts.join('\n\n')},
      ],
    };
  }

  /// 过滤掉 system 消息（已提取到 systemInstruction）
  List<Map<String, dynamic>> _filterNonSystemMessages(
    List<Map<String, dynamic>> messages,
  ) {
    return messages.where((m) => m['role'] != 'system').toList();
  }

  /// 转换 OpenAI 风格 messages 为 Gemini contents 数组
  ///
  /// 差异处理：
  /// 1. role: assistant → model, user 保持, tool → user（含 functionResponse）
  /// 2. content String → parts: [{text: "..."}]
  /// 3. tool_calls → parts: [{functionCall: {name, args}}]
  /// 4. role:"tool" 消息 → 含 functionResponse 的 user 消息
  /// 5. thinkingBlocks（含 thoughtSignature）优先 → parts:
  ///    [{thought:true, text, thoughtSignature}]；camel reasoningContent
  ///    分支仅在无 thinkingBlocks 的跨协议夹具下可达（生产 geminiNative
  ///    请求 map 不注入该键），预算估算面按 thinkingBlocks 同口径
  List<Map<String, dynamic>> _convertMessagesToContents(
    List<Map<String, dynamic>> messages,
  ) {
    return messages.map(_convertMessage).toList();
  }

  /// 转换单条消息为 Gemini content 格式
  Map<String, dynamic> _convertMessage(Map<String, dynamic> msg) {
    final role = msg['role'] as String?;
    final content = msg['content'];

    // 工具结果消息：OpenAI role:"tool" → Gemini user + functionResponse part
    if (role == 'tool') {
      final toolCallId = msg['tool_call_id'] as String? ?? '';
      // 从 tool_call_id 提取工具名（Gemini 用 name 而非 id 关联）
      // tool_call_id 格式为 "gemini_{name}"（首次）或 "gemini_{name}__N"
      // （同名第 N 次调用，v0.3 本地序号），统一剥离 __N 后缀取 name
      final toolName = _toolNameFromCallId(toolCallId);
      final resultContent = content is String ? content : '';
      final isError = msg['is_error'] == true;

      return {
        'role': 'user',
        'parts': [
          {
            'functionResponse': {
              'name': toolName,
              'response': isError
                  ? {'error': resultContent}
                  : {'result': resultContent},
            },
          }
        ],
      };
    }

    // assistant 消息 → model 角色
    if (role == 'assistant') {
      final parts = <Map<String, dynamic>>[];

      // thinking 内容回传（置于正文之前：模型原始输出顺序即 thought→text，
      // 官方要求原样回传全部 thought 块，不可删改）
      // 优先使用 thinkingBlocks（结构化，含签名），无则用 reasoningContent（字符串）
      final thinkingBlocks = msg['thinkingBlocks'];
      if (thinkingBlocks is List) {
        for (final tb in thinkingBlocks) {
          if (tb is Map<String, dynamic>) {
            final thinking = tb['thinking'] as String? ?? '';
            if (thinking.isNotEmpty) {
              final signature = tb['signature'] as String?;
              parts.add({
                'thought': true,
                'text': thinking,
                if (signature != null && signature.isNotEmpty)
                  'thoughtSignature': signature,
              });
            }
          }
        }
      } else {
        final reasoningContent = msg['reasoningContent'] as String?;
        if (reasoningContent != null && reasoningContent.isNotEmpty) {
          parts.add({'thought': true, 'text': reasoningContent});
        }
      }

      // 文本内容
      if (content is String && content.isNotEmpty) {
        parts.add({'text': content});
      } else if (content is List) {
        for (final part in content) {
          if (part is Map<String, dynamic> && part['type'] == 'text') {
            final text = part['text'] as String?;
            if (text != null && text.isNotEmpty) {
              parts.add({'text': text});
            }
          }
        }
      }

      // tool_calls → functionCall parts
      final toolCalls = msg['tool_calls'];
      if (toolCalls is List) {
        for (final tc in toolCalls) {
          if (tc is! Map<String, dynamic>) continue;
          final function = tc['function'] as Map<String, dynamic>?;
          final name = function?['name'] as String? ?? '';
          // OpenAI 的 arguments 是 JSON 字符串，Gemini 需要解析为对象
          final rawArgs = function?['arguments'] as String? ?? '{}';
          Map<String, dynamic> args;
          try {
            final decoded = jsonDecode(rawArgs);
            args =
                decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
          } catch (_) {
            args = <String, dynamic>{};
          }
          // Gemini 3 思考签名回传（v0.3）：thoughtSignature 必须原样随
          // tool-call part 回传，否则多轮质量下降（设计报告 §4.3）
          final thoughtSignature = tc['thought_signature'] as String?;
          parts.add({
            'functionCall': {'name': name, 'args': args},
            if (thoughtSignature != null && thoughtSignature.isNotEmpty)
              'thoughtSignature': thoughtSignature,
          });
        }
      }

      return {
        'role': 'model',
        // HAR-02：空 assistant（无正文无 functionCall）置占位空文本
        // part——保消息形状不丢消息（与 Anthropic 空 content 数组同因）。
        'parts': parts.isEmpty
            ? <Map<String, dynamic>>[
                {'text': ''},
              ]
            : parts,
      };
    }

    // user 消息：转换 content 为 parts 数组
    if (role == 'user') {
      final parts = <Map<String, dynamic>>[];
      if (content is String) {
        parts.add({'text': content});
      } else if (content is List) {
        for (final part in content) {
          if (part is Map<String, dynamic>) {
            final type = part['type'];
            if (type == 'text') {
              final text = part['text'] as String?;
              if (text != null && text.isNotEmpty) {
                parts.add({'text': text});
              }
            } else if (type == 'image_url') {
              // OpenAI image_url → Gemini 多模态 part
              // - data: base64 URL → inlineData（mimeType + data）
              // - http(s) URL → 降级为文本提示：Gemini 的 fileData.fileUri
              //   仅接受 Files API / gs:// URI（官方契约），任意 http(s)
              //   图片地址直传必 400——宁可让模型知道图未被发送，
              //   不可静默丢弃（原实现丢弃导致 vision 实测恒真）。
              final imageUrl = part['image_url'];
              if (imageUrl is Map<String, dynamic>) {
                final url = imageUrl['url'] as String?;
                if (url != null && url.isNotEmpty) {
                  final inlinePart = _inlineDataFromDataUrl(url);
                  if (inlinePart != null) {
                    parts.add(inlinePart);
                  } else {
                    parts.add({'text': '（图片附件未随请求发送：$url）'});
                  }
                }
              }
            }
          }
        }
      }
      return {
        'role': 'user',
        'parts': parts.isEmpty ? <Map<String, dynamic>>[] : parts,
      };
    }

    // 其他 role 兜底
    return msg;
  }

  /// `data:<mimeType>;base64,<data>` 内联图 URL → Gemini inlineData part
  ///
  /// 非 data: URL 或非 base64 / 缺 mimeType 的形态返回 null，由调用方降级。
  static Map<String, dynamic>? _inlineDataFromDataUrl(String url) {
    if (!url.startsWith('data:')) return null;
    final commaIndex = url.indexOf(',');
    if (commaIndex == -1) return null;
    final meta = url.substring(5, commaIndex);
    final data = url.substring(commaIndex + 1);
    if (!meta.toLowerCase().endsWith(';base64')) return null;
    final mimeType = meta.substring(0, meta.length - ';base64'.length);
    if (mimeType.isEmpty) return null;
    return {
      'inlineData': {'mimeType': mimeType, 'data': data},
    };
  }

  /// 转换 ToolChoice 为 Gemini toolConfig.functionCallingConfig
  ///
  /// OpenAI: "auto"/"required"/"none"
  /// Gemini: {mode: "AUTO"/"ANY"/"NONE", allowedFunctionNames?: [...]}
  Map<String, dynamic> _convertToolChoice(ToolChoice toolChoice) {
    return switch (toolChoice) {
      ToolChoice.auto => {'mode': 'AUTO'},
      ToolChoice.required => {'mode': 'ANY'},
      ToolChoice.none => {'mode': 'NONE'},
    };
  }

  /// 转换 LlmResponseFormat 为 Gemini generationConfig 字段
  ///
  /// Gemini 不支持 OpenAI 的 response_format，但有原生结构化输出方式：
  /// - json_object → responseMimeType: "application/json"
  /// - json_schema → responseMimeType: "application/json" + responseSchema
  Map<String, dynamic> _convertResponseFormat(LlmResponseFormat format) {
    return switch (format) {
      LlmResponseFormatJsonObject() => {
          'responseMimeType': 'application/json',
        },
      LlmResponseFormatJsonSchema(:final schema) => {
          'responseMimeType': 'application/json',
          'responseSchema': toGeminiSchema(schema),
        },
    };
  }

  /// 构建 thinkingConfig（Gemini thinking 双轨制）
  ///
  /// 优先级（DOC-12 §7，2026-07-28 修订）：
  /// 1. `reasoningEffort == disabled`（显式禁用）→ 按 modelId 发送显式关闭参数，
  ///    优先级最高，覆盖 providerOptions 透传。与 ThinkingParamBuilder 对齐。
  ///    - Gemini 3.x：`thinkingLevel:off`
  ///    - Gemini 2.5/2.0：`thinkingBudget:0`
  /// 2. providerOptions.thinkingConfig（调用方显式配置）
  /// 3. 根据 reasoningEffort + 模型 ID 自动映射
  ///    - Gemini 3.x：用 `thinkingLevel`（low/medium/high）
  ///    - Gemini 2.5.x：用 `thinkingBudget`（int，0=禁用，-1=自动，正数=token 预算）
  ///    - 其他：不注入 thinkingConfig
  ///
  /// maxTokens 过小时一律不发 thinking——Gemini 要求
  /// thinkingBudget < maxOutputTokens，而正数预算协议下限为 128，
  /// maxTokens ≤ 128 时任何 thinking 配置都可能与预算冲突（模型实测的
  /// maxTokens=1/10/50 探针遇用户大预算 thinkingConfig 必然 400，误判
  /// 「模型不可用」）。与 Anthropic 适配器 S-2 护栏同构；显式禁用
  /// （优先级 1）不受影响——thinkingBudget:0 / thinkingLevel:off 恒合法。
  Map<String, dynamic>? _buildThinkingConfig(LlmRequest request) {
    final effort = request.reasoningEffort;
    final modelId = request.modelId;

    // 优先级 1：显式禁用，覆盖 providerOptions（2026-07-28 修复，与 ThinkingParamBuilder 对齐）
    // Gemini 2.5/3.x 默认开启思考，必须发送显式关闭参数才能停止
    //
    // 2026-09-08 修复：gemini-3* 一律用 thinkingBudget:0 禁用——真机实测
    // gemini-3.8-flash 对 thinkingLevel:"off" 返回 400 INVALID_ARGUMENT
    // （ThinkingLevel 枚举不含 off/minimal，合法值仅 low/medium/high），
    // 而 thinkingBudget:0 在 3.x 与 2.5 均被接受且语义就是关闭思考。
    if (effort == ReasoningEffort.disabled) {
      if (modelId.contains('gemini-3') ||
          modelId.contains('gemini-4') ||
          modelId.contains('gemini-2.5') ||
          modelId.contains('gemini-2.0')) {
        return {'thinkingBudget': 0};
      }
      return null;
    }

    // 极小 maxTokens（能力探测等）跳过 thinking 透传与自动映射
    final maxTokens = request.maxTokens;
    if (maxTokens != null && maxTokens <= _minThinkingMaxTokens) return null;

    // 优先级 2：providerOptions 显式配置（仅在用户未显式禁用时生效）
    final providerThinking = request.providerOptions?['thinkingConfig'];
    if (providerThinking is Map<String, dynamic>) {
      return providerThinking;
    }

    // 优先级 3：根据 reasoningEffort + 模型 ID 自动映射
    if (effort == null) return null;

    // Gemini 3.x / 4 用 thinkingLevel（4 系大小写与 budget:0 实测行为待核，
    // 先与 3 系同轨保守处理）
    if (modelId.contains('gemini-3') || modelId.contains('gemini-4')) {
      final level = switch (effort) {
        ReasoningEffort.low => 'low',
        ReasoningEffort.medium => 'medium',
        ReasoningEffort.high => 'high',
        ReasoningEffort.disabled => 'off',
      };
      return {'thinkingLevel': level};
    }

    // Gemini 2.5.x 用 thinkingBudget
    if (modelId.contains('gemini-2.5') || modelId.contains('gemini-2.0')) {
      final budget = switch (effort) {
        ReasoningEffort.low => 1024,
        ReasoningEffort.medium => 8192,
        ReasoningEffort.high => 24576,
        ReasoningEffort.disabled => 0,
      };
      // thinkingBudget 须小于
      // maxOutputTokens——medium=8192 恰等于常见 maxTokens 默认值、
      // high=24576 直接越界，均 400 INVALID_ARGUMENT。钳到
      // maxTokens-1024（正文余量），钳后低于 low 档 1024 则不发
      // thinkingConfig（交模型默认动态思考，好过必 400）。
      if (maxTokens != null) {
        final capped = maxTokens - 1024;
        if (capped < 1024) return null;
        return {'thinkingBudget': budget < capped ? budget : capped};
      }
      return {'thinkingBudget': budget};
    }

    // 其他模型不注入 thinkingConfig
    return null;
  }

  /// Web 平台 CORS 代理包装（与 ApiUrlResolver._wrapWithProxyIfNeeded 一致）
  ///
  /// Gemini 的 URL 构造逻辑特殊（含 modelId 在路径中），不能直接复用
  /// ApiUrlResolver.resolve，但 Web 平台仍需 CORS 代理。
  static String _wrapWithProxyIfNeeded(String targetUrl) {
    if (!_isWebPlatform) return targetUrl;
    if (!targetUrl.startsWith('http://') && !targetUrl.startsWith('https://')) {
      return targetUrl;
    }
    return '/api-proxy?url=${Uri.encodeComponent(targetUrl)}';
  }

  /// Web 平台检测（避免引入 Flutter foundation 依赖，用条件编译常量）
  ///
  /// 与 ApiUrlResolver 中的 kIsWeb 等价，但 GeminiAdapter 不依赖 Flutter。
  /// 编译期常量，原生平台编译时此分支被完全移除。
  static const bool _isWebPlatform =
      bool.fromEnvironment('dart.library.js_util');
}
