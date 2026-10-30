import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/director_wizard/presentation/controllers/director_wizard_controller.dart';

/// 导演向导状态机：三步内的步进边界与重置语义（退出即弃的态由
/// autoDispose provider 负责销毁，这里锁控制器本身的边界行为）。
void main() {
  int step(DirectorWizardController c) => c.state.currentStep;

  test('初始状态：第 1 步（0 基），共三步', () {
    final controller = DirectorWizardController();
    addTearDown(controller.dispose);
    expect(step(controller), 0);
    expect(DirectorWizardState.totalSteps, 3);
  });

  test('nextStep/prevStep 在 0..2 内往返，步号正确', () {
    final controller = DirectorWizardController();
    addTearDown(controller.dispose);
    controller.nextStep();
    expect(step(controller), 1);
    controller.nextStep();
    expect(step(controller), 2);
    controller.prevStep();
    expect(step(controller), 1);
    controller.prevStep();
    expect(step(controller), 0);
  });

  test('步进边界：首步 prevStep 不越界', () {
    final controller = DirectorWizardController();
    addTearDown(controller.dispose);
    controller.prevStep();
    expect(step(controller), 0);
  });

  test('步进边界：末步 nextStep 不越界', () {
    final controller = DirectorWizardController();
    addTearDown(controller.dispose);
    controller
      ..nextStep()
      ..nextStep()
      ..nextStep();
    expect(step(controller), 2);
  });

  test('goToStep：越界忽略', () {
    final controller = DirectorWizardController();
    addTearDown(controller.dispose);
    controller.goToStep(5);
    expect(step(controller), 0, reason: '越界忽略');
    controller.goToStep(-1);
    expect(step(controller), 0, reason: '负数同样忽略');
  });

  test('goToStep：模型步未就绪时滑动越步被守卫', () {
    final controller = DirectorWizardController();
    addTearDown(controller.dispose);
    controller.goToStep(2);
    expect(step(controller), 0, reason: 'GM 未就绪不允许滑入后续步');
  });

  test('goToStep：模型就绪后直达', () {
    final controller = DirectorWizardController();
    addTearDown(controller.dispose);
    controller
      ..selectExistingModel(presetId: 'p', modelId: 'm')
      ..goToStep(2);
    expect(step(controller), 2, reason: '就绪后直达');
  });

  test('reset 回到全新状态（第 1 步）', () {
    final controller = DirectorWizardController();
    addTearDown(controller.dispose);
    controller
      ..nextStep()
      ..nextStep()
      ..reset();
    expect(step(controller), 0);
  });

  group('规则步状态机（2026-10-18 UX 重构：确认页+生成中隔离）', () {
    DirectorWizardController toAnswering() {
      final controller = DirectorWizardController()
        ..chooseRulesPath(WizardRulesPath.questionnaire)
        ..setRulesGenre('xianxia');
      return controller;
    }

    test('答题页可返回分叉页：答案保留、预览清除', () {
      final controller = toAnswering();
      addTearDown(controller.dispose);
      controller
        ..showRulesAssembled('预览文本')
        ..backToRulesAnswering()
        ..backToRulesChoosing();
      expect(controller.state.rulesStage, WizardRulesStage.choosing);
      expect(controller.state.rulesGenreId, 'xianxia', reason: '答案保留');
      expect(controller.state.rulesPreviewText, isNull, reason: '预览清除');
    });

    test('「让模型替你写」先进确认页：未发起生成', () {
      final controller = toAnswering();
      addTearDown(controller.dispose);
      controller.enterRulesConfirming();
      expect(controller.state.rulesStage, WizardRulesStage.confirming);
      expect(controller.state.isGeneratingRules, isFalse, reason: '确认页零调用');
    });

    test('「开始写」才进入生成中；isGeneratingRules 为阶段派生', () {
      final controller = toAnswering();
      addTearDown(controller.dispose);
      controller
        ..enterRulesConfirming()
        ..startRulesGeneration();
      expect(controller.state.rulesStage, WizardRulesStage.generating);
      expect(controller.state.isGeneratingRules, isTrue);
      controller.showRulesGenerated('产物');
      expect(controller.state.rulesStage, WizardRulesStage.previewing);
      expect(controller.state.isGeneratingRules, isFalse);
    });

    test('生成中取消：回确认页（已耗成本由页面确认弹窗告知）', () {
      final controller = toAnswering();
      addTearDown(controller.dispose);
      controller
        ..enterRulesConfirming()
        ..startRulesGeneration()
        ..cancelRulesGeneration();
      expect(controller.state.rulesStage, WizardRulesStage.confirming);
    });
  });
}
