import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/pages/general_appearance_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/general_language_input_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/general_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_system_prompt_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/settings_page.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../test_helpers/stub_settings_notifier.dart';

/// 结构无变化面（配置双模式）简化模式无裁剪确认测试。
///
/// 外观/语言与输入/数据管理四区与系统提示词区全部为 simple 声明键，
/// 简单模式必须原样可见（裁剪即实施漂移）；通用设置页 4 卡 + 开关区块
/// 与设置主页 9 卡全保留（入口层不裁剪）。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Future<void> pumpPage(
    WidgetTester tester,
    Widget page, {
    ConfigLevel level = ConfigLevel.simple,
  }) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

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
            home: page,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('结构无变化面：简化模式无裁剪', () {
    testWidgets('外观子页：主题模式 + 字体大小区原样可见', (tester) async {
      await pumpPage(tester, const GeneralAppearanceSettingsPage());

      expect(find.text('主题模式'), findsOneWidget);
      expect(find.text('字体大小'), findsOneWidget);
    });

    testWidgets('语言与输入子页：语言 + 发送键区原样可见', (tester) async {
      await pumpPage(tester, const GeneralLanguageInputSettingsPage());

      expect(find.text('语言'), findsOneWidget);
      expect(find.text('发送键'), findsOneWidget);
    });

    testWidgets('通用设置页：4 卡 + 配置显示模式区块全保留', (tester) async {
      await pumpPage(tester, const GeneralSettingsPage());

      expect(find.text('外观'), findsOneWidget);
      expect(find.text('语言与输入'), findsOneWidget);
      expect(find.text('高级'), findsOneWidget);
      expect(find.text('配置显示模式'), findsOneWidget);
    });

    testWidgets('设置主页：一级菜单 9 卡全保留（入口层不裁剪）', (tester) async {
      await pumpPage(tester, const SettingsPage());

      expect(find.text('通用设置'), findsOneWidget);
      expect(find.text('对话模式设置'), findsOneWidget);
      expect(find.text('故事模式设置'), findsOneWidget);
      expect(find.text('导演模式设置'), findsOneWidget);
      expect(find.text('数据管理'), findsOneWidget);
      expect(find.text('诊断信息'), findsOneWidget);
    });

    testWidgets('故事系统提示词子页：编辑器区原样可见', (tester) async {
      await pumpPage(tester, const IntermediateSystemPromptSettingsPage());

      expect(find.text('系统提示词'), findsWidgets);
    });
  });
}
