import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';
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
import 'package:lmstory/features/memory/domain/entities/fact_replay_record.dart';
import 'package:lmstory/features/memory/domain/entities/facts_change_record.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart'
    show FactTargetMismatch;
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';
import 'package:lmstory/features/memory/domain/services/fact_context_builder.dart';
import 'package:lmstory/features/story_runtime/domain/entities/message_variant_record.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/services/persistence_service.dart';
import 'package:lmstory/features/story_runtime/domain/services/round_history_utils.dart';

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
/// 每条事实提议在整轮事务内独立保存。失败只回滚该条并计数，实际执行
/// 结果随轮产物保存，用于以后原子地切换正文和派生记忆。
class StoryPersistenceServiceImpl
    implements StoryPersistenceService, StoryHistoryReadStore {
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
    bool hasVerifiedSourceTurn = false,
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
        hasVerifiedSourceTurn: hasVerifiedSourceTurn &&
            userMessage.role == 'user' &&
            userMessage.sessionId == assistantMessage.sessionId &&
            _matchesSingleTurnArtifacts(
              assistantMessage,
              eventSummary,
              artifacts,
            ),
      );

      // 4. 若 embedding 生成成功 → 更新向量 + has_embedding=true
      //    P1 阶段 embedding 恒为 null（向量化模型未配置，FTS5 兜底），
      //    此分支保留供 P2 启用 embedding_model 配置后激活。
      if (embedding != null) {
        await _experienceRepository.updateEmbedding(memory.memoryId, embedding);
      }

      // 6. 会话元数据 → chat_sessions（lastActiveAt + messageCount）
      //    updateSessionMessageCount 为绝对值设置（非增量），需读取实际消息数。
      //    与 Simple 模式 MessageManager.updateMessageCount 同模式。
      await _chatRepository.updateSessionLastActive(userMessage.sessionId);
      final newCount = await _chatRepository.getMessageCount(
        userMessage.sessionId,
      );
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
      final facts = await _applyFactsInTransaction(
        sessionId: userMessage.sessionId,
        turnNumber: eventSummary.turnNumber,
        factsDeltas: factsDeltas,
        factualConfig: factualConfig,
      );
      final factsChanges = facts.changes;

      // 8. 中间产物 -> intermediate_round_artifacts（新增）
      //    持久化生成内容/关键词/检索结果 + 本轮事实层变更记录（含变更前/后），
      //    使历史轮次小窗切换会话后仍可见。
      if (artifacts != null) {
        await _insertArtifacts(
          artifacts.copyWithFactsChanges(factsChanges),
          factsDeltas: facts.replay,
        );
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
            createdMemoryId: memory.memoryId,
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

      return PersistRoundResult(
        memory: memory,
        factsChanges: factsChanges,
        factWriteFailureCount: facts.factWriteFailureCount,
      );
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
    bool hasVerifiedSourceTurn = false,
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
        hasVerifiedSourceTurn: hasVerifiedSourceTurn &&
            _matchesSingleTurnArtifacts(
              assistantMessage,
              eventSummary,
              artifacts,
            ),
      );

      // 3. 若 embedding 生成成功 → 更新向量 + has_embedding=true
      if (embedding != null) {
        await _experienceRepository.updateEmbedding(memory.memoryId, embedding);
      }

      // 5. 会话元数据 → chat_sessions（messageCount +1，因只加了 assistant）
      await _chatRepository.updateSessionLastActive(assistantMessage.sessionId);
      final newCount = await _chatRepository.getMessageCount(
        assistantMessage.sessionId,
      );
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
      final facts = await _applyFactsInTransaction(
        sessionId: assistantMessage.sessionId,
        turnNumber: eventSummary.turnNumber,
        factsDeltas: factsDeltas,
        factualConfig: factualConfig,
      );
      final factsChanges = facts.changes;

      // 7. 中间产物 -> intermediate_round_artifacts（新增，含事实层变更记录）
      if (artifacts != null) {
        await _insertArtifacts(
          artifacts.copyWithFactsChanges(factsChanges),
          factsDeltas: facts.replay,
        );
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
          createdMemoryId: memory.memoryId,
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

      return PersistRoundResult(
        memory: memory,
        factsChanges: factsChanges,
        factWriteFailureCount: facts.factWriteFailureCount,
      );
    });
  }

  bool _matchesSingleTurnArtifacts(
    ChatMessage assistantMessage,
    EventSummary summary,
    StoryRoundArtifacts? artifacts,
  ) {
    return summary.turnNumber > 0 &&
        assistantMessage.role == 'assistant' &&
        (assistantMessage.content?.isNotEmpty ?? false) &&
        artifacts != null &&
        artifacts.sessionId == assistantMessage.sessionId &&
        artifacts.turnNumber == summary.turnNumber &&
        artifacts.eventSummary?.turnNumber == summary.turnNumber &&
        artifacts.replyText == assistantMessage.content;
  }

  /// 为每条提议保存实际效果，未生效的条目明确标记。
  /// 单条事实与它的流水在同一个回滚点内写入。
  Future<
      ({
        List<FactsChangeRecord> changes,
        String? replay,
        int factWriteFailureCount,
      })> _applyFactsInTransaction({
    required String sessionId,
    required int turnNumber,
    required List<FactsDelta>? factsDeltas,
    required FactualConfig? factualConfig,
  }) async {
    if (factsDeltas == null || factsDeltas.isEmpty) {
      return const (
        changes: <FactsChangeRecord>[],
        replay: null,
        factWriteFailureCount: 0,
      );
    }
    final applier = _factApplier;
    final effects = <int, AppliedFact>{};
    final result = applier == null || factualConfig == null
        ? const (factsChanges: <FactsChangeRecord>[], factWriteFailureCount: 0)
        : await applier.applyDeltasWithResult(
            sessionId,
            factsDeltas,
            turnNumber,
            factualConfig,
            onApplied: (index, effect) => effects[index] = effect,
          );
    return (
      changes: result.factsChanges,
      factWriteFailureCount: result.factWriteFailureCount,
      replay: jsonEncode([
        for (final (index, delta) in factsDeltas.indexed)
          {...delta.toJson(), AppliedFact.field: effects[index]?.toJson()},
      ]),
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
  }) {
    return _database.transaction(() async {
      final rollback = await _deleteRoundAndDownstreamInTransaction(
        sessionId: sessionId,
        fromTurnNumber: fromTurnNumber,
        messageIdsToDelete: messageIdsToDelete,
        keepVariantsAtFromTurn: keepVariantsAtFromTurn,
      );
      return rollback.storyAnchor;
    });
  }

  @override
  Future<RoundRollbackResult> rollbackRoundAndDownstream({
    required String sessionId,
    required int fromTurnNumber,
    required List<String> messageIdsToDelete,
    bool keepVariantsAtFromTurn = false,
    RoundVariantSnapshot? variantSnapshot,
    Future<bool> Function(String sessionId, int fromTurnNumber)? truncateEvents,
  }) {
    return _database.transaction(() async {
      // 保存旧稿时，活动稿的经历、事实增量和轮次产物还可读。
      if (variantSnapshot != null) {
        await _insertVariantInTransaction(
          sessionId: sessionId,
          turnNumber: fromTurnNumber,
          content: variantSnapshot.assistant.content,
          thinkingContent: variantSnapshot.assistant.thinkingContent,
          sourceInput: variantSnapshot.sourceInput,
          process: variantSnapshot.process,
        );
      }
      final rollback = await _deleteRoundAndDownstreamInTransaction(
        sessionId: sessionId,
        fromTurnNumber: fromTurnNumber,
        messageIdsToDelete: messageIdsToDelete,
        keepVariantsAtFromTurn:
            keepVariantsAtFromTurn || variantSnapshot != null,
      );
      final deletedFrozenPrefix =
          await truncateEvents?.call(sessionId, fromTurnNumber) ?? false;
      final experiences = await _experienceRepository.getAllExperiences(
        sessionId,
      );
      final narrativeTime = latestNarrativeTimeOf(experiences);
      await _database.customStatement(
        'UPDATE chat_sessions SET current_narrative_time = ? '
        'WHERE session_id = ?',
        [narrativeTime, sessionId],
      );
      return (
        storyAnchor: rollback.storyAnchor,
        narrativeTime: narrativeTime,
        messageCount: rollback.messageCount,
        deletedFrozenPrefix: deletedFrozenPrefix,
      );
    });
  }

  Future<({StoryAnchor? storyAnchor, int messageCount})>
      _deleteRoundAndDownstreamInTransaction({
    required String sessionId,
    required int fromTurnNumber,
    required List<String> messageIdsToDelete,
    required bool keepVariantsAtFromTurn,
  }) async {
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

    return (
      storyAnchor: StoryAnchor.parse(restoredAnchorJson),
      messageCount: newCount,
    );
  }

  @override
  Future<Map<int, StoryRoundArtifacts>> loadArtifactsBySession(
    String sessionId,
  ) =>
      _loadArtifacts(sessionId);

  static const _historyTurnFilter =
      ' AND turn_number IN (SELECT value FROM json_each(?))';

  @override
  Future<T> runHistoryTransaction<T>(Future<T> Function() operation) =>
      _database.transaction(operation);

  @override
  Future<StoryHistoryTurnDetails> loadHistoryTurnDetails(
    String sessionId,
    Set<int> turns,
  ) async {
    if (turns.isEmpty) {
      return (
        artifacts: const <int, StoryRoundArtifacts>{},
        variants: const <int, List<MessageVariantRecord>>{},
      );
    }
    return runHistoryTransaction(() async {
      final encodedTurns = jsonEncode(turns.toList());
      final artifacts = await _loadArtifacts(sessionId, encodedTurns);
      final variants = await _loadVariants(sessionId, encodedTurns);
      return (artifacts: artifacts, variants: variants);
    });
  }

  @override
  Future<Map<int, AgentWorkSummary?>> loadHistorySummaries(
    String sessionId,
  ) async {
    final rows = await _database.customSelect(
      'SELECT turn_number, agent_summary FROM intermediate_round_artifacts '
      'WHERE session_id = ?',
      variables: [Variable.withString(sessionId)],
    ).get();
    return {
      for (final row in rows)
        row.read<int>('turn_number'): StoryRoundArtifacts.parseAgentWorkSummary(
          row.readNullable<String>('agent_summary'),
        ),
    };
  }

  Future<Map<int, StoryRoundArtifacts>> _loadArtifacts(
    String sessionId, [
    String? encodedTurns,
  ]) async {
    final rows = await _database.customSelect(
      'SELECT session_id, turn_number, generated_text, extracted_keywords, '
      'retrieved_memories, retrieved_facts, reply_text, event_summary, '
      'facts_changes, agent_steps, agent_timeline, agent_summary, '
      'story_anchor, review_executed, created_at, current_variant_index '
      'FROM intermediate_round_artifacts WHERE session_id = ?'
      '${encodedTurns == null ? '' : _historyTurnFilter}',
      variables: [
        Variable.withString(sessionId),
        if (encodedTurns != null) Variable.withString(encodedTurns),
      ],
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
        extractedKeywords: StoryRoundArtifacts.parseDraftKeywords(
          extractedKeywordsStr,
        ),
        retrievedMemories: ExperientialMemory.listFromJsonString(
          retrievedMemoriesStr,
        ),
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
        storyAnchor: StoryAnchor.parse(
          row.readNullable<String>('story_anchor'),
        ),
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
  ) =>
      _loadVariants(sessionId);

  Future<Map<int, List<MessageVariantRecord>>> _loadVariants(
    String sessionId, [
    String? encodedTurns,
  ]) async {
    final rows = await _database.customSelect(
      'SELECT turn_number, variant_index, content, thinking_content, '
      'source_input, created_at FROM message_variants '
      'WHERE session_id = ?'
      '${encodedTurns == null ? '' : _historyTurnFilter} '
      'ORDER BY turn_number, variant_index',
      variables: [
        Variable.withString(sessionId),
        if (encodedTurns != null) Variable.withString(encodedTurns),
      ],
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
  Future<bool> updateAssistantContentAndCurrentVariant({
    required String sessionId,
    required int turnNumber,
    required String assistantMessageId,
    required String newContent,
  }) {
    return _database.transaction(() async {
      final existing = await _database.customSelect(
        'SELECT content FROM chat_messages '
        "WHERE session_id = ? AND message_id = ? AND role = 'assistant'",
        variables: [
          Variable.withString(sessionId),
          Variable.withString(assistantMessageId),
        ],
      ).get();
      if (existing.isEmpty) return false;
      if (existing.first.readNullable<String>('content') == newContent) {
        return true;
      }
      await _database.customStatement(
        'UPDATE chat_messages SET content = ? '
        'WHERE session_id = ? AND message_id = ?',
        [newContent, sessionId, assistantMessageId],
      );
      // 正文变动后，先前的单轮摘要不再能指向当前正文核对。
      await _database.customStatement(
        'UPDATE experiential_memories SET has_verified_source_turn = 0 '
        'WHERE session_id = ? AND turn_number = ? '
        "AND source = 'auto' AND has_verified_source_turn = 1",
        [sessionId, turnNumber],
      );
      // 当前稿快照也会在重生成后被恢复，随正文同步撤销其来源标记。
      final variants = await _database.customSelect(
        'SELECT id, experiential_snapshot FROM message_variants '
        'WHERE session_id = ? AND turn_number = ? AND variant_index = '
        '(SELECT current_variant_index FROM intermediate_round_artifacts '
        'WHERE session_id = ? AND turn_number = ?)',
        variables: [
          Variable.withString(sessionId),
          Variable.withInt(turnNumber),
          Variable.withString(sessionId),
          Variable.withInt(turnNumber),
        ],
      ).get();
      for (final variant in variants) {
        await _database.customStatement(
          'UPDATE message_variants SET content = ?, experiential_snapshot = ? '
          'WHERE id = ?',
          [
            newContent,
            _invalidateSnapshotSourceTurn(
              variant.readNullable<String>('experiential_snapshot'),
            ),
            variant.read<int>('id'),
          ],
        );
      }
      return true;
    });
  }

  @override
  Future<bool> updateUserContentAndInvalidateSourceTurn({
    required String sessionId,
    required int? turnNumber,
    required String userMessageId,
    required String newContent,
  }) {
    return _database.transaction(() async {
      final existing = await _database.customSelect(
        'SELECT content FROM chat_messages '
        "WHERE session_id = ? AND message_id = ? AND role = 'user'",
        variables: [
          Variable.withString(sessionId),
          Variable.withString(userMessageId),
        ],
      ).get();
      if (existing.isEmpty) return false;
      if (existing.first.readNullable<String>('content') == newContent) {
        return true;
      }
      await _database.customStatement(
        'UPDATE chat_messages SET content = ? '
        'WHERE session_id = ? AND message_id = ?',
        [newContent, sessionId, userMessageId],
      );
      final turnFilter = turnNumber == null ? '' : ' AND turn_number = ?';
      final args = [sessionId, if (turnNumber != null) turnNumber];
      await _database.customStatement(
        'UPDATE experiential_memories SET has_verified_source_turn = 0 '
        'WHERE session_id = ?$turnFilter AND has_verified_source_turn = 1',
        args,
      );
      return true;
    });
  }

  @override
  Future<bool> switchMessageVariant({
    required String sessionId,
    required int turnNumber,
    required int variantIndex,
    required String assistantMessageId,
    FactualConfig? factualConfig,
  }) async {
    try {
      return await _switchVariant(
        sessionId,
        turnNumber,
        variantIndex,
        assistantMessageId,
        factualConfig,
      );
    } on FactTargetMismatch {
      return false;
    } on _VariantRestoreRejected {
      return false;
    } on FormatException {
      return false;
    }
  }

  Future<bool> _switchVariant(
    String sessionId,
    int turnNumber,
    int variantIndex,
    String assistantMessageId,
    FactualConfig? factualConfig,
  ) {
    return _database.transaction(() async {
      final rows = await _database.customSelect(
        'SELECT content, thinking_content, agent_steps, agent_timeline, '
        'agent_summary, story_anchor, facts_deltas, '
        'experiential_snapshot, event_summary, facts_changes, source_input '
        'FROM message_variants '
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

      // 服务层终局守卫（控制器守卫之外的兜底）：该轮之后存在后续轮时
      // 拒绝切换——后续轮派生无法随交换，继续会删掉它们且无恢复路径。
      // next_turn 单一事实源：末轮恒为 turnNumber+1；NULL（极旧会话未
      // 物化计数器）时视为无后续（与轮号推导口径一致）。
      final nextTurnRows = await _database.customSelect(
        'SELECT next_turn FROM chat_sessions WHERE session_id = ?',
        variables: [Variable.withString(sessionId)],
      ).get();
      final nextTurn = nextTurnRows.isEmpty
          ? null
          : nextTurnRows.first.readNullable<int>('next_turn');
      if (nextTurn != null && nextTurn > turnNumber + 1) {
        return false;
      }

      // 0. 被切走变体的派生资料回写（先于任何删除——此刻库中派生仍属于
      //    指针所指变体）。来回切换各自快照无损。
      final pointerRows = await _database.customSelect(
        'SELECT a.current_variant_index, v.experiential_snapshot '
        'FROM intermediate_round_artifacts a LEFT JOIN message_variants v '
        'ON v.session_id = a.session_id AND v.turn_number = a.turn_number '
        'AND v.variant_index = a.current_variant_index '
        'JOIN chat_messages m ON m.session_id = a.session_id '
        "AND m.message_id = ? AND m.role = 'assistant' "
        'WHERE a.session_id = ? AND a.turn_number = ? ORDER BY a.id DESC LIMIT 1',
        variables: [
          Variable.withString(assistantMessageId),
          Variable.withString(sessionId),
          Variable.withInt(turnNumber),
        ],
      ).get();
      if (pointerRows.isEmpty) return false;
      final outgoingIndex = pointerRows.first.readNullable<int>(
        'current_variant_index',
      );
      if (outgoingIndex == variantIndex) return true;
      // 正文变体切换不改当前用户消息，比较数据库中紧邻的真实输入，
      // 不用被切走变体的 source_input 代替（多次切换后两者可能不同）。
      final inputRows = await _database.customSelect(
        'SELECT m.role, m.content FROM chat_messages m '
        'JOIN chat_messages a ON m.session_id = a.session_id '
        "WHERE a.session_id = ? AND a.message_id = ? AND a.role = 'assistant' "
        "AND m.role IN ('user', 'assistant') AND m.is_summary = 0 "
        'AND (m.created_at < a.created_at OR '
        '(m.created_at = a.created_at AND m.id < a.id)) '
        'ORDER BY m.created_at DESC, m.id DESC LIMIT 1',
        variables: [
          Variable.withString(sessionId),
          Variable.withString(assistantMessageId),
        ],
      ).get();
      final currentInput =
          inputRows.isNotEmpty && inputRows.first.read<String>('role') == 'user'
              ? inputRows.first.readNullable<String>('content')
              : null;
      final targetInput = row.readNullable<String>('source_input');
      final sourceInputMatches = currentInput != null &&
          targetInput != null &&
          currentInput == targetInput;
      final incomingSnapshot = row.readNullable<String>(
        'experiential_snapshot',
      );
      if (!await _canRestoreSnapshot(
        sessionId,
        turnNumber,
        incomingSnapshot,
        pointerRows.single.readNullable<String>('experiential_snapshot'),
      )) {
        return false;
      }

      if (outgoingIndex != null) {
        final previous = pointerRows.single.readNullable<String>(
          'experiential_snapshot',
        );
        final ownedIds = previous == null || previous.isEmpty
            ? <String>{}
            : {
                for (final item in _snapshotRows(previous))
                  if (item['snapshot_session_id'] == sessionId)
                    item['memory_id'] as String,
              };
        final snapshot = await _snapshotExperientialRows(
          sessionId,
          turnNumber,
          ownedIds,
        );
        // 旧版活动产物可能仍带上一次所选稿的 deltas；每份稿件保留自己的重放数据。
        await _database.customStatement(
          'UPDATE message_variants SET experiential_snapshot = ? '
          'WHERE session_id = ? AND turn_number = ? AND variant_index = ?',
          [snapshot, sessionId, turnNumber, outgoingIndex],
        );
      }

      // 1. 消息行 content/thinking ← 变体（上下文组装读 content 即读当前变体）
      final updated = await _database.customUpdate(
        'UPDATE chat_messages SET content = ?, thinking_content = ? '
        "WHERE message_id = ? AND session_id = ? AND role = 'assistant'",
        variables: [
          Variable<String>(content),
          Variable<String>(row.readNullable<String>('thinking_content')),
          Variable.withString(assistantMessageId),
          Variable.withString(sessionId),
        ],
      );
      if (updated != 1) throw const _VariantRestoreRejected();
      // 2. 记忆层随正文同步（正文=事实真源，记忆是派生物）：
      //    先移除当前轮派生（其事实属被切走正文的废弃时间线），再按
      //    所选变体快照恢复；无快照的旧变体不虚构记忆。
      await _experienceRepository.deleteExperienceByTurns(
        sessionId: sessionId,
        fromTurnNumber: turnNumber,
      );
      await _factApplier?.deleteFactsByTurns(
        sessionId: sessionId,
        fromTurn: turnNumber,
      );
      await _restoreExperientialRows(
        sessionId,
        turnNumber,
        incomingSnapshot,
        allowVerifiedSourceTurn: sourceInputMatches,
      );
      final replayDeltas = await _replayVariantFacts(
        sessionId,
        turnNumber,
        row.readNullable<String>('facts_deltas'),
        row.readNullable<String>('facts_changes'),
        factualConfig,
      );
      if (replayDeltas != row.readNullable<String>('facts_deltas')) {
        await _database.customStatement(
          'UPDATE message_variants SET facts_deltas = ? WHERE session_id = ? '
          'AND turn_number = ? AND variant_index = ?',
          [replayDeltas, sessionId, turnNumber, variantIndex],
        );
      }
      // 3. artifacts 指针 + 过程列/展示列 ← 变体（幕后回放与轮小窗随变体切换）
      await _database.customStatement(
        'UPDATE intermediate_round_artifacts SET current_variant_index = ?, '
        'agent_steps = ?, agent_timeline = ?, agent_summary = ?, '
        'story_anchor = ?, reply_text = ?, event_summary = ?, '
        'facts_changes = ?, facts_deltas = ? '
        'WHERE session_id = ? AND turn_number = ?',
        [
          variantIndex,
          row.read<String>('agent_steps'),
          row.readNullable<String>('agent_timeline'),
          row.readNullable<String>('agent_summary'),
          row.readNullable<String>('story_anchor'),
          content,
          row.readNullable<String>('event_summary'),
          row.readNullable<String>('facts_changes') ?? '[]',
          replayDeltas,
          sessionId,
          turnNumber,
        ],
      );

      // 叙事时间指针随恢复行回拨（末轮切换，恢复行即最新时间线）
      final restoredNarrative = await _database.customSelect(
        'SELECT narrative_time FROM experiential_memories '
        'WHERE session_id = ? AND turn_number = ? '
        'ORDER BY id DESC LIMIT 1',
        variables: [
          Variable.withString(sessionId),
          Variable.withInt(turnNumber),
        ],
      ).get();
      final narrativeValue = restoredNarrative.isEmpty
          ? null
          : restoredNarrative.first.readNullable<String>('narrative_time');
      await _database.customStatement(
        'UPDATE chat_sessions SET current_narrative_time = ? '
        'WHERE session_id = ?',
        [narrativeValue, sessionId],
      );

      // 4. ：会话当前锚与正文版本同步——锚消费面
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

  /// 旧副本的活动行曾换过 ID，而其稿件快照仍沿用源 ID。在无归属标记
  /// 的旧稿，先核对当前指针对应的快照与实际自动经历，无法确认则整笔拒绝。
  Future<bool> _canRestoreSnapshot(
    String sessionId,
    int turnNumber,
    String? incoming,
    String? outgoing,
  ) async {
    if (incoming == null || incoming.isEmpty) return true;
    final rows = _snapshotRows(incoming);
    if (rows.isEmpty) return true;
    var legacy = false;
    for (final row in rows) {
      final owner = row['snapshot_session_id'];
      if (owner != null && owner != sessionId) return false;
      if (owner == null) legacy = true;
    }
    if (!legacy) return true;
    // 旧版可能已经恢复过借来的 ID。当前稿自洽也不能替另一份历史稿认领身份。
    // 仅检查旧格式，按 JSON 中声明的字段匹配，不把正文中的 ID 字样算作引用。
    final claimed = await _database.customSelect(
      'SELECT 1 FROM message_variants v, json_each(CASE WHEN '
      "json_valid(v.experiential_snapshot) THEN v.experiential_snapshot ELSE '[]' END) j "
      "WHERE v.session_id <> ? AND j.type = 'object' "
      r"AND json_extract(j.value, '$.memory_id') IN (SELECT value FROM json_each(?)) LIMIT 1",
      variables: [
        Variable.withString(sessionId),
        Variable.withString(
          jsonEncode([for (final item in rows) item['memory_id']]),
        ),
      ],
    ).get();
    if (claimed.isNotEmpty || outgoing == null || outgoing.isEmpty) {
      return false;
    }
    final expectedIds =
        _snapshotRows(outgoing).map((r) => r['memory_id']).toSet();
    final live = await _database.customSelect(
      'SELECT memory_id FROM experiential_memories WHERE session_id = ? '
      "AND turn_number = ? AND source = 'auto'",
      variables: [
        Variable.withString(sessionId),
        Variable.withInt(turnNumber),
      ],
    ).get();
    return live.isNotEmpty &&
        live.length == expectedIds.length &&
        live.every((r) => expectedIds.contains(r.read<String>('memory_id')));
  }

  List<Map<String, dynamic>> _snapshotRows(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! List ||
        decoded.any(
          (r) => r is! Map<String, dynamic> || r['memory_id'] is! String,
        )) {
      throw const _VariantRestoreRejected();
    }
    return decoded.cast<Map<String, dynamic>>();
  }

  /// 仅重放已有成功证据的事实，效果不同则拒绝整次切稿。
  Future<String?> _replayVariantFacts(
    String sessionId,
    int turn,
    String? encoded,
    String? changes,
    FactualConfig? config,
  ) async {
    final rows = _readFactRows(encoded);
    if (rows.isEmpty) {
      if (_readFactRows(changes).isNotEmpty) {
        throw const _VariantRestoreRejected();
      }
      return encoded;
    }
    final annotated = rows.first.containsKey(AppliedFact.field);
    if (rows.any((row) => row.containsKey(AppliedFact.field) != annotated)) {
      throw const _VariantRestoreRejected();
    }
    if (annotated && rows.every((row) => row[AppliedFact.field] == null)) {
      return encoded;
    }
    final applier = _factApplier;
    if (applier == null || config == null || !config.enabled) {
      throw const _VariantRestoreRejected();
    }
    final legacy =
        annotated ? null : LegacyFactReplay.read(rows, _readFactRows(changes));
    final bindings = <String, String>{};
    for (final (index, row) in rows.indexed) {
      final expected = switch (row[AppliedFact.field]) {
        final Map<String, Object?> stored => AppliedFact.fromJson(stored),
        null => null,
        _ => throw const _VariantRestoreRejected(),
      };
      if (annotated && expected == null) continue;
      final old = legacy?[index];
      final proposal = old?.proposal ?? readStoredFactProposal(row);
      final entityId = expected?.entityId ?? old?.entityId;
      final action = expected?.action ?? old?.change.action;
      if (entityId == null || action == null) {
        throw const _VariantRestoreRejected();
      }
      final creating = action == FactAction.createEntity;
      final target = bindings[entityId] ?? entityId;
      if (creating &&
          (bindings.containsKey(entityId) ||
              await _storedFactIdExists(entityId))) {
        throw const _VariantRestoreRejected();
      }
      final delta = expected?.replayDelta(proposal, target) ??
          FactsDelta.fromJson({
            ...proposal.toJson(),
            if (!creating) 'entityId': target,
          });
      AppliedFact? replayed;
      final display = await applier.applyDelta(
        sessionId,
        delta,
        turn,
        config,
        replay: true,
        onApplied: (value) => replayed = value,
      );
      final actual = replayed;
      if (actual == null ||
          display == null ||
          action != actual.action ||
          (!creating && actual.entityId != target) ||
          (expected != null && !expected.matches(actual)) ||
          (old != null && !old.matches(display, actual))) {
        throw const _VariantRestoreRejected();
      }
      if (creating) bindings[entityId] = actual.entityId;
      if (bindings[row['entityId']] case final rebound?) {
        row['entityId'] = rebound;
      }
      row
        ..remove(LegacyFactReplay.createdIdField)
        ..remove(LegacyFactReplay.displayIdField)
        ..[AppliedFact.field] = actual.toJson();
    }
    return jsonEncode(rows);
  }

  Future<bool> _storedFactIdExists(String entityId) async {
    final entity = await (_database.select(
      _database.factualEntitiesTable,
    )..where((t) => t.entityId.equals(entityId)))
        .getSingleOrNull();
    return entity != null;
  }

  List<Map<String, Object?>> _readFactRows(String? encoded) {
    if (encoded == null || encoded.isEmpty) return const [];
    final rows = jsonDecode(encoded);
    if (rows is! List<Object?> ||
        rows.any((row) => row is! Map<String, Object?>)) {
      throw const _VariantRestoreRejected();
    }
    return rows.cast<Map<String, Object?>>();
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
    String? createdMemoryId,
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
      'source_input, created_at, facts_deltas, experiential_snapshot, '
      'event_summary, facts_changes) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
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
        // 派生资料快照：自当前库状态取——snapshotMessageVariant 时是被
        // 快照版本自己的派生（删除发生在此之前），persist 8.2 时是刚
        // 落库的本轮派生。两种场景同一取数口径。
        ...await _captureTurnDerivation(sessionId, turnNumber, createdMemoryId),
      ],
    );
    return nextIndex;
  }

  /// 捕获某轮的派生资料三元组（facts_deltas / experiential_snapshot /
  /// event_summary+facts_changes），须在事务内调用。
  ///
  /// 变体快照与切换回写共用：值来自 artifacts 行与该轮经历记忆行。
  Future<List<String?>> _captureTurnDerivation(
    String sessionId,
    int turnNumber,
    String? createdMemoryId,
  ) async {
    final artifactRow = await _database.customSelect(
      'SELECT CASE WHEN v.id IS NULL THEN a.facts_deltas ELSE v.facts_deltas END AS facts_deltas, '
      'a.event_summary, a.facts_changes FROM intermediate_round_artifacts a '
      'LEFT JOIN message_variants v ON v.session_id = a.session_id AND '
      'v.turn_number = a.turn_number AND v.variant_index = a.current_variant_index '
      'WHERE a.session_id = ? AND a.turn_number = ? ORDER BY a.id DESC LIMIT 1',
      variables: [
        Variable.withString(sessionId),
        Variable.withInt(turnNumber),
      ],
    ).get();
    final snapshot = await _snapshotExperientialRows(sessionId, turnNumber, {
      if (createdMemoryId != null) createdMemoryId,
    });
    final row = artifactRow.isEmpty ? null : artifactRow.first.data;
    return [
      row?['facts_deltas'] as String?,
      snapshot,
      row?['event_summary'] as String?,
      row?['facts_changes'] as String?,
    ];
  }

  /// 序列化某轮的经历记忆行（source=auto，含向量与 FTS 状态标记）。
  /// 无行时返回 null（该轮无经历派生）。
  Future<String?> _snapshotExperientialRows(
    String sessionId,
    int turnNumber,
    Set<String> ownedIds,
  ) async {
    final rows = await _database.customSelect(
      'SELECT m.memory_id, m.importance, m.tags, m.turn_number, '
      'm.narrative_time, m.narrative_period, m.when_text, m.where_text, '
      'm.who_text, m.what_text, m.significance, m.extra, m.summary, '
      'm.is_archived, m.is_summary, m.has_embedding, m.embedding, '
      'm.embedding_dimensions, m.memory_level, m.parent_event_ids, '
      'm.macro_trigger_reason, m.archived_event_ids, m.source, '
      'm.has_verified_source_turn, m.created_at, '
      '(SELECT COUNT(*) FROM memories_fts f '
      'WHERE f.session_id = m.session_id AND f.memory_id = m.memory_id) '
      'AS fts_present '
      'FROM experiential_memories m '
      "WHERE m.session_id = ? AND m.turn_number = ? AND m.source = 'auto'",
      variables: [
        Variable.withString(sessionId),
        Variable.withInt(turnNumber),
      ],
    ).get();
    if (rows.isEmpty) return null;
    return jsonEncode(
      rows
          .map(
            (r) => {
              ...r.data,
              if (ownedIds.contains(r.read<String>('memory_id')))
                'snapshot_session_id': sessionId,
              'embedding': r.readNullable<Uint8List>('embedding') == null
                  ? null
                  : base64Encode(r.readNullable<Uint8List>('embedding')!),
            },
          )
          .toList(),
    );
  }

  /// 保留快照内容，仅清除可恢复的单轮来源标记。
  String? _invalidateSnapshotSourceTurn(String? snapshotJson) {
    if (snapshotJson == null) return null;
    final Object? snapshot;
    try {
      snapshot = jsonDecode(snapshotJson);
    } on FormatException {
      return snapshotJson;
    }
    if (snapshot is! List<Object?>) return snapshotJson;

    var changed = false;
    for (final row in snapshot.whereType<Map<String, Object?>>()) {
      final verified = row['has_verified_source_turn'];
      if (verified != 1 && verified != true) continue;
      row['has_verified_source_turn'] = 0;
      changed = true;
    }
    return changed ? jsonEncode(snapshot) : snapshotJson;
  }

  /// 按快照恢复某轮经历记忆行（原 memory_id 复用——切换前已删除该轮
  /// auto 行，原 id 无碰撞；FTS 行按快照标记重建）。须在事务内调用。
  Future<void> _restoreExperientialRows(
    String sessionId,
    int turnNumber,
    String? snapshotJson, {
    bool allowVerifiedSourceTurn = false,
  }) async {
    if (snapshotJson == null || snapshotJson.isEmpty) return;
    for (final item in _snapshotRows(snapshotJson)) {
      final existing = await _database.customSelect(
        'SELECT 1 FROM experiential_memories WHERE memory_id = ? LIMIT 1',
        variables: [Variable.withString(item['memory_id'] as String)],
      ).get();
      if (existing.isNotEmpty) throw const _VariantRestoreRejected();
      final embeddingB64 = item['embedding'] as String?;
      await _database.customStatement(
        'INSERT INTO experiential_memories '
        '(memory_id, session_id, summary, when_text, where_text, who_text, '
        'what_text, significance, extra, importance, tags, turn_number, '
        'narrative_time, narrative_period, embedding, has_embedding, '
        'embedding_dimensions, is_archived, is_summary, memory_level, '
        'parent_event_ids, macro_trigger_reason, archived_event_ids, '
        'has_verified_source_turn, '
        'created_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '
        '?, ?, ?, ?, ?)',
        [
          item['memory_id'],
          sessionId,
          item['summary'] ?? '',
          item['when_text'],
          item['where_text'],
          item['who_text'],
          item['what_text'],
          item['significance'],
          item['extra'],
          item['importance'] ?? 3,
          item['tags'] ?? '[]',
          turnNumber,
          item['narrative_time'],
          item['narrative_period'],
          if (embeddingB64 == null)
            null
          else
            Uint8List.fromList(base64Decode(embeddingB64)),
          item['has_embedding'] == 1 || item['has_embedding'] == true,
          item['embedding_dimensions'],
          item['is_archived'] == 1 || item['is_archived'] == true,
          item['is_summary'] == 1 || item['is_summary'] == true,
          item['memory_level'] ?? 'micro',
          item['parent_event_ids'],
          item['macro_trigger_reason'],
          item['archived_event_ids'],
          allowVerifiedSourceTurn &&
              (item['has_verified_source_turn'] == 1 ||
                  item['has_verified_source_turn'] == true),
          // created_at 随 drift 日期文本格式存回快照原值
          item['created_at'],
        ],
      );
      if (item['fts_present'] != 0) {
        await _database.customStatement(
          'INSERT INTO memories_fts '
          '(summary, when_text, where_text, who_text, what_text, '
          'significance, extra, memory_id, memory_type, session_id) '
          "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'experiential', ?)",
          [
            item['summary'] ?? '',
            item['when_text'] ?? '',
            item['where_text'] ?? '',
            item['who_text'] ?? '',
            item['what_text'] ?? '',
            item['significance'] ?? '',
            item['extra'] ?? '',
            item['memory_id'],
            sessionId,
          ],
        );
      }
    }
  }

  @override
  Future<bool> persistConsolidatedMemories({
    required String sessionId,
    required List<ConsolidatedMemoryRecord> records,
    required List<ExperientialMemory> originalMemories,
  }) async {
    if (records.isEmpty || originalMemories.isEmpty) return false;
    return _database.transaction(() async {
      // 模型等待期间可能删轮、切稿或编辑经历。先在写入事务内校验
      // 模型使用的全部源数据，避免迟到的产物重新写入已撤回的经历。
      for (final original in originalMemories) {
        final current = await _experienceRepository.getExperienceById(
          original.memoryId,
        );
        if (current == null ||
            original.sessionId != sessionId ||
            current.sessionId != sessionId ||
            current.isArchived ||
            current.turnNumber != original.turnNumber ||
            current.summary != original.summary ||
            current.importance != original.importance ||
            !const ListEquality<String>().equals(current.tags, original.tags)) {
          return false;
        }
      }

      final originalIds =
          originalMemories.map((memory) => memory.memoryId).toList();
      final placeholders = List.filled(originalIds.length, '?').join(', ');
      final indexedSources = await _database.customSelect(
        'SELECT 1 FROM memories_fts WHERE session_id = ? '
        'AND memory_id IN ($placeholders) LIMIT 1',
        variables: [
          Variable.withString(sessionId),
          for (final id in originalIds) Variable.withString(id),
        ],
      ).get();
      if (indexedSources.isNotEmpty) return false;

      // append 同时写入经历和 FTS，随后补上可用的向量。
      for (final record in records) {
        final memory = await _experienceRepository.appendExperience(
          sessionId: sessionId,
          summary: record.summary,
          importance: record.importance,
          tags: record.tags,
          turnNumber: record.turnNumber,
        );
        final embedding = record.embedding;
        if (embedding != null) {
          await _experienceRepository.updateEmbedding(
            memory.memoryId,
            embedding,
          );
        }
      }

      await _experienceRepository.deleteExperiencesByIds(
        sessionId: sessionId,
        memoryIds: originalIds,
      );
      return true;
    });
  }

  /// INSERT 一行到 intermediate_round_artifacts（内部辅助方法）
  Future<void> _insertArtifacts(
    StoryRoundArtifacts artifacts, {
    required String? factsDeltas,
  }) async {
    await _database.customStatement(
      'INSERT INTO intermediate_round_artifacts '
      '(session_id, turn_number, generated_text, extracted_keywords, '
      'retrieved_memories, retrieved_facts, reply_text, event_summary, '
      'facts_changes, agent_steps, agent_timeline, agent_summary, '
      'story_anchor, review_executed, created_at, current_variant_index, '
      'facts_deltas) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        artifacts.sessionId,
        artifacts.turnNumber,
        artifacts.generatedText,
        StoryRoundArtifacts.stringifyDraftKeywords(artifacts.extractedKeywords),
        ExperientialMemory.listToJsonString(artifacts.retrievedMemories),
        RetrievedFact.listToJsonString(artifacts.retrievedFacts),
        artifacts.replyText,
        StoryRoundArtifacts.stringifyEventSummary(artifacts.eventSummary),
        StoryRoundArtifacts.stringifyFactsChanges(artifacts.factsChanges),
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
        factsDeltas,
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

class _VariantRestoreRejected implements Exception {
  const _VariantRestoreRejected();
}
