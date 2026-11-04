import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/entities/tool_permissions.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';

void main() {
  late AppDatabase db;

  setUp(() async {
    final nativeDb = NativeDatabase.memory();
    db = AppDatabase.forTesting(nativeDb);
    await db.customSelect('SELECT 1').get();
  });

  tearDown(() async {
    await db.close();
  });

  group('Schema 验证', () {
    test('6 张表全部创建', () async {
      final tables = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'drift_%'",
          )
          .get();

      final tableNames = tables.map((r) => r.read<String>('name')).toSet();
      expect(
        tableNames,
        containsAll([
          'chat_sessions',
          'chat_messages',
          'chat_session_branches',
          'compaction_points',
          'api_presets',
          'templates',
        ]),
      );
    });

    test('chat_sessions 表结构匹配 DOC-02', () async {
      final columns = await db
          .customSelect(
            'PRAGMA table_info(chat_sessions)',
          )
          .get();

      final colMap = <String, String>{};
      for (final c in columns) {
        colMap[c.read<String>('name')] = c.read<String>('type');
      }

      expect(colMap, containsPair('id', 'INTEGER'));
      expect(colMap, containsPair('session_id', 'TEXT'));
      expect(colMap, containsPair('title', 'TEXT'));
      expect(colMap, containsPair('mode', 'TEXT'));
      expect(colMap, contains('created_at'));
      expect(colMap, contains('last_active_at'));
      expect(colMap, containsPair('message_count', 'INTEGER'));
      expect(colMap, containsPair('model_id', 'TEXT'));
      expect(colMap, containsPair('preset_id', 'TEXT'));
      expect(colMap, containsPair('system_prompt_override', 'TEXT'));
      expect(colMap, containsPair('temperature', 'REAL'));
      expect(colMap, containsPair('top_p', 'REAL'));
      expect(colMap, containsPair('max_tokens', 'INTEGER'));
      expect(colMap, contains('auto_compaction'));
      expect(colMap, containsPair('compaction_threshold', 'REAL'));
      expect(colMap, contains('stream_enabled'));
    });

    test('chat_messages 表结构匹配 DOC-02', () async {
      final columns = await db
          .customSelect(
            'PRAGMA table_info(chat_messages)',
          )
          .get();

      final colMap = <String, String>{};
      for (final c in columns) {
        colMap[c.read<String>('name')] = c.read<String>('type');
      }

      expect(colMap, containsPair('id', 'INTEGER'));
      expect(colMap, containsPair('message_id', 'TEXT'));
      expect(colMap, containsPair('session_id', 'TEXT'));
      expect(colMap, containsPair('role', 'TEXT'));
      expect(colMap, containsPair('content', 'TEXT'));
      expect(colMap, containsPair('tool_calls', 'TEXT'));
      expect(colMap, containsPair('tool_call_id', 'TEXT'));
      expect(colMap, containsPair('parent_user_msg_id', 'TEXT'));
      expect(colMap, containsPair('branch_index', 'INTEGER'));
      expect(colMap, contains('is_summary'));
      expect(colMap, contains('created_at'));
    });

    test('chat_session_branches 表结构匹配 DOC-02（快照模型）', () async {
      final columns = await db
          .customSelect(
            'PRAGMA table_info(chat_session_branches)',
          )
          .get();

      final colMap = <String, String>{};
      for (final c in columns) {
        colMap[c.read<String>('name')] = c.read<String>('type');
      }

      expect(colMap, containsPair('id', 'INTEGER'));
      expect(colMap, containsPair('session_id', 'TEXT'));
      expect(colMap, containsPair('anchor_user_msg_id', 'TEXT'));
      expect(colMap, containsPair('active_branch_index', 'INTEGER'));
      expect(colMap, containsPair('branch_count', 'INTEGER'));
      // v12: 新增 branch_snapshots 列（快照模型）
      expect(colMap, containsPair('branch_snapshots', 'TEXT'));
      expect(colMap, contains('created_at'));
    });

    test('compaction_points 表结构匹配 DOC-02', () async {
      final columns = await db
          .customSelect(
            'PRAGMA table_info(compaction_points)',
          )
          .get();

      final colMap = <String, String>{};
      for (final c in columns) {
        colMap[c.read<String>('name')] = c.read<String>('type');
      }

      expect(colMap, containsPair('id', 'INTEGER'));
      expect(colMap, containsPair('session_id', 'TEXT'));
      expect(colMap, containsPair('summary_message_id', 'TEXT'));
      expect(colMap, containsPair('boundary_message_id', 'TEXT'));
      expect(colMap, contains('created_at'));
    });

    test('api_presets 表结构匹配 DOC-05', () async {
      final columns =
          await db.customSelect('PRAGMA table_info(api_presets)').get();
      final colMap = <String, String>{};
      for (final c in columns) {
        colMap[c.read<String>('name')] = c.read<String>('type');
      }
      expect(colMap, containsPair('id', 'INTEGER'));
      expect(colMap, containsPair('preset_id', 'TEXT'));
      expect(colMap, containsPair('name', 'TEXT'));
      expect(colMap, containsPair('base_url', 'TEXT'));
      expect(colMap, contains('is_built_in'));
      expect(colMap, containsPair('cached_models', 'TEXT'));
      expect(colMap, contains('created_at'));
      expect(colMap, contains('updated_at'));
    });

    test('templates 表结构匹配 DOC-05', () async {
      final columns =
          await db.customSelect('PRAGMA table_info(templates)').get();
      final colMap = <String, String>{};
      for (final c in columns) {
        colMap[c.read<String>('name')] = c.read<String>('type');
      }
      expect(colMap, containsPair('id', 'INTEGER'));
      expect(colMap, containsPair('template_id', 'TEXT'));
      expect(colMap, containsPair('name', 'TEXT'));
      expect(colMap, containsPair('kind', 'TEXT'));
      expect(colMap, containsPair('content', 'TEXT'));
      expect(colMap, contains('is_built_in'));
      expect(colMap, contains('created_at'));
      expect(colMap, contains('updated_at'));
    });
  });

  group('索引验证', () {
    test('13 个索引全部创建（对齐 DOC-02 Section 6.4 + branches 索引 + 新表索引）', () async {
      final indexes = await db
          .customSelect(
            'SELECT name, tbl_name FROM sqlite_master '
            '''WHERE type='index' AND name NOT LIKE 'sqlite_%\'''',
          )
          .get();

      final indexNames = indexes.map((r) => r.read<String>('name')).toSet();

      expect(
        indexNames,
        containsAll([
          'idx_msg_session_created',
          'idx_msg_session_branch',
          'idx_msg_session_summary',
          'idx_msg_message_id',
          'idx_cp_session_created',
          'idx_cp_summary_msg',
          'idx_cp_boundary_msg',
          'idx_csb_session_anchor',
          'idx_ap_presets_id',
          'idx_ap_built_in',
          'idx_tmpl_template_id',
          'idx_tmpl_kind',
          'idx_tmpl_built_in',
        ]),
      );
    });

    test('message_id 唯一索引生效', () async {
      final indexInfo = await db
          .customSelect(
            'PRAGMA index_info(idx_msg_message_id)',
          )
          .get();

      expect(indexInfo, isNotEmpty);
      expect(indexInfo.first.read<String>('name'), 'message_id');
    });

    test('idx_msg_session_branch 包含 parent_user_msg_id', () async {
      final indexInfo = await db
          .customSelect(
            'PRAGMA index_info(idx_msg_session_branch)',
          )
          .get();

      final columns = indexInfo.map((r) => r.read<String>('name')).toList();
      expect(columns, contains('parent_user_msg_id'));
    });

    test('idx_msg_session_summary 包含 is_summary', () async {
      final indexInfo = await db
          .customSelect(
            'PRAGMA index_info(idx_msg_session_summary)',
          )
          .get();

      final columns = indexInfo.map((r) => r.read<String>('name')).toList();
      expect(columns, contains('is_summary'));
    });

    test('idx_cp_summary_msg 索引生效', () async {
      final indexInfo = await db
          .customSelect(
            'PRAGMA index_info(idx_cp_summary_msg)',
          )
          .get();

      expect(indexInfo, isNotEmpty);
      expect(indexInfo.first.read<String>('name'), 'summary_message_id');
    });

    test('idx_csb_session_anchor 索引生效', () async {
      final indexInfo = await db
          .customSelect(
            'PRAGMA index_info(idx_csb_session_anchor)',
          )
          .get();

      final columns = indexInfo.map((r) => r.read<String>('name')).toList();
      expect(columns, containsAll(['session_id', 'anchor_user_msg_id']));
    });

    test('idx_ap_presets_id 唯一索引生效', () async {
      final indexInfo =
          await db.customSelect('PRAGMA index_info(idx_ap_presets_id)').get();
      expect(indexInfo, isNotEmpty);
      expect(indexInfo.first.read<String>('name'), 'preset_id');
    });

    test('idx_tmpl_template_id 唯一索引生效', () async {
      final indexInfo = await db
          .customSelect('PRAGMA index_info(idx_tmpl_template_id)')
          .get();
      expect(indexInfo, isNotEmpty);
      expect(indexInfo.first.read<String>('name'), 'template_id');
    });

    test('idx_tmpl_kind 索引生效', () async {
      final indexInfo =
          await db.customSelect('PRAGMA index_info(idx_tmpl_kind)').get();
      expect(indexInfo, isNotEmpty);
      expect(indexInfo.first.read<String>('name'), 'kind');
    });
  });

  group('默认值验证', () {
    test('message_id 插入后可读取', () async {
      await db.into(db.chatSessionsTable).insert(
            ChatSessionsTableCompanion.insert(
              sessionId: 'test-session',
              title: 'Test',
            ),
          );

      const messageId = 'msg-001';
      await db.into(db.chatMessagesTable).insert(
            ChatMessagesTableCompanion.insert(
              messageId: messageId,
              sessionId: 'test-session',
              role: 'user',
              content: const Value('Hello'),
            ),
          );

      final messages = await db.select(db.chatMessagesTable).get();
      expect(messages, hasLength(1));
      expect(messages.first.messageId, messageId);
    });

    test('branch_index 默认值为 0', () async {
      await db.into(db.chatSessionsTable).insert(
            ChatSessionsTableCompanion.insert(
              sessionId: 'test-session',
              title: 'Test',
            ),
          );

      await db.into(db.chatMessagesTable).insert(
            ChatMessagesTableCompanion.insert(
              messageId: 'msg-1',
              sessionId: 'test-session',
              role: 'user',
              content: const Value('Hello'),
            ),
          );

      final messages = await db.select(db.chatMessagesTable).get();
      expect(messages.first.branchIndex, 0);
    });

    test('is_summary 默认值为 false', () async {
      await db.into(db.chatSessionsTable).insert(
            ChatSessionsTableCompanion.insert(
              sessionId: 'test-session',
              title: 'Test',
            ),
          );

      await db.into(db.chatMessagesTable).insert(
            ChatMessagesTableCompanion.insert(
              messageId: 'msg-1',
              sessionId: 'test-session',
              role: 'user',
              content: const Value('Hello'),
            ),
          );

      final messages = await db.select(db.chatMessagesTable).get();
      expect(messages.first.isSummary, false);
    });

    test('mode 默认值为 chat', () async {
      await db.into(db.chatSessionsTable).insert(
            ChatSessionsTableCompanion.insert(
              sessionId: 'test-session',
              title: 'Test',
            ),
          );

      final sessions = await db.select(db.chatSessionsTable).get();
      expect(sessions.first.mode, 'chat');
    });

    test('message_count 默认值为 0', () async {
      await db.into(db.chatSessionsTable).insert(
            ChatSessionsTableCompanion.insert(
              sessionId: 'test-session',
              title: 'Test',
            ),
          );

      final sessions = await db.select(db.chatSessionsTable).get();
      expect(sessions.first.messageCount, 0);
    });

    test('api_presets isBuiltIn 默认值为 false', () async {
      await db.into(db.apiPresetsTable).insert(
            ApiPresetsTableCompanion.insert(
              presetId: 'test-preset',
              name: 'Test',
              baseUrl: const Value('https://api.test.com'),
            ),
          );
      final presets = await db.select(db.apiPresetsTable).get();
      expect(presets.first.isBuiltIn, false);
    });

    test('templates isBuiltIn 默认值为 false', () async {
      await db.into(db.templatesTable).insert(
            TemplatesTableCompanion.insert(
              templateId: 'test-template',
              name: 'Test',
              kind: 'systemPrompt',
              content: 'content',
            ),
          );
      final templates = await db.select(db.templatesTable).get();
      expect(templates.first.isBuiltIn, false);
    });
  });

  group('CRUD 验证', () {
    test('4 张表可 CRUD', () async {
      await db.into(db.chatSessionsTable).insert(
            ChatSessionsTableCompanion.insert(
              sessionId: 'sess-1',
              title: 'Session 1',
            ),
          );

      var sessions = await db.select(db.chatSessionsTable).get();
      expect(sessions, hasLength(1));
      expect(sessions.first.title, 'Session 1');

      await db.into(db.chatMessagesTable).insert(
            ChatMessagesTableCompanion.insert(
              messageId: 'msg-1',
              sessionId: 'sess-1',
              role: 'user',
              content: const Value('Hello'),
            ),
          );

      final messages = await db.select(db.chatMessagesTable).get();
      expect(messages, hasLength(1));

      await db.into(db.chatSessionBranchesTable).insert(
            ChatSessionBranchesTableCompanion.insert(
              sessionId: 'sess-1',
              anchorUserMsgId: 'msg-1',
            ),
          );

      final branches = await db.select(db.chatSessionBranchesTable).get();
      expect(branches, hasLength(1));

      await db.into(db.compactionPointsTable).insert(
            CompactionPointsTableCompanion.insert(
              sessionId: 'sess-1',
              summaryMessageId: 'msg-summary',
              boundaryMessageId: 'msg-1',
            ),
          );

      final compactions = await db.select(db.compactionPointsTable).get();
      expect(compactions, hasLength(1));

      await (db.update(db.chatSessionsTable)
            ..where((t) => t.sessionId.equals('sess-1')))
          .write(const ChatSessionsTableCompanion(title: Value('Updated')));

      sessions = await db.select(db.chatSessionsTable).get();
      expect(sessions.first.title, 'Updated');

      await db.delete(db.compactionPointsTable).go();
      final compactionsAfterDelete =
          await db.select(db.compactionPointsTable).get();
      expect(compactionsAfterDelete, isEmpty);
    });

    test('api_presets 表可 CRUD', () async {
      await db.into(db.apiPresetsTable).insert(
            ApiPresetsTableCompanion.insert(
              presetId: 'test-preset',
              name: 'Test Preset',
              baseUrl: const Value('https://api.test.com'),
            ),
          );

      var presets = await db.select(db.apiPresetsTable).get();
      expect(presets, hasLength(1));
      expect(presets.first.presetId, 'test-preset');
      expect(presets.first.isBuiltIn, false);

      await (db.update(db.apiPresetsTable)
            ..where((t) => t.presetId.equals('test-preset')))
          .write(const ApiPresetsTableCompanion(name: Value('Updated')));

      presets = await db.select(db.apiPresetsTable).get();
      expect(presets.first.name, 'Updated');

      await db.delete(db.apiPresetsTable).go();
      presets = await db.select(db.apiPresetsTable).get();
      expect(presets, isEmpty);
    });

    test('templates 表可 CRUD', () async {
      await db.into(db.templatesTable).insert(
            TemplatesTableCompanion.insert(
              templateId: 'test-template',
              name: 'Test Template',
              kind: 'systemPrompt',
              content: 'You are a helpful assistant.',
            ),
          );

      var templates = await db.select(db.templatesTable).get();
      expect(templates, hasLength(1));
      expect(templates.first.templateId, 'test-template');
      expect(templates.first.isBuiltIn, false);

      await (db.update(db.templatesTable)
            ..where((t) => t.templateId.equals('test-template')))
          .write(
        const TemplatesTableCompanion(content: Value('Updated content')),
      );

      templates = await db.select(db.templatesTable).get();
      expect(templates.first.content, 'Updated content');

      await db.delete(db.templatesTable).go();
      templates = await db.select(db.templatesTable).get();
      expect(templates, isEmpty);
    });
  });

  group('索引效果验证', () {
    test('EXPLAIN QUERY PLAN 使用索引', () async {
      await db.into(db.chatSessionsTable).insert(
            ChatSessionsTableCompanion.insert(
              sessionId: 'sess-1',
              title: 'Test',
            ),
          );

      await db.into(db.chatMessagesTable).insert(
            ChatMessagesTableCompanion.insert(
              messageId: 'msg-1',
              sessionId: 'sess-1',
              role: 'user',
              content: const Value('Hello'),
            ),
          );

      final plan = await db
          .customSelect(
            'EXPLAIN QUERY PLAN SELECT * FROM chat_messages '
            "WHERE session_id = 'sess-1'",
          )
          .get();

      final planStr = plan.map((r) => r.read<String>('detail')).join(' ');
      // SQLite 优化器会选择最合适的索引，验证使用了索引而非全表扫描
      expect(planStr, contains('INDEX idx_msg_'));
    });
  });

  group('recreateConversationTables', () {
    /// 辅助：检查表是否存在
    Future<bool> tableExists(String tableName) async {
      final result = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name = ?",
        variables: [Variable.withString(tableName)],
      ).get();
      return result.isNotEmpty;
    }

    test('清除所有会话/消息相关数据（数据被清空）', () async {
      // 准备：插入会话、消息、压缩点、分支
      await db.into(db.chatSessionsTable).insert(
            ChatSessionsTableCompanion.insert(
              sessionId: 'sess-1',
              title: 'Test',
            ),
          );
      await db.into(db.chatMessagesTable).insert(
            ChatMessagesTableCompanion.insert(
              messageId: 'msg-1',
              sessionId: 'sess-1',
              role: 'user',
              content: const Value('Hello'),
            ),
          );
      await db.into(db.chatSessionBranchesTable).insert(
            ChatSessionBranchesTableCompanion.insert(
              sessionId: 'sess-1',
              anchorUserMsgId: 'msg-1',
            ),
          );
      await db.into(db.compactionPointsTable).insert(
            CompactionPointsTableCompanion.insert(
              sessionId: 'sess-1',
              summaryMessageId: 'msg-summary',
              boundaryMessageId: 'msg-1',
            ),
          );

      expect(await db.select(db.chatSessionsTable).get(), hasLength(1));
      expect(await db.select(db.chatMessagesTable).get(), hasLength(1));

      // 执行：重建表
      await db.recreateConversationTables();

      // 验证：所有会话相关数据被清空
      expect(await db.select(db.chatSessionsTable).get(), isEmpty);
      expect(await db.select(db.chatMessagesTable).get(), isEmpty);
      expect(await db.select(db.chatSessionBranchesTable).get(), isEmpty);
      expect(await db.select(db.compactionPointsTable).get(), isEmpty);
    });

    test('保留 api_presets 和 templates 表数据', () async {
      // 准备：插入供应商配置和模板
      await db.into(db.apiPresetsTable).insert(
            ApiPresetsTableCompanion.insert(
              presetId: 'preset-1',
              name: 'OpenAI',
              baseUrl: const Value('https://api.openai.com'),
            ),
          );
      await db.into(db.templatesTable).insert(
            TemplatesTableCompanion.insert(
              templateId: 'tmpl-1',
              name: 'Default',
              kind: 'systemPrompt',
              content: 'You are a helpful assistant.',
            ),
          );

      // 执行：重建会话相关表
      await db.recreateConversationTables();

      // 验证：供应商配置和模板数据保留
      final presets = await db.select(db.apiPresetsTable).get();
      expect(presets, hasLength(1));
      expect(presets.first.presetId, 'preset-1');

      final templates = await db.select(db.templatesTable).get();
      expect(templates, hasLength(1));
      expect(templates.first.templateId, 'tmpl-1');
    });

    test('重建后表结构正常（可继续 CRUD）', () async {
      // 执行：重建表
      await db.recreateConversationTables();

      // 验证：重建后可正常插入和读取
      await db.into(db.chatSessionsTable).insert(
            ChatSessionsTableCompanion.insert(
              sessionId: 'sess-new',
              title: 'New Session',
            ),
          );
      await db.into(db.chatMessagesTable).insert(
            ChatMessagesTableCompanion.insert(
              messageId: 'msg-new',
              sessionId: 'sess-new',
              role: 'user',
              content: const Value('Hello after recreate'),
            ),
          );

      final sessions = await db.select(db.chatSessionsTable).get();
      expect(sessions, hasLength(1));
      expect(sessions.first.title, 'New Session');

      final messages = await db.select(db.chatMessagesTable).get();
      expect(messages, hasLength(1));
      expect(messages.first.content, 'Hello after recreate');
    });

    test('修复 v16 新增表缺失场景（模拟 v15 → v16 升级）', () async {
      // 准备：模拟 v15 升级后 intermediate_round_artifacts 表缺失
      // （v16 onUpgrade 无迁移块，旧库升级时新表不会被创建）
      await db
          .customStatement('DROP TABLE IF EXISTS intermediate_round_artifacts');
      expect(
        await tableExists('intermediate_round_artifacts'),
        isFalse,
        reason: '前置：表应已被手动 DROP',
      );

      // 执行：重建会话相关表
      await db.recreateConversationTables();

      // 验证：intermediate_round_artifacts 表被重新创建
      expect(
        await tableExists('intermediate_round_artifacts'),
        isTrue,
        reason: '修复后：表应被 recreateConversationTables 重建',
      );

      // 验证：可正常插入（模拟故事模式持久化场景）
      await db.into(db.intermediateRoundArtifactsTable).insert(
            IntermediateRoundArtifactsTableCompanion.insert(
              sessionId: 'sess-ira',
              turnNumber: 1,
              createdAt: DateTime.now().millisecondsSinceEpoch,
            ),
          );
      final artifacts =
          await db.select(db.intermediateRoundArtifactsTable).get();
      expect(artifacts, hasLength(1));
      expect(artifacts.first.sessionId, 'sess-ira');
      expect(artifacts.first.turnNumber, 1);
    });

    test('重建 memories_fts 虚拟表', () async {
      // 准备：手动 DROP 虚拟表（模拟旧库缺失）
      await db.customStatement('DROP TABLE IF EXISTS memories_fts');
      expect(await tableExists('memories_fts'), isFalse);

      // 执行：重建会话相关表
      await db.recreateConversationTables();

      // 验证：memories_fts 虚拟表被重新创建
      expect(await tableExists('memories_fts'), isTrue);
    });

    test('重建 failure_logs 表', () async {
      // 准备：手动 DROP（模拟旧库缺失）
      await db.customStatement('DROP TABLE IF EXISTS failure_logs');
      expect(await tableExists('failure_logs'), isFalse);

      // 执行：重建会话相关表
      await db.recreateConversationTables();

      // 验证：failure_logs 表被重新创建
      expect(await tableExists('failure_logs'), isTrue);
    });
  });

  group('v44 导演工具权限迁移（导演设置 P1-8）', () {
    Future<void> insertSession(String id, {bool? watchMode}) async {
      if (watchMode == null) {
        await db.customStatement(
          'INSERT INTO chat_sessions (session_id, title, mode) '
          "VALUES (?, ?, 'advanced')",
          [id, '测试'],
        );
      } else {
        await db.customStatement(
          'INSERT INTO chat_sessions (session_id, title, mode, watch_mode) '
          "VALUES (?, ?, 'advanced', ?)",
          [id, '测试', watchMode],
        );
      }
    }

    Future<String?> toolPermissionsOf(String id) async {
      final rows = await db.customSelect(
        'SELECT tool_permissions FROM chat_sessions WHERE session_id = ?',
        variables: [Variable.withString(id)],
      ).get();
      return rows.isEmpty
          ? null
          : rows.first.readNullable<String>('tool_permissions');
    }

    test('watch_mode=1 物化监督预设完整 map；false/null 保持 NULL', () async {
      await insertSession('watch-on', watchMode: true);
      await insertSession('watch-off', watchMode: false);
      await insertSession('watch-null');

      await db.migrateDirectorToolPermissionsForTest();

      final supervisedJson = jsonEncode(ToolPermissions.supervised);
      expect(await toolPermissionsOf('watch-on'), supervisedJson);
      expect(await toolPermissionsOf('watch-off'), null);
      expect(await toolPermissionsOf('watch-null'), null);
      // 旧列保留不删
      final watch = await db.customSelect(
        'SELECT watch_mode FROM chat_sessions WHERE session_id = ?',
        variables: [Variable.withString('watch-on')],
      ).get();
      expect(watch.first.readNullable<bool>('watch_mode'), true);
    });

    test('幂等：已物化的 map 不被二次覆盖，自定义值不被清', () async {
      await insertSession('watch-on', watchMode: true);
      await db.customStatement(
        "UPDATE chat_sessions SET tool_permissions = '{\"spawn\":\"deny\"}' "
        "WHERE session_id = 'watch-on'",
      );

      await db.migrateDirectorToolPermissionsForTest();
      await db.migrateDirectorToolPermissionsForTest();

      expect(
        await toolPermissionsOf('watch-on'),
        '{"spawn":"deny"}',
        reason: '已有非空值不覆盖（条件带 tool_permissions IS NULL）',
      );
    });

    test('schemaVersion ≥ 44：两新列存在且可空', () async {
      final columns =
          await db.customSelect('PRAGMA table_info(chat_sessions)').get();
      final names = columns.map((c) => c.read<String>('name')).toSet();
      expect(names, containsAll(['tool_permissions', 'max_duration_minutes']));
    });
  });

  group('v45 轮时间线列迁移（对话流 T3）', () {
    test('schemaVersion ≥ 45：agent_timeline 列存在且可空', () async {
      final columns = await db
          .customSelect('PRAGMA table_info(intermediate_round_artifacts)')
          .get();
      final timeline = columns
          .where((c) => c.read<String>('name') == 'agent_timeline')
          .toList();

      expect(timeline, hasLength(1));
      expect(
        timeline.single.read<int>('notnull'),
        0,
        reason: '旧数据缺列必须允许 NULL（回退 agentSteps 渲染红线）',
      );
    });

    test('旧行（无 agent_timeline）数据保留且读回 NULL（不丢数据）', () async {
      // 模拟 v44 旧行：仅写旧列
      await db.customStatement(
        'INSERT INTO intermediate_round_artifacts '
        '(session_id, turn_number, extracted_keywords, retrieved_memories, '
        'retrieved_facts, facts_changes, agent_steps, review_executed, '
        'created_at) '
        "VALUES ('legacy-session', 1, '[]', '[]', '[]', '[]', "
        "'[{\"toolName\":\"search_story\",\"status\":\"done\"}]', 0, 1000)",
      );

      final rows = await db.customSelect(
        'SELECT turn_number, generated_text, agent_steps, agent_timeline '
        'FROM intermediate_round_artifacts WHERE session_id = ?',
        variables: [Variable.withString('legacy-session')],
      ).get();

      expect(rows, hasLength(1));
      final row = rows.single;
      expect(row.read<int>('turn_number'), 1);
      expect(row.readNullable<String>('generated_text'), null);
      expect(
        row.read<String>('agent_steps'),
        contains('search_story'),
        reason: '升级不得改动/丢失旧列数据',
      );
      expect(
        row.readNullable<String>('agent_timeline'),
        null,
        reason: '旧数据缺列读回 NULL，UI 据此回退 agentSteps 渲染',
      );
    });
  });

  group('v46 剧情节奏会话列迁移', () {
    test('schemaVersion ≥ 46：narrative_pacing 列存在且可空', () async {
      final columns =
          await db.customSelect('PRAGMA table_info(chat_sessions)').get();
      final pacing = columns
          .where((c) => c.read<String>('name') == 'narrative_pacing')
          .toList();

      expect(pacing, hasLength(1));
      expect(
        pacing.single.read<int>('notnull'),
        0,
        reason: 'NULL = 跟随全局 advanced.narrative_pacing',
      );
    });

    test('写入与读回（旧会话行为 NULL 跟随全局）', () async {
      // 模拟 v45 旧会话：不写 narrative_pacing → NULL
      await db.customStatement(
        'INSERT INTO chat_sessions (session_id, title) '
        "VALUES ('pacing-null', 't')",
      );
      // 新写入显式档位
      await db.customStatement(
        'INSERT INTO chat_sessions (session_id, title, narrative_pacing) '
        "VALUES ('pacing-set', 't', 'conservative')",
      );

      final rows = await db
          .customSelect(
            'SELECT session_id, narrative_pacing FROM chat_sessions '
            "WHERE session_id IN ('pacing-null', 'pacing-set')",
          )
          .get();

      final byId = {
        for (final r in rows) r.read<String>('session_id'): r,
      };
      expect(
        byId['pacing-null']!.readNullable<String>('narrative_pacing'),
        null,
      );
      expect(
        byId['pacing-set']!.readNullable<String>('narrative_pacing'),
        'conservative',
      );
    });
  });

  group('v47+ turn 单一事实源列迁移（B1）', () {
    test('schemaVersion ≥ 47：next_turn 列存在且可空', () async {
      final columns =
          await db.customSelect('PRAGMA table_info(chat_sessions)').get();
      final nextTurn =
          columns.where((c) => c.read<String>('name') == 'next_turn').toList();

      expect(nextTurn, hasLength(1));
      expect(
        nextTurn.single.read<int>('notnull'),
        0,
        reason: '存量会话未物化时必须允许 NULL（公式惰性回退）',
      );
      expect(db.schemaVersion, 54);
    });

    test('旧会话行为 NULL，物化后读回计数器值', () async {
      // 模拟 v46 旧会话：不写 next_turn → NULL
      await db.customStatement(
        'INSERT INTO chat_sessions (session_id, title) '
        "VALUES ('turn-null', 't')",
      );
      await db.customStatement(
        'INSERT INTO chat_sessions (session_id, title, next_turn) '
        "VALUES ('turn-set', 't', 7)",
      );

      final rows = await db
          .customSelect(
            'SELECT session_id, next_turn FROM chat_sessions '
            "WHERE session_id IN ('turn-null', 'turn-set')",
          )
          .get();

      final byId = {
        for (final r in rows) r.read<String>('session_id'): r,
      };
      expect(byId['turn-null']!.readNullable<int>('next_turn'), null);
      expect(byId['turn-set']!.readNullable<int>('next_turn'), 7);
    });
  });

  // schemaVersion 48→49（新增
  // message_variants 表 + intermediate_round_artifacts.current_variant_index
  // 指针列）。模拟 v48 旧库（无表无列）重新打开，验证 repairSchema 增量
  // 补齐、旧数据不丢、版本推进 49——「旧会话打开不迁移失败」的守门。
  group('v49 稿件变体迁移（G-08+09）', () {
    test('旧库（user_version=48、无 message_variants/指针列）打开后自动补齐', () async {
      final dir = Directory.systemTemp.createTempSync('lmstory_v49_upgrade');
      final file = File('${dir.path}/test.db');
      AppDatabase? fileDb;

      try {
        // 1. 以当前 schema 建库并写入一条 v48 时代的 artifacts 行
        fileDb = AppDatabase.forTesting(NativeDatabase(file));
        await fileDb.customSelect('SELECT 1').get();
        await fileDb.customStatement(
          'INSERT INTO intermediate_round_artifacts '
          "(session_id, turn_number, created_at) VALUES ('s1', 3, 1000)",
        );
        await fileDb.close();

        // 2. 模拟 v48 旧库：DROP 指针列 + DROP 变体表并回拨版本号
        final native = NativeDatabase(
          file,
          setup: (raw) {
            raw
              ..execute(
                'ALTER TABLE intermediate_round_artifacts '
                'DROP COLUMN current_variant_index',
              )
              ..execute('DROP TABLE message_variants')
              ..execute('PRAGMA user_version = 48');
          },
        );

        // 3. 重新打开：onUpgrade(48→49) → repairSchema 增量补表补列
        fileDb = AppDatabase.forTesting(native);
        await fileDb.customSelect('SELECT 1').get();
        expect(fileDb.schemaVersion, 54);

        final tables = await fileDb
            .customSelect(
              "SELECT name FROM sqlite_master WHERE type='table' "
              "AND name='message_variants'",
            )
            .get();
        expect(tables, hasLength(1), reason: 'repairSchema 必须补建变体表');

        final columns = await fileDb
            .customSelect('PRAGMA table_info(intermediate_round_artifacts)')
            .get();
        expect(
          columns
              .where((c) => c.read<String>('name') == 'current_variant_index'),
          hasLength(1),
          reason: 'repairSchema 必须补齐指针列',
        );

        // 旧行不丢、指针 NULL（单版本语义）
        final legacy = await fileDb.customSelect(
          'SELECT turn_number, current_variant_index '
          'FROM intermediate_round_artifacts WHERE session_id = ?',
          variables: [Variable.withString('s1')],
        ).get();
        expect(legacy, hasLength(1));
        expect(legacy.single.read<int>('turn_number'), 3);
        expect(legacy.single.readNullable<int>('current_variant_index'), null);

        // 变体表可写（新会话重生成即用）
        await fileDb.customStatement(
          'INSERT INTO message_variants '
          '(session_id, turn_number, variant_index, content, created_at) '
          "VALUES ('s1', 3, 0, '旧版', 1000)",
        );
      } finally {
        await fileDb?.close();
        dir.deleteSync(recursive: true);
      }
    });
  });

  // a：7cf837af 落版 schemaVersion 47→48（新增
  // factual_entities.injection_disabled）但升级路径零测试。本组模拟
  // v47 旧库（user_version=47、无该列）重新打开，验证 onUpgrade→
  // repairSchema 自动补列、旧行默认 0、版本推进 48。搭法沿用
  // app_database_before_open_repair_test 的临时文件库 + setup 回调。
  group('v48 注入停用列迁移（批 J-b / ）', () {
    test('旧库（user_version=47、无 injection_disabled）打开后自动补列且默认 0', () async {
      final dir = Directory.systemTemp.createTempSync('lmstory_v48_upgrade');
      final file = File('${dir.path}/test.db');
      AppDatabase fileDb;

      try {
        // 1. 以当前 schema 建库并写入一条 v47 时代的实体行
        fileDb = AppDatabase.forTesting(NativeDatabase(file));
        await fileDb.customSelect('SELECT 1').get();
        await fileDb.customStatement(
          'INSERT INTO factual_entities '
          '(entity_id, session_id, type, primary_name, importance, '
          'created_turn, created_at, is_archived) '
          "VALUES ('ent-legacy', 's1', 'character', '林动', 3, 1, 1000, 0)",
        );
        await fileDb.close();

        // 2. 模拟 v47 旧库：DROP 掉 v48 新增列并回拨版本号
        final native = NativeDatabase(
          file,
          setup: (raw) {
            raw
              ..execute(
                'ALTER TABLE factual_entities DROP COLUMN injection_disabled',
              )
              ..execute('PRAGMA user_version = 47');
          },
        );

        // 3. 重新打开：drift 触发 onUpgrade(47→48) → repairSchema 增量补列
        fileDb = AppDatabase.forTesting(native);
        await fileDb.customSelect('SELECT 1').get();

        final columns = await fileDb
            .customSelect('PRAGMA table_info(factual_entities)')
            .get();
        final col = columns
            .where((c) => c.read<String>('name') == 'injection_disabled')
            .toList();
        expect(col, hasLength(1), reason: 'repairSchema 必须补齐 v48 列');
        expect(
          col.single.read<int>('notnull'),
          1,
          reason: '列定义带 DEFAULT 0，NOT NULL 约束可在 ADD COLUMN 中保留',
        );

        // 旧行读回默认 0（未停用），旧数据不丢
        final legacy = await fileDb
            .customSelect(
              'SELECT primary_name, injection_disabled FROM factual_entities '
              "WHERE entity_id = 'ent-legacy'",
            )
            .get();
        expect(legacy, hasLength(1));
        expect(legacy.single.read<String>('primary_name'), '林动');
        expect(legacy.single.read<int>('injection_disabled'), 0);

        // 新行不写该列 → DEFAULT 0 兜底
        await fileDb.customStatement(
          'INSERT INTO factual_entities '
          '(entity_id, session_id, type, primary_name, importance, '
          'created_turn, created_at, is_archived) '
          "VALUES ('ent-new', 's1', 'item', '玄天尺', 2, 1, 1000, 0)",
        );
        final fresh = await fileDb
            .customSelect(
              'SELECT injection_disabled FROM factual_entities '
              "WHERE entity_id = 'ent-new'",
            )
            .get();
        expect(fresh.single.read<int>('injection_disabled'), 0);

        // 版本号推进到当前 schemaVersion（v49 起为 49；升级完成后由 drift 写回）
        final version = await fileDb.customSelect('PRAGMA user_version').get();
        expect(version.first.read<int>('user_version'), fileDb.schemaVersion);
        expect(fileDb.schemaVersion, 54);

        await fileDb.close();
      } finally {
        dir.deleteSync(recursive: true);
      }
    });
  });

  group('v47+ 窗口：主名唯一索引 partial 化（B11/ 归档让名）', () {
    Future<String?> indexSql() async {
      final rows = await db
          .customSelect(
            "SELECT sql FROM sqlite_master WHERE type='index' "
            "AND name='idx_factual_entities_session_name'",
          )
          .get();
      return rows.isEmpty ? null : rows.first.readNullable<String>('sql');
    }

    Future<void> insertEntity(
      String id,
      String name, {
      bool archived = false,
    }) async {
      await db.customStatement(
        'INSERT INTO factual_entities '
        '(entity_id, session_id, type, primary_name, importance, '
        'created_turn, created_at, is_archived) '
        "VALUES (?, 's1', 'character', ?, 3, 1, 1000, ?)",
        [id, name, if (archived) 1 else 0],
      );
    }

    test('新库索引即 partial（WHERE is_archived = 0）', () async {
      final sql = await indexSql();
      expect(sql, isA<String>(), reason: '索引必须存在');
      expect(
        sql,
        contains('is_archived'),
        reason: 'onCreate 建的必须是 partial 版（归档让名）',
      );
    });

    test('归档让名：归档后同名活跃实体可再建', () async {
      await insertEntity('ent-old', '魔法', archived: true);
      // 归档名不再占用：同名活跃实体创建成功（partial 索引放行）
      await insertEntity('ent-new', '魔法');
      final rows = await db
          .customSelect(
            "SELECT entity_id FROM factual_entities WHERE primary_name = '魔法'",
          )
          .get();
      expect(rows, hasLength(2));
    });

    test('活跃互斥不变：两条同名活跃实体第二条被拒', () async {
      await insertEntity('ent-a', '王国');
      await expectLater(
        insertEntity('ent-b', '王国'),
        throwsA(anything),
        reason: 'partial 索引仍约束活跃行',
      );
    });

    test('迁移：旧全量索引被替换为 partial，且幂等', () async {
      // 模拟旧库：手工重建全量唯一索引
      await db.customStatement(
        'DROP INDEX idx_factual_entities_session_name',
      );
      await db.customStatement(
        'CREATE UNIQUE INDEX idx_factual_entities_session_name '
        'ON factual_entities (session_id, primary_name)',
      );
      expect(await indexSql(), isNot(contains('is_archived')));

      await db.migrateFactualArchivedNameIndexForTest();
      expect(await indexSql(), contains('is_archived'));

      // 幂等：已是 partial 再跑不报错不变形
      await db.migrateFactualArchivedNameIndexForTest();
      expect(await indexSql(), contains('is_archived'));
    });
  });

  // FTS 形状漂移自愈——v16-20 旧库
  // （memories_fts 4 列）在统一增量策略下永不自愈，insertFtsIndex 的
  // 10 列 INSERT 在轮事务内必败（故事轮持久化全链失效）。repairSchema
  // 检出形状不符 → DROP 重建 + 从 experiential_memories 回填。
  group('FTS 形状漂移自愈', () {
    test('v16-20 旧形状 → repairSchema 重建 10 列并回填存量行', () async {
      // 源表放三条：两条达标（importance>=3）、一条低价值不索引
      await db.customStatement(
        'INSERT INTO experiential_memories '
        '(memory_id, session_id, summary, when_text, who_text, importance, '
        'tags, turn_number, created_at) VALUES '
        "('m-hi-1', 's1', '勇者抵达边境', '次日清晨', '勇者', 4, '[]', 1, 1000), "
        "('m-hi-2', 's1', '巨龙现身', NULL, '巨龙', 3, '[]', 2, 1000), "
        "('m-lo', 's1', '风吹过', NULL, NULL, 2, '[]', 3, 1000)",
      );

      // 模拟 v16-20 旧形状：DROP 现表，建 4 列旧表
      await db.customStatement('DROP TABLE memories_fts');
      await db.customStatement(
        'CREATE VIRTUAL TABLE memories_fts USING fts5(summary, when_text, who_text, memory_id UNINDEXED, '
        "tokenize='trigram')",
      );
      // 旧行残留在旧形状表里
      await db.customStatement(
        "INSERT INTO memories_fts (summary, memory_id) VALUES ('旧词', 'm-old')",
      );

      await db.repairSchema();

      // 形状修复为 10 列
      final cols =
          await db.customSelect('PRAGMA table_info(memories_fts)').get();
      final names = cols.map((c) => c.read<String>('name')).toSet();
      expect(names, containsAll(const ['extra', 'what_text', 'session_id']));

      // 达标行回填（null → 空串），低价值行不索引，旧幽灵行随 DROP 消失
      final rows = await db.customSelect(
        'SELECT memory_id, summary FROM memories_fts WHERE session_id = ?',
        variables: [Variable.withString('s1')],
      ).get();
      final ids = rows.map((r) => r.read<String>('memory_id')).toSet();
      expect(
        ids,
        {'m-hi-1', 'm-hi-2'},
        reason: 'importance>=3 回填；importance<3 维持不索引语义',
      );
      expect(ids, isNot(contains('m-old')), reason: '旧形状残行随 DROP 消失');
    });

    // v32/v33 列改名（drafting_*/revise_*
    // → generating_*/reviewing_*）当年只改了 Table 类未迁数据——旧列值孤儿化，
    // 会话级步骤模型与审查开关静默回落全局。按旧列存在性检测回填，幂等。
    group('v32/v33 列改名回填', () {
      test('旧列存在且有值 → 回填到新列，旧列保留', () async {
        // 模拟 v23-31 形状：加旧列、写值（新列已由当前 schema 存在但为 NULL）
        await db.customStatement(
          'ALTER TABLE chat_sessions ADD COLUMN drafting_preset_id TEXT',
        );
        await db.customStatement(
          'ALTER TABLE chat_sessions ADD COLUMN drafting_model_id TEXT',
        );
        await db.customStatement(
          'ALTER TABLE chat_sessions ADD COLUMN revise_enabled_override BOOLEAN',
        );
        await db.customStatement(
          'INSERT INTO chat_sessions (session_id, title, mode, created_at, '
          'drafting_preset_id, drafting_model_id, revise_enabled_override) '
          "VALUES ('s-dv12', '旧库会话', 'intermediate', 1000, "
          "'preset-a', 'model-x', 1)",
        );

        await db.migrateSessionColumnRenamesForTest();

        final row = await db.customSelect(
          'SELECT generating_preset_id, generating_model_id, '
          'review_enabled_override, drafting_preset_id '
          'FROM chat_sessions WHERE session_id = ?',
          variables: [Variable.withString('s-dv12')],
        ).getSingle();
        expect(row.read<String?>('generating_preset_id'), 'preset-a');
        expect(row.read<String?>('generating_model_id'), 'model-x');
        expect(row.read<bool?>('review_enabled_override'), isTrue);
        expect(
          row.read<String?>('drafting_preset_id'),
          'preset-a',
          reason: '旧列保留不删（保数据铁律）',
        );
      });

      test('幂等 + 新值优先：新列已有值不被旧列覆盖', () async {
        await db.customStatement(
          'ALTER TABLE chat_sessions ADD COLUMN drafting_preset_id TEXT',
        );
        await db.customStatement(
          'INSERT INTO chat_sessions (session_id, title, mode, created_at, '
          'drafting_preset_id, generating_preset_id) '
          "VALUES ('s-dv12b', '会话B', 'intermediate', 1000, "
          "'old-preset', 'new-preset')",
        );

        await db.migrateSessionColumnRenamesForTest();
        await db.migrateSessionColumnRenamesForTest();

        final row = await db.customSelect(
          'SELECT generating_preset_id FROM chat_sessions WHERE session_id = ?',
          variables: [Variable.withString('s-dv12b')],
        ).getSingle();
        expect(
          row.read<String?>('generating_preset_id'),
          'new-preset',
          reason: '改名后用户显式改过的新值优先，重跑零动作',
        );
      });

      test('新装库无旧列 → no-op', () async {
        await db.customStatement(
          'INSERT INTO chat_sessions (session_id, title, mode, created_at) '
          "VALUES ('s-fresh', '新装会话', 'intermediate', 1000)",
        );

        await db.migrateSessionColumnRenamesForTest();

        final row = await db.customSelect(
          'SELECT generating_preset_id FROM chat_sessions WHERE session_id = ?',
          variables: [Variable.withString('s-fresh')],
        ).getSingle();
        expect(row.read<String?>('generating_preset_id'), equals(null));
      });
    });

    test('形状正常时不重建（幂等零动作）', () async {
      await db.customStatement(
        'INSERT INTO experiential_memories '
        '(memory_id, session_id, summary, importance, tags, turn_number, '
        "created_at) VALUES ('m-1', 's1', '正文甲乙', 3, '[]', 1, 1000)",
      );
      // 走单一写入口建索引
      await db.customStatement(
        'INSERT INTO memories_fts (summary, when_text, where_text, who_text, '
        'what_text, significance, extra, memory_id, memory_type, session_id) '
        "VALUES ('正文甲乙', '', '', '', '', '', '', 'm-1', 'experiential', 's1')",
      );

      await db.repairSchema();

      final rows = await db.customSelect(
        'SELECT COUNT(*) AS c FROM memories_fts WHERE session_id = ?',
        variables: [Variable.withString('s1')],
      ).get();
      expect(rows.first.read<int>('c'), 1, reason: '形状正常时不得重复回填（幂等）');
    });
  });
}
