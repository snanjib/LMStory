import 'dart:async';
import 'dart:convert';
import 'package:lmstory/core/config/output_token_policy.dart';
import 'package:lmstory/core/llm/reasoning_effort.dart';
import 'package:lmstory/core/llm/tool_calling/tool_call.dart';
import 'package:lmstory/core/llm/tool_calling/tool_choice.dart';
import 'package:lmstory/core/network/llm_adapters/llm_protocol_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/sampling_params.dart';
import 'package:lmstory/core/network/sse/anthropic_sse_parser.dart';
import 'package:lmstory/core/utils/api_url_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Anthropic Claude 原生协议适配器
///
/// 适用供应商：Anthropic Claude 系列（claude-opus-4-6 / claude-sonnet-4-6 /
/// claude-haiku-4-5 等）
///
/// 端点：`POST /messages`（版本号由 baseUrl 携带，见 ApiUrlResolver；
/// 流式与非流式同端点，靠 `stream` 字段切换）
/// 认证：`x-api-key: {apiKey}` + `anthropic-version: 2023-06-01`（必需）
/// SSE：`event: {type}\ndata: {json}\n\n`，6 事件类型，无 `[DONE]`，
/// 靠 `message_stop` 事件结束流。
///
/// 关键差异处理（DOC-12 §5.4.4）：
/// 1. **system 顶层字段**：OpenAI 风格的 `role:"system"` 消息需提取到顶层 `system` 字段
/// 2. **max_tokens 必填**：显式配置 0 时使用模型最大输出元数据；缺失元数据则明确报错
/// 3. **tools 字段格式**：用 `input_schema` 而非 `parameters`，无 `type:"function"` 包裹
/// 4. **tool_choice 格式**：`{type:"auto"|"any"|"tool", name?:...}` 而非字符串
/// 5. **工具调用位置**：响应 `content[]` 中的 `tool_use` block（非 `message.tool_calls`）
/// 6. **工具结果位置**：下一条 user 消息 `content` 中的 `tool_result` block
/// 7. **thinking signature**：跨轮回传必须完整保留（通过 [LlmThinkingBlockComplete] 上抛）
/// 8. **不支持 response_format**：忽略 [LlmRequest.responseFormat]，由调用方通过
///    strict tool 或提示词约束结构化输出
/// 9. **不支持 presence_penalty/frequency_penalty**：忽略这两个参数
///
/// 实现依据：DOC-12 §5.2 + §5.4.4 + §5.5 + Anthropic 官方文档（2026-07-24 调研）。
class AnthropicAdapter implements LlmProtocolAdapter {
  /// [sseParserFactory] 用于创建每次流式解析所需的 [AnthropicSseParser] 实例。
  ///
  /// **必须每次调用创建新实例**：[AnthropicSseParser] 内部维护可变状态
  /// （`_blocks` / `_streamStopped` / `_inputTokens` / `_outputTokens`），
  /// 在 `parse()` 入口重置。若多个流式请求共享同一实例（适配器是工厂单例），
  /// 并发流的 `parse()` 会互相重置状态，导致工具调用丢失、thinking signature
  /// 错乱、usage 数据污染。默认工厂 `AnthropicSseParser.new` 保证每流一实例。
  AnthropicAdapter({AnthropicSseParser Function()? sseParserFactory})
      : _sseParserFactory = sseParserFactory ?? AnthropicSseParser.new;

  final AnthropicSseParser Function() _sseParserFactory;

  /// thinking 合法所需的 max_tokens 下限（budget_tokens ≥ 1024 且
  /// max_tokens > budget_tokens，见 _buildThinkingConfig 的 S-2 说明）
  static const int _minThinkingMaxTokens = 1024;

  /// Anthropic API 版本（必需 header，2026-07 调研为 2023-06-01）
  static const String _anthropicVersion = '2023-06-01';

  /// 默认 max_tokens（Anthropic 必填字段，调用方未提供时使用）
  ///
  /// 8192 与故事模式的新默认值一致。显式配置 0 时不会使用此兜底，而是要求
  /// 模型元数据提供 maxOutput，避免把“不设应用层上限”静默降级为固定上限。
  /// 调用方应尽量通过 [LlmRequest.maxTokens] 显式传入。
  static const int _defaultMaxTokens = OutputTokenPolicy.storyDefaultLimit;

  @override
  String buildUrl(String baseUrl, String modelId, {required bool stream}) {
    return ApiUrlResolver.resolve(baseUrl, '/messages');
  }

  @override
  Map<String, String> buildHeaders(
    LlmRequest request, {
    Map<String, String>? extra,
  }) {
    final apiKey = request.apiKey;
    // 从 providerOptions 提取 beta 特性标识（如 interleaved-thinking-2025-05-14）
    final betaFlags =
        (request.providerOptions?['anthropic_beta'] as List<dynamic>?)
                ?.cast<String>() ??
            const <String>[];

    return {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'anthropic-version': _anthropicVersion,
      if (apiKey != null && apiKey.isNotEmpty) 'x-api-key': apiKey,
      if (betaFlags.isNotEmpty) 'anthropic-beta': betaFlags.join(', '),
      ...?extra,
    };
  }

  @override
  Map<String, dynamic> buildRequestBody(
    LlmRequest request, {
    required bool stream,
  }) {
    // 提取 system 消息到顶层字段（Anthropic 要求 system 必须在顶层）
    final messages = request.messages;
    final systemTexts = _extractSystemTexts(messages);
    final filteredMessages = _filterNonSystemMessages(messages);

    // 转换 OpenAI 风格 messages 为 Anthropic 风格
    // - 工具调用结果：role:"tool" → role:"user" + content:[{type:"tool_result",...}]
    // - assistant 工具调用：message.tool_calls → content:[{type:"tool_use",...}]
    // - 思考内容回传：reasoning_content/thinkingBlocks → content 中的 thinking block
    final anthropicMessages = _convertMessages(filteredMessages);

    final configuredMaxTokens = request.maxTokens;
    final int effectiveMaxTokens;
    if (configuredMaxTokens != null && configuredMaxTokens <= 0) {
      final modelMaxOutput = request.modelMaxOutputTokens;
      if (modelMaxOutput == null || modelMaxOutput <= 0) {
        throw ArgumentError(t.common.errors.anthropicMaxTokens);
      }
      effectiveMaxTokens = modelMaxOutput;
    } else {
      effectiveMaxTokens = OutputTokenPolicy.clampToModel(
            configuredMaxTokens,
            request.modelMaxOutputTokens,
          ) ??
          _defaultMaxTokens;
    }

    final body = <String, dynamic>{
      'model': request.modelId,
      'messages': anthropicMessages,
      'stream': stream,
      // Anthropic max_tokens 必填
      'max_tokens': effectiveMaxTokens,
    };

    // system 顶层字段
    // 2026-08-15（v0.3）：带工具的请求（agent loop）自动打缓存断点。
    // 2026-09-02：system 改为**每条源 system 消息一个
    // 内容块**（保序不合并），断点分层下放——冻结前缀块（第 0 条）与最新
    // 可变块（末条）末尾各一个断点，叠加倒数第二条消息断点（opencode 同款
    // 策略）。此前全部 system 合并成单串只打一个断点，导演模式第 1 条
    // system（core blocks，每轮可变）一变就作废整个 system 及其后全部历史
    // 缓存；分离后 core blocks 变化只重算自身段，冻结前缀与既有历史前缀
    // 照常命中。断点总数上限 4：≤3 块时逐块打断点，超过时只保首块与末块。
    if (systemTexts.isNotEmpty) {
      final useCacheBreakpoints = request.tools != null;
      body['system'] = useCacheBreakpoints
          ? _buildSystemBlocks(systemTexts)
          : systemTexts.join('\n\n');
    }
    // 消息区断点对无工具请求
    // （chat 模式）同样开放——此前条件 request.tools != null 让普通对话
    // 完全零断点，跨轮缓存全无。断点锚定上一轮结束的消息边界（倒数
    // 第二条），其前缀（含 system）整体入缓存；带工具请求维持既有分层
    // （system 块断点+消息区断点，总数恰在 4 上限内，不得超限硬发）。
    if (anthropicMessages.isNotEmpty) {
      _markAnthropicCacheBreakpoint(anthropicMessages);
    }

    // 采样参数（Anthropic 支持 temperature/top_p，但不支持 presence/frequency penalty）
    // 出网前统一取整到 2 位小数：滑块浮点尾差会被按位数校验的厂商 400
    if (request.temperature != null) {
      body['temperature'] = sanitizeSamplingParam(request.temperature);
    }
    if (request.topP != null) {
      body['top_p'] = sanitizeSamplingParam(request.topP);
    }

    // 工具定义（Anthropic 用 input_schema，无 type:"function" 包裹）
    if (request.tools != null && request.tools!.isNotEmpty) {
      body['tools'] = request.tools!
          .map(
            (t) => {
              'name': t.name,
              'description': t.description,
              'input_schema': t.parameters,
            },
          )
          .toList();
    }

    // 工具选择策略
    if (request.toolChoice != null) {
      body['tool_choice'] = _convertToolChoice(request.toolChoice!);
    }

    // thinking 参数（从 providerOptions 提取，或根据 reasoningEffort 自动映射）
    final thinkingConfig = _buildThinkingConfig(request);
    if (thinkingConfig != null) {
      body['thinking'] = thinkingConfig;
    }

    // 注意：Anthropic 不支持 response_format，忽略此字段
    // 调用方需通过 strict tool 或提示词约束结构化输出

    return body;
  }

  @override
  Stream<LlmStreamEvent> parseStream(Stream<String> rawStream) {
    // 每次调用创建新的解析器实例，避免并发流共享可变状态。
    // 适配器本身是单例（LlmAdapterFactory 持有），若复用同一解析器实例，
    // 两个并发的流式请求会互相覆盖 _blocks / _streamStopped 等状态。
    return _sseParserFactory().parse(rawStream);
  }

  @override
  LlmResponse parseResponse(Map<String, dynamic> body) {
    // Anthropic 非流式响应结构：
    // {
    //   "id": "msg_xxx",
    //   "type": "message",
    //   "role": "assistant",
    //   "content": [
    //     {"type": "text", "text": "..."},
    //     {"type": "thinking", "thinking": "...", "signature": "..."},
    //     {"type": "tool_use", "id": "toolu_xxx", "name": "...", "input": {...}}
    //   ],
    //   "stop_reason": "end_turn"|"tool_use"|"max_tokens"|...,
    //   "usage": {"input_tokens": 10, "output_tokens": 20}
    // }

    final contentBlocks = body['content'] as List<dynamic>? ?? [];
    final textBuffer = StringBuffer();
    final thinkingBlocks = <LlmThinkingBlock>[];
    final toolCalls = <ToolCall>[];

    for (final block in contentBlocks) {
      if (block is! Map<String, dynamic>) continue;
      final type = block['type'] as String?;

      switch (type) {
        case 'text':
          final text = block['text'] as String? ?? '';
          if (text.isNotEmpty) {
            textBuffer.write(text);
          }
        case 'thinking':
          final thinking = block['thinking'] as String? ?? '';
          final signature = block['signature'] as String? ?? '';
          if (thinking.isNotEmpty || signature.isNotEmpty) {
            thinkingBlocks.add(
              LlmThinkingBlock(
                thinking: thinking,
                signature: signature,
              ),
            );
          }
        case 'tool_use':
          final id = block['id'] as String? ?? '';
          final name = block['name'] as String? ?? '';
          final input = block['input'];
          final arguments =
              input is Map<String, dynamic> ? input : <String, dynamic>{};
          toolCalls.add(
            ToolCall(
              id: id,
              name: name,
              arguments: arguments,
            ),
          );
      }
    }

    // 解析 usage（Anthropic 用 input_tokens/output_tokens，无 total_tokens）
    final usageJson = body['usage'] as Map<String, dynamic>?;
    LlmUsage? usage;
    if (usageJson != null) {
      final inputTokens = usageJson['input_tokens'] as int? ?? 0;
      final outputTokens = usageJson['output_tokens'] as int? ?? 0;
      usage = LlmUsage(
        promptTokens: inputTokens,
        completionTokens: outputTokens,
        totalTokens: inputTokens + outputTokens,
        // v0.3 ：缓存命中计量（agent loop 成本观测）
        cacheReadTokens: usageJson['cache_read_input_tokens'] as int?,
        cacheCreationTokens: usageJson['cache_creation_input_tokens'] as int?,
      );
    }

    return LlmResponse(
      content: textBuffer.toString(),
      usage: usage,
      toolCalls: toolCalls.isEmpty ? null : toolCalls,
      // Anthropic 使用 thinkingBlocks（结构化 + signature），不用 reasoningContent
      thinkingBlocks: thinkingBlocks.isEmpty ? null : thinkingBlocks,
      // XC-2：stop_reason 映射为统一 finishReason 词表（max_tokens→length 等），
      // 截断/安全终止诊断对 Anthropic 端点生效
      finishReason: AnthropicSseParser.mapStopReasonToFinishReason(
        body['stop_reason'] as String?,
      ),
    );
  }

  @override
  String buildModelsUrl(String baseUrl) {
    // Anthropic 模型列表端点：{baseUrl}/models
    return ApiUrlResolver.resolve(baseUrl, '/models');
  }

  /// 在倒数第二条消息的最后一个 content block 打 cache_control 断点
  ///
  /// append-only 历史下该断点覆盖"既有前缀"：新追加的尾部消息不遮蔽
  /// 上一轮的缓存。消息 content 已是 block 数组（_convertMessage 产物）；
  /// String content（user 消息本可块化，转换层保持字符串直传）仅在此处
  /// 包成 [{type:'text', text:...}] 再打断点，否则会被静默跳过、断点丢失。
  static void _markAnthropicCacheBreakpoint(
    List<Map<String, dynamic>> messages,
  ) {
    if (messages.length < 2) return;
    final index = messages.length - 2;
    final target = messages[index];
    final content = target['content'];
    // 浅拷贝替换（user 消息与请求共享 map 实例，不原地改写调用方数据）
    if (content is String && content.isNotEmpty) {
      messages[index] = <String, dynamic>{
        ...target,
        'content': <Map<String, dynamic>>[
          {
            'type': 'text',
            'text': content,
            'cache_control': {'type': 'ephemeral'},
          },
        ],
      };
      return;
    }
    if (content is List && content.isNotEmpty) {
      final lastBlock = content.last;
      if (lastBlock is Map<String, dynamic>) {
        lastBlock['cache_control'] = {'type': 'ephemeral'};
      }
    }
  }

  /// 从 messages 数组中按序提取各 system 消息的文本（每条一块，不合并）
  ///
  /// Anthropic 要求 system 必须在顶层字段，不能在 messages 中用 role:"system"。
  /// 保持每条源 system 消息独立（缓存断点分层的载体，见 [buildRequestBody]）。
  /// system 消息的 content 可能是 String 或 List（vision 格式），这里只处理文本。
  List<String> _extractSystemTexts(List<Map<String, dynamic>> messages) {
    final systemTexts = <String>[];
    for (final msg in messages) {
      if (msg['role'] != 'system') continue;
      final content = msg['content'];
      if (content is String && content.isNotEmpty) {
        systemTexts.add(content);
      } else if (content is List) {
        // system 消息的 content 数组形式（多模态），提取 text 部分
        final parts = <String>[];
        for (final part in content) {
          if (part is Map<String, dynamic> && part['type'] == 'text') {
            final text = part['text'] as String?;
            if (text != null && text.isNotEmpty) parts.add(text);
          }
        }
        if (parts.isNotEmpty) systemTexts.add(parts.join('\n'));
      }
    }
    return systemTexts;
  }

  /// system 文本列表 → Anthropic 内容块数组（分层缓存断点）
  ///
  /// 断点预算：Anthropic 上限 4 个 cache_control，本方法最多占 3 个，
  /// 留 1 个给"倒数第二条消息"断点。块数 ≤3 时逐块末尾打断点（最大化
  /// 分段命中）；超过时只给首块（冻结前缀）与末块（最新可变块）打断点，
  /// 中间块保持原序无断点。
  static List<Map<String, dynamic>> _buildSystemBlocks(List<String> texts) {
    return [
      for (var i = 0; i < texts.length; i++)
        {
          'type': 'text',
          'text': texts[i],
          if (texts.length <= 3 || i == 0 || i == texts.length - 1)
            'cache_control': {'type': 'ephemeral'},
        },
    ];
  }

  /// 过滤掉 system 消息（已提取到顶层）
  List<Map<String, dynamic>> _filterNonSystemMessages(
    List<Map<String, dynamic>> messages,
  ) {
    return messages.where((m) => m['role'] != 'system').toList();
  }

  /// 转换 OpenAI 风格 messages 为 Anthropic 风格
  ///
  /// 处理以下差异：
  /// 1. role:"tool" → role:"user" + content:[{type:"tool_result", tool_use_id, content}]
  /// 2. assistant 消息的 tool_calls → content 数组中的 tool_use block
  /// 3. assistant 消息的 thinkingBlocks → content 数组中的 thinking block（含 signature）
  /// 4. assistant 消息的 reasoning_content → 转换为 thinking block（但无 signature，
  ///    仅当 thinkingBlocks 不存在时使用，这种情况一般来自跨协议回传，不推荐）
  List<Map<String, dynamic>> _convertMessages(
    List<Map<String, dynamic>> messages,
  ) {
    return messages.map(_convertMessage).toList();
  }

  /// 转换单条消息
  Map<String, dynamic> _convertMessage(Map<String, dynamic> msg) {
    final role = msg['role'] as String?;
    final content = msg['content'];

    // 工具结果消息：OpenAI role:"tool" → Anthropic role:"user" + tool_result block
    if (role == 'tool') {
      final toolCallId = msg['tool_call_id'] as String? ?? '';
      final resultContent = content is String ? content : '';
      return {
        'role': 'user',
        'content': [
          {
            'type': 'tool_result',
            'tool_use_id': toolCallId,
            'content': resultContent,
          }
        ],
      };
    }

    // assistant 消息：处理 tool_calls 和 thinking 回传
    if (role == 'assistant') {
      final blocks = <Map<String, dynamic>>[];

      // 文本内容
      if (content is String && content.isNotEmpty) {
        blocks.add({'type': 'text', 'text': content});
      } else if (content is List) {
        for (final part in content) {
          if (part is Map<String, dynamic> && part['type'] == 'text') {
            final text = part['text'] as String?;
            if (text != null && text.isNotEmpty) {
              blocks.add({'type': 'text', 'text': text});
            }
          }
        }
      }

      // thinking blocks 回传（含 signature，跨轮必需）
      // 优先使用 thinkingBlocks（结构化），无则尝试 reasoning_content（降级）
      final thinkingBlocks = msg['thinkingBlocks'];
      if (thinkingBlocks is List && thinkingBlocks.isNotEmpty) {
        for (final tb in thinkingBlocks) {
          if (tb is Map<String, dynamic>) {
            blocks.add({
              'type': 'thinking',
              'thinking': tb['thinking'] ?? '',
              'signature': tb['signature'] ?? '',
            });
          }
        }
      } else {
        // 降级：reasoning_content 是 String，无 signature
        // 这种情况一般来自跨协议回传（如 DeepSeek → Claude），signature 缺失
        // Anthropic 服务端会验证失败，但这里仍尝试发送（让 API 报错以暴露问题）
        final reasoningContent = msg['reasoningContent'] as String?;
        if (reasoningContent != null && reasoningContent.isNotEmpty) {
          blocks.add({
            'type': 'thinking',
            'thinking': reasoningContent,
            'signature': '', // 缺失 signature，API 会报错
          });
        }
      }

      // tool_calls → tool_use blocks
      final toolCalls = msg['tool_calls'];
      if (toolCalls is List) {
        for (final tc in toolCalls) {
          if (tc is! Map<String, dynamic>) continue;
          final function = tc['function'] as Map<String, dynamic>?;
          final id = tc['id'] as String? ?? '';
          final name = function?['name'] as String? ?? '';
          // OpenAI 的 arguments 是 JSON 字符串，Anthropic 需要解析为对象
          final rawArgs = function?['arguments'] as String? ?? '{}';
          Map<String, dynamic> input;
          try {
            final decoded = jsonDecode(rawArgs);
            input =
                decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
          } catch (_) {
            input = <String, dynamic>{};
          }
          blocks.add({
            'type': 'tool_use',
            'id': id,
            'name': name,
            'input': input,
          });
        }
      }

      return {
        'role': 'assistant',
        'content': blocks.isEmpty ? <Map<String, dynamic>>[] : blocks,
      };
    }

    // user 消息：content 数组需对齐 Anthropic block 格式
    if (role == 'user') {
      // user 的 content 可能是 String 或 List（多模态）
      // String 形式 Anthropic 也接受，直接返回
      if (content is! List) return msg;

      // CF-1：OpenAI 风格 image_url 不是 Anthropic 合法 content block 类型，
      // 原样透传必 400。仅当消息携带 image_url 时重建 block 数组，
      // 纯文本消息保持原样透传（零行为差异）。
      final hasImageUrl = content.any(
        (part) => part is Map<String, dynamic> && part['type'] == 'image_url',
      );
      if (!hasImageUrl) return msg;

      final blocks = <Map<String, dynamic>>[];
      for (final part in content) {
        if (part is! Map<String, dynamic>) {
          continue;
        }
        if (part['type'] == 'image_url') {
          final imageBlock = _convertImageUrlBlock(part['image_url']);
          if (imageBlock != null) {
            blocks.add(imageBlock);
          }
        } else {
          // text 等其余 block 原样保留（保序）
          blocks.add(part);
        }
      }
      return {...msg, 'content': blocks};
    }

    // 其他 role（如 system 已被过滤，这里兜底）
    return msg;
  }

  /// OpenAI `image_url` part → Anthropic image block（CF-1）
  ///
  /// 两种形态：
  /// - `data:<mediaType>;base64,<data>` 内联图 →
  ///   `{type:'image', source:{type:'base64', media_type, data}}`
  /// - `http(s)://...` 远程图 → `{type:'image', source:{type:'url', url}}`
  ///   （Anthropic 2025-05 起支持 URL source）
  /// 其余形态（缺 url / 非 base64 data URL）返回 null，由调用方忽略。
  static Map<String, dynamic>? _convertImageUrlBlock(Object? imageUrl) {
    if (imageUrl is! Map<String, dynamic>) return null;
    final url = imageUrl['url'] as String?;
    if (url == null || url.isEmpty) return null;
    if (url.startsWith('data:')) {
      final commaIndex = url.indexOf(',');
      if (commaIndex == -1) return null;
      final meta = url.substring(5, commaIndex);
      final data = url.substring(commaIndex + 1);
      // Anthropic 仅支持 base64 内联 source
      if (!meta.toLowerCase().endsWith(';base64')) return null;
      final mediaType = meta.substring(0, meta.length - ';base64'.length);
      if (mediaType.isEmpty) return null;
      return {
        'type': 'image',
        'source': {
          'type': 'base64',
          'media_type': mediaType,
          'data': data,
        },
      };
    }
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return {
        'type': 'image',
        'source': {'type': 'url', 'url': url},
      };
    }
    return null;
  }

  /// 转换 ToolChoice 枚举为 Anthropic 格式
  ///
  /// OpenAI: "auto"/"required"/"none"
  /// Anthropic: {"type":"auto"}/{"type":"any"}/{"type":"tool","name":"..."}
  ///
  /// 注意：Anthropic 无 "none" 对应，"none" 映射到 "auto"（让 LLM 自行不调用）
  /// 调用方若需严格禁止工具调用，应不传 tools 参数。
  Map<String, dynamic> _convertToolChoice(ToolChoice toolChoice) {
    return switch (toolChoice) {
      ToolChoice.auto => {'type': 'auto'},
      ToolChoice.required => {'type': 'any'},
      ToolChoice.none => {'type': 'auto'}, // 降级处理
    };
  }

  /// 构建 thinking 配置
  ///
  /// 优先级（DOC-12 §7，2026-07-28 修订）：
  /// 1. `reasoningEffort == disabled`（显式禁用）→ 返回 null（Claude 默认不思考），
  ///    优先级最高，覆盖 providerOptions 透传。与 ThinkingParamBuilder 对齐。
  /// 2. providerOptions.thinking（调用方显式配置，如 `{type:enabled, budget_tokens:2000}`）
  /// 3. 根据 reasoningEffort 自动映射（low=2000, medium=10000, high=32000）
  /// 4. null（不启用 thinking）
  ///
  /// S-2：max_tokens 过小时一律不发 thinking——Anthropic 要求
  /// max_tokens > budget_tokens ≥ 1024，max_tokens ≤ 1024 时任何 thinking
  /// 配置都必然 400（模型实测的 maxTokens=1 探测会误判「模型不可用」）。
  Map<String, dynamic>? _buildThinkingConfig(LlmRequest request) {
    // 优先级 1：显式禁用，覆盖 providerOptions（2026-07-28 修复，与 ThinkingParamBuilder 对齐）
    // Claude 默认不思考，disabled 时直接返回 null（不发 thinking 参数）
    final effort = request.reasoningEffort;
    if (effort == ReasoningEffort.disabled) return null;

    // 极小 max_tokens（能力探测等）：跳过 thinking 透传与自动映射
    final maxTokens = request.maxTokens;
    if (maxTokens != null && maxTokens <= _minThinkingMaxTokens) return null;

    // 优先级 2：providerOptions 显式配置（仅在用户未显式禁用时生效）
    final providerThinking = request.providerOptions?['thinking'];
    if (providerThinking is Map<String, dynamic>) {
      return providerThinking;
    }

    // 优先级 3：根据 reasoningEffort 自动映射
    if (effort == null || !effort.isEnabled) return null;

    final budgetTokens = switch (effort) {
      ReasoningEffort.low => 2000,
      ReasoningEffort.medium => 10000,
      ReasoningEffort.high => 32000,
      ReasoningEffort.disabled => null,
    };

    if (budgetTokens == null) return null;

    // 预算必须严格小于 max_tokens——
    // S-2 只挡了 ≤1024 的探测场景；常规 maxTokens（如 8192）下
    // medium=10000/high=32000 直接越界，Anthropic 必回 400。钳制：
    // 上限 maxTokens-1024（给正文留最低产出余量），钳后低于硬下限
    // 1024 则放弃 thinking（输出预算本就容不下有效思考）。
    if (maxTokens != null) {
      final capped = maxTokens - 1024;
      if (capped < _minThinkingMaxTokens) return null;
      return {
        'type': 'enabled',
        'budget_tokens': budgetTokens < capped ? budgetTokens : capped,
      };
    }

    return {
      'type': 'enabled',
      'budget_tokens': budgetTokens,
    };
  }
}
