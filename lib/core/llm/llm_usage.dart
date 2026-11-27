/// LLM 用量统计与 Anthropic thinking block（core 值对象）。
///
/// 自 chat feature
/// llm_service.dart 下沉——core/agent 的网关值类型不得反向依赖 feature。
/// 原位置 re-export 维持消费面零改动。
library;

/// LLM 用量统计（usage 块）
///
/// 口径约定（2026-11-09 上下文数据可靠性第一批）：
/// - [promptTokens] 保留协议原生语义（Anthropic = 最后一个缓存断点之后），
///   仅用于诊断，**不得**直接做缓存命中率分母；
/// - [totalInputTokens] 为完整输入面（OpenAI/Gemini 的 prompt_tokens 已含
///   缓存；Anthropic = input + cache_read + cache_creation），上下文占用与
///   `cacheRead / totalInput` 命中率统一以本字段为准；
/// - 协议适配器必须显式写入 [totalInputTokens]，缺失时按 [promptTokens]
///   降级（旧日志兼容），不能悄悄把缓存分项加两次。
class LlmUsage {
  const LlmUsage({
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
    this.totalInputTokens,
    this.cacheReadTokens,
    this.cacheCreationTokens,
    this.reasoningTokens,
    this.warnings = const [],
  });

  final int? promptTokens;
  final int? completionTokens;
  final int? totalTokens;

  /// 完整输入面（Anthropic = input_tokens + cache_read + cache_creation）。
  ///
  /// `promptTokens` 继续保留 Anthropic 的"最后一个缓存断点之后"语义，
  /// 供协议诊断使用；上下文占用/缓存命中率一律用本字段。
  final int? totalInputTokens;

  /// 缓存命中读 token（Anthropic cache_read_input_tokens /
  /// OpenAI prompt_tokens_details.cached_tokens /
  /// DeepSeek prompt_cache_hit_tokens；无缓存信息为 null）
  final int? cacheReadTokens;

  /// 缓存写入 token（Anthropic cache_creation_input_tokens）
  final int? cacheCreationTokens;

  /// 思维链/推理 token（OpenAI reasoning_tokens / Gemini thoughtsTokenCount）
  ///
  /// 与 [completionTokens] 分开记录：部分协议把思考 token 计入 completion，
  /// 部分单列，展示面需要能把两者区分开。
  final int? reasoningTokens;

  /// 计量异常说明（字段冲突等）——不阻断请求，但不得静默丢弃。
  final List<String> warnings;

  /// 完整输入 token；缺失时降级到协议原生 prompt（旧日志/旧适配器）
  int? get fullInputTokens {
    final explicit = totalInputTokens;
    if (explicit != null && explicit > 0) return explicit;
    final prompt = promptTokens;
    if (prompt == null) return null;
    return prompt;
  }

  /// 未命中缓存的输入 token（full - cacheRead - cacheCreation，下限 0）
  int? get uncachedInputTokens {
    final input = fullInputTokens;
    if (input == null) return null;
    final cached = (cacheReadTokens ?? 0) + (cacheCreationTokens ?? 0);
    final uncached = input - cached;
    return uncached < 0 ? 0 : uncached;
  }

  /// 缓存命中率（cacheRead / 完整输入），无可用/可信样本时 null
  ///
  /// 计量异常（字段冲突 warnings、cached > input、
  /// 负数）不得产出「精确比例」。异常样本保留原值用于诊断，但命中率返回
  /// null，由展示面显示未知/异常。
  double? get cacheHitRatio {
    if (warnings.isNotEmpty) return null;
    final input = fullInputTokens;
    if (input == null || input <= 0) return null;
    final cached = cacheReadTokens;
    if (cached == null || cached < 0 || cached > input) return null;
    return cached / input;
  }

  /// 该样本的缓存命中率是否可用于无标识的精确展示
  bool get hasQualifiedCacheSample => cacheHitRatio != null;

  /// 是否有端点级缓存分项（false = 面板显示「—」，不能填 0）
  bool get hasCacheData => cacheReadTokens != null;

  /// 共享命中率公式（会话累计/单轮统计统一入口）
  ///
  /// 只接受完整输入 token；Anthropic 的 promptTokens 不可直接传入。
  /// 非法样本（负数、cached > input、input ≤ 0）返回 null。
  static double? hitRateOf({
    required int? cacheReadTokens,
    required int? inputTokens,
  }) {
    if (cacheReadTokens == null || inputTokens == null || inputTokens <= 0) {
      return null;
    }
    if (cacheReadTokens < 0 || cacheReadTokens > inputTokens) return null;
    return cacheReadTokens / inputTokens;
  }
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
