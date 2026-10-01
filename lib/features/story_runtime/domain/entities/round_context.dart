import 'package:lmstory/core/config/intermediate_config.dart'
    show ContextBudget;
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session_settings.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/scored_memory.dart';
import 'package:lmstory/features/memory/domain/services/fact_context_builder.dart';
import 'package:lmstory/features/story_runtime/domain/entities/classified_keywords.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_runtime_config.dart';

/// 轮次上下文（：自动重试时复用各阶段参数与产出）
///
/// sendMessage 时创建，存入 IntermediateChatController._round。
/// 各阶段产出（generatedText/keywords/scoredMemories）在阶段完成后填充，
/// 供同阶段重试（复用输入）和后续阶段（读取前阶段产出）使用。
///
/// persist 成功 / cancel / clearRound / retry 时置 null。
/// failed 状态下保留 _round，供"从中断处继续"（continueFromFailed）复用。
///
/// Phase 5 从 IntermediateChatController 内部类提取为公开类，
/// 供 PhaseHandler 各阶段共享（行为等价，不改变四步流程）。
class RoundContext {
  RoundContext({
    required this.userInput,
    required this.history,
    required this.settings,
    required this.generatingNamingConfig,
    required this.extractNamingConfig,
    required this.reviewingNamingConfig,
    required this.summarizeNamingConfig,
    required this.contextWindow,
    required this.config,
    required this.embeddingConfig,
    required this.turnNumber,
    required this.connectTimeout,
    required this.readTimeout,
    this.currentNarrativeTime,
  });

  final String userInput;

  /// 对话历史（改为 mutable，压缩后替换为压缩后的历史）
  ///
  /// compacting 阶段若触发压缩，会用压缩后的消息列表（摘要 + boundary 之后的消息）
  /// 替换此字段，使后续 generating/reviewing 阶段使用压缩后的历史。
  /// 未触发压缩时保持原始历史不变。
  List<ChatMessage> history;
  final ChatSessionSettings settings;

  /// generating 阶段的模型配置（分步骤模型配置）
  final NamingConfig generatingNamingConfig;

  /// extracting 阶段的模型配置（分步骤模型配置）
  final NamingConfig extractNamingConfig;

  /// reviewing 阶段的模型配置（分步骤模型配置）
  final NamingConfig reviewingNamingConfig;

  /// summarizing 阶段的模型配置（分步骤模型配置）
  final NamingConfig summarizeNamingConfig;

  /// 向后兼容别名：等价于 [generatingNamingConfig]
  ///
  /// 保留给控制器中 `_autoNameSession` / `_maybeConsolidateMemories` 等
  /// 非阶段特定调用使用（标题生成 / 记忆提炼复用生成阶段模型）。
  NamingConfig get namingConfig => generatingNamingConfig;

  final int contextWindow;

  /// 模式无关配置聚合（2026-08-27 导演设置体系，设计文档 §3.1）
  ///
  /// 故事/导演控制器各自从 IntermediateConfig / AdvancedConfig 经
  /// `.storyRuntime` 组装；本字段不再定型为某一模式的顶层配置。
  final StoryRuntimeConfig config;

  /// 网络连接超时（来自全局 network.connect_timeout_ms）
  ///
  /// 各阶段构建 `LlmRequest` 时透传到 HttpClient.streamPost，
  /// 确保故事模式 9 处 LLM 请求构造点统一使用用户配置的超时值。
  /// 修复前：所有 LlmRequest 未传 timeout，回退到 HttpClient 硬编码 15s/30s，
  /// 用户在通用设置→高级调整的超时值对故事模式无效。
  final Duration connectTimeout;

  /// 响应读取超时（来自全局 network.receive_timeout_ms）
  ///
  /// 同 [connectTimeout]，用于 LlmRequest 透传到 HttpClient.streamPost。
  /// 故事模式多阶段 LLM 调用单轮可能消耗较长时间，用户调高响应超时是常见诉求。
  final Duration readTimeout;

  /// 语义检索 embedding 配置（全局，null = 未配置 → FTS5 兜底）
  final EmbeddingApiConfig? embeddingConfig;

  /// 当前轮次序号（会话级元数据，由控制器在 sendMessage 时填充）
  ///
  /// 用途：
  /// - 检索阶段：作为 `currentTurnNumber` 推导时间衰减
  /// - 摘要阶段：填充 `EventSummary.turnNumber`（非 LLM 输出）
  ///
  /// 推导公式（修复 2026-08-23）：
  /// `压缩基数 + 可见真实对话消息数 ~/ 2 + 1`（每轮 = user + assistant
  /// 两条；基数 = 已被 CompactionPoint 覆盖的完整轮数，先除后加）。
  final int turnNumber;

  /// 会话当前叙事时间（v0.2 叙事时间机制，2026-07-25 新增）
  ///
  /// 从 `chat_sessions.current_narrative_time` 读取，表示上一轮结束时
  /// 的叙事时间。summarizing 阶段注入到提示词的【最近叙事时间线】中，
  /// 供 LLM 判断本轮时间是否推进。null 表示首轮或尚未建立叙事时间。
  final String? currentNarrativeTime;

  // 阶段产出（随阶段推进填充）

  /// CompactionPoint 压缩摘要（compacting 阶段产出，新增）
  ///
  /// 当总占用 token 超过 [ContextBudget.compactionTriggerRatio] 时触发压缩，
  /// LLM 将旧对话压缩为一段剧情宏观骨架摘要。
  ///
  /// **双重职责**（会议纪要 §5.5 废弃宏摘要决策）：
  /// 1. 作为 generating/reviewing 的稳定前缀 system 消息注入（提升 LLM 缓存命中率）
  /// 2. 作为宏摘要留档写入 experiential_memories（memory_level=macro，
  ///    macroTriggerReason=compaction），不参与语义检索
  ///
  /// null 表示本轮未触发压缩（token 未超阈值）。
  /// 非空时，[history] 已被替换为压缩后的消息列表。
  ///
  /// **持久化时机**（会议纪要 §7.1 整轮事务性）：
  /// compacting 阶段仅生成摘要存内存，不写 DB。
  /// persisting 阶段将摘要写入 chat_messages + compaction_points +
  /// experiential_memories（macro 级别），与回复写入在同一事务内。
  String? compactionSummary;

  /// 压缩 boundary 消息 ID（compacting 阶段产出，新增）
  ///
  /// 记录压缩范围的边界消息（最后一条被压缩的消息的 messageId）。
  /// persisting 阶段据此创建 CompactionPoint 记录。
  /// null 表示本轮未触发压缩。
  String? compactionBoundaryMessageId;

  /// 压缩摘要消息（compacting 阶段产出，新增）
  ///
  /// 内存中创建的摘要消息（isSummary=true，role=system），
  /// 已放入 [history] 首位供 generating/reviewing 使用。
  /// persisting 阶段将此消息写入 chat_messages（持久化），
  /// 并在 compaction_points 表记录 summaryMessageId ↔ boundaryMessageId 映射。
  /// null 表示本轮未触发压缩。
  ChatMessage? compactionSummaryMessage;

  /// 分段宏摘要（compacting 阶段产出，v0.2.3 新增）
  ///
  /// 仅覆盖本次压缩新增轮次的分段宏摘要文本。
  /// null 表示首次压缩（压缩摘要兼作宏摘要）或本轮未触发压缩。
  /// persisting 阶段将其写入 experiential_memories（memory_level=macro,
  /// importance=3），供记忆检索和记忆查看器使用。
  String? segmentMacroSummary;

  /// 生成正文（generating 阶段产出）
  String? generatedText;

  /// 中断续写前缀
  ///
  /// generating 失败续跑（continueFromFailed）时由控制器填入失败前已
  /// 写出的半截正文；非 null 时 generating 阶段组装请求把「原指令 + 已写
  /// 正文 + 续写指令块」作为用户消息注入（从中断处自然继续，不重复已有
  /// 内容）。一次性消费语义：新轮创建时保持 null。
  String? continuationPrefix;

  /// 检索关键词（extracting 阶段产出，compact 模式下可能为空）
  ClassifiedKeywords? keywords;

  /// 检索到的相关记忆（retrieving 阶段产出）
  List<ScoredMemory>? scoredMemories;

  /// 检索到的事实块（retrieving 阶段产出，DOC-11 §6.1）
  ///
  /// 由 FactContextBuilder 产出，包含【世界设定】注入文本和命中事实列表。
  /// null 表示事实层未启用或未注入；非 null 但 factBlock 为空字符串表示禁用。
  /// reviewing 阶段据此注入【世界设定】区块到 prompt。
  /// UI 检索面板据此展示事实类分区。
  FactRetrievalResult? retrievedFacts;

  /// 最终回复正文（reviewing 阶段产出）
  ///
  /// 四步拆分后，reviewing 步骤独立产出 replyText。
  /// 2026-07-16 优化项10：移除 compact 降级后，reviewing 始终执行，
  /// replyText 总是来自 reviewing 阶段（不再有 replyText = generatedText 的降级路径）。
  String? replyText;

  /// 最终回复的思考/推理内容（reviewing 阶段产出）
  ///
  /// 当模型支持 reasoning 且发送了 `reasoning_effort` 参数时，LLM 返回的
  /// 思考内容会累积到这里，供 persist 阶段写入消息的 thinkingContent 字段。
  String? thinkingContent;

  /// 事件摘要（summarizing 阶段产出）
  EventSummary? eventSummary;

  /// 事实变更列表（summarizing 阶段产出，DOC-11 §4.4 双工具并行调用）
  ///
  /// summarizing 阶段通过 `extract_facts` 工具调用产出。空列表表示本轮
  /// 无事实变更；null 表示 summarizing 阶段未执行或 facts 工具未调用。
  /// persisting 阶段据此决定是否调用 FactApplier 应用事实变更。
  List<FactsDelta>? factsDeltas;

  /// 2026-07-16 优化项10：compact 降级已移除，此字段保留但不再被设置。
  ///
  /// 历史用途：retrieving 阶段末尾根据 keywords/scoredMemories 是否为空设置，
  /// reviewing 阶段据此分支：true → 仅生成 EventSummary，reply=generatedText。
  /// 现状：reviewing 始终执行（有双重功能：按记忆修正 + 润色文案），
  /// 注入前质量过滤在 ContextBuilder._formatMemories 中完成。
  /// 保留字段供向后兼容，但恒为 false。
  bool skipReview = false;
}
