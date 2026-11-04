/// LLM 用量统计与 Anthropic thinking block（core 值对象）。
///
/// 自 chat feature
/// llm_service.dart 下沉——core/agent 的网关值类型不得反向依赖 feature。
/// 原位置 re-export 维持消费面零改动。
library;

/// LLM 用量统计（usage 块）
class LlmUsage {
  const LlmUsage({
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
    this.totalInputTokens,
    this.cacheReadTokens,
    this.cacheCreationTokens,
  });

  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;

  /// 完整输入面（Anthropic = input_tokens + cache_read + cache_creation）。
  ///
  /// `promptTokens` 继续保留 Anthropic 的"最后一个缓存断点之后"语义，
  /// 供 C/(C+P) 命中率使用；需要上下文占用/成本口径时优先用本字段。
  final int? totalInputTokens;

  /// 缓存命中读 token（Anthropic cache_read_input_tokens /
  /// OpenAI prompt_tokens_details.cached_tokens；无缓存信息为 null）
  final int? cacheReadTokens;

  /// 缓存写入 token（Anthropic cache_creation_input_tokens）
  final int? cacheCreationTokens;
}

/// Anthropic thinking block（结构化思考块，含 signature）
///
/// Anthropic Claude 响应中的 thinking block 由两部分组成：
/// - [thinking]：思考内容明文
/// - [signature]：服务端加密签名，多轮对话中必须原样回传，否则 400 错误
///
/// 与 reasoningContent（String）的差异：
/// - `reasoningContent`：OpenAI/DeepSeek 风格，纯文本思维链，无签名
/// - `thinkingBlocks`：Anthropic 风格，结构化块，含签名，多轮回传必需
///
/// 调用方在多轮对话中构造 assistant 消息时，应将此列表中的每个 block
/// 原样写入 messages 的 content 数组：
/// `{type: 'thinking', thinking: '...', signature: '...'}`。
///
/// 实现依据：DOC-12 §5.4.4 + §11 风险表。
class LlmThinkingBlock {
  const LlmThinkingBlock({
    required this.thinking,
    required this.signature,
  });

  /// 思考内容文本（完整内容，非增量）
  final String thinking;

  /// 加密签名（多轮回传必需，不可修改）
  final String signature;
}
