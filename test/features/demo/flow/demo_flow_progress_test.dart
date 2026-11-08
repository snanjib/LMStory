import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/demo/domain/demo_scene.dart';
import 'package:lmstory/features/demo/presentation/demo_bridge.dart';
import 'package:lmstory/features/demo/presentation/demo_flow.dart';

/// 流程推进回归：记忆步必须以「真实进入记忆库→返回」两段事件推进，
/// 底层挂载的输入区不得充当返回证据；向导步按选择结果推进。
void main() {
  late AppDatabase db;
  late DemoBridge bridge;
  late DemoFlowController flow;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customStatement(
      'INSERT INTO chat_sessions (session_id, title, mode, created_at, '
      'last_active_at, message_count, next_turn) VALUES '
      "('s1', 't', 'advanced', 1, 2, 2, 2)",
    );
    bridge = DemoBridge();
    flow = DemoFlowController(bridge: bridge, demoDb: db)..start();
  });

  tearDown(() async {
    flow.dispose();
    bridge.dispose();
    await db.close();
  });

  void jumpTo(String stepId) => bridge.tutorial.jumpTo(stepId);

  group('记忆步两段推进', () {
    test('设置面板打开（memoryButton 注册）→ 进入 memoryView', () async {
      jumpTo(DemoStepId.settingsIntro.name);
      bridge.spotlights.register(
        DemoTargetIds.sessionMemoryButton,
        const Rect.fromLTWH(0, 0, 40, 40),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        bridge.tutorial.current?.id,
        DemoStepId.memoryView.name,
        reason: '设置面板真实打开后推进',
      );
    });

    test('进入记忆库（factualTab 注册）→ 进入记忆查看步；底层 inputArea 不算返回', () async {
      jumpTo(DemoStepId.memoryView.name);
      // 缺陷形态：inputArea（底层会话页常驻）注册曾直接把步骤推到收尾
      bridge.spotlights.register(
        DemoTargetIds.sessionInputArea,
        const Rect.fromLTWH(0, 0, 200, 80),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        bridge.tutorial.current?.id,
        DemoStepId.memoryView.name,
        reason: '仅底层输入区注册不得推进——必须先真实进入记忆库',
      );

      bridge.spotlights.register(
        DemoTargetIds.memoryFactualTab,
        const Rect.fromLTWH(0, 0, 300, 500),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        bridge.tutorial.current?.id,
        DemoStepId.memoryInspect.name,
        reason: '记忆库页真实打开（事实 Tab 注册）才进入查看步',
      );
    });

    test('返回会话（factualTab 注销）→ 进入收尾步', () async {
      // 镜像真实序列：memoryView 因 factualTab 出现而推进——跳步时
      // 该目标已在注册表里（步入口快照应包含它）
      bridge.spotlights.register(
        DemoTargetIds.memoryFactualTab,
        const Rect.fromLTWH(0, 0, 300, 500),
      );
      jumpTo(DemoStepId.memoryInspect.name);
      await Future<void>.delayed(Duration.zero);
      expect(bridge.tutorial.current?.id, DemoStepId.memoryInspect.name);

      // 用户 pop 记忆库页 → 目标注销
      bridge.spotlights.unregister(DemoTargetIds.memoryFactualTab);
      await Future<void>.delayed(Duration.zero);
      expect(
        bridge.tutorial.current?.id,
        DemoStepId.backToSession.name,
        reason: '记忆库目标消失=用户已返回会话',
      );
    });
  });

  group('向导步按选择结果推进', () {
    test('wizardModel：模型选择完成且翻页（嵌入步目标注册）才推进', () async {
      jumpTo(DemoStepId.wizardModel.name);
      // 1. 目标已注册但未选模型：不得推进
      bridge.spotlights.register(
        DemoTargetIds.wizardEmbeddingChoice,
        const Rect.fromLTWH(0, 0, 100, 100),
      );
      bridge.wizardProgress.value = const WizardProgress(modelReady: false);
      await Future<void>.delayed(Duration.zero);
      expect(
        bridge.tutorial.current?.id,
        DemoStepId.wizardModel.name,
        reason: '未选择不得推进（即便目标已注册）',
      );

      // 2. 仅选完模型但未翻页（嵌入步目标未出现）：不得提前推进（防等待卡）
      bridge.spotlights.unregister(DemoTargetIds.wizardEmbeddingChoice);
      bridge.wizardProgress.value = const WizardProgress(modelReady: true);
      await Future<void>.delayed(Duration.zero);
      expect(
        bridge.tutorial.current?.id,
        DemoStepId.wizardModel.name,
        reason: '未翻页进嵌入步时必须停留模型步，不可提前跳步触发等待卡',
      );

      // 3. 模型就绪且点下一步翻页（嵌入步目标出现或 currentStep>=1）：推进
      bridge.spotlights.register(
        DemoTargetIds.wizardEmbeddingChoice,
        const Rect.fromLTWH(0, 0, 100, 100),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        bridge.tutorial.current?.id,
        DemoStepId.wizardEmbedding.name,
        reason: '模型选择完成且进入嵌入步驱动推进',
      );
    });

    test('wizardEmbedding：配上或跳过且翻页（规则步目标注册）才推进', () async {
      jumpTo(DemoStepId.wizardEmbedding.name);
      bridge.wizardProgress.value = const WizardProgress(modelReady: true);
      await Future<void>.delayed(Duration.zero);
      expect(bridge.tutorial.current?.id, DemoStepId.wizardEmbedding.name);

      // 仅选完嵌入但未翻页：不提前推进
      bridge.wizardProgress.value =
          const WizardProgress(modelReady: true, embeddingDone: true);
      await Future<void>.delayed(Duration.zero);
      expect(bridge.tutorial.current?.id, DemoStepId.wizardEmbedding.name);

      // 点下一步翻页（规则步目标注册）后推进
      bridge.spotlights.register(
        DemoTargetIds.wizardTemplateList,
        const Rect.fromLTWH(0, 0, 100, 100),
      );
      await Future<void>.delayed(Duration.zero);
      expect(bridge.tutorial.current?.id, DemoStepId.wizardRules.name);
    });

    test('wizardRules：模板确认完成才推进', () async {
      jumpTo(DemoStepId.wizardRules.name);
      bridge.wizardProgress.value =
          const WizardProgress(modelReady: true, embeddingDone: true);
      await Future<void>.delayed(Duration.zero);
      expect(bridge.tutorial.current?.id, DemoStepId.wizardRules.name);

      bridge.wizardProgress.value = const WizardProgress(
        modelReady: true,
        embeddingDone: true,
        rulesConfirmed: true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        bridge.tutorial.current?.id,
        DemoStepId.wizardRules.name,
        reason: '确认完成但不立即推进——等用户点真实「完成」关闭向导',
      );

      // 用户点「完成」→ 向导关闭 → 会话页挂载 → inputArea 新出现
      bridge.spotlights.register(
        DemoTargetIds.sessionInputArea,
        const Rect.fromLTWH(0, 0, 200, 80),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(
        bridge.tutorial.current?.id,
        DemoStepId.sessionInput.name,
        reason: '规则确认完成后等会话页出现（目标注册推进）',
      );
    });
  });

  group('收尾步确认可点（完成体验触发交接）', () {
    test('backToSession 步 confirmLabel 可用，点击收尾回调', () async {
      jumpTo(DemoStepId.backToSession.name);
      var finished = false;
      bridge.tutorial.onFinished = () => finished = true;

      final step = bridge.tutorial.current!;
      expect(step.confirmLabel, isNotNull, reason: '收尾步必须提供确认（完成体验）');

      // bubble 修复语义：提供 confirmLabel 的步骤按钮可用
      // （真实按钮行为在 widget 测试覆盖；此处断言步骤语义）
      bridge.tutorial.next();
      expect(finished, isTrue, reason: '收尾步确认 → 教程结束 → 交接回调');
    });
  });

  group('向导步动态目标指示（下一步焦点切换与放行区）', () {
    test('wizardModel：未选时指向 wizardGmRow，模型就绪且下一步存在时指向 wizardNext', () async {
      jumpTo(DemoStepId.wizardModel.name);
      final step = bridge.tutorial.current!;

      // 注册 wizardGmRow 和 wizardNext
      bridge.spotlights.register(
        DemoTargetIds.wizardGmRow,
        const Rect.fromLTWH(0, 0, 200, 50),
      );
      bridge.spotlights.register(
        DemoTargetIds.wizardNext,
        const Rect.fromLTWH(0, 500, 200, 50),
      );

      // 1. modelReady = false -> 指向 wizardGmRow
      bridge.wizardProgress.value = const WizardProgress(modelReady: false);
      expect(
        step.resolveTargetId(bridge.spotlights.isRegistered),
        DemoTargetIds.wizardGmRow,
      );

      // 2. modelReady = true -> 指向 wizardNext
      bridge.wizardProgress.value = const WizardProgress(modelReady: true);
      expect(
        step.resolveTargetId(bridge.spotlights.isRegistered),
        DemoTargetIds.wizardNext,
      );
    });

    test('wizardEmbedding：未选时指向 wizardEmbeddingChoice，完成且下一步存在时指向 wizardNext',
        () async {
      jumpTo(DemoStepId.wizardEmbedding.name);
      final step = bridge.tutorial.current!;

      bridge.spotlights.register(
        DemoTargetIds.wizardEmbeddingChoice,
        const Rect.fromLTWH(0, 100, 200, 50),
      );
      bridge.spotlights.register(
        DemoTargetIds.wizardNext,
        const Rect.fromLTWH(0, 500, 200, 50),
      );

      // 1. embeddingDone = false -> 指向 wizardEmbeddingChoice
      bridge.wizardProgress.value = const WizardProgress(modelReady: true);
      expect(
        step.resolveTargetId(bridge.spotlights.isRegistered),
        DemoTargetIds.wizardEmbeddingChoice,
      );

      // 2. embeddingDone = true -> 指向 wizardNext
      bridge.wizardProgress.value =
          const WizardProgress(modelReady: true, embeddingDone: true);
      expect(
        step.resolveTargetId(bridge.spotlights.isRegistered),
        DemoTargetIds.wizardNext,
      );
    });

    test('roundRunning 步配置放行区 sessionChatBody 且不全局放行', () async {
      jumpTo(DemoStepId.roundRunning.name);
      final step = bridge.tutorial.current!;
      expect(step.passThroughTargetId, DemoTargetIds.sessionChatBody);
      expect(step.allowUntargetedTaps, isFalse);
    });

    test('settingsIntro 步配置放行区、候选目标与全屏交互放行', () async {
      jumpTo(DemoStepId.settingsIntro.name);
      final step = bridge.tutorial.current!;
      expect(step.passThroughTargetId, DemoTargetIds.sessionChatBody);
      expect(step.allowUntargetedTaps, isTrue);
      expect(step.candidateTargetIds, contains(DemoTargetIds.sessionSettingsButton));
      expect(step.candidateTargetIds, contains(DemoTargetIds.sessionMemoryButton));

      // 仅 sessionSettingsButton 挂载时解析至 settingsButton
      bridge.spotlights.register(
        DemoTargetIds.sessionSettingsButton,
        const Rect.fromLTWH(300, 40, 40, 40),
      );
      expect(
        step.resolveTargetId(bridge.spotlights.isRegistered),
        DemoTargetIds.sessionSettingsButton,
      );

      // sessionMemoryButton 挂载时（设置面板已开）优先解析至 memoryButton
      bridge.spotlights.register(
        DemoTargetIds.sessionMemoryButton,
        const Rect.fromLTWH(50, 400, 200, 50),
      );
      expect(
        step.resolveTargetId(bridge.spotlights.isRegistered),
        DemoTargetIds.sessionMemoryButton,
      );
    });

    test('memoryView 步配置全屏交互放行与动态目标解析', () async {
      jumpTo(DemoStepId.memoryView.name);
      final step = bridge.tutorial.current!;
      expect(step.allowUntargetedTaps, isTrue);

      bridge.spotlights.register(
        DemoTargetIds.sessionMemoryButton,
        const Rect.fromLTWH(50, 400, 200, 50),
      );
      expect(
        step.resolveTargetId(bridge.spotlights.isRegistered),
        DemoTargetIds.sessionMemoryButton,
      );

      bridge.spotlights.register(
        DemoTargetIds.memoryFactualTab,
        const Rect.fromLTWH(0, 0, 100, 40),
      );
      expect(
        step.resolveTargetId(bridge.spotlights.isRegistered),
        DemoTargetIds.memoryFactualTab,
      );
    });
  });
}
