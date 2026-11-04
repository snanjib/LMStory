import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/theme/appearance_controller.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/pages/general_appearance_settings_page.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../test_helpers/stub_settings_notifier.dart';

/// 外观三轴选择器（主题结构 / 配色 / 日夜）接线测试。
///
/// 选择器 UI 只读 catalog 注册表：选项数=登记数、显示名走 slang 动态键；
/// 切换即写持久化键并保持另一轴不变。桌面交互实测在真机验收清单补做，
/// 此处以 widget 测试锁定接线语义。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Future<Preferences> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({});
    final prefs = Preferences(prefs: await SharedPreferences.getInstance());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsNotifierProvider.overrideWith((ref) {
            return StubSettingsNotifier();
          }),
          configLevelProvider.overrideWith(
            (ref) =>
                ConfigLevelNotifier(prefs, initialValue: ConfigLevel.simple),
          ),
          preferencesProvider.overrideWithValue(prefs),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(splashFactory: InkRipple.splashFactory),
            home: const GeneralAppearanceSettingsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return prefs;
  }

  testWidgets('外观页渲染三轴选择器与字号区，选项数与 catalog 一致', (tester) async {
    await pumpPage(tester);

    expect(find.text('主题'), findsOneWidget);
    expect(find.text('配色'), findsOneWidget);
    expect(find.text('主题模式'), findsOneWidget);
    expect(find.text('字体大小'), findsOneWidget);

    // 「经典」在结构/配色两选择器各渲染一项；两轴新登记项自动出现
    // （catalog 驱动，选择器零 UI 改动即获得琉璃/波尔多）。
    expect(find.text('经典'), findsNWidgets(2));
    expect(find.text('琉璃'), findsOneWidget);
    expect(find.text('波尔多'), findsOneWidget);
  });

  testWidgets('点选结构轴选项写入持久化键且不动配色轴', (tester) async {
    final prefs = await pumpPage(tester);

    final option = find.text('经典').first;
    await tester.tap(option);
    await tester.pump();

    expect(await prefs.getString('appearance_structure'), 'classic');
    expect(await prefs.getString('appearance_palette'), 'classic');
  });

  testWidgets('未注册 id 回退默认组合（选择器只显示已登记项）', (tester) async {
    SharedPreferences.setMockInitialValues({
      'appearance_structure': 'gone',
      'appearance_palette': 'gone',
    });
    final prefs = Preferences(prefs: await SharedPreferences.getInstance());

    final resolved = await AppearanceNotifier.readInitial(prefs);
    expect(resolved.structureId, ThemeCatalog.defaults.structureId);
    expect(resolved.paletteId, ThemeCatalog.defaults.paletteId);
    // 回退后持久化被纠正，重启保持默认组合。
    expect(
      await prefs.getString('appearance_structure'),
      ThemeCatalog.defaults.structureId,
    );
    expect(
      await prefs.getString('appearance_palette'),
      ThemeCatalog.defaults.paletteId,
    );
  });
}
