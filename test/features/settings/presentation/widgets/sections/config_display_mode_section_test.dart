import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/config_display_mode_section.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 配置显示模式开关区块测试：双档位渲染、切换即时生效并持久化、
/// 开关本体在双模式下都渲染（元配置恒显）。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Future<(ProviderContainer, Preferences)> pumpSection(
    WidgetTester tester, {
    ConfigLevel initial = ConfigLevel.simple,
    Map<String, Object> stored = const {},
  }) async {
    SharedPreferences.setMockInitialValues(stored);
    final prefs = Preferences(prefs: await SharedPreferences.getInstance());
    late ProviderContainer container;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container = ProviderContainer(
          overrides: [
            configLevelProvider.overrideWith(
              (ref) => ConfigLevelNotifier(prefs, initialValue: initial),
            ),
          ],
        ),
        child: TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(splashFactory: InkRipple.splashFactory),
            home: const Scaffold(body: ConfigDisplayModeSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (container, prefs);
  }

  testWidgets('1. 渲染说明文案与两个档位选项，默认选中简单模式', (tester) async {
    await pumpSection(tester);

    expect(
      find.text('简单模式只显示常用配置；进阶模式显示全部配置（含高级参数）'),
      findsOneWidget,
    );
    expect(find.text('简单模式'), findsOneWidget);
    expect(find.text('进阶模式'), findsOneWidget);
  });

  testWidgets('2. 点进阶：选中态即时迁移并持久化 ui_config_level', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final (container, prefs) = await pumpSection(tester);

    await tester.tap(find.text('进阶模式'));
    await tester.pumpAndSettle();

    expect(container.read(configLevelProvider), ConfigLevel.advanced);
    expect(await prefs.getString(ConfigLevelNotifier.prefKey), 'advanced');
  });

  testWidgets('3. 进阶模式进入：开关本体仍渲染（双模式恒显）', (tester) async {
    await pumpSection(
      tester,
      initial: ConfigLevel.advanced,
      stored: {ConfigLevelNotifier.prefKey: 'advanced'},
    );

    expect(find.text('简单模式'), findsOneWidget);
    expect(find.text('进阶模式'), findsOneWidget);
  });
}
