import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_models_settings_page.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// IntermediateModelsSettingsPage 配置显示模式过滤测试。
///
/// 简单模式保留分步骤模型区（四类②）与嵌入模型区（两模式
/// 基本需要，划 simple），reasoning 提示卡（所指审查开关在简单模式
/// 不可见）隐藏；进阶模式全量 = 现状基线。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Future<ProviderContainer> pumpPage(
    WidgetTester tester, {
    required ConfigLevel level,
  }) async {
    // 三段内容较长，默认视口下 ListView 懒构建会裁掉下折区段，
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

    final container = ProviderContainer(
      overrides: [
        intermediateConfigProvider
            .overrideWith((ref) async => const IntermediateConfig()),
        settingsRepositoryProvider.overrideWithValue(
          // 模型子页仅读展示，stub 空实现即可（同枢纽页测试的空仓库口径）。
          _NoopSettingsRepository(),
        ),
        apiPresetRepositoryProvider.overrideWithValue(
          _EmptyPresetRepository(),
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
          child: MaterialApp(
            theme: ThemeData(splashFactory: InkRipple.splashFactory),
            home: const IntermediateModelsSettingsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  group('IntermediateModelsSettingsPage 配置显示模式过滤', () {
    testWidgets('1. 简单模式：分步骤模型区+嵌入模型区保留，提示卡隐藏', (tester) async {
      await pumpPage(tester, level: ConfigLevel.simple);

      expect(find.text('分步骤模型配置'), findsOneWidget);
      expect(find.text('嵌入模型'), findsWidgets);
      expect(find.text('建议配置支持 reasoning 的模型'), findsNothing);
    });

    testWidgets('2. 进阶模式：提示卡 + 分步骤模型区 + 嵌入模型区全量渲染', (tester) async {
      await pumpPage(tester, level: ConfigLevel.advanced);

      expect(find.text('建议配置支持 reasoning 的模型'), findsOneWidget);
      expect(find.text('分步骤模型配置'), findsOneWidget);
      expect(find.text('嵌入模型'), findsWidgets);
    });

    testWidgets('3. 简单模式切进阶：provider 更新即时生效（提示卡回归）', (tester) async {
      final container = await pumpPage(tester, level: ConfigLevel.simple);

      expect(find.text('嵌入模型'), findsWidgets);

      await container
          .read(configLevelProvider.notifier)
          .setLevel(ConfigLevel.advanced);
      await tester.pumpAndSettle();

      expect(find.text('嵌入模型'), findsWidgets);
      expect(find.text('建议配置支持 reasoning 的模型'), findsOneWidget);
    });
  });
}

class _NoopSettingsRepository implements SettingsRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _EmptyPresetRepository implements ApiPresetRepository {
  @override
  Future<List<ApiPreset>> getAllPresets() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}
