import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/templates/data/repositories/template_repository_impl.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';

/// TemplateRepositoryImpl 测试
///
/// `consolidation`（折叠模板）类型下架——
/// 编辑不生效（真压缩提示词在故事模式分段自定义）。回退策略 = "保留行
/// 但过滤"：存量行留在库中（数据保全），仓库映射层跳过已移除/未知 kind，
/// 任何列表/读取入口都不可见（死内容不得变活，区别于 CF-7 的
/// suggestReply → systemPrompt 回退）。
void main() {
  late AppDatabase db;
  late TemplateRepositoryImpl repo;

  setUp(() async {
    final nativeDb = NativeDatabase.memory();
    db = AppDatabase.forTesting(nativeDb);
    await db.customSelect('SELECT 1').get();
    repo = TemplateRepositoryImpl(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> insertRawRow(
    String templateId,
    String kind, {
    bool isBuiltIn = false,
  }) async {
    final now = DateTime.now();
    await db.into(db.templatesTable).insert(
          TemplatesTableCompanion.insert(
            templateId: templateId,
            name: 'row-$templateId',
            kind: kind,
            content: 'content-$templateId',
            isBuiltIn: Value(isBuiltIn),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
  }

  group('A1：consolidation 存量行隐藏（保留行但过滤）', () {
    test('getAllTemplates 跳过 consolidation 行，其余照常返回', () async {
      await insertRawRow('legacy-c', 'consolidation');
      await insertRawRow('live-s', 'systemPrompt');

      final templates = await repo.getAllTemplates();

      expect(
        templates.map((t) => t.templateId),
        ['live-s'],
        reason: 'consolidation 行必须对一切列表入口不可见',
      );
      // 数据行本身仍在库中（数据保全，不做物理删除）
      final rawRows = await db.select(db.templatesTable).get();
      expect(rawRows, hasLength(2));
    });

    test('getTemplate 对 consolidation 行按不存在处理（不可编辑/复制/删除）', () async {
      await insertRawRow('legacy-c', 'consolidation');

      expect(
        () => repo.getTemplate('legacy-c'),
        throwsA(isA<ModelNotFoundException>()),
      );
    });

    test('suggestReply（CF-7 旧值）同样隐藏，不再回退 systemPrompt', () async {
      await insertRawRow('legacy-sr', 'suggestReply');
      await insertRawRow('live-s', 'systemPrompt');

      final templates = await repo.getAllTemplates();

      expect(templates.map((t) => t.templateId), ['live-s']);
    });
  });

  group('A1：内置种子不再包含 consolidation 模板', () {
    test('ensureBuiltInTemplates 只种存活类型，无折叠模板条目', () async {
      await repo.ensureBuiltInTemplates();

      final templates = await repo.getAllTemplates();
      expect(templates, isNotEmpty);
      expect(
        templates.every((t) => t.kind == TemplateKind.systemPrompt),
        isTrue,
        reason: '种子模板应全部为系统提示词类型',
      );
      expect(
        templates.any((t) => t.templateId == 'builtin-compaction-default'),
        isFalse,
        reason: 'builtin-compaction-default（死数据）不再种子',
      );
    });
  });

  group('A2：内置模板轮换（v0.4.0 异世界替换无限流/古代穿越）', () {
    test('ensureBuiltInTemplates 种子含异世界叙述者，不含已下架两套', () async {
      await repo.ensureBuiltInTemplates();

      final templates = await repo.getAllTemplates();
      final isekai = templates
          .where((t) => t.templateId == 'builtin-isekai-narrator')
          .toList();
      expect(isekai, hasLength(1), reason: 'v0.4.0 新增异世界穿越叙述者种子');
      expect(isekai.single.isBuiltIn, isTrue);
      expect(isekai.single.name, '异世界穿越叙述者系统提示词');
      expect(
        templates.any((t) => t.templateId == 'builtin-infinite-flow-narrator'),
        isFalse,
      );
      expect(
        templates.any(
          (t) => t.templateId == 'builtin-ancient-transmigration-narrator',
        ),
        isFalse,
      );
    });

    test('老用户库中已下架内置模板的存量行被物理删除', () async {
      // 模拟 v0.2 升级前已种下的两套内置行
      await insertRawRow(
        'builtin-infinite-flow-narrator',
        'systemPrompt',
        isBuiltIn: true,
      );
      await insertRawRow(
        'builtin-ancient-transmigration-narrator',
        'systemPrompt',
        isBuiltIn: true,
      );

      await repo.ensureBuiltInTemplates();

      final templates = await repo.getAllTemplates();
      expect(
        templates.any((t) => t.templateId == 'builtin-infinite-flow-narrator'),
        isFalse,
        reason: '内置行由应用全权管理，只从种子移除会留下不可删除的僵尸条目',
      );
      expect(
        templates.any(
          (t) => t.templateId == 'builtin-ancient-transmigration-narrator',
        ),
        isFalse,
      );
    });

    test('同 id 但 isBuiltIn=false 的用户行不受清理影响', () async {
      await insertRawRow(
        'builtin-infinite-flow-narrator',
        'systemPrompt',
      );

      await repo.ensureBuiltInTemplates();

      expect(
        (await repo.getAllTemplates())
            .any((t) => t.templateId == 'builtin-infinite-flow-narrator'),
        isTrue,
        reason: '清理只针对 isBuiltIn=true 的行，用户数据保全',
      );
    });
  });
}
