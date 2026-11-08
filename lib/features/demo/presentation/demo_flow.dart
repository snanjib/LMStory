import 'dart:async';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/tutorial/tutorial_controller.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/demo/domain/demo_scene.dart';
import 'package:lmstory/features/demo/presentation/demo_bridge.dart';
import 'package:lmstory/i18n/strings.g.dart' show Translations, t;

/// 演示流程驱动器（Demo 容器内）：把「目标注册事件 + 演示库业务状态」
/// 翻译成教程步骤推进。
///
/// 推进条件全部是存在性/业务性（契约 §10.3）——点击与路由本身不推进；
/// Spotlight 只展示，本控制器不替用户调用任何业务。
class DemoFlowController {
  DemoFlowController({
    required DemoBridge bridge,
    required AppDatabase demoDb,
  })  : _bridge = bridge,
        _db = demoDb;

  final DemoBridge _bridge;
  final AppDatabase _db;

  Timer? _poll;
  bool _started = false;
  final Set<String> _seenTargets = {};

  TutorialController get tutorial => _bridge.tutorial;

  List<TutorialStep> _buildSteps() {
    final d = t; // slang 全局实例（随当前 locale）

    String? confirmFor(DemoStepId id) =>
        id == DemoStepId.backToSession ? d.demo.steps.finish : null;

    TutorialStep step(
      DemoStepId id,
      String? targetId, {
      List<String> candidateTargetIds = const [],
      List<String> extraHighlightTargetIds = const [],
      String? Function()? targetResolver,
      String? passThroughTargetId,
      bool allowUntargetedTaps = false,
    }) =>
        TutorialStep(
          id: id.name,
          title: _titleOf(d, id),
          message: _messageOf(d, id),
          targetId: targetId,
          candidateTargetIds: candidateTargetIds,
          extraHighlightTargetIds: extraHighlightTargetIds,
          targetResolver: targetResolver,
          passThroughTargetId: passThroughTargetId,
          allowUntargetedTaps: allowUntargetedTaps,
          confirmLabel: confirmFor(id),
        );

    return [
      step(DemoStepId.homeWizardEntry, DemoTargetIds.homeWizardCard),
      step(
        DemoStepId.wizardModel,
        DemoTargetIds.wizardGmRow,
        candidateTargetIds: const [
          DemoTargetIds.wizardNext,
          DemoTargetIds.wizardGmRow,
        ],
        targetResolver: _resolveModelTarget,
      ),
      step(
        DemoStepId.wizardEmbedding,
        DemoTargetIds.wizardEmbeddingChoice,
        candidateTargetIds: const [
          DemoTargetIds.wizardNext,
          DemoTargetIds.wizardEmbeddingModelItem,
          DemoTargetIds.wizardEmbeddingChoice,
        ],
        targetResolver: _resolveEmbeddingTarget,
      ),
      step(
        DemoStepId.wizardRules,
        DemoTargetIds.wizardTemplateList,
        candidateTargetIds: const [
          DemoTargetIds.wizardNext,
          DemoTargetIds.wizardRulesConfirm,
          DemoTargetIds.wizardTemplateItem,
          DemoTargetIds.wizardTemplateList,
        ],
        targetResolver: _resolveRulesTarget,
      ),
      step(DemoStepId.sessionInput, DemoTargetIds.sessionInputArea),
      step(
        DemoStepId.roundRunning,
        null,
        passThroughTargetId: DemoTargetIds.sessionChatBody,
      ),
      step(
        DemoStepId.settingsIntro,
        DemoTargetIds.sessionSettingsButton,
        candidateTargetIds: const [
          DemoTargetIds.sessionSettingsButton,
          DemoTargetIds.sessionMemoryButton,
          DemoTargetIds.sessionChatBody,
          DemoTargetIds.sessionInputArea,
        ],
        targetResolver: _resolveSettingsIntroTarget,
        passThroughTargetId: DemoTargetIds.sessionChatBody,
        allowUntargetedTaps: true,
      ),
      step(
        DemoStepId.memoryView,
        DemoTargetIds.sessionMemoryButton,
        candidateTargetIds: const [
          DemoTargetIds.sessionMemoryButton,
          DemoTargetIds.memoryFactualTab,
          DemoTargetIds.sessionSettingsButton,
        ],
        targetResolver: _resolveMemoryViewTarget,
        allowUntargetedTaps: true,
      ),
      step(
        DemoStepId.memoryInspect,
        DemoTargetIds.memoryFactualTab,
        candidateTargetIds: const [
          DemoTargetIds.memoryBackButton,
          DemoTargetIds.memoryFactualItem,
          DemoTargetIds.memoryFactualTab,
          DemoTargetIds.memoryEpisodicItem,
          DemoTargetIds.memoryEpisodicTab,
        ],
        extraHighlightTargetIds: const [
          DemoTargetIds.memoryBackButton,
          DemoTargetIds.memoryEpisodicTab,
          DemoTargetIds.memoryFactualTab,
        ],
        targetResolver: _resolveMemoryTarget,
        allowUntargetedTaps: true,
      ),
      step(
        DemoStepId.backToSession,
        DemoTargetIds.sessionInputArea,
        candidateTargetIds: const [
          DemoTargetIds.sessionInputArea,
          DemoTargetIds.sessionSettingsButton,
          DemoTargetIds.sessionMemoryButton,
        ],
        allowUntargetedTaps: true,
      ),
    ];
  }

  String _titleOf(Translations d, DemoStepId id) => switch (id) {
        DemoStepId.homeWizardEntry => d.demo.steps.homeWizardEntry.title,
        DemoStepId.wizardModel => d.demo.steps.wizardModel.title,
        DemoStepId.wizardEmbedding => d.demo.steps.wizardEmbedding.title,
        DemoStepId.wizardRules => d.demo.steps.wizardRules.title,
        DemoStepId.sessionInput => d.demo.steps.sessionInput.title,
        DemoStepId.roundRunning => d.demo.steps.roundRunning.title,
        DemoStepId.settingsIntro => d.demo.steps.settingsIntro.title,
        DemoStepId.memoryView => d.demo.steps.memoryView.title,
        DemoStepId.memoryInspect => d.demo.steps.memoryInspect.title,
        DemoStepId.backToSession => d.demo.steps.backToSession.title,
      };

  String _messageOf(Translations d, DemoStepId id) => switch (id) {
        DemoStepId.homeWizardEntry => d.demo.steps.homeWizardEntry.message,
        DemoStepId.wizardModel => d.demo.steps.wizardModel.message,
        DemoStepId.wizardEmbedding => d.demo.steps.wizardEmbedding.message,
        DemoStepId.wizardRules => d.demo.steps.wizardRules.message,
        DemoStepId.sessionInput => d.demo.steps.sessionInput.message,
        DemoStepId.roundRunning => d.demo.steps.roundRunning.message,
        DemoStepId.settingsIntro => d.demo.steps.settingsIntro.message,
        DemoStepId.memoryView => d.demo.steps.memoryView.message,
        DemoStepId.memoryInspect => d.demo.steps.memoryInspect.message,
        DemoStepId.backToSession => d.demo.steps.backToSession.message,
      };

  /// 启动（幂等）：装配步骤、恢复检查点、挂目标/轮询监听
  void start() {
    if (_started) return;
    _started = true;

    tutorial
      ..onFinished = _bridge.hooks.onComplete
      ..onExitRequested = () async {
        await _bridge.hooks.onExitRequested?.call();
      };
    tutorial.begin(_buildSteps());

    final initial = _bridge.initialStepId;
    if (initial != null) {
      tutorial.jumpTo(initial);
      // 恢复到会话步时输入锁直接置位（roundRunning/settingsIntro 无需锁）
      if (initial == DemoStepId.sessionInput.name) {
        _applyStepSideEffects();
      }
    }

    tutorial.addListener(_onStepChanged);
    _bridge.wizardProgress.addListener(_onWizardProgress);
    _onStepChanged();

    _bridge.spotlights.addListener(_onRegistry);
    // lm-motion-exempt: 演示流程业务状态轮询间隔（非过渡动效）
    _poll = Timer.periodic(const Duration(milliseconds: 300), (_) => _tick());
  }

  void dispose() {
    _poll?.cancel();
    _bridge.spotlights.removeListener(_onRegistry);
    _bridge.wizardProgress.removeListener(_onWizardProgress);
    tutorial.removeListener(_onStepChanged);
  }

  // —— 步骤副作用 ——

  bool _rulesConfirmed = false;

  /// 步内目标快照（进入步骤那一刻已注册的目标集）
  Set<String> _stepEntryTargets = <String>{};

  /// 记忆真实沉淀快照（记忆步定向用）。候选数据形态不同：多数候选有
  /// 实体，个别候选零实体、只有经历事件——定向与文案以真实沉淀为准，
  /// 不为任何候选等待永不存在的实体条目。
  int? _memoryEntityCount;

  /// 记忆步只做一次真实沉淀快照（教程通知链会重入本控制器；查询后
  /// refreshTarget 再触发 _onStepChanged——无一次性守卫会形成查询循环）
  bool _memoryStatsLoaded = false;

  bool get _zeroEntities => (_memoryEntityCount ?? 1) == 0;

  Future<void> _refreshMemoryStats() async {
    try {
      final sessions = await _db
          .customSelect(
            "SELECT session_id FROM chat_sessions WHERE mode = 'advanced' "
            'ORDER BY last_active_at DESC LIMIT 1',
          )
          .get();
      if (sessions.isEmpty) return;
      final sid = sessions.first.read<String>('session_id');
      final entities = await _db.customSelect(
        'SELECT COUNT(*) AS n FROM factual_entities WHERE session_id = ?',
        variables: [Variable.withString(sid)],
      ).get();
      _memoryEntityCount = entities.first.read<int>('n');
      // 沉淀事实到位后重定向当前记忆步目标
      tutorial.refreshTarget();
    } catch (_) {
      // 查询失败下一拍重试
    }
  }

  void _onStepChanged() {
    _applyStepSideEffects();
    // 步内目标快照：只有步骤切换后「新出现」的目标才推进本步
    _stepEntryTargets = Set<String>.of(_bridge.spotlights.snapshot().keys);
    final id = tutorial.current?.id;
    if (id != null) {
      _bridge.hooks.onStepCheckpoint?.call(id);
    }
    if (id == DemoStepId.memoryView.name ||
        id == DemoStepId.memoryInspect.name) {
      if (!_memoryStatsLoaded) {
        _memoryStatsLoaded = true;
        unawaited(_refreshMemoryStats());
      }
    } else {
      _memoryStatsLoaded = false;
    }
    _evaluateRegistryAdvance();
    _evaluateWizardAdvance();
  }

  void _applyStepSideEffects() {
    final stepId = tutorial.current?.id;
    if (stepId == DemoStepId.sessionInput.name) {
      final prompt = _bridge.fixedPrompt;
      if (prompt != null) {
        // 重发安全：新一次发送同一回合前重置回放游标
        _bridge.resetReplayTurn();
        _bridge.inputLock.lockTo(prompt);
      }
    } else if (stepId == DemoStepId.roundRunning.name || stepId == null) {
      _bridge.inputLock.release();
    }
  }

  // —— 注册表事件推进 ——

  String? _resolveModelTarget() {
    final rects = _bridge.spotlights.snapshot();
    final p = _bridge.wizardProgress.value;
    if ((p?.modelReady ?? false) &&
        rects.containsKey(DemoTargetIds.wizardNext)) {
      return DemoTargetIds.wizardNext;
    }
    if (rects.containsKey(DemoTargetIds.wizardGmRow)) {
      return DemoTargetIds.wizardGmRow;
    }
    return DemoTargetIds.wizardGmRow;
  }

  String? _resolveEmbeddingTarget() {
    final rects = _bridge.spotlights.snapshot();
    final p = _bridge.wizardProgress.value;
    if ((p?.embeddingDone ?? false) &&
        rects.containsKey(DemoTargetIds.wizardNext)) {
      return DemoTargetIds.wizardNext;
    }
    if (rects.containsKey(DemoTargetIds.wizardEmbeddingModelItem)) {
      return DemoTargetIds.wizardEmbeddingModelItem;
    }
    if (rects.containsKey(DemoTargetIds.wizardEmbeddingChoice)) {
      return DemoTargetIds.wizardEmbeddingChoice;
    }
    return DemoTargetIds.wizardEmbeddingChoice;
  }

  String? _resolveRulesTarget() {
    final rects = _bridge.spotlights.snapshot();
    if (_rulesConfirmed && rects.containsKey(DemoTargetIds.wizardNext)) {
      return DemoTargetIds.wizardNext;
    }
    if (rects.containsKey(DemoTargetIds.wizardRulesConfirm)) {
      return DemoTargetIds.wizardRulesConfirm;
    }
    if (rects.containsKey(DemoTargetIds.wizardTemplateItem)) {
      return DemoTargetIds.wizardTemplateItem;
    }
    if (rects.containsKey(DemoTargetIds.wizardTemplateList)) {
      return DemoTargetIds.wizardTemplateList;
    }
    return DemoTargetIds.wizardTemplateList;
  }

  String? _resolveMemoryTarget() {
    final rects = _bridge.spotlights.snapshot();
    // 零实体候选：本轮真实沉淀只有经历事件，定向经历条目而非空实体区
    if (_zeroEntities && rects.containsKey(DemoTargetIds.memoryEpisodicItem)) {
      return DemoTargetIds.memoryEpisodicItem;
    }
    if (rects.containsKey(DemoTargetIds.memoryFactualItem)) {
      return DemoTargetIds.memoryFactualItem;
    }
    if (rects.containsKey(DemoTargetIds.memoryEpisodicItem)) {
      return DemoTargetIds.memoryEpisodicItem;
    }
    if (rects.containsKey(DemoTargetIds.memoryFactualTab)) {
      return DemoTargetIds.memoryFactualTab;
    }
    if (rects.containsKey(DemoTargetIds.memoryBackButton)) {
      return DemoTargetIds.memoryBackButton;
    }
    return DemoTargetIds.memoryFactualTab;
  }

  String? _resolveSettingsIntroTarget() {
    final rects = _bridge.spotlights.snapshot();
    if (rects.containsKey(DemoTargetIds.sessionMemoryButton)) {
      return DemoTargetIds.sessionMemoryButton;
    }
    if (rects.containsKey(DemoTargetIds.sessionSettingsButton)) {
      return DemoTargetIds.sessionSettingsButton;
    }
    return null;
  }

  String? _resolveMemoryViewTarget() {
    final rects = _bridge.spotlights.snapshot();
    // 零实体候选：优先指向经历分区（本轮沉淀所在），非空实体才先看实体
    if (_zeroEntities && rects.containsKey(DemoTargetIds.memoryEpisodicTab)) {
      return DemoTargetIds.memoryEpisodicTab;
    }
    if (rects.containsKey(DemoTargetIds.memoryFactualTab)) {
      return DemoTargetIds.memoryFactualTab;
    }
    if (rects.containsKey(DemoTargetIds.sessionMemoryButton)) {
      return DemoTargetIds.sessionMemoryButton;
    }
    if (rects.containsKey(DemoTargetIds.sessionSettingsButton)) {
      return DemoTargetIds.sessionSettingsButton;
    }
    return null;
  }

  void _onRegistry() {
    _evaluateRegistryAdvance();
  }

  void _onWizardProgress() {
    _evaluateWizardAdvance();
    _evaluateRegistryAdvance();
    tutorial.refreshTarget();
  }

  void _evaluateWizardAdvance() {
    final progress = _bridge.wizardProgress.value;
    if (progress == null) return;
    switch (tutorial.current?.id) {
      case 'wizardRules':
        if (progress.rulesConfirmed) {
          _rulesConfirmed = true;
          // 不立即推进：等用户点真实「完成」（向导关闭、会话页出现，
          // inputArea 注册）后再进入 sessionInput 步
        }
      default:
        break;
    }
  }

  bool _appeared(String targetId) {
    final present = _bridge.spotlights.snapshot().containsKey(targetId);
    return present && !_stepEntryTargets.contains(targetId);
  }

  bool _disappeared(String targetId) {
    final presentAtEntry = _stepEntryTargets.contains(targetId);
    return presentAtEntry &&
        !_bridge.spotlights.snapshot().containsKey(targetId);
  }

  void _evaluateRegistryAdvance() {
    final rects = _bridge.spotlights.snapshot();
    for (final id in rects.keys) {
      _seenTargets.add(id);
    }

    switch (tutorial.current?.id) {
      case 'homeWizardEntry':
        if (rects.containsKey(DemoTargetIds.wizardGmRow)) {
          tutorial.next();
        }
      case 'wizardModel':
        final p = _bridge.wizardProgress.value;
        if ((p?.modelReady ?? false) &&
            ((p?.currentStep ?? 0) >= 1 ||
                rects.containsKey(DemoTargetIds.wizardEmbeddingChoice))) {
          tutorial.next();
        }
      case 'wizardEmbedding':
        final p = _bridge.wizardProgress.value;
        if ((p?.embeddingDone ?? false) &&
            ((p?.currentStep ?? 0) >= 2 ||
                rects.containsKey(DemoTargetIds.wizardTemplateList))) {
          tutorial.next();
        }
      case 'wizardRules':
        // 规则确认完成 + 用户点真实「完成」关闭向导 → 会话页出现
        if (_rulesConfirmed && _appeared(DemoTargetIds.sessionInputArea)) {
          tutorial.next();
        }
      case 'settingsIntro':
        if (_appeared(DemoTargetIds.sessionMemoryButton) ||
            rects.containsKey(DemoTargetIds.sessionMemoryButton)) {
          tutorial.next();
        }
      case 'memoryView':
        // 真实进入记忆库（事实 Tab 挂载），底层 inputArea 不算
        if (_appeared(DemoTargetIds.memoryFactualTab) ||
            rects.containsKey(DemoTargetIds.memoryFactualTab)) {
          tutorial.next();
        }
      case 'memoryInspect':
        // 用户返回：记忆库目标在步内消失（进步时曾存在）
        if (_disappeared(DemoTargetIds.memoryFactualTab) ||
            (_seenTargets.contains(DemoTargetIds.memoryFactualTab) &&
                !rects.containsKey(DemoTargetIds.memoryFactualTab))) {
          tutorial.next();
        }
      case 'backToSession':
        // 收尾确认按钮推进（overlay 消费 confirmLabel）
        break;
      default:
        break;
    }
  }

  // —— 业务状态轮询（仅会话/回合步）——

  Future<void> _tick() async {
    final stepId = tutorial.current?.id;
    if (stepId == null) return;
    try {
      switch (stepId) {
        case 'sessionInput':
          // 物化即回填会话 id；回合启动（事件日志出现）→ 进入 roundRunning
          final sessions = await _db
              .customSelect(
                "SELECT session_id FROM chat_sessions WHERE mode = 'advanced' "
                'ORDER BY last_active_at DESC LIMIT 1',
              )
              .get();
          if (sessions.isEmpty) return;
          final sid = sessions.first.read<String>('session_id');
          await _bridge.hooks.onSessionRecorded?.call(sid);
          final events = await _db.customSelect(
            'SELECT COUNT(*) AS n FROM agent_events WHERE session_id = ?',
            variables: [Variable.withString(sid)],
          ).get();
          if (events.first.read<int>('n') > 0) {
            // 首轮发送/物化开始：锁定本次候选（禁止热换另一包），再推进
            _bridge.selection?.lock();
            tutorial.next();
          }
        case 'roundRunning':
          final sessions = await _db
              .customSelect(
                'SELECT session_id, next_turn FROM chat_sessions '
                "WHERE mode = 'advanced' ORDER BY last_active_at DESC LIMIT 1",
              )
              .get();
          if (sessions.isEmpty) return;
          final row = sessions.first;
          final sid = row.read<String>('session_id');
          await _bridge.hooks.onSessionRecorded?.call(sid);
          final nextTurn = row.read<int>('next_turn');
          if (nextTurn >= 2) {
            final replies = await _db.customSelect(
              'SELECT COUNT(*) AS n FROM chat_messages '
              "WHERE session_id = ? AND role = 'assistant'",
              variables: [Variable.withString(sid)],
            ).get();
            if (replies.first.read<int>('n') > 0) {
              tutorial.next();
            }
          }
        default:
          break;
      }
    } catch (_) {
      // 轮询失败下一拍重试（库关闭竞态等）
    }
  }
}

/// Demo 容器内的流程 provider（由 DemoScope 的 bootstrap widget 激活）
final demoFlowProvider = Provider<DemoFlowController>((ref) {
  final bridge = ref.watch(demoBridgeProvider);
  assert(bridge != null, 'demoFlowProvider is only available within DemoScope');
  final controller = DemoFlowController(
    bridge: bridge!,
    demoDb: ref.watch(demoDbProviderForFlow),
  );
  ref.onDispose(controller.dispose);
  controller.start();
  return controller;
});

/// 流程侧取演示库（复用装配时的覆盖实例）
final demoDbProviderForFlow = Provider<AppDatabase>(
  (ref) => throw StateError(
    'demoDbProviderForFlow must be overridden by buildDemoOverrides',
  ),
);
