import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/simple/simple_theme.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/widgets/default_model_picker_sheet.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/title_model_section.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 全局级「配后无清除路径」UI 接线回归。
///
/// SettingsNotifier.setTitleModel 的 null 分支（removeUserOverride 双键）
/// 早已就绪，但 TitleModelSection 从未给 DefaultModelPickerSheet 传
/// clearLabel——配置一次后无法清除。本文件锁住「清除 tile 渲染 + 点击
/// 走 removeUserOverride」的接线。
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
            theme: SimpleTheme.lightTheme,
            home: Scaffold(
              body: ListView(children: const [TitleModelSection()]),
            ),
          ),
        ),
      ),
    );
    // settingsNotifier _init + 静默刷新两拍
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    return repo;
  }

  testWidgets('未配置时副标题提示降级行为', (tester) async {
    await pumpSection(tester);

    expect(find.text('会话标题模型'), findsOneWidget);
    expect(
      find.text('未配置（先用当前生成模型起标题，失败时截取回复前缀）'),
      findsOneWidget,
    );
  });

  testWidgets('CF8-1：sheet 渲染清除 tile，点击后 removeUserOverride 双键', (
    tester,
  ) async {
    final repo = await pumpSection(tester);

    await tester.tap(find.text('会话标题模型'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 清除 tile 存在（修复前 clearLabel 恒为 null，tile 不渲染）。
    // 清除 tile 改标题模型专用键，不再复用
    // 「清除默认模型」（本面板语境错位）。
    final clearTile = find.descendant(
      of: find.byType(DefaultModelPickerSheet),
      matching: find.text('清除标题模型'),
    );
    expect(clearTile, findsOneWidget);

    await tester.tap(clearTile);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      repo.removedKeys,
      containsAll([
        'common.title_model.preset_id',
        'common.title_model.model_id',
      ]),
      reason: '清除应走 setTitleModel(null) → removeUserOverride 双键',
    );
    // 清除成功 snackbar（复用「未配置」态文案；卡片副标题同时回退为同文案，
    // 故限定在 SnackBar 内断言避免多义匹配）
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.text('未配置（先用当前生成模型起标题，失败时截取回复前缀）'),
      ),
      findsOneWidget,
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
/// getUserOverrides 返回内部 map 的副本（与真实实现 jsonDecode 每次
/// 新建语义一致），避免调用方原地修改污染 stub 状态。
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
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
