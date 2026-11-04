import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_recap_card.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 幕间 Recap 卡测试（体验重构卡片 C §4.3.7）
///
/// 验证：一行书脊形态、点击展开锚详情、无编辑入口。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Widget wrap(Widget child) {
    return TranslationProvider(
      child: MaterialApp(
        theme: ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
        home: Scaffold(body: ListView(children: [child])),
      ),
    );
  }

  const anchor = StoryAnchor(
    updatedTurn: 3,
    arc: '古碑遗迹的真相',
    narrativeTime: '第三天黄昏',
    oneLiner: '主角进入古碑遗迹',
    foreshadows: [
      AnchorForeshadow(text: '守碑人的身份'),
      AnchorForeshadow(text: '左手的旧伤', resolved: true),
    ],
  );

  testWidgets('1. 书脊一行：第 N 幕 · 叙事时间 · 一句主线', (tester) async {
    await tester
        .pumpWidget(wrap(const DirectorRecapCard(act: 3, anchor: anchor)));

    expect(find.text('第 3 幕 · 第三天黄昏 · 主角进入古碑遗迹'), findsOneWidget);
    // 展开内容不可见
    expect(find.text('当前弧线：古碑遗迹的真相'), findsNothing);
  });

  testWidgets('2. 点击展开锚详情（弧线+伏笔清单）', (tester) async {
    await tester
        .pumpWidget(wrap(const DirectorRecapCard(act: 3, anchor: anchor)));
    await tester.tap(find.text('第 3 幕 · 第三天黄昏 · 主角进入古碑遗迹'));
    await tester.pumpAndSettle();

    expect(find.text('当前弧线：古碑遗迹的真相'), findsOneWidget);
    expect(find.text('待兑现伏笔'), findsOneWidget);
    expect(find.text('· 守碑人的身份'), findsOneWidget);
    expect(find.text('已兑现'), findsOneWidget);
  });

  testWidgets('3. 无编辑入口：展开态不含任何可编辑控件', (tester) async {
    await tester
        .pumpWidget(wrap(const DirectorRecapCard(act: 3, anchor: anchor)));
    await tester.tap(find.text('第 3 幕 · 第三天黄昏 · 主角进入古碑遗迹'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNothing);
    expect(find.byType(IconButton), findsNothing);
    expect(find.byType(ElevatedButton), findsNothing);
    expect(find.text('编辑'), findsNothing);
  });

  testWidgets('4. G-22：提供 onEditAnchor 时展开区出现编辑入口，点击开编辑 sheet', (
    tester,
  ) async {
    StoryAnchor? edited;
    await tester.pumpWidget(
      wrap(
        DirectorRecapCard(
          act: 3,
          anchor: anchor,
          onEditAnchor: (value) => edited = value,
        ),
      ),
    );
    await tester.tap(find.text('第 3 幕 · 第三天黄昏 · 主角进入古碑遗迹'));
    await tester.pumpAndSettle();

    expect(find.text('编辑'), findsOneWidget);

    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    // 编辑 sheet 打开且弧线字段预填
    expect(find.text('编辑剧情锚'), findsOneWidget);
    expect(find.widgetWithText(TextField, '古碑遗迹的真相'), findsOneWidget);

    // 改弧线后保存：回调携带新锚（伏笔/时间/oneLiner 原样保留）
    await tester.enterText(
      find.widgetWithText(TextField, '古碑遗迹的真相'),
      '新的弧线',
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(edited, isNotNull);
    expect(edited!.arc, '新的弧线');
    expect(edited!.narrativeTime, '第三天黄昏');
    expect(edited!.oneLiner, '主角进入古碑遗迹');
    expect(edited!.foreshadows, hasLength(2));
    expect(edited!.updatedTurn, 3);
  });

  testWidgets('5. G-23：伏笔超 8 条可展开全部/收起', (tester) async {
    final many = StoryAnchor(
      updatedTurn: 3,
      arc: '长线',
      foreshadows: [
        for (var i = 1; i <= 10; i++) AnchorForeshadow(text: '伏笔 $i'),
      ],
    );
    await tester.pumpWidget(wrap(DirectorRecapCard(act: 3, anchor: many)));
    await tester.tap(find.text('第 3 幕'));
    await tester.pumpAndSettle();

    // 默认前 8 条 + 展开入口
    expect(find.text('· 伏笔 8'), findsOneWidget);
    expect(find.text('· 伏笔 9'), findsNothing);
    expect(find.text('展开其余 2 条'), findsOneWidget);

    await tester.tap(find.text('展开其余 2 条'));
    await tester.pumpAndSettle();
    expect(find.text('· 伏笔 9'), findsOneWidget);
    expect(find.text('· 伏笔 10'), findsOneWidget);
    expect(find.text('收起'), findsOneWidget);

    await tester.tap(find.text('收起'));
    await tester.pumpAndSettle();
    expect(find.text('· 伏笔 10'), findsNothing);
    expect(find.text('展开其余 2 条'), findsOneWidget);
  });
}
