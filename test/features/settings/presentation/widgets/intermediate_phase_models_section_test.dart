import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/widgets/intermediate_model_picker_sheet.dart';
import 'package:lmstory/features/settings/presentation/widgets/intermediate_phase_models_section.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 分步骤模型「全局模式配后无清除路径」UI 接线回归。
///
/// _persistPhase 的 null 分支（removeUserOverride 双键 + cleared snackbar）
/// 早已就绪，但全局模式从未给 IntermediateModelPickerSheet 传 clearLabel
/// （旧注释「全局模式不提供清除按钮」与 controller 能力不符）——配置一次
/// 后无法清除。本文件锁住「全局模式清除 tile 渲染 + 点击走
/// removeUserOverride 双键」的接线。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Future<_RecorderSettingsRepo> pumpSection(WidgetTester tester) async {
    final repo = _RecorderSettingsRepo();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiPresetRepositoryProvider.overrideWithValue(_StubPresetRepo()),
          templateRepositoryProvider.overrideWithValue(_StubTemplateRepo()),
          settingsRepositoryProvider.overrideWithValue(repo),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme:
                ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
            home: const Scaffold(
              body: SingleChildScrollView(
                child: IntermediatePhaseModelsSection(),
              ),
            ),
          ),
        ),
      ),
    );
    // 区块 _loadPresets + settingsNotifier _init 两拍
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return repo;
  }

  testWidgets('全局模式已配置阶段显示供应商 · 模型', (tester) async {
    await pumpSection(tester);

    expect(find.text('生成回复'), findsOneWidget);
    // 卡片副标题是「模型\n影响：…」单 Text，用包含匹配
    expect(find.textContaining('测试供应商 · 测试模型'), findsOneWidget);
  });

  testWidgets('CF8-1：全局模式 sheet 渲染清除 tile，点击后双键 remove', (
    tester,
  ) async {
    final repo = await pumpSection(tester);

    await tester.tap(find.text('生成回复'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 清除 tile 存在（修复前全局模式 clearLabel 恒为 null，tile 不渲染）。
    // 用 descendant 限定在 sheet 内：区块里其余未配置阶段的副标题也是「未配置」。
    final clearTile = find.descendant(
      of: find.byType(IntermediateModelPickerSheet),
      matching: find.text('未配置'),
    );
    expect(clearTile, findsOneWidget);

    await tester.tap(clearTile);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      repo.removedKeys,
      containsAll([
        'intermediate.phase_models.generating_preset_id',
        'intermediate.phase_models.generating_model_id',
      ]),
      reason: '全局模式清除应走 _persistPhase(null) → removeUserOverride 双键',
    );
  });
}

class _StubPresetRepo implements ApiPresetRepository {
  static final _preset = ApiPreset(
    presetId: 'p1',
    name: '测试供应商',
    baseUrl: 'https://api.test.com',
    cachedModels: const [ModelInfo(modelId: 'm1', displayName: '测试模型')],
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );

  @override
  Future<List<ApiPreset>> getAllPresets() async => [_preset];

  @override
  Future<ApiPreset> getPreset(String presetId) async => _preset;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _StubTemplateRepo implements TemplateRepository {
  @override
  Future<List<Template>> getAllTemplates() async => [];

  @override
  Future<void> ensureBuiltInTemplates() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// 记录 removeUserOverride 调用的 settings 仓库 stub。
///
/// getResolvedConfig 返回生成阶段已配置 p1/m1 的中间态配置，让区块
/// 副标题走「已配置」分支（与清除后的「未配置」形成对照）。
/// getUserOverrides 返回副本，避免调用方原地修改污染 stub 状态。
class _RecorderSettingsRepo implements SettingsRepository {
  final Map<String, dynamic> overrides = {};
  final List<String> removedKeys = [];

  @override
  Future<Map<String, dynamic>> getUserOverrides() async => Map.of(overrides);

  @override
  Future<void> setUserOverride(String key, dynamic value) async {
    overrides[key] = value;
  }

  @override
  Future<void> removeUserOverride(String key) async {
    removedKeys.add(key);
    overrides.remove(key);
  }

  @override
  Future<String?> getApiKey(String presetId) async => null;

  @override
  Future<AppConfig> getResolvedConfig() async => const AppConfig(
        version: '0.1',
        broadcastChat: BroadcastChatConfig(),
        intermediate: IntermediateConfig(
          phaseModels: PhaseModelsConfig(
            generatingPresetId: 'p1',
            generatingModelId: 'm1',
          ),
        ),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
