import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';
import 'package:lmstory/features/settings/data/auto_backup_manager.dart';
import 'package:lmstory/features/settings/data/repositories/backup_repository_impl.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/domain/services/data_management_service.dart';

/// v3 备份 roundtrip 测试矩阵（备份完整性立项，2026-09-02）
///
/// 导出→清库→导入→逐表计数与抽样内容断言——首次覆盖
/// BackupRepository / DataManagementService 核心路径（此前零测试）。
///
/// 命名注意：backupVersion 是项目自己的备份格式
/// 版本号，与世界书/角色卡的 SillyTavern 卡规范（卡 JSON 内 spec_version
/// v1/v2/v3）完全无关——本组测试同时覆盖两者共存场景（资源库存的是卡
/// 原始 JSON，其内部的 spec_version 与备份格式版本互不影响）。
void main() {
  late AppDatabase db;
  late ChatRepository chatRepo;
  late BackupRepositoryImpl backupRepo;
  late _StubSettingsRepository settingsRepo;
  late _StubPresetRepository presetRepo;
  late DataManagementService service;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    chatRepo = ChatRepositoryImpl(database: db);
    backupRepo = BackupRepositoryImpl(database: db);
    settingsRepo = _StubSettingsRepository();
    presetRepo = _StubPresetRepository();
    service = DataManagementService(
      chatRepository: chatRepo,
      presetRepository: presetRepo,
      settingsRepository: settingsRepo,
      backupRepository: backupRepo,
    );
  });

  tearDown(() async => db.close());

  Future<int> count(String sql, [List<Object?> args = const []]) async {
    final rows = await db
        .customSelect('SELECT COUNT(*) AS n FROM ($sql)', variables: []).get();
    return rows.first.read<int>('n');
  }

  Future<int> tableCount(String table) async {
    final rows =
        await db.customSelect('SELECT COUNT(*) AS n FROM $table').get();
    return rows.first.read<int>('n');
  }

  /// 播种一套跨表数据：会话+消息+记忆+事实层+产物+供应商+资源库+模板+事件日志
  Future<String> seedEverything() async {
    final session = await chatRepo.createSession(
      title: '备份测试会话',
      mode: 'intermediate',
    );
    final sessionId = session.sessionId;
    final now = DateTime(2026);
    for (var i = 0; i < 2; i++) {
      await chatRepo.addMessage(
        ChatMessage(
          messageId: 'u$i',
          sessionId: sessionId,
          role: 'user',
          content: '用户消息 $i',
          createdAt: now,
        ),
      );
      await chatRepo.addMessage(
        ChatMessage(
          messageId: 'a$i',
          sessionId: sessionId,
          role: 'assistant',
          content: '助手回复 $i',
          createdAt: now,
        ),
      );
    }

    final expRepo = ExperienceRepositoryImpl(
      database: db,
      vectorEngine: const VectorEngine(),
    );
    final memory = await expRepo.appendExperience(
      sessionId: sessionId,
      summary: '勇者在古堡发现了古碑',
      importance: 4,
      tags: const ['探索'],
      turnNumber: 1,
    );
    await expRepo.insertFtsIndex(
      memoryId: memory.memoryId,
      summary: '勇者在古堡发现了古碑',
      sessionId: sessionId,
    );

    await db.customStatement(
      'INSERT INTO factual_entities '
      '(entity_id, session_id, primary_name, type, importance, '
      'is_archived, aliases, source, source_ref, force_inject, created_turn) '
      "VALUES ('ent-1', ?, '古碑', 'object', 3, 0, '[]', "
      "'auto', NULL, 'none', 1)",
      [sessionId],
    );
    await db.customStatement(
      'INSERT INTO factual_attributes '
      '(attribute_id, entity_id, session_id, attr_key, value, source) '
      "VALUES ('attr-1', 'ent-1', ?, 'description', '刻着符文的石碑', 'auto')",
      [sessionId],
    );
    await db.customStatement(
      'INSERT INTO intermediate_round_artifacts '
      '(session_id, turn_number, extracted_keywords, retrieved_memories, '
      'retrieved_facts, reply_text, facts_changes, agent_steps, '
      'review_executed, created_at) '
      "VALUES (?, 1, '[]', '[]', '[]', '回复正文', '[]', '[]', 0, 1000)",
      [sessionId],
    );

    // 供应商：1 自定义（is_built_in=0）
    await db.customStatement(
      'INSERT INTO api_presets (preset_id, name, base_url, is_built_in) '
      "VALUES ('preset-custom', '自定义供应商', 'https://api.test', 0)",
    );

    // 资源库：角色卡 + 世界书（rawJson 内含 SillyTavern spec_version 字段，
    // 与备份格式 backupVersion 互不相干）
    await db.customStatement(
      'INSERT INTO character_cards (card_id, name, raw_json, source_format) '
      "VALUES ('card-1', '艾琳', "
      "'{\"spec\":\"chara_card_v2\",\"spec_version\":\"2.0\",\"data\":{}}', "
      "'v2')",
    );
    await db.customStatement(
      'INSERT INTO worldbooks (book_id, name, raw_json) '
      "VALUES ('book-1', '北境设定', "
      "'{\"spec\":\"worldbook\",\"entries\":[]}')",
    );

    // 模板：1 内置 + 1 自建（导出仅含自建）
    await db.customStatement(
      'INSERT INTO templates (template_id, name, kind, content, is_built_in) '
      "VALUES ('tmpl-builtin', '内置模板', 'systemPrompt', '...', 1)",
    );
    await db.customStatement(
      'INSERT INTO templates (template_id, name, kind, content, is_built_in) '
      "VALUES ('tmpl-custom', '我的模板', 'systemPrompt', '自定义内容', 0)",
    );

    // 导演事件日志（行级 dump 跟随 schema；仅数据播种，不涉日志读写代码）
    await db.customStatement(
      'INSERT INTO agent_events '
      '(session_id, seq, type, time, data, surface_op) '
      "VALUES (?, 1, 'round', 1000, '{\"turn\":1}', NULL)",
      [sessionId],
    );

    // 偏好 + API Key
    await settingsRepo.setUserOverride(
      'intermediate.generation.temperature',
      0.7,
    );
    await settingsRepo.saveApiKey('preset-custom', 'sk-secret');

    return sessionId;
  }

  test('v3 全量导出→清库→覆盖导入→逐表计数与抽样内容还原', () async {
    final sessionId = await seedEverything();

    // ── 导出 ──
    final json = await service.exportFullBackup(
      const DataExportOptions(
        includeSessions: true,
        includePresets: true,
        includePreferences: true,
      ),
    );
    final map = jsonDecode(json) as Map<String, dynamic>;

    expect(map['version'], 3, reason: 'backupVersion 3（项目备份格式版本）');
    // v3 新键齐全
    expect((map['characterCards'] as List).length, 1);
    expect((map['worldbooks'] as List).length, 1);
    expect((map['userTemplates'] as List).length, 1, reason: '内置模板不入备份');
    expect((map['agentEvents'] as List).length, 1);
    // 默认不含 API Key
    final presets = (map['presets'] as List).cast<Map<String, dynamic>>();
    expect(presets.single.containsKey('api_key'), isFalse);

    // ── 清库（模拟换机/清空）──
    await backupRepo.deleteAllSessionData();
    await backupRepo.deleteAllCustomPresets();
    await db.customStatement('DELETE FROM character_cards');
    await db.customStatement('DELETE FROM worldbooks');
    await db.customStatement('DELETE FROM templates WHERE is_built_in = 0');
    await db.customStatement('DELETE FROM agent_events');
    await settingsRepo.clearAllUserOverrides();
    settingsRepo.apiKeys.clear();

    expect(await tableCount('chat_messages'), 0);
    expect(await tableCount('character_cards'), 0);
    expect(await tableCount('agent_events'), 0);

    // ── 覆盖导入 ──
    final result = await service.importBackup(json, ImportMode.overwrite);

    expect(result.importedSessions, 1);
    expect(result.importedMessages, 4);
    expect(result.importedAssets, 4, reason: '角色卡1+世界书1+自建模板1+事件1');
    expect(result.importedPreferences, 1);

    // 会话与消息
    final messages = await chatRepo.getMessages(sessionId);
    expect(messages.length, 4);
    expect(messages.first.content, '用户消息 0');
    // 经历记忆 + FTS
    expect(await tableCount('experiential_memories'), 1);
    expect(await tableCount('memories_fts'), 1);
    // 事实层
    expect(await tableCount('factual_entities'), 1);
    expect(await tableCount('factual_attributes'), 1);
    // 产物
    expect(await tableCount('intermediate_round_artifacts'), 1);
    // 供应商
    expect(
      await count('SELECT 1 FROM api_presets WHERE preset_id '
          "= 'preset-custom'"),
      1,
    );
    // 资源库（抽样内容）
    final card = (await db
            .customSelect(
              'SELECT name, raw_json, source_format FROM character_cards '
              "WHERE card_id = 'card-1'",
            )
            .get())
        .single;
    expect(card.read<String>('name'), '艾琳');
    expect(card.read<String>('raw_json'), contains('spec_version'));
    expect(await count("SELECT 1 FROM worldbooks WHERE book_id = 'book-1'"), 1);
    // 模板：自建还原 + 内置保留（覆盖导入只清自建）
    expect(
      await count(
        "SELECT 1 FROM templates WHERE template_id = 'tmpl-custom'",
      ),
      1,
    );
    expect(
      await count(
        "SELECT 1 FROM templates WHERE template_id = 'tmpl-builtin'",
      ),
      1,
    );
    // 事件日志
    expect(await tableCount('agent_events'), 1);
    // 偏好
    expect(
      settingsRepo.overrides['intermediate.generation.temperature'],
      0.7,
    );
    // API Key 不随备份（includeApiKeys=false）：导入后无 Key
    expect(settingsRepo.apiKeys.containsKey('preset-custom'), isFalse);
  });

  test('v2 备份（缺 v3 新键）导入兼容：会话还原、全局资产零导入', () async {
    await seedEverything();
    final json = await service.exportFullBackup(
      const DataExportOptions(
        includeSessions: true,
        includePresets: true,
        includePreferences: true,
      ),
    );
    // 降级成 v2 形态：剥掉 v3 新键 + 版本号改 2
    final v2Map = (jsonDecode(json) as Map<String, dynamic>)
      ..remove('characterCards')
      ..remove('worldbooks')
      ..remove('userTemplates')
      ..remove('agentEvents')
      ..['version'] = 2;
    final v2Json = jsonEncode(v2Map);

    await backupRepo.deleteAllSessionData();
    await db.customStatement('DELETE FROM character_cards');
    await db.customStatement('DELETE FROM worldbooks');
    await db.customStatement('DELETE FROM templates WHERE is_built_in = 0');

    final result = await service.importBackup(
      v2Json,
      ImportMode.overwrite,
    );

    // v2 路由正确（不再误入 v1 链）：会话数据还原
    expect(result.importedSessions, 1);
    expect(result.importedMessages, 4);
    // 全局资产键缺失 → 空清单，0 导入不报错
    expect(result.importedAssets, 0);
    expect(await tableCount('character_cards'), 0);
  });

  test('未来版本（version > backupVersion）拒绝导入', () async {
    final future = jsonEncode({
      'version': 99,
      'sessions': <String>[],
      'presets': <String>[],
      'preferences': <String, dynamic>{},
      'characterCards': <String>[],
      'worldbooks': <String>[],
      'userTemplates': <String>[],
      'agentEvents': <String>[],
    });
    await expectLater(
      service.importBackup(future, ImportMode.append),
      throwsA(isA<FormatException>()),
    );
  });

  test('含 API Key 导出：预设行带 api_key + contains_secrets 标记', () async {
    await seedEverything();
    final json = await service.exportFullBackup(
      const DataExportOptions(
        includeSessions: true,
        includePresets: true,
        includePreferences: true,
        includeApiKeys: true,
      ),
    );
    final map = jsonDecode(json) as Map<String, dynamic>;
    expect(map['contains_secrets'], true);
    final presets = (map['presets'] as List).cast<Map<String, dynamic>>();
    expect(presets.single['api_key'], 'sk-secret');

    // 导回后 Key 恢复（：Key 导入默认关闭，能力测试显式勾选）
    await backupRepo.deleteAllCustomPresets();
    settingsRepo.apiKeys.clear();
    await service.importBackup(json, ImportMode.append, importApiKeys: true);
    expect(settingsRepo.apiKeys['preset-custom'], 'sk-secret');
  });

  test('DM-1: 单会话导出含 agent_events，覆盖导入后事件日志还原（无净损失）', () async {
    final sessionId = await seedEverything();

    final json = await service.exportSessionAsJson(sessionId);
    final map = jsonDecode(json) as Map<String, dynamic>;
    final sessionData =
        (map['sessions'] as List).single as Map<String, dynamic>;

    // 导出面包含事件日志（按 session_id 过滤行）
    expect(sessionData.containsKey('agentEvents'), isTrue);
    expect(sessionData['agentEvents'] as List? ?? const [], isNotEmpty);

    // 覆盖导入同一会话：deleteSessionData 先删 agent_events，文件里有 → 还原。
    // 修复前导出缺该表 → 覆盖导入净损失事件日志（轮轨迹/日志恢复失守）。
    final result = await service.importBackup(json, ImportMode.overwrite);

    expect(result.importedSessions, 1);
    expect(result.importedMessages, 4);
    expect(await tableCount('agent_events'), 1);
    expect(await tableCount('chat_messages'), 4);
  });

  test('DM-1 兼容: 旧单会话导出（无 agentEvents 键）覆盖导入不崩、缺键不导入', () async {
    final sessionId = await seedEverything();
    final map = jsonDecode(await service.exportSessionAsJson(sessionId))
        as Map<String, dynamic>;
    ((map['sessions'] as List).single as Map<String, dynamic>)
        .remove('agentEvents');
    final oldJson = jsonEncode(map);

    final result = await service.importBackup(oldJson, ImportMode.overwrite);

    // 缺键 = 不导入该表，保持现状行为（旧导出文件向后兼容）
    expect(result.importedSessions, 1);
    expect(result.importedMessages, 4);
    expect(await tableCount('agent_events'), 0);
    expect(await tableCount('chat_messages'), 4);
  });

  test('DM-2: 空会话数组 v3 备份覆盖导入：不动现有会话（UI 承诺兑现）', () async {
    await seedEverything();
    // 空库设备「会话（默认勾选）」全量导出的真实形态：sessions/agentEvents
    // 均为空数组（exportFullBackup 对空清单照写键）
    final emptyBackup = jsonEncode({
      'version': 3,
      'exportedAt': DateTime(2026, 9, 4).toIso8601String(),
      'presets': <Map<String, dynamic>>[],
      'sessions': <Map<String, dynamic>>[],
      'preferences': <String, dynamic>{},
      'characterCards': <Map<String, dynamic>>[],
      'worldbooks': <Map<String, dynamic>>[],
      'userTemplates': <Map<String, dynamic>>[],
      'agentEvents': <Map<String, dynamic>>[],
    });

    final result =
        await service.importBackup(emptyBackup, ImportMode.overwrite);

    // UI 三处承诺「覆盖不会影响你的任何会话」→ 会话与衍生数据全部保留
    expect(result.importedSessions, 0);
    expect(await tableCount('chat_sessions'), 1);
    expect(await tableCount('chat_messages'), 4);
    expect(
      await tableCount('agent_events'),
      1,
      reason: 'agent_events 属会话衍生数据，随会话域一并保留',
    );
  });

  test('DM-2: sessions 键缺失的 v3 备份覆盖导入：会话域不动（既有语义保持）', () async {
    await seedEverything();
    final noKeyBackup = jsonEncode({
      'version': 3,
      'presets': <Map<String, dynamic>>[],
      'preferences': <String, dynamic>{},
      'characterCards': <Map<String, dynamic>>[],
      'worldbooks': <Map<String, dynamic>>[],
      'userTemplates': <Map<String, dynamic>>[],
    });

    await service.importBackup(noKeyBackup, ImportMode.overwrite);

    expect(await tableCount('chat_sessions'), 1);
    expect(await tableCount('chat_messages'), 4);
    expect(await tableCount('agent_events'), 1);
  });

  test('DM-2: 空会话数组 v1 备份覆盖导入：不动现有会话（与 v3 链同口径）', () async {
    await seedEverything();
    final v1Empty = jsonEncode({
      'version': 1,
      'presets': <Map<String, dynamic>>[],
      'sessions': <Map<String, dynamic>>[],
      'preferences': <String, dynamic>{},
    });

    await service.importBackup(v1Empty, ImportMode.overwrite);

    expect(await tableCount('chat_sessions'), 1);
    expect(await tableCount('chat_messages'), 4);
  });

  // 全局资产覆盖删除此前不看键存在性——手裁/第三
  // 方 v3 变体缺 characterCards 键时该表被整表清零且恢复 0 行。对齐
  // agent_events 的 DM-2 键判定：缺键=该域不动；键存在（含空数组）=
  // 覆盖语义保持。
  test('DM6-1: 缺资产键的 v3 备份覆盖导入——缺键表不动，在键表照常覆盖', () async {
    await seedEverything();
    final json = await service.exportFullBackup(
      const DataExportOptions(
        includeSessions: true,
        includePresets: true,
        includePreferences: true,
      ),
    );
    final map = (jsonDecode(json) as Map<String, dynamic>)
      ..remove('characterCards') // 模拟手裁/第三方变体缺键
      ..remove('userTemplates');
    map['worldbooks'] = <dynamic>[]; // 键存在且空 → 覆盖清空（既有语义）

    final result = await service.importBackup(
      jsonEncode(map),
      ImportMode.overwrite,
    );

    // 缺键表原样保留
    expect(await tableCount('character_cards'), 1, reason: '缺键=该域不动');
    expect(
      await tableCount('templates'),
      greaterThanOrEqualTo(1),
      reason: '自建模板随 userTemplates 缺键保留',
    );
    // 在键表被空数组覆盖清空
    expect(await tableCount('worldbooks'), 0, reason: '键存在空数组=覆盖清空');
    // agentEvents 键仍在（1 行）：删除重建计入 importedAssets
    expect(result.importedAssets, 1);
  });

  test('DM-3: v1 备份畸形条目容错：坏条目跳过计数，好条目照常导入（覆盖）', () async {
    await seedEverything();
    final v1 = jsonEncode({
      'version': 1,
      'presets': [
        {'name': '好供应商', 'baseUrl': 'https://good.test', 'apiKey': 'sk-1'},
        'garbage-not-a-map',
        {'name': '坏值供应商', 'baseUrl': 42},
      ],
      'sessions': [
        {
          'sessionId': 'v1-s1',
          'name': 'v1 会话',
          'mode': 'chat',
          'messages': [
            {
              'role': 'user',
              'content': '好消息',
              'messageId': 'v1-m1',
              'createdAt': '2026-01-01T00:00:00.000',
            },
            'garbage-not-a-map',
            {
              'role': 'user',
              'content': '坏日期',
              'createdAt': 'not-a-date',
            },
          ],
        },
        42,
      ],
      'preferences': {'k': 'v'},
    });

    // 修复前：presetRaw as Map 抛 TypeError 直穿 importBackup——
    // 覆盖模式删除已先行提交，剩余条目全部不导入（半空库终态）
    // Key 导入默认关闭，本用例验证好条目落地能力故显式勾选
    final result = await service.importBackup(
      v1,
      ImportMode.overwrite,
      importApiKeys: true,
    );

    expect(result.importedPresets, 1);
    expect(result.skippedPresets, 2, reason: '非 Map 条目 + 坏值条目');
    expect(result.importedSessions, 1);
    expect(result.skippedSessions, 1, reason: '非 Map 会话条目');
    expect(result.importedMessages, 1, reason: '坏消息跳过，好消息保留');
    // 覆盖删除先行后，好条目仍落地（不再半空库）。v1 链总是新建会话
    // （sessionId 仅用于追加去重），按标题断言。
    expect(
      await count("SELECT 1 FROM chat_sessions WHERE title = 'v1 会话'"),
      1,
    );
    expect(await tableCount('chat_messages'), 1);
    expect(settingsRepo.overrides['k'], 'v');
    expect(settingsRepo.apiKeys.values, contains('sk-1'));
  });

  test('DM-3: legacy 数组导入畸形条目容错：坏条目跳过，好条目导入', () async {
    final legacy = jsonEncode([
      {
        'name': '旧会话 A',
        'messages': [
          {'role': 'user', 'content': 'hello'},
          'garbage-not-a-map',
        ],
      },
      'garbage-session',
    ]);

    // 修复前：data.cast<Map<String, dynamic>>() 对畸形条目直接抛 TypeError
    final result = await service.importBackup(legacy, ImportMode.append);

    expect(result.importedSessions, 1);
    expect(result.skippedSessions, 1);
    expect(result.importedMessages, 1);
    expect(await count("SELECT 1 FROM chat_sessions WHERE title = '旧会话 A'"), 1);
  });

  test('新列随行导出；旧备份缺 embedding_dimensions 键导入后回填', () async {
    final sessionId = await chatRepo.createSession(
      title: '维度备份会话',
      mode: 'intermediate',
    );
    final expRepo = ExperienceRepositoryImpl(
      database: db,
      vectorEngine: const VectorEngine(),
    );
    final memory = await expRepo.appendExperience(
      sessionId: sessionId.sessionId,
      summary: '带向量的记忆',
      importance: 4,
      tags: const [],
      turnNumber: 1,
    );
    await expRepo.updateEmbedding(
      memory.memoryId,
      Float32List.fromList(List.filled(8, 0.3)),
    );

    // ── 新备份：维度列随行导出 ──
    final data = await backupRepo.exportSessionData(sessionId.sessionId);
    final rows = data['experientialMemories'] as List<dynamic>;
    expect(rows, hasLength(1));
    expect((rows.single as Map<String, dynamic>)['embedding_dimensions'], 8);

    // ── 旧备份（缺键）：导入后 NULL → 导入侧回填补齐 ──
    final oldRow =
        Map<String, dynamic>.from(rows.single as Map<String, dynamic>)
          ..remove('embedding_dimensions');
    final oldBackup = Map<String, dynamic>.from(data)
      ..['experientialMemories'] = [oldRow];

    await backupRepo.deleteSessionData(sessionId.sessionId);
    final inserted = await backupRepo.importSessionData(
      oldBackup,
      mode: ImportMode.overwrite,
    );
    expect(inserted, greaterThanOrEqualTo(0), reason: '导入不因缺键失败');

    final restored = await db.customSelect(
      'SELECT embedding, embedding_dimensions FROM experiential_memories '
      'WHERE memory_id = ?',
      variables: [Variable.withString(memory.memoryId)],
    ).get();
    expect(restored, hasLength(1), reason: '旧备份行（含向量 BLOB）照常导入');
    expect(
      restored.single.readNullable<int>('embedding_dimensions'),
      8,
      reason: '导入即回填：维度 = LENGTH(blob)/4，不等下次开库',
    );
    expect(restored.single.read<Uint8List>('embedding'), hasLength(8 * 4));
  });

  group('AutoBackupManager（B3）', () {
    test('runIfNeeded：三条件门控 + 写文件 + 滚动保留 3 份', () async {
      // 用真实对象 + 注入临时目录/时钟（path_provider 不可用于测试环境）
      final dir = Directory.systemTemp.createTempSync('lmstory_autobackup');
      addTearDown(() => dir.deleteSync(recursive: true));

      final sessionId = await seedEverything();
      // 无关断言消除 unused 警告：seed 保证有会话数据
      expect(sessionId, isNotEmpty);

      final chatRepoForManager = chatRepo;
      var now = DateTime(2026, 9, 2, 12);
      final manager = AutoBackupManager(
        dataManagementService: service,
        settingsRepository: settingsRepo,
        chatRepository: chatRepoForManager,
        documentsDirectory: () async => dir,
        clock: () => now,
      );

      // 空目录 + 有会话 → 首次执行
      final first = await manager.runIfNeeded();
      expect(first, isNotNull);
      expect((await manager.listBackups()).length, 1);

      // 24h 间隔门控比较文件真实 mtime；把 mtime 同步到注入时钟，
      // 门控与真实 wall clock 解耦（原实现随测试运行时刻偶发跳备）
      Future<void> syncMtimes() async {
        for (final f in await manager.listBackups()) {
          await f.setLastModified(now);
        }
      }

      await syncMtimes();

      // 24h 内 → 跳过
      now = now.add(const Duration(hours: 1));
      expect(await manager.runIfNeeded(), isNull);
      expect((await manager.listBackups()).length, 1);

      // 超 24h → 再备份；滚动到 4 份时只保留 3
      for (var i = 0; i < 3; i++) {
        now = now.add(const Duration(hours: 25));
        await manager.runIfNeeded();
        await syncMtimes();
      }
      final files = await manager.listBackups();
      expect(files.length, 3, reason: '滚动保留最近 3 份');

      // 开关关闭 → 即使超 24h 也不执行
      await manager.setEnabled(enabled: false);
      now = now.add(const Duration(hours: 25));
      expect(await manager.runIfNeeded(), isNull);
      expect(
        settingsRepo.overrides[AutoBackupManager.enabledKey],
        false,
      );

      // 自动备份文件不含 API Key（默认安全导出）
      final content =
          jsonDecode(files.first.readAsStringSync()) as Map<String, dynamic>;
      expect(content.containsKey('contains_secrets'), isFalse);
      final presets = (content['presets'] as List).cast<Map<String, dynamic>>();
      expect(presets.single.containsKey('api_key'), isFalse);
    });
  });
}

/// SettingsRepository 测试桩：偏好与 Key 走内存 Map，其余 noSuchMethod
class _StubSettingsRepository implements SettingsRepository {
  final Map<String, dynamic> overrides = {};
  final Map<String, String> apiKeys = {};

  @override
  Future<Map<String, dynamic>> getUserOverrides() async =>
      Map<String, dynamic>.from(overrides);

  @override
  Future<void> setUserOverride(String key, dynamic value) async {
    overrides[key] = value;
  }

  @override
  Future<void> clearAllUserOverrides() async => overrides.clear();

  @override
  Future<String?> getApiKey(String presetId) async => apiKeys[presetId];

  @override
  Future<void> saveApiKey(String presetId, String apiKey) async {
    apiKeys[presetId] = apiKey;
  }

  @override
  Future<int> getUserOverrideCount() async => overrides.length;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

/// ApiPresetRepository 测试桩：v3 导入导出不经此仓库（仅 v1 链与统计用）。
/// v1 链（DM-3 容错测试）需要最小可用的内存实现：建/列/删自定义。
class _StubPresetRepository implements ApiPresetRepository {
  final List<ApiPreset> presets = [];
  var _nextId = 0;

  @override
  Future<List<ApiPreset>> getAllPresets() async => List.of(presets);

  @override
  Future<ApiPreset> createPreset({
    required String name,
    String baseUrl = '',
    LlmProtocol protocol = LlmProtocol.openaiCompatible,
  }) async {
    final preset = ApiPreset(
      presetId: 'stub-preset-${_nextId++}',
      name: name,
      baseUrl: baseUrl,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    presets.add(preset);
    return preset;
  }

  @override
  Future<void> deleteAllCustomPresets() async =>
      presets.removeWhere((p) => !p.isBuiltIn);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}
