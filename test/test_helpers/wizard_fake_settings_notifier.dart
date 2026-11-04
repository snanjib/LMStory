import 'dart:async';

import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';

/// 导演向导测试用可控 [SettingsNotifier]。
///
/// 仓库层用内存 stub（驱动 `_init` 装载 presets/apiKeyStatus），
/// 公开方法按构造参数返回预设结果并记录调用——控制器单测与
/// widget 测试共用同一假件，覆盖创建供应商/存 Key/拉模型/测试
/// 连接四条链路的成功与失败形态。
class FakeWizardSettingsNotifier extends SettingsNotifier {
  FakeWizardSettingsNotifier({
    this.initialPresets = const [],
    this.templates = const [],
    this.keyedPresetIds = const {},
    this.userOverrides = const {},
    this.createdPresetOverride,
    this.createShouldFail = false,
    this.fetchModelsResult,
    this.fetchModelsFail = false,
    this.testOutcome = 'success',
    this.createTemplateShouldFail = false,
    this.setDefaultGate,
  }) : super(
          presetRepo: _StubPresetRepo(initialPresets),
          templateRepo: _StubTemplateRepo(templates),
          settingsRepo: _StubSettingsRepo(keyedPresetIds, userOverrides),
        );

  /// 初始供应商列表（驱动 apiKeyStatus 装载）
  final List<ApiPreset> initialPresets;

  /// 模板列表（规则步路 A 用）
  final List<Template> templates;

  /// 有 Key 的 presetId 集合
  final Set<String> keyedPresetIds;

  /// getUserOverrides 返回值（broadcast_chat.* 等全局默认键注入用）
  final Map<String, dynamic> userOverrides;

  /// createFromTemplate 的返回覆盖（null 且 createShouldFail=false 时用缺省）
  final ApiPreset? createdPresetOverride;

  /// createFromTemplate 是否返回 null（创建失败）
  final bool createShouldFail;

  /// fetchModels 的返回；null = 返回参数缺省空表（模拟拉取失败）
  final List<ModelInfo>? fetchModelsResult;

  /// fetchModels 是否抛错（false 时返回空表并置 fetchModelsError）
  final bool fetchModelsFail;

  /// testConnection 写入 state.testResult 的结果
  final String testOutcome;

  /// createTemplate 是否失败（规则步存模板路径用）
  final bool createTemplateShouldFail;

  /// 完成事务闸门：非空时 setDefaultModel 等待其完成（终审 F2 用例）
  final Completer<void>? setDefaultGate;

  /// 调用记录（断言用）
  final List<String> calls = [];
  final List<(String, String)> savedKeys = [];
  final List<(String, List<ModelInfo>)> updatedModels = [];

  static final _defaultCreatedPreset = ApiPreset(
    presetId: 'new-preset',
    name: '新供应商',
    baseUrl: 'https://new.example.com',
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
  );

  @override
  Future<ApiPreset?> createFromTemplate({
    required String templateId,
    required String name,
  }) async {
    calls.add('createFromTemplate:$templateId:$name');
    if (createShouldFail) return null;
    return createdPresetOverride ?? _defaultCreatedPreset;
  }

  @override
  Future<bool> saveApiKey(String presetId, String apiKey) async {
    calls.add('saveApiKey:$presetId');
    savedKeys.add((presetId, apiKey));
    return true;
  }

  @override
  Future<List<ModelInfo>> fetchModels(String presetId) async {
    calls.add('fetchModels:$presetId');
    if (fetchModelsFail) {
      state = state.copyWith(fetchModelsError: 'boom');
      return const [];
    }
    state = state.copyWith(fetchModelsError: null);
    return fetchModelsResult ?? const [];
  }

  @override
  Future<void> updatePresetModels(String presetId, List<ModelInfo> models) {
    calls.add('updatePresetModels:$presetId');
    updatedModels.add((presetId, models));
    return Future.value();
  }

  @override
  Future<void> setDefaultModel({
    required String? presetId,
    required String? modelId,
  }) async {
    calls.add('setDefaultModel:$presetId:$modelId');
    final gate = setDefaultGate;
    if (gate != null) await gate.future;
  }

  @override
  Future<void> testConnection(String presetId) async {
    calls.add('testConnection:$presetId');
    state = state.copyWith(testResult: testOutcome);
  }

  @override
  Future<Template?> createTemplate({
    required String name,
    required TemplateKind kind,
    required String content,
  }) async {
    calls.add('createTemplate:$name');
    if (createTemplateShouldFail) return null;
    return Template(
      templateId: 'tpl-new',
      name: name,
      kind: kind,
      content: content,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
  }
}

class _StubPresetRepo implements ApiPresetRepository {
  _StubPresetRepo(this.presets);

  final List<ApiPreset> presets;

  @override
  Future<List<ApiPreset>> getAllPresets() async => presets;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _StubTemplateRepo implements TemplateRepository {
  _StubTemplateRepo(this.templates);

  final List<Template> templates;

  @override
  Future<void> ensureBuiltInTemplates() async {}

  @override
  Future<List<Template>> getAllTemplates() async => templates;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _StubSettingsRepo implements SettingsRepository {
  _StubSettingsRepo(this.keyedPresetIds, this.userOverrides);

  final Set<String> keyedPresetIds;
  final Map<String, dynamic> userOverrides;

  @override
  Future<Map<String, dynamic>> getUserOverrides() async => userOverrides;

  @override
  Future<String?> getApiKey(String presetId) async =>
      keyedPresetIds.contains(presetId) ? 'test-key' : null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
