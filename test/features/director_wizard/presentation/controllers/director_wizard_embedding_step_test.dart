import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/director_wizard/presentation/controllers/director_wizard_controller.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/model_capability.dart';

import '../../../../test_helpers/wizard_fake_settings_notifier.dart';

/// 嵌入步状态机：现状快照、两路径（保留/更换｜配上/跳过）、
/// 第二供应商流与嵌入类型自动标记的手填兜底。
void main() {
  Future<FakeWizardSettingsNotifier> newFake({
    List<ModelInfo> fetchModelsResult = const [],
  }) async {
    final fake = FakeWizardSettingsNotifier(
      fetchModelsResult: fetchModelsResult,
    );
    addTearDown(fake.dispose);
    await Future<void>.delayed(Duration.zero);
    return fake;
  }

  test('进入嵌入步：已有全局嵌入配置 → 现状入态并预选「按现状继续」', () async {
    final controller = DirectorWizardController(
      settings: await newFake(),
    );
    addTearDown(controller.dispose);
    controller.enterEmbeddingStep(currentPresetId: 'p1', currentModelId: 'm1');
    expect(controller.state.embeddingStatus, WizardEmbeddingStatus.configured);
    expect(controller.state.currentEmbeddingPresetId, 'p1');
    expect(controller.state.currentEmbeddingModelId, 'm1');
    expect(
      controller.state.embeddingChoice,
      WizardEmbeddingChoice.keep,
      reason: '已配置分支默认高亮「就按现状继续」',
    );
  });

  test('进入嵌入步：无全局嵌入配置 → 未配置态且无默认选择（强制显式）', () async {
    final controller = DirectorWizardController(
      settings: await newFake(),
    );
    addTearDown(controller.dispose);
    controller.enterEmbeddingStep(currentPresetId: '', currentModelId: '');
    expect(
      controller.state.embeddingStatus,
      WizardEmbeddingStatus.unconfigured,
    );
    expect(
      controller.state.embeddingChoice,
      WizardEmbeddingChoice.none,
      reason: '未配置分支不预置默认（2026-10-18 拍板：强制显式选择）',
    );
  });

  test('保留现状：choice=keep（页面写回入口快照）', () async {
    final controller = DirectorWizardController(
      settings: await newFake(),
    );
    addTearDown(controller.dispose);
    controller
      ..enterEmbeddingStep(currentPresetId: 'p1', currentModelId: 'm1')
      ..keepCurrentEmbedding();
    expect(controller.state.embeddingChoice, WizardEmbeddingChoice.keep);
  });

  test('先跳过：choice=skip（零写入）', () async {
    final controller = DirectorWizardController(
      settings: await newFake(),
    );
    addTearDown(controller.dispose);
    controller
      ..enterEmbeddingStep(currentPresetId: '', currentModelId: '')
      ..skipEmbedding();
    expect(controller.state.embeddingChoice, WizardEmbeddingChoice.skip);
  });

  test('选择既有嵌入模型：选择入态', () async {
    final controller = DirectorWizardController(
      settings: await newFake(),
    );
    addTearDown(controller.dispose);
    controller
      ..enterEmbeddingStep(currentPresetId: '', currentModelId: '')
      ..chooseEmbeddingModel(presetId: 'preset-1', modelId: 'emb-1');
    expect(controller.state.embeddingChoice, WizardEmbeddingChoice.change);
    expect(controller.state.selectedEmbeddingPresetId, 'preset-1');
    expect(controller.state.selectedEmbeddingModelId, 'emb-1');
  });

  test('嵌入第二供应商流：创建+拉取后只暴露嵌入类型模型', () async {
    final fake = await newFake(
      fetchModelsResult: const [
        ModelInfo(modelId: 'chat-x'),
        ModelInfo(modelId: 'emb-x', type: ModelType.embedding),
      ],
    );
    final controller = DirectorWizardController(settings: fake);
    addTearDown(controller.dispose);
    controller.enterEmbeddingStep(currentPresetId: '', currentModelId: '');
    // 一条级联走完配置+创建（拆两条语句会触发 cascade lint）
    final created = await (controller
          ..selectEmbTemplate(templateId: 'tpl-openai', displayName: 'OpenAI')
          ..setEmbApiKeyInput('sk-emb'))
        .createEmbProviderAndFetch();
    expect(created, isTrue);
    expect(controller.state.embCreatedPresetId, 'new-preset');
    expect(
      controller.state.embSelectableModels.map((m) => m.modelId),
      ['emb-x'],
      reason: '只列嵌入类型',
    );

    controller.selectEmbModel('emb-x');
    expect(controller.state.selectedEmbeddingPresetId, 'new-preset');
    expect(controller.state.selectedEmbeddingModelId, 'emb-x');
  });

  test('嵌入手填兜底：模型自动标记 embedding 类型回写', () async {
    final fake = await newFake();
    final controller = DirectorWizardController(settings: fake);
    addTearDown(controller.dispose);
    controller.enterEmbeddingStep(currentPresetId: '', currentModelId: '');
    await (controller
          ..selectEmbTemplate(templateId: 'tpl-openai', displayName: 'OpenAI')
          ..setEmbApiKeyInput('sk-emb'))
        .createEmbProviderAndFetch();

    await (controller..setEmbManualModelId('my-emb')).useEmbManualModel();
    expect(fake.updatedModels.length, 1);
    expect(
      fake.updatedModels.first.$2.first.type,
      ModelType.embedding,
      reason: '类型标记是群材料实证的头号坑，向导代填',
    );
    expect(controller.state.selectedEmbeddingModelId, 'my-emb');
  });
}
