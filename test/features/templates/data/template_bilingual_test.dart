import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/templates/data/repositories/template_repository_impl.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/features/templates/presentation/support/template_l10n.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:lmstory/i18n/strings_en_US.g.dart';

/// 内置模板双语（templates.name_en/content_en，schemaVersion 53）
///
/// 钉死四链：
/// - 新装含列；v52 旧库（无列）升级补列且既有模板行保留；
/// - ensureBuiltIn 启动刷新给老库内置行回填英文名/正文（用户副本行不碰）；
/// - en 界面显示与运行时消费走英文版，zh 回退中文；
/// - 前三个模板正文本就是英文 → contentEn 留空走基础值回退（同一表现）。
void main() {
  late AppDatabase db;
  late TemplateRepositoryImpl repo;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    repo = TemplateRepositoryImpl(db);
  });

  tearDown(() async => db.close());

  Future<bool> hasEnColumns(AppDatabase database) async {
    final cols =
        await database.customSelect('PRAGMA table_info(templates)').get();
    final names = cols.map((r) => r.read<String>('name')).toSet();
    return names.containsAll(const {'name_en', 'content_en'});
  }

  test('新装：templates 含 name_en/content_en 列', () async {
    expect(await hasEnColumns(db), isTrue);
  });

  test('v52 旧库升级：补列且既有模板行保留', () async {
    final dir = Directory.systemTemp.createTempSync('lmstory_tpl_v52');
    final file = File('${dir.path}/old.db');

    final db1 = AppDatabase.forTesting(NativeDatabase(file));
    await db1.customSelect('SELECT 1').get();
    final created = await TemplateRepositoryImpl(db1).createTemplate(
      name: '用户的模板',
      kind: TemplateKind.systemPrompt,
      content: 'x',
    );
    await db1.close();

    final db2 = AppDatabase.forTesting(
      NativeDatabase(
        file,
        setup: (raw) {
          raw
            ..execute('ALTER TABLE templates DROP COLUMN name_en')
            ..execute('ALTER TABLE templates DROP COLUMN content_en')
            ..execute('PRAGMA user_version = 52');
        },
      ),
    );
    await db2.customSelect('SELECT 1').get();

    expect(await hasEnColumns(db2), isTrue, reason: 'onUpgrade 增量补列');
    final kept =
        await TemplateRepositoryImpl(db2).getTemplate(created.templateId);
    expect(kept.name, '用户的模板', reason: '升级不丢既有模板');
    await db2.close();
  });

  test('ensureBuiltIn 回填：老库内置行获得英文名/异世界英文正文，副本行不碰', () async {
    // 老库形态：内置行没有英文列值（列刚补上，全 NULL）
    await repo.ensureBuiltInTemplates();
    await db.customStatement(
      'UPDATE templates SET name_en = NULL, content_en = NULL '
      'WHERE is_built_in = 1',
    );

    await repo.ensureBuiltInTemplates();

    final isekai = await repo.getTemplate('builtin-isekai-narrator');
    expect(isekai.nameEn, 'Isekai narrator system prompt');
    expect(isekai.contentEn, contains('third-person omniscient narrator'));
    final narrative = await repo.getTemplate('builtin-narrative-engine');
    expect(narrative.nameEn, 'Narrative engine system prompt');
    // 正文与导演模式默认项目规则同源（中文），英文版走 contentEn
    expect(narrative.content, contains('叙事引擎与主持人'));
    expect(narrative.contentEn, contains('narrative engine and host'));
  });

  test('显示与消费本地化：en 走英文版，zh 回退基础值', () async {
    await repo.ensureBuiltInTemplates();
    final isekai = await repo.getTemplate('builtin-isekai-narrator');

    final en = TranslationsEnUs();
    final zh = Translations();

    expect(isekai.localizedName(en), 'Isekai narrator system prompt');
    expect(isekai.localizedContent(en), contains('omniscient'));
    expect(isekai.localizedName(zh), '异世界穿越叙述者系统提示词');
    expect(isekai.localizedContent(zh), contains('第三人称全知叙述者'));

    // 无英文版的模板（用户副本）恒回退基础值
    final custom = await repo.createTemplate(
      name: '我的模板',
      kind: TemplateKind.systemPrompt,
      content: '自定义内容',
    );
    expect(custom.localizedName(en), '我的模板');
    expect(custom.localizedContent(en), '自定义内容');
  });
}
