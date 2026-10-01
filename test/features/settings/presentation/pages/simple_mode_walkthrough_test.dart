import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/pages/director_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/general_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_models_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/settings_page.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../test_helpers/stub_settings_notifier.dart';

/// 简化模式新用户路径走查（C-P4 QA 前置，02 §四）。
///
/// 断言「只靠四类完成 配好模型→开局→调节奏 全流程」在简单模式可达：
/// ①供应商配置（BYOK 必需）→ ②选模型（chat 默认/故事分步骤/故事嵌入
/// D-C13/导演 GM）→ ③模板选择（提示词模板/资源库入口）→ ④导演剧情节奏；
/// 另含思考预算成本旋钮（D-C7 族）可达。chat 默认模型区由其专面双态测试
/// 覆盖。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 无保存值：默认简单模式（新用户口径）
    SharedPreferences.setMockInitialValues({});
    final prefs = Preferences(prefs: await SharedPreferences.getInstance());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsNotifierProvider.overrideWith((ref) {
            return StubSettingsNotifier();
          }),
          // 导演设置页依赖（夜航主题页与折叠记忆，同其专面测试口径）
          advancedConfigProvider
              .overrideWith((ref) async => const AdvancedConfig()),
          intermediateConfigProvider
              .overrideWith((ref) async => const IntermediateConfig()),
          apiPresetRepositoryProvider.overrideWithValue(
            _WalkthroughPresetRepo(),
          ),
          settingsRepositoryProvider
              .overrideWithValue(_WalkthroughSettingsRepo()),
          configLevelProvider.overrideWith(
            (ref) =>
                ConfigLevelNotifier(prefs, initialValue: ConfigLevel.simple),
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

  group('简化模式四类全流程走查（无保存值 → 默认简单）', () {
    testWidgets('四类③：主页模板管理/角色卡世界书入口可达（入口层不裁剪）', (tester) async {
      await pumpPage(tester, const SettingsPage());

      expect(find.text('模板管理'), findsOneWidget);
      expect(find.text('角色卡/世界书'), findsOneWidget);
      // ① 供应商配置的父级入口保留
      expect(find.text('通用设置'), findsOneWidget);
    });

    testWidgets('四类①：通用设置页模型提供商卡片可见', (tester) async {
      await pumpPage(tester, const GeneralSettingsPage());

      expect(find.text('模型提供商'), findsOneWidget);
    });

    testWidgets('四类②：故事分步骤模型区+嵌入模型区可见（D-C13，故事模型子页）',
        (tester) async {
      await pumpPage(tester, const IntermediateModelsSettingsPage());

      expect(find.text('分步骤模型配置'), findsOneWidget);
      expect(find.text('嵌入模型'), findsWidgets);
    });

    testWidgets('四类②+④：导演 GM 模型/剧情节奏/思考档/嵌入模型入口可见（导演设置页）',
        (tester) async {
      await pumpPage(tester, const DirectorSettingsPage());

      expect(find.text('导演主模型'), findsOneWidget);
      expect(find.text('剧情节奏'), findsOneWidget);
      // 成本旋钮（D-C12 思考档行级保留）
      expect(find.text('思考档位'), findsOneWidget);
      // 嵌入模型（D-C13）：记忆区壳恒显，标题即简单模式的配置入口
      expect(find.text('检索与记忆'), findsOneWidget);
    });
  });
}

class _WalkthroughSettingsRepo implements SettingsRepository {
  @override
  Future<Map<String, dynamic>> getUserOverrides() async => const {};

  @override
  Future<void> setUserOverride(String key, dynamic value) async {}

  @override
  Future<void> removeUserOverride(String key) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _WalkthroughPresetRepo implements ApiPresetRepository {
  @override
  Future<List<ApiPreset>> getAllPresets() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}
