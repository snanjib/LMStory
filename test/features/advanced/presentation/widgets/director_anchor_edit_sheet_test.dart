import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_anchor_edit_sheet.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 剧情锚编辑 sheet 测试
///
/// 字段预填/伏笔增删改与兑现切换/清空字段语义（null 而非保留）/取消。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

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

  Future<void> pumpSheet(
    WidgetTester tester, {
    void Function(StoryAnchor?)? onResult,
  }) {
    return tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  onPressed: () async {
                    final result = await DirectorAnchorEditSheet.show(
                      context,
                      anchor,
                    );
                    onResult?.call(result);
                  },
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('字段预填：弧线/叙事时间/伏笔行', (tester) async {
    await pumpSheet(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, '古碑遗迹的真相'), findsOneWidget);
    expect(find.widgetWithText(TextField, '第三天黄昏'), findsOneWidget);
    expect(find.widgetWithText(TextField, '守碑人的身份'), findsOneWidget);
    expect(find.widgetWithText(TextField, '左手的旧伤'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
  });

  testWidgets('伏笔增删与兑现切换 + 保存构造新锚（全量清单语义）', (tester) async {
    StoryAnchor? result;
    await pumpSheet(tester, onResult: (v) => result = v);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 切换第一条伏笔为已兑现
    await tester.tap(find.byKey(const ValueKey('anchor-edit-resolved-0')));
    await tester.pump();

    // 删除第二条（已兑现的旧伤）
    await tester.tap(find.byKey(const ValueKey('anchor-edit-remove-1')));
    await tester.pump();
    expect(find.widgetWithText(TextField, '左手的旧伤'), findsNothing);

    // 新增一条伏笔（末位字段即新增行）
    await tester.tap(find.byKey(const ValueKey('anchor-edit-add')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey('anchor-edit-foreshadow-1')),
      '新埋的伏笔',
    );

    // 改叙事时间
    await tester.enterText(
      find.widgetWithText(TextField, '第三天黄昏'),
      '第四夜',
    );

    await tester.tap(find.byKey(const ValueKey('anchor-edit-save')));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.arc, '古碑遗迹的真相');
    expect(result!.narrativeTime, '第四夜');
    expect(result!.oneLiner, '主角进入古碑遗迹');
    expect(result!.updatedTurn, 3);
    expect(result!.foreshadows, hasLength(2));
    expect(result!.foreshadows[0].text, '守碑人的身份');
    expect(result!.foreshadows[0].resolved, isTrue);
    expect(result!.foreshadows[1].text, '新埋的伏笔');
    expect(result!.foreshadows[1].resolved, isFalse);
  });

  testWidgets('清空弧线=清除字段（null 而非保留旧值）', (tester) async {
    StoryAnchor? result;
    await pumpSheet(tester, onResult: (v) => result = v);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, '古碑遗迹的真相'),
      '',
    );
    await tester.tap(find.byKey(const ValueKey('anchor-edit-save')));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.arc, isNull);
    expect(result!.oneLiner, '主角进入古碑遗迹');
  });

  testWidgets('取消：sheet 关闭不保存（结果为 null）', (tester) async {
    StoryAnchor? result;
    await pumpSheet(tester, onResult: (v) => result = v);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, '古碑遗迹的真相'),
      '被放弃的修改',
    );
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.text('编辑剧情锚'), findsNothing);
  });
}
