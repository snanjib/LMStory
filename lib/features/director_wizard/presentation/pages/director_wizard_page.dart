import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/tutorial/spotlight_target.dart';
import 'package:lmstory/features/chat/domain/entities/session_phase_models.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/demo/domain/demo_scene.dart';
import 'package:lmstory/features/demo/presentation/demo_bridge.dart';
import 'package:lmstory/features/demo/presentation/demo_selection_controller.dart';
import 'package:lmstory/features/director_wizard/domain/entities/director_wizard_outcome.dart';
import 'package:lmstory/features/director_wizard/domain/services/world_prompt_composer.dart';
import 'package:lmstory/features/director_wizard/domain/services/world_prompt_generator.dart';
import 'package:lmstory/features/director_wizard/presentation/controllers/director_wizard_controller.dart';
import 'package:lmstory/features/director_wizard/presentation/widgets/wizard_option_row.dart';
import 'package:lmstory/features/director_wizard/presentation/widgets/wizard_quiz_flow.dart';
import 'package:lmstory/features/settings/data/provider_templates.dart';
import 'package:lmstory/features/settings/domain/entities/model_capability.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/widgets/default_model_picker_sheet.dart';
import 'package:lmstory/features/settings/presentation/widgets/manual_model_id_confirmation.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/director_setting_rows.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/features/templates/presentation/support/template_l10n.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:url_launcher/url_launcher.dart';

/// 导演会话创建向导（2026-10-17 需求）。
///
/// 全屏三步分步页：①模型步（两分支）②嵌入模型步（可跳）③项目规则步。
/// 走完 pop 携带 [DirectorWizardOutcome]（配置就绪的会话覆盖）；
/// 右上角「跳过」退出即弃（pop 无结果）。
///
/// 骨架遵循 onboarding 同款视觉约定：场地自承载（lmVenue）+
/// scaffoldBgOf + 分段进度条 + PageView + 底部上一步/下一步。
class DirectorWizardPage extends ConsumerStatefulWidget {
  const DirectorWizardPage({super.key});

  @override
  ConsumerState<DirectorWizardPage> createState() => _DirectorWizardPageState();
}

class _DirectorWizardPageState extends ConsumerState<DirectorWizardPage> {
  final PageController _pageController = PageController();
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _keyCtrl = TextEditingController();
  final TextEditingController _manualModelCtrl = TextEditingController();
  final TextEditingController _embNameCtrl = TextEditingController();
  final TextEditingController _embKeyCtrl = TextEditingController();
  final TextEditingController _embManualCtrl = TextEditingController();
  final TextEditingController _genreCustomCtrl = TextEditingController();
  final TextEditingController _styleCustomCtrl = TextEditingController();
  final TextEditingController _characterDescCtrl = TextEditingController();
  final TextEditingController _rulesEditCtrl = TextEditingController();
  TextEditingController? _tplNameCtrl;
  bool _nameDirty = false;
  bool _embChangeExpanded = false;
  bool _embSetupExpanded = false;
  bool _isFinishing = false;

  @override
  void dispose() {
    _pageController.dispose();
    _nameCtrl.dispose();
    _keyCtrl.dispose();
    _manualModelCtrl.dispose();
    _embNameCtrl.dispose();
    _embKeyCtrl.dispose();
    _embManualCtrl.dispose();
    _genreCustomCtrl.dispose();
    _styleCustomCtrl.dispose();
    _characterDescCtrl.dispose();
    _rulesEditCtrl.dispose();
    _tplNameCtrl?.dispose();
    super.dispose();
  }

  DirectorWizardController get _wizard =>
      ref.read(directorWizardProvider.notifier);

  void _determineModelBranch(SettingsState next) {
    if (next.isLoading) return;
    if (!mounted) return;
    final wizard = ref.read(directorWizardProvider);
    if (wizard.modelBranch != WizardModelBranch.undetermined) return;
    _wizard.enterModelStep(
      anyKeyedPreset: next.apiKeyStatus.values.any((v) => v),
    );
    // 默认模型预选（advancedConfig 可能后到，advancedConfig 监听里补跑）
    _tryPrefillDefaultGm();
    final name = ref.read(directorWizardProvider).providerName;
    if (!_nameDirty && name.isNotEmpty) {
      _nameCtrl.text = name;
    }
  }

  void _determineEmbedding(AdvancedConfig? config) {
    if (config == null || !mounted) return;
    final wizard = ref.read(directorWizardProvider);
    if (wizard.embeddingStatus != WizardEmbeddingStatus.undetermined) return;
    _wizard.enterEmbeddingStep(
      currentPresetId: config.embeddingPresetId,
      currentModelId: config.embeddingModelId,
    );
  }

  void _goToStep(int index) {
    if (index < 0 || index >= DirectorWizardState.totalSteps) return;
    _pageController.animateToPage(
      index,
      duration: LmMotion.step,
      curve: LmMotion.easeEmphasis,
    );
  }

  void _next() {
    final state = ref.read(directorWizardProvider);
    if (state.currentStep == 0 && !state.isModelReady) return;
    if (state.currentStep == 1 && state.isEmbeddingChoicePending) return;
    if (state.currentStep < DirectorWizardState.totalSteps - 1) {
      _goToStep(state.currentStep + 1);
    } else {
      _finish();
    }
  }

  void _prev() {
    final current = ref.read(directorWizardProvider).currentStep;
    if (current > 0) _goToStep(current - 1);
  }

  /// 退出即弃：不写任何配置、不产出会话覆盖。
  ///
  /// 完成事务进行中无效（终审 F2：全局写入落定前退出会交付用户
  /// 刚刚明确丢弃的会话，或与完成 pop 双重出栈）。
  void _exit() {
    if (_isFinishing) return;
    Navigator.of(context).pop();
  }

  /// 完成：三步数据齐备后交付产物并 pop。
  ///
  /// **演示作用域会话入口屏障**：绑定未收敛不得按旧选择创建会话——
  /// 等待未完成绑定请求收敛（选择器关闭时未提交请求已被取消），
  /// 将向导选择与已提交候选对齐并锁定；真实会话 Controller/网关消费
  /// 配置与画像之前固定同一份已提交候选。屏障期间完成按钮呈处理中
  /// 状态（禁用+进度指示）。
  ///
  /// 写入时序：未配置分支在「完成」统一下发全局默认——
  /// broadcast_chat 两键（Simple 默认模型）+ advanced.phase_models.
  /// generating 两键（导演 GM），下次新建不必重走全程；已配置分支
  /// 只随草稿带会话覆盖，全局不动。嵌入两键已在嵌入步确认时写。
  Future<void> _finish() async {
    if (_isFinishing) return;
    final state = ref.read(directorWizardProvider);
    if (!state.isModelReady) return;
    setState(() => _isFinishing = true);
    final selection = ref.read(demoBridgeProvider)?.selection;
    if (selection != null) {
      final committedModelId = await selection.settleForSessionEntry();
      if (!mounted) return;
      final current = ref.read(directorWizardProvider);
      if (current.gmModelId != committedModelId) {
        // 向导选择与已提交候选不一致（仅极端竞态可达）：以已提交候选
        // 为准同步最终确认——提交者必为用户真实点击，不冒充旧选择。
        final presetId = _presetIdForModel(committedModelId);
        if (presetId == null) {
          // 无法对齐：阻止完成，回退处理中状态
          setState(() => _isFinishing = false);
          return;
        }
        _wizard.selectExistingModel(
          presetId: presetId,
          modelId: committedModelId,
        );
      }
    }
    if (!mounted) return;
    final settled = ref.read(directorWizardProvider);
    if (settled.shouldWriteGlobalDefaults) {
      // 全局默认写入失败不阻断交付（会话覆盖仍齐）——best-effort
      try {
        await ref.read(settingsNotifierProvider.notifier).setDefaultModel(
              presetId: settled.gmPresetId,
              modelId: settled.gmModelId,
            );
        await writeDirectorOverride(
          ref,
          'advanced.phase_models.generating_preset_id',
          settled.gmPresetId,
        );
        await writeDirectorOverride(
          ref,
          'advanced.phase_models.generating_model_id',
          settled.gmModelId,
        );
      } catch (e) {
        debugPrint('Wizard finish global defaults write failed: $e');
      }
    }
    if (!mounted) return;
    Navigator.of(context).pop(
      DirectorWizardOutcome(
        phaseModels: SessionPhaseModels(
          generatingPresetId: settled.gmPresetId,
          generatingModelId: settled.gmModelId,
        ),
        // null = 跳过规则步，跟随全局兜底（物化语义：null 才回退全局）
        systemPromptOverride: settled.confirmedRules,
        // 「初始化你的角色」两产物（开关关闭时派生 getter 恒 null）
        characterInitPrompt: settled.characterInitPrompt,
        characterCardId: settled.characterCardId,
      ),
    );
  }

  /// 在已装载供应商里定位模型所属 preset id（会话入口屏障对齐用）
  String? _presetIdForModel(String modelId) {
    for (final preset in ref.read(settingsNotifierProvider).presets) {
      if (preset.cachedModels.any((m) => m.modelId == modelId)) {
        return preset.presetId;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    // 模型步分支判定：settings 装载完成后按「任一 preset 带 Key」定一次。
    // listen 管装载后变化；微任务兜底「订阅时已装载」的初始态——
    // build 内 postFrame 链路在 pumpAndSettle 边界有跨帧竞态。
    ref.listen<SettingsState>(
      settingsNotifierProvider,
      (previous, next) => _determineModelBranch(next),
    );
    // 演示进度上报：向导选择结果实时写入桥（页面销毁即停报，
    // 与 autoDispose 状态语义一致；流程按选择结果推进步骤）
    ref.listen<DirectorWizardState>(directorWizardProvider, (prev, next) {
      final bridge = ref.read(demoBridgeProvider);
      if (bridge == null) return;
      bridge.wizardProgress.value = WizardProgress(
        modelReady: next.isModelReady,
        embeddingDone: next.selectedEmbeddingModelId != null ||
            next.embeddingChoice == WizardEmbeddingChoice.skip,
        rulesConfirmed: next.confirmedRules != null,
        currentStep: next.currentStep,
      );
    });
    Future.microtask(() {
      if (!mounted) return;
      final bridge = ref.read(demoBridgeProvider);
      if (bridge == null) return;
      final s = ref.read(directorWizardProvider);
      bridge.wizardProgress.value = WizardProgress(
        modelReady: s.isModelReady,
        embeddingDone: s.selectedEmbeddingModelId != null ||
            s.embeddingChoice == WizardEmbeddingChoice.skip,
        rulesConfirmed: s.confirmedRules != null,
        currentStep: s.currentStep,
      );
    });
    Future.microtask(
      () => _determineModelBranch(ref.read(settingsNotifierProvider)),
    );
    // 嵌入步现状判定：advancedConfig 装载完成后按全局嵌入键快照定一次；
    // 同源补跑默认 GM 预选（导演覆盖键在 advancedConfig 里，可能晚于
    // settings 装载到达）
    ref.listen<AsyncValue<AdvancedConfig>>(
      advancedConfigProvider,
      (previous, next) {
        _determineEmbedding(next.valueOrNull);
        _tryPrefillDefaultGm();
      },
    );
    Future.microtask(
      () => _determineEmbedding(
        ref.read(advancedConfigProvider).valueOrNull,
      ),
    );

    final colors = context.lm.palette;
    final t = Translations.of(context);
    final wizard = ref.watch(directorWizardProvider);
    final currentStep = wizard.currentStep;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (currentStep > 0) {
          _prev();
        } else {
          final bridge = ref.read(demoBridgeProvider);
          if (bridge != null) {
            bridge.tutorial.requestExit();
          } else {
            _exit();
          }
        }
      },
      child: context.lmVenue(
        // 场地由本页自承载（不依赖祖先幕布），再按框架口径取 Scaffold
        // 底色——与 onboarding 同构。
        Builder(
          builder: (context) => Scaffold(
            backgroundColor: context.scaffoldBgOf(colors.bg),
            appBar: AppBar(
              backgroundColor: context.scaffoldBgOf(colors.bg),
              foregroundColor: colors.ink,
              elevation: 0,
              scrolledUnderElevation: 0,
              surfaceTintColor: Colors.transparent,
              actions: [
                TextButton(
                  onPressed: _exit,
                  child: Text(
                    t.directorWizard.exit,
                    style:
                        SimpleTextStyles.bodySm.copyWith(color: colors.muted),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            body: SafeArea(
              child: Column(
                children: [
                  _buildStepIndicator(colors, t, currentStep),
                  Expanded(
                    child: PageView(
                      controller: _pageController,
                      // GM 未就绪 / 嵌入步未显式选择时锁滑动——仅靠
                      // goToStep 守卫会出现「页面已滑走、步号还在原地」的
                      // 失联态（终审 F1 同款物理门控）
                      physics: wizard.isModelReady &&
                              !(currentStep == 1 &&
                                  wizard.isEmbeddingChoicePending)
                          ? null
                          : const NeverScrollableScrollPhysics(),
                      onPageChanged: _wizard.goToStep,
                      children: [
                        _buildModelStep(colors, t),
                        _buildEmbeddingStep(colors, t),
                        _buildRulesStep(colors, t),
                      ],
                    ),
                  ),
                  _buildBottomBar(colors, t, currentStep),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── 步骤指示器（与 onboarding 同款分段进度条） ────────────────────

  Widget _buildStepIndicator(
    LmPalette colors,
    Translations t,
    int currentStep,
  ) {
    const totalSteps = DirectorWizardState.totalSteps;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sLg,
        vertical: SimpleSpacing.sSm,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxWidth: LmLayout.readingWidthOf(context)),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  t.directorWizard.stepIndicator(
                    current: currentStep + 1,
                    total: totalSteps,
                  ),
                  style: SimpleTextStyles.caption.copyWith(color: colors.faint),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: SimpleSpacing.sMd),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final segmentWidth =
                        (constraints.maxWidth - (totalSteps - 1) * 4) /
                            totalSteps;
                    return Row(
                      children: List.generate(totalSteps, (i) {
                        final isDone = i < currentStep;
                        final isCurrent = i == currentStep;
                        // segmentWidth 只扣了 n-1 个间隔——末段不带 margin，
                        // 否则 Row 总宽超 4px（debug 溢出黄黑条）。
                        return Container(
                          width: segmentWidth,
                          height: 3,
                          margin: i == totalSteps - 1
                              ? EdgeInsets.zero
                              : const EdgeInsets.only(right: 4),
                          decoration: BoxDecoration(
                            color: isCurrent
                                ? colors.primary
                                : (isDone
                                    ? colors.muted
                                    : colors.surfaceVariant),
                            borderRadius: BorderRadius.circular(
                              context.lmUi.radius(LmCorner.xs),
                            ),
                          ),
                        );
                      }),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 步骤 1：模型步（两分支） ─────────────────────────────────────

  Widget _buildModelStep(LmPalette colors, Translations t) {
    final wizard = ref.watch(directorWizardProvider);
    final settings = ref.watch(settingsNotifierProvider);
    return _StepScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StepTitle(colors: colors, title: t.directorWizard.modelStepTitle),
          const SizedBox(height: SimpleSpacing.sSm),
          _buildTeachBlock(colors, t.directorWizard.model.teach),
          switch (wizard.modelBranch) {
            WizardModelBranch.configured => _buildConfiguredBranch(
                colors,
                t,
                settings,
              ),
            WizardModelBranch.unconfigured => _buildUnconfiguredBranch(
                colors,
                t,
                wizard,
              ),
            WizardModelBranch.undetermined => const SizedBox(
                height: SimpleSpacing.s3xl,
              ),
          },
          if (wizard.isModelReady) ...[
            const SizedBox(height: SimpleSpacing.sLg),
            _buildSelectedSummary(colors, t, wizard, settings),
          ],
        ],
      ),
    );
  }

  /// 白话教学块（两分支共用，步骤标题下）：向非技术用户解释
  /// 「现在选的是什么、不同选择意味着什么」。
  Widget _buildTeachBlock(LmPalette colors, String text) {
    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sMd),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
        border: Border.all(color: colors.divider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lightbulb, size: 18, color: colors.primary),
          const SizedBox(width: SimpleSpacing.sSm),
          Expanded(
            child: Text(
              text,
              style: SimpleTextStyles.bodySm.copyWith(color: colors.muted),
            ),
          ),
        ],
      ),
    );
  }

  /// 已配置分支：当前选中行（默认模型预选）+「换一个主编」弹
  /// [DefaultModelPickerSheet]（供应商分组折叠，多供应商用户不再
  /// 面对全仓平铺）。
  Widget _buildConfiguredBranch(
    LmPalette colors,
    Translations t,
    SettingsState settings,
  ) {
    final wizard = ref.watch(directorWizardProvider);
    var chatModelCount = 0;
    for (final preset in settings.presets) {
      chatModelCount +=
          preset.cachedModels.where((m) => m.type == ModelType.chat).length;
    }
    if (chatModelCount == 0) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: SimpleSpacing.sSm),
          Text(
            t.directorWizard.model.noModelsYet,
            style: SimpleTextStyles.body.copyWith(color: colors.muted),
          ),
          const SizedBox(height: SimpleSpacing.sMd),
          OutlinedButton.icon(
            onPressed: () {
              setState(() => _nameDirty = false);
              _wizard.switchToProviderSetup();
              // 与模板选中同源同步名称框（终审 F7：不同步时按钮按
              // 隐藏的预填态放行，用户面对空输入框）
              _nameCtrl.text = ref.read(directorWizardProvider).providerName;
            },
            icon: Icon(Icons.add, size: 16, color: colors.primary),
            label: Text(t.directorWizard.model.addProvider),
          ),
        ],
      );
    }
    final selected = _findSelectedChatModel(settings, wizard);
    // Spotlight 目标覆盖整段可操作区：预选选中行/「换一支笔」/无预选
    // 「选择模型」按钮三种形态都在挖孔内（高亮可操作入口，契约 §10.3）
    return SpotlightTarget(
      id: DemoTargetIds.wizardGmRow,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: SimpleSpacing.sMd),
          Text(
            t.directorWizard.model.introConfigured,
            style: SimpleTextStyles.body.copyWith(color: colors.muted),
          ),
          const SizedBox(height: SimpleSpacing.sMd),
          if (selected != null) ...[
            // 当前选中行：预选的默认模型（或刚换的笔）
            Container(
              padding: const EdgeInsets.all(SimpleSpacing.sMd),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(
                  context.lmUi.radius(LmCorner.xs),
                ),
                border: Border.all(color: colors.divider),
              ),
              child: Row(
                children: [
                  Icon(Icons.check_circle, size: 20, color: colors.primary),
                  const SizedBox(width: SimpleSpacing.sMd),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          selected.modelName,
                          style: SimpleTextStyles.body.copyWith(
                            color: colors.ink,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          selected.presetName,
                          style: SimpleTextStyles.caption.copyWith(
                            color: colors.faint,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: SimpleSpacing.sSm),
            OutlinedButton.icon(
              onPressed: _showModelPickerSheet,
              icon: Icon(Icons.swap_horiz, size: 16, color: colors.primary),
              label: Text(t.directorWizard.model.changePen),
            ),
          ] else
            // 罕见边缘：默认链无可预选项（默认模型从未设置且无导演覆盖）
            OutlinedButton.icon(
              onPressed: _showModelPickerSheet,
              icon: Icon(Icons.edit_note, size: 16, color: colors.primary),
              label: Text(t.directorWizard.model.pickModel),
            ),
        ],
      ),
    );
  }

  /// 弹供应商分组模型选择器（复用设置页现成设计）；选中只写向导
  /// 暂存（会话覆盖语义），不动全局默认。
  ///
  /// 演示作用域（桥非空）：sheet 顶部注入仿真说明横幅；选择先经
  /// 选择协调点绑定候选（换包+持久身份），**绑定成功**（正常完成）
  /// 才确认向导选择——sheet 据此关闭并提示；绑定失败以异常上抛作为
  /// 失败回执（sheet 保持打开可就地重试，不触发向导推进、不弹成功
  /// 提示），错误说明由本页 snackbar 承担。选择器关闭时取消全部
  /// 未提交的绑定请求（已提交选择不受影响）——迟到请求不得在向导
  /// 推进或页面离开后换包。
  Future<void> _showModelPickerSheet() async {
    final t = Translations.of(context);
    final wizard = ref.read(directorWizardProvider);
    final bridge = ref.read(demoBridgeProvider);
    await showLmSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DefaultModelPickerSheet(
        selectedPresetId: wizard.gmPresetId,
        selectedModelId: wizard.gmModelId,
        title: t.directorWizard.model.pickerTitle,
        successMessage: t.directorWizard.model.pickToast,
        hintText: bridge != null ? t.demo.candidates.pickerHint : null,
        onModelSelected: (presetId, modelId) async {
          if (presetId == null || modelId == null) return;
          final selection = bridge?.selection;
          if (selection != null) {
            // 失败/锁定：抛出→sheet 保持打开；取消：静默失效不推进
            await _bindDemoCandidate(selection, modelId);
          }
          if (!mounted) return;
          _wizard.selectExistingModel(presetId: presetId, modelId: modelId);
        },
      ),
    );
    // 选择器已关闭（无论以何种方式）：取消仍未提交的绑定请求
    bridge?.selection?.cancelPendingSelections();
  }

  /// 演示作用域选模绑定（可等待回执）：绑定完成正常返回放行向导确认；
  /// 失败（候选不可用/已锁定/身份保存失败）就地提示后**重新抛出**——
  /// 作为 sheet 的失败回执保持其打开可重试，绝不触发「选模成功」；
  /// 选择被取消（选择器关闭）静默上抛，不提示、不确认向导选择。
  Future<void> _bindDemoCandidate(
    DemoSelectionController selection,
    String modelId,
  ) async {
    try {
      await selection.bindByVirtualModelId(modelId);
    } on DemoCandidateCancelledException {
      rethrow;
    } catch (e) {
      debugPrint('demo candidate bind failed: $e');
      if (!mounted) rethrow;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            Translations.of(context).demo.candidates.bindFailed,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      );
      rethrow;
    }
  }

  /// 已配置分支的当前选中模型定位（displayName/preset 名用于卡片展示）。
  ({String presetName, String modelName})? _findSelectedChatModel(
    SettingsState settings,
    DirectorWizardState wizard,
  ) {
    final presetId = wizard.gmPresetId;
    final modelId = wizard.gmModelId;
    if (presetId == null || presetId.isEmpty || modelId == null) return null;
    for (final preset in settings.presets) {
      if (preset.presetId != presetId) continue;
      for (final model in preset.cachedModels) {
        if (model.modelId == modelId) {
          return (
            presetName: preset.name,
            modelName: model.displayName ?? model.modelId,
          );
        }
      }
    }
    return null;
  }

  /// 摘要解释行的模型显示名（先查拉取列表，再查已配置缓存）。
  String _gmDisplayName(
    DirectorWizardState wizard,
    SettingsState settings,
  ) {
    for (final model in wizard.fetchedModels) {
      if (model.modelId == wizard.gmModelId) {
        return model.displayName ?? model.modelId;
      }
    }
    final found = _findSelectedChatModel(settings, wizard);
    if (found != null) return found.modelName;
    return wizard.gmModelId ?? '';
  }

  /// 已配置分支默认预选：导演 GM 全局覆盖优先，兜底 Simple 默认模型
  /// （与运行时会话解析同向），预选=「不换就用你的默认模型」的落点。
  void _tryPrefillDefaultGm() {
    final wizard = ref.read(directorWizardProvider);
    if (wizard.modelBranch != WizardModelBranch.configured) return;
    if (wizard.gmPresetId != null && wizard.gmPresetId!.isNotEmpty) return;
    final advanced = ref.read(advancedConfigProvider).valueOrNull;
    if (advanced != null &&
        advanced.generatingPresetId.isNotEmpty &&
        advanced.generatingModelId.isNotEmpty) {
      _wizard.selectExistingModel(
        presetId: advanced.generatingPresetId,
        modelId: advanced.generatingModelId,
      );
      return;
    }
    final settings = ref.read(settingsNotifierProvider);
    final presetId = settings.defaultPresetId;
    final modelId = settings.defaultModelId;
    if (presetId != null &&
        presetId.isNotEmpty &&
        modelId != null &&
        modelId.isNotEmpty) {
      _wizard.selectExistingModel(presetId: presetId, modelId: modelId);
    }
  }

  /// 未配置分支：模板选择（推荐 DeepSeek）→ 申请 Key 外跳 → 贴 Key →
  /// 创建并拉取 → 选模型（失败手填兜底）。
  Widget _buildUnconfiguredBranch(
    LmPalette colors,
    Translations t,
    DirectorWizardState wizard,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: SimpleSpacing.sLg),
        _SectionLabel(
          colors: colors,
          label: t.directorWizard.model.pickProvider,
        ),
        const SizedBox(height: SimpleSpacing.sXs),
        // 模板=整行描边选项（推荐语常显，选中即解释范式）
        for (var i = 0; i < ProviderTemplates.all.length; i++) ...[
          if (i > 0) const SizedBox(height: SimpleSpacing.sSm),
          WizardOptionRow(
            title: ProviderTemplates.all[i].name,
            description: _templateHintOf(
              t,
              ProviderTemplates.all[i].templateId,
            ),
            icon: Icons.cloud_outlined,
            selected: wizard.selectedTemplateId ==
                ProviderTemplates.all[i].templateId,
            onTap: () => _onTemplateTap(ProviderTemplates.all[i]),
          ),
        ],
        if (_apiKeyUrlOf(wizard.selectedTemplateId) != null) ...[
          const SizedBox(height: SimpleSpacing.sSm),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => _launchKeyUrl(wizard.selectedTemplateId),
              icon: Icon(Icons.open_in_new, size: 16, color: colors.primary),
              label: Text(t.directorWizard.model.applyKey),
            ),
          ),
        ],
        const SizedBox(height: SimpleSpacing.sMd),
        _WizardTextField(
          controller: _nameCtrl,
          colors: colors,
          label: t.directorWizard.model.nameField,
          enabled: wizard.createdPresetId == null,
          onChanged: (v) {
            _nameDirty = true;
            _wizard.setProviderName(v);
          },
        ),
        const SizedBox(height: SimpleSpacing.sMd),
        _WizardTextField(
          controller: _keyCtrl,
          colors: colors,
          label: t.directorWizard.model.keyField,
          obscureText: true,
          enabled: wizard.createdPresetId == null,
          onChanged: _wizard.setApiKeyInput,
        ),
        const SizedBox(height: SimpleSpacing.sMd),
        if (wizard.createdPresetId == null)
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed:
                  wizard.isSettingUpProvider || !_canCreateProvider(wizard)
                      ? null
                      : () => _wizard.createAndFetchModels(),
              style: ElevatedButton.styleFrom(
                backgroundColor: colors.primary,
                foregroundColor: colors.surface,
                elevation: 0,
                padding: const EdgeInsets.symmetric(
                  vertical: SimpleSpacing.sMd,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(
                    context.lmUi.radius(LmCorner.xs),
                  ),
                ),
              ),
              child: wizard.isSettingUpProvider
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      t.directorWizard.model.createAndFetch,
                      style: SimpleTextStyles.body.copyWith(
                        color: colors.surface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
        if (wizard.createdPresetId != null && wizard.fetchedModels.isEmpty) ...[
          const SizedBox(height: SimpleSpacing.sMd),
          Text(
            t.settings.provider.fetchEmpty,
            style: SimpleTextStyles.bodySm.copyWith(color: colors.muted),
          ),
          const SizedBox(height: SimpleSpacing.sSm),
          _WizardTextField(
            controller: _manualModelCtrl,
            colors: colors,
            label: t.directorWizard.model.manualModelId,
            onChanged: _wizard.setManualModelId,
            autocorrect: false,
          ),
          const SizedBox(height: SimpleSpacing.sSm),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: wizard.manualModelId.trim().isEmpty
                  ? null
                  : () async {
                      final id = wizard.manualModelId.trim();
                      final confirmed = await confirmManualModelId(context, id);
                      if (!mounted ||
                          !confirmed ||
                          _manualModelCtrl.text.trim() != id) {
                        return;
                      }
                      await _wizard.useManualModel();
                    },
              child: Text(t.directorWizard.model.useManual),
            ),
          ),
        ],
        if (wizard.gmSelectableModels.isNotEmpty) ...[
          const SizedBox(height: SimpleSpacing.sLg),
          _SectionLabel(
            colors: colors,
            label: t.directorWizard.model.pickModel,
          ),
          for (final model in wizard.gmSelectableModels)
            _ModelRow(
              colors: colors,
              modelId: model.modelId,
              displayName: model.displayName,
              selected: wizard.gmModelId == model.modelId &&
                  wizard.gmPresetId == wizard.createdPresetId,
              onTap: () => _wizard.selectFetchedModel(model.modelId),
            ),
        ],
      ],
    );
  }

  bool _canCreateProvider(DirectorWizardState wizard) =>
      wizard.selectedTemplateId.isNotEmpty &&
      wizard.providerName.trim().isNotEmpty &&
      wizard.apiKeyInput.trim().isNotEmpty;

  /// 模板推荐语（每家一句，白话讲「这家是什么路子」）。
  String? _templateHintOf(Translations t, String templateId) =>
      switch (templateId) {
        'tpl-deepseek' => t.directorWizard.model.templateHints.deepseek,
        'tpl-openai' => t.directorWizard.model.templateHints.openai,
        'tpl-openrouter' => t.directorWizard.model.templateHints.openrouter,
        'tpl-anthropic' => t.directorWizard.model.templateHints.anthropic,
        'tpl-gemini' => t.directorWizard.model.templateHints.gemini,
        'tpl-nvidia-nim' => t.directorWizard.model.templateHints.nvidia,
        'tpl-agnes' => t.directorWizard.model.templateHints.agnes,
        _ => null,
      };

  void _onTemplateTap(ProviderTemplate tpl) {
    setState(() => _nameDirty = false);
    _nameCtrl.text = tpl.name;
    _wizard.selectTemplate(templateId: tpl.templateId, displayName: tpl.name);
  }

  String? _apiKeyUrlOf(String templateId) =>
      ProviderTemplates.findById(templateId)?.apiKeyUrl;

  Future<void> _launchKeyUrl(String templateId) async {
    final url = _apiKeyUrlOf(templateId);
    if (url == null) return;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  /// 已选摘要（选中即解释行 + 测试连接，可选，人话结果就地展示）。
  Widget _buildSelectedSummary(
    LmPalette colors,
    Translations t,
    DirectorWizardState wizard,
    SettingsState settings,
  ) {
    final resultText = wizard.testResult == null
        ? null
        : _testResultMessage(t, wizard.testResult!);
    final resultOk = wizard.testResult == 'success';
    final modelName = _gmDisplayName(wizard, settings);
    final hint = wizard.modelBranch == WizardModelBranch.configured
        ? t.directorWizard.model.selectedHintConfigured(model: modelName)
        : t.directorWizard.model.selectedHintNew(model: modelName);
    // 演示作用域：已选卡片附近的仿真说明（操作当时可见，非选后补发）
    final isDemo = ref.watch(demoBridgeProvider) != null;
    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sMd),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
        border: Border.all(color: colors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          WizardExplanationLine(text: hint),
          if (isDemo) ...[
            const SizedBox(height: SimpleSpacing.sXs),
            Text(
              t.demo.candidates.selectedHint,
              style: SimpleTextStyles.caption.copyWith(color: colors.muted),
            ),
          ],
          const SizedBox(height: SimpleSpacing.sXs),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: wizard.isTestingConnection
                  ? null
                  : () => _wizard.testSelectedConnection(),
              child: wizard.isTestingConnection
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(t.directorWizard.model.testConnection),
            ),
          ),
          if (resultText != null) ...[
            const SizedBox(height: SimpleSpacing.sXs),
            Text(
              resultText,
              style: SimpleTextStyles.caption.copyWith(
                color: resultOk ? colors.success : colors.error,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 测试连接结果 → 人话文案（映射与供应商详情页同口径）。
  String _testResultMessage(Translations t, String result) {
    if (result == 'success') return t.settings.provider.testResult.success;
    final parts = result.replaceFirst('fail:', '');
    final bar = parts.indexOf('|');
    final kind = bar == -1 ? 'unknown' : parts.substring(0, bar);
    final raw = bar == -1 ? parts : parts.substring(bar + 1);
    final labels = t.settings.provider.testResult;
    return switch (kind) {
      'auth' => labels.failAuth(status: '401/403'),
      'network' => labels.failNetwork,
      'endpoint' => labels.failEndpoint(status: '404'),
      'server' => labels.failServer(status: '5xx'),
      _ => labels.fail(error: raw),
    };
  }

  // ── 步骤 2/3：嵌入模型步与项目规则步 ─────────────

  Widget _buildEmbeddingStep(LmPalette colors, Translations t) {
    final wizard = ref.watch(directorWizardProvider);
    final settings = ref.watch(settingsNotifierProvider);
    return _StepScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StepTitle(
            colors: colors,
            title: t.directorWizard.embeddingStepTitle,
          ),
          const SizedBox(height: SimpleSpacing.sSm),
          _buildTeachBlock(colors, t.directorWizard.embedding.teach),
          const SizedBox(height: SimpleSpacing.sMd),
          switch (wizard.embeddingStatus) {
            WizardEmbeddingStatus.configured => _buildEmbeddingConfigured(
                colors,
                t,
                wizard,
                settings,
              ),
            WizardEmbeddingStatus.unconfigured => _buildEmbeddingUnconfigured(
                colors,
                t,
                wizard,
                settings,
              ),
            WizardEmbeddingStatus.undetermined => const SizedBox(
                height: SimpleSpacing.s3xl,
              ),
          },
          if (wizard.selectedEmbeddingModelId != null) ...[
            const SizedBox(height: SimpleSpacing.sLg),
            _SelectedBadge(
              colors: colors,
              label: t.directorWizard.embedding.selectedEmb,
              value: wizard.selectedEmbeddingModelId!,
            ),
          ],
        ],
      ),
    );
  }

  /// 已配置分支：现状卡 + 就按现状继续/换一个（无关闭——创建流程
  /// 不做配置管理，砍掉）。
  Widget _buildEmbeddingConfigured(
    LmPalette colors,
    Translations t,
    DirectorWizardState wizard,
    SettingsState settings,
  ) {
    final presetName = _presetNameOf(settings, wizard.currentEmbeddingPresetId);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(SimpleSpacing.sMd),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(
              context.lmUi.radius(LmCorner.xs),
            ),
            border: Border.all(color: colors.divider),
          ),
          child: Row(
            children: [
              Icon(Icons.memory, size: 18, color: colors.primary),
              const SizedBox(width: SimpleSpacing.sXs),
              Expanded(
                child: Text(
                  t.directorWizard.embedding.currentCard(
                    model: '$presetName · ${wizard.currentEmbeddingModelId}',
                  ),
                  style: SimpleTextStyles.bodySm.copyWith(color: colors.ink),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: SimpleSpacing.sSm),
        SpotlightTarget(
          id: DemoTargetIds.wizardEmbeddingChoice,
          child: WizardOptionRow(
            title: t.directorWizard.embedding.optionKeepTitle,
            description: t.directorWizard.embedding.optionKeepDesc,
            icon: Icons.check_circle_outline,
            selected: wizard.embeddingChoice == WizardEmbeddingChoice.keep &&
                !_embChangeExpanded,
            // 保留=把入口快照写回去——若中途「换一个」已写新值，
            // 不回写会让 UI 说的和库里存的两回事（终审 F4）
            onTap: () async {
              setState(() => _embChangeExpanded = false);
              _wizard.keepCurrentEmbedding();
              await _writeEmbeddingKeys(
                wizard.currentEmbeddingPresetId,
                wizard.currentEmbeddingModelId,
              );
            },
          ),
        ),
        const SizedBox(height: SimpleSpacing.sSm),
        WizardOptionRow(
          title: t.directorWizard.embedding.optionChangeTitle,
          description: t.directorWizard.embedding.optionChangeDesc,
          icon: Icons.swap_horiz,
          selected: _embChangeExpanded ||
              wizard.embeddingChoice == WizardEmbeddingChoice.change,
          onTap: () => setState(
            () => _embChangeExpanded = !_embChangeExpanded,
          ),
        ),
        if (_embChangeExpanded)
          _buildEmbeddingPicker(colors, t, wizard, settings),
      ],
    );
  }

  /// 未配置分支：配上（推荐）/暂时跳过两路径整行选项。
  ///
  /// 不预置默认高亮（：强制显式选择，未选择前
  /// 下一步不放行——消除「什么都不选也能过」的不透明）。
  Widget _buildEmbeddingUnconfigured(
    LmPalette colors,
    Translations t,
    DirectorWizardState wizard,
    SettingsState settings,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SpotlightTarget(
          id: DemoTargetIds.wizardEmbeddingChoice,
          child: Column(
            children: [
              WizardOptionRow(
                title: t.directorWizard.embedding.optionSetupTitle,
                description: t.directorWizard.embedding.optionSetupDesc,
                icon: Icons.memory,
                selected: _embSetupExpanded ||
                    wizard.embeddingChoice == WizardEmbeddingChoice.change,
                onTap: () => setState(
                  () => _embSetupExpanded = !_embSetupExpanded,
                ),
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              WizardOptionRow(
                title: t.directorWizard.embedding.optionSkipTitle,
                description: t.directorWizard.embedding.optionSkipDesc,
                icon: Icons.arrow_forward,
                selected: wizard.embeddingChoice == WizardEmbeddingChoice.skip,
                onTap: () {
                  setState(() => _embSetupExpanded = false);
                  _wizard.skipEmbedding();
                },
              ),
            ],
          ),
        ),
        if (_embSetupExpanded) ...[
          _buildEmbeddingPicker(colors, t, wizard, settings),
          if (!wizard.showEmbProviderFlow)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () {
                  _embNameCtrl.text =
                      DirectorWizardController.providerNameOf('tpl-deepseek');
                  _wizard.startEmbProviderFlow();
                },
                child: Text(
                  t.directorWizard.embedding.connectProvider,
                  style: SimpleTextStyles.bodySm.copyWith(
                    color: colors.primary,
                  ),
                ),
              ),
            ),
        ],
      ],
    );
  }

  /// 嵌入模型选择区（未配置分支主体 / 已配置「更换」展开区共用）。
  Widget _buildEmbeddingPicker(
    LmPalette colors,
    Translations t,
    DirectorWizardState wizard,
    SettingsState settings,
  ) {
    final embeddingModels = [
      for (final preset in settings.presets)
        for (final model
            in preset.cachedModels.where((m) => m.type == ModelType.embedding))
          (presetId: preset.presetId, model: model),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(
          colors: colors,
          label: t.directorWizard.embedding.pickSection,
        ),
        for (var i = 0; i < embeddingModels.length; i++)
          if (i == 0)
            SpotlightTarget(
              id: DemoTargetIds.wizardEmbeddingModelItem,
              child: _ModelRow(
                colors: colors,
                modelId: embeddingModels[i].model.modelId,
                displayName: embeddingModels[i].model.displayName,
                selected: wizard.selectedEmbeddingModelId ==
                    embeddingModels[i].model.modelId,
                onTap: () => _chooseAndWriteEmbedding(
                  embeddingModels[i].presetId,
                  embeddingModels[i].model.modelId,
                ),
              ),
            )
          else
            _ModelRow(
              colors: colors,
              modelId: embeddingModels[i].model.modelId,
              displayName: embeddingModels[i].model.displayName,
              selected: wizard.selectedEmbeddingModelId ==
                  embeddingModels[i].model.modelId,
              onTap: () => _chooseAndWriteEmbedding(
                embeddingModels[i].presetId,
                embeddingModels[i].model.modelId,
              ),
            ),
        if (!wizard.showEmbProviderFlow && _hasNoEmbeddingModels(settings))
          Padding(
            padding: const EdgeInsets.only(top: SimpleSpacing.sXs),
            child: Text(
              t.directorWizard.embedding.embOnlyHint,
              style: SimpleTextStyles.caption.copyWith(color: colors.faint),
            ),
          ),
        if (wizard.showEmbProviderFlow)
          _buildEmbProviderFlow(colors, t, wizard),
      ],
    );
  }

  bool _hasNoEmbeddingModels(SettingsState settings) => !settings.presets.any(
        (p) => p.cachedModels.any((m) => m.type == ModelType.embedding),
      );

  String _presetNameOf(SettingsState settings, String presetId) {
    for (final preset in settings.presets) {
      if (preset.presetId == presetId) return preset.name;
    }
    return presetId;
  }

  /// 嵌入步第二供应商接入流（与模型步创建链同构，独立状态与控制器）。
  Widget _buildEmbProviderFlow(
    LmPalette colors,
    Translations t,
    DirectorWizardState wizard,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: SimpleSpacing.sSm),
        Wrap(
          spacing: SimpleSpacing.sSm,
          runSpacing: SimpleSpacing.sXs,
          children: [
            for (final tpl in ProviderTemplates.all)
              ChoiceChip(
                label: Text(tpl.name),
                selected: wizard.embSelectedTemplateId == tpl.templateId,
                onSelected: (_) {
                  _embNameCtrl.text = tpl.name;
                  _wizard.selectEmbTemplate(
                    templateId: tpl.templateId,
                    displayName: tpl.name,
                  );
                },
              ),
          ],
        ),
        if (ProviderTemplates.findById(wizard.embSelectedTemplateId)
                ?.apiKeyUrl !=
            null)
          Padding(
            padding: const EdgeInsets.only(top: SimpleSpacing.sSm),
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => _launchKeyUrl(wizard.embSelectedTemplateId),
                icon: Icon(Icons.open_in_new, size: 16, color: colors.primary),
                label: Text(t.directorWizard.model.applyKey),
              ),
            ),
          ),
        const SizedBox(height: SimpleSpacing.sMd),
        _WizardTextField(
          controller: _embNameCtrl,
          colors: colors,
          label: t.directorWizard.model.nameField,
          enabled: wizard.embCreatedPresetId == null,
          onChanged: _wizard.setEmbProviderName,
        ),
        const SizedBox(height: SimpleSpacing.sMd),
        _WizardTextField(
          controller: _embKeyCtrl,
          colors: colors,
          label: t.directorWizard.model.keyField,
          obscureText: true,
          enabled: wizard.embCreatedPresetId == null,
          onChanged: _wizard.setEmbApiKeyInput,
        ),
        const SizedBox(height: SimpleSpacing.sMd),
        if (wizard.embCreatedPresetId == null)
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: wizard.embIsSettingUp ||
                      wizard.embSelectedTemplateId.isEmpty ||
                      wizard.embProviderName.trim().isEmpty ||
                      wizard.embApiKeyInput.trim().isEmpty
                  ? null
                  : () => _wizard.createEmbProviderAndFetch(),
              style: ElevatedButton.styleFrom(
                backgroundColor: colors.primary,
                foregroundColor: colors.surface,
                elevation: 0,
                padding: const EdgeInsets.symmetric(
                  vertical: SimpleSpacing.sMd,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(
                    context.lmUi.radius(LmCorner.xs),
                  ),
                ),
              ),
              child: wizard.embIsSettingUp
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      t.directorWizard.model.createAndFetch,
                      style: SimpleTextStyles.body.copyWith(
                        color: colors.surface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
        if (wizard.embCreatedPresetId != null) ...[
          for (final model in wizard.embSelectableModels)
            _ModelRow(
              colors: colors,
              modelId: model.modelId,
              displayName: model.displayName,
              selected: wizard.selectedEmbeddingModelId == model.modelId,
              onTap: () => _chooseAndWriteEmbedding(
                wizard.embCreatedPresetId!,
                model.modelId,
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: SimpleSpacing.sSm),
            child: Text(
              t.directorWizard.embedding.embOnlyHint,
              style: SimpleTextStyles.caption.copyWith(color: colors.faint),
            ),
          ),
          const SizedBox(height: SimpleSpacing.sSm),
          _WizardTextField(
            controller: _embManualCtrl,
            colors: colors,
            label: t.directorWizard.embedding.manualEmbModelId,
            onChanged: _wizard.setEmbManualModelId,
            autocorrect: false,
          ),
          const SizedBox(height: SimpleSpacing.sSm),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: wizard.embManualModelId.trim().isEmpty
                  ? null
                  : () async {
                      final id = wizard.embManualModelId.trim();
                      final confirmed = await confirmManualModelId(context, id);
                      if (!mounted ||
                          !confirmed ||
                          _embManualCtrl.text.trim() != id) {
                        return;
                      }
                      await _wizard.useEmbManualModel();
                      if (!mounted) return;
                      await _writeSelectedEmbedding();
                    },
              child: Text(t.directorWizard.model.useManual),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _chooseAndWriteEmbedding(String presetId, String modelId) async {
    _wizard.chooseEmbeddingModel(presetId: presetId, modelId: modelId);
    await _writeSelectedEmbedding();
  }

  Future<void> _writeSelectedEmbedding() async {
    final wizard = ref.read(directorWizardProvider);
    final presetId = wizard.selectedEmbeddingPresetId;
    final modelId = wizard.selectedEmbeddingModelId;
    if (presetId == null || modelId == null) return;
    await _writeEmbeddingKeys(presetId, modelId);
  }

  Future<void> _writeEmbeddingKeys(String? presetId, String? modelId) async {
    await writeDirectorOverride(
      ref,
      'advanced.embedding_preset_id',
      presetId,
    );
    await writeDirectorOverride(
      ref,
      'advanced.embedding_model_id',
      modelId,
    );
  }

  Widget _buildRulesStep(LmPalette colors, Translations t) {
    final wizard = ref.watch(directorWizardProvider);
    return _StepScaffold(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _StepTitle(colors: colors, title: t.directorWizard.rulesStepTitle),
          const SizedBox(height: SimpleSpacing.sSm),
          switch (wizard.rulesStage) {
            WizardRulesStage.choosing => _buildRulesChoosing(colors, t),
            WizardRulesStage.answering => _buildRulesAnswering(
                colors,
                t,
                wizard,
              ),
            WizardRulesStage.confirming => _buildRulesConfirming(
                colors,
                t,
                wizard,
              ),
            WizardRulesStage.generating => _buildRulesGenerating(
                colors,
                t,
                wizard,
              ),
            WizardRulesStage.previewing => _buildRulesPreview(
                colors,
                t,
                wizard,
              ),
            WizardRulesStage.editing => _buildRulesEditing(colors, t, wizard),
          },
          if (wizard.confirmedRules != null) ...[
            const SizedBox(height: SimpleSpacing.sLg),
            _SelectedBadge(
              colors: colors,
              label: t.directorWizard.rules.useIt,
              value: wizard.rulesPath == WizardRulesPath.template
                  ? t.directorWizard.rules.pathTemplateTitle
                  : t.directorWizard.rules.pathQuizTitle,
            ),
          ],
        ],
      ),
    );
  }

  /// 路径分叉：模板 / 问卷。
  Widget _buildRulesChoosing(LmPalette colors, Translations t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.directorWizard.rules.intro,
          style: SimpleTextStyles.body.copyWith(color: colors.muted),
        ),
        const SizedBox(height: SimpleSpacing.sLg),
        SpotlightTarget(
          id: DemoTargetIds.wizardTemplateList,
          child: _PathCard(
            colors: colors,
            icon: Icons.description_outlined,
            title: t.directorWizard.rules.pathTemplateTitle,
            desc: t.directorWizard.rules.pathTemplateDesc,
            onTap: _wizard.enterRulesTemplates,
          ),
        ),
        const SizedBox(height: SimpleSpacing.sSm),
        _PathCard(
          colors: colors,
          icon: Icons.auto_awesome,
          title: t.directorWizard.rules.pathQuizTitle,
          desc: t.directorWizard.rules.pathQuizDesc,
          onTap: () => _wizard.chooseRulesPath(WizardRulesPath.questionnaire),
        ),
      ],
    );
  }

  /// 路 A：模板列表（点击即预览模板内容）。
  Widget _buildRulesTemplates(LmPalette colors, Translations t) {
    final settings = ref.watch(settingsNotifierProvider);
    final templates = settings.templates
        .where((tpl) => tpl.kind == TemplateKind.systemPrompt)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _BackToPathButton(
          colors: colors,
          label: t.directorWizard.rules.backToPath,
          onTap: _wizard.backToRulesChoosing,
        ),
        _SectionLabel(
          colors: colors,
          label: t.directorWizard.rules.templateSection,
        ),
        for (final tpl in templates) _rulesTemplateRow(tpl, colors, t),
      ],
    );
  }

  Widget _rulesTemplateRow(
    Template template,
    LmPalette colors,
    Translations t,
  ) {
    final row = _ModelRow(
      colors: colors,
      modelId: template.localizedName(t),
      displayName: null,
      selected: false,
      onTap: () => _wizard.selectRulesTemplate(
        templateId: template.templateId,
        content: template.localizedContent(t),
      ),
    );
    if (template.templateId != 'builtin-isekai-narrator') return row;
    return SpotlightTarget(id: DemoTargetIds.wizardTemplateItem, child: row);
  }

  /// 路 B 答题（2026-10-19 方案 C 重构）：每题一张摘要卡，点开单题弹层
  /// 选择（选中即解释+原文盒在弹层内，「下一题」链式推进）——页面恒短，
  /// 不再整页平铺表单；题目以 spec 声明（[ _quizSectionSpecs ]），摘要卡
  /// 与弹层共用同一份声明，新增/调整题目只动 spec + 状态字段 + i18n。
  Widget _buildRulesAnswering(
    LmPalette colors,
    Translations t,
    DirectorWizardState wizard,
  ) {
    final labels = t.directorWizard.rules;
    if (wizard.rulesPath == WizardRulesPath.template) {
      return _buildRulesTemplates(colors, t);
    }
    final specs = _quizSectionSpecs(t);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _BackToPathButton(
          colors: colors,
          label: labels.backToPath,
          onTap: _wizard.backToRulesChoosing,
        ),
        Text(
          labels.quizOpening,
          style: SimpleTextStyles.body.copyWith(color: colors.ink),
        ),
        const SizedBox(height: SimpleSpacing.sXs),
        Text(
          labels.quizHint,
          style: SimpleTextStyles.caption.copyWith(color: colors.faint),
        ),
        const SizedBox(height: SimpleSpacing.sMd),
        for (var i = 0; i < specs.length; i++) ...[
          if (i > 0) const SizedBox(height: SimpleSpacing.sSm),
          Builder(
            builder: (context) {
              final spec = specs[i];
              final answer = spec.answerLabelOf(wizard, t);
              final customText = spec.customTextOf?.call(wizard).trim() ?? '';
              final preview = customText.isNotEmpty
                  ? '${spec.customPreviewPrefix ?? ''}$customText'
                  : spec.blockPreviewOf?.call(wizard, t);
              return WizardQuizSectionCard(
                colors: colors,
                question: spec.title,
                answer: answer,
                unansweredLabel: labels.unanswered,
                previewLine: preview,
                onTap: () => _openQuizSection(i),
              );
            },
          ),
        ],
        const SizedBox(height: SimpleSpacing.sMd),
        _buildCharacterInitSection(colors, t, wizard),
        const SizedBox(height: SimpleSpacing.sLg),
        _buildKnowCard(colors, t, wizard),
      ],
    );
  }

  /// 打开单题弹层；主按钮「下一题」链式打开下一题（末题「完成答题」
  /// 关闭即回短页——角色卡与知情卡就在下方）。
  Future<void> _openQuizSection(int index) async {
    final t = Translations.of(context);
    final specs = _quizSectionSpecs(t);
    if (index < 0 || index >= specs.length) return;
    final spec = specs[index];
    final labels = t.directorWizard.rules;
    final isLast = index == specs.length - 1;
    await showLmSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => WizardQuizSheet(
        title: spec.title,
        options: spec.options,
        selectedIdOf: spec.selectedIdOf,
        onSelected: (id) => spec.onSelected(_wizard, id),
        explanationOf: spec.explanationOf,
        promptPreviewOf: spec.promptPreviewOf,
        previewLabel: labels.promptPreviewLabel,
        customFieldLabel: spec.customFieldLabel,
        customController: spec.customController,
        customTextOf: spec.customTextOf,
        onCustomChanged: spec.onCustomChanged == null
            ? null
            : (v) => spec.onCustomChanged!(_wizard, v),
        customPreviewPrefix: spec.customPreviewPrefix,
        actionLabel: isLast ? labels.finishQuestions : labels.nextQuestion,
        onAction: () {
          Navigator.of(context).pop();
          if (!isLast) _openQuizSection(index + 1);
        },
      ),
    );
  }

  /// 问卷题目规格（模块化扩展点）：一题一份完整自描述——摘要卡答案/
  /// 原文预览、弹层选项/解释/原文/自定义输入全部由同一份 spec 派生，
  /// 两视图永不漂移。新增题目 = 增一条 spec（+控制器状态字段 + i18n 块）。
  List<_QuizSectionSpec> _quizSectionSpecs(Translations t) {
    final labels = t.directorWizard.rules;
    return [
      _QuizSectionSpec(
        title: labels.genreQuestion,
        options: [
          for (final o in _genreOptionsOf(t))
            WizardQuizOption(id: o.id, label: o.label, desc: o.desc),
        ],
        selectedIdOf: (s) => s.rulesGenreId,
        onSelected: (c, id) => c.setRulesGenre(id),
        answerLabelOf: (s, tt) =>
            s.rulesGenreId == null || s.rulesGenreId!.isEmpty
                ? null
                : _optionLabelOf(_genreOptionsOf(tt), s.rulesGenreId),
        blockPreviewOf: (s, tt) =>
            (s.rulesGenreId == null || s.rulesGenreId!.isEmpty)
                ? null
                : _genreBlockOf(tt, s.rulesGenreId!),
        explanationOf: (id, label) => labels.quizHintGenre(label: label),
        promptPreviewOf: (id) => id.isEmpty ? null : _genreBlockOf(t, id),
        customFieldLabel: labels.genreCustomHint,
        customController: _genreCustomCtrl,
        customTextOf: (s) => s.rulesGenreCustom,
        onCustomChanged: (c, v) => c.setRulesGenreCustom(v),
        customPreviewPrefix: labels.blocks.userSupplementPrefix,
      ),
      _QuizSectionSpec(
        title: labels.styleQuestion,
        options: [
          for (final o in _styleOptionsOf(t))
            WizardQuizOption(id: o.id, label: o.label, desc: o.desc),
        ],
        selectedIdOf: (s) => s.rulesStyleId,
        onSelected: (c, id) => c.setRulesStyle(id),
        answerLabelOf: (s, tt) =>
            s.rulesStyleId == null || s.rulesStyleId!.isEmpty
                ? null
                : _optionLabelOf(_styleOptionsOf(tt), s.rulesStyleId),
        blockPreviewOf: (s, tt) =>
            (s.rulesStyleId == null || s.rulesStyleId!.isEmpty)
                ? null
                : _styleBlockOf(tt, s.rulesStyleId!),
        explanationOf: (id, label) => labels.quizHintStyle,
        promptPreviewOf: (id) => id.isEmpty ? null : _styleBlockOf(t, id),
        customFieldLabel: labels.styleCustomHint,
        customController: _styleCustomCtrl,
        customTextOf: (s) => s.rulesStyleCustom,
        onCustomChanged: (c, v) => c.setRulesStyleCustom(v),
        customPreviewPrefix: labels.blocks.userSupplementPrefix,
      ),
      _QuizSectionSpec(
        title: labels.personQuestion,
        options: [
          for (final o in _personOptionsOf(t))
            WizardQuizOption(id: o.id, label: o.label, desc: o.desc),
        ],
        selectedIdOf: (s) => s.rulesPerson?.name,
        onSelected: (c, id) => c.setRulesPerson(
          id == null || id.isEmpty ? null : WorldPerson.values.byName(id),
        ),
        answerLabelOf: (s, tt) => s.rulesPerson == null
            ? null
            : _optionLabelOf(_personOptionsOf(tt), s.rulesPerson!.name),
        blockPreviewOf: (s, tt) => s.rulesPerson == null
            ? null
            : switch (s.rulesPerson!.name) {
                'first' => tt.directorWizard.rules.blocks.person.first,
                'second' => tt.directorWizard.rules.blocks.person.second,
                'third' => tt.directorWizard.rules.blocks.person.third,
                _ => null,
              },
        explanationOf: (id, label) => switch (id) {
          'first' => labels.quizHintPerson.first,
          'second' => labels.quizHintPerson.second,
          'third' => labels.quizHintPerson.third,
          _ => labels.quizHintPerson.none,
        },
        promptPreviewOf: (id) => switch (id) {
          'first' => labels.blocks.person.first,
          'second' => labels.blocks.person.second,
          'third' => labels.blocks.person.third,
          _ => null,
        },
      ),
    ];
  }

  /// 「初始化你的角色」开关区（问卷路专属）：打开后二选一——
  /// 自己描述（第 1 轮尾部一次性注入）或选现成角色卡（资料通道，
  /// 物化时应用，无需一次性提示）。
  Widget _buildCharacterInitSection(
    LmPalette colors,
    Translations t,
    DirectorWizardState wizard,
  ) {
    final labels = t.directorWizard.rules;
    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sMd),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
        border: Border.all(color: colors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  labels.characterInitTitle,
                  style: SimpleTextStyles.title3.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Switch(
                value: wizard.rulesCharacterInitEnabled,
                onChanged: (v) =>
                    _wizard.setRulesCharacterInitEnabled(enabled: v),
              ),
            ],
          ),
          const SizedBox(height: SimpleSpacing.s2xs),
          Text(
            labels.characterInitDesc,
            style: SimpleTextStyles.caption.copyWith(color: colors.faint),
          ),
          if (wizard.rulesCharacterInitEnabled) ...[
            const SizedBox(height: SimpleSpacing.sSm),
            WizardOptionRow(
              title: labels.characterInitDescribeTitle,
              description: labels.characterInitDescribeDesc,
              icon: Icons.edit_note,
              selected: wizard.rulesCharacterInitMode ==
                  WizardCharacterInitMode.describe,
              onTap: () => _wizard.setRulesCharacterInitMode(
                WizardCharacterInitMode.describe,
              ),
            ),
            const SizedBox(height: SimpleSpacing.sSm),
            WizardOptionRow(
              title: labels.characterInitCardTitle,
              description: labels.characterInitCardDesc,
              icon: Icons.badge_outlined,
              selected:
                  wizard.rulesCharacterInitMode == WizardCharacterInitMode.card,
              onTap: () => _wizard.setRulesCharacterInitMode(
                WizardCharacterInitMode.card,
              ),
            ),
            if (wizard.rulesCharacterInitMode ==
                WizardCharacterInitMode.describe) ...[
              const SizedBox(height: SimpleSpacing.sSm),
              _WizardTextField(
                controller: _characterDescCtrl,
                colors: colors,
                label: labels.characterInitHint,
                maxLines: 4,
                onChanged: _wizard.setRulesCharacterDescription,
              ),
            ] else ...[
              const SizedBox(height: SimpleSpacing.sSm),
              if (wizard.rulesCharacterCardId != null)
                WizardExplanationLine(
                  text: labels.characterInitCardSelected(
                    name: wizard.rulesCharacterCardName,
                  ),
                ),
              const SizedBox(height: SimpleSpacing.sXs),
              OutlinedButton(
                onPressed: _pickCharacterCard,
                child: Text(labels.characterInitPickCard),
              ),
            ],
          ],
        ],
      ),
    );
  }

  /// 角色卡选择（card 模式）：资源库卡列表 → 弹层单选。
  /// 库为空时提示先去资源库（不阻断向导，可切回自己描述）。
  Future<void> _pickCharacterCard() async {
    final cards = await ref
        .read(resourceLibraryRepositoryProvider)
        .getAllCharacterCards();
    if (!mounted) return;
    final labels = Translations.of(context).directorWizard.rules;
    if (cards.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(labels.characterInitCardEmpty),
            behavior: SnackBarBehavior.floating,
          ),
        );
      return;
    }
    final selected = await showLmSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final card in cards)
              ListTile(
                title: Text(card.name),
                onTap: () => Navigator.pop(ctx, card.cardId),
              ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;
    final card = cards.firstWhere((c) => c.cardId == selected);
    _wizard.selectRulesCharacterCard(id: selected, name: card.name);
  }

  /// 知情卡：两条路径的整行选项（选中即解释；「让模型替你写」
  /// 只进确认页，不直接调模型——调用模型是有成本的事，须独立确认）。
  Widget _buildKnowCard(
    LmPalette colors,
    Translations t,
    DirectorWizardState wizard,
  ) {
    final labels = t.directorWizard.rules;
    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sMd),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
        border: Border.all(color: colors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            labels.knowTitle,
            style: SimpleTextStyles.title3.copyWith(
              color: colors.ink,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: SimpleSpacing.sSm),
          WizardOptionRow(
            title: labels.knowAssemble,
            description: labels.knowAssembleDesc,
            icon: Icons.bolt,
            selected: false,
            onTap: () => _wizard.showRulesAssembled(_composeFromAnswers(t)),
          ),
          const SizedBox(height: SimpleSpacing.sSm),
          WizardOptionRow(
            title: labels.knowGenerate,
            description: labels.knowGenerateDesc(
              model: wizard.gmModelId ?? '',
            ),
            icon: Icons.auto_awesome,
            selected: false,
            onTap: _wizard.enterRulesConfirming,
          ),
          const SizedBox(height: SimpleSpacing.sSm),
          Text(
            labels.knowTail,
            style: SimpleTextStyles.caption.copyWith(color: colors.faint),
          ),
        ],
      ),
    );
  }

  /// 确认页（confirming 阶段整屏内容）：模型名 + 内容预告 + 消耗预告
  /// +「开始写」；点「开始写」才真正调起模型。
  Widget _buildRulesConfirming(
    LmPalette colors,
    Translations t,
    DirectorWizardState wizard,
  ) {
    final labels = t.directorWizard.rules;
    final settings = ref.watch(settingsNotifierProvider);
    final modelName = _gmDisplayName(wizard, settings);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          labels.confirmTitle(model: modelName),
          style: SimpleTextStyles.title2.copyWith(
            color: colors.ink,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: SimpleSpacing.sSm),
        Text(
          labels.confirmBody,
          style: SimpleTextStyles.body.copyWith(color: colors.muted),
        ),
        const SizedBox(height: SimpleSpacing.sLg),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            onPressed: () => _generateWorldPrompt(t),
            style: FilledButton.styleFrom(
              backgroundColor: colors.primary,
              foregroundColor: colors.surface,
              padding: const EdgeInsets.symmetric(
                vertical: SimpleSpacing.sMd,
              ),
            ),
            child: Text(
              labels.startGenerate,
              style: SimpleTextStyles.body.copyWith(
                color: colors.surface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        TextButton(
          onPressed: _wizard.backToRulesAnswering,
          child: Text(
            labels.backToPath,
            style: SimpleTextStyles.bodySm.copyWith(color: colors.muted),
          ),
        ),
      ],
    );
  }

  /// 生成中（generating 隔离态）：模型名等待态 + 「停止生成」
  /// （会浪费已耗成本，须经确认弹窗才能取消）。
  Widget _buildRulesGenerating(
    LmPalette colors,
    Translations t,
    DirectorWizardState wizard,
  ) {
    final labels = t.directorWizard.rules;
    final settings = ref.watch(settingsNotifierProvider);
    final modelName = _gmDisplayName(wizard, settings);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: SimpleSpacing.sLg),
        Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: SimpleSpacing.sMd),
            Expanded(
              child: Text(
                labels.generatingHint(model: modelName),
                style: SimpleTextStyles.body.copyWith(color: colors.ink),
              ),
            ),
          ],
        ),
        const SizedBox(height: SimpleSpacing.sLg),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton(
            onPressed: () => _confirmCancelGeneration(colors, t),
            child: Text(labels.generatingCancel),
          ),
        ),
      ],
    );
  }

  /// 停止生成的成本确认（取消会浪费已耗额度——用户 ：
  /// 生成中的返回须明确确认）。
  Future<void> _confirmCancelGeneration(
    LmPalette colors,
    Translations t,
  ) async {
    final labels = t.directorWizard.rules;
    final confirmed = await showLmDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          labels.cancelGenTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: Text(
          labels.cancelGenBody,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.common.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: colors.error),
            child: Text(labels.cancelGenConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    _wizard.cancelRulesGeneration();
  }

  /// 预览确认：四键 + 存模板开关（默认开）。
  Widget _buildRulesPreview(
    LmPalette colors,
    Translations t,
    DirectorWizardState wizard,
  ) {
    final labels = t.directorWizard.rules;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (wizard.rulesGenFallback) ...[
          Text(
            labels.genFallbackHint,
            style: SimpleTextStyles.bodySm.copyWith(color: colors.warning),
          ),
          const SizedBox(height: SimpleSpacing.sSm),
        ],
        _SectionLabel(colors: colors, label: labels.previewTitle),
        const SizedBox(height: SimpleSpacing.sXs),
        Container(
          width: double.infinity,
          // 视口比例限高（t07：宽度/高度字面量须走语义槽，比例不登记）
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.38,
          ),
          padding: const EdgeInsets.all(SimpleSpacing.sMd),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(
              context.lmUi.radius(LmCorner.xs),
            ),
            border: Border.all(color: colors.divider),
          ),
          child: SingleChildScrollView(
            child: Text(
              wizard.rulesPreviewText ?? '',
              style: SimpleTextStyles.body.copyWith(color: colors.ink),
            ),
          ),
        ),
        const SizedBox(height: SimpleSpacing.sSm),
        Wrap(
          spacing: SimpleSpacing.sSm,
          runSpacing: SimpleSpacing.sXs,
          children: [
            SpotlightTarget(
              id: DemoTargetIds.wizardRulesConfirm,
              child: FilledButton(
                onPressed: () => _useRulesPreview(t),
                style: FilledButton.styleFrom(
                  backgroundColor: colors.primary,
                  foregroundColor: colors.surface,
                ),
                child: Text(labels.useIt),
              ),
            ),
            if (wizard.rulesPreviewGenerated || wizard.rulesGenFallback)
              OutlinedButton(
                // 重新生成也走确认页（口径统一：任何模型调用前
                // 都有成本确认；代价=重试多一拍）
                onPressed: _wizard.enterRulesConfirming,
                child: Text(labels.regenerate),
              ),
            if (wizard.rulesPreviewGenerated)
              OutlinedButton(
                onPressed: () =>
                    _wizard.showRulesAssembled(_composeFromAnswers(t)),
                child: Text(labels.switchToAssemble),
              ),
            OutlinedButton(
              onPressed: _wizard.beginRulesEditing,
              child: Text(labels.editSelf),
            ),
          ],
        ),
        if (wizard.rulesPath == WizardRulesPath.questionnaire)
          SwitchListTile(
            value: wizard.saveRulesTemplate,
            onChanged: (v) => _wizard.setSaveRulesTemplate(value: v),
            title: Text(
              labels.saveTemplate,
              style: SimpleTextStyles.bodySm.copyWith(color: colors.ink),
            ),
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
        TextButton(
          onPressed: _wizard.backToRulesAnswering,
          child: Text(
            labels.reAnswer,
            style: SimpleTextStyles.bodySm.copyWith(color: colors.muted),
          ),
        ),
      ],
    );
  }

  /// 自行编辑。
  Widget _buildRulesEditing(
    LmPalette colors,
    Translations t,
    DirectorWizardState wizard,
  ) {
    if (_rulesEditCtrl.text.isEmpty && wizard.rulesEditDraft.isNotEmpty) {
      _rulesEditCtrl.text = wizard.rulesEditDraft;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SectionLabel(
          colors: colors,
          label: t.directorWizard.rules.editFieldLabel,
        ),
        const SizedBox(height: SimpleSpacing.sXs),
        TextField(
          controller: _rulesEditCtrl,
          onChanged: _wizard.updateRulesEditDraft,
          minLines: 8,
          maxLines: 14,
          style: SimpleTextStyles.body.copyWith(color: colors.ink),
          decoration: InputDecoration(
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(
                context.lmUi.radius(LmCorner.sm),
              ),
              borderSide: BorderSide(color: colors.divider),
            ),
          ),
        ),
        const SizedBox(height: SimpleSpacing.sSm),
        FilledButton(
          onPressed: _wizard.confirmRulesEdit,
          style: FilledButton.styleFrom(
            backgroundColor: colors.primary,
            foregroundColor: colors.surface,
          ),
          child: Text(t.directorWizard.rules.editConfirm),
        ),
      ],
    );
  }

  // ── 规则步动作 ───────────────────────────────────────────────────

  /// 选项集（id + 标签 + 可选描述）——slang 生成物无 map 访问，
  /// 用显式枚举映射保证 en parity 同源。
  List<({String id, String label, String? desc})> _genreOptionsOf(
    Translations t,
  ) {
    final o = t.directorWizard.rules.genreOptions;
    return [
      (id: 'xianxia', label: o.xianxia, desc: null),
      (id: 'isekai', label: o.isekai, desc: null),
      (id: 'scifi', label: o.scifi, desc: null),
      (id: 'wuxia', label: o.wuxia, desc: null),
      (id: 'urban', label: o.urban, desc: null),
      (id: 'mystery', label: o.mystery, desc: null),
      (id: 'apocalypse', label: o.apocalypse, desc: null),
      (id: 'altHistory', label: o.altHistory, desc: null),
      (id: 'courtIntrigue', label: o.courtIntrigue, desc: null),
    ];
  }

  List<({String id, String label, String? desc})> _styleOptionsOf(
    Translations t,
  ) {
    final o = t.directorWizard.rules.styleOptions;
    return [
      (id: 'plain', label: o.plain, desc: null),
      (id: 'literary', label: o.literary, desc: null),
      (id: 'humorous', label: o.humorous, desc: null),
      (id: 'terse', label: o.terse, desc: null),
      (id: 'classical', label: o.classical, desc: null),
    ];
  }

  List<({String id, String label, String? desc})> _personOptionsOf(
    Translations t,
  ) {
    final o = t.directorWizard.rules;
    return [
      (id: 'first', label: o.personFirst, desc: o.personFirstDesc),
      (id: 'second', label: o.personSecond, desc: o.personSecondDesc),
      (id: 'third', label: o.personThird, desc: o.personThirdDesc),
      (id: '', label: o.personNone, desc: o.personNoneDesc),
    ];
  }

  String _optionLabelOf(
    List<({String id, String label, String? desc})> options,
    String? id,
  ) {
    if (id == null || id.isEmpty) return '';
    for (final o in options) {
      if (o.id == id) return o.label;
    }
    return '';
  }

  WorldPromptTextSource _textSourceOf(Translations t) {
    final blocks = t.directorWizard.rules.blocks;
    return WorldPromptTextSource(
      identity: blocks.identity,
      genreBlocks: {
        for (final o in _genreOptionsOf(t)) o.id: _genreBlockOf(t, o.id),
      },
      styleBlocks: {
        for (final o in _styleOptionsOf(t)) o.id: _styleBlockOf(t, o.id),
      },
      personBlocks: {
        WorldPerson.first: blocks.person.first,
        WorldPerson.second: blocks.person.second,
        WorldPerson.third: blocks.person.third,
      },
      userSupplementPrefix: blocks.userSupplementPrefix,
    );
  }

  String _genreBlockOf(Translations t, String id) {
    final b = t.directorWizard.rules.blocks.genre;
    return switch (id) {
      'xianxia' => b.xianxia,
      'isekai' => b.isekai,
      'scifi' => b.scifi,
      'wuxia' => b.wuxia,
      'urban' => b.urban,
      'mystery' => b.mystery,
      'apocalypse' => b.apocalypse,
      'altHistory' => b.altHistory,
      'courtIntrigue' => b.courtIntrigue,
      _ => '',
    };
  }

  String _styleBlockOf(Translations t, String id) {
    final b = t.directorWizard.rules.blocks.style;
    return switch (id) {
      'plain' => b.plain,
      'literary' => b.literary,
      'humorous' => b.humorous,
      'terse' => b.terse,
      'classical' => b.classical,
      _ => '',
    };
  }

  String _composeFromAnswers(Translations t) {
    final wizard = ref.read(directorWizardProvider);
    return WorldPromptComposer.compose(
      WorldQuestionnaireAnswers(
        genreId: wizard.rulesGenreId,
        genreCustom: wizard.rulesGenreCustom,
        styleId: wizard.rulesStyleId,
        styleCustom: wizard.rulesStyleCustom,
        person: wizard.rulesPerson,
      ),
      _textSourceOf(t),
    );
  }

  Future<void> _generateWorldPrompt(Translations t) async {
    final wizardBefore = ref.read(directorWizardProvider);
    _wizard.startRulesGeneration();
    final labels = t.directorWizard.rules;
    final resolver = ref.read(configurationResolverProvider);
    final fallback = _composeFromAnswers(t);
    NamingConfig? naming;
    ({Duration connectTimeout, Duration readTimeout}) timeouts;
    try {
      naming = await resolver.resolvePresetModelNamingConfig(
        wizardBefore.gmPresetId ?? '',
        wizardBefore.gmModelId ?? '',
      );
      timeouts = await resolver.resolveTimeouts();
    } catch (_) {
      naming = null;
      timeouts = (
        connectTimeout: const Duration(seconds: 15),
        readTimeout: const Duration(seconds: 30),
      );
    }
    if (naming == null) {
      if (!_generationStillActive()) return;
      _wizard.showRulesGenerated(fallback, fallback: true);
      return;
    }
    final generator = WorldPromptGenerator(
      llmService: ref.read(llmServiceProvider),
    );
    final wizard = ref.read(directorWizardProvider);
    final person = wizard.rulesPerson == null
        ? labels.genPersonNone
        : _optionLabelOf(_personOptionsOf(t), wizard.rulesPerson?.name);
    final genre = _genreBlockOf(t, wizard.rulesGenreId ?? '');
    final style = _styleBlockOf(t, wizard.rulesStyleId ?? '');

    final result = await generator.generate(
      namingConfig: naming,
      systemPrompt: labels.genSystem,
      userPrompt: labels.genUser(
        genreLabel: genre.isEmpty ? labels.unanswered : genre,
        genreExtra: wizard.rulesGenreCustom.trim().isEmpty
            ? labels.noneExtra
            : wizard.rulesGenreCustom.trim(),
        styleLabel: style.isEmpty ? labels.unanswered : style,
        styleExtra: wizard.rulesStyleCustom.trim().isEmpty
            ? labels.noneExtra
            : wizard.rulesStyleCustom.trim(),
        person: person,
      ),
      connectTimeout: timeouts.connectTimeout,
      readTimeout: timeouts.readTimeout,
    );
    if (!mounted) return;
    // 用户已「停止生成」（回确认页）→ 在途结果作废，不回写预览
    if (!_generationStillActive()) return;
    if (result == null) {
      _wizard.showRulesGenerated(fallback, fallback: true);
    } else {
      _wizard.showRulesGenerated(result);
    }
  }

  /// 在途生成是否仍有效（阶段仍是 generating——被停止即作废）。
  bool _generationStillActive() =>
      ref.read(directorWizardProvider).rulesStage ==
      WizardRulesStage.generating;

  /// 就用这个：确认产物；开关开时弹命名框存模板（预填可改）。
  Future<void> _useRulesPreview(Translations t) async {
    _wizard.confirmRulesUse();
    final wizard = ref.read(directorWizardProvider);
    if (wizard.rulesPath != WizardRulesPath.questionnaire) return;
    if (!wizard.saveRulesTemplate) return;
    final name = await _promptTemplateName(t, _suggestedTemplateName(t));
    if (name == null || name.trim().isEmpty) return;
    try {
      await ref.read(settingsNotifierProvider.notifier).createTemplate(
            name: name.trim(),
            kind: TemplateKind.systemPrompt,
            content: wizard.confirmedRules ?? wizard.rulesPreviewText ?? '',
          );
    } catch (e) {
      // 存模板失败不撤销产物使用（产物已确认；模板可后补）
      debugPrint('Wizard save template failed: $e');
    }
  }

  String _suggestedTemplateName(Translations t) {
    final labels = t.directorWizard.rules;
    final wizard = ref.read(directorWizardProvider);
    final genreLabel = _optionLabelOf(
      _genreOptionsOf(t),
      wizard.rulesGenreId,
    );
    return genreLabel.isEmpty
        ? labels.customWorldBase
        : '${labels.customWorldBase}·$genreLabel';
  }

  Future<String?> _promptTemplateName(Translations t, String presetName) {
    final labels = t.directorWizard.rules;
    final controller = _tplNameCtrlFor(presetName);
    return showLmDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(labels.nameDialogTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            hintText: labels.nameDialogHint,
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(
                context.lmUi.radius(LmCorner.sm),
              ),
              borderSide: BorderSide(color: context.lm.palette.divider),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(t.common.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: Text(labels.save),
          ),
        ],
      ),
    );
  }

  /// 命名弹框控制器：弹窗退场动画期间仍会被 TextField 引用，
  /// 不能在 future 完成时立即释放——下次调用置换、页面销毁兜底。
  TextEditingController _tplNameCtrlFor(String presetName) {
    _tplNameCtrl?.dispose();
    return _tplNameCtrl = TextEditingController(text: presetName);
  }

  // ── 底部导航栏 ────────────────────────────────────────────────────

  Widget _buildBottomBar(LmPalette colors, Translations t, int currentStep) {
    final wizard = ref.watch(directorWizardProvider);
    final isLast = currentStep == DirectorWizardState.totalSteps - 1;
    final isFirst = currentStep == 0;
    // 模型步门控：GM 未就绪不放行；嵌入步门控：未配置分支未显式
    // 选择（配上/暂时跳过）不放行；规则步可跳，
    // 恒放行；完成事务进行中同样禁用（终审 F2 双击/抢跑）
    final nextEnabled = !_isFinishing &&
        !(isFirst && !wizard.isModelReady) &&
        !(currentStep == 1 && wizard.isEmbeddingChoicePending);

    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.divider)),
        // 同 Scaffold：琉璃下让场地透上来，不再压一条平涂带。
        color: context.scaffoldBgOf(colors.bg),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sLg,
        vertical: SimpleSpacing.sMd,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxWidth: LmLayout.readingWidthOf(context)),
          child: Row(
            children: [
              Expanded(
                child: isFirst
                    ? const SizedBox()
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: _prev,
                          child: Text(
                            t.directorWizard.prev,
                            style: SimpleTextStyles.bodySm
                                .copyWith(color: colors.muted),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
              ),
              const SizedBox(width: SimpleSpacing.sMd),
              Expanded(
                child: SpotlightTarget(
                  id: DemoTargetIds.wizardNext,
                  child: ElevatedButton(
                    onPressed: nextEnabled ? _next : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: colors.primary,
                      foregroundColor: colors.surface,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(
                        horizontal: SimpleSpacing.sLg,
                        vertical: SimpleSpacing.sMd,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(
                          context.lmUi.radius(LmCorner.xs),
                        ),
                      ),
                    ),
                    child: _isFinishing && isLast
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: colors.surface,
                                ),
                              ),
                              const SizedBox(width: SimpleSpacing.sSm),
                              Flexible(
                                child: Text(
                                  t.directorWizard.finish,
                                  style: SimpleTextStyles.body.copyWith(
                                    color: colors.surface,
                                    fontWeight: FontWeight.w600,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          )
                        : Text(
                            isLast
                                ? t.directorWizard.finish
                                : t.directorWizard.next,
                            style: SimpleTextStyles.body.copyWith(
                              color: colors.surface,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 2,
                            textAlign: TextAlign.center,
                            overflow: TextOverflow.ellipsis,
                          ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── 私有组件 ──────────────────────────────────────────────────────────

/// 单步内容骨架：水平 padding + 垂直可滚动 + 阅读列宽约束。
class _StepScaffold extends StatelessWidget {
  const _StepScaffold({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: LmLayout.readingWidthOf(context)),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(
            horizontal: SimpleSpacing.sLg,
            vertical: SimpleSpacing.sMd,
          ),
          physics: const ClampingScrollPhysics(),
          child: SizedBox(width: double.infinity, child: child),
        ),
      ),
    );
  }
}

/// 步骤标题。
class _StepTitle extends StatelessWidget {
  const _StepTitle({required this.colors, required this.title});

  final LmPalette colors;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: SimpleTextStyles.title1.copyWith(
        color: colors.ink,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

/// 分组小标题（供应商名 / 选一个模型 等）。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.colors, required this.label});

  final LmPalette colors;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: SimpleSpacing.sSm),
      child: Text(
        label,
        style: SimpleTextStyles.title3.copyWith(
          color: colors.muted,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 模型行（modelId + 可选显示名 + 选中态）。
class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.colors,
    required this.modelId,
    required this.displayName,
    required this.selected,
    required this.onTap,
  });

  final LmPalette colors;
  final String modelId;
  final String? displayName;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final shownName =
        displayName == null || displayName == modelId ? null : displayName;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: SimpleSpacing.sSm,
            vertical: SimpleSpacing.sMd,
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 20,
                color: selected ? colors.primary : colors.muted,
              ),
              const SizedBox(width: SimpleSpacing.sMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      modelId,
                      style: SimpleTextStyles.body.copyWith(color: colors.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (shownName != null)
                      Text(
                        shownName,
                        style: SimpleTextStyles.caption
                            .copyWith(color: colors.faint),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 路径分叉卡（模板/问卷）。
class _PathCard extends StatelessWidget {
  const _PathCard({
    required this.colors,
    required this.icon,
    required this.title,
    required this.desc,
    required this.onTap,
  });

  final LmPalette colors;
  final IconData icon;
  final String title;
  final String desc;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return context.lmUi.entryCard(
      context,
      onTap: onTap,
      fallbackColor: colors.surface,
      horizontal: true,
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: colors.primaryDim,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
            ),
            child: Icon(icon, color: colors.primary, size: 22),
          ),
          const SizedBox(width: SimpleSpacing.sMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: SimpleTextStyles.title3.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  desc,
                  style: SimpleTextStyles.caption.copyWith(color: colors.muted),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: colors.muted),
        ],
      ),
    );
  }
}

/// 问卷题目规格（方案 C 模块化声明）：摘要卡与单题弹层共用的一份
/// 完整自描述——答案摘要、原文预览、选项、解释、自定义输入。
/// 见页面 `_quizSectionSpecs`（扩展点）。
class _QuizSectionSpec {
  const _QuizSectionSpec({
    required this.title,
    required this.options,
    required this.selectedIdOf,
    required this.onSelected,
    required this.answerLabelOf,
    this.blockPreviewOf,
    this.explanationOf,
    this.promptPreviewOf,
    this.customFieldLabel,
    this.customController,
    this.customTextOf,
    this.onCustomChanged,
    this.customPreviewPrefix,
  });

  /// 题目标题（摘要卡与弹层共用）
  final String title;

  /// 选项集（整行按钮渲染）
  final List<WizardQuizOption> options;

  /// 当前选中 id（null/'' = 未选）
  final String? Function(DirectorWizardState state) selectedIdOf;

  /// 点选选项（null = 取消选择，不选交给 AI）
  final void Function(DirectorWizardController controller, String? id)
      onSelected;

  /// 摘要卡答案标签（null = 未选）
  final String? Function(DirectorWizardState state, Translations t)
      answerLabelOf;

  /// 摘要卡拼入原文行（已选块；null = 无）
  final String? Function(DirectorWizardState state, Translations t)?
      blockPreviewOf;

  /// 弹层内选中项白话解释
  final String? Function(String id, String label)? explanationOf;

  /// 弹层内选中项拼入原文（null/空 = 无块不显）
  final String? Function(String id)? promptPreviewOf;

  /// 自定义输入（null = 该题不支持自己说；controller 由页面持有保值）
  final String? customFieldLabel;
  final TextEditingController? customController;
  final String Function(DirectorWizardState state)? customTextOf;
  final void Function(DirectorWizardController controller, String value)?
      onCustomChanged;

  /// 自定义拼入行前缀（「用户补充：」）
  final String? customPreviewPrefix;
}

/// 答题页/模板列表顶部的「返回上一级」（回路径分叉页，答案保留）。
class _BackToPathButton extends StatelessWidget {
  const _BackToPathButton({
    required this.colors,
    required this.label,
    required this.onTap,
  });

  final LmPalette colors;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        onPressed: onTap,
        icon: Icon(Icons.arrow_back, size: 16, color: colors.muted),
        label: Text(
          label,
          style: SimpleTextStyles.bodySm.copyWith(color: colors.muted),
        ),
      ),
    );
  }
}

/// 已选徽标卡（嵌入/规则等确认后的摘要）。
class _SelectedBadge extends StatelessWidget {
  const _SelectedBadge({
    required this.colors,
    required this.label,
    required this.value,
  });

  final LmPalette colors;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sMd),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(
          context.lmUi.radius(LmCorner.xs),
        ),
        border: Border.all(color: colors.divider),
      ),
      child: Row(
        children: [
          Icon(Icons.check_circle, size: 18, color: colors.success),
          const SizedBox(width: SimpleSpacing.sXs),
          Expanded(
            child: Text(
              '$label：$value',
              style: SimpleTextStyles.bodySm.copyWith(color: colors.ink),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// 向导内文本输入（标签 + 输入框，风格与导演规则编辑行一致）。
class _WizardTextField extends StatelessWidget {
  const _WizardTextField({
    required this.controller,
    required this.colors,
    required this.label,
    required this.onChanged,
    this.obscureText = false,
    this.autocorrect = true,
    this.enabled = true,
    this.maxLines,
  });

  final TextEditingController controller;
  final LmPalette colors;
  final String label;
  final ValueChanged<String> onChanged;
  final bool obscureText;
  final bool autocorrect;
  final bool enabled;

  /// 多行输入（缺省单行；角色描述等多段文本用）
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: SimpleTextStyles.bodySm.copyWith(color: colors.muted),
        ),
        const SizedBox(height: SimpleSpacing.sXs),
        TextField(
          controller: controller,
          onChanged: onChanged,
          obscureText: obscureText,
          autocorrect: autocorrect,
          enableSuggestions: autocorrect,
          enabled: enabled,
          // obscureText 断言要求 maxLines==1；多行仅对明文输入开放
          maxLines: obscureText ? 1 : maxLines,
          minLines: obscureText || maxLines == null ? null : 1,
          style: SimpleTextStyles.body.copyWith(color: colors.ink),
          decoration: InputDecoration(
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(
                context.lmUi.radius(LmCorner.sm),
              ),
              borderSide: BorderSide(color: colors.divider),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(
                context.lmUi.radius(LmCorner.sm),
              ),
              borderSide: BorderSide(color: colors.divider),
            ),
          ),
        ),
      ],
    );
  }
}
