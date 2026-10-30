import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/features/advanced/presentation/advanced_mode_flag.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/pages/director_settings_page.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// DirectorSettingsPage 配置显示模式过滤测试。
///
/// 简单模式：折叠区 5→2（项目规则 + 检索与记忆区壳——D-C13 嵌入模型行
/// simple，壳恒显），页首折叠批操作隐藏（可折叠区仍少），模型与生成区内
/// 仅 GM 模型/剧情节奏/思考档行（D-C12）；进阶模式全量 = 现状基线。
/// 折叠批操作只作用于可见区。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Future<ProviderContainer> pumpPage(
    WidgetTester tester, {
    required ConfigLevel level,
    _StubSettingsRepo? repo,
    String? focusSection,
  }) async {
    // 页面内容长，默认视口下 ListView 懒构建会裁掉下折区段，
    // 导致 find 落空；改用手机尺寸视口让全部区块入树。
    tester.view.physicalSize = const Size(1080, 4800);
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
        advancedConfigProvider
            .overrideWith((ref) async => const AdvancedConfig()),
        settingsRepositoryProvider
            .overrideWithValue(repo ?? _StubSettingsRepo()),
        advancedModeFlagProvider.overrideWith(
          (ref) => AdvancedModeFlagNotifier(prefs, initialValue: false),
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
            home: DirectorSettingsPage(focusSection: focusSection),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  group('DirectorSettingsPage 配置显示模式过滤', () {
    testWidgets('1. 简单模式：规则+记忆区壳（D-C13），入口开关与模型区保留，折叠批操作隐藏', (tester) async {
      await pumpPage(tester, level: ConfigLevel.simple);

      expect(find.text('项目规则'), findsOneWidget);
      expect(find.text('模型与生成'), findsOneWidget);
      expect(find.text('工具权限'), findsNothing);
      expect(find.text('运行与预算'), findsNothing);
      expect(find.text('上下文与压缩'), findsNothing);
      // 记忆区壳恒显（D-C13 嵌入模型行 simple），默认折叠仅标题可见
      expect(find.text('检索与记忆'), findsOneWidget);
      expect(find.text('一键折叠'), findsNothing);
      expect(find.text('一键展开'), findsNothing);
    });

    testWidgets('2. 简单模式模型区：GM/剧情节奏/思考档保留，采样参数与推荐回复隐藏（D-C12）', (tester) async {
      await pumpPage(tester, level: ConfigLevel.simple);

      expect(find.text('导演主模型'), findsOneWidget);
      expect(find.text('剧情节奏'), findsOneWidget);
      expect(find.text('思考档位'), findsOneWidget);
      // 温度行（区组件内多处以「温度」为标签，简单模式不应出现）
      expect(find.text('温度'), findsNothing);
      expect(find.text('单次生成上限'), findsNothing);
      expect(find.text('存在惩罚'), findsNothing);
      expect(find.text('频率惩罚'), findsNothing);
      expect(find.text('推荐回复'), findsNothing);
    });

    testWidgets('3. 进阶模式：5 折叠区 + 折叠批操作 + 全部行全量渲染', (tester) async {
      await pumpPage(tester, level: ConfigLevel.advanced);

      expect(find.text('项目规则'), findsOneWidget);
      expect(find.text('工具权限'), findsOneWidget);
      expect(find.text('运行与预算'), findsOneWidget);
      expect(find.text('上下文与压缩'), findsOneWidget);
      expect(find.text('检索与记忆'), findsOneWidget);
      expect(find.text('一键折叠'), findsOneWidget);
      expect(find.text('一键展开'), findsOneWidget);
      expect(find.text('导演主模型'), findsOneWidget);
      expect(find.text('剧情节奏'), findsOneWidget);
      expect(find.text('思考档位'), findsOneWidget);
      // 推荐回复组尾滑桿标签与生成参数行同名，至少一次即全量在树。
      expect(find.text('温度'), findsWidgets);
      expect(find.text('单次生成上限'), findsWidgets);
      expect(find.text('推荐回复'), findsOneWidget);
    });

    testWidgets('4. 简单模式仅规则区可交互，切换不触碰隐藏区折叠记录', (tester) async {
      final repo = _StubSettingsRepo();
      // 预置全部折叠区的折叠记录（模拟进阶模式的用户折叠历史）
      repo.overrides['ui.directorSettings.collapsedSections'] = [
        'rules',
        'budget',
        'memory',
      ];

      await pumpPage(tester, level: ConfigLevel.simple, repo: repo);

      // 简单模式：折叠批操作按钮隐藏，唯一可交互区=规则区头
      expect(find.text('一键折叠'), findsNothing);
      expect(find.text('工具权限'), findsNothing);
      repo.setUserOverrideKeys.clear();
      await tester.tap(find.text('项目规则'));
      await tester.pumpAndSettle();

      // 单区切换写存储；隐藏区（budget/memory）记录原样保留
      expect(
        repo.setUserOverrideKeys,
        contains('ui.directorSettings.collapsedSections'),
      );
      final saved =
          repo.overrides['ui.directorSettings.collapsedSections'] as List;
      expect(saved, isNot(contains('rules')));
      expect(saved, containsAll(['budget', 'memory']));
    });

    testWidgets('5. 简单模式记忆区（D-C13）：向量化模型行保留，记忆管线技术行隐藏', (tester) async {
      // focusSection 展开记忆区（同会话横幅「去配置」深链口径），
      // 简单模式下区内仅向量化模型行（simple），其余行 advanced 隐藏。
      await pumpPage(
        tester,
        level: ConfigLevel.simple,
        focusSection: 'memory',
      );

      expect(find.text('检索与记忆'), findsOneWidget);
      expect(find.text('向量化模型'), findsOneWidget);
      expect(find.text('事实记忆'), findsNothing);
      expect(find.text('记忆归并触发阈值'), findsNothing);
    });
  });
}

class _StubSettingsRepo implements SettingsRepository {
  final Map<String, dynamic> overrides = {};
  final List<String> setUserOverrideKeys = [];

  @override
  Future<Map<String, dynamic>> getUserOverrides() async => overrides;

  @override
  Future<void> setUserOverride(String key, dynamic value) async {
    setUserOverrideKeys.add(key);
    overrides[key] = value;
  }

  @override
  Future<void> removeUserOverride(String key) async {
    overrides.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}
