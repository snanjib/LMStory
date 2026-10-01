import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/settings/data/repositories/backup_repository_impl.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';

/// importSessionData 的 factual_fts 重建测试
///
/// 导出不含 factual_fts、覆盖导入会清空它、而世界书重应用的同名去重
/// 跳过堵死自救路径——导入后世界书关键词召回静默失效。修复：导入事务
/// 内按恢复行重建该会话的 worldbook 词条索引。
void main() {
  late AppDatabase db;
  late BackupRepositoryImpl repo;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    repo = BackupRepositoryImpl(database: db);
  });

  tearDown(() async {
    await db.close();
  });

  test('导入会话后按恢复行重建 factual_fts（worldbook 词条）', () async {
    final inserted = await repo.importSessionData(
      {
        'session': {
          'session_id': 's1',
          'title': '导入的会话',
        },
        'messages': [
          {
            'message_id': 'm1',
            'session_id': 's1',
            'role': 'user',
            'content': '你好',
          },
        ],
        'factualEntities': [
          {
            'entity_id': 'ent_wb',
            'session_id': 's1',
            'type': 'lore',
            'primary_name': '魔法体系',
            'aliases': '["法术","咒文"]',
            'importance': 2,
            'created_turn': 0,
            'source': 'worldbook',
          },
          {
            'entity_id': 'ent_auto',
            'session_id': 's1',
            'type': 'character',
            'primary_name': '路人甲',
            'aliases': '[]',
            'importance': 3,
            'created_turn': 0,
            'source': 'auto',
          },
        ],
        'factualAttributes': [
          {
            'attribute_id': 'attr1',
            'entity_id': 'ent_wb',
            'session_id': 's1',
            'attr_key': 'description',
            'value': '以元素为核心的魔法体系',
          },
        ],
      },
      mode: ImportMode.append,
    );

    expect(inserted, 1);

    // FF6 不变量（2026-09-09 审查）：索引以落库行为准——此前按备份 JSON
    // 建索引，实体行因缺 NOT NULL 列被 INSERT OR IGNORE 跳过时，索引会
    // 指向不存在的实体。夹具必须让实体真正落库。
    final entityRows = await db.customSelect(
      'SELECT entity_id FROM factual_entities WHERE session_id = ?',
      variables: [Variable.withString('s1')],
    ).get();
    expect(
      entityRows.map((r) => r.read<String>('entity_id')).toSet(),
      {'ent_wb', 'ent_auto'},
      reason: '实体行必须真正落库（否则重建索引为空是正确行为）',
    );

    // customSelect variables 传参：drift 需要 Variable 包装，这里直接读全表过滤
    final all = await db
        .customSelect(
          'SELECT primary_name, aliases, description, entity_id, session_id '
          'FROM factual_fts',
        )
        .get();
    final s1Rows =
        all.where((r) => r.read<String>('session_id') == 's1').toList();
    expect(
      s1Rows.map((r) => r.read<String>('entity_id')),
      ['ent_wb'],
      reason: '只有 worldbook 词条重建索引（与投影写侧口径一致），auto 不建',
    );
    final fts = s1Rows.single;
    expect(fts.read<String>('primary_name'), '魔法体系');
    expect(
      fts.read<String>('aliases'),
      '法术 咒文',
      reason: 'aliases JSON 数组解为空格拼接（FTS 口径）',
    );
    expect(fts.read<String>('description'), '以元素为核心的魔法体系');
  });
}
