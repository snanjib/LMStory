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
import 'package:lmstory/features/settings/presentation/pages/general_advanced_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_generation_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_models_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_settings_page.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../test_helpers/stub_settings_notifier.dart';

/// 进阶=接入前基线回归矩阵（C-P4 QA；02 §四「进阶=现状全量」承载）。
///
/// 设置侧 6 个实质过滤面在**进阶模式**下逐面断言渲染的区块/行集合与
/// 接线前一致——任何「进阶模式误隐藏」在此红。会话内三面板的进阶基线
/// 由各自既有用例组承载（chat/导演面板过滤组进阶用例、故事面板 C-P2
/// 缺省进阶回归组）；结构无变化面无双态差异，不进矩阵。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Future<void> pumpPage(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(1080, 4800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    SharedPreferences.setMockInitialValues({
      ConfigLevelNotifier.prefKey: 'advanced',
    });
    final prefs = Preferences(prefs: await SharedPreferences.getInstance());

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsNotifierProvider.overrideWith((ref) {
            return StubSettingsNotifier();
          }),
          advancedConfigProvider
              .overrideWith((ref) async => const AdvancedConfig()),
          intermediateConfigProvider
              .overrideWith((ref) async => const IntermediateConfig()),
          settingsRepositoryProvider.overrideWithValue(_MatrixSettingsRepo()),
          apiPresetRepositoryProvider.overrideWithValue(
            _MatrixPresetRepo(),
          ),
          configLevelProvider.overrideWith(
            (ref) =>
                ConfigLevelNotifier(prefs, initialValue: ConfigLevel.advanced),
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

  group('进阶基线矩阵（进阶模式 = 接入前全量）', () {
    testWidgets('高级子页：3 区全量', (tester) async {
      await pumpPage(tester, const GeneralAdvancedSettingsPage());

      expect(find.text('默认思考预算'), findsOneWidget);
      expect(find.text('超时设置'), findsOneWidget);
      expect(find.text('会话标题模型'), findsWidgets);
    });

    testWidgets('故事设置枢纽页：7 卡全量', (tester) async {
      await pumpPage(tester, const IntermediateSettingsPage());

      expect(find.text('模型配置'), findsOneWidget);
      expect(find.text('系统提示词'), findsOneWidget);
      expect(find.text('工具与记忆'), findsOneWidget);
      expect(find.text('生成参数'), findsOneWidget);
      expect(find.text('提示词模板'), findsOneWidget);
      expect(find.text('推荐回复'), findsOneWidget);
      expect(find.text('使用帮助'), findsOneWidget);
    });

    testWidgets('故事模型子页：提示卡 + 分步骤 + 嵌入 3 块全量', (tester) async {
      await pumpPage(tester, const IntermediateModelsSettingsPage());

      expect(find.text('建议配置支持 reasoning 的模型'), findsOneWidget);
      expect(find.text('分步骤模型配置'), findsOneWidget);
      expect(find.text('嵌入模型'), findsWidgets);
    });

    testWidgets('故事生成参数子页：6 行全量', (tester) async {
      await pumpPage(tester, const IntermediateGenerationSettingsPage());

      expect(find.text('温度'), findsOneWidget);
      expect(find.text('Top P'), findsOneWidget);
      expect(find.text('最大 Token 数'), findsWidgets);
      expect(find.text('存在惩罚'), findsOneWidget);
      expect(find.text('频率惩罚'), findsOneWidget);
      expect(find.text('思考预算'), findsOneWidget);
    });

    testWidgets('导演设置页：5 折叠区 + 折叠批按钮 + 模型区全行', (tester) async {
      await pumpPage(tester, const DirectorSettingsPage());

      expect(find.text('项目规则'), findsOneWidget);
      expect(find.text('工具权限'), findsOneWidget);
      expect(find.text('运行与预算'), findsOneWidget);
      expect(find.text('上下文与压缩'), findsOneWidget);
      expect(find.text('检索与记忆'), findsOneWidget);
      expect(find.text('一键折叠'), findsOneWidget);
      expect(find.text('一键展开'), findsOneWidget);
      // 模型与生成区行集合（推荐回复组尾滑杆标签与生成参数行同文案）
      expect(find.text('导演主模型'), findsOneWidget);
      expect(find.text('温度'), findsWidgets);
      expect(find.text('单次生成上限'), findsWidgets);
      expect(find.text('思考档位'), findsOneWidget);
      expect(find.text('剧情节奏'), findsOneWidget);
      expect(find.text('推荐回复'), findsOneWidget);
      expect(find.text('候选数量'), findsOneWidget);
      expect(find.text('单条最大字数'), findsOneWidget);
    });
  });
}

class _MatrixSettingsRepo implements SettingsRepository {
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

class _MatrixPresetRepo implements ApiPresetRepository {
  @override
  Future<List<ApiPreset>> getAllPresets() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}
