import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/intermediate_config.dart'
    show
        ConsolidationConfig,
        ContextBudget,
        ContextConfig,
        EmbeddingConfig,
        IntermediateConfig,
        MemoryConfig,
        PromptsConfig,
        RetrievalConfig,
        RetryConfig,
        StreamConfig;

/// story_runtime 共享服务（压缩/持久化/归并/检索）消费的模式无关配置聚合。
///
/// 故事与导演各自由自己的顶层配置（IntermediateConfig / AdvancedConfig）
/// 组装出本聚合——共享的是数据形状与服务实现，不是配置键（设计文档 §3.1，
/// "两个产品"原则）。
///
/// 字段清单按 2026-08-27 消费点审计定稿：contextBudget/context/embedding/
/// memory/consolidation/retrieval/reviewEnabled 为两侧共享服务消费；
/// prompts/systemPrompt/stream 为故事侧 PhaseHandler 消费（导演侧仅
/// prompts.consolidationPrompt 一条，经 [consolidationPrompt] 便捷访问），
/// AdvancedConfig 组合同名值类，两侧同构；retry 为故事 RetryScheduler
/// 专用（导演 agent loop 用自身预算模型，组装侧固定传默认值，设计文档 §4）。
class StoryRuntimeConfig {
  const StoryRuntimeConfig({
    required this.contextBudget,
    required this.context,
    required this.embedding,
    required this.memory,
    required this.consolidation,
    required this.retrieval,
    required this.prompts,
    required this.systemPrompt,
    required this.stream,
    required this.reviewEnabled,
    this.retry = const RetryConfig(),
    this.engineeringCompaction = const AdvancedEngineeringCompactionConfig(),
  });

  final ContextBudget contextBudget;
  final ContextConfig context;
  final EmbeddingConfig embedding;
  final MemoryConfig memory;

  /// 工程上下文压缩参数（开启态；默认值唯一来源=default_config.json
  /// advanced.engineering_compaction 段；关闭态不消费）
  final AdvancedEngineeringCompactionConfig engineeringCompaction;
  final ConsolidationConfig consolidation;
  final RetrievalConfig retrieval;
  final PromptsConfig prompts;

  /// 全局系统提示词（故事：intermediate.system_prompt；导演：advanced.system_prompt）
  final String systemPrompt;
  final StreamConfig stream;
  final bool reviewEnabled;

  /// 故事 RetryScheduler 专用重试策略（intermediate.retry.*）
  ///
  /// 导演不消费（agent loop 预算/重试模型在 advanced.budget），组装侧传默认值。
  final RetryConfig retry;

  /// 归并提示词便捷访问（导演侧唯一消费的 prompts 条目）
  String get consolidationPrompt => prompts.consolidationPrompt;

  /// 替换子段（会话级 contextBudget override 合并用）
  StoryRuntimeConfig copyWith({ContextBudget? contextBudget}) =>
      StoryRuntimeConfig(
        contextBudget: contextBudget ?? this.contextBudget,
        context: context,
        embedding: embedding,
        memory: memory,
        engineeringCompaction: engineeringCompaction,
        consolidation: consolidation,
        retrieval: retrieval,
        prompts: prompts,
        systemPrompt: systemPrompt,
        stream: stream,
        reviewEnabled: reviewEnabled,
        retry: retry,
      );
}

extension IntermediateStoryRuntime on IntermediateConfig {
  StoryRuntimeConfig get storyRuntime => StoryRuntimeConfig(
        contextBudget: contextBudget,
        context: context,
        embedding: embedding,
        memory: memory,
        consolidation: consolidation,
        retrieval: retrieval,
        prompts: prompts,
        systemPrompt: systemPrompt,
        stream: stream,
        reviewEnabled: reviewEnabled,
        retry: retry,
      );
}

extension AdvancedStoryRuntime on AdvancedConfig {
  StoryRuntimeConfig get storyRuntime => StoryRuntimeConfig(
        // 2026-09-13 上下文配置收敛（计划 §2.1-4）：导演无三段式预算，
        // 检索预留与保留量下限由引擎内定，见 [DirectorContextBudgetPin]。
        contextBudget: contextBudget.directorPinned,
        context: context,
        embedding: embedding,
        memory: memory,
        engineeringCompaction: engineeringCompaction,
        consolidation: consolidation,
        retrieval: retrieval,
        prompts: prompts,
        systemPrompt: systemPrompt,
        //  审查移除 advanced.stream 段后：导演侧共享服务不消费 stream
        //（PhaseHandler 是故事侧专属），组装传默认值即可
        stream: const StreamConfig(),
        reviewEnabled: reviewEnabled,
      );
}

/// 导演模式的压缩预算形态：单一「上下文压缩阈值」旋钮（收敛计划 §2.1-4）。
///
/// `recentMinRatio`（原文区下限）与 `retrievalRatio`（检索区比例）是故事
/// 模式三段式预算（摘要前缀+原文区+检索区）的概念；导演请求装配走 agent
/// harness（core blocks + 历史 + 尾部），没有三段结构。压缩服务
/// （StoryCompactionService）零改动照常消费 ContextBudget，导演侧数值由
/// 本定值决定：检索预留 0、原文区下限动态（目标值沿用
/// recentMinTokenTarget）、压缩阈值原样透传。
extension DirectorContextBudgetPin on ContextBudget {
  /// 触发线钳制域（导演 UI 滑杆范围；手改 user_overrides / 导入备份
  /// 可写入域外值，钳死防轮前压缩饿死/触不到）。
  static const double triggerFloor = 0.30;
  static const double triggerCeil = 0.80;

  ContextBudget get directorPinned => ContextBudget(
        compactionTriggerRatio: compactionTriggerRatio,
        // 原文区下限走默认动态（null）；不变量由 story_runtime_config_test
        // 断言守护，防止未来默认值变化悄悄改掉定值
        // 检索预留定死 0（默认 0.15）
        retrievalRatio: 0,
        recentMinTokenTarget: recentMinTokenTarget,
      );

  /// 触发线钳制 + 落到导演定值形态（单一真源）。
  ///
  /// 会话覆盖优先于全局；两者都过 [triggerFloor, triggerCeil] 钳制。
  /// 输出与 [directorPinned] 同形态（检索预留 0、原文区下限动态），
  /// 仅触发线替换为生效值——此前控制器内联第二份钳制副本与此处的
  /// 定值各自为政，收敛到本方法防口径漂移。
  ContextBudget directorClamped({required double? sessionOverride}) {
    final effective = (sessionOverride ?? compactionTriggerRatio)
        .clamp(triggerFloor, triggerCeil);
    return ContextBudget(
      compactionTriggerRatio: effective,
      retrievalRatio: 0,
      recentMinTokenTarget: recentMinTokenTarget,
    );
  }
}
