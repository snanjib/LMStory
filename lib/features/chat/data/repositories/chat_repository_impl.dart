import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_mode.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/fork_anchor.dart';
import 'package:lmstory/features/chat/domain/entities/message_attachment.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/entities/search_result.dart';
import 'package:lmstory/features/chat/domain/entities/session_phase_models.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/memory/data/repositories/memory_fts_rebuilder.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
import 'package:uuid/uuid.dart';

/// ChatRepository 实现
///
/// 使用 drift 数据库进行数据持久化。
class ChatRepositoryImpl implements ChatRepository {
  ChatRepositoryImpl({
    required AppDatabase database,
  }) : _database = database;

  final AppDatabase _database;
  final _uuid = const Uuid();

  // ==================== 会话操作 ====================

  @override
  Future<ChatSession> createSession({
    required String title,
    String mode = ChatMode.chat,
    String? modelId,
    String? presetId,
  }) async {
    final now = DateTime.now();
    final sessionId = _uuid.v4();

    // Compute sortOrder: min existing sortOrder - 1000
    // 新会话 sortOrder 最小，侧边栏按 sortOrder 升序排列时出现在列表顶部（最新在上）。
    // 注意：不能改为按 lastActiveAt 反转排序，否则会破坏用户拖拽自定义顺序
    // （_handleReorder 按显示顺序重排 sortOrder 为 0,1000,2000...）。
    final minRow = await (_database.selectOnly(_database.chatSessionsTable)
          ..addColumns([
            _database.chatSessionsTable.sortOrder.min(),
          ]))
        .getSingle();
    final minSortOrder = minRow.read(
          _database.chatSessionsTable.sortOrder.min(),
        ) ??
        0.0;
    final sortOrder = minSortOrder - 1000.0;

    await _database.into(_database.chatSessionsTable).insert(
          ChatSessionsTableCompanion.insert(
            sessionId: sessionId,
            title: title,
            mode: Value(mode),
            createdAt: Value(now),
            lastActiveAt: Value(now),
            messageCount: const Value(0),
            modelId: Value(modelId),
            presetId: Value(presetId),
            sortOrder: Value(sortOrder),
          ),
        );

    return ChatSession(
      sessionId: sessionId,
      title: title,
      mode: mode,
      createdAt: now,
      lastActiveAt: now,
      messageCount: 0,
      modelId: modelId,
      presetId: presetId,
      sortOrder: sortOrder,
    );
  }

  @override
  Future<List<ChatSession>> getAllSessions() async {
    final rows = await (_database.select(_database.chatSessionsTable)
          ..orderBy([
            (t) => OrderingTerm(
                  expression: t.lastActiveAt,
                  mode: OrderingMode.desc,
                ),
          ]))
        .get();
    final sessions = rows.map(_sessionFromRow).toList();

    // Batch-fetch last message preview for each session (2 queries total)
    if (sessions.isNotEmpty) {
      final sessionIds = sessions.map((s) => s.sessionId).toList();
      final placeholders = sessionIds.map((_) => '?').join(', ');
      final previewRows = await _database
          .customSelect(
            'SELECT cm.session_id, cm.content FROM chat_messages cm '
            'INNER JOIN ('
            '  SELECT session_id, MAX(id) AS max_id FROM chat_messages '
            '  WHERE session_id IN ($placeholders) '
            '  GROUP BY session_id '
            ') sub ON cm.id = sub.max_id',
            variables: sessionIds.map(Variable.withString).toList(),
          )
          .get();

      final previews = <String, String>{};
      for (final row in previewRows) {
        final content = row.read<String?>('content');
        if (content != null) {
          previews[row.read<String>('session_id')] =
              content.length > 50 ? content.substring(0, 50) : content;
        }
      }

      return sessions
          .map((s) => s.copyWith(lastMessagePreview: previews[s.sessionId]))
          .toList();
    }

    return sessions;
  }

  @override
  Future<ChatSession> getSession(String sessionId) async {
    final row = await (_database.select(_database.chatSessionsTable)
          ..where((t) => t.sessionId.equals(sessionId)))
        .getSingleOrNull();

    if (row == null) {
      throw ModelNotFoundException(sessionId);
    }
    return _sessionFromRow(row);
  }

  @override
  Future<String?> getSessionDraft(String sessionId) async {
    final row = await (_database.select(_database.chatSessionsTable)
          ..where((t) => t.sessionId.equals(sessionId)))
        .getSingleOrNull();
    return row?.draftInput;
  }

  @override
  Future<void> setSessionDraft(String sessionId, String? draft) async {
    await (_database.update(_database.chatSessionsTable)
          ..where((t) => t.sessionId.equals(sessionId)))
        .write(ChatSessionsTableCompanion(draftInput: Value(draft)));
  }

  @override
  Future<void> setSessionStarred(
    String sessionId, {
    required bool starred,
  }) async {
    await (_database.update(_database.chatSessionsTable)
          ..where((t) => t.sessionId.equals(sessionId)))
        .write(ChatSessionsTableCompanion(isStarred: Value(starred)));
  }

  @override
  Future<ChatSession> updateSession(ChatSession session) async {
    await (_database.update(_database.chatSessionsTable)
          ..where((t) => t.sessionId.equals(session.sessionId)))
        .write(
      ChatSessionsTableCompanion(
        title: Value(session.title),
        mode: Value(session.mode),
        messageCount: Value(session.messageCount),
        modelId: Value(session.modelId),
        presetId: Value(session.presetId),
        systemPromptOverride: Value(session.systemPromptOverride),
        temperature: Value(session.temperature),
        topP: Value(session.topP),
        maxTokens: Value(session.maxTokens),
        autoCompaction: Value(session.autoCompaction),
        compactionThreshold: Value(session.compactionThreshold),
        streamEnabled: Value(session.streamEnabled),
        maxContextMessages: Value(session.maxContextMessages),
        effectiveContextLimit: Value(session.effectiveContextLimit),
        reasoningEffort: Value(session.reasoningEffort?.toJson()),
        jsonModeOverride: Value(session.jsonModeOverride),
        // schemaVersion ≥ 23：会话级分步骤模型配置（8 列）
        generatingPresetId: Value(session.phaseModels.generatingPresetId),
        generatingModelId: Value(session.phaseModels.generatingModelId),
        extractingPresetId: Value(session.phaseModels.extractingPresetId),
        extractingModelId: Value(session.phaseModels.extractingModelId),
        reviewingPresetId: Value(session.phaseModels.reviewingPresetId),
        reviewingModelId: Value(session.phaseModels.reviewingModelId),
        summarizingPresetId: Value(session.phaseModels.summarizingPresetId),
        summarizingModelId: Value(session.phaseModels.summarizingModelId),
        isStarred: Value(session.isStarred),
        sortOrder: Value(session.sortOrder),
        currentNarrativeTime: Value(session.currentNarrativeTime),
        suggestReplyPresetId: Value(session.suggestReplyPresetId),
        suggestReplyModelId: Value(session.suggestReplyModelId),
        suggestReplyPromptOverride: Value(session.suggestReplyPromptOverride),
        // schemaVersion ≥ 31：终稿审查会话级覆盖
        reviewEnabledOverride: Value(session.reviewEnabledOverride),
        // 审查  修复：contextBudget 会话级覆盖
        recentMinRatioOverride: Value(session.recentMinRatioOverride),
        retrievalRatioOverride: Value(session.retrievalRatioOverride),
        maxSteps: Value(session.maxSteps),
        // schemaVersion ≥ 42：剧情锚 JSON（体验重构卡片 C）
        storyAnchor: Value(StoryAnchor.stringify(session.storyAnchor)),
        watchMode: Value(session.watchMode),
        // schemaVersion ≥ 44：导演工具权限 + 单轮时间预算会话覆盖
        toolPermissions: Value(session.toolPermissions),
        maxDurationMinutes: Value(session.maxDurationMinutes),
        // schemaVersion ≥ 46：剧情节奏档会话覆盖
        narrativePacing: Value(session.narrativePacing),
        // schemaVersion ≥ 47： turn 单一事实源计数器
        nextTurn: Value(session.nextTurn),
        // 检索松紧度快照 JSON（repairSchema 开库补列）
        retrievalOverrides: Value(session.retrievalOverrides),
        // 向导「初始化你的角色」两列（repairSchema 开库补列）
        characterInitPrompt: Value(session.characterInitPrompt),
        characterInitCardId: Value(session.characterInitCardId),
      ),
    );

    return session;
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    await _database.transaction(() async {
      await (_database.delete(_database.chatMessagesTable)
            ..where((t) => t.sessionId.equals(sessionId)))
          .go();
      await (_database.delete(_database.compactionPointsTable)
            ..where((t) => t.sessionId.equals(sessionId)))
          .go();
      await (_database.delete(_database.chatSessionBranchesTable)
            ..where((t) => t.sessionId.equals(sessionId)))
          .go();
      //  修复：连带清理导演模式事件日志——
      // 此前删会话后 agent_events 永久残留（隐私残留 + 存储膨胀）。
      await (_database.delete(_database.agentEventsTable)
            ..where((t) => t.sessionId.equals(sessionId)))
          .go();
      //  删会话须清空该会话全部衍生数据。
      // 此前经历记忆/事实三表/轮次产物/两个 FTS 索引/失败日志永久残留——
      // 用户确认「此操作不可恢复」后以为删干净，实际记忆与失败详情仍在库中
      //（隐私残留 + 存储膨胀）。与 backupRepository.deleteSessionData 同口径。
      await (_database.delete(_database.experientialMemoriesTable)
            ..where((t) => t.sessionId.equals(sessionId)))
          .go();
      await (_database.delete(_database.intermediateRoundArtifactsTable)
            ..where((t) => t.sessionId.equals(sessionId)))
          .go();
      // 稿件变体随会话删除——正文/思考/幕后过程/
      // 锚快照都在 message_variants 行里，残留即隐私残留 + 幽灵变体可被
      // 切换物化（与 backupRepository.deleteSessionData 同口径）。
      await (_database.delete(_database.messageVariantsTable)
            ..where((t) => t.sessionId.equals(sessionId)))
          .go();
      // factual_memory_history 无 session_id 列：先按实体子查询删历史，再删实体
      await _database.customStatement(
        'DELETE FROM factual_memory_history WHERE entity_id IN '
        '(SELECT entity_id FROM factual_entities WHERE session_id = ?)',
        [sessionId],
      );
      await (_database.delete(_database.factualAttributesTable)
            ..where((t) => t.sessionId.equals(sessionId)))
          .go();
      await (_database.delete(_database.factualEntitiesTable)
            ..where((t) => t.sessionId.equals(sessionId)))
          .go();
      // 两个 FTS5 虚拟表（无 drift 表对象，原生语句按 session 清行）
      await _database.customStatement(
        'DELETE FROM memories_fts WHERE session_id = ?',
        [sessionId],
      );
      await _database.customStatement(
        'DELETE FROM factual_fts WHERE session_id = ?',
        [sessionId],
      );
      await (_database.delete(_database.failureLogsTable)
            ..where((t) => t.sessionId.equals(sessionId)))
          .go();
      await (_database.delete(_database.chatSessionsTable)
            ..where((t) => t.sessionId.equals(sessionId)))
          .go();
    });
  }

  @override
  Future<void> deleteAllSessions() async {
    // 2026-09-09 审查（FF22）：与 deleteSession / deleteAllSessionData
    // 同口径——此前只删消息与会话，记忆三表、经历记忆与两个 FTS 索引全成
    // 孤儿（当前无生产调用点，但重新接线即隐私残留 + 索引指向不存在会话）。
    await _database.transaction(() async {
      await _database.delete(_database.factualAttributesTable).go();
      await _database.delete(_database.factualMemoryHistoryTable).go();
      await _database.delete(_database.factualEntitiesTable).go();
      await _database.customStatement('DELETE FROM factual_fts');
      await _database.delete(_database.experientialMemoriesTable).go();
      await _database.customStatement('DELETE FROM memories_fts');
      await _database.delete(_database.chatMessagesTable).go();
      await _database.delete(_database.compactionPointsTable).go();
      await _database.delete(_database.chatSessionBranchesTable).go();
      //  修复：同 deleteSession，全量清空时一并清事件日志
      await _database.delete(_database.agentEventsTable).go();
      // 稿件变体一并清空（同 deleteSession 口径）
      await _database.delete(_database.messageVariantsTable).go();
      await _database.delete(_database.chatSessionsTable).go();
    });
  }

  @override
  Future<void> recreateConversationTables() async {
    await _database.recreateConversationTables();
  }

  @override
  Future<SchemaRepairResult> repairSchema() async {
    return _database.repairSchema();
  }

  @override
  Future<void> updateSessionLastActive(String sessionId) async {
    await (_database.update(_database.chatSessionsTable)
          ..where((t) => t.sessionId.equals(sessionId)))
        .write(
      ChatSessionsTableCompanion(
        lastActiveAt: Value(DateTime.now()),
      ),
    );
  }

  @override
  Future<void> updateSessionMessageCount(String sessionId, int count) async {
    await (_database.update(_database.chatSessionsTable)
          ..where((t) => t.sessionId.equals(sessionId)))
        .write(
      ChatSessionsTableCompanion(
        messageCount: Value(count),
      ),
    );
  }

  @override
  Future<ChatSession> copySession(
    String sourceSessionId, {
    String copySuffix = '(Copy)',
  }) {
    // OH-3：复制全程包进单事务——此前会话行 insert 后逐条
    // await 插入消息，进程被杀/DB 异常时留下「有会话行、缺尾部消息」的
    // 半份副本，违反持久化事务性不变量。消息/压缩点/分支行改为同事务
    // batch 插入。
    return _database.transaction(() async {
      final sourceSession = await getSession(sourceSessionId);
      final sourceMessages = await getMessages(sourceSessionId);
      // CH-3a：压缩点与分支快照随会话复制——此前只复制
      // 消息行：压缩点全部失配使 getCompressedMessages 退化为全量注入
      // （旧摘要整批进入 API 上下文+超窗），Fork 结构全丢。
      final sourceCompactionPoints = await getCompactionPoints(
        sourceSessionId,
      );
      final sourceBranchRows =
          await (_database.select(_database.chatSessionBranchesTable)
                ..where((t) => t.sessionId.equals(sourceSessionId)))
              .get();
      // 轮产物与稿件变体随会话
      // 复制——两表均按 (session_id, turn_number) 键、无消息 id 引用，改
      // session_id 即可；此前不复制导致副本幕后时间线/Recap 小窗丢失、
      // 变体悬空（后 message_variants 行也随副本齐全，指针列
      // current_variant_index 原值保留）。
      final sourceArtifactRows =
          await (_database.select(_database.intermediateRoundArtifactsTable)
                ..where((t) => t.sessionId.equals(sourceSessionId)))
              .get();
      final sourceVariantRows =
          await (_database.select(_database.messageVariantsTable)
                ..where((t) => t.sessionId.equals(sourceSessionId)))
              .get();

      final now = DateTime.now();
      final newSessionId = _uuid.v4();
      // CH-3c：后缀由展示层注入本地化文案（默认兼容旧值）
      final newTitle = '${sourceSession.title}$copySuffix';

      // 消息 id 重映射：副本消息必须获得全新 id（message_id 全局唯一，
      // 不能沿用源 id），压缩点/分支锚点/parent 引用经同一映射改写，
      // 保证副本自洽、不跨会话引用源消息。
      final messageIdMap = <String, String>{
        for (final msg in sourceMessages) msg.messageId: _uuid.v4(),
      };
      // 分支快照内的消息不在 chat_messages 表内，同样分配新 id 并改写
      // 快照 JSON 中的 sessionId/parent 引用（否则副本切分支会把指向
      // 源会话的消息行插回表内）。
      final remappedSnapshots = <List<_BranchSnapshot>>[];
      for (final row in sourceBranchRows) {
        final snapshots = _decodeSnapshots(row.branchSnapshots);
        for (final snapshot in snapshots) {
          for (final message in snapshot.messages) {
            messageIdMap.putIfAbsent(message.messageId, _uuid.v4);
          }
        }
        remappedSnapshots.add([
          for (final snapshot in snapshots)
            _BranchSnapshot(
              index: snapshot.index,
              messages: [
                for (final message in snapshot.messages)
                  message.copyWith(
                    messageId:
                        messageIdMap[message.messageId] ?? message.messageId,
                    sessionId: newSessionId,
                    // 未命中映射时 copyWith(null) 保留原值
                    parentUserMsgId: _mappedMessageId(
                      message.parentUserMsgId,
                      messageIdMap,
                    ),
                  ),
              ],
            ),
        ]);
      }

      // CH-3b：sortOrder 同 createSession 取 min-1000——
      // 此前不写该列（表默认 0），在用户拖拽排序（0,1000,…）的列表里
      // 副本与首项撞值导致排序错乱。
      final minRow = await (_database.selectOnly(_database.chatSessionsTable)
            ..addColumns([
              _database.chatSessionsTable.sortOrder.min(),
            ]))
          .getSingle();
      final minSortOrder = minRow.read(
            _database.chatSessionsTable.sortOrder.min(),
          ) ??
          0.0;
      final sortOrder = minSortOrder - 1000.0;

      await _database.into(_database.chatSessionsTable).insert(
            ChatSessionsTableCompanion.insert(
              sessionId: newSessionId,
              title: newTitle,
              mode: Value(sourceSession.mode),
              createdAt: Value(now),
              lastActiveAt: Value(now),
              messageCount: Value(sourceSession.messageCount),
              modelId: Value(sourceSession.modelId),
              presetId: Value(sourceSession.presetId),
              systemPromptOverride: Value(sourceSession.systemPromptOverride),
              temperature: Value(sourceSession.temperature),
              topP: Value(sourceSession.topP),
              maxTokens: Value(sourceSession.maxTokens),
              autoCompaction: Value(sourceSession.autoCompaction),
              compactionThreshold: Value(sourceSession.compactionThreshold),
              streamEnabled: Value(sourceSession.streamEnabled),
              maxContextMessages: Value(sourceSession.maxContextMessages),
              effectiveContextLimit: Value(sourceSession.effectiveContextLimit),
              reasoningEffort: Value(sourceSession.reasoningEffort?.toJson()),
              jsonModeOverride: Value(sourceSession.jsonModeOverride),
              // schemaVersion ≥ 23：会话级分步骤模型配置（8 列）随会话复制
              generatingPresetId:
                  Value(sourceSession.phaseModels.generatingPresetId),
              generatingModelId:
                  Value(sourceSession.phaseModels.generatingModelId),
              extractingPresetId:
                  Value(sourceSession.phaseModels.extractingPresetId),
              extractingModelId:
                  Value(sourceSession.phaseModels.extractingModelId),
              reviewingPresetId:
                  Value(sourceSession.phaseModels.reviewingPresetId),
              reviewingModelId:
                  Value(sourceSession.phaseModels.reviewingModelId),
              summarizingPresetId:
                  Value(sourceSession.phaseModels.summarizingPresetId),
              summarizingModelId:
                  Value(sourceSession.phaseModels.summarizingModelId),
              // schemaVersion ≥ 26：会话级当前叙事时间随会话复制（保留故事进度）
              currentNarrativeTime: Value(sourceSession.currentNarrativeTime),
              suggestReplyPresetId: Value(sourceSession.suggestReplyPresetId),
              suggestReplyModelId: Value(sourceSession.suggestReplyModelId),
              suggestReplyPromptOverride:
                  Value(sourceSession.suggestReplyPromptOverride),
              // schemaVersion ≥ 31：终稿审查会话级覆盖随会话复制
              reviewEnabledOverride: Value(sourceSession.reviewEnabledOverride),
              // 审查  修复：contextBudget 会话级覆盖随会话复制
              recentMinRatioOverride:
                  Value(sourceSession.recentMinRatioOverride),
              retrievalRatioOverride:
                  Value(sourceSession.retrievalRatioOverride),
              // OH-2：v0.3 导演会话列随会话复制（与
              // updateSession 对齐）——此前这些列静默丢失：工具权限（安全
              // 相关）/单轮时间预算/节奏档/每轮步数回退默认，轮次计数器
              // 从 1 重开。
              maxSteps: Value(sourceSession.maxSteps),
              // schemaVersion ≥ 42：剧情锚随会话复制（体验重构卡片 C）
              storyAnchor:
                  Value(StoryAnchor.stringify(sourceSession.storyAnchor)),
              watchMode: Value(sourceSession.watchMode),
              toolPermissions: Value(sourceSession.toolPermissions),
              maxDurationMinutes: Value(sourceSession.maxDurationMinutes),
              narrativePacing: Value(sourceSession.narrativePacing),
              nextTurn: Value(sourceSession.nextTurn),
              retrievalOverrides: Value(sourceSession.retrievalOverrides),
              // 向导「初始化你的角色」两列随会话复制（草稿副本的第 1 轮
              // 仍按一次性语义注入）
              characterInitPrompt: Value(sourceSession.characterInitPrompt),
              characterInitCardId: Value(sourceSession.characterInitCardId),
              // CH-3b：见上
              sortOrder: Value(sortOrder),
            ),
          );

      // 同事务 batch 插入：消息 + 压缩点 + 分支行
      await _database.batch((batch) {
        // Copy all messages with new IDs and the new session ID
        for (final msg in sourceMessages) {
          batch.insert(
            _database.chatMessagesTable,
            ChatMessagesTableCompanion.insert(
              messageId: messageIdMap[msg.messageId]!,
              sessionId: newSessionId,
              role: msg.role,
              content: Value(msg.content),
              toolCalls: Value(msg.toolCalls),
              toolCallId: Value(msg.toolCallId),
              thinkingContent: Value(msg.thinkingContent),
              thinkingDuration: Value(msg.thinkingDuration),
              reasoningContent: Value(msg.reasoningContent),
              parentUserMsgId: Value(
                _mappedMessageId(msg.parentUserMsgId, messageIdMap) ??
                    msg.parentUserMsgId,
              ),
              branchIndex: Value(msg.branchIndex),
              isSummary: Value(msg.isSummary),
              isContinued: Value(msg.isContinued),
              attachments: Value(
                msg.attachments != null && msg.attachments!.isNotEmpty
                    ? MessageAttachment.listToJson(msg.attachments!)
                    : null,
              ),
              error: Value(msg.error),
              tokensUsed: Value(msg.tokensUsed),
              firstTokenLatency: Value(msg.firstTokenLatency),
              modelName: Value(msg.modelName),
              createdAt: Value(msg.createdAt),
            ),
          );
        }

        // 压缩点：仅复制两侧引用在副本内均可解析的行——失配行复制过去
        // 只会复现 boundary/summary 失配的全量回退（同口径：不留脏点）。
        for (final point in sourceCompactionPoints) {
          final summaryId = _mappedMessageId(
            point['summaryMessageId'] as String?,
            messageIdMap,
          );
          final boundaryId = _mappedMessageId(
            point['boundaryMessageId'] as String?,
            messageIdMap,
          );
          if (summaryId == null || boundaryId == null) continue;
          batch.insert(
            _database.compactionPointsTable,
            CompactionPointsTableCompanion.insert(
              sessionId: newSessionId,
              summaryMessageId: summaryId,
              boundaryMessageId: boundaryId,
              createdAt: Value(point['createdAt'] as DateTime),
            ),
          );
        }

        // 分支结构：锚点经映射改写后随会话复制；锚点在副本内无法解析的
        // 脏行跳过（保留只会得到指向源会话的死锚点）。
        for (var i = 0; i < sourceBranchRows.length; i++) {
          final row = sourceBranchRows[i];
          final anchorId = _mappedMessageId(
            row.anchorUserMsgId,
            messageIdMap,
          );
          if (anchorId == null) continue;
          batch.insert(
            _database.chatSessionBranchesTable,
            ChatSessionBranchesTableCompanion.insert(
              sessionId: newSessionId,
              anchorUserMsgId: anchorId,
              activeBranchIndex: Value(row.activeBranchIndex),
              branchCount: Value(row.branchCount),
              branchSnapshots: Value(_encodeSnapshots(remappedSnapshots[i])),
              createdAt: Value(row.createdAt),
            ),
          );
        }

        // 轮产物与稿件变体：改 session_id 原样复制（id 置 absent 由新库
        // 自增分配，否则与源行主键冲突）。
        for (final row in sourceArtifactRows) {
          batch.insert(
            _database.intermediateRoundArtifactsTable,
            row.copyWith(sessionId: newSessionId).toCompanion(true).copyWith(
                  id: const Value.absent(),
                ),
          );
        }
        for (final row in sourceVariantRows) {
          batch.insert(
            _database.messageVariantsTable,
            row.copyWith(sessionId: newSessionId).toCompanion(true).copyWith(
                  id: const Value.absent(),
                ),
          );
        }
      });

      // 记忆补齐：记忆随会话搬运。
      // 留在 copySession 单事务内——中途失败整体回滚，不留「有会话行、
      // 无记忆」的半份副本。
      await _copySessionMemories(sourceSessionId, newSessionId);

      return ChatSession(
        sessionId: newSessionId,
        title: newTitle,
        mode: sourceSession.mode,
        createdAt: now,
        lastActiveAt: now,
        messageCount: sourceSession.messageCount,
        modelId: sourceSession.modelId,
        presetId: sourceSession.presetId,
        systemPromptOverride: sourceSession.systemPromptOverride,
        temperature: sourceSession.temperature,
        topP: sourceSession.topP,
        maxTokens: sourceSession.maxTokens,
        autoCompaction: sourceSession.autoCompaction,
        compactionThreshold: sourceSession.compactionThreshold,
        streamEnabled: sourceSession.streamEnabled,
        maxContextMessages: sourceSession.maxContextMessages,
        effectiveContextLimit: sourceSession.effectiveContextLimit,
        reasoningEffort: sourceSession.reasoningEffort,
        jsonModeOverride: sourceSession.jsonModeOverride,
        // schemaVersion ≥ 23：会话级分步骤模型配置（8 列）随会话复制
        phaseModels: sourceSession.phaseModels,
        // schemaVersion ≥ 26：会话级当前叙事时间随会话复制（保留故事进度）
        currentNarrativeTime: sourceSession.currentNarrativeTime,
        // schemaVersion ≥ 31：终稿审查会话级覆盖随会话复制
        reviewEnabledOverride: sourceSession.reviewEnabledOverride,
        // 审查  修复：contextBudget 会话级覆盖随会话复制
        recentMinRatioOverride: sourceSession.recentMinRatioOverride,
        retrievalRatioOverride: sourceSession.retrievalRatioOverride,
        // OH-2：v0.3 导演会话列与剧情锚——返回实体与落库行对齐
        maxSteps: sourceSession.maxSteps,
        storyAnchor: sourceSession.storyAnchor,
        watchMode: sourceSession.watchMode,
        toolPermissions: sourceSession.toolPermissions,
        maxDurationMinutes: sourceSession.maxDurationMinutes,
        narrativePacing: sourceSession.narrativePacing,
        nextTurn: sourceSession.nextTurn,
        retrievalOverrides: sourceSession.retrievalOverrides,
        characterInitPrompt: sourceSession.characterInitPrompt,
        characterInitCardId: sourceSession.characterInitCardId,
        // CH-3b：返回实体携带实际落库的排序值
        sortOrder: sortOrder,
      );
    });
  }

  /// 复制会话记忆
  ///
  /// 事实层三表（实体/属性/审计历史）与经历记忆随会话搬运，业务 ID 全部
  /// 重映射——副本与源**内容等价、ID 不共享**，删任一侧不影响另一侧。
  /// 两个 FTS5 索引以落库后的副本主表重建（memory_fts_rebuilder，禁止
  /// 第三份重建 SQL）。
  ///
  /// 明确不搬运：`failure_logs` / `agent_events`（同 / 口径，副本从空
  /// 开始）；`intermediate_round_artifacts` 的 retrieved_facts/facts_changes
  /// JSON 内的历史 entity_id **不重映射**——仅用于面板展示，不参与检索与
  /// 写回（重映射历史 JSON 属扩大范围，见实施计划 §1.4）。
  ///
  /// `embedding` BLOB 与 `has_embedding` 原样保留：同嵌入模型下向量仍有效；
  /// 换模型产生的陈旧向量由健康面板的维度自愈流程处理。
  Future<void> _copySessionMemories(
    String sourceSessionId,
    String newSessionId,
  ) async {
    // ---------- 事实层：实体 → 属性 → 审计历史 ----------
    final sourceEntities = await (_database.select(
      _database.factualEntitiesTable,
    )..where((t) => t.sessionId.equals(sourceSessionId)))
        .get();
    final sourceAttributes = await (_database.select(
      _database.factualAttributesTable,
    )..where((t) => t.sessionId.equals(sourceSessionId)))
        .get();
    final entityIdMap = <String, String>{
      for (final row in sourceEntities) row.entityId: 'ent_${_uuid.v4()}',
    };
    final attributeIdMap = <String, String>{
      for (final row in sourceAttributes) row.attributeId: 'attr_${_uuid.v4()}',
    };
    // 审计历史无 session_id 列：按源实体集合取行（deleteSession 同口径）
    final sourceHistory = entityIdMap.isEmpty
        ? const <FactualMemoryHistoryTableData>[]
        : await (_database.select(_database.factualMemoryHistoryTable)
              ..where((t) => t.entityId.isIn(entityIdMap.keys.toList())))
            .get();

    // ---------- 经历层：微/宏记忆 + parent_event_ids 重映射 ----------
    final sourceMemories = await (_database.select(
      _database.experientialMemoriesTable,
    )..where((t) => t.sessionId.equals(sourceSessionId)))
        .get();
    final memoryIdMap = <String, String>{
      for (final row in sourceMemories) row.memoryId: _uuid.v4(),
    };

    await _database.batch((batch) {
      for (final row in sourceEntities) {
        batch.insert(
          _database.factualEntitiesTable,
          row
              .copyWith(
                entityId: entityIdMap[row.entityId],
                sessionId: newSessionId,
              )
              .toCompanion(true)
              .copyWith(id: const Value.absent()),
        );
      }
      for (final row in sourceAttributes) {
        batch.insert(
          _database.factualAttributesTable,
          row
              .copyWith(
                attributeId: attributeIdMap[row.attributeId],
                // 映射外（跨会话/悬空）引用保持原值——内容等价优先
                entityId: entityIdMap[row.entityId] ?? row.entityId,
                sessionId: newSessionId,
              )
              .toCompanion(true)
              .copyWith(id: const Value.absent()),
        );
      }
      for (final row in sourceHistory) {
        batch.insert(
          _database.factualMemoryHistoryTable,
          row
              .copyWith(
                entityId: entityIdMap[row.entityId],
                // 源行为 NULL 保持 NULL；指向映射外属性（已删/跨会话）置 NULL
                attributeId: Value(attributeIdMap[row.attributeId]),
              )
              .toCompanion(true)
              .copyWith(id: const Value.absent()),
        );
      }
      for (final row in sourceMemories) {
        batch.insert(
          _database.experientialMemoriesTable,
          row
              .copyWith(
                memoryId: memoryIdMap[row.memoryId],
                sessionId: newSessionId,
                parentEventIds: Value(
                  _remapParentEventIds(row.parentEventIds, memoryIdMap),
                ),
              )
              .toCompanion(true)
              .copyWith(id: const Value.absent()),
        );
      }
    });

    await rebuildSessionFts(_database, newSessionId);
  }

  /// 宏记忆 parent_event_ids 重映射：逐个映射到副本记忆 id，未命中的剔除
  /// （源 JSON 可能引用已删除/跨会话记忆；引用列表允许收缩）。
  /// micro 行（NULL）与异常 JSON 原样保留，不因复制破坏数据。
  String? _remapParentEventIds(
    String? parentEventIds,
    Map<String, String> memoryIdMap,
  ) {
    if (parentEventIds == null) return null;
    try {
      final decoded = jsonDecode(parentEventIds);
      if (decoded is! List) return parentEventIds;
      return jsonEncode([
        for (final id in decoded)
          if (id is String && memoryIdMap[id] != null) memoryIdMap[id]!,
      ]);
    } on FormatException {
      return parentEventIds;
    }
  }

  @override
  Future<void> updateSessionTitle(String sessionId, String title) async {
    await (_database.update(_database.chatSessionsTable)
          ..where((t) => t.sessionId.equals(sessionId)))
        .write(
      ChatSessionsTableCompanion(
        title: Value(title),
      ),
    );
  }

  @override
  Future<void> updateSessionSortOrders(
    Map<String, double> sortOrders,
  ) async {
    await _database.transaction(() async {
      for (final entry in sortOrders.entries) {
        await (_database.update(_database.chatSessionsTable)
              ..where((t) => t.sessionId.equals(entry.key)))
            .write(
          ChatSessionsTableCompanion(
            sortOrder: Value(entry.value),
          ),
        );
      }
    });
  }

  // ==================== 消息操作 ====================

  @override
  Future<ChatMessage> addMessage(ChatMessage message) async {
    await _insertMessageRow(message);
    return message;
  }

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async {
    final rows = await (_database.select(_database.chatMessagesTable)
          ..where((t) => t.sessionId.equals(sessionId))
          ..orderBy([(t) => OrderingTerm(expression: t.createdAt)]))
        .get();
    return rows.map(_messageFromRow).toList();
  }

  @override
  Future<int> getMessageCount(String sessionId) async {
    final row = await (_database.selectOnly(_database.chatMessagesTable)
          ..addColumns([_database.chatMessagesTable.messageId.count()])
          ..where(_database.chatMessagesTable.sessionId.equals(sessionId)))
        .getSingle();
    return row.read(_database.chatMessagesTable.messageId.count()) ?? 0;
  }

  @override
  Future<void> updateMessageContent(String messageId, String content) async {
    await (_database.update(_database.chatMessagesTable)
          ..where((t) => t.messageId.equals(messageId)))
        .write(
      ChatMessagesTableCompanion(
        content: Value(content),
      ),
    );
  }

  @override
  Future<void> appendContinuation(
    String messageId,
    String continuation, {
    int? tokensUsed,
  }) {
    // 续写段并入被续写消息——单条 SQL 原子拼接（免读改写
    // 竞态）并落「已中断·续写」标记
    // CH-7：续写 usage 一并写入 tokens_used；null 时
    // COALESCE 保留旧值（与内存态 copyWith 口径一致），重进会话后
    // 上下文用量显示不回退
    return _database.customStatement(
      'UPDATE chat_messages SET content = COALESCE(content, ?) || ?, '
      'is_continued = 1, tokens_used = COALESCE(?, tokens_used) '
      'WHERE message_id = ?',
      ['', continuation, tokensUsed, messageId],
    );
  }

  @override
  Future<int> updateMessageError(String messageId, String? error) async {
    return (_database.update(_database.chatMessagesTable)
          ..where((t) => t.messageId.equals(messageId)))
        .write(
      ChatMessagesTableCompanion(
        error: Value(error),
      ),
    );
  }

  @override
  Future<void> updateMessageTokensUsed(
    String messageId,
    int? tokensUsed,
  ) async {
    await (_database.update(_database.chatMessagesTable)
          ..where((t) => t.messageId.equals(messageId)))
        .write(
      ChatMessagesTableCompanion(
        tokensUsed: Value(tokensUsed),
      ),
    );
  }

  @override
  Future<void> deleteMessage(String messageId) async {
    await (_database.delete(_database.chatMessagesTable)
          ..where((t) => t.messageId.equals(messageId)))
        .go();
  }

  @override
  Future<void> deleteMessages(String sessionId) async {
    await _database.transaction(() async {
      // 删除所有消息
      await (_database.delete(_database.chatMessagesTable)
            ..where((t) => t.sessionId.equals(sessionId)))
          .go();
      // 删除所有分支记录（避免残留孤儿数据）
      await (_database.delete(_database.chatSessionBranchesTable)
            ..where((t) => t.sessionId.equals(sessionId)))
          .go();
      // 消息全删后压缩点必然失配，一并清空，
      // 不再依赖 filterByCompactionPoint 的失配兜底（脏数据累积）。
      await (_database.delete(_database.compactionPointsTable)
            ..where((t) => t.sessionId.equals(sessionId)))
          .go();
    });
  }

  // ==================== 分支操作 ====================
  //
  // 快照模型（对标 ChatBox messageForksHash）：
  // - chat_messages 表仅存储当前活跃分支的消息
  // - 非活跃分支的消息以 JSON 快照存储在 chat_session_branches.branch_snapshots
  // - 快照结构：[{"index": 0, "messages": [{...}, ...]}, ...]
  // - 切换分支 = 在 DB 与快照之间交换消息

  @override
  Future<void> deleteForkBranchesByAnchor(
    String sessionId,
    String anchorUserMsgId,
  ) async {
    await (_database.delete(_database.chatSessionBranchesTable)
          ..where(
            (t) =>
                t.sessionId.equals(sessionId) &
                t.anchorUserMsgId.equals(anchorUserMsgId),
          ))
        .go();
  }

  @override
  Future<List<ForkAnchor>> getForkAnchors(String sessionId) async {
    final rows = await (_database.select(_database.chatSessionBranchesTable)
          ..where(
            (t) =>
                t.sessionId.equals(sessionId) &
                t.branchCount.isBiggerThanValue(1),
          )
          ..orderBy([(t) => OrderingTerm(expression: t.createdAt)]))
        .get();
    return rows
        .map(
          (b) => ForkAnchor(
            parentUserMsgId: b.anchorUserMsgId,
            activeIndex: b.activeBranchIndex,
            branchCount: b.branchCount,
          ),
        )
        .toList();
  }

  @override
  Future<int> addAssistantBranchAndSnapshot({
    required String sessionId,
    required String anchorUserMsgId,
    required List<ChatMessage> tailMessages,
  }) async {
    return _database.transaction(() async {
      final existing =
          await (_database.select(_database.chatSessionBranchesTable)
                ..where(
                  (t) =>
                      t.sessionId.equals(sessionId) &
                      t.anchorUserMsgId.equals(anchorUserMsgId),
                ))
              .getSingleOrNull();

      if (existing == null) {
        // 首次创建锚点：当前活跃分支为 0，将尾部消息保存为分支 0 的快照
        final snapshots = _encodeSnapshots([
          _BranchSnapshot(index: 0, messages: tailMessages),
        ]);
        await _database.into(_database.chatSessionBranchesTable).insert(
              ChatSessionBranchesTableCompanion.insert(
                sessionId: sessionId,
                anchorUserMsgId: anchorUserMsgId,
                activeBranchIndex: const Value(1),
                branchCount: const Value(2),
                branchSnapshots: Value(snapshots),
                createdAt: Value(DateTime.now()),
              ),
            );
        // 删除尾部消息（新分支将由调用方生成并插入）
        await _deleteMessagesByIds(
          tailMessages.map((m) => m.messageId).toList(),
        );
        //  修复：尾部消息入快照后，引用它们的压缩点已失配
        await _pruneInvalidCompactionPoints(sessionId);
        return 1;
      }

      // 已存在锚点：保存当前活跃分支快照，branchCount+1
      final currentActive = existing.activeBranchIndex;
      final snapshots = _decodeSnapshots(existing.branchSnapshots)
        ..add(_BranchSnapshot(index: currentActive, messages: tailMessages));
      final newBranchIndex = existing.branchCount;
      await (_database.update(_database.chatSessionBranchesTable)
            ..where(
              (t) =>
                  t.sessionId.equals(sessionId) &
                  t.anchorUserMsgId.equals(anchorUserMsgId),
            ))
          .write(
        ChatSessionBranchesTableCompanion(
          branchCount: Value(existing.branchCount + 1),
          activeBranchIndex: Value(newBranchIndex),
          branchSnapshots: Value(_encodeSnapshots(snapshots)),
        ),
      );
      await _deleteMessagesByIds(tailMessages.map((m) => m.messageId).toList());
      //  修复：尾部消息入快照后，引用它们的压缩点已失配
      await _pruneInvalidCompactionPoints(sessionId);
      return newBranchIndex;
    });
  }

  @override
  Future<List<ChatMessage>> switchForkBranchWithSnapshot({
    required String sessionId,
    required String anchorUserMsgId,
    required int newActiveIndex,
    required List<ChatMessage> currentTailMessages,
  }) async {
    return _database.transaction(() async {
      final anchor = await (_database.select(_database.chatSessionBranchesTable)
            ..where(
              (t) =>
                  t.sessionId.equals(sessionId) &
                  t.anchorUserMsgId.equals(anchorUserMsgId),
            ))
          .getSingleOrNull();
      if (anchor == null) {
        throw StateError(
          'switchForkBranchWithSnapshot: anchor not found for '
          'session=$sessionId, anchor=$anchorUserMsgId',
        );
      }

      final currentActive = anchor.activeBranchIndex;

      // 1. 保存当前活跃分支的尾部消息为快照
      final snapshots = _decodeSnapshots(anchor.branchSnapshots)
        ..add(
          _BranchSnapshot(index: currentActive, messages: currentTailMessages),
        );

      // 2. 从快照中加载目标分支的消息
      final targetSnapshotIndex =
          snapshots.indexWhere((s) => s.index == newActiveIndex);
      if (targetSnapshotIndex < 0) {
        throw StateError(
          'switchForkBranchWithSnapshot: branch $newActiveIndex snapshot '
          'not found',
        );
      }
      final newMessages = snapshots[targetSnapshotIndex].messages;
      snapshots.removeAt(targetSnapshotIndex);

      // 3. 删除当前尾部消息，插入新分支消息
      await _deleteMessagesByIds(
        currentTailMessages.map((m) => m.messageId).toList(),
      );
      for (final msg in newMessages) {
        await _insertMessageRow(msg);
      }

      // 4. 更新锚点
      await (_database.update(_database.chatSessionBranchesTable)
            ..where(
              (t) =>
                  t.sessionId.equals(sessionId) &
                  t.anchorUserMsgId.equals(anchorUserMsgId),
            ))
          .write(
        ChatSessionBranchesTableCompanion(
          activeBranchIndex: Value(newActiveIndex),
          branchSnapshots: Value(_encodeSnapshots(snapshots)),
        ),
      );

      // 5.  修复：切换后校验压缩点归属（见 _pruneInvalidCompactionPoints）
      await _pruneInvalidCompactionPoints(sessionId);

      return newMessages;
    });
  }

  @override
  Future<List<ChatMessage>?> removeForkBranchWithSnapshot({
    required String sessionId,
    required String anchorUserMsgId,
    required int removedBranchIndex,
    required List<ChatMessage> currentTailMessages,
  }) async {
    return _database.transaction(() async {
      final anchor = await (_database.select(_database.chatSessionBranchesTable)
            ..where(
              (t) =>
                  t.sessionId.equals(sessionId) &
                  t.anchorUserMsgId.equals(anchorUserMsgId),
            ))
          .getSingleOrNull();
      if (anchor == null) return null;
      final newCount = anchor.branchCount - 1;
      final snapshots = _decodeSnapshots(anchor.branchSnapshots);
      final isRemovingActive = removedBranchIndex == anchor.activeBranchIndex;

      List<ChatMessage>? switchedMessages;

      if (isRemovingActive) {
        // 删除活跃分支：需要切换到另一个分支
        if (snapshots.isEmpty) {
          // 没有其他快照可切换，直接删除当前消息
          await _deleteMessagesByIds(
            currentTailMessages.map((m) => m.messageId).toList(),
          );
          //  修复：活跃消息集变更，清理失配压缩点
          await _pruneInvalidCompactionPoints(sessionId);
        } else {
          // 选择第一个可用快照作为新活跃分支
          final target = snapshots.removeAt(0);
          await _deleteMessagesByIds(
            currentTailMessages.map((m) => m.messageId).toList(),
          );
          for (final msg in target.messages) {
            await _insertMessageRow(msg);
          }
          switchedMessages = target.messages;
          //  修复：活跃消息集变更，清理失配压缩点
          await _pruneInvalidCompactionPoints(sessionId);
        }
      } else {
        // 删除非活跃分支：仅从快照中移除
        final idx = snapshots.indexWhere((s) => s.index == removedBranchIndex);
        if (idx >= 0) {
          snapshots.removeAt(idx);
        }
      }

      if (newCount <= 1) {
        // 分支数降为 1，删除锚点记录
        await (_database.delete(_database.chatSessionBranchesTable)
              ..where(
                (t) =>
                    t.sessionId.equals(sessionId) &
                    t.anchorUserMsgId.equals(anchorUserMsgId),
              ))
            .go();
      } else {
        // 计算新的 activeBranchIndex
        var newActive = anchor.activeBranchIndex;
        if (isRemovingActive) {
          // 切换到了快照中的第一个分支，需要找到它的原始索引
          newActive = switchedMessages != null
              ? snapshots.isEmpty
                  ? newCount - 1
                  : _findAvailableBranchIndex(
                      snapshots,
                      removedBranchIndex,
                      newCount,
                    )
              : newCount - 1;
        } else if (removedBranchIndex < anchor.activeBranchIndex) {
          newActive = anchor.activeBranchIndex - 1;
        }

        // 重新整理快照索引（确保连续）
        final reindexedSnapshots =
            _reindexSnapshots(snapshots, removedBranchIndex);

        await (_database.update(_database.chatSessionBranchesTable)
              ..where(
                (t) =>
                    t.sessionId.equals(sessionId) &
                    t.anchorUserMsgId.equals(anchorUserMsgId),
              ))
            .write(
          ChatSessionBranchesTableCompanion(
            branchCount: Value(newCount),
            activeBranchIndex: Value(newActive),
            branchSnapshots: Value(_encodeSnapshots(reindexedSnapshots)),
          ),
        );
      }

      return switchedMessages;
    });
  }

  @override
  Future<bool> appendMessageToBranchSnapshot({
    required String sessionId,
    required String anchorUserMsgId,
    required int branchIndex,
    required ChatMessage message,
  }) async {
    return _database.transaction(() async {
      final anchor = await (_database.select(_database.chatSessionBranchesTable)
            ..where(
              (t) =>
                  t.sessionId.equals(sessionId) &
                  t.anchorUserMsgId.equals(anchorUserMsgId),
            ))
          .getSingleOrNull();
      // 锚点不存在 / 该分支即当前活跃分支（表内）/ 目标快照缺失：
      // 无法安全追加，调用方回退 addMessage 保数据
      if (anchor == null || anchor.activeBranchIndex == branchIndex) {
        return false;
      }
      final snapshots = _decodeSnapshots(anchor.branchSnapshots);
      final idx = snapshots.indexWhere((s) => s.index == branchIndex);
      if (idx < 0) return false;

      final target = snapshots[idx];
      snapshots[idx] = _BranchSnapshot(
        index: target.index,
        messages: [...target.messages, message],
      );
      await (_database.update(_database.chatSessionBranchesTable)
            ..where(
              (t) =>
                  t.sessionId.equals(sessionId) &
                  t.anchorUserMsgId.equals(anchorUserMsgId),
            ))
          .write(
        ChatSessionBranchesTableCompanion(
          branchSnapshots: Value(_encodeSnapshots(snapshots)),
        ),
      );
      return true;
    });
  }

  @override
  Future<bool> appendContinuationToBranchSnapshot({
    required String sessionId,
    required String anchorUserMsgId,
    required int branchIndex,
    required String messageId,
    required String continuation,
    int? tokensUsed,
  }) {
    // CH-5：续写在后台分支完成的接写合并——被续写的半截
    // 消息随生成分支存在快照中（活跃表无此行），在快照内按 messageId
    // 定位并合并，保持  单气泡语义
    return _database.transaction(() async {
      final anchor = await (_database.select(_database.chatSessionBranchesTable)
            ..where(
              (t) =>
                  t.sessionId.equals(sessionId) &
                  t.anchorUserMsgId.equals(anchorUserMsgId),
            ))
          .getSingleOrNull();
      // 锚点不存在 / 该分支即当前活跃分支（消息应在活跃表，走普通
      // appendContinuation）/ 目标快照缺失：无法安全合并
      if (anchor == null || anchor.activeBranchIndex == branchIndex) {
        return false;
      }
      final snapshots = _decodeSnapshots(anchor.branchSnapshots);
      final idx = snapshots.indexWhere((s) => s.index == branchIndex);
      if (idx < 0) return false;

      final snapshot = snapshots[idx];
      final msgIdx = snapshot.messages.lastIndexWhere(
        (m) => m.messageId == messageId,
      );
      if (msgIdx < 0) return false;

      final target = snapshot.messages[msgIdx];
      snapshot.messages[msgIdx] = target.copyWith(
        content: (target.content ?? '') + continuation,
        isContinued: true,
        tokensUsed: tokensUsed ?? target.tokensUsed,
      );
      snapshots[idx] = _BranchSnapshot(
        index: snapshot.index,
        messages: snapshot.messages,
      );
      await (_database.update(_database.chatSessionBranchesTable)
            ..where(
              (t) =>
                  t.sessionId.equals(sessionId) &
                  t.anchorUserMsgId.equals(anchorUserMsgId),
            ))
          .write(
        ChatSessionBranchesTableCompanion(
          branchSnapshots: Value(_encodeSnapshots(snapshots)),
        ),
      );
      return true;
    });
  }

  /// 查找可用分支索引（当删除活跃分支后）
  int _findAvailableBranchIndex(
    List<_BranchSnapshot> snapshots,
    int removedIndex,
    int newCount,
  ) {
    // 优先使用快照中已存在的最小索引
    if (snapshots.isNotEmpty) {
      final indices = snapshots.map((s) => s.index).toList()..sort();
      return indices.first;
    }
    return newCount - 1;
  }

  /// 重新整理快照索引（删除分支后，索引大于 removedIndex 的减 1）
  List<_BranchSnapshot> _reindexSnapshots(
    List<_BranchSnapshot> snapshots,
    int removedIndex,
  ) {
    return snapshots
        .map(
          (s) => _BranchSnapshot(
            index: s.index > removedIndex ? s.index - 1 : s.index,
            messages: s.messages,
          ),
        )
        .toList();
  }

  // ==================== 快照 JSON 编解码 ====================

  /// 将快照列表编码为 JSON 字符串
  String _encodeSnapshots(List<_BranchSnapshot> snapshots) {
    if (snapshots.isEmpty) return '[]';
    return jsonEncode(snapshots.map((s) => s.toJson()).toList());
  }

  /// 从 JSON 字符串解码快照列表
  List<_BranchSnapshot> _decodeSnapshots(String? jsonStr) {
    if (jsonStr == null || jsonStr.isEmpty) return [];
    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      return list
          .map((e) => _BranchSnapshot.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// 消息 id 引用重映射（CH-3a）：id 在映射表内返回副本新 id，否则 null。
  ///
  /// copySession 用：可空引用（parentUserMsgId）未命中时由调用方保留原值；
  /// 必须可解析的引用（压缩点两侧/分支锚点）未命中时调用方跳过该行。
  String? _mappedMessageId(String? id, Map<String, String> map) =>
      id == null ? null : map[id];

  /// 删除指定 ID 的消息
  Future<void> _deleteMessagesByIds(List<String> messageIds) async {
    if (messageIds.isEmpty) return;
    await (_database.delete(_database.chatMessagesTable)
          ..where((t) => t.messageId.isIn(messageIds)))
        .go();
  }

  /// 插入消息行（内部辅助）
  Future<void> _insertMessageRow(ChatMessage message) async {
    await _database.into(_database.chatMessagesTable).insert(
          ChatMessagesTableCompanion.insert(
            messageId: message.messageId,
            sessionId: message.sessionId,
            role: message.role,
            content: Value(message.content),
            toolCalls: Value(message.toolCalls),
            toolCallId: Value(message.toolCallId),
            thinkingContent: Value(message.thinkingContent),
            thinkingDuration: Value(message.thinkingDuration),
            reasoningContent: Value(message.reasoningContent),
            parentUserMsgId: Value(message.parentUserMsgId),
            branchIndex: Value(message.branchIndex),
            isSummary: Value(message.isSummary),
            isContinued: Value(message.isContinued),
            attachments: Value(
              message.attachments != null && message.attachments!.isNotEmpty
                  ? MessageAttachment.listToJson(message.attachments!)
                  : null,
            ),
            error: Value(message.error),
            tokensUsed: Value(message.tokensUsed),
            firstTokenLatency: Value(message.firstTokenLatency),
            modelName: Value(message.modelName),
            createdAt: Value(message.createdAt),
          ),
        );
  }

  // ==================== 压缩点操作 ====================

  @override
  Future<void> addCompactionPoint({
    required String sessionId,
    required String summaryMessageId,
    required String boundaryMessageId,
    required DateTime createdAt,
  }) async {
    await _database.into(_database.compactionPointsTable).insert(
          CompactionPointsTableCompanion.insert(
            sessionId: sessionId,
            summaryMessageId: summaryMessageId,
            boundaryMessageId: boundaryMessageId,
            createdAt: Value(createdAt),
          ),
        );
  }

  @override
  Future<List<Map<String, dynamic>>> getCompactionPoints(
    String sessionId,
  ) async {
    final rows = await (_database.select(_database.compactionPointsTable)
          ..where((t) => t.sessionId.equals(sessionId))
          ..orderBy([(t) => OrderingTerm(expression: t.createdAt)]))
        .get();

    return rows
        .map(
          (row) => {
            'id': row.id,
            'sessionId': row.sessionId,
            'summaryMessageId': row.summaryMessageId,
            'boundaryMessageId': row.boundaryMessageId,
            'createdAt': row.createdAt,
          },
        )
        .toList();
  }

  @override
  Future<void> deleteCompactionPoint(
    String sessionId,
    DateTime createdAt,
  ) async {
    await (_database.delete(_database.compactionPointsTable)
          ..where(
            (t) =>
                t.sessionId.equals(sessionId) & t.createdAt.equals(createdAt),
          ))
        .go();
  }

  @override
  Future<void> deleteCompactionPointBySummaryId(
    String sessionId,
    String summaryMessageId,
  ) async {
    await (_database.delete(_database.compactionPointsTable)
          ..where(
            (t) =>
                t.sessionId.equals(sessionId) &
                t.summaryMessageId.equals(summaryMessageId),
          ))
        .go();
  }

  /// 清理引用了非活跃消息的压缩点（修复，2026-08-23）
  ///
  /// 压缩点是会话级记录，而分支切换/重建会把摘要或边界消息收进快照
  /// （从 chat_messages 移除）。失配的压缩点若保留：
  /// - boundary 失配 → getCompressedMessages 静默回退全量上下文（超窗 400）
  /// - summary 失配 → 界面渲染 ChatMessage.summaryUnavailableContent 哨兵占位（本地化映射）
  ///
  /// 必须在与消息集变更相同的事务内调用。切回原分支后压缩点不恢复，
  /// 由自动压缩按新上下文重新触发（可接受的语义：压缩随分支走）。
  Future<void> _pruneInvalidCompactionPoints(String sessionId) async {
    final activeMessages = await (_database.select(_database.chatMessagesTable)
          ..where((t) => t.sessionId.equals(sessionId)))
        .get();
    final activeIds = activeMessages.map((m) => m.messageId).toSet();
    final points = await getCompactionPoints(sessionId);
    for (final point in points) {
      final boundaryOk = activeIds.contains(point['boundaryMessageId']);
      final summaryOk = activeIds.contains(point['summaryMessageId']);
      if (!boundaryOk || !summaryOk) {
        await deleteCompactionPointBySummaryId(
          sessionId,
          point['summaryMessageId'] as String,
        );
      }
    }
  }

  @override
  Future<void> pruneInvalidCompactionPoints(String sessionId) =>
      _pruneInvalidCompactionPoints(sessionId);

  // ==================== 搜索操作 ====================

  @override
  Future<List<SearchResult>> searchMessages(String query) async {
    // 转义 LIKE 通配符（\ % _），防止用户输入被当作通配符
    final escapedLike = query
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
    final pattern = '%$escapedLike%';

    final rows = await _database.customSelect(
      'SELECT cm.message_id, cm.session_id, cm.content, cm.role, '
      'cm.created_at, cs.title AS session_name '
      'FROM chat_messages cm '
      'INNER JOIN chat_sessions cs ON cm.session_id = cs.session_id '
      'WHERE cm.content IS NOT NULL '
      r"AND cm.content LIKE ? ESCAPE '\' "
      'AND cm.is_summary = 0 '
      'ORDER BY cm.created_at DESC '
      'LIMIT ${ChatRepository.globalSearchLimit}',
      variables: [Variable.withString(pattern)],
    ).get();

    return rows
        .map(
          (row) => SearchResult(
            sessionId: row.read<String>('session_id'),
            sessionName: row.read<String>('session_name'),
            messageId: row.read<String>('message_id'),
            content: row.read<String>('content'),
            role: row.read<String>('role'),
            createdAt: row.read<DateTime>('created_at'),
          ),
        )
        .toList();
  }

  @override
  Future<List<SearchResult>> searchMessagesInSession(
    String sessionId,
    String query,
  ) async {
    // 同 searchMessages 的转义口径；无 JOIN（会话名已知），LIMIT 提升
    // 到 200（单会话命中面窄）
    // DESC 取最近 200 后 Dart 侧翻回
    // 升序——原 ASC 直接截最旧 200，单会话命中 >200 时最新命中不可达，
    // 且与全局搜索的 DESC 方向不一致。
    final escapedLike = query
        .replaceAll(r'\', r'\\')
        .replaceAll('%', r'\%')
        .replaceAll('_', r'\_');
    final pattern = '%$escapedLike%';

    final rows = await _database.customSelect(
      'SELECT message_id, session_id, content, role, created_at '
      'FROM chat_messages '
      'WHERE session_id = ? '
      'AND content IS NOT NULL '
      r"AND content LIKE ? ESCAPE '\' "
      'AND is_summary = 0 '
      'ORDER BY created_at DESC '
      'LIMIT ${ChatRepository.inSessionSearchLimit}',
      variables: [Variable.withString(sessionId), Variable.withString(pattern)],
    ).get();

    return rows
        .map(
          (row) => SearchResult(
            sessionId: row.read<String>('session_id'),
            sessionName: '',
            messageId: row.read<String>('message_id'),
            content: row.read<String>('content'),
            role: row.read<String>('role'),
            createdAt: row.read<DateTime>('created_at'),
          ),
        )
        .toList()
        .reversed
        .toList();
  }

  // ==================== 数据管理操作 ====================

  @override
  Future<List<List<ChatMessage>>> scanOrphanMessages() async {
    // 1. 获取所有有效的 sessionIds
    final validSessions =
        await _database.select(_database.chatSessionsTable).get();
    final validIds = validSessions.map((s) => s.sessionId).toSet();

    // 2. 获取所有消息，按 sessionId 和 createdAt 排序
    final allMessages = await (_database.select(_database.chatMessagesTable)
          ..orderBy([
            (t) => OrderingTerm(expression: t.sessionId),
            (t) => OrderingTerm(expression: t.createdAt),
          ]))
        .get();

    // 3. 过滤孤立消息并按 sessionId 分组
    final groups = <String, List<ChatMessage>>{};
    for (final row in allMessages) {
      if (!validIds.contains(row.sessionId)) {
        final message = _messageFromRow(row);
        groups.putIfAbsent(message.sessionId, () => []).add(message);
      }
    }

    return groups.values.toList();
  }

  @override
  Future<int> getTotalMessageCount() async {
    final row = await (_database.selectOnly(_database.chatMessagesTable)
          ..addColumns([_database.chatMessagesTable.messageId.count()]))
        .getSingle();
    return row.read(_database.chatMessagesTable.messageId.count()) ?? 0;
  }

  // ==================== 私有辅助方法 ====================

  ChatSession _sessionFromRow(ChatSessionsTableData row) {
    return ChatSession(
      sessionId: row.sessionId,
      title: row.title,
      mode: row.mode,
      createdAt: row.createdAt,
      lastActiveAt: row.lastActiveAt,
      messageCount: row.messageCount,
      modelId: row.modelId,
      presetId: row.presetId,
      systemPromptOverride: row.systemPromptOverride,
      temperature: row.temperature,
      topP: row.topP,
      maxTokens: row.maxTokens,
      autoCompaction: row.autoCompaction,
      compactionThreshold: row.compactionThreshold,
      streamEnabled: row.streamEnabled,
      maxContextMessages: row.maxContextMessages,
      effectiveContextLimit: row.effectiveContextLimit,
      reasoningEffort: ReasoningEffort.fromString(row.reasoningEffort),
      jsonModeOverride: row.jsonModeOverride,
      // schemaVersion ≥ 23：会话级分步骤模型配置（8 列）
      phaseModels: SessionPhaseModels(
        generatingPresetId: row.generatingPresetId,
        generatingModelId: row.generatingModelId,
        extractingPresetId: row.extractingPresetId,
        extractingModelId: row.extractingModelId,
        reviewingPresetId: row.reviewingPresetId,
        reviewingModelId: row.reviewingModelId,
        summarizingPresetId: row.summarizingPresetId,
        summarizingModelId: row.summarizingModelId,
      ),
      isStarred: row.isStarred,
      sortOrder: row.sortOrder,
      currentNarrativeTime: row.currentNarrativeTime,
      suggestReplyPresetId: row.suggestReplyPresetId,
      suggestReplyModelId: row.suggestReplyModelId,
      suggestReplyPromptOverride: row.suggestReplyPromptOverride,
      // schemaVersion ≥ 31：终稿审查会话级覆盖
      reviewEnabledOverride: row.reviewEnabledOverride,
      // 审查  修复：contextBudget 会话级覆盖
      recentMinRatioOverride: row.recentMinRatioOverride,
      retrievalRatioOverride: row.retrievalRatioOverride,
      maxSteps: row.maxSteps,
      // schemaVersion ≥ 42：剧情锚 JSON（体验重构卡片 C）
      storyAnchor: StoryAnchor.parse(row.storyAnchor),
      watchMode: row.watchMode,
      // schemaVersion ≥ 44：导演工具权限 + 单轮时间预算会话覆盖
      toolPermissions: row.toolPermissions,
      maxDurationMinutes: row.maxDurationMinutes,
      // schemaVersion ≥ 46：剧情节奏档会话覆盖
      narrativePacing: row.narrativePacing,
      // schemaVersion ≥ 47： turn 单一事实源计数器
      nextTurn: row.nextTurn,
      // 检索松紧度快照 JSON
      retrievalOverrides: row.retrievalOverrides,
      // 向导「初始化你的角色」两列
      characterInitPrompt: row.characterInitPrompt,
      characterInitCardId: row.characterInitCardId,
    );
  }

  ChatMessage _messageFromRow(ChatMessagesTableData row) {
    return ChatMessage(
      messageId: row.messageId,
      sessionId: row.sessionId,
      role: row.role,
      content: row.content,
      toolCalls: row.toolCalls,
      toolCallId: row.toolCallId,
      thinkingContent: row.thinkingContent,
      thinkingDuration: row.thinkingDuration,
      reasoningContent: row.reasoningContent,
      parentUserMsgId: row.parentUserMsgId,
      branchIndex: row.branchIndex,
      isSummary: row.isSummary,
      isContinued: row.isContinued,
      attachments: MessageAttachment.listFromJson(row.attachments),
      error: row.error,
      tokensUsed: row.tokensUsed,
      firstTokenLatency: row.firstTokenLatency,
      modelName: row.modelName,
      createdAt: row.createdAt,
    );
  }
}

/// 分支快照（内部使用）
///
/// 存储非活跃分支的消息列表，序列化为 JSON 存储在 branch_snapshots 列。
class _BranchSnapshot {
  const _BranchSnapshot({
    required this.index,
    required this.messages,
  });
  factory _BranchSnapshot.fromJson(Map<String, dynamic> json) {
    final list = json['messages'] as List<dynamic>;
    return _BranchSnapshot(
      index: json['index'] as int,
      messages: list
          .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// 分支索引
  final int index;

  /// 该分支的消息列表（按时间顺序）
  final List<ChatMessage> messages;

  Map<String, dynamic> toJson() {
    return {
      'index': index,
      'messages': messages.map((m) => m.toJson()).toList(),
    };
  }
}
