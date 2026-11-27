import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/memory/data/migrations/relationship_split_migration.dart';

/// 关系属性拆分迁移测试（真实 drift 内存库）
///
/// 覆盖：个人关系拆出 / 群体保留 / 损坏恢复（历史证据） / 损坏无证据标记 /
/// 错型 list 标记 / 幂等 / 备份表 / 只读基线不动。
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seedEntity(
    String entityId,
    String name, {
    List<String> aliases = const [],
  }) async {
    await db.customStatement(
      'INSERT INTO factual_entities '
      '(entity_id, session_id, type, primary_name, aliases, importance, '
      'is_archived, source, created_turn, created_at) '
      "VALUES (?, 's1', 'character', ?, ?, 4, 0, 'auto', 1, '2026-01-01T00:00:00')",
      [entityId, name, jsonEncode(aliases)],
    );
  }

  Future<void> seedRelationshipsAttr(
    String attributeId,
    String entityId,
    String value,
    String valueType, {
    String source = 'auto',
  }) async {
    await db.customStatement(
      'INSERT INTO factual_attributes '
      '(attribute_id, entity_id, session_id, attr_key, value, value_type, '
      'importance, source, created_at, updated_turn) '
      "VALUES (?, ?, 's1', 'relationships', ?, ?, 3, ?, '2026-01-02T00:00:00', 5)",
      [attributeId, entityId, value, valueType, source],
    );
  }

  Future<void> seedHistory(
    String attributeId,
    String entityId,
    String? oldValue, {
    String createdAt = '2026-01-03T00:00:00',
  }) async {
    await db.customStatement(
      'INSERT INTO factual_memory_history '
      '(entity_id, attribute_id, action, old_value, new_value, reason, '
      'turn_number, created_at) '
      "VALUES (?, ?, 'update_attr', ?, 'x', '剧情推进', 5, ?)",
      [entityId, attributeId, oldValue, createdAt],
    );
  }

  Future<List<Map<String, Object?>>> attrRows(
    String entityId,
    String attrKey,
  ) async {
    final rows = await db.customSelect(
      'SELECT attribute_id, value, value_type, source FROM factual_attributes '
      "WHERE entity_id = ? AND attr_key = ? AND source = 'auto'",
      variables: [Variable.withString(entityId), Variable.withString(attrKey)],
    ).get();
    return rows.map((r) => r.data).toList();
  }

  test('个人关系拆出 + 群体保留 + 历史与备份留痕', () async {
    await seedEntity('ent_lin', '林舟');
    await seedEntity('ent_su', '苏晴', aliases: const ['小晴']);
    await seedEntity('ent_gu', '顾远');
    await seedRelationshipsAttr(
      'attr_rel',
      'ent_lin',
      '{"苏晴": "信任", "顾远": "戒心", "师门众人": "交恶"}',
      'dict',
    );

    await RelationshipSplitMigration(db).run();

    final dictRows = await attrRows('ent_lin', 'relationships');
    expect(dictRows.length, 1, reason: 'dict 行保留（承载群体关系）');
    expect(dictRows.single['value'], '{"师门众人":"交恶"}');

    final su = await attrRows('ent_lin', 'relationship:苏晴');
    expect(su.single['value'], '信任');
    expect(su.single['value_type'], 'single');
    final gu = await attrRows('ent_lin', 'relationship:顾远');
    expect(gu.single['value'], '戒心');

    // 迁移来源审计：拆分行与 dict 收敛行都有历史
    final history = await db
        .customSelect(
          'SELECT reason FROM factual_memory_history '
          "WHERE reason LIKE '关系拆分迁移%'",
        )
        .get();
    expect(history.length, 3, reason: '两条拆出 + 一条 dict 收敛');

    // 备份表保留原始值
    final backup = await db
        .customSelect(
          'SELECT value FROM factual_relationship_migration_backup '
          "WHERE attribute_id = 'attr_rel'",
        )
        .get();
    expect(
      backup.single.readNullable<String>('value'),
      '{"苏晴": "信任", "顾远": "戒心", "师门众人": "交恶"}',
    );
  });

  test('别名命中也按主名建行', () async {
    await seedEntity('ent_lin', '林舟');
    await seedEntity('ent_su', '苏晴', aliases: const ['小晴']);
    await seedRelationshipsAttr(
      'attr_rel',
      'ent_lin',
      '{"小晴": "青梅竹马"}',
      'dict',
    );

    await RelationshipSplitMigration(db).run();

    expect(
      (await attrRows('ent_lin', 'relationship:苏晴')).single['value'],
      '青梅竹马',
    );
    expect(
      (await attrRows('ent_lin', 'relationships')).single['value'],
      '{}',
    );
  });

  test('损坏 dict（内容为 List）：按历史恢复后再拆分', () async {
    await seedEntity('ent_lin', '林舟');
    await seedEntity('ent_su', '苏晴');
    await seedRelationshipsAttr('attr_rel', 'ent_lin', '["陈默=怀疑"]', 'dict');
    await seedHistory('attr_rel', 'ent_lin', '{"苏晴": "信任"}');

    await RelationshipSplitMigration(db).run();

    final rows = await attrRows('ent_lin', 'relationships');
    expect(rows.single['value'], '{}', reason: '恢复后的个人关系已拆出');
    expect(
      (await attrRows('ent_lin', 'relationship:苏晴')).single['value'],
      '信任',
    );
    final restore = await db
        .customSelect(
          'SELECT COUNT(*) AS c FROM factual_memory_history '
          "WHERE reason LIKE '关系数据损坏修复%'",
        )
        .get();
    expect(restore.first.read<int>('c'), 1);
    // 备份的是损坏原值
    final backup = await db
        .customSelect(
          'SELECT value FROM factual_relationship_migration_backup '
          "WHERE attribute_id = 'attr_rel'",
        )
        .get();
    expect(backup.single.readNullable<String>('value'), '["陈默=怀疑"]');
  });

  test('损坏但无历史证据：保留原值 + 待确认标记，不猜测恢复', () async {
    await seedEntity('ent_lin', '林舟');
    await seedRelationshipsAttr('attr_rel', 'ent_lin', '["陈默=怀疑"]', 'dict');

    await RelationshipSplitMigration(db).run();

    final rows = await attrRows('ent_lin', 'relationships');
    expect(rows.single['value'], '["陈默=怀疑"]', reason: '原样保留');
    final pending = await db
        .customSelect(
          'SELECT COUNT(*) AS c FROM factual_memory_history '
          "WHERE reason LIKE '关系数据待人工确认%'",
        )
        .get();
    expect(pending.first.read<int>('c'), 1);
  });

  test('错型 list 行：数据保留 + 待确认标记', () async {
    await seedEntity('ent_lin', '林舟');
    await seedEntity('ent_su', '苏晴');
    await seedRelationshipsAttr(
      'attr_rel',
      'ent_lin',
      '["与苏晴交好"]',
      'list',
    );

    await RelationshipSplitMigration(db).run();

    final rows = await attrRows('ent_lin', 'relationships');
    expect(rows.single['value'], '["与苏晴交好"]');
    expect(rows.single['value_type'], 'list');
    final pending = await db
        .customSelect(
          'SELECT COUNT(*) AS c FROM factual_memory_history '
          "WHERE reason LIKE '关系数据待人工确认%'",
        )
        .get();
    expect(pending.first.read<int>('c'), 1);
  });

  test('幂等：连续运行两次不重复建行/写标记/写备份', () async {
    await seedEntity('ent_lin', '林舟');
    await seedEntity('ent_su', '苏晴');
    await seedRelationshipsAttr('attr_rel', 'ent_lin', '{"苏晴": "信任"}', 'dict');

    await RelationshipSplitMigration(db).run();
    await RelationshipSplitMigration(db).run();

    expect((await attrRows('ent_lin', 'relationship:苏晴')).length, 1);
    final backup = await db
        .customSelect(
          'SELECT COUNT(*) AS c FROM factual_relationship_migration_backup '
          "WHERE attribute_id = 'attr_rel'",
        )
        .get();
    expect(backup.first.read<int>('c'), 1);
    final history = await db
        .customSelect(
          'SELECT COUNT(*) AS c FROM factual_memory_history '
          "WHERE reason LIKE '关系拆分迁移%'",
        )
        .get();
    expect(
      history.first.read<int>('c'),
      2,
      reason: '一次拆出 + 一次 dict 收敛，二次运行零新增',
    );
  });

  test('只读基线行（source=card）不迁移', () async {
    await seedEntity('ent_lin', '林舟');
    await seedEntity('ent_su', '苏晴');
    await seedRelationshipsAttr(
      'attr_card',
      'ent_lin',
      '{"苏晴": "卡面设定"}',
      'dict',
      source: 'card',
    );

    await RelationshipSplitMigration(db).run();

    final cardRows = await db
        .customSelect(
          'SELECT value FROM factual_attributes '
          "WHERE attribute_id = 'attr_card'",
        )
        .get();
    expect(cardRows.single.readNullable<String>('value'), '{"苏晴": "卡面设定"}');
    expect(await attrRows('ent_lin', 'relationship:苏晴'), isEmpty);
  });
}
