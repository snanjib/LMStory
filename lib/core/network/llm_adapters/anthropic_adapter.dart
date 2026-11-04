import 'dart:async';
import 'dart:convert';
import 'package:lmstory/core/llm/llm_content_block.dart';
import 'package:lmstory/core/llm/tool_calling/tool_call.dart';
import 'package:lmstory/core/llm/tool_calling/tool_choice.dart';
import 'package:lmstory/core/network/llm_adapters/anthropic_compat_options.dart';
import 'package:lmstory/core/network/llm_adapters/llm_protocol_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/sampling_params.dart';
import 'package:lmstory/core/network/sse/anthropic_sse_parser.dart';
import 'package:lmstory/core/utils/api_url_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// Anthropic Claude 原生协议适配器
///
/// 适用供应商：Anthropic Claude 系列（claude-opus-4-6 / claude-sonnet-4-6 /
/// claude-haiku-4-5 等）
///
/// 端点：`POST /messages`（版本号由 baseUrl 携带，见 ApiUrlResolver；
/// 流式与非流式同端点，靠 `stream` 字段切换）
/// 认证：`x-api-key: {apiKey}` + `anthropic-version`（由
/// [AnthropicCompatOptions] 按官方/第三方端点决定）
/// SSE：`event: {type}\ndata: {json}\n\n`，6 事件类型，无 `[DONE]`，
/// 靠 `message_stop` 事件结束流。
///
/// 关键差异处理：
/// 1. **system 顶层字段**：OpenAI 风格的 `role:"system"` 消息需提取到顶层 `system` 字段
/// 2. **max_tokens 必填**：配置 0/null 时优先用模型最大输出；缺失元数据回退 8192
/// 3. **tools 字段格式**：用 `input_schema` 而非 `parameters`，无 `type:"function"` 包裹
/// 4. **tool_choice 格式**：`{type:"auto"|"any"|"none"}` 而非字符串
/// 5. **工具调用位置**：响应 `content[]` 中的 `tool_use` block（非 `message.tool_calls`）
/// 6. **工具结果位置**：下一条 user 消息 `content` 中的 `tool_result` block
/// 7. **thinking block 保真**：优先使用有序 `anthropicBlocks` 回传，含
///    `redacted_thinking`；旧数据按 thinking→text→tool_use 回退
/// 8. **sampling/thinking 形态**：Anthropic 分支不再读模型名，由
///    [AnthropicCompatOptions] 的端点画像决定
/// 9. **不支持 presence_penalty/frequency_penalty**：忽略这两个参数
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

  /// 极小 max_tokens（能力探测等）不发送 thinking 的下限。
  static const int _minThinkingMaxTokens = 1024;

  /// 不可打 cache_control 的 block 类型（Anthropic 只允许可缓存 block）。
  static const Set<String> _nonCacheableBlockTypes = {
    'thinking',
    'redacted_thinking',
  };

  @override
  String buildUrl(String baseUrl, String modelId, {required bool stream}) {
    return ApiUrlResolver.resolve(baseUrl, '/messages');
  }

  @override
  Map<String, String> buildHeaders(
    LlmRequest request, {
    Map<String, String>? extra,
  }) {
    final compat = AnthropicCompatOptions.resolve(
      baseUrl: request.baseUrl,
      providerOptions: request.providerOptions,
      reasoningEffort: request.reasoningEffort,
      requestedMaxTokens: request.maxTokens,
      modelMaxOutputTokens: request.modelMaxOutputTokens,
    );
    final apiKey = request.apiKey;
    final providerHeaders = <String, String>{};
    final rawHeaders = request.providerOptions?['extra_headers'];
    if (rawHeaders is Map<String, dynamic>) {
      rawHeaders.forEach((k, v) => providerHeaders[k] = v.toString());
    }

    final rawBeta = request.providerOptions?['anthropic_beta'];
    final betaFlags = rawBeta is List
        ? rawBeta
            .map((e) => e.toString().trim())
            .where((e) => e.isNotEmpty)
            .toList()
        : const <String>[];

    return {
      ...providerHeaders,
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'anthropic-version': compat.apiVersion,
      if (apiKey != null && apiKey.isNotEmpty) 'x-api-key': apiKey,
      if (betaFlags.isNotEmpty) 'anthropic-beta': betaFlags.join(','),
      ...?extra,
    };
  }

  @override
  Map<String, dynamic> buildRequestBody(
    LlmRequest request, {
    required bool stream,
  }) {
    final compat = AnthropicCompatOptions.resolve(
      baseUrl: request.baseUrl,
      providerOptions: request.providerOptions,
      reasoningEffort: request.reasoningEffort,
      requestedMaxTokens: request.maxTokens,
      modelMaxOutputTokens: request.modelMaxOutputTokens,
    );

    // 提取 system 消息到顶层字段（Anthropic 要求 system 必须在顶层）
    final messages = request.messages;
    final systemTexts = _extractSystemTexts(messages);
    final filteredMessages = _filterNonSystemMessages(messages);

    // 转换 OpenAI 风格 messages 为 Anthropic 风格
    // - 工具调用结果：role:"tool" → role:"user" + content:[{type:"tool_result",...}]
    // - assistant 工具调用：message.tool_calls → content:[{type:"tool_use",...}]
    // - 思考内容回传：anthropicBlocks（优先）或 thinkingBlocks → thinking block
    final anthropicMessages = _convertMessages(filteredMessages);

    final effectiveMaxTokens = compat.maxTokens;

    final body = <String, dynamic>{
      'model': request.modelId,
      'messages': anthropicMessages,
      'stream': stream,
      // Anthropic max_tokens 必填；0/null 的解析见 AnthropicCompatOptions
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
    // 照常命中。断点总数上限 4：无历史端断点时 system ≤3 块逐块打，
    // 超过时只保首末；有历史端断点时 system 最多保留首末两块。
    final rawCacheBreakpointIndex = request.cacheBreakpointIndex;
    final historyCacheBreakpointIndex = rawCacheBreakpointIndex == null
        ? null
        : _mapCacheBreakpointIndex(messages, rawCacheBreakpointIndex);

    if (systemTexts.isNotEmpty) {
      final useCacheBreakpoints = request.tools != null;
      body['system'] = useCacheBreakpoints
          ? _buildSystemBlocks(
              systemTexts,
              maxBreakpoints: historyCacheBreakpointIndex == null ? 3 : 2,
            )
          : systemTexts.join('\n\n');
    }
    // 消息区断点对无工具请求
    // （chat 模式）同样开放；有稳定历史尾时额外打一个断点，让跨轮
    // system + 历史前缀持续命中。
    if (anthropicMessages.isNotEmpty) {
      _markAnthropicCacheBreakpoints(
        anthropicMessages,
        historyIndex: historyCacheBreakpointIndex,
      );
    }

    // Anthropic 默认不发采样参数：官方新模型与严格中转站会拒绝非默认值；
    // 需要时由 providerOptions['anthropic_send_sampling']=true 显式开启。
    if (compat.sendSampling && request.temperature != null) {
      body['temperature'] = sanitizeSamplingParam(request.temperature);
    }
    if (compat.sendSampling && request.topP != null) {
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
      body['tool_choice'] = _convertToolChoice(
        request.toolChoice!,
        compat: compat,
        forceAuto:
            request.providerOptions?[kAnthropicToolChoiceAutoInternal] == true,
      );
    }

    // thinking 参数（端点画像决定形态；不再按模型名自动映射 enabled）
    final thinkingConfig = _buildThinkingConfig(
      compat: compat,
      effectiveMaxTokens: effectiveMaxTokens,
    );
    if (thinkingConfig != null) {
      body['thinking'] = thinkingConfig;
    }
    if (compat.effort != null) {
      body['output_config'] = {'effort': compat.effort};
    }

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

    final contentBlocksJson = body['content'] as List<dynamic>? ?? [];
    final textBuffer = StringBuffer();
    final thinkingBlocks = <LlmThinkingBlock>[];
    final toolCalls = <ToolCall>[];
    final orderedBlocks = <LlmContentBlock>[];

    for (final block in contentBlocksJson) {
      if (block is! Map<String, dynamic>) continue;
      final type = block['type'] as String?;
      final ordered = LlmContentBlock.fromAnthropicJson(block);
      if (ordered != null) orderedBlocks.add(ordered);

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
      final cacheRead = usageJson['cache_read_input_tokens'] as int?;
      final cacheCreation = usageJson['cache_creation_input_tokens'] as int?;
      final totalInput = inputTokens + (cacheRead ?? 0) + (cacheCreation ?? 0);
      usage = LlmUsage(
        promptTokens: inputTokens,
        completionTokens: outputTokens,
        totalTokens: inputTokens + outputTokens,
        totalInputTokens: totalInput,
        cacheReadTokens: cacheRead,
        cacheCreationTokens: cacheCreation,
      );
    }

    return LlmResponse(
      content: textBuffer.toString(),
      usage: usage,
      toolCalls: toolCalls.isEmpty ? null : toolCalls,
      // Anthropic 使用 thinkingBlocks（结构化 + signature），不用 reasoningContent
      thinkingBlocks: thinkingBlocks.isEmpty ? null : thinkingBlocks,
      contentBlocks: orderedBlocks.isEmpty ? null : orderedBlocks,
      // stop_reason 映射为统一 finishReason 词表（max_tokens→length 等），
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

  /// 在指定消息的最后一个 content block 打 cache_control 断点
  ///
  /// String content 包成 text 块；List content 复制末块与列表后写入，
  /// 不改写调用方共享的 map。
  static bool _markBreakpointAt(
    List<Map<String, dynamic>> messages,
    int index,
  ) {
    if (index < 0 || index >= messages.length) return false;
    final target = messages[index];
    final content = target['content'];
    if (content is String) {
      if (content.isEmpty) return false;
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
      return true;
    }
    if (content is List && content.isNotEmpty) {
      final copied = <dynamic>[];
      for (final block in content) {
        copied.add(
          block is Map<String, dynamic>
              ? Map<String, dynamic>.from(block)
              : block,
        );
      }

      // thinking / redacted_thinking 不接受 cache_control；从后往前找
      // 最后一个可缓存 block（text / tool_use / tool_result 等）。
      Map<String, dynamic>? cacheable;
      for (var i = copied.length - 1; i >= 0; i--) {
        final block = copied[i];
        if (block is! Map<String, dynamic>) continue;
        final type = block['type'];
        if (type is String && _nonCacheableBlockTypes.contains(type)) {
          continue;
        }
        cacheable = block;
        break;
      }
      if (cacheable == null) return false;
      cacheable['cache_control'] = {'type': 'ephemeral'};
      messages[index] = <String, dynamic>{...target, 'content': copied};
      return true;
    }
    return false;
  }

  /// 标记消息区缓存断点：可选的稳定历史尾 + 倒数第二条
  ///
  /// 历史尾断点让跨轮不变的前缀（system + 历史）在 Anthropic 端持续命中；
  /// 倒数第二条断点覆盖轮内 append-only 的步间前缀。两者同址时只打一次。
  static void _markAnthropicCacheBreakpoints(
    List<Map<String, dynamic>> messages, {
    int? historyIndex,
  }) {
    final marked = <int>{};
    if (historyIndex != null &&
        historyIndex >= 0 &&
        historyIndex < messages.length &&
        _markBreakpointAt(messages, historyIndex)) {
      marked.add(historyIndex);
    }
    if (messages.length >= 2) {
      final secondLast = messages.length - 2;
      if (marked.add(secondLast)) {
        _markBreakpointAt(messages, secondLast);
      }
    }
  }

  /// raw messages 下标 → Anthropic messages 下标（过滤 system 后）
  ///
  /// 目标消息必须是 user/assistant；system 或越界返回 null。
  static int? _mapCacheBreakpointIndex(
    List<Map<String, dynamic>> messages,
    int rawIndex,
  ) {
    if (rawIndex < 0 || rawIndex >= messages.length) return null;
    if (messages[rawIndex]['role'] == 'system') return null;
    var filteredIndex = 0;
    for (var i = 0; i < rawIndex; i++) {
      if (messages[i]['role'] != 'system') filteredIndex++;
    }
    return filteredIndex;
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
  static List<Map<String, dynamic>> _buildSystemBlocks(
    List<String> texts, {
    int maxBreakpoints = 3,
  }) {
    return [
      for (var i = 0; i < texts.length; i++)
        {
          'type': 'text',
          'text': texts[i],
          if (texts.length <= maxBreakpoints || i == 0 || i == texts.length - 1)
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

  /// 有序 block → Anthropic content 数组。
  ///
  /// 返回 null 表示没有可用有序数据，调用方回退旧的三段式重建。
  List<Map<String, dynamic>>? _convertOrderedAssistantBlocks(
    Map<String, dynamic> msg,
  ) {
    final raw = msg['anthropicBlocks'];
    if (raw is! List || raw.isEmpty) return null;
    final blocks = <Map<String, dynamic>>[];
    for (final item in raw) {
      if (item is! Map<String, dynamic>) continue;
      final block = LlmContentBlock.fromJson(item);
      if (block == null) continue;
      if (block is LlmThinkingContentBlock && block.signature.isEmpty) {
        continue;
      }
      if (block is LlmRedactedThinkingContentBlock && block.data.isEmpty) {
        continue;
      }
      blocks.add(block.toAnthropicJson());
    }
    if (blocks.isEmpty) return null;

    // 有序块缺 tool_use 但平行字段有 tool_calls：回退旧重建，避免
    // 丢掉工具调用、让后续 tool_result 变成孤儿。
    final hasToolUse = blocks.any((b) => b['type'] == 'tool_use');
    final toolCalls = msg['tool_calls'];
    if (!hasToolUse && toolCalls is List && toolCalls.isNotEmpty) return null;

    return blocks;
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

    // assistant 消息：优先使用有序 block，旧数据按 thinking→text→tool_use 回退
    if (role == 'assistant') {
      final orderedBlocks = _convertOrderedAssistantBlocks(msg);
      if (orderedBlocks != null) {
        return {'role': 'assistant', 'content': orderedBlocks};
      }

      final blocks = <Map<String, dynamic>>[];

      // thinking 必须在 text 之前；空 signature 不可回传。
      final thinkingBlocks = msg['thinkingBlocks'];
      if (thinkingBlocks is List) {
        for (final tb in thinkingBlocks) {
          if (tb is! Map<String, dynamic>) continue;
          final signature = tb['signature'] as String? ?? '';
          if (signature.isEmpty) continue;
          blocks.add({
            'type': 'thinking',
            'thinking': tb['thinking'] ?? '',
            'signature': signature,
          });
        }
      }

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

      // OpenAI 风格 image_url 不是 Anthropic 合法 content block 类型，
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

  /// OpenAI `image_url` part → Anthropic image block
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
      final normalized = mediaType.toLowerCase() == 'image/jpg'
          ? 'image/jpeg'
          : mediaType.toLowerCase();
      const supported = {
        'image/jpeg',
        'image/png',
        'image/gif',
        'image/webp',
      };
      if (!supported.contains(normalized)) return null;
      return {
        'type': 'image',
        'source': {
          'type': 'base64',
          'media_type': normalized,
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

  /// 转换 ToolChoice 枚举为 Anthropic 格式。
  ///
  /// `none` 在官方端点直接发送；第三方默认降级 auto（旧中转可能不认识），
  /// 可由 `anthropic_capabilities.tool_choice_none` 显式声明。
  Map<String, dynamic> _convertToolChoice(
    ToolChoice toolChoice, {
    required AnthropicCompatOptions compat,
    required bool forceAuto,
  }) {
    if (forceAuto) return {'type': 'auto'};
    return switch (toolChoice) {
      ToolChoice.auto => {'type': 'auto'},
      ToolChoice.required => {'type': 'any'},
      ToolChoice.none =>
        compat.allowToolChoiceNone ? {'type': 'none'} : {'type': 'auto'},
    };
  }

  /// 构建 thinking 配置（形态由 [AnthropicCompatOptions] 决定）。
  ///
  /// 极小 max_tokens（能力探测等）不发 thinking；adaptive 不再需要
  /// budget_tokens，因此只剩这一个数值守卫。
  Map<String, dynamic>? _buildThinkingConfig({
    required AnthropicCompatOptions compat,
    required int effectiveMaxTokens,
  }) {
    if (compat.thinking == AnthropicThinkingDirective.omit) return null;
    if (effectiveMaxTokens <= _minThinkingMaxTokens) return null;
    return switch (compat.thinking) {
      AnthropicThinkingDirective.providerJson => compat.providerThinking,
      AnthropicThinkingDirective.adaptive => {'type': 'adaptive'},
      AnthropicThinkingDirective.disabled => {'type': 'disabled'},
      AnthropicThinkingDirective.betweenTools => {'type': 'between_tools'},
      AnthropicThinkingDirective.omit => null,
    };
  }
}
