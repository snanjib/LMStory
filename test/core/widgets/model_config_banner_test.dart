import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/widgets/model_config_banner.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 「模型未配置」引导横幅壳：三模式宿主注入文案与回调。
///
/// 契约：标题/正文/主操作渲染、主操作回调触发、关闭后组件自持隐藏。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Future<void> pumpBanner(WidgetTester tester, {VoidCallback? onConfigure}) {
    return tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: ModelConfigBanner(
              title: '对话模型未配置',
              message: '发送前需先选择默认模型并配置 API Key',
              actionLabel: '去配置',
              dismissTooltip: '关闭',
              onConfigure: onConfigure ?? () {},
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('渲染标题、正文与主操作按钮', (tester) async {
    await pumpBanner(tester);

    expect(find.text('对话模型未配置'), findsOneWidget);
    expect(find.text('发送前需先选择默认模型并配置 API Key'), findsOneWidget);
    expect(find.text('去配置'), findsOneWidget);
  });

  testWidgets('点击主操作触发回调', (tester) async {
    var fired = 0;
    await pumpBanner(tester, onConfigure: () => fired++);

    await tester.tap(find.text('去配置'));
    expect(fired, 1);
  });

  testWidgets('关闭后隐藏（组件自持，宿主无需介入）', (tester) async {
    await pumpBanner(tester);

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();

    expect(find.text('对话模型未配置'), findsNothing);
    expect(find.text('去配置'), findsNothing);
  });
}
