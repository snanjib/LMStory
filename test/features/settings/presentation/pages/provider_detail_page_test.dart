import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/network/llm_adapters/sampling_params.dart';
import 'package:lmstory/core/theme/simple/simple_theme.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/pages/provider_detail_page.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 供应商详情页「高级参数」（providerOptions）Widget 测试
///
/// 口径：非空 JSON 文本 → 校验为对象后保存；非法 JSON/非对象 → 行内
/// 错误且保存禁用；空串保存 = 清除该字段（空就是空，不做隐义）。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Widget wrap(Widget child) => TranslationProvider(
        child: MaterialApp(theme: SimpleTheme.lightTheme, home: child),
      );

  Future<(ProviderContainer, _StubPresetRepo)> pumpPage(
    WidgetTester tester, {
    Map<String, dynamic>? providerOptions,
    LlmProtocol protocol = LlmProtocol.openaiCompatible,
    Size viewSize = const Size(1200, 3000),
  }) async {
    // 页面分区较多，默认 600 高视口下 ListView 懒加载不会构建底部的
    // 高级参数与采样参数区；放大视口让整页进入构建范围。
    tester.view.physicalSize = viewSize;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final repo = _StubPresetRepo(
      ApiPreset(
        presetId: 'p1',
        name: '测试供应商',
        baseUrl: 'https://api.test.com',
        protocol: protocol,
        providerOptions: providerOptions,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    );
    final container = ProviderContainer(
      overrides: [
        apiPresetRepositoryProvider.overrideWithValue(repo),
        templateRepositoryProvider.overrideWithValue(_StubTemplateRepo()),
        settingsRepositoryProvider.overrideWithValue(_StubSettingsRepo()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: wrap(const ProviderDetailPage(presetId: 'p1')),
      ),
    );
    // initState 静默刷新，两拍让 preset 就位
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    return (container, repo);
  }

  testWidgets('model IDs with look-alike dashes require confirmation',
      (tester) async {
    final (_, repo) = await pumpPage(tester);
    final addModel = find.text('添加模型');
    await tester.ensureVisible(addModel);
    await tester.tap(addModel);
    await tester.pumpAndSettle();

    final id = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.hintText == '输入模型 ID',
    );
    final save = find.widgetWithText(ElevatedButton, '保存');
    await tester.enterText(id, 'deepsee－kchat');
    await tester.tap(save);
    await tester.pumpAndSettle();

    expect(repo.preset.cachedModels, isEmpty);
    expect(find.textContaining('U+FF0D'), findsOneWidget);
    await tester.tap(find.text('返回修改'));
    await tester.pumpAndSettle();
    expect(find.text('deepsee－kchat'), findsOneWidget);

    await tester.enterText(id, 'test-provider/reader-v2:free');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(
      repo.preset.cachedModels.single.modelId,
      'test-provider/reader-v2:free',
    );

    await tester.tap(addModel);
    await tester.pumpAndSettle();
    await tester.enterText(id, '测试模型−本地');
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.textContaining('U+2212'), findsOneWidget);
    await tester.tap(find.text('按原样保存'));
    await tester.pumpAndSettle();
    expect(repo.preset.cachedModels.last.modelId, '测试模型−本地');
  });

  testWidgets('model list credentials failure shows a lasting next step',
      (tester) async {
    final (_, repo) = await pumpPage(tester);
    repo.listFailure = const AppHttpException(
      'Model list request failed',
      statusCode: 401,
      responseBody:
          '{"error":{"message":"loopback details","api_key":"synthetic-secret"}}',
    );
    final fetch = find.text('获取模型列表');
    await tester.ensureVisible(fetch);
    await tester.tap(fetch);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));

    expect(find.text('API Key 无效或无权限'), findsOneWidget);
    expect(find.textContaining('检查或更正 API Key'), findsOneWidget);
    expect(find.textContaining('loopback details'), findsNothing);
    await tester.tap(find.text('详细信息'));
    await tester.pumpAndSettle();

    expect(find.textContaining('401'), findsOneWidget);
    expect(find.textContaining('loopback details'), findsOneWidget);
    expect(find.textContaining('synthetic-secret'), findsNothing);
  });

  testWidgets('API Key actions fit on a narrow screen with large English text',
      (tester) async {
    await tester.runAsync(() => LocaleSettings.setLocale(AppLocale.enUs));
    addTearDown(() => LocaleSettings.setLocaleSync(AppLocale.zhCn));
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpPage(tester, viewSize: const Size(320, 3000));
    await tester.pumpAndSettle();

    expect(find.text('Test connection'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final editKey = find.widgetWithText(TextButton, 'Edit').last;
    await tester.ensureVisible(editKey);
    await tester.tap(editKey);
    await tester.pumpAndSettle();
    expect(find.text('Enter API Key'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('已配置时折叠摘要显示条数，展开回填格式化 JSON', (tester) async {
    await pumpPage(
      tester,
      providerOptions: {
        'thinking': {'type': 'enabled'},
      },
    );

    await tester.ensureVisible(
      find.text('已配置 1 项', skipOffstage: false),
    );
    await tester.pump();

    await tester.tap(find.text('已配置 1 项'));
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, contains('"thinking"'));
    expect(find.text('已配置 1 项'), findsNothing);
  });

  testWidgets('非法 JSON 给行内错误且保存禁用', (tester) async {
    await pumpPage(tester);

    await tester.ensureVisible(
      find.text('未配置', skipOffstage: false),
    );
    await tester.pump();
    await tester.tap(find.text('未配置'));
    await tester.pump();

    await tester.enterText(find.byType(TextField), '{not-json');
    await tester.pump();

    expect(find.text('JSON 格式无效，请检查逗号与引号'), findsOneWidget);
    final save = find.widgetWithText(ElevatedButton, '保存');
    expect(tester.widget<ElevatedButton>(save).onPressed, isNull);
  });

  testWidgets('非对象 JSON（数组）给行内错误且保存禁用', (tester) async {
    await pumpPage(tester);

    await tester.ensureVisible(
      find.text('未配置', skipOffstage: false),
    );
    await tester.pump();
    await tester.tap(find.text('未配置'));
    await tester.pump();

    await tester.enterText(find.byType(TextField), '[1, 2]');
    await tester.pump();

    expect(find.text('必须是 JSON 对象（以 { 开头）'), findsOneWidget);
    final save = find.widgetWithText(ElevatedButton, '保存');
    expect(tester.widget<ElevatedButton>(save).onPressed, isNull);
  });

  testWidgets('合法 JSON 保存写入 providerOptions', (tester) async {
    final (_, repo) = await pumpPage(tester);

    await tester.ensureVisible(
      find.text('未配置', skipOffstage: false),
    );
    await tester.pump();
    await tester.tap(find.text('未配置'));
    await tester.pump();

    await tester.enterText(
      find.byType(TextField),
      '{"thinking": {"type": "enabled", "budget_tokens": 2000}}',
    );
    await tester.pump();

    final save = find.widgetWithText(ElevatedButton, '保存');
    await tester.ensureVisible(
      find.widgetWithText(ElevatedButton, '保存', skipOffstage: false),
    );
    await tester.pump();
    await tester.tap(save);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final options = repo.preset.providerOptions;
    expect(options, isNotNull);
    expect((options!['thinking'] as Map)['budget_tokens'], 2000);
    // 保存后折叠回摘要态
    expect(find.text('已配置 1 项'), findsOneWidget);
  });

  testWidgets('空串保存 = 清除 providerOptions（空就是空）', (tester) async {
    final (_, repo) = await pumpPage(
      tester,
      providerOptions: {
        'extra_headers': {'HTTP-Referer': 'x'},
      },
    );

    await tester.ensureVisible(
      find.text('已配置 1 项', skipOffstage: false),
    );
    await tester.pump();
    await tester.tap(find.text('已配置 1 项'));
    await tester.pump();

    await tester.enterText(find.byType(TextField), '');
    await tester.pump();

    final save = find.widgetWithText(ElevatedButton, '保存');
    await tester.ensureVisible(
      find.widgetWithText(ElevatedButton, '保存', skipOffstage: false),
    );
    await tester.pump();
    await tester.tap(save);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(repo.preset.providerOptions, isNull);
  });

  // ── ：保存后回填读持久值，而非保存前的旧值 ────────

  testWidgets('清除保存后重新展开回填持久值（文本为空）', (tester) async {
    await pumpPage(
      tester,
      providerOptions: {
        'extra_headers': {'HTTP-Referer': 'x'},
      },
    );

    await tester.ensureVisible(
      find.text('已配置 1 项', skipOffstage: false),
    );
    await tester.pump();
    await tester.tap(find.text('已配置 1 项'));
    await tester.pump();

    await tester.enterText(find.byType(TextField), '');
    await tester.pump();

    final save = find.widgetWithText(ElevatedButton, '保存');
    await tester.ensureVisible(
      find.widgetWithText(ElevatedButton, '保存', skipOffstage: false),
    );
    await tester.pump();
    await tester.tap(save);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // 摘要已折叠为未配置；此时再展开必须显示持久值（空）——
    // 修复前回填的是保存前旧 JSON，与摘要矛盾且可在其上继续编辑写回
    expect(find.text('未配置'), findsOneWidget);
    await tester.tap(find.text('未配置'));
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(
      field.controller!.text,
      isEmpty,
      reason: '清除保存后再展开应显示持久值（空），而非保存前的旧 JSON',
    );
  });

  testWidgets('展开中外部变更（重置）且未编辑时同步回填', (tester) async {
    final (container, _) = await pumpPage(
      tester,
      providerOptions: {'a': 1},
    );

    await tester.ensureVisible(
      find.text('已配置 1 项', skipOffstage: false),
    );
    await tester.pump();
    await tester.tap(find.text('已配置 1 项'));
    await tester.pump();

    // 展开中（未编辑）外部清除 providerOptions——AppBar「重置为模板
    // 默认值」的等价路径（S-1 重置会清空该列）
    await container
        .read(settingsNotifierProvider.notifier)
        .updatePreset('p1', providerOptions: null);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(
      field.controller!.text,
      isEmpty,
      reason: '外部重置后展开中的编辑器应同步持久值，否则一键保存即覆盖刚完成的重置',
    );
  });

  // ── ：保存失败接失败反馈 ──────────────────────────

  testWidgets('保存失败显示失败反馈，不再误报已保存', (tester) async {
    final (_, repo) = await pumpPage(tester);
    repo.throwOnUpdate = true;

    await tester.ensureVisible(
      find.text('未配置', skipOffstage: false),
    );
    await tester.pump();
    await tester.tap(find.text('未配置'));
    await tester.pump();

    await tester.enterText(
      find.byType(TextField),
      '{"thinking": {"type": "enabled"}}',
    );
    await tester.pump();

    final save = find.widgetWithText(ElevatedButton, '保存');
    await tester.ensureVisible(
      find.widgetWithText(ElevatedButton, '保存', skipOffstage: false),
    );
    await tester.pump();
    await tester.tap(save);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('高级参数已保存'), findsNothing);
    expect(
      find.textContaining('Mock update failure'),
      findsOneWidget,
      reason: 'repo 写入异常时须展示失败反馈（floating snackbar）',
    );
  });

  // ── ：helperText 按协议列有效键位 ──────────────────

  testWidgets('Anthropic 协议 helperText 列本协议有效键位', (tester) async {
    await pumpPage(tester, protocol: LlmProtocol.anthropic);

    await tester.ensureVisible(
      find.text('未配置', skipOffstage: false),
    );
    await tester.pump();
    await tester.tap(find.text('未配置'));
    await tester.pump();

    expect(
      find.textContaining('anthropic_beta'),
      findsOneWidget,
      reason: 'helperText 应按协议列有效键位（Anthropic：anthropic_beta/thinking）',
    );
  });

  // ── ：名称/URL 编辑点保存失败不再静默退出编辑态 ──────

  // 页面上 edit_outlined 图标自上而下：名称行 → API Host 行 → API Key 行
  // （模型行为空），用下标区分名称/URL 两个编辑入口。
  // skipOffstage:false——滚动后视口外的图标默认 finder 找不到，会让
  // 下标在 ensureVisible 前后漂移（.at(1) 变成 API Key 行的图标）。
  testWidgets('名称保存失败给失败反馈且留在编辑态', (tester) async {
    final (_, repo) = await pumpPage(tester);
    repo.throwOnUpdate = true;

    final nameEdit =
        find.byIcon(Icons.edit_outlined, skipOffstage: false).first;
    await tester.ensureVisible(nameEdit);
    await tester.pump();
    await tester.tap(nameEdit);
    await tester.pump();

    await tester.enterText(find.byType(TextField).first, '新名字');
    await tester.pump();

    final save = find.widgetWithText(ElevatedButton, '保存');
    await tester.ensureVisible(save);
    await tester.pump();
    await tester.tap(save);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      find.textContaining('Mock update failure'),
      findsOneWidget,
      reason: '重命名失败须给失败反馈（与 providerOptions 保存同口径）',
    );
    expect(
      find.byType(TextField),
      findsOneWidget,
      reason: '保存失败应留在编辑态，不静默退出让用户误以为已保存',
    );
  });

  testWidgets('baseUrl 保存失败给失败反馈且留在编辑态', (tester) async {
    final (_, repo) = await pumpPage(tester);
    repo.throwOnUpdate = true;

    final urlEdit = find.byIcon(Icons.edit_outlined, skipOffstage: false).at(1);
    await tester.ensureVisible(urlEdit);
    await tester.pump();
    await tester.tap(urlEdit);
    await tester.pump();

    await tester.enterText(
      find.byType(TextField).first,
      'https://new.example.com',
    );
    await tester.pump();

    final save = find.widgetWithText(ElevatedButton, '保存');
    await tester.ensureVisible(save);
    await tester.pump();
    await tester.tap(save);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      find.textContaining('Mock update failure'),
      findsOneWidget,
      reason: 'URL 保存失败须给失败反馈（与 providerOptions 保存同口径）',
    );
    expect(
      find.byType(TextField),
      findsOneWidget,
      reason: '保存失败应留在编辑态，不静默退出让用户误以为已保存',
    );
  });

  // ── ：供应商级「不发送采样参数」开关 ────────────────

  Finder samplingSwitch() => find.widgetWithText(
        SwitchListTile,
        '不发送采样参数',
        skipOffstage: false,
      );

  testWidgets('采样参数开关：默认关，开启写入保留键并保留其他键', (tester) async {
    final (_, repo) = await pumpPage(
      tester,
      providerOptions: {
        'extra_headers': {'X-Test': '1'},
      },
    );

    final tile = samplingSwitch();
    await tester.ensureVisible(tile);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);

    await tester.tap(tile);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(repo.preset.providerOptions?[kOmitSamplingParamsOption], isTrue);
    expect(
      (repo.preset.providerOptions?['extra_headers'] as Map)['X-Test'],
      '1',
    );
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
  });

  testWidgets('采样参数开关：关闭删除保留键并保留其他键', (tester) async {
    final (_, repo) = await pumpPage(
      tester,
      providerOptions: {
        kOmitSamplingParamsOption: true,
        'thinking': {'type': 'enabled'},
      },
    );

    final tile = samplingSwitch();
    await tester.ensureVisible(tile);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);

    await tester.tap(tile);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(repo.preset.providerOptions, {
      'thinking': {'type': 'enabled'},
    });
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
  });

  testWidgets('采样参数开关：高级参数有未保存修改时禁用并说明', (tester) async {
    await pumpPage(tester);

    final tile = samplingSwitch();
    await tester.ensureVisible(tile);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(tile).onChanged, isNotNull);

    final summary = find.text('未配置', skipOffstage: false);
    await tester.ensureVisible(summary);
    await tester.pump();
    await tester.tap(summary);
    await tester.pump();
    await tester.enterText(find.byType(TextField), '{"thinking": {}}');
    await tester.pump();

    await tester.ensureVisible(tile);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(tile).onChanged, isNull);
    expect(find.text('高级参数有未保存的修改，请先保存或取消后再切换'), findsOneWidget);
  });

  testWidgets('采样参数开关：保存失败显示失败反馈', (tester) async {
    final (_, repo) = await pumpPage(tester);
    repo.throwOnUpdate = true;

    final tile = samplingSwitch();
    await tester.ensureVisible(tile);
    await tester.pump();
    await tester.tap(tile);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.textContaining('Mock update failure'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(tile).value, isFalse);
  });
}

class _StubPresetRepo implements ApiPresetRepository {
  _StubPresetRepo(this.preset);

  ApiPreset preset;
  AppHttpException? listFailure;

  /// 置 true 时 updatePreset 抛异常（模拟 DB 写入失败）
  bool throwOnUpdate = false;

  @override
  Future<List<ApiPreset>> getAllPresets() async => [preset];

  @override
  Future<ApiPreset> getPreset(String presetId) async => preset;

  @override
  Future<List<ModelInfo>> fetchModels(String presetId) async {
    final failure = listFailure;
    if (failure != null) throw failure;
    return const [];
  }

  @override
  Future<void> updateModelList(String presetId, List<ModelInfo> models) async {
    preset = preset.copyWith(cachedModels: models);
  }

  @override
  Future<ApiPreset> updatePreset(
    String presetId,
    ApiPreset Function(ApiPreset current) updater,
  ) async {
    if (throwOnUpdate) {
      throw Exception('Mock update failure');
    }
    return preset = updater(preset);
  }

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

class _StubSettingsRepo implements SettingsRepository {
  final Map<String, dynamic> overrides = {};

  @override
  Future<Map<String, dynamic>> getUserOverrides() async => overrides;

  @override
  Future<void> setUserOverride(String key, dynamic value) async {
    overrides[key] = value;
  }

  @override
  Future<void> removeUserOverride(String key) async {
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
