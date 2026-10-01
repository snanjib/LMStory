import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/pages/general_advanced_settings_page.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../test_helpers/stub_settings_notifier.dart';

/// GeneralAdvancedSettingsPage 配置显示模式过滤测试。
///
/// 简单模式保留默认思考预算（成本旋钮），超时/会话标题模型
/// 仅进阶模式渲染；进阶模式三区全量 = 现状基线。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Future<ProviderContainer> pumpPage(
    WidgetTester tester, {
    required ConfigLevel level,
  }) async {
    // 三区内容较长，默认视口下 ListView 懒构建会裁掉下折区段，
    // 导致 find 落空；改用手机尺寸视口让全部区块入树。
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // mock 持久化值与 initialValue 一致，notifier _load 兜底重读不回跳。
    SharedPreferences.setMockInitialValues({
      if (level == ConfigLevel.advanced)
        ConfigLevelNotifier.prefKey: 'advanced',
    });
    final prefs = Preferences(prefs: await SharedPreferences.getInstance());

    late ProviderContainer container;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container = ProviderContainer(
          overrides: [
            settingsNotifierProvider.overrideWith((ref) {
              return StubSettingsNotifier();
            }),
            configLevelProvider.overrideWith(
              (ref) => ConfigLevelNotifier(prefs, initialValue: level),
            ),
          ],
        ),
        child: TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(splashFactory: InkRipple.splashFactory),
            home: const GeneralAdvancedSettingsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  group('GeneralAdvancedSettingsPage 配置显示模式过滤', () {
    testWidgets('1. 简单模式：仅默认思考预算保留，超时/标题模型隐藏', (tester) async {
      await pumpPage(tester, level: ConfigLevel.simple);

      expect(find.text('默认思考预算'), findsOneWidget);
      expect(find.text('超时设置'), findsNothing);
      expect(find.text('会话标题模型'), findsNothing);
    });

    testWidgets('2. 进阶模式：三区全量渲染', (tester) async {
      await pumpPage(tester, level: ConfigLevel.advanced);

      expect(find.text('默认思考预算'), findsOneWidget);
      expect(find.text('超时设置'), findsOneWidget);
      // 区标题与内部行标签同文案，至少一次即整区在树。
      expect(find.text('会话标题模型'), findsWidgets);
    });

    testWidgets('3. 简单模式切进阶：provider 更新即时生效（页面重建出全量区块）', (tester) async {
      final container = await pumpPage(tester, level: ConfigLevel.simple);

      expect(find.text('超时设置'), findsNothing);

      await container
          .read(configLevelProvider.notifier)
          .setLevel(ConfigLevel.advanced);
      await tester.pumpAndSettle();

      expect(find.text('超时设置'), findsOneWidget);
      expect(find.text('会话标题模型'), findsWidgets);
    });
  });
}
