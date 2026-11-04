import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/presentation/widgets/in_session_search_bar.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// InSessionSearchBar 组件测试
///
/// 受控组件契约：可见性/查询/计数由宿主页持有，本条只渲染与上抛。
/// 产品规范（impeccable product register）：非模态内联、触控 ≥44dp、
/// 计数文案「当前/总数」、无结果态与搜索中态（…）。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Widget buildBar({
    bool visible = true,
    String query = '',
    int matchCount = -1,
    int currentMatch = 0,
    ValueChanged<String>? onQueryChanged,
    VoidCallback? onNext,
    VoidCallback? onPrev,
    VoidCallback? onClose,
  }) {
    return MaterialApp(
      home: TranslationProvider(
        child: Scaffold(
          body: InSessionSearchBar(
            visible: visible,
            query: query,
            matchCount: matchCount,
            currentMatch: currentMatch,
            onQueryChanged: onQueryChanged ?? (_) {},
            onNext: onNext ?? () {},
            onPrev: onPrev ?? () {},
            onClose: onClose ?? () {},
          ),
        ),
      ),
    );
  }

  testWidgets('不可见时零占位（SizedBox.shrink，不占布局）', (tester) async {
    await tester.pumpWidget(buildBar(visible: false));
    expect(find.byType(InSessionSearchBar), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(
      tester.widget<AnimatedSize>(find.byType(AnimatedSize)).child,
      isA<SizedBox>(),
    );
  });

  testWidgets('可见：占位文案/搜索中计数…渲染，导航钮禁用', (tester) async {
    var nextCalls = 0;
    await tester.pumpWidget(buildBar(onNext: () => nextCalls++));

    expect(find.text('搜索会话内容...'), findsOneWidget);
    expect(find.text('…'), findsOneWidget);
    // 三枚导航钮存在（上/下/关闭），无命中时上下两枚禁用
    final enabledIcons = tester
        .widgetList<IconButton>(find.byType(IconButton))
        .where((b) => b.onPressed != null)
        .length;
    expect(enabledIcons, 1, reason: '仅关闭钮可用');
    expect(nextCalls, 0);
  });

  testWidgets('有命中：计数「当前/总数」，导航钮全部可用', (tester) async {
    await tester.pumpWidget(buildBar(matchCount: 17, currentMatch: 3));

    expect(find.text('3/17'), findsOneWidget);
    final enabledIcons = tester
        .widgetList<IconButton>(find.byType(IconButton))
        .where((b) => b.onPressed != null)
        .length;
    expect(enabledIcons, 3);
  });

  testWidgets('无结果：计数区显示「无结果」', (tester) async {
    await tester.pumpWidget(buildBar(matchCount: 0));
    expect(find.text('无结果'), findsOneWidget);
  });

  testWidgets('输入上抛 onQueryChanged；关闭钮上抛 onClose', (tester) async {
    final queries = <String>[];
    var closed = false;
    await tester.pumpWidget(
      buildBar(
        onQueryChanged: queries.add,
        onClose: () => closed = true,
      ),
    );

    await tester.enterText(find.byType(TextField), '古堡');
    expect(queries.last, '古堡');

    await tester.tap(find.byIcon(Icons.close).last);
    expect(closed, isTrue);
  });

  testWidgets('关闭钮与导航钮触控目标 ≥44dp', (tester) async {
    await tester.pumpWidget(buildBar(matchCount: 2));
    for (final button in tester.widgetList<IconButton>(
      find.byType(IconButton),
    )) {
      expect(button.constraints!.minWidth, greaterThanOrEqualTo(44));
      expect(button.constraints!.minHeight, greaterThanOrEqualTo(44));
    }
  });
}
