import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_data.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// R-1 最小落地：Wiki 计数文案上锁
///
/// 三处人工维护的数字曾三处漂移（WK-1/2/3 连续三轮回归）：Wiki 入口数
/// （功能索引 moduleHelpBody「47 个入口」）、术语表条数（glossary
/// projectCount「N 个核心术语」）、Schema 号（版本记录 intro「Schema
/// 为 N」）。本测试对账「文案数字 = 实物数量」，改实物者必须同步文案，
/// 漂移在 CI 即红。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  testWidgets('Wiki 入口数：功能索引宣称数 = buildWikiSections 实际数', (
    tester,
  ) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: const MaterialApp(home: SizedBox()),
      ),
    );
    final context = tester.element(find.byType(SizedBox));
    final sections = buildWikiSections(context);
    final entryCount = sections.fold<int>(
      0,
      (sum, section) => sum + section.entries.length,
    );

    // 功能索引帮助模块正文宣称「N 个入口」——数字必须等于实物
    final claimed = t.help.featureIndex.moduleHelpBody;
    expect(
      claimed,
      contains('$entryCount 个入口'),
      reason: '功能索引 moduleHelpBody 宣称的入口数与 buildWikiSections '
          '实际数（$entryCount）不一致——WK-1 同型漂移回归',
    );
  });

  test('术语表条数：projectCount 宣称数 = 项目组词条实物数', () {
    // projectCount 的口径是「项目组」词条（projectTitle → entryTitle 区间）
    // 全页 38 条含 API/记忆两组。词条在惰性列表里运行时计数受视口影响，
    // 源码区间计数是该文件作为唯一事实源的确定性口径（同
    // agent_skill_reference_test 的源码扫描先例）。
    final source = File(
      'lib/features/help/presentation/pages/glossary_wiki_page.dart',
    ).readAsStringSync();
    final projectStart = source.indexOf('glossary.projectTitle');
    final entryStart = source.indexOf('glossary.entryTitle', projectStart);
    expect(projectStart, greaterThan(0), reason: '项目组标题锚点消失？');
    final projectBlock = source.substring(projectStart, entryStart);
    final termCount = '_TermItem('.allMatches(projectBlock).length;

    expect(
      t.help.glossary.projectCount,
      contains('$termCount 个核心术语'),
      reason:
          '术语表 projectCount 宣称的条数与 GlossaryWikiPage 项目组实际词条数（$termCount）不一致——WK-2 同型漂移回归',
    );
  });

  test('Schema 号：版本记录 intro 宣称数 = drift schemaVersion', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    expect(
      t.help.versionHistory.intro,
      contains('Schema 为 ${db.schemaVersion}'),
      reason:
          '版本记录 intro 宣称的 Schema 号与 AppDatabase.schemaVersion（${db.schemaVersion}）不一致——WK-3 同型漂移回归',
    );
    // 同页 schema 演进图节点曾停在 37-49 而实际已
    // 升 50（的另一半）——intro 与图节点必须同源同值。
    expect(
      t.help.versionHistory.v03Schema,
      contains('37-${db.schemaVersion}'),
      reason:
          '版本记录 schema 演进图节点与 AppDatabase.schemaVersion（${db.schemaVersion}）不一致——intro/图节点双口径漂移回归',
    );
  });

  // helpCount 是第四处人工维护数字
  // （「47 个 Wiki 入口」），此前不在三断言锁内——同型数字必锁。
  testWidgets('Wiki 入口数：helpCount 宣称数 = buildWikiSections 实际数', (
    tester,
  ) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: const MaterialApp(home: SizedBox()),
      ),
    );
    final context = tester.element(find.byType(SizedBox));
    final sections = buildWikiSections(context);
    final entryCount = sections.fold<int>(
      0,
      (sum, section) => sum + section.entries.length,
    );

    expect(
      t.help.featureIndex.helpCount,
      contains('$entryCount 个'),
      reason:
          '功能索引 helpCount 宣称的入口数与 buildWikiSections 实际数（$entryCount）不一致——第四处人工数字上锁',
    );
  });
}
