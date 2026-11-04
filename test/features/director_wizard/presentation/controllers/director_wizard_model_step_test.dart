import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/director_wizard/presentation/controllers/director_wizard_controller.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';

import '../../../../test_helpers/wizard_fake_settings_notifier.dart';

/// 模型步状态机：两分支判定、未配置供应商创建链、手填兜底、
/// 已配置直选与 GM 就绪门控。
void main() {
  /// 构造假件并等其异步 `_init` 落定（否则 teardown 后 `_init` 续帧
  /// 触发 use-after-dispose）。
  Future<FakeWizardSettingsNotifier> newFake({
    List<ModelInfo> fetchModelsResult = const [
      ModelInfo(modelId: 'model-a'),
      ModelInfo(modelId: 'model-b'),
    ],
    bool fetchModelsFail = false,
    String testOutcome = 'success',
  }) async {
    final fake = FakeWizardSettingsNotifier(
      fetchModelsResult: fetchModelsResult,
      fetchModelsFail: fetchModelsFail,
      testOutcome: testOutcome,
    );
    addTearDown(fake.dispose);
    await Future<void>.delayed(Duration.zero);
    return fake;
  }

  test('分支判定：无任何带 Key 供应商 → 未配置分支，默认推荐 DeepSeek', () async {
    final controller = DirectorWizardController(settings: await newFake());
    addTearDown(controller.dispose);
    controller.enterModelStep(anyKeyedPreset: false);
    expect(controller.state.modelBranch, WizardModelBranch.unconfigured);
    expect(controller.state.selectedTemplateId, 'tpl-deepseek');
    expect(controller.state.providerName, 'DeepSeek');
    expect(controller.state.shouldWriteGlobalDefaults, isTrue);
  });

  test('分支判定：已有带 Key 供应商 → 已配置分支，不预选模板', () async {
    final controller = DirectorWizardController(settings: await newFake());
    addTearDown(controller.dispose);
    controller.enterModelStep(anyKeyedPreset: true);
    expect(controller.state.modelBranch, WizardModelBranch.configured);
    expect(controller.state.selectedTemplateId, isEmpty);
    expect(controller.state.shouldWriteGlobalDefaults, isFalse);
  });

  test('未配置链路：创建+存 Key+拉取成功 → 列表入态，选模型后 GM 就绪', () async {
    final fake = await newFake();
    final controller = DirectorWizardController(settings: fake);
    addTearDown(controller.dispose);
    controller
      ..enterModelStep(anyKeyedPreset: false)
      ..setApiKeyInput('sk-test');

    final created = await controller.createAndFetchModels();
    expect(created, isTrue);
    expect(controller.state.createdPresetId, 'new-preset');
    expect(controller.state.fetchedModels.map((m) => m.modelId), [
      'model-a',
      'model-b',
    ]);
    expect(controller.state.isModelReady, isFalse, reason: '未选模型前不可下一步');

    controller.selectFetchedModel('model-b');
    expect(controller.state.gmPresetId, 'new-preset');
    expect(controller.state.gmModelId, 'model-b');
    expect(controller.state.isModelReady, isTrue);
    expect(
      fake.calls,
      containsAll(
        [
          'createFromTemplate:tpl-deepseek:DeepSeek',
          'saveApiKey:new-preset',
          'fetchModels:new-preset',
        ],
      ),
    );
  });

  test('未配置链路守卫：Key 为空不发起创建', () async {
    final fake = await newFake();
    final controller = DirectorWizardController(settings: fake);
    addTearDown(controller.dispose);
    controller.enterModelStep(anyKeyedPreset: false);

    final created = await controller.createAndFetchModels();
    expect(created, isFalse);
    expect(fake.calls, isEmpty, reason: '未填 Key 不触碰任何供应商操作');
  });

  test('未配置链路：拉取失败 → 手填模型 ID 兜底并回写模型列表', () async {
    final fake = await newFake(fetchModelsFail: true);
    final controller = DirectorWizardController(settings: fake);
    addTearDown(controller.dispose);
    controller
      ..enterModelStep(anyKeyedPreset: false)
      ..setApiKeyInput('sk-test');

    final created = await controller.createAndFetchModels();
    expect(created, isTrue, reason: '供应商已创建，仅拉取失败');
    expect(controller.state.fetchedModels, isEmpty);
    expect(controller.state.providerSetupError, isNotNull);

    controller.setManualModelId('my-model');
    await controller.useManualModel();
    expect(fake.updatedModels.length, 1);
    expect(fake.updatedModels.first.$2.first.modelId, 'my-model');
    expect(controller.state.gmModelId, 'my-model');
    expect(controller.state.isModelReady, isTrue);
  });

  test('已配置链路：直选既有模型 → 只写会话覆盖，不写全局', () async {
    final controller = DirectorWizardController(settings: await newFake());
    addTearDown(controller.dispose);
    controller
      ..enterModelStep(anyKeyedPreset: true)
      ..selectExistingModel(presetId: 'preset-1', modelId: 'model-1');
    expect(controller.state.gmPresetId, 'preset-1');
    expect(controller.state.gmModelId, 'model-1');
    expect(controller.state.isModelReady, isTrue);
    expect(controller.state.shouldWriteGlobalDefaults, isFalse);
  });

  test('测试连接：结果原文入态供 UI 映射人话', () async {
    final fake = await newFake(testOutcome: 'fail:auth|401');
    final controller = DirectorWizardController(settings: fake);
    addTearDown(controller.dispose);
    controller
      ..enterModelStep(anyKeyedPreset: true)
      ..selectExistingModel(presetId: 'preset-1', modelId: 'model-1');

    await controller.testSelectedConnection();
    expect(fake.calls, contains('testConnection:preset-1'));
    expect(controller.state.testResult, 'fail:auth|401');
  });
}
