import 'package:lmstory/core/llm/llm_usage.dart' show LlmUsage;

/// Agent 轮预算（三档硬上限，DOC-03A §9 决策 2）
///
/// 默认值对齐设计报告 §9：maxSteps=8（可配 1–32，0 = 不限步数）、
/// 时间 5 min/轮。超限安全停止并保留现场（已完成的 step 与消息不回滚）。
/// maxSteps=0 时步数不设限，仍受 maxDuration / maxTotalTokens / doom-loop
/// 检测兜底（导演设置面板「无上限」选项）。
class AgentBudget {
  const AgentBudget({
    this.maxSteps = 8,
    this.maxTotalTokens,
    this.maxDuration = const Duration(minutes: 5),
    this.maxRequestRetries = 5,
    this.contextWindowTokens,
  });

  /// 单轮最大模型请求数（step 数）；0 = 不限制
  final int maxSteps;

  /// 单轮累计消耗 token 上限（成本预算，null = 不限制；建议 = 上下文窗口 × 0.6）。
  ///  语义改名：这是「花了多少」的成本口径，不是「装了多少」的上下文口径
  /// ——上下文余量守卫见 [contextWindowTokens]。
  final int? maxTotalTokens;

  /// 单轮墙钟时间上限
  final Duration? maxDuration;

  /// 单个 step 的请求失败重试上限（request-error 瀑布内）
  final int maxRequestRetries;

  /// 模型上下文窗口（余量守卫，null = 不启用）：runner 按其 85% 作为
  /// 触发线，最近请求 promptTokens 越线即软着陆——防止「上下文装爆」
  /// 与「花费超支」（[maxTotalTokens]）两种耗尽混为一谈。
  final int? contextWindowTokens;

  AgentBudget copyWith({
    int? maxSteps,
    int? maxTotalTokens,
    Duration? maxDuration,
    int? maxRequestRetries,
    int? contextWindowTokens,
  }) {
    return AgentBudget(
      maxSteps: maxSteps ?? this.maxSteps,
      maxTotalTokens: maxTotalTokens ?? this.maxTotalTokens,
      maxDuration: maxDuration ?? this.maxDuration,
      maxRequestRetries: maxRequestRetries ?? this.maxRequestRetries,
      contextWindowTokens: contextWindowTokens ?? this.contextWindowTokens,
    );
  }
}

/// 轮内 token 用量累计（扩展 cache 命中分项计量）
class AgentUsageAccumulator {
  int promptTokens = 0;
  int completionTokens = 0;
  int totalTokens = 0;
  int cacheReadTokens = 0;
  int cacheCreationTokens = 0;
  int stepsWithUsage = 0;

  /// 最近一次请求分项（上下文用量指示 2026-09-01）：add() 覆盖而非累加。
  /// 语义为"该轮最后一次成功请求时模型看到的上下文"。
  int lastPromptTokens = 0;
  int lastCompletionTokens = 0;
  int lastCacheReadTokens = 0;

  /// 最近一次请求的完整输入面（Anthropic 含 cache read/creation）。
  int lastTotalInputTokens = 0;

  void add(LlmUsage? usage) {
    if (usage == null) return;
    promptTokens += usage.promptTokens ?? 0;
    completionTokens += usage.completionTokens ?? 0;
    totalTokens += usage.totalTokens ??
        ((usage.promptTokens ?? 0) + (usage.completionTokens ?? 0));
    cacheReadTokens += usage.cacheReadTokens ?? 0;
    cacheCreationTokens += usage.cacheCreationTokens ?? 0;
    lastPromptTokens = usage.promptTokens ?? 0;
    lastCompletionTokens = usage.completionTokens ?? 0;
    lastCacheReadTokens = usage.cacheReadTokens ?? 0;
    lastTotalInputTokens = usage.totalInputTokens ?? 0;
    stepsWithUsage++;
  }

  /// 并账另一累计器。[carryLastRequest] = false 用于子代理并账：
  /// last* 分项语义是"父轮最后一次请求看到的上下文"，子代理是独立
  /// 上下文，不应污染父轮的上下文用量指示口径。
  void merge(AgentUsageAccumulator other, {bool carryLastRequest = true}) {
    promptTokens += other.promptTokens;
    completionTokens += other.completionTokens;
    totalTokens += other.totalTokens;
    cacheReadTokens += other.cacheReadTokens;
    cacheCreationTokens += other.cacheCreationTokens;
    if (carryLastRequest && other.stepsWithUsage > 0) {
      lastPromptTokens = other.lastPromptTokens;
      lastCompletionTokens = other.lastCompletionTokens;
      lastCacheReadTokens = other.lastCacheReadTokens;
      lastTotalInputTokens = other.lastTotalInputTokens;
    }
    stepsWithUsage += other.stepsWithUsage;
  }
}
