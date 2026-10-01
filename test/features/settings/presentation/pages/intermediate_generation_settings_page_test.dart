import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_generation_settings_page.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// IntermediateGenerationSettingsPage 配置显示模式过滤测试。
///
/// 全局页内行级混排首例：区块恒显，简单模式仅保留思考档位行
/// （C-34 成本旋钮），采样参数 5 行进阶模式渲染；进阶=全量。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Future<ProviderContainer> pumpPage(
    WidgetTester tester, {
    required ConfigLevel level,
  }) async {
    // 六行内容较长，默认视口下 ListView 懒构建会裁掉下折区段，
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
          child: MaterialApp(
            theme: ThemeData(splashFactory: InkRipple.splashFactory),
            home: const IntermediateGenerationSettingsPage(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  group('IntermediateGenerationSettingsPage 配置显示模式过滤', () {
    testWidgets('1. 简单模式：仅思考档位行保留，采样参数行隐藏', (tester) async {
      await pumpPage(tester, level: ConfigLevel.simple);

      // 区块标题恒显（思考预算属生成参数族）
      expect(find.text('生成参数'), findsWidgets);
      expect(find.text('思考预算'), findsOneWidget);
      expect(find.text('温度'), findsNothing);
      expect(find.text('最大 Token 数'), findsNothing);
      expect(find.text('存在惩罚'), findsNothing);
      expect(find.text('频率惩罚'), findsNothing);
    });

    testWidgets('2. 进阶模式：6 行全量渲染', (tester) async {
      await pumpPage(tester, level: ConfigLevel.advanced);

      expect(find.text('温度'), findsOneWidget);
      expect(find.text('Top P'), findsOneWidget);
      expect(find.text('最大 Token 数'), findsWidgets);
      expect(find.text('存在惩罚'), findsOneWidget);
      expect(find.text('频率惩罚'), findsOneWidget);
      expect(find.text('思考预算'), findsOneWidget);
    });

    testWidgets('3. 简单模式切进阶：provider 更新即时生效（采样参数行回归）', (tester) async {
      final container = await pumpPage(tester, level: ConfigLevel.simple);

      expect(find.text('温度'), findsNothing);

      await container
          .read(configLevelProvider.notifier)
          .setLevel(ConfigLevel.advanced);
      await tester.pumpAndSettle();

      expect(find.text('温度'), findsOneWidget);
      expect(find.text('频率惩罚'), findsOneWidget);
      expect(find.text('思考预算'), findsOneWidget);
    });
  });
}

class _NoopSettingsRepository implements SettingsRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}
