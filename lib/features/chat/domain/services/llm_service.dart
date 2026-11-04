import 'dart:async';

// 值类型已下沉 core/llm。
// import 供本库内部引用，export 维持既有消费面零改动。
import 'package:lmstory/core/llm/llm_content_block.dart';
import 'package:lmstory/core/llm/llm_usage.dart';
import 'package:lmstory/core/llm/tool_calling/tool_call.dart';
import 'package:lmstory/core/llm/tool_calling/tool_choice.dart';
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';
import 'package:lmstory/core/network/http_client.dart' show CancellationToken;
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart'
    show ApiPreset;
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';

export 'package:lmstory/core/llm/llm_usage.dart';

/// LLM 流式事件（Domain 层，不暴露 Core 的 SseEvent）
///
/// 由 [LlmService.streamChat] 产出，调用方在流上叠加业务解析
/// （如中级模式的 `StreamMarkerParser`）。
sealed class LlmStreamEvent {
  const LlmStreamEvent();
}

/// 文本增量（对应 OpenAI `delta.content`）
class LlmTextDelta extends LlmStreamEvent {
  const LlmTextDelta(this.content);

  final String content;
}

/// 思考/推理内容增量（对应 `delta.reasoning_content`，DeepSeek-R1/Claude thinking）
class LlmThinkingDelta extends LlmStreamEvent {
  const LlmThinkingDelta(this.content);

  final String content;
}

/// 有序内容块完成事件（Anthropic 专用）
///
/// 与 text/thinking/tool 平行事件并行发出，保留原始 block 顺序。
/// `thinking`/`redacted_thinking` 的原样回传依赖本事件。
class LlmContentBlockComplete extends LlmStreamEvent {
  const LlmContentBlockComplete(this.block);

  final LlmContentBlock block;
}

/// 思考块完成事件（Anthropic 专用，DOC-12 §5.4.4）
///
/// 在 Anthropic 流式响应的 `content_block_stop`（type=thinking）时发出，
/// 携带完整 thinking 文本 + signature。signature 是加密签名，多轮对话中
/// 必须原样回传给 API，否则服务端验证失败（400 错误）。
///
/// 调用方应缓存此事件信息用于下一轮请求回传（构造 assistant 消息时
/// 写入 `thinking` block 含 signature）。
///
/// OpenAI/DeepSeek 适配器不发此事件（它们用 [LlmThinkingDelta] 累积字符串，
/// 无 signature 概念）。
class LlmThinkingBlockComplete extends LlmStreamEvent {
  const LlmThinkingBlockComplete({
    required this.thinking,
    required this.signature,
  });

  /// 思考内容文本（完整累积值，非增量）
  final String thinking;

  /// 加密签名（多轮回传必需）
  final String signature;
}

/// 流正常结束（对应 `[DONE]` 或 `finish_reason=stop`）
class LlmStreamDone extends LlmStreamEvent {
  const LlmStreamDone({this.usage, this.finishReason});

  final LlmUsage? usage;

  /// 最后一次收到的 finish_reason（length/content_filter 等需要调用方区分）
  final String? finishReason;
}

/// 流内错误（SSE 解析失败或服务端返回错误事件）
class LlmStreamError extends LlmStreamEvent {
  const LlmStreamError(this.message, {this.code, this.retryAfter});

  final String message;
  final String? code;

  /// Retry-After 冷却时长（：wire 层透传；null=无指示）
  final Duration? retryAfter;
}

/// 工具调用开始（对应 `delta.tool_calls[0]` 首次出现，含 id 与 name）
class LlmToolCallStart extends LlmStreamEvent {
  const LlmToolCallStart(this.toolCallId, this.name);

  final String toolCallId;
  final String name;
}

/// 工具调用参数增量（对应 `delta.tool_calls[0].function.arguments` 分片）
class LlmToolCallArgs extends LlmStreamEvent {
  const LlmToolCallArgs(this.toolCallId, this.argsDelta);

  final String toolCallId;

  /// 参数 JSON 字符串分片（需累积后整体解析）
  final String argsDelta;
}

/// 工具调用完成（累积结束，arguments 已解析为 Map）
class LlmToolCallComplete extends LlmStreamEvent {
  const LlmToolCallComplete({
    required this.toolCallId,
    required this.name,
    required this.arguments,
    this.thoughtSignature,
  });

  final String toolCallId;
  final String name;

  /// 已解析的参数 Map（容错解析失败时为空 Map）
  final Map<String, dynamic> arguments;

  /// Gemini 3 思考签名（part 级 `thoughtSignature`）
  ///
  /// 多轮工具调用中原样随 tool-call part 回传（设计报告 §4.3）；
  /// OpenAI/Anthropic/DeepSeek 协议恒为 null。
  final String? thoughtSignature;
}

/// LLM 非流式响应
class LlmResponse {
  const LlmResponse({
    required this.content,
    this.usage,
    this.toolCalls,
    this.reasoningContent,
    this.thinkingBlocks,
    this.contentBlocks,
    this.finishReason,
  });

  final String content;
  final LlmUsage? usage;

  /// 原始 block 顺序（Anthropic 专用；其它协议为 null）。
  final List<LlmContentBlock>? contentBlocks;

  /// 结束原因（stop/tool_calls/length/content_filter…）
  ///
  /// 推理型模型的输出预算含思维链：`length` 且 [content] 为空表示
  /// 预算被推理耗尽，调用方不应视作"模型主动返回空"。
  final String? finishReason;

  /// 工具调用列表（非流式请求携带 tools 时，LLM 可能返回 tool_calls）
  ///
  /// 流式请求通过 [LlmToolCallStart]/[LlmToolCallArgs]/[LlmToolCallComplete]
  /// 事件上抛；非流式请求在此字段返回。无工具调用时为 null。
  final List<ToolCall>? toolCalls;

  /// LLM 思考/推理内容（来自 `reasoning_content` 字段）
  ///
  /// DeepSeek V4 thinking 模式下，响应会携带 reasoning_content（思维链）。
  /// 多轮工具调用场景下，调用方需将此字段回传给 API。
  /// 仅当模型支持 reasoning 时有值，其他模型为 null（不影响兼容性）。
  final String? reasoningContent;

  /// Anthropic 结构化 thinking blocks（含 signature）
  ///
  /// 仅 Anthropic 协议响应有值，OpenAI/DeepSeek/Gemini 为 null。
  /// 多轮对话中调用方必须将此列表原样回传到下轮请求的 messages 中，
  /// 否则 Anthropic 服务端 signature 验证失败（400 错误）。
  ///
  /// 与 [reasoningContent] 互斥：OpenAI/DeepSeek 用 reasoningContent，
  /// Anthropic 用 thinkingBlocks，两者不会同时有值。
  final List<LlmThinkingBlock>? thinkingBlocks;
}

/// 响应格式（OpenAI `response_format` 参数）
///
/// 注入到请求体以强制 LLM 输出结构化数据。
///  改造为 sealed class，支持三种模式：
/// - [LlmResponseFormatJsonObject]：`{type: 'json_object'}`，仅保证返回合法 JSON
/// - [LlmResponseFormatJsonSchema]：`{type: 'json_schema', strict: true}`，100% 保证字段结构合规
/// - null：不注入 response_format，纯提示词约束
sealed class LlmResponseFormat {
  const LlmResponseFormat();
}

/// `{type: 'json_object'}` —— 强制输出 JSON 对象（DeepSeek/OpenRouter 支持）
class LlmResponseFormatJsonObject extends LlmResponseFormat {
  const LlmResponseFormatJsonObject();
}

/// `{type: 'json_schema', strict: true}` —— 严格 schema 合规（OpenAI 官方支持）
///
/// 注入 `response_format: {type: 'json_schema', json_schema: {name, schema, strict: true}}`，
/// 100% 保证返回 JSON 且字段结构、类型符合 [schema] 定义。
class LlmResponseFormatJsonSchema extends LlmResponseFormat {
  const LlmResponseFormatJsonSchema({
    required this.name,
    required this.schema,
    this.strict = true,
  });

  /// schema 名称（OpenAI 要求，仅用于服务端日志，无业务影响）
  final String name;

  /// JSON Schema 定义（Draft 07 子集，OpenAI 有限制：additionalProperties 必须为 false 等）
  final Map<String, dynamic> schema;

  /// 是否严格模式（默认 true，保证 100% schema 合规）
  final bool strict;
}

/// LLM 请求参数（值对象，所有调用方共用）
///
/// 收口 OpenAI 兼容 `/chat/completions` 请求的统一参数。
/// 调用方填充本对象后交给 [LlmService.streamChat] / [LlmService.chat]，
/// 不再关心请求体拼装、SSE 解析、response_format 注入等传输细节。
class LlmRequest {
  const LlmRequest({
    required this.baseUrl,
    required this.modelId,
    required this.messages,
    this.apiKey,
    this.temperature,
    this.topP,
    this.maxTokens,
    this.modelMaxOutputTokens,
    this.presencePenalty,
    this.frequencyPenalty,
    this.stream = true,
    this.includeUsage = false,
    this.responseFormat,
    this.tools,
    this.toolChoice,
    this.reasoningEffort,
    this.protocol = LlmProtocol.openaiCompatible,
    this.providerOptions,
    this.connectTimeout,
    this.readTimeout,
    this.responseStartTimeout,
    this.nonStreamingTimeout,
    this.cancelToken,
    this.cacheBreakpointIndex,
  });

  /// API 供应商 baseUrl（未经过 `ApiUrlResolver` 解析）
  final String baseUrl;

  /// API Key（nullable，部分本地部署供应商可为 null）
  final String? apiKey;

  /// 模型 ID
  final String modelId;

  /// 消息列表（content 可为 String 或 List，兼容 vision 消息）
  final List<Map<String, dynamic>> messages;

  final double? temperature;
  final double? topP;
  final int? maxTokens;

  /// 模型元数据声明的最大输出 token 数。
  ///
  /// 用于约束显式正数配置；Anthropic 原生协议在 [maxTokens] 为 0 时还需
  /// 使用该值填充其必填的 `max_tokens` 字段。
  final int? modelMaxOutputTokens;

  /// 存在惩罚（presence_penalty，OpenAI 兼容参数）
  ///
  /// 取值范围 -2.0 ~ 2.0，默认 0（不发送参数）。
  /// 正值鼓励 LLM 谈论新话题：每次 token 出现在已生成文本中时，
  /// 统一施加惩罚（不管出现几次），降低已出现 token 的概率。
  /// 适用于故事模式避免剧情单调重复出现相同话题。
  ///
  /// 与 [frequencyPenalty] 的差异：
  /// - presence_penalty：按"是否出现过"施加固定惩罚（鼓励新话题）
  /// - frequency_penalty：按"出现次数"施加递增惩罚（减少重复用词）
  ///
  /// 调用方需确认模型支持此参数（OpenAI/DeepSeek/OpenRouter 均支持）。
  final double? presencePenalty;

  /// 频率惩罚（frequency_penalty，OpenAI 兼容参数）
  ///
  /// 取值范围 -2.0 ~ 2.0，默认 0（不发送参数）。
  /// 正值减少 LLM 重复用词：token 每多出现一次，惩罚递增，
  /// 降低高频 token 的概率。适用于故事模式避免重复描写、口头禅。
  ///
  /// 与 [presencePenalty] 互补：可同时使用，前者控话题、后者控用词。
  final double? frequencyPenalty;

  /// 是否流式（true 走 streamChat，false 走 chat）
  final bool stream;

  /// 是否在流式响应末尾返回 usage（stream_options.include_usage）
  final bool includeUsage;

  /// 响应格式约束（null = 不注入 response_format）
  final LlmResponseFormat? responseFormat;

  /// 工具定义列表（OpenAI 兼容 `tools` 参数，null = 不携带工具）
  ///
  /// 注入后 LLM 可发起工具调用，事件通过 [LlmToolCallStart]/
  /// [LlmToolCallArgs]/[LlmToolCallComplete] 上抛。
  final List<ToolDefinition>? tools;

  /// 工具选择策略（`tool_choice`，null = 不注入，由 LLM 默认行为决定）
  final ToolChoice? toolChoice;

  /// 思考预算档位（OpenAI 兼容 `reasoning_effort` 参数）
  ///
  /// - null：不发送参数（由模型自行决定）
  /// - [ReasoningEffort.disabled]：不发送参数（大多数模型默认不思考）
  /// - [ReasoningEffort.low]/[ReasoningEffort.medium]/[ReasoningEffort.high]：
  ///   发送 `reasoning_effort: 'low'/'medium'/'high'`
  ///
  /// 调用方需先确认模型支持 reasoning 能力（通过 ModelCapability.reasoning），
  /// 否则 API 可能返回 400 错误。
  final ReasoningEffort? reasoningEffort;

  final Duration? connectTimeout;
  final Duration? readTimeout;

  /// Send to first response byte; null preserves legacy header waiting.
  final Duration? responseStartTimeout;

  /// Entire non-streaming request, including response headers.
  final Duration? nonStreamingTimeout;

  /// 取消令牌（取消正在进行的请求）
  final CancellationToken? cancelToken;

  /// 稳定前缀结束位置（messages 下标；仅 Anthropic 适配器消费）
  ///
  /// null = 不额外标记历史端缓存断点。
  final int? cacheBreakpointIndex;

  /// LLM 协议类型（决定适配器分发目标）
  ///
  /// 默认 [LlmProtocol.openaiCompatible]，兼容 v0.1 调用方（未显式传 protocol 时
  /// 走 OpenAI 兼容协议）。调用方应从 [ApiPreset.protocol] 读取并传入此字段，
  /// 以支持 Claude/Gemini 等非 OpenAI 协议供应商。
  final LlmProtocol protocol;

  /// 协议特有参数透传字段（DOC-12 §7）
  ///
  /// 用于承载无法用统一字段表达的协议特有参数。适配器从此 Map 中
  /// 提取自己识别的 key，忽略不识别的 key。
  ///
  /// 用途示例（DOC-12 §7）：
  /// - Anthropic：`{'thinking': {'type': 'enabled', 'budget_tokens': 2000}}`
  /// - Gemini：`{'thinkingConfig': {'thinkingLevel': 'high'}}`
  /// - OpenRouter：`{'reasoning': {'effort': 'high'}}`
  /// - OpenRouter：`{'extra_headers': {'HTTP-Referer': '...'}}`
  ///
  /// 优先级：适配器应先读取 [reasoningEffort] 统一枚举做基础映射，
  /// 再用 providerOptions 中的协议特有配置覆盖（如果存在）。
  /// 调用方未配置协议特有参数时为 null，适配器走默认映射逻辑。
  final Map<String, dynamic>? providerOptions;

  /// 复制并覆盖部分字段（主要用于补充 cancelToken / 兼容降级）
  LlmRequest copyWith({
    CancellationToken? cancelToken,
    List<Map<String, dynamic>>? messages,
    Map<String, dynamic>? providerOptions,
    int? maxTokens,
  }) {
    return LlmRequest(
      baseUrl: baseUrl,
      apiKey: apiKey,
      modelId: modelId,
      messages: messages ?? this.messages,
      temperature: temperature,
      topP: topP,
      maxTokens: maxTokens ?? this.maxTokens,
      modelMaxOutputTokens: modelMaxOutputTokens,
      presencePenalty: presencePenalty,
      frequencyPenalty: frequencyPenalty,
      stream: stream,
      includeUsage: includeUsage,
      responseFormat: responseFormat,
      tools: tools,
      toolChoice: toolChoice,
      reasoningEffort: reasoningEffort,
      protocol: protocol,
      providerOptions: providerOptions ?? this.providerOptions,
      connectTimeout: connectTimeout,
      readTimeout: readTimeout,
      responseStartTimeout: responseStartTimeout,
      nonStreamingTimeout: nonStreamingTimeout,
      cancelToken: cancelToken ?? this.cancelToken,
      cacheBreakpointIndex: cacheBreakpointIndex,
    );
  }
}

/// LLM 服务抽象接口（Domain 层）
///
/// 由 Data 层 `LlmRemoteDataSource` 实现。
/// 收口项目中散落的 LLM 调用（中级模式 generating/reviewing、Simple 模式对话、
/// 压缩、标题生成、模型测试等），统一请求体构造、SSE 解析、
/// `response_format` 注入。
///
/// 接口仅做"发请求、收响应/流"的传输职责，不含任何业务逻辑
/// （符合 DOC-05 "Repository 仅含纯数据存取，业务逻辑在 UseCase/Service"）。
///
/// 接口定义依据：DOC-05-7 §8.x（待补）。
// ignore: one_member_abstracts, 多方法抽象接口为 Clean Architecture 依赖反转所需
abstract class LlmService {
  /// 流式对话：返回 [LlmStreamEvent] 流
  ///
  /// 调用方监听本流接收增量，cancel subscription 即可取消请求
  /// （[LlmRequest.cancelToken] 也可用于取消）。
  /// 流异常时发出 [LlmStreamError] 而非直接抛错，调用方自行处理。
  Stream<LlmStreamEvent> streamChat(LlmRequest request);

  /// 非流式对话：返回完整响应
  ///
  /// HTTP 错误（非 200）抛 `AppHttpException`（由调用方失败分类器处理）。
  Future<LlmResponse> chat(LlmRequest request);
}
