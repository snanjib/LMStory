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

  /// 完整输入面累计（命中率分母；与 promptTokens 不同协议同口径）
  int totalInputTokens = 0;
  int cacheReadTokens = 0;
  int cacheCreationTokens = 0;

  /// 可比缓存样本的输入分母（只累计「完整输入 + 命中分项都有效」的请求）
  ///
  /// 总输入与命中率分母不能共用一个字段——一请求上报缓存、另一请求未
  /// 上报时，用全量输入做分母会把未知当零命中（80/200 = 40%）。命中率
  /// 只用本字段做分母。
  int cacheComparableInputTokens = 0;

  /// 可比缓存样本的命中分子（与 [cacheComparableInputTokens] 同一样本集）
  int cacheComparableReadTokens = 0;

  /// 可比缓存样本的请求数（= 有 usage 且缓存分项有效的请求数）
  int cacheComparableSteps = 0;

  /// 端点是否上报过 cache 分项。缺省（false）时不得把 0 当作「0 命中」，
  /// durable `turn/end` 据此决定是否落缓存键（旧日志/无缓存端点不可比）。
  bool hasCacheReadTokens = false;
  bool hasCacheCreationTokens = false;
  int stepsWithUsage = 0;

  /// 计量异常说明累计（字段冲突等）：随 `turn/end` 持久化用于诊断，
  /// 同时该请求不进入可比缓存样本。
  final List<String> usageWarnings = [];

  /// 最近一次主请求自身的计量异常（add() 每次覆盖，包括清空）。
  ///
  /// 与 [usageWarnings] 的整轮累计口径分离：早先步骤或子代理的异常
  /// 不能把最后一次合法请求的命中率拖成未知。
  List<String> lastRequestWarnings = const [];

  /// 是否存在可比较的缓存样本
  bool get hasComparableCache => cacheComparableSteps > 0;

  /// 最近一次请求分项（上下文用量指示 2026-09-01）：add() 覆盖而非累加。
  /// 语义为"该轮最后一次成功请求时模型看到的上下文"。
  int lastPromptTokens = 0;
  int lastCompletionTokens = 0;

  /// 最近一次请求的缓存命中分项；null = 端点未上报（不得按 0 命中计）
  int? lastCacheReadTokens;

  /// 最近一次请求的完整输入面（Anthropic 含 cache read/creation）。
  int lastTotalInputTokens = 0;

  /// 本轮第一次成功请求的完整输入（下一轮材料估算的基准锚点）。
  ///
  /// 多步工具轮的后续请求会不断携带本轮临时工作面（工具结果、工具调用
  /// 消息），最后一次输入因此包含下一轮不会保留的材料。首末输入之差即
  /// 该工作面的增量，用于把「当前预计」校准到下一轮实际装配边界。
  int? firstCompleteInputTokens;

  /// 最近一次请求的完整输入（展示口径）：协议实报优先，旧适配器回退 prompt。
  ///
  /// 余量守卫仍用 [lastTotalInputTokens] 的原始语义（0 = 未上报），
  /// 以保留其「prompt + cacheRead」旧兜底。
  int get lastCompleteInputTokens =>
      lastTotalInputTokens > 0 ? lastTotalInputTokens : lastPromptTokens;

  void add(LlmUsage? usage) {
    if (usage == null) return;
    promptTokens += usage.promptTokens ?? 0;
    completionTokens += usage.completionTokens ?? 0;
    totalTokens += usage.totalTokens ??
        ((usage.promptTokens ?? 0) + (usage.completionTokens ?? 0));
    final input = usage.fullInputTokens;
    totalInputTokens += input ?? 0;
    final read = usage.cacheReadTokens;
    if (read != null) {
      hasCacheReadTokens = true;
      cacheReadTokens += read;
    }
    if (usage.cacheCreationTokens != null) {
      hasCacheCreationTokens = true;
      cacheCreationTokens += usage.cacheCreationTokens!;
    }
    // 只有「完整输入 + 命中分项」都有效且无计量异常的请求才进入可比
    // 样本；异常的原始值仍保留在 cacheReadTokens 供诊断。
    if (read != null &&
        input != null &&
        input > 0 &&
        read >= 0 &&
        read <= input &&
        usage.warnings.isEmpty) {
      cacheComparableInputTokens += input;
      cacheComparableReadTokens += read;
      cacheComparableSteps++;
    }
    if (usage.warnings.isNotEmpty) usageWarnings.addAll(usage.warnings);
    final firstInput =
        input != null && input > 0 ? input : (usage.promptTokens ?? 0);
    if (firstCompleteInputTokens == null && firstInput > 0) {
      firstCompleteInputTokens = firstInput;
    }
    lastPromptTokens = usage.promptTokens ?? 0;
    lastCompletionTokens = usage.completionTokens ?? 0;
    lastCacheReadTokens = read;
    lastTotalInputTokens = usage.totalInputTokens ?? 0;
    lastRequestWarnings = List.unmodifiable(usage.warnings);
    stepsWithUsage++;
  }

  /// 并账另一累计器。[carryLastRequest] = false 用于子代理并账：
  /// last* 分项语义是"父轮最后一次请求看到的上下文"，子代理是独立
  /// 上下文，不应污染父轮的上下文用量指示口径。
  void merge(AgentUsageAccumulator other, {bool carryLastRequest = true}) {
    promptTokens += other.promptTokens;
    completionTokens += other.completionTokens;
    totalTokens += other.totalTokens;
    totalInputTokens += other.totalInputTokens;
    cacheReadTokens += other.cacheReadTokens;
    cacheCreationTokens += other.cacheCreationTokens;
    cacheComparableInputTokens += other.cacheComparableInputTokens;
    cacheComparableReadTokens += other.cacheComparableReadTokens;
    cacheComparableSteps += other.cacheComparableSteps;
    usageWarnings.addAll(other.usageWarnings);
    hasCacheReadTokens = hasCacheReadTokens || other.hasCacheReadTokens;
    hasCacheCreationTokens =
        hasCacheCreationTokens || other.hasCacheCreationTokens;
    if (carryLastRequest && other.stepsWithUsage > 0) {
      lastPromptTokens = other.lastPromptTokens;
      lastCompletionTokens = other.lastCompletionTokens;
      lastCacheReadTokens = other.lastCacheReadTokens;
      lastTotalInputTokens = other.lastTotalInputTokens;
      lastRequestWarnings = other.lastRequestWarnings;
      firstCompleteInputTokens ??= other.firstCompleteInputTokens;
    }
    stepsWithUsage += other.stepsWithUsage;
  }
}
