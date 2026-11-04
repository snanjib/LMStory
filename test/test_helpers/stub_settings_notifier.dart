/// Widget 测试用 [SettingsNotifier] 覆写 stub。
///
/// 提供一个含单个供应商（`preset-1` / `model-1`，显示名「测试供应商」/
/// 「测试模型」）的静态设置态，供需要解析模型显示名的组件测试覆写
/// `settingsNotifierProvider` 使用（DefaultModelPickerSheet、resource_ai
/// 会话设置面板等）。
library;

import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';

/// 预置供应商/模型的 SettingsNotifier（构造即装载，异步完成）。
class StubSettingsNotifier extends SettingsNotifier {
  StubSettingsNotifier()
      : super(
          presetRepo: _StubPresetRepo(),
          templateRepo: _StubTemplateRepo(),
          settingsRepo: _StubSettingsRepo(),
        );
}

class _StubPresetRepo implements ApiPresetRepository {
  @override
  Future<List<ApiPreset>> getAllPresets() async => [
        ApiPreset(
          presetId: 'preset-1',
          name: '测试供应商',
          baseUrl: 'https://test',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          cachedModels: const [
            ModelInfo(modelId: 'model-1', displayName: '测试模型'),
          ],
        ),
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _StubTemplateRepo implements TemplateRepository {
  @override
  Future<void> ensureBuiltInTemplates() async {}

  @override
  Future<List<Template>> getAllTemplates() async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _StubSettingsRepo implements SettingsRepository {
  @override
  Future<Map<String, dynamic>> getUserOverrides() async => {};

  @override
  Future<String?> getApiKey(String presetId) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
