import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;
import 'package:lmstory/core/config/intermediate_config.dart';
// TODO(decouple): domain→advanced 临时边（导演 UI 实体），P2 拆 state 时消除
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/facts_change_record.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';
import 'package:lmstory/features/memory/domain/services/fact_context_builder.dart';
import 'package:lmstory/features/story_runtime/domain/entities/message_variant_record.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/services/persistence_service.dart';

/// 中级模式原子持久化服务实现（DOC-09C §1）
///
/// 在单一 drift transaction 内编排写入步骤，保证原子性（DOC-08 §6.1）。
/// 提供四个方法：[persistRound]（新对话）、[persistRegeneratedRound]（重生）、
/// [deleteRoundAndDownstream]（删除轮次及下游）、[loadArtifactsBySession]
/// （批量加载历史 artifacts）。
///
/// 依赖的 Repository 方法（addMessage / appendExperience / updateEmbedding /
/// insertFtsIndex / updateSessionLastActive / updateSessionMessageCount /
/// deleteExperienceByTurns / deleteMessage）均不开自己的事务，
/// 可安全嵌套在本服务的外层事务内（已验证）。
/// 仅 `ExperienceRepositoryImpl.deleteAllExperiences` 开自己的事务，本服务不调用它。
///
///  修复：persistRound / persistRegeneratedRound 同事务追加 INSERT 到
/// intermediate_round_artifacts 表；deleteRoundAndDownstream 追加 DELETE。
/// 用 customStatement 直接 SQL 避免生成 Companion 类型依赖。
///
/// DOC-11 §8.2 事务一致性（2026-07-22 修订）：persistRound /
/// persistRegeneratedRound 同事务调用 [FactApplier.applyDeltas]
/// （若 [_factApplier] 注入且 factsDeltas 非空）。
/// **单变更容错**：FactApplier 内部对每个 delta 独立 try-catch，
/// 单个 delta 失败只记录日志不抛异常，不再导致整轮事务回滚。
/// 经历记忆始终能写入，事实层部分成功的 delta 保留。
class StoryPersistenceServiceImpl implements StoryPersistenceService {
  StoryPersistenceServiceImpl({
    required AppDatabase database,
    required ChatRepository chatRepository,
    required ExperienceRepository experienceRepository,
    FactApplier? factApplier,
  })  : _database = database,
        _chatRepository = chatRepository,
        _experienceRepository = experienceRepository,
        _factApplier = factApplier;

  final AppDatabase _database;
  final ChatRepository _chatRepository;
  final ExperienceRepository _experienceRepository;
  final FactApplier? _factApplier;

  @override
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
  }) async {
    return _database.transaction(() async {
      // 0. 若本轮触发了 CompactionPoint 压缩，先写入压缩摘要消息
      //    （isSummary=true, role=system），使其在 chat_messages 中按 createdAt
      //    排序时位于 user/assistant 之前。
      if (compaction != null) {
        await _persistCompactionInTransaction(compaction);
      }

      // 1-2. 用户消息 + 助手回复 → chat_messages
      await _chatRepository.addMessage(userMessage);
      await _chatRepository.addMessage(assistantMessage);

      // 3. 事件摘要 → experiential_memories（先以 has_embedding=false 写入）
      //    叙事时间机制：narrativeTime 写入 experiential_memories
      //    2026-09-09：FTS 索引由 appendExperience 在同一事务内维护
      //    （单一写入口）；indexForRetrieval=false 时不建索引。
      final memory = await _experienceRepository.appendExperience(
        sessionId: userMessage.sessionId,
        summary: eventSummary.summary,
        importance: eventSummary.importance,
        tags: eventSummary.tags,
        turnNumber: eventSummary.turnNumber,
        narrativeTime: eventSummary.narrativeTime,
        when: eventSummary.when,
        where: eventSummary.where,
        who: eventSummary.who,
        what: eventSummary.what,
        significance: eventSummary.significance,
        extra: eventSummary.extra,
        indexForRetrieval: indexForRetrieval,
      );

      // 4. 若 embedding 生成成功 → 更新向量 + has_embedding=true
      //    P1 阶段 embedding 恒为 null（向量化模型未配置，FTS5 兜底），
      //    此分支保留供 P2 启用 embedding_model 配置后激活。
      if (embedding != null) {
        await _experienceRepository.updateEmbedding(
          memory.memoryId,
          embedding,
        );
      }

      // 6. 会话元数据 → chat_sessions（lastActiveAt + messageCount）
      //    updateSessionMessageCount 为绝对值设置（非增量），需读取实际消息数。
      //    与 Simple 模式 MessageManager.updateMessageCount 同模式。
      await _chatRepository.updateSessionLastActive(userMessage.sessionId);
      final newCount =
          await _chatRepository.getMessageCount(userMessage.sessionId);
      await _chatRepository.updateSessionMessageCount(
        userMessage.sessionId,
        newCount,
      );

      // 6.5. 叙事时间 -> chat_sessions.current_narrative_time（同事务）
      //    2026-08-05：从 controller 层移入事务内，避免"消息成功但叙事时间失败"
      //    的不一致状态。失败时异常包含 narrativeTime 关键词便于定位。
      //    若 LLM 未输出 narrativeTime（null/空），跳过更新，保留旧值。
      await _updateNarrativeTimeInTransaction(
        sessionId: userMessage.sessionId,
        narrativeTime: eventSummary.narrativeTime,
      );

      // 6.6.  turn 单一事实源：next_turn = 本轮轮次号 + 1（同事务递增）。
      //     本轮轮次号取 eventSummary.turnNumber（= round.turnNumber，
      //     轮前已按 next_turn ?? 公式 定值，与 artifacts/compaction 同源）。
      await _updateNextTurnInTransaction(
        sessionId: userMessage.sessionId,
        nextTurn: eventSummary.turnNumber + 1,
      );

      // 7. 事实层 → factual_entities / factual_attributes /
      //    factual_memory_history（DOC-11 §8.2 同事务）
      //    先于 artifacts 应用：factsChanges 需写入 artifacts 供变更小窗展示。
      //     修复：原实现位于事务外，现已移入事务内对齐设计文档。
      //    2026-07-22 修订：FactApplier 单变更容错，单个 delta 失败只记录日志
      //    不抛异常，不再导致整轮回滚。经历记忆始终能写入。
      final factsChanges = await _applyFactsInTransaction(
        sessionId: userMessage.sessionId,
        turnNumber: eventSummary.turnNumber,
        factsDeltas: factsDeltas,
        factualConfig: factualConfig,
      );

      // 8. 中间产物 -> intermediate_round_artifacts（新增）
      //    持久化生成内容/关键词/检索结果 + 本轮事实层变更记录（含变更前/后），
      //    使历史轮次小窗切换会话后仍可见。
      if (artifacts != null) {
        await _insertArtifacts(artifacts.copyWithFactsChanges(factsChanges));
      }

      // 8.2. 编辑重发路径的变体收口：旧版已由 controller 在删除阶段前经
      //     snapshotMessageVariant 快照（deleteRoundAndDownstream 以
      //     keepVariantsAtFromTurn 保留变体行），本轮新内容也需记为变体并
      //     移指针，否则旧版快照无 UI 入口（切换器要求变体 >1 且指针非
      //     null）。按「该轮已存在变体行」判定——普通发送轮变体表为空
      //     不受影响；重生成路径走 persistRegeneratedRound（显式
      //     recordVariant）。故事/导演两模式共享此修复。
      if (artifacts != null) {
        final existingVariant = await _database.customSelect(
          'SELECT 1 FROM message_variants '
          'WHERE session_id = ? AND turn_number = ? LIMIT 1',
          variables: [
            Variable.withString(userMessage.sessionId),
            Variable.withInt(artifacts.turnNumber),
          ],
        ).get();
        if (existingVariant.isNotEmpty) {
          final newVariantIndex = await _insertVariantInTransaction(
            sessionId: userMessage.sessionId,
            turnNumber: artifacts.turnNumber,
            content: assistantMessage.content,
            thinkingContent: assistantMessage.thinkingContent,
            sourceInput: variantSourceInput,
            process: artifacts.copyWithFactsChanges(factsChanges),
          );
          await _database.customStatement(
            'UPDATE intermediate_round_artifacts SET current_variant_index = ? '
            'WHERE session_id = ? AND turn_number = ?',
            [newVariantIndex, userMessage.sessionId, artifacts.turnNumber],
          );
        }
      }

      // 8.5. 剧情锚 -> chat_sessions.story_anchor（同事务，体验重构卡片 C）
      //     artifacts.storyAnchor 为"该轮结束时的当前锚"（更新值或继承值）。
      await _updateStoryAnchorInTransaction(
        sessionId: userMessage.sessionId,
        anchor: artifacts?.storyAnchor,
      );

      return PersistRoundResult(memory: memory, factsChanges: factsChanges);
    });
  }

  @override
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
  }) async {
    return _database.transaction(() async {
      // 0. 若本轮触发了 CompactionPoint 压缩，先写入压缩摘要消息
      if (compaction != null) {
        await _persistCompactionInTransaction(compaction);
      }

      // 1. 助手回复 → chat_messages（不写 user 消息，user_N 已存在）
      await _chatRepository.addMessage(assistantMessage);

      // 2. 事件摘要 → experiential_memories（先以 has_embedding=false 写入）
      //    叙事时间机制：narrativeTime 写入 experiential_memories
      //    2026-09-09：FTS 索引由 appendExperience 同事务维护（单一写入口）。
      final memory = await _experienceRepository.appendExperience(
        sessionId: assistantMessage.sessionId,
        summary: eventSummary.summary,
        importance: eventSummary.importance,
        tags: eventSummary.tags,
        turnNumber: eventSummary.turnNumber,
        narrativeTime: eventSummary.narrativeTime,
        when: eventSummary.when,
        where: eventSummary.where,
        who: eventSummary.who,
        what: eventSummary.what,
        significance: eventSummary.significance,
        extra: eventSummary.extra,
        indexForRetrieval: indexForRetrieval,
      );

      // 3. 若 embedding 生成成功 → 更新向量 + has_embedding=true
      if (embedding != null) {
        await _experienceRepository.updateEmbedding(memory.memoryId, embedding);
      }

      // 5. 会话元数据 → chat_sessions（messageCount +1，因只加了 assistant）
      await _chatRepository.updateSessionLastActive(assistantMessage.sessionId);
      final newCount =
          await _chatRepository.getMessageCount(assistantMessage.sessionId);
      await _chatRepository.updateSessionMessageCount(
        assistantMessage.sessionId,
        newCount,
      );

      // 5.5. 叙事时间 -> chat_sessions.current_narrative_time（同事务）
      //    2026-08-05：从 controller 层移入事务内（同 persistRound 步骤 6.5）。
      await _updateNarrativeTimeInTransaction(
        sessionId: assistantMessage.sessionId,
        narrativeTime: eventSummary.narrativeTime,
      );

      // 5.6.  turn 单一事实源：next_turn = 本轮轮次号 + 1（同事务递增，
      //     与 persistRound 步骤 6.6 同口径）。
      await _updateNextTurnInTransaction(
        sessionId: assistantMessage.sessionId,
        nextTurn: eventSummary.turnNumber + 1,
      );

      // 6. 事实层（DOC-11 §8.2 同事务， 修复，2026-07-22 单变更容错）
      //    先于 artifacts 应用：factsChanges 需写入 artifacts 供变更小窗展示。
      final factsChanges = await _applyFactsInTransaction(
        sessionId: assistantMessage.sessionId,
        turnNumber: eventSummary.turnNumber,
        factsDeltas: factsDeltas,
        factualConfig: factualConfig,
      );

      // 7. 中间产物 -> intermediate_round_artifacts（新增，含事实层变更记录）
      if (artifacts != null) {
        await _insertArtifacts(artifacts.copyWithFactsChanges(factsChanges));
      }

      // 7.2. ：把新版记为下一变体并指向它（非破坏性重生成）
      //     旧版已由 controller 在删除阶段前经 snapshotMessageVariant 快照。
      if (recordVariant && artifacts != null) {
        final newVariantIndex = await _insertVariantInTransaction(
          sessionId: assistantMessage.sessionId,
          turnNumber: artifacts.turnNumber,
          content: assistantMessage.content,
          thinkingContent: assistantMessage.thinkingContent,
          sourceInput: variantSourceInput,
          process: artifacts.copyWithFactsChanges(factsChanges),
        );
        await _database.customStatement(
          'UPDATE intermediate_round_artifacts SET current_variant_index = ? '
          'WHERE session_id = ? AND turn_number = ?',
          [newVariantIndex, assistantMessage.sessionId, artifacts.turnNumber],
        );
      }

      // 7.5. 剧情锚 -> chat_sessions.story_anchor（同事务，体验重构卡片 C）
      await _updateStoryAnchorInTransaction(
        sessionId: assistantMessage.sessionId,
        anchor: artifacts?.storyAnchor,
      );

      return PersistRoundResult(memory: memory, factsChanges: factsChanges);
    });
  }

  /// 在当前 drift transaction 内应用事实层 deltas（DOC-11 §8.2）
  ///
  /// 调用前置条件：必须在 `_database.transaction` 闭包内调用。
  /// - [_factApplier] 未注入（v0.2 部分环境）→ 返回空列表
  /// - [factsDeltas] 为 null 或空 → 返回空列表
  /// - [factualConfig] 为 null 或 enabled=false → 返回空列表
  /// - 否则调用 [FactApplier.applyDeltas]（单变更容错：单个 delta 失败
  ///   只记录日志不抛异常，不再导致事务回滚），返回成功应用的变更记录
  ///   （含变更前/变更后），供「事实层变更小窗」展示。
  Future<List<FactsChangeRecord>> _applyFactsInTransaction({
    required String sessionId,
    required int turnNumber,
    required List<FactsDelta>? factsDeltas,
    required FactualConfig? factualConfig,
  }) async {
    final applier = _factApplier;
    if (applier == null) return const [];
    if (factsDeltas == null || factsDeltas.isEmpty) return const [];
    if (factualConfig == null || !factualConfig.enabled) return const [];

    // FactApplier.applyDeltas 不开自身事务，可安全嵌套在本服务的外层事务内
    // （FactualRepositoryImpl 所有写方法均不开自身事务，见 DOC-05-5 §4.6.4）
    // 2026-07-22：单变更容错后，applyDeltas 不会向上抛异常，事务不会因
    // 事实层单个 delta 失败而回滚。
    return applier.applyDeltas(
      sessionId,
      factsDeltas,
      turnNumber,
      factualConfig,
    );
  }

  /// 在当前 drift transaction 内更新 chat_sessions.current_narrative_time
  ///
  /// 调用前置条件：必须在 `_database.transaction` 闭包内调用。
  /// - [narrativeTime] 为 null 或空 -> 跳过（LLM 未输出，保留旧值）
  /// - 更新失败 -> 抛出包含 narrativeTime 关键词的异常，导致事务回滚
  Future<void> _updateNarrativeTimeInTransaction({
    required String sessionId,
    required String? narrativeTime,
  }) async {
    if (narrativeTime == null || narrativeTime.isEmpty) return;
    try {
      await _database.customStatement(
        'UPDATE chat_sessions SET current_narrative_time = ? '
        'WHERE session_id = ?',
        [narrativeTime, sessionId],
      );
    } catch (e) {
      throw Exception('narrativeTime update failed: $e');
    }
  }

  /// 剧情锚 → chat_sessions.story_anchor（同事务，体验重构卡片 C）
  ///
  /// null/空锚 = 跳过（保留旧值）。锚只由 AI 经 update_story_anchor 维护。
  Future<void> _updateStoryAnchorInTransaction({
    required String sessionId,
    required StoryAnchor? anchor,
  }) async {
    final json = StoryAnchor.stringify(anchor);
    if (json == null) return;
    try {
      await _database.customStatement(
        'UPDATE chat_sessions SET story_anchor = ? '
        'WHERE session_id = ?',
        [json, sessionId],
      );
    } catch (e) {
      throw Exception('storyAnchor update failed: $e');
    }
  }

  /// 在当前 drift transaction 内更新 chat_sessions.next_turn
  ///
  /// 单一事实源计数器写回：
  /// - persistRound / persistRegeneratedRound：写为「本轮轮次号 + 1」
  /// - deleteRoundAndDownstream：写为被删起始轮号（下一写复用该号）
  /// 调用前置条件：必须在 `_database.transaction` 闭包内调用。
  Future<void> _updateNextTurnInTransaction({
    required String sessionId,
    required int nextTurn,
  }) async {
    try {
      await _database.customStatement(
        'UPDATE chat_sessions SET next_turn = ? WHERE session_id = ?',
        [nextTurn, sessionId],
      );
    } catch (e) {
      throw Exception('nextTurn update failed: $e');
    }
  }

  @override
  Future<StoryAnchor?> deleteRoundAndDownstream({
    required String sessionId,
    required int fromTurnNumber,
    required List<String> messageIdsToDelete,
    bool keepVariantsAtFromTurn = false,
  }) async {
    return _database.transaction(() async {
      // 1. 删除 turn_number >= fromTurnNumber 的经历记忆 + FTS 索引
      //    （deleteExperienceByTurns 不开自身事务，可嵌套）
      await _experienceRepository.deleteExperienceByTurns(
        sessionId: sessionId,
        fromTurnNumber: fromTurnNumber,
      );

      // 2. 删除待删消息（物理 DELETE 无级联，循环单条删除）
      //    chat_messages 无 turn_number 列，messageIdsToDelete 由 Controller 推导。
      for (final messageId in messageIdsToDelete) {
        await _chatRepository.deleteMessage(messageId);
      }

      // 3. 更新会话元数据（lastActiveAt + messageCount = 实际剩余消息数）
      await _chatRepository.updateSessionLastActive(sessionId);
      final newCount = await _chatRepository.getMessageCount(sessionId);
      await _chatRepository.updateSessionMessageCount(sessionId, newCount);

      // 4. 删除中间产物（新增）
      //    与 experiential_memories 同 turn_number 范围删除，避免悬空数据。
      await _database.customStatement(
        'DELETE FROM intermediate_round_artifacts '
        'WHERE session_id = ? AND turn_number >= ?',
        [sessionId, fromTurnNumber],
      );

      // 4.5. ：连带删除该轮及下游的稿件变体（变体按 (session,turn)
      //     键，不随消息行级联）。keepVariantsAtFromTurn（重生成/编辑重发）
      //     保留起始轮快照——它在本次删除前刚落库，是「不覆盖旧版」的本体；
      //     下游轮次已物理销毁，其变体必须随之清掉（防新轮续号后混入幽灵版）。
      await _database.customStatement(
        'DELETE FROM message_variants '
        'WHERE session_id = ? AND turn_number ${keepVariantsAtFromTurn ? '>' : '>='} ?',
        [sessionId, fromTurnNumber],
      );

      // 4.6 剧情锚对称回滚：story_anchor 由
      //     persistRound 同事务写入「该轮结束时的当前锚」，删除侧必须在
      //     同一事务回拨——否则被删轮经 update_story_anchor 登记的弧线/
      //     伏笔残留 chat_sessions，经 coreBlocks/伏笔清点重新进入后续
      //     轮上下文。取值 = 存活 artifacts（turn < fromTurnNumber）最近
      //     一份轮末锚（变体快照不在取值面）；无 → 置 NULL（如第一轮即
      //     被删，回到未设锚，不会读到任何已删轮的锚）。
      final anchorRows = await _database.customSelect(
        'SELECT story_anchor FROM intermediate_round_artifacts '
        'WHERE session_id = ? AND turn_number < ? '
        'AND story_anchor IS NOT NULL '
        'ORDER BY turn_number DESC LIMIT 1',
        variables: [
          Variable.withString(sessionId),
          Variable.withInt(fromTurnNumber),
        ],
      ).get();
      final restoredAnchorJson = anchorRows.isEmpty
          ? null
          : anchorRows.first.readNullable<String>('story_anchor');
      try {
        await _database.customStatement(
          'UPDATE chat_sessions SET story_anchor = ? WHERE session_id = ?',
          [restoredAnchorJson, sessionId],
        );
      } catch (e) {
        throw Exception('storyAnchor rollback failed: $e');
      }

      // 5. 删除事实层 turns >= fromTurnNumber 的数据（防止重写后设定串戏）
      //    deleteFactsByTurns 不开自身事务，可嵌套在当前事务内。
      //    _factApplier 为 null 时（事实层禁用）跳过。
      await _factApplier?.deleteFactsByTurns(
        sessionId: sessionId,
        fromTurn: fromTurnNumber,
      );

      // 6. 清理 compaction_points 孤儿记录
      //    压缩摘要消息在 messageIdsToDelete 中时，对应的 compaction_points
      //    记录也需删除，避免 loadHistory 时 filterByCompactionPoint 指向已删除消息。
      for (final messageId in messageIdsToDelete) {
        await _chatRepository.deleteCompactionPointBySummaryId(
          sessionId,
          messageId,
        );
      }

      // 7.  turn 单一事实源：next_turn = 被删起始轮号。
      //    下一次写入（重生成/编辑重发/新发送）复用该号，保证轮号连续；
      //    对存量会话（next_turn 为 NULL）本步即计数器物化，
      //    物化值与公式口径在干净状态下恒等。
      await _updateNextTurnInTransaction(
        sessionId: sessionId,
        nextTurn: fromTurnNumber,
      );

      return restoredAnchorJson == null
          ? null
          : StoryAnchor.parse(restoredAnchorJson);
    });
  }

  @override
  Future<Map<int, StoryRoundArtifacts>> loadArtifactsBySession(
    String sessionId,
  ) async {
    final rows = await _database.customSelect(
      'SELECT session_id, turn_number, generated_text, extracted_keywords, '
      'retrieved_memories, retrieved_facts, reply_text, event_summary, '
      'facts_changes, agent_steps, agent_timeline, agent_summary, '
      'story_anchor, review_executed, created_at, current_variant_index '
      'FROM intermediate_round_artifacts WHERE session_id = ?',
      variables: [Variable.withString(sessionId)],
    ).get();
    final result = <int, StoryRoundArtifacts>{};
    for (final row in rows) {
      final turnNumber = row.read<int>('turn_number');
      final extractedKeywordsStr = row.read<String>('extracted_keywords');
      final retrievedMemoriesStr = row.read<String>('retrieved_memories');
      final retrievedFactsStr = row.read<String>('retrieved_facts');
      final eventSummaryStr = row.readNullable<String>('event_summary');
      final factsChangesStr = row.read<String>('facts_changes');
      final agentStepsStr = row.read<String>('agent_steps');
      final createdAtMs = row.read<int>('created_at');
      result[turnNumber] = StoryRoundArtifacts(
        sessionId: row.read<String>('session_id'),
        turnNumber: turnNumber,
        generatedText: row.readNullable<String>('generated_text'),
        extractedKeywords:
            StoryRoundArtifacts.parseDraftKeywords(extractedKeywordsStr),
        retrievedMemories:
            ExperientialMemory.listFromJsonString(retrievedMemoriesStr),
        // 2026-07-29 修复：读取事实层检索结果，恢复历史轮次小窗的
        // 【世界设定】分区显示。
        retrievedFacts: RetrievedFact.listFromJsonString(retrievedFactsStr),
        replyText: row.readNullable<String>('reply_text'),
        eventSummary: StoryRoundArtifacts.parseEventSummary(eventSummaryStr),
        factsChanges: StoryRoundArtifacts.parseFactsChanges(factsChangesStr),
        // 读侧终态归一——写侧归一（f8c9d7c9）只堵
        // 新数据，schema 45 以来存量成功轮 artifacts 里仍带 running 的
        // finish_round 块，历史轮幕后组渲染永久 spinner；此处是全部历史
        // 轮的必经读点（StoryRoundArtifacts.fromJson 同款兜底），同时防
        // 未来任何写侧回归。
        agentSteps: AgentWorkStep.normalizeTerminal(
          AgentWorkStep.listFromJsonString(agentStepsStr),
        ),
        agentTimeline: AgentTimelineBlock.normalizeTerminalActions(
          AgentTimelineBlock.listFromJsonString(
            row.readNullable<String>('agent_timeline'),
          ),
        ),
        agentWorkSummary: StoryRoundArtifacts.parseAgentWorkSummary(
          row.readNullable<String>('agent_summary'),
        ),
        storyAnchor:
            StoryAnchor.parse(row.readNullable<String>('story_anchor')),
        reviewExecuted: row.read<bool>('review_executed'),
        currentVariantIndex: row.readNullable<int>('current_variant_index'),
        createdAt: DateTime.fromMillisecondsSinceEpoch(createdAtMs),
      );
    }
    return result;
  }

  // ── ：稿件变体（非破坏性重生成）────

  @override
  Future<int> snapshotMessageVariant({
    required String sessionId,
    required int turnNumber,
    required String? content,
    String? thinkingContent,
    String? sourceInput,
    StoryRoundArtifacts? process,
  }) {
    return _database.transaction(() async {
      return _insertVariantInTransaction(
        sessionId: sessionId,
        turnNumber: turnNumber,
        content: content,
        thinkingContent: thinkingContent,
        sourceInput: sourceInput,
        process: process,
      );
    });
  }

  @override
  Future<Map<int, List<MessageVariantRecord>>> loadMessageVariants(
    String sessionId,
  ) async {
    final rows = await _database.customSelect(
      'SELECT turn_number, variant_index, content, thinking_content, '
      'source_input, created_at FROM message_variants '
      'WHERE session_id = ? ORDER BY turn_number, variant_index',
      variables: [Variable.withString(sessionId)],
    ).get();
    final result = <int, List<MessageVariantRecord>>{};
    for (final row in rows) {
      final turn = row.read<int>('turn_number');
      result.putIfAbsent(turn, () => []).add(
            MessageVariantRecord(
              variantIndex: row.read<int>('variant_index'),
              content: row.readNullable<String>('content'),
              thinkingContent: row.readNullable<String>('thinking_content'),
              sourceInput: row.readNullable<String>('source_input'),
              createdAtMs: row.read<int>('created_at'),
            ),
          );
    }
    return result;
  }

  @override
  Future<bool> switchMessageVariant({
    required String sessionId,
    required int turnNumber,
    required int variantIndex,
    required String assistantMessageId,
  }) {
    return _database.transaction(() async {
      final rows = await _database.customSelect(
        'SELECT content, thinking_content, agent_steps, agent_timeline, '
        'agent_summary, story_anchor FROM message_variants '
        'WHERE session_id = ? AND turn_number = ? AND variant_index = ?',
        variables: [
          Variable.withString(sessionId),
          Variable.withInt(turnNumber),
          Variable.withInt(variantIndex),
        ],
      ).get();
      if (rows.isEmpty) return false;
      final row = rows.first;
      final content = row.readNullable<String>('content');
      // 1. 消息行 content/thinking ← 变体（上下文组装读 content 即读当前变体）
      await _database.customStatement(
        'UPDATE chat_messages SET content = ?, thinking_content = ? '
        'WHERE message_id = ?',
        [
          content,
          row.readNullable<String>('thinking_content'),
          assistantMessageId,
        ],
      );
      // 2. artifacts 指针 + 过程列 ← 变体（幕后回放随变体切换）
      await _database.customStatement(
        'UPDATE intermediate_round_artifacts SET current_variant_index = ?, '
        'agent_steps = ?, agent_timeline = ?, agent_summary = ?, '
        'story_anchor = ?, reply_text = ? '
        'WHERE session_id = ? AND turn_number = ?',
        [
          variantIndex,
          row.read<String>('agent_steps'),
          row.readNullable<String>('agent_timeline'),
          row.readNullable<String>('agent_summary'),
          row.readNullable<String>('story_anchor'),
          content,
          sessionId,
          turnNumber,
        ],
      );
      // 3. ：会话当前锚与正文版本同步——锚消费面
      //（coreBlocks/伏笔清点/Recap）全读 chat_sessions.story_anchor，此前
      // 只改 artifacts 锚不回拨会话锚，切回旧变体后下一轮注入的仍是新
      // 重生成轮写入的锚（「锚描述一条已不成立的叙事未来」= 05aaa3fb
      // 所修错配的温和变体）。变体锚为 NULL 时按 05aaa3fb 同款回退：
      // 存活轮（turn < 本轮）最近一份轮末锚，无则置 NULL。
      var anchorJson = row.readNullable<String>('story_anchor');
      if (anchorJson == null) {
        final prior = await _database.customSelect(
          'SELECT story_anchor FROM intermediate_round_artifacts '
          'WHERE session_id = ? AND turn_number < ? '
          'AND story_anchor IS NOT NULL '
          'ORDER BY turn_number DESC LIMIT 1',
          variables: [
            Variable.withString(sessionId),
            Variable.withInt(turnNumber),
          ],
        ).get();
        anchorJson = prior.isEmpty
            ? null
            : prior.first.readNullable<String>('story_anchor');
      }
      await _database.customStatement(
        'UPDATE chat_sessions SET story_anchor = ? WHERE session_id = ?',
        [anchorJson, sessionId],
      );
      return true;
    });
  }

  @override
  Future<void> deleteMessageVariant({
    required String sessionId,
    required int turnNumber,
    required int variantIndex,
  }) {
    return _database.transaction(() async {
      await _database.customStatement(
        'DELETE FROM message_variants '
        'WHERE session_id = ? AND turn_number = ? AND variant_index = ?',
        [sessionId, turnNumber, variantIndex],
      );
    });
  }

  /// INSERT 一行 message_variants（内部辅助；须在事务内）
  ///
  /// 变体索引 = 该轮现有最大 + 1（无行时 0 = 最初版本）。
  Future<int> _insertVariantInTransaction({
    required String sessionId,
    required int turnNumber,
    required String? content,
    String? thinkingContent,
    String? sourceInput,
    StoryRoundArtifacts? process,
  }) async {
    final maxRows = await _database.customSelect(
      'SELECT MAX(variant_index) AS m FROM message_variants '
      'WHERE session_id = ? AND turn_number = ?',
      variables: [
        Variable.withString(sessionId),
        Variable.withInt(turnNumber),
      ],
    ).get();
    final maxIndex = maxRows.first.readNullable<int>('m');
    final nextIndex = (maxIndex ?? -1) + 1;
    await _database.customStatement(
      'INSERT INTO message_variants '
      '(session_id, turn_number, variant_index, content, thinking_content, '
      'agent_steps, agent_timeline, agent_summary, story_anchor, '
      'source_input, created_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        sessionId,
        turnNumber,
        nextIndex,
        content,
        thinkingContent,
        if (process == null)
          '[]'
        else
          AgentWorkStep.listToJsonString(process.agentSteps),
        if (process == null || process.agentTimeline.isEmpty)
          null
        else
          AgentTimelineBlock.listToJsonString(process.agentTimeline),
        if (process == null)
          null
        else
          StoryRoundArtifacts.stringifyAgentWorkSummary(
            process.agentWorkSummary,
          ),
        if (process == null)
          null
        else
          StoryAnchor.stringify(process.storyAnchor),
        sourceInput,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    return nextIndex;
  }

  @override
  Future<void> persistConsolidatedMemories({
    required String sessionId,
    required List<ConsolidatedMemoryRecord> records,
    required List<String> originalMemoryIds,
  }) async {
    return _database.transaction(() async {
      // 1. 写入每条合并后的记忆：append（内部成对写 FTS 索引）+ embedding
      //    合并后记忆达存储门槛（importance >= threshold），必须建索引
      for (final record in records) {
        final memory = await _experienceRepository.appendExperience(
          sessionId: sessionId,
          summary: record.summary,
          importance: record.importance,
          tags: record.tags,
          turnNumber: record.turnNumber,
        );
        if (record.embedding != null) {
          await _experienceRepository.updateEmbedding(
            memory.memoryId,
            record.embedding!,
          );
        }
      }

      // 2. 删除参与合并的原始未索引记忆（避免下次重复处理）
      await _experienceRepository.deleteExperiencesByIds(
        sessionId: sessionId,
        memoryIds: originalMemoryIds,
      );
    });
  }

  /// INSERT 一行到 intermediate_round_artifacts（内部辅助方法）
  Future<void> _insertArtifacts(StoryRoundArtifacts artifacts) async {
    await _database.customStatement(
      'INSERT INTO intermediate_round_artifacts '
      '(session_id, turn_number, generated_text, extracted_keywords, '
      'retrieved_memories, retrieved_facts, reply_text, event_summary, '
      'facts_changes, agent_steps, agent_timeline, agent_summary, '
      'story_anchor, review_executed, created_at, current_variant_index) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        artifacts.sessionId,
        artifacts.turnNumber,
        artifacts.generatedText,
        StoryRoundArtifacts.stringifyDraftKeywords(
          artifacts.extractedKeywords,
        ),
        ExperientialMemory.listToJsonString(artifacts.retrievedMemories),
        RetrievedFact.listToJsonString(artifacts.retrievedFacts),
        artifacts.replyText,
        StoryRoundArtifacts.stringifyEventSummary(
          artifacts.eventSummary,
        ),
        StoryRoundArtifacts.stringifyFactsChanges(
          artifacts.factsChanges,
        ),
        AgentWorkStep.listToJsonString(artifacts.agentSteps),
        if (artifacts.agentTimeline.isNotEmpty)
          AgentTimelineBlock.listToJsonString(artifacts.agentTimeline)
        else
          null,
        StoryRoundArtifacts.stringifyAgentWorkSummary(
          artifacts.agentWorkSummary,
        ),
        StoryAnchor.stringify(artifacts.storyAnchor),
        artifacts.reviewExecuted,
        artifacts.createdAt.millisecondsSinceEpoch,
        artifacts.currentVariantIndex,
      ],
    );
  }

  /// 在当前 drift transaction 内持久化 CompactionPoint 压缩摘要
  ///
  /// 调用前置条件：必须在 `_database.transaction` 闭包内调用。
  /// 写入三部分（均在同一事务内，保证原子性）：
  /// 1. INSERT 摘要消息 → chat_messages（isSummary=true, role=system）
  /// 2. INSERT 压缩点记录 → compaction_points
  ///    （summaryMessageId ↔ boundaryMessageId 映射）
  /// 3. INSERT 宏摘要记忆 → experiential_memories
  ///    （memory_level=macro, macroTriggerReason=compaction）
  ///    + INSERT FTS5 索引 → memories_fts
  ///
  /// **v0.2.3 分段宏摘要**：
  /// - `data.segmentMacroSummary` 非空：使用分段宏摘要作为 macro 记忆内容（后续压缩）
  /// - `data.segmentMacroSummary` 为空：使用压缩摘要作为 macro 记忆内容（首次压缩）
  /// - importance 统一为 3（中等），参与语义检索
  ///
  /// 关联设计§5.5
  @override
  Future<void> persistManualCompaction({
    required CompactionPersistenceData compaction,
  }) {
    final sessionId = compaction.summaryMessage.sessionId;
    return _database.transaction(() async {
      await _persistCompactionInTransaction(compaction);
      // 会话元数据与 persistRound 同口径（读取实际消息数后设绝对值）
      await _chatRepository.updateSessionLastActive(sessionId);
      final newCount = await _chatRepository.getMessageCount(sessionId);
      await _chatRepository.updateSessionMessageCount(sessionId, newCount);
    });
  }

  /// 撤销最新一次压缩（2026-09-04 撤销压缩，接口契约见
  /// [StoryPersistenceService.undoCompaction]）
  @override
  Future<bool> undoCompaction({required String sessionId}) {
    return _database.transaction(() async {
      final points = await _chatRepository.getCompactionPoints(sessionId);
      if (points.isEmpty) return false;
      final latest = points.last;
      final summaryMessageId = latest['summaryMessageId'] as String;
      // 1. 压缩点 → 2. 摘要消息行 → 3. 该次压缩的宏摘要记忆（含 FTS）
      await _chatRepository.deleteCompactionPointBySummaryId(
        sessionId,
        summaryMessageId,
      );
      await _chatRepository.deleteMessage(summaryMessageId);
      await _experienceRepository.deleteLatestCompactionMacroMemory(
        sessionId: sessionId,
      );
      // 会话元数据与 persistManualCompaction 同口径
      await _chatRepository.updateSessionLastActive(sessionId);
      final newCount = await _chatRepository.getMessageCount(sessionId);
      await _chatRepository.updateSessionMessageCount(sessionId, newCount);
      return true;
    });
  }

  Future<void> _persistCompactionInTransaction(
    CompactionPersistenceData data,
  ) async {
    // 1. 摘要消息 → chat_messages
    await _chatRepository.addMessage(data.summaryMessage);

    // 2. 压缩点记录 → compaction_points
    await _chatRepository.addCompactionPoint(
      sessionId: data.summaryMessage.sessionId,
      summaryMessageId: data.summaryMessage.messageId,
      boundaryMessageId: data.boundaryMessageId,
      createdAt: data.summaryMessage.createdAt,
    );

    // 3. 宏摘要记忆 → experiential_memories（memory_level=macro,
    //    macroTriggerReason=compaction, importance=3）
    //    v0.2.3：分段宏摘要优先，首次压缩回退到压缩摘要文本。
    final macroSummaryText =
        data.segmentMacroSummary ?? data.summaryMessage.content ?? '';
    final macro = await _experienceRepository.appendMacroExperience(
      sessionId: data.summaryMessage.sessionId,
      summary: macroSummaryText,
      importance: 3,
      tags: const ['compaction', 'macro_summary'],
      turnNumber: data.turnNumber,
      parentEventIds: const [],
      triggerReason: MacroTriggerReason.compaction,
    );
    // 4. 宏摘要向量：非空时同事务写入——兑现
    //    appendMacroExperience 接口注释「宏摘要始终建 FTS5 索引 + 向量化」
    //    的承诺（此前只建 FTS，长故事前情摘要语义搜不到）。
    if (data.macroEmbedding != null) {
      await _experienceRepository.updateEmbedding(
        macro.memoryId,
        data.macroEmbedding!,
      );
    }
    // 5. FTS5 索引由 appendMacroExperience 同事务写入（单一写入口，2026-09-09）
  }
}
