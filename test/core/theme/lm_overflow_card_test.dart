import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/shared/components/lm_overflow_card.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// LmOverflowCard 测试（"限高滚动区看不出能下滑"）
///
/// 覆盖：未溢出零提示、溢出显示「下滑查看更多」pill、pill 点击直达底部
/// 且到底后隐藏、无 label 时只留渐隐。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Widget wrap(Widget child) {
    return TranslationProvider(
      child: MaterialApp(
        theme: ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
        home: Scaffold(body: child),
      ),
    );
  }

  Widget longContent({int lines = 30}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [for (var i = 0; i < lines; i++) Text('行 $i')],
      );

  testWidgets('内容未溢出：不渲染提示 pill，按内容收高', (tester) async {
    await tester.pumpWidget(
      wrap(
        const LmOverflowCard(
          maxHeight: 400,
          scrollHintLabel: '下滑查看更多',
          child: Text('短内容'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('下滑查看更多'), findsNothing);
    expect(find.text('短内容'), findsOneWidget);
  });

  testWidgets('内容溢出：提示 pill 出现；点击直达底部后隐藏且末行进入视口', (tester) async {
    await tester.pumpWidget(
      wrap(
        LmOverflowCard(
          maxHeight: 200,
          scrollHintLabel: '下滑查看更多',
          child: longContent(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 溢出：pill 可见，末行在限高之外
    expect(find.text('下滑查看更多'), findsOneWidget);
    expect(tester.getTopLeft(find.text('行 29')).dy, greaterThan(200));

    // 点击 pill → 直达底部 → pill 隐藏，末行进入限高视口
    await tester.tap(find.text('下滑查看更多'));
    await tester.pumpAndSettle();
    expect(find.text('下滑查看更多'), findsNothing);
    expect(tester.getTopLeft(find.text('行 29')).dy, lessThan(200));
  });

  testWidgets('scrollHintLabel 为 null：只留渐隐，不渲染 pill（滚到底行为不变）', (tester) async {
    await tester.pumpWidget(
      wrap(
        LmOverflowCard(
          maxHeight: 150,
          child: longContent(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('下滑查看更多'), findsNothing);

    // 手动滚动到底：渐隐状态翻转不抛错
    await tester.dragUntilVisible(
      find.text('行 29'),
      find.byType(SingleChildScrollView),
      const Offset(0, -80),
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('行 29')).dy, lessThan(150));
  });

  testWidgets('透明模式（无卡框）：无裁剪框；卡框模式（有底色）带裁剪框', (tester) async {
    await tester.pumpWidget(
      wrap(
        LmOverflowCard(
          maxHeight: 150,
          fadeColor: const Color(0xFF000000),
          child: longContent(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(LmOverflowCard),
        matching: find.byType(ClipRRect),
      ),
      findsNothing,
      reason: '透明模式不得引入卡框（ClipRRect）层',
    );

    await tester.pumpWidget(
      wrap(
        LmOverflowCard(
          maxHeight: 150,
          backgroundColor: const Color(0xFF101010),
          child: longContent(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(LmOverflowCard),
        matching: find.byType(ClipRRect),
      ),
      findsOneWidget,
      reason: '卡框模式应有圆角裁剪框',
    );
  });
}
