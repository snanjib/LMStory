import 'dart:typed_data';

import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/facts_change_record.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/story_runtime/domain/entities/message_variant_record.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/services/compaction_service.dart'
    show CompactionResult;

/// The process and manuscript versions for explicitly requested turns.
typedef StoryHistoryTurnDetails = ({
  Map<int, StoryRoundArtifacts> artifacts,
  Map<int, List<MessageVariantRecord>> variants,
});

/// Bounded history reads. The older whole-session readers remain available on
/// [StoryPersistenceService] for callers that need every historical detail.
abstract interface class StoryHistoryReadStore {
  /// Keep a history write and its readback in the same SQLite transaction.
  Future<T> runHistoryTransaction<T>(Future<T> Function() operation);

  Future<StoryHistoryTurnDetails> loadHistoryTurnDetails(
    String sessionId,
    Set<int> turns,
  );

  /// One entry per stored round, including rounds without a usable summary.
  Future<Map<int, AgentWorkSummary?>> loadHistorySummaries(String sessionId);
}

/// 编辑重发或重生成时保留的旧稿及其来源信息。
typedef RoundVariantSnapshot = ({
  ChatMessage assistant,
  String? sourceInput,
  StoryRoundArtifacts? process,
});

/// 回退已提交。调用方可同步会话状态及冻结前缀备忘。
typedef RoundRollbackResult = ({
  StoryAnchor? storyAnchor,
  String? narrativeTime,
  int messageCount,
  bool deletedFrozenPrefix,
});

/// 中级模式原子持久化服务（DOC-09C §1）
///
/// 提供四个原子持久化操作，均包在**单一 drift transaction** 内执行，
/// 保证原子性（DOC-08 §6.1）。单条事实写入失败只回滚该条并在结果中计数。
/// 整轮事务失败时回滚并抛出异常（Controller 捕获后置 phase=failed, E018）。
///
/// - [persistRound]：持久化一轮新对话（写 user + assistant + 事件摘要）
/// - [persistRegeneratedRound]：重新生成场景持久化（只写 assistant，user 已存在）
/// - [deleteRoundAndDownstream]：删除指定轮次及下游所有消息 + 事件摘要
/// - [persistConsolidatedMemories]：批量记忆提炼结果持久化（新增）
///
///  修复（DOC-09A-1 §1.5 修订）：
/// - persistRound / persistRegeneratedRound 同事务写入 [StoryRoundArtifacts]
///   到 intermediate_round_artifacts 表，持久化生成内容/关键词/检索结果
/// - 新增 [loadArtifactsBySession] 供 Controller.loadHistory 批量加载历史 artifacts
///
/// persistRound / persistRegeneratedRound 新增可选
/// `compaction` 参数，在**同一事务**内持久化 CompactionPoint 压缩摘要：
/// - INSERT 摘要消息 → chat_messages（isSummary=true, role=system）
/// - INSERT 压缩点记录 → compaction_points（summaryMessageId ↔ boundaryMessageId）
/// - INSERT 宏摘要记忆 → experiential_memories（memory_level=macro,
///   macroTriggerReason=compaction），不参与语义检索
abstract interface class StoryPersistenceService {
  /// 原子持久化一轮对话
  ///
  /// 步骤（DOC-09C §1， 扩展，DOC-11 §8.2 事务一致性）：
  /// 1. INSERT user message → chat_messages
  /// 2. INSERT assistant message → chat_messages
  /// 3. INSERT event summary → experiential_memories（has_embedding=false 先写）
  /// 4. 若 [embedding] 非空：UPDATE embedding + has_embedding=true
  /// 5. 若 [indexForRetrieval]=true：INSERT FTS5 索引 → memories_fts
  /// 6. UPDATE session（lastActiveAt, messageCount+2）
  /// 7. 若 [artifacts] 非空：INSERT intermediate_round_artifacts（新增）
  /// 8. 若 [factsDeltas] 非空 + Impl 注入了 FactApplier：
  ///    应用事实变更 → factual_entities / factual_attributes /
  ///    factual_memory_history（每条事实与流水使用同一保存点）
  /// 9. 若 [compaction] 非空（新增）：
  ///    INSERT 摘要消息 + compaction_points + experiential_memories(macro)
  ///
  /// [embedding] 为 null 表示 embedding 生成降级（has_embedding=false，事务仍提交）。
  /// [artifacts] 为 null 表示无中间产物需持久化（向后兼容旧调用方）。
  /// [indexForRetrieval] 为 false 时跳过 FTS5 索引（：importance < threshold
  /// 的低重要性记忆不建索引，仍写入 experiential_memories 供后续批量提炼）。
  /// [factsDeltas] 为 null/空表示本轮无事实变更（跳过事实层写入）。
  /// [factualConfig] 事实层配置（仅在 [factsDeltas] 非空时使用）。
  /// [compaction] 压缩持久化数据（仅在本轮触发了 CompactionPoint 压缩时非空）。
  ///
  /// 返回已提交的经历记忆、成功的事实变更记录和事实写入失败数。
  Future<PersistRoundResult> persistRound({
    required ChatMessage userMessage,
    required ChatMessage assistantMessage,
    required EventSummary eventSummary,
    required Float32List? embedding,
    required StoryRoundArtifacts? artifacts,
    bool indexForRetrieval = true,
    List<FactsDelta>? factsDeltas,
    FactualConfig? factualConfig,
    CompactionPersistenceData? compaction,
    String? variantSourceInput,
    bool hasVerifiedSourceTurn = false,
  });

  /// 原子持久化重新生成的助手回复（简化 Fork）
  ///
  /// 用于"重新生成"场景：用户消息（user_N）已存在于 chat_messages，
  /// 仅需写入新的助手回复 + 事件摘要。与 [persistRound] 的差异：不写 user 消息，
  /// session messageCount +1（非 +2）。
  ///
  /// 步骤：
  /// 1. INSERT assistant message → chat_messages
  /// 2-5. 同 [persistRound] 步骤 3-6（事件摘要 + embedding + FTS + 会话元数据）
  /// 6. 若 [artifacts] 非空：INSERT intermediate_round_artifacts（新增）
  /// 7. 若 [factsDeltas] 非空 + Impl 注入了 FactApplier：应用事实变更
  ///    （每条事实与流水使用同一保存点）
  /// 8. 若 [compaction] 非空（新增）：同 [persistRound] 步骤 9
  ///
  /// [assistantMessage].sessionId 用于关联事件摘要和会话元数据。
  /// [indexForRetrieval] 语义同 [persistRound]（新增）。
  /// [factsDeltas] / [factualConfig] 语义同 [persistRound]。
  /// [compaction] 语义同 [persistRound]。
  /// 返回已提交的经历记忆、成功的事实变更记录和事实写入失败数。
  Future<PersistRoundResult> persistRegeneratedRound({
    required ChatMessage assistantMessage,
    required EventSummary eventSummary,
    required Float32List? embedding,
    required StoryRoundArtifacts? artifacts,
    bool indexForRetrieval = true,
    List<FactsDelta>? factsDeltas,
    FactualConfig? factualConfig,
    CompactionPersistenceData? compaction,
    bool recordVariant = false,
    String? variantSourceInput,
    bool hasVerifiedSourceTurn = false,
  });

  /// 原子持久化手动压缩结果（上下文用量指示设计 §4.3）
  ///
  /// 与轮前自动压缩同口径单事务写入（复用压缩持久化三步）：
  /// 1. INSERT 摘要消息 → chat_messages
  /// 2. INSERT 压缩点 → compaction_points
  /// 3. INSERT 宏摘要 → experiential_memories + memories_fts
  /// 4. UPDATE 会话 lastActiveAt + messageCount（读取实际消息数后设绝对值）
  Future<void> persistManualCompaction({
    required CompactionPersistenceData compaction,
  });

  /// 撤销最新一次压缩（2026-09-04 撤销压缩，单事务）
  ///
  /// 压缩从不删除旧消息（filterByCompactionPoint 只是视图过滤），撤销即
  /// 删三条记录、旧对话自然回到可见列表与上下文：
  /// 1. DELETE 最新压缩点 → compaction_points
  /// 2. DELETE 摘要消息行 → chat_messages
  /// 3. DELETE 该次压缩的宏摘要记忆 + FTS 索引（最新一条
  ///    memoryLevel=macro 且 macroTriggerReason=compaction）
  /// 4. UPDATE 会话 lastActiveAt + messageCount（同 persistManualCompaction 口径）
  ///
  /// 多次压缩叠加时只回剥最新一次，逐次调用逐次回剥。
  /// 无压缩点时返回 false（幂等，不抛异常）。
  Future<bool> undoCompaction({required String sessionId});

  /// 原子删除指定轮次及下游所有消息 + 事件摘要（简化 Fork）
  ///
  /// 用于"重新生成/编辑重发/删除整轮"的删除阶段：
  /// 1. 删除 turn_number >= [fromTurnNumber] 的经历记忆 + FTS 索引
  ///    （调 ExperienceRepository.deleteExperienceByTurns）
  /// 2. 删除 [messageIdsToDelete] 列表中的所有 chat_messages
  ///    （循环 ChatRepository.deleteMessage，物理 DELETE 无级联）
  /// 3. UPDATE session（lastActiveAt, messageCount = 实际消息数）
  /// 4. 删除 turn_number >= [fromTurnNumber] 的 intermediate_round_artifacts
  ///    （新增：清理历史小窗的持久化数据）
  /// 5. 删除事实层 createdTurn >= [fromTurnNumber] 的实体及审计历史
  ///    （经 FactApplier.deleteFactsByTurns，防止重写后设定串戏。
  ///    事实层禁用时 _factApplier 为 null，跳过此步）
  ///
  /// [messageIdsToDelete] 由 Controller 从 state.messages 按索引推导
  /// （chat_messages 无 turn_number 列，无法按 turn 删消息）。
  ///
  /// [keepVariantsAtFromTurn]：true = 保留起始轮的稿件变体
  /// （重生成/编辑重发——旧版快照在删除前已落，新版随后接管指针），
  /// 仅清 turn > fromTurnNumber 的下游变体；false（删轮）= 连起始轮
  /// 变体一并物理删除。
  ///
  /// 返回值：回滚后
  /// chat_sessions.story_anchor 应处的值——存活 artifacts（turn <
  /// fromTurnNumber）中最近一份轮末锚；无 = null（回到未设锚，如第一轮
  /// 即被删）。已在同一删除事务内写回 DB，返回值仅供调用方同步内存态。
  Future<StoryAnchor?> deleteRoundAndDownstream({
    required String sessionId,
    required int fromTurnNumber,
    required List<String> messageIdsToDelete,
    bool keepVariantsAtFromTurn = false,
  });

  /// 在一个事务内保存旧稿（如有）、删除本轮及下游，并回拨叙事时间。
  ///
  /// [truncateEvents] 在故事数据删除后运行，必须使用同一个数据库连接。
  /// 它收到与故事数据一致的会话、起始轮次，返回是否截断了冻结前缀。
  /// 任一步骤失败时回滚全部写入。
  Future<RoundRollbackResult> rollbackRoundAndDownstream({
    required String sessionId,
    required int fromTurnNumber,
    required List<String> messageIdsToDelete,
    bool keepVariantsAtFromTurn = false,
    RoundVariantSnapshot? variantSnapshot,
    Future<bool> Function(String sessionId, int fromTurnNumber)? truncateEvents,
  });

  /// 批量加载会话的所有轮次 artifacts（新增）
  ///
  /// 供 Controller.loadHistory 调用，按 turnNumber 索引返回 Map。
  /// UI 渲染时按 assistant message 的 turnNumber 关联到对应 artifacts。
  ///
  /// 返回 Map<int, StoryRoundArtifacts>：key=turnNumber，value=artifacts。
  /// 没有持久化 artifacts 的轮次不会出现在 Map 中（缺失即视为无 artifacts）。
  Future<Map<int, StoryRoundArtifacts>> loadArtifactsBySession(
    String sessionId,
  );

  // ── ：稿件变体（非破坏性重生成）────

  /// 把当前版本快照为变体（重生成/编辑重发的删除阶段**之前**调用）
  ///
  /// 单事务 INSERT message_variants 一行（变体索引 = 该轮现有最大 + 1），
  /// 返回分配的变体索引。过程数据（agent 步骤/时间线/摘要/锚）从
  /// [process]（controller 内存中的 artifacts）序列化。
  Future<int> snapshotMessageVariant({
    required String sessionId,
    required int turnNumber,
    required String? content,
    String? thinkingContent,
    String? sourceInput,
    StoryRoundArtifacts? process,
  });

  /// 批量加载会话全部变体（loadHistory 调用；key=turnNumber）
  Future<Map<int, List<MessageVariantRecord>>> loadMessageVariants(
    String sessionId,
  );

  /// 切换当前变体（单事务）
  ///
  /// 1. chat_messages 的 [assistantMessageId] 行 content/thinking_content
  ///    改写为所选变体（上下文组装读 content 即读当前变体）
  /// 2. intermediate_round_artifacts 行 current_variant_index 指向所选
  ///    变体，agent 过程列/事件摘要/事实变更展示改写为变体快照
  /// 3. 保存切走稿的活动经历，撤销本轮派生，再按所选稿自己的事实增量与
  ///    经历快照恢复。所选稿没有派生记录时只撤销废弃的轮效果。
  ///
  /// 调用方先确认该轮未被压缩。服务核对末轮、消息所属会话与快照身份。
  /// 已选中该稿时返回 true。目标缺失、归属不明或缺少重放所需的
  /// [factualConfig] 时返回 false，当前稿和派生记录保留。存储故障抛出
  /// 异常，事务整体回滚。
  Future<bool> switchMessageVariant({
    required String sessionId,
    required int turnNumber,
    required int variantIndex,
    required String assistantMessageId,
    FactualConfig? factualConfig,
  });

  /// 编辑助手消息正文：message 行与当前指针指向的变体行同事务更新。
  ///
  /// 所见=所存——只改 message 行时，切换器往返会把变体行的旧正文拷回
  /// message 行，用户编辑被静默回退。同事务同步当前变体行（artifacts
  /// 的 current_variant_index 所指），切换往返后继续使用编辑正文。
  /// 正文变动时，同时撤销该轮活跃经历与当前变体快照的单轮来源标记。
  Future<bool> updateAssistantContentAndCurrentVariant({
    required String sessionId,
    required int turnNumber,
    required String assistantMessageId,
    required String newContent,
  });

  /// 编辑用户输入并撤销受影响摘要的单轮来源标记。
  /// 无法确定轮号时保守地撤销该会话的来源标记。
  Future<bool> updateUserContentAndInvalidateSourceTurn({
    required String sessionId,
    required int? turnNumber,
    required String userMessageId,
    required String newContent,
  });

  /// 删除非当前变体（当前指针所指变体由调用方守卫不传入）
  Future<void> deleteMessageVariant({
    required String sessionId,
    required int turnNumber,
    required int variantIndex,
  });

  /// 原子持久化批量记忆提炼结果。
  ///
  /// [originalMemories] 是提交给模型的源经历快照。事务内先确认它们仍
  /// 属于本会话、未归档、未被索引，且模型所用内容没有变更。任一源失效
  /// 或任一列表为空时，整批跳过并返回 false。
  /// 有效时写入 [records]（含 FTS 和可选向量）、删除全部源经历并返回
  /// true。写入异常使事务回滚并向调用方抛出。
  Future<bool> persistConsolidatedMemories({
    required String sessionId,
    required List<ConsolidatedMemoryRecord> records,
    required List<ExperientialMemory> originalMemories,
  });
}

/// 单轮持久化结果。
///
/// 由 [StoryPersistenceService.persistRound] /
/// [StoryPersistenceService.persistRegeneratedRound] 返回。
class PersistRoundResult {
  const PersistRoundResult({
    required this.memory,
    this.factsChanges = const [],
    this.factWriteFailureCount = 0,
  }) : assert(factWriteFailureCount >= 0, 'Failure count cannot be negative');

  /// 写入的经历记忆（含 memoryId）
  final ExperientialMemory memory;

  /// 本轮应用到事实层的变更记录（无变更或事实层禁用时为空列表）
  final List<FactsChangeRecord> factsChanges;

  /// 本轮写入失败并单独回滚的事实变更数，仅用于本次收稿反馈。
  final int factWriteFailureCount;
}

/// 批量记忆提炼持久化记录（新增）
///
/// 由 Controller 从 `ConsolidatedMemory`（MemoryConsolidator 产出）构建，
/// 补充 [turnNumber]（取参与合并的原始记忆最大 turnNumber）与 [embedding]
/// （若 embedding 配置可用）。供 [StoryPersistenceService.persistConsolidatedMemories]
/// 在事务内写入 experiential_memories + memories_fts。
class ConsolidatedMemoryRecord {
  const ConsolidatedMemoryRecord({
    required this.summary,
    required this.tags,
    required this.importance,
    required this.turnNumber,
    this.embedding,
  });

  final String summary;
  final List<String> tags;
  final int importance;
  final int turnNumber;
  final Float32List? embedding;
}

/// CompactionPoint 压缩持久化数据（新增）
///
/// 由 Controller 从 [CompactionResult]（StoryCompactionService.compact 产出）
/// 构建，供 [StoryPersistenceService.persistRound] /
/// [StoryPersistenceService.persistRegeneratedRound] 在**同一事务**内写入：
///
/// 1. INSERT [summaryMessage] → chat_messages（isSummary=true, role=system）
/// 2. INSERT 压缩点记录 → compaction_points（summaryMessageId ↔ boundaryMessageId）
/// 3. INSERT 宏摘要记忆 → experiential_memories（memory_level=macro,
///    macroTriggerReason=compaction）
///
/// **事务性**（会议纪要 §7.1）：compacting 阶段仅生成摘要存内存，
/// persisting 阶段将摘要与回复写入在同一事务内，保证原子性。
///
/// 关联设计§5.5
class CompactionPersistenceData {
  const CompactionPersistenceData({
    required this.summaryMessage,
    required this.boundaryMessageId,
    required this.turnNumber,
    this.segmentMacroSummary,
    this.macroEmbedding,
  });

  /// 压缩摘要消息（内存中已创建，含 messageId）
  ///
  /// role=system, isSummary=true，content 为压缩摘要文本。
  /// 持久化时 INSERT 到 chat_messages，下次 loadHistory 时作为历史首条加载。
  final ChatMessage summaryMessage;

  /// 压缩边界消息 ID（最后一条被压缩的消息的 messageId）
  ///
  /// 用于 compaction_points 表记录 summaryMessageId ↔ boundaryMessageId 映射，
  /// 供后续 fork/删除操作定位压缩范围。
  final String boundaryMessageId;

  /// 当前轮次号（用于 experiential_memories 的 turnNumber 字段）
  ///
  /// 宏摘要记忆写入 experiential_memories 时使用，便于按轮次检索和回滚。
  final int turnNumber;

  /// 分段宏摘要文本（v0.2.3 新增）
  ///
  /// 非空时作为 macro 记忆的 summary 写入（仅覆盖本次压缩新增轮次）。
  /// 为空时使用 [summaryMessage] 的 content 作为 macro 记忆（首次压缩）。
  final String? segmentMacroSummary;

  /// 宏摘要向量
  ///
  /// Controller 侧对宏文本（segmentMacroSummary ?? summaryMessage.content）
  /// 预计算；非空时在 appendMacroExperience 之后同事务写入，兑现接口注释
  /// 「宏摘要始终建 FTS5 索引 + 向量化」的承诺。null = 未配置嵌入或计算
  /// 失败降级（has_embedding=false，FTS5 兜底，重建向量索引可补）。
  final Float32List? macroEmbedding;
}
