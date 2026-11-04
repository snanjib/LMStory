import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/pages/chat_settings_page.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../test_helpers/stub_settings_notifier.dart';

/// ChatSettingsPage 配置显示模式过滤测试。
///
/// 简单模式保留默认模型 + 显示偏好（四类②与阅读体验族），
/// 采样参数/自动压缩仅进阶模式渲染；进阶模式四区全量 = 现状基线。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Future<void> pumpPage(
    WidgetTester tester, {
    required ConfigLevel level,
  }) async {
    // 四区内容较长，默认 800x600 视口下 ListView 懒构建会裁掉下折区段，
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

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsNotifierProvider.overrideWith((ref) {
            return StubSettingsNotifier();
          }),
          configLevelProvider.overrideWith(
            (ref) => ConfigLevelNotifier(prefs, initialValue: level),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(splashFactory: InkRipple.splashFactory),
            home: const ChatSettingsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('ChatSettingsPage 配置显示模式过滤', () {
    testWidgets('1. 简单模式：默认模型 + 显示偏好保留，采样参数/压缩隐藏', (tester) async {
      await pumpPage(tester, level: ConfigLevel.simple);

      expect(find.text('默认模型'), findsOneWidget);
      expect(find.text('显示时间戳'), findsOneWidget);
      expect(find.text('新对话默认生成参数'), findsNothing);
      expect(find.text('自动压缩'), findsNothing);
    });

    testWidgets('2. 进阶模式：四区全量渲染', (tester) async {
      await pumpPage(tester, level: ConfigLevel.advanced);

      expect(find.text('默认模型'), findsOneWidget);
      expect(find.text('新对话默认生成参数'), findsOneWidget);
      expect(find.text('自动压缩'), findsOneWidget);
      expect(find.text('显示时间戳'), findsOneWidget);
    });

    testWidgets('3. 简单模式切进阶：provider 更新即时生效（页面重建出全量区块）', (tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      SharedPreferences.setMockInitialValues({});
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
                (ref) => ConfigLevelNotifier(prefs),
              ),
            ],
          ),
          child: TranslationProvider(
            child: const MaterialApp(home: ChatSettingsPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('自动压缩'), findsNothing);

      await container
          .read(configLevelProvider.notifier)
          .setLevel(ConfigLevel.advanced);
      await tester.pumpAndSettle();

      expect(find.text('自动压缩'), findsOneWidget);
      expect(find.text('新对话默认生成参数'), findsOneWidget);
      // 已隐藏区的既有值不受模式切换影响（provider 状态保持）
      expect(
        container.read(settingsNotifierProvider).autoCompaction,
        isTrue,
      );
    });
  });
}
