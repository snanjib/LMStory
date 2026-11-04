import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/config_visibility.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/widgets/advanced_level_hint.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_generation_settings_page.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 简单模式页尾进阶引导行：显隐单源 surfaceHasAdvancedEntries。
///
/// 三态：简单+含进阶键的面显示；进阶模式恒不显示；无进阶键的面
/// 简单模式也不显示（无收起内容不引导）。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('surfaceHasAdvancedEntries 判定矩阵', () {
    test('含 advanced 级声明键的面为 true', () {
      const advancedSurfaces = [
        ConfigVisibilitySurfaces.chatSettings,
        ConfigVisibilitySurfaces.generalAdvanced,
        ConfigVisibilitySurfaces.storyHub,
        ConfigVisibilitySurfaces.storyGeneration,
        ConfigVisibilitySurfaces.director,
        ConfigVisibilitySurfaces.chatPanel,
        ConfigVisibilitySurfaces.storyPanel,
        ConfigVisibilitySurfaces.directorPanel,
      ];
      for (final surface in advancedSurfaces) {
        expect(
          ConfigVisibility.surfaceHasAdvancedEntries(surface),
          isTrue,
          reason: '面 $surface 应含 advanced 级声明键',
        );
      }
    });

    test('全 simple 面、空声明面与未声明面为 false', () {
      const simpleSurfaces = [
        ConfigVisibilitySurfaces.storyModels,
        ConfigVisibilitySurfaces.appearance,
        ConfigVisibilitySurfaces.home,
      ];
      for (final surface in simpleSurfaces) {
        expect(
          ConfigVisibility.surfaceHasAdvancedEntries(surface),
          isFalse,
          reason: '面 $surface 无 advanced 级声明键',
        );
      }
      expect(
        ConfigVisibility.surfaceHasAdvancedEntries('not.a.surface'),
        isFalse,
      );
    });
  });

  Future<ProviderContainer> pumpWithLevel(
    WidgetTester tester, {
    required ConfigLevel level,
    required Widget home,
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

    final container = ProviderContainer(
      overrides: [
        intermediateConfigProvider
            .overrideWith((ref) async => const IntermediateConfig()),
        settingsRepositoryProvider.overrideWithValue(
          _NoopSettingsRepository(),
        ),
        configLevelProvider.overrideWith(
          (ref) => ConfigLevelNotifier(prefs, initialValue: level),
        ),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(home: home),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  const hintZh = '更多配置：设置 → 通用设置 → 配置显示模式 → 进阶模式';

  group('AdvancedLevelHint 组件三态', () {
    testWidgets('简单模式 × 含进阶键面：显示引导行', (tester) async {
      await pumpWithLevel(
        tester,
        level: ConfigLevel.simple,
        home: const IntermediateGenerationSettingsPage(),
      );
      expect(find.text(hintZh), findsOneWidget);
    });

    testWidgets('进阶模式 × 含进阶键面：不显示', (tester) async {
      await pumpWithLevel(
        tester,
        level: ConfigLevel.advanced,
        home: const IntermediateGenerationSettingsPage(),
      );
      expect(find.text(hintZh), findsNothing);
    });

    testWidgets('简单模式 × 无进阶键面：不显示', (tester) async {
      await pumpWithLevel(
        tester,
        level: ConfigLevel.simple,
        home: const Scaffold(
          body: AdvancedLevelHint(
            surfaceId: ConfigVisibilitySurfaces.storyModels,
          ),
        ),
      );
      expect(find.text(hintZh), findsNothing);
      expect(
        find.byType(AdvancedLevelHint),
        paintsNothing,
        reason: '无 advanced 级声明键的面渲染为 SizedBox.shrink',
      );
    });
  });
}

class _NoopSettingsRepository implements SettingsRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}
