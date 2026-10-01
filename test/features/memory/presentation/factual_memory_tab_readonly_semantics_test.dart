import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/intermediate/components/factual_memory_tab.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../../helpers/fake_factual_repository.dart';

/// （只读语义 2.0）记忆库可见性回归测试：
/// - 属性行级徽标：同键双行时基线行标「基线」、auto 演变行标「演变」；
///   纯 auto 实体（无基线行）的行无徽标
/// - 新增属性守卫翻转：只读实体也可新增属性（打开对话框而非只读提示），
///   落库 source 显式为 auto（手动新增也是「演变/生长」）
/// - 编辑基线行仍被拦截（只读提示，不打开编辑对话框）
///
/// 搭法沿用 factual_memory_tab_injection_wiring_test 的 pump 范式
/// （定时 pump，勿用 pumpAndSettle——无限动画会挂死）。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  FactualEntity entity(
    String id,
    String name, {
    FactualSource source = FactualSource.auto,
  }) =>
      FactualEntity(
        entityId: id,
        sessionId: 's1',
        type: FactualEntityType.character,
        primaryName: name,
        aliases: const [],
        importance: 3,
        createdTurn: 1,
        createdAt: DateTime(2026),
        source: source,
      );

  FactualAttribute attr(
    String id,
    String entityId,
    String key,
    FactualSource source, {
    int importance = 3,
  }) =>
      FactualAttribute(
        attributeId: id,
        entityId: entityId,
        sessionId: 's1',
        attrKey: key,
        value: '$key 的值',
        importance: importance,
        createdAt: DateTime(2026),
        source: source,
      );

  Future<void> pumpTab(WidgetTester tester, FakeFactualRepository repo) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: ProviderScope(
          overrides: [factualRepositoryProvider.overrideWithValue(repo)],
          child: MaterialApp(
            theme:
                ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
            home: const Scaffold(
              body: FactualMemoryTab(sessionId: 's1'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// 展开实体卡（属性行与「新增属性」按钮仅在展开态渲染）
  Future<void> expandEntity(WidgetTester tester, String name) async {
    await tester.tap(find.text(name));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('同键双行：基线行标「基线」、auto 行标「演变」；纯 auto 实体无徽标', (tester) async {
    // e1：background 同键双行（基线 + auto 演变）+ 纯 auto 的 mood 行；
    // e2：纯 auto 实体
    final repo = FakeFactualRepository()
      ..entitiesById = {
        'e1': entity('e1', '角色卡种子', source: FactualSource.card),
        'e2': entity('e2', '自动角色'),
      }
      ..seedAttribute(attr('a1', 'e1', 'background', FactualSource.card))
      ..seedAttribute(attr('a2', 'e1', 'background', FactualSource.auto))
      ..seedAttribute(attr('a3', 'e1', 'mood', FactualSource.auto))
      ..seedAttribute(attr('b1', 'e2', 'mood', FactualSource.auto));
    await pumpTab(tester, repo);

    expect(find.text('基线'), findsNothing, reason: '未展开前属性区不渲染');
    await expandEntity(tester, '角色卡种子');
    await expandEntity(tester, '自动角色');

    // e1：基线行 1 枚「基线」徽标；auto 演变行 1 枚「演变」徽标
    // （mood 行的键不在基线键集合内，无徽标——总数即各一）
    expect(find.text('基线'), findsOneWidget);
    expect(find.text('演变'), findsOneWidget);
    expect(
      find.byIcon(Icons.lock_outline),
      findsOneWidget,
      reason: '「基线」徽标带锁形图标',
    );
  });

  testWidgets('只读实体新增属性放行：打开对话框而非只读提示，落库 source=auto', (tester) async {
    final repo = FakeFactualRepository()
      ..entitiesById = {
        'e1': entity('e1', '世界书词条', source: FactualSource.worldbook),
      }
      ..seedAttribute(attr('a1', 'e1', 'background', FactualSource.worldbook));
    await pumpTab(tester, repo);
    await expandEntity(tester, '世界书词条');

    //  守卫翻转：此前此处直接吃只读提示，对话框打不开
    await tester.tap(find.text('新增属性'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // 对话框入场
    expect(
      find.text(t.intermediate.memoryBrowser.readonlyHint),
      findsNothing,
      reason: '新增属性不再看实体 source，不应出只读提示',
    );
    expect(find.text('属性值'), findsOneWidget, reason: '编辑对话框已打开');

    // 填值保存（新增非自定义模式：对话框内值输入框是唯一 TextField；
    // 记忆库顶栏另有搜索框，须限定在 AlertDialog 内查找）
    final valueField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(valueField, '温和');
    await tester.tap(find.text('保存'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300)); // 对话框退场
    await tester.pump(const Duration(milliseconds: 100)); // 落库 + 刷新

    expect(repo.createdAttributes, hasLength(1));
    expect(
      repo.createdAttributes.single.source,
      FactualSource.auto,
      reason: '手动新增行没有基线语义，必须落 auto',
    );
    expect(find.text('已保存'), findsOneWidget);
  });

  testWidgets('编辑基线行仍被拦截：只读提示，不打开编辑对话框', (tester) async {
    final repo = FakeFactualRepository()
      ..entitiesById = {
        'e1': entity('e1', '世界书词条', source: FactualSource.worldbook),
      }
      ..seedAttribute(attr('a1', 'e1', 'background', FactualSource.worldbook));
    await pumpTab(tester, repo);
    await expandEntity(tester, '世界书词条');

    await tester.tap(find.byIcon(Icons.edit_outlined).first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.text(t.intermediate.memoryBrowser.readonlyHint),
      findsOneWidget,
    );
    expect(find.text('编辑属性'), findsNothing, reason: '基线行不可编辑');
    expect(repo.createdAttributes, isEmpty);
  });
}
