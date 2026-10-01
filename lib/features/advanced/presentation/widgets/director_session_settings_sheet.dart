import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/config_visibility.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/widgets/numeric_input_dialog.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/domain/entities/director_session_extension.dart';
import 'package:lmstory/features/advanced/domain/entities/narrative_pacing.dart';
import 'package:lmstory/features/advanced/domain/entities/retrieval_profile.dart';
import 'package:lmstory/features/advanced/domain/entities/tool_permissions.dart';
import 'package:lmstory/features/advanced/presentation/controllers/advanced_chat_controller.dart';
import 'package:lmstory/features/advanced/presentation/pages/advanced_chat_page.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_tool_permissions_field.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/entities/session_phase_models.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/collapsed_sections_store.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/collapsible_settings_section.dart';
import 'package:lmstory/features/settings/presentation/widgets/director_compaction_threshold_field.dart';
import 'package:lmstory/features/settings/presentation/widgets/intermediate_model_picker_sheet.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/features/story_runtime/presentation/pages/memory_browser_page.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/seed_resource_section.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/session_settings_fields.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 导演模式会话设置面板（导演设置 /15 折叠骨架，DOC-14 §3.4 同款）。
///
/// 结构：「查看记忆库」常驻置顶（不参与折叠，一键折叠跳过）+ 8 个可折叠
/// 分区——记忆管理（重建向量索引）/ 项目规则 / 模型与生成 / 剧情节奏 /
/// 监督与工具 / 运行预算 / 上下文与压缩 / 角色卡/世界书（种子应用）。
/// 标题栏一键折叠/一键展开；折叠状态全局记忆
/// （`ui.directorSession.collapsedSections`）；默认态仅首次生效
/// （展开 = 记忆管理/模型与生成，折叠 = 项目规则/剧情节奏/监督与工具/
/// 运行预算/上下文与压缩/角色卡/世界书）。
///
/// 分区按配置显示模式过滤（8 区 → 5 区）：简单模式保留记忆管理/
/// 项目规则/模型与生成/剧情节奏/角色卡世界书；监督与工具/运行预算/
/// 上下文与压缩仅进阶模式渲染。模型与生成区内行级过滤：GM 模型行
/// 保留，采样参数行仅进阶，思考档行 D-C12 保留。折叠批操作只作用于
/// 可见区，被隐藏区折叠记录原样保留。过滤只动展示层，被隐藏项已有
/// 用户值（含会话列快照值）继续生效。
///
/// 会话项 NULL/空 = 跟随全局（advanced 段对应项）；「重置为全局」逐项可用。
/// 例外（批 L 配置语义铁律快照化）：单轮时间预算与剧情节奏的重置 chip
/// 写入「当前全局值快照」，不再产生新的 NULL 继承态；其余字段重置
/// 仍写 NULL。轮开始快照语义与生成中拒绝写入（updateSession 现状）不变。
/// 滑杆量化值（commit_slider
/// min + round((v-min)/step)*step）存在 double 逐档累积误差，与全局
/// 字面值精确比较多数档位不等——「值恰等于全局」标注/重置 chip 选中态
/// 按显示精度容差判定。双 null 视为相等（未自定义）。
bool _nearlyEqual(double? a, double? b) {
  if (a == null && b == null) return true;
  if (a == null || b == null) return false;
  return (a - b).abs() < 1e-9;
}

class DirectorSessionSettingsSheet extends ConsumerStatefulWidget {
  const DirectorSessionSettingsSheet({required this.session, super.key});

  final ChatSession session;

  @override
  ConsumerState<DirectorSessionSettingsSheet> createState() =>
      _DirectorSessionSettingsSheetState();
}

/// 会话设置保存结果文案
///
/// saved=false 有两路：生成中被 updateSession 拒绝（phase 非终态，判据与
/// updateSession 守卫同口径）→ 专用引导文案；其余 = DB 写入失败 → 通用
/// 保存失败。此前一律复用 settings.saveFailed，把「请先停止本轮」的
/// 可行动信息吞掉。
String directorSaveResultText(
  Translations t, {
  required bool saved,
  required IntermediatePhase phase,
}) {
  if (saved) return t.advanced.settings.saved;
  final generating =
      phase != IntermediatePhase.idle && phase != IntermediatePhase.failed;
  return generating
      ? t.advanced.settings.saveBlockedWhileGenerating
      : t.advanced.settings.saveFailed;
}

class _DirectorSessionSettingsSheetState
    extends ConsumerState<DirectorSessionSettingsSheet> {
  /// maxSteps 约定（对齐 AgentBudget）：null = 跟随全局；0 = 无上限。
  static const int _kDefaultMaxSteps = 8;
  static const int _kUnlimitedMaxSteps = 0;

  /// 可折叠分区 id（一键折叠全集；：补 pacing，否则一键折叠后
  /// 该分区仍展开、手动收起后一键展开无法恢复）。
  static const List<String> _collapsibleSectionIds = [
    'memoryManagement',
    'rules',
    'modelGeneration',
    'pacing',
    'supervision',
    'budget',
    'context',
    'resource',
  ];

  /// 默认折叠分区（仅首次打开生效； ：默认折叠
  /// 至 2 区——记忆管理+模型展开，其余收起，首开滚动负担下降；用户手动
  /// 调整后走 CollapsedSectionsStore 全局记忆，不再回默认）。
  static const Set<String> _defaultCollapsed = {
    'resource',
    'pacing',
    'rules',
    'supervision',
    'budget',
    'context',
  };

  late final TextEditingController _rulesController;
  late final TextEditingController _maxTokensController;

  /// maxTokens 失焦提交（对齐 chat 侧
  ///  修法）——此前点别处输入静默丢弃。
  late final FocusNode _maxTokensFocusNode;

  /// 项目规则可选的系统提示词模板（与故事模式共用同一模板库）。
  List<Template> _systemPromptTemplates = const [];

  /// 折叠状态全局记忆（DOC-14 §3.4）。
  late final CollapsedSectionsStore _collapseStore;

  /// 可变副本（测试暴露的存量缺陷：此前直接引用 const 集合，
  /// 首跑无记忆时首次点击分区头抛「Cannot change an unmodifiable set」）。
  Set<String> _collapsed = {..._defaultCollapsed};

  /// 本会话未向量化记忆数（「重建向量索引」徽标）。
  int _pendingEmbeddingCount = 0;

  /// 与基准维度不一致的陈旧向量数。
  int _staleEmbeddingCount = 0;

  /// 重建中标记（禁用按钮）。
  bool _isRebuilding = false;

  /// 拖拽中的 maxSteps 显示值（修复 2026-08-23：松手才提交）。
  int? _draggingMaxSteps;

  /// 拖拽中的单轮时间预算显示值（DP-3 ：与 maxSteps 同构，
  /// 松手才提交——此前裸 Slider 逐 tick 真实写库+弹 SnackBar）。
  int? _draggingMaxDuration;

  @override
  void initState() {
    super.initState();
    _rulesController = TextEditingController(
      text: widget.session.systemPromptOverride ?? '',
    );
    _maxTokensController = TextEditingController(
      text: widget.session.maxTokens?.toString() ?? '',
    );
    _maxTokensFocusNode = FocusNode()..addListener(_onMaxTokensFocusChanged);
    _collapseStore = CollapsedSectionsStore(
      ref.read(settingsRepositoryProvider),
      storageKey: 'ui.directorSession.collapsedSections',
    );
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    final saved = await _collapseStore.loadOrNull();
    if (!mounted) return;
    if (saved != null) setState(() => _collapsed = saved);

    try {
      final templateRepo =
          ref.read<TemplateRepository>(templateRepositoryProvider);
      final templates =
          await templateRepo.getTemplatesByKind(TemplateKind.systemPrompt);
      final pending = await ref
          .read(advancedChatControllerProvider(widget.session).notifier)
          .pendingEmbeddingCount();
      if (!mounted) return;
      setState(() {
        _systemPromptTemplates = templates;
        _pendingEmbeddingCount = pending.missing;
        _staleEmbeddingCount = pending.stale;
      });
    } on Exception {
      // 模板/计数加载失败静默降级：隐藏模板按钮与徽标
    }
  }

  @override
  void dispose() {
    _rulesController.dispose();
    _maxTokensController.dispose();
    _maxTokensFocusNode.dispose();
    super.dispose();
  }

  /// 当前控制器状态（避免直接访问 StateNotifier 受保护的 `state`）。
  AdvancedChatState get _state =>
      ref.read(advancedChatControllerProvider(widget.session));

  bool _isSectionExpanded(String id) => !_collapsed.contains(id);

  Future<void> _toggleSection(String id) async {
    setState(() {
      if (_collapsed.contains(id)) {
        _collapsed.remove(id);
      } else {
        _collapsed.add(id);
      }
    });
    await _collapseStore.save(_collapsed);
  }

  /// 区级可见性键；null = 面板级元素（未登记 id 走 fail-open 视为可见）。
  String? _sectionVisibilityKey(String id) => switch (id) {
        'memoryManagement' =>
          ConfigVisibilityKeys.directorPanelMemoryManagement,
        'rules' => ConfigVisibilityKeys.directorPanelRules,
        'modelGeneration' => null, // 区壳恒显，行级过滤见 _ModelGenerationBody
        'pacing' => ConfigVisibilityKeys.directorPanelPacing,
        'supervision' => ConfigVisibilityKeys.directorPanelSupervision,
        'budget' => ConfigVisibilityKeys.directorPanelBudget,
        'context' => ConfigVisibilityKeys.directorPanelContext,
        'resource' => ConfigVisibilityKeys.directorPanelResource,
        _ => null,
      };

  /// 该区在当前配置显示模式下是否渲染。
  bool _isSectionRendered(String id, ConfigLevel level) {
    final key = _sectionVisibilityKey(id);
    return key == null || ConfigVisibility.of(key, level);
  }

  /// 当前模式下实际渲染的可折叠区 id——折叠批操作只作用于可见区，
  /// 被隐藏区的折叠记录原样保留，切回进阶模式恢复原折叠状态。
  Iterable<String> _renderedCollapsibleIds() {
    final level = ref.read(configLevelProvider);
    return _collapsibleSectionIds.where((id) => _isSectionRendered(id, level));
  }

  Future<void> _collapseAllSections() async {
    setState(() => _collapsed.addAll(_renderedCollapsibleIds()));
    await _collapseStore.save(_collapsed);
  }

  Future<void> _expandAllSections() async {
    setState(() => _collapsed.removeAll(_renderedCollapsibleIds()));
    await _collapseStore.save(_collapsed);
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final state = ref.watch(
      advancedChatControllerProvider(widget.session),
    );
    final controller = ref.read(
      advancedChatControllerProvider(widget.session).notifier,
    );
    // advanced 全局值（会话列 NULL 时的展示回退与「跟随全局」语义源）
    final advanced = ref.watch(advancedConfigProvider).valueOrNull;
    final level = ref.watch(configLevelProvider);
    // failed 态与 idle 同为「可改」——保存结果文案判定口径本就放行 failed。
    final isBusy = state.phase != IntermediatePhase.idle &&
        state.phase != IntermediatePhase.failed;

    return Container(
      decoration: BoxDecoration(
        // 琉璃下面层让位 GlassBottomSheet 工厂；经典保持原槽位零变化。
        color: context.lmSheetFaceColor(colors.bg),
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(context.lmUi.radius(LmCorner.xl)),
        ),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(IntermediateSpacing.sLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.divider,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: IntermediateSpacing.sLg),

              // ── 标题栏：标题 + 一键折叠/一键展开 ──────────────────
              Row(
                children: [
                  Expanded(
                    child: Text(
                      t.advanced.settings.sheetTitle,
                      style: IntermediateTextStyles.title
                          .copyWith(color: colors.ink),
                    ),
                  ),
                  TextButton(
                    onPressed: _collapseAllSections,
                    child: Text(
                      t.advanced.settings.collapseAll,
                      style: IntermediateTextStyles.caption
                          .copyWith(color: colors.muted),
                    ),
                  ),
                  TextButton(
                    onPressed: _expandAllSections,
                    child: Text(
                      t.advanced.settings.expandAll,
                      style: IntermediateTextStyles.caption
                          .copyWith(color: colors.muted),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: IntermediateSpacing.sSm),

              // ── 查看记忆库：常驻置顶，不参与折叠（DOC-14 §3.4）──
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => MemoryBrowserPage(
                        session: state.session,
                      ),
                    ),
                  ),
                  icon: const Icon(Icons.library_books_outlined, size: 16),
                  label: Text(t.advanced.settings.openMemoryBrowser),
                ),
              ),
              const SizedBox(height: IntermediateSpacing.sMd),

              // ── 记忆管理（默认展开）：检索松紧度 + 重建向量索引 ──
              _section(
                id: 'memoryManagement',
                title: t.advanced.settings.sectionMemoryManagement,
                child: _MemoryManagementBody(
                  pendingCount: _pendingEmbeddingCount,
                  staleCount: _staleEmbeddingCount,
                  isRebuilding: _isRebuilding,
                  canRebuild:
                      (_pendingEmbeddingCount + _staleEmbeddingCount) > 0 &&
                          !_isRebuilding &&
                          !isBusy,
                  onRebuild: () => _rebuildVectorIndex(controller),
                  retrievalProfile: state.session.sessionRetrievalProfile,
                  enabled: !isBusy,
                  onRetrievalProfileChanged: (profile) => _saveSession(
                    controller,
                    _state.session.copyWith(
                      // 快照语义：选中即写入该档具体值
                      retrievalOverrides: profile.encode(),
                    ),
                  ),
                ),
              ),

              // ── 项目规则（默认折叠）────────────────────────
              _section(
                id: 'rules',
                title: t.advanced.settings.sectionRules,
                child: _RulesBody(
                  controller: _rulesController,
                  templates: _systemPromptTemplates,
                  onSave: () => _saveRules(controller),
                  onPickTemplate: () => _showTemplatePicker(controller),
                ),
              ),

              // ── 模型与生成（默认展开）─────────────────────────────
              _section(
                id: 'modelGeneration',
                title: t.advanced.settings.sectionModelGeneration,
                child: _ModelGenerationBody(
                  state: state,
                  advanced: advanced,
                  level: level,
                  enabled: !isBusy,
                  onModelPick: () => _showModelPicker(controller, advanced),
                  onGenerationChanged: (session) =>
                      _saveSession(controller, session),
                  maxTokensController: _maxTokensController,
                  maxTokensFocusNode: _maxTokensFocusNode,
                  onCommitMaxTokens: _commitMaxTokens,
                  onResetMaxTokens: _resetMaxTokensToGlobal,
                ),
              ),

              // ── 剧情节奏（默认折叠）────────────────────────
              _section(
                id: 'pacing',
                title: t.advanced.settings.sectionPacing,
                child: _PacingBody(
                  session: state.session,
                  globalPacing: NarrativePacing.tryFromConfigValue(
                        advanced?.narrativePacing,
                      ) ??
                      NarrativePacing.balanced,
                  enabled: !isBusy,
                  onChanged: (v) => _saveSession(
                    controller,
                    _state.session.copyWith(narrativePacing: v?.configValue),
                  ),
                ),
              ),

              // ── 监督与工具（默认折叠）──────────────────────
              _section(
                id: 'supervision',
                title: t.advanced.settings.sectionSupervision,
                child: _SupervisionBody(
                  state: state,
                  globalPermissions: advanced?.tools ?? const {},
                  enabled: !isBusy,
                  sessionAllowCount: controller.sessionApprovalAllowCount,
                  onToggle: (v) => _saveWithFeedback(
                    controller,
                    watchMode: v,
                    globalTools: advanced?.tools ?? const {},
                  ),
                  onPermissionsChanged: (map) => _saveSession(
                    controller,
                    _state.session.copyWith(toolPermissions: map),
                  ),
                  onClearSessionAllows: () =>
                      _clearSessionApprovalAllows(controller),
                ),
              ),

              // ── 运行预算（默认折叠）───────────────────────────────
              _section(
                id: 'budget',
                title: t.advanced.settings.sectionBudget,
                child: _BudgetBody(
                  state: state,
                  globalMaxDurationMinutes:
                      advanced?.budget.maxDurationMinutes ?? 5,
                  //  三口径统一：回显走 effectiveMaxSteps（注入全局
                  // 当前值），不再「?? 8」
                  globalMaxSteps:
                      advanced?.defaults.maxSteps ?? _kDefaultMaxSteps,
                  enabled: !isBusy,
                  draggingMaxSteps: _draggingMaxSteps,
                  onDrag: (v) => setState(() => _draggingMaxSteps = v),
                  onDragEnd: (v) {
                    setState(() => _draggingMaxSteps = null);
                    _saveMaxSteps(controller, v);
                  },
                  // +：关「无上限」= 写全局当前快照（的
                  // 「写死 8」与「null 跟随」两路径一并收敛到快照语义）。
                  // 全局本身是 0（无上限）
                  // 时关 toggle 不能再写 0——写 0 后 unlimited 判据纹丝不动，
                  // 开关死锁；回退默认步数。
                  onUnlimitedToggle: (v) => _saveMaxSteps(
                    controller,
                    v
                        ? _kUnlimitedMaxSteps
                        : (advanced?.defaults.maxSteps ?? _kDefaultMaxSteps) <=
                                0
                            ? _kDefaultMaxSteps
                            : advanced!.defaults.maxSteps,
                  ),
                  draggingMaxDuration: _draggingMaxDuration,
                  onDurationDrag: (v) =>
                      setState(() => _draggingMaxDuration = v),
                  onDurationDragEnd: (v) {
                    setState(() => _draggingMaxDuration = null);
                    _saveSession(
                      controller,
                      _state.session.copyWith(maxDurationMinutes: v),
                    );
                  },
                  onMaxDurationChanged: (minutes) => _saveSession(
                    controller,
                    _state.session.copyWith(maxDurationMinutes: minutes),
                  ),
                ),
              ),

              // ── 上下文与压缩（默认折叠）───────────────────────────
              _section(
                id: 'context',
                title: t.advanced.settings.sectionContext,
                child: _ContextBody(
                  state: state,
                  advanced: advanced,
                  enabled: !isBusy,
                  onChanged: (session) => _saveSession(controller, session),
                ),
              ),

              // ── 角色卡/世界书（默认折叠）：应用只读种子（DOC-15 §0
              //    边界修订——导演已实现消费，入口对齐故事模式）──────
              _section(
                id: 'resource',
                title: t.advanced.settings.sectionResource,
                child: SeedResourceSection(
                  sessionId: state.session.sessionId,
                  enabled: !isBusy,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 构造一个可折叠分区（顶部间距 + 分区卡）。
  ///
  /// 区级按配置显示模式过滤：被隐藏区直接不出区壳（上层 build 已
  /// watch configLevelProvider，切换即时重建）。
  Widget _section({
    required String id,
    required String title,
    required Widget child,
  }) {
    if (!_isSectionRendered(id, ref.watch(configLevelProvider))) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: IntermediateSpacing.sMd),
      child: CollapsibleSettingsSection(
        title: title,
        isExpanded: _isSectionExpanded(id),
        onToggle: () => _toggleSection(id),
        child: Padding(
          padding:
              const EdgeInsets.symmetric(vertical: IntermediateSpacing.sXs),
          child: child,
        ),
      ),
    );
  }

  // ── 重建向量索引（对齐故事面板 memoryManagement 能力）────────────

  Future<void> _rebuildVectorIndex(AdvancedChatController controller) async {
    final t = Translations.of(context);
    //  残余：改用导演侧专用键
    final adv = t.advanced.settings.memory;
    final confirmed = await showLmDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(adv.rebuildVectorIndexConfirmTitle),
        content: Text(
          // 确认口径 = 未向量化 + 陈旧（重建实际处理的总条数）
          adv.rebuildVectorIndexConfirmContent(
            count: _pendingEmbeddingCount + _staleEmbeddingCount,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.common.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.common.confirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _isRebuilding = true);
    final progressNotifier = ValueNotifier<(int, int, int)>((0, 0, 0));
    // 照抄 factual_memory_tab 的  修复样板——
    // DialogRoute + PopScope 挡 Esc + removeRoute 精确移除。旧实现裸
    // showDialog 无 PopScope（桌面 Esc 会关掉遮罩），任务结束后无参
    // pop() 弹出栈顶（即承载本 sheet 的路由），用户被踢出设置面板。
    final overlayRoute = DialogRoute<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: ValueListenableBuilder<(int, int, int)>(
          valueListenable: progressNotifier,
          builder: (ctx, progress, _) {
            final (processed, total, failed) = progress;
            return AlertDialog(
              title: Text(adv.rebuildVectorIndexRunning),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(
                    value: total == 0 ? null : processed / total,
                  ),
                  const SizedBox(height: IntermediateSpacing.sSm),
                  // 进度文案入 slang（复用故事侧现成键，删硬编码中文）
                  Text(
                    adv.rebuildVectorIndexProgress(
                      processed: processed,
                      total: total,
                      failed: failed,
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
    unawaited(Navigator.of(context).push(overlayRoute));

    // 重建调用包 onError——查询抛
    // 异常时进度框（barrierDismissible=false+PopScope）与按钮禁用态
    // 此前永久滞留。异常转通用失败提示（与故事侧同款）。
    final result = await controller.rebuildEmbeddings(
      onProgress: (processed, total, failed) {
        progressNotifier.value = (processed, total, failed);
      },
    ).onError((e, _) {
      return (total: 0, succeeded: 0, failed: 0, failureReason: 'error');
    });
    progressNotifier.dispose();

    if (mounted) Navigator.of(context).removeRoute(overlayRoute);
    if (!mounted) return;
    setState(() => _isRebuilding = false);
    final pending = await controller.pendingEmbeddingCount();
    _pendingEmbeddingCount = pending.missing;
    _staleEmbeddingCount = pending.stale;
    if (!mounted) return;
    setState(() {});

    final message = switch (result.failureReason) {
      'busy' => adv.rebuildVectorIndexFailureBusy,
      'not_configured' => adv.rebuildVectorIndexFailureNotConfigured,
      'error' => t.common.error,
      _ => adv.rebuildVectorIndexResultSuccess(
          succeeded: result.succeeded,
          failed: result.failed,
        ),
    };
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(behavior: SnackBarBehavior.floating, content: Text(message)),
    );
  }

  /// 清除本会话审批放行；反馈清除数量（0 = 本就无放行）
  void _clearSessionApprovalAllows(AdvancedChatController controller) {
    final cleared = controller.clearSessionApprovalAllows();
    if (!mounted) return;
    final t = Translations.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            cleared > 0
                ? t.advanced.settings.sessionAllowCleared(count: cleared)
                : t.advanced.settings.sessionAllowNone,
          ),
          duration: const Duration(seconds: 1),
        ),
      );
    setState(() {}); // 放行数徽标随清除刷新
  }

  // ── 既有交互（迁入折叠容器，行为不变）──────────────────────────

  void _showModelPicker(
    AdvancedChatController controller,
    AdvancedConfig? advanced,
  ) {
    final t = Translations.of(context);
    final (presetId, modelId) =
        _state.session.phaseModels.forPhase('generating');
    showLmSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => IntermediateModelPickerSheet(
        selectedPresetId:
            (presetId == null || presetId.isEmpty) ? null : presetId,
        selectedModelId: (modelId == null || modelId.isEmpty) ? null : modelId,
        title: t.advanced.settings.sectionModel,
        // 清除=写全局当前 GM 快照（不再置回 null 跟随态）
        clearLabel: t.advanced.settings.resetToGlobalSnapshot,
        onModelSelected: (p, m) async {
          final SessionPhaseModels effective;
          if (p == null && m == null) {
            effective = SessionPhaseModels(
              generatingPresetId: (advanced?.generatingPresetId ?? '').isEmpty
                  ? null
                  : advanced?.generatingPresetId,
              generatingModelId: (advanced?.generatingModelId ?? '').isEmpty
                  ? null
                  : advanced?.generatingModelId,
            );
          } else {
            effective = _state.session.phaseModels.copyWithPhase(
              phase: 'generating',
              presetId: p,
              modelId: m,
            );
          }
          await _saveWithFeedback(
            controller,
            phaseModels: effective,
          );
        },
      ),
    );
  }

  /// 从模板库直选项目规则：填入输入框并立即保存（与故事模式选模板行为一致）。
  void _showTemplatePicker(AdvancedChatController controller) {
    showSystemPromptTemplatePicker(
      context,
      templates: _systemPromptTemplates,
      onTemplateSelected: (template) {
        _rulesController.text = template.content;
        _saveRules(controller);
      },
    );
  }

  Future<void> _saveRules(AdvancedChatController controller) async {
    final rules = _rulesController.text.trim();
    //  修复：检查 updateSession 返回值——生成中会被拒绝，
    // 此前无视失败无条件弹「已保存」是假反馈
    // （快照宪法）：清空=写空串（具体「无规则」内容），不再转 null
    //（null=跟随态已禁）。重置走物化：从模板库/全局快照重新写入。
    final saved = await controller.updateSession(
      _state.session.copyWith(
        systemPromptOverride: rules,
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          directorSaveResultText(
            Translations.of(context),
            saved: saved,
            phase: _state.phase,
          ),
        ),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  /// steps=null 表示清除会话覆盖（写回 NULL = 跟随全局）。
  void _saveMaxSteps(AdvancedChatController controller, int? steps) {
    unawaited(
      _saveWithFeedback(
        controller,
        maxSteps: steps,
        clearMaxSteps: steps == null,
      ),
    );
  }

  /// 生成参数/上下文覆盖写入（session-state 字段组）。
  Future<void> _saveSession(
    AdvancedChatController controller,
    ChatSession session,
  ) async {
    final saved = await controller.updateSession(session);
    if (!mounted) return;
    final t = Translations.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            directorSaveResultText(t, saved: saved, phase: _state.phase),
          ),
          duration: const Duration(seconds: 1),
        ),
      );
  }

  /// maxTokens 提交收口——
  /// 对照 chat 侧 「装载前 no-op」与故事侧「空输入走全局快照回退」，
  /// 此前导演侧两头都没有：空输入+回车直写显式 null（重建  已废除的
  /// 跟随态）；重置后回车把陈旧文本重新写库静默撤销重置。
  void _commitMaxTokens() {
    final generation = ref.read(advancedConfigProvider).valueOrNull?.generation;
    final parsed = int.tryParse(_maxTokensController.text.trim());
    final current = _state.session.maxTokens;
    if (parsed == current) return;
    if (parsed != null) {
      _saveSession(
        ref.read(advancedChatControllerProvider(widget.session).notifier),
        _state.session.copyWith(maxTokens: parsed),
      );
      return;
    }
    if (generation == null) {
      // 装载前窗口：no-op 并回显当前值，防「看似已清空实则未提交」
      _maxTokensController.text = current?.toString() ?? '';
      return;
    }
    _saveSession(
      ref.read(advancedChatControllerProvider(widget.session).notifier),
      _state.session.copyWith(maxTokens: generation.maxTokens),
    );
  }

  void _onMaxTokensFocusChanged() {
    if (!_maxTokensFocusNode.hasFocus) _commitMaxTokens();
  }

  /// ②：重置在未装载窗口 no-op（此前把硬编码值/显式 null 冒充
  /// 全局快照写入）；装载后写快照并回显输入框。
  Future<void> _resetMaxTokensToGlobal() async {
    final generation = ref.read(advancedConfigProvider).valueOrNull?.generation;
    if (generation == null) return;
    await _saveSession(
      ref.read(advancedChatControllerProvider(widget.session).notifier),
      _state.session.copyWith(maxTokens: generation.maxTokens),
    );
    if (mounted && !_maxTokensFocusNode.hasFocus) {
      _maxTokensController.text = generation.maxTokens.toString();
    }
  }

  /// 会话设置写路径统一收口
  ///
  /// 生成中被 updateSession 拒绝后 UI 不再静默回弹，统一反馈保存结果。
  Future<void> _saveWithFeedback(
    AdvancedChatController controller, {
    bool? watchMode,
    Map<String, String>? globalTools,
    SessionPhaseModels? phaseModels,
    int? maxSteps,
    bool clearMaxSteps = false,
  }) async {
    var session = _state.session;
    if (watchMode != null) {
      //  过渡写点（重写面板时收敛）：运行时已改读
      // tool_permissions（监督预设 map），watchMode 列仅保留展示/兼容。
      // （快照宪法）：开=写监督预设具体 map；关=写全局当前 12 工具
      // 完整快照（未配置键展开为内置默认 allow），不再置回 null 跟随态。
      final closedSnapshot = ToolPermissions.toJson({
        for (final tool in ToolPermissions.allTools)
          tool: (globalTools ?? const {})[tool] ?? 'allow',
      });
      session = session.copyWith(
        watchMode: watchMode,
        toolPermissions: watchMode
            ? ToolPermissions.toJson(ToolPermissions.supervised)
            : closedSnapshot,
      );
    }
    if (phaseModels != null) {
      session = session.copyWith(phaseModels: phaseModels);
    }
    // clearMaxSteps 时显式写回 null（跟全局），copyWith 哨兵语义
    // 区分「未传」与「清除」
    if (maxSteps != null || clearMaxSteps) {
      session = session.copyWith(maxSteps: maxSteps);
    }

    final saved = await controller.updateSession(session);
    if (!mounted) return;
    final t = Translations.of(context);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            directorSaveResultText(t, saved: saved, phase: _state.phase),
          ),
          duration: const Duration(seconds: 1),
        ),
      );
  }
}

// ==================== 分区体 ====================

/// 记忆管理分区体：重建向量索引。
class _MemoryManagementBody extends StatelessWidget {
  const _MemoryManagementBody({
    required this.pendingCount,
    required this.staleCount,
    required this.isRebuilding,
    required this.canRebuild,
    required this.onRebuild,
    required this.retrievalProfile,
    required this.enabled,
    required this.onRetrievalProfileChanged,
  });

  final int pendingCount;

  /// 与基准维度不一致的陈旧向量数
  final int staleCount;
  final bool isRebuilding;
  final bool canRebuild;
  final VoidCallback onRebuild;

  /// 当前会话「检索松紧度」快照（null = 存量会话未物化，无选中态）
  final RetrievalProfile? retrievalProfile;
  final bool enabled;

  /// 选中某档：上层把该档具体值快照写入会话列
  final ValueChanged<RetrievalProfile> onRetrievalProfileChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final adv = t.advanced.settings.memory;
    final settings = t.advanced.settings;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.advanced.settings.sectionMemoryDesc,
          style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
        ),
        const SizedBox(height: IntermediateSpacing.sSm),

        // ── 检索松紧度：三档单选，选中即快照具体值到会话列 ──
        // NULL 快照（存量会话/未选过）行为恰等于
        // 「平衡」档——「平衡」chip 以「默认」态高亮并回显说明，不再三档全空。
        // 物化后列恒有值（通常=平衡档快照），「默认」徽标改按值判定
        // （sameAs 平衡=默认行为的信息标注，与 null/物化无关）
        Text(
          settings.retrievalProfileTitle,
          style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
        ),
        const SizedBox(height: IntermediateSpacing.sXs),
        Row(
          children: [
            _RetrievalProfileChip(
              key: const ValueKey('retrieval-profile-conservative'),
              label: settings.retrievalProfileConservative,
              selected: retrievalProfile != null &&
                  retrievalProfile!.sameAs(RetrievalProfile.conservative),
              enabled: enabled,
              onTap: () =>
                  onRetrievalProfileChanged(RetrievalProfile.conservative),
            ),
            const SizedBox(width: IntermediateSpacing.sSm),
            _RetrievalProfileChip(
              key: const ValueKey('retrieval-profile-balanced'),
              label: settings.retrievalProfileBalanced,
              badge: retrievalProfile == null ||
                      retrievalProfile!.sameAs(RetrievalProfile.balanced)
                  ? settings.retrievalProfileDefaultBadge
                  : null,
              selected: retrievalProfile != null &&
                  retrievalProfile!.sameAs(RetrievalProfile.balanced),
              enabled: enabled,
              onTap: () => onRetrievalProfileChanged(RetrievalProfile.balanced),
            ),
            const SizedBox(width: IntermediateSpacing.sSm),
            _RetrievalProfileChip(
              key: const ValueKey('retrieval-profile-loose'),
              label: settings.retrievalProfileLoose,
              selected: retrievalProfile != null &&
                  retrievalProfile!.sameAs(RetrievalProfile.loose),
              enabled: enabled,
              onTap: () => onRetrievalProfileChanged(RetrievalProfile.loose),
            ),
          ],
        ),
        const SizedBox(height: IntermediateSpacing.sXs),
        Text(
          retrievalProfile == null
              ? settings.retrievalProfileDefaultDesc
              : retrievalProfile!.sameAs(RetrievalProfile.conservative)
                  ? settings.retrievalProfileConservativeDesc
                  : retrievalProfile!.sameAs(RetrievalProfile.loose)
                      ? settings.retrievalProfileLooseDesc
                      : settings.retrievalProfileBalancedDesc,
          style: IntermediateTextStyles.captionSm.copyWith(color: colors.faint),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: IntermediateSpacing.sSm),

        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: canRebuild ? onRebuild : null,
                child: Text(
                  isRebuilding
                      ? adv.rebuildVectorIndexRunning
                      : adv.rebuildVectorIndexButton,
                  style: IntermediateTextStyles.label.copyWith(
                    color: canRebuild ? colors.primary : colors.faint,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            if (pendingCount > 0 || staleCount > 0) ...[
              const SizedBox(width: IntermediateSpacing.sSm),
              Expanded(
                child: Text(
                  [
                    if (pendingCount > 0)
                      t.advanced.settings
                          .rebuildPendingCount(count: pendingCount),
                    if (staleCount > 0)
                      t.advanced.settings.rebuildStaleCount(count: staleCount),
                  ].join(' · '),
                  style: IntermediateTextStyles.caption
                      .copyWith(color: colors.faint),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}

/// 检索松紧度档位 chip（对齐预算区 FilterChip 词汇）。
class _RetrievalProfileChip extends StatelessWidget {
  const _RetrievalProfileChip({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
    this.badge,
    super.key,
  });

  final String label;

  /// NULL 快照时的「默认」徽标（如「平衡 · 默认」）——非选中态，
  /// 仅标识当前生效档；选中态照常按快照回显
  final String? badge;

  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final isDefaultBadge = badge != null;
    return FilterChip(
      label: Text(isDefaultBadge ? '$label · $badge' : label),
      selected: selected,
      showCheckmark: false,
      onSelected: enabled ? (_) => onTap() : null,
      selectedColor: colors.primary,
      backgroundColor: colors.surfaceVariant,
      side: isDefaultBadge ? BorderSide(color: colors.primary) : null,
      labelStyle: IntermediateTextStyles.caption.copyWith(
        color: selected
            ? colors.bg
            : isDefaultBadge
                ? colors.primary
                : colors.muted,
      ),
    );
  }
}

/// 模型与生成分区体：GM 主模型 + 生成参数组（会话覆盖，「重置为全局」置 null）。
class _ModelGenerationBody extends StatelessWidget {
  const _ModelGenerationBody({
    required this.state,
    required this.advanced,
    required this.level,
    required this.enabled,
    required this.onModelPick,
    required this.onGenerationChanged,
    required this.maxTokensController,
    required this.onCommitMaxTokens,
    required this.onResetMaxTokens,
    this.maxTokensFocusNode,
  });

  final AdvancedChatState state;
  final AdvancedConfig? advanced;
  final ConfigLevel level;
  final bool enabled;
  final VoidCallback onModelPick;
  final ValueChanged<ChatSession> onGenerationChanged;
  final TextEditingController maxTokensController;

  /// 失焦提交/重置收口（见 sheet State 同名注释）
  final FocusNode? maxTokensFocusNode;
  final VoidCallback onCommitMaxTokens;
  final VoidCallback onResetMaxTokens;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final gen = t.advanced.settings.generation;
    final session = state.session;

    // 会话列 NULL 时展示 advanced 全局值（快照语义：改动写会话列）
    final generation = advanced?.generation;
    final temperature = session.temperature ?? generation?.temperature ?? 0.8;
    final topP = session.topP ?? generation?.topP ?? 0.95;
    final presencePenalty =
        session.presencePenalty ?? generation?.presencePenalty ?? 0.6;
    final frequencyPenalty =
        session.frequencyPenalty ?? generation?.frequencyPenalty ?? 0.3;
    final sessionEffort = session.reasoningEffort;
    final globalEffortStr = generation?.reasoningEffort;
    final globalEffort = globalEffortStr == null
        ? null
        : ReasoningEffort.fromString(globalEffortStr);

    final modelId = session.phaseModels.forPhase('generating').$2;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 主模型（GM）
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.advanced.settings.sectionModel,
                    style: IntermediateTextStyles.caption
                        .copyWith(color: colors.muted),
                  ),
                  Text(
                    (modelId == null || modelId.isEmpty)
                        ? t.settings.intermediate.phaseModels.notConfigured
                        : modelId,
                    style: IntermediateTextStyles.bodyUi
                        .copyWith(color: colors.ink),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: onModelPick,
              child: Text(t.advanced.settings.selectModel),
            ),
          ],
        ),
        const SizedBox(height: IntermediateSpacing.sSm),

        // 生成参数组（session_settings_fields 零改动复用）。
        // 区标题恒显（思考档属生成参数族）；行级按配置显示模式过滤：
        // 简单模式仅保留思考档行（D-C12），采样参数行进阶渲染。
        Text(
          t.advanced.settings.generationGroup,
          style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
        ),
        const SizedBox(height: IntermediateSpacing.sXs),
        if (ConfigVisibility.of(
          ConfigVisibilityKeys.directorPanelGenerationTemperature,
          level,
        ))
          IntermediateSliderField(
            label: gen.temperature,
            value: temperature.clamp(0, 2),
            min: 0,
            max: 2,
            divisions: 200,
            enabled: enabled,
            // +：徽标=信息标注（「此值恰等于全局快照」）——快照化后
            // 列恒有值，改按值比较；advanced 未装载时视为自定义（不显示
            // 徽标，不拿硬编码默认值冒充全局）
            isCustomized: generation == null ||
                !_nearlyEqual(session.temperature, generation.temperature),
            globalValueText: generation?.temperature.toStringAsFixed(2),
            onChanged: (v) => onGenerationChanged(
              session.copyWith(temperature: v),
            ),
            // 重置=写按下时全局快照（不再置回 null）
            onReset: () => onGenerationChanged(
              session.copyWith(
                temperature: generation?.temperature ?? session.temperature,
              ),
            ),
          ),
        if (ConfigVisibility.of(
          ConfigVisibilityKeys.directorPanelGenerationTopP,
          level,
        )) ...[
          const SizedBox(height: IntermediateSpacing.sSm),
          IntermediateSliderField(
            label: gen.topP,
            value: topP.clamp(0, 1),
            min: 0,
            max: 1,
            divisions: 100,
            enabled: enabled,
            isCustomized: generation == null ||
                !_nearlyEqual(session.topP, generation.topP),
            globalValueText: generation?.topP.toStringAsFixed(2),
            onChanged: (v) => onGenerationChanged(session.copyWith(topP: v)),
            onReset: () => onGenerationChanged(
              session.copyWith(topP: generation?.topP ?? session.topP),
            ),
          ),
        ],
        if (ConfigVisibility.of(
          ConfigVisibilityKeys.directorPanelGenerationPresencePenalty,
          level,
        )) ...[
          const SizedBox(height: IntermediateSpacing.sSm),
          IntermediateSliderField(
            label: gen.presencePenalty,
            value: presencePenalty.clamp(-2, 2),
            min: -2,
            max: 2,
            divisions: 200,
            enabled: enabled,
            isCustomized: generation == null ||
                !_nearlyEqual(
                  session.presencePenalty,
                  generation.presencePenalty,
                ),
            globalValueText: generation?.presencePenalty.toStringAsFixed(2),
            onChanged: (v) =>
                onGenerationChanged(session.copyWith(presencePenalty: v)),
            onReset: () => onGenerationChanged(
              session.copyWith(
                presencePenalty:
                    generation?.presencePenalty ?? session.presencePenalty,
              ),
            ),
          ),
        ],
        if (ConfigVisibility.of(
          ConfigVisibilityKeys.directorPanelGenerationFrequencyPenalty,
          level,
        )) ...[
          const SizedBox(height: IntermediateSpacing.sSm),
          IntermediateSliderField(
            label: gen.frequencyPenalty,
            value: frequencyPenalty.clamp(-2, 2),
            min: -2,
            max: 2,
            divisions: 200,
            enabled: enabled,
            isCustomized: generation == null ||
                !_nearlyEqual(
                  session.frequencyPenalty,
                  generation.frequencyPenalty,
                ),
            globalValueText: generation?.frequencyPenalty.toStringAsFixed(2),
            onChanged: (v) =>
                onGenerationChanged(session.copyWith(frequencyPenalty: v)),
            onReset: () => onGenerationChanged(
              session.copyWith(
                frequencyPenalty:
                    generation?.frequencyPenalty ?? session.frequencyPenalty,
              ),
            ),
          ),
        ],
        if (ConfigVisibility.of(
          ConfigVisibilityKeys.directorPanelGenerationMaxTokens,
          level,
        )) ...[
          const SizedBox(height: IntermediateSpacing.sSm),
          IntermediateMaxTokensField(
            controller: maxTokensController,
            focusNode: maxTokensFocusNode,
            enabled: enabled,
            isCustomized:
                generation == null || session.maxTokens != generation.maxTokens,
            globalValueText: generation?.maxTokens.toString(),
            // 提交走收口（空输入=快照回退/装载前 no-op，
            // 不再直写 null）；重置走收口（未装载 no-op+保存后回显）
            onSubmitted: (_) => onCommitMaxTokens(),
            onReset: onResetMaxTokens,
          ),
        ],
        const SizedBox(height: IntermediateSpacing.sSm),
        IntermediateReasoningEffortSelector(
          value: sessionEffort,
          effectiveValue: sessionEffort ?? globalEffort,
          onChanged: (v) =>
              onGenerationChanged(session.copyWith(reasoningEffort: v)),
          //  carve-out：重置=物化全局当前值；全局未配置（null）时写
          // null——那是「模型自行决定」这一具体状态（模型语义非跟随）
          onReset: () => onGenerationChanged(
            session.copyWith(reasoningEffort: globalEffort),
          ),
          enabled: enabled,
        ),
      ],
    );
  }
}

/// 项目规则分区体：TextField + 模板库（现有交互原样迁入）。
class _RulesBody extends StatelessWidget {
  const _RulesBody({
    required this.controller,
    required this.templates,
    required this.onSave,
    required this.onPickTemplate,
  });

  final TextEditingController controller;
  final List<Template> templates;
  final VoidCallback onSave;
  final VoidCallback onPickTemplate;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.advanced.settings.sectionRulesDesc,
          style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
        ),
        const SizedBox(height: IntermediateSpacing.sSm),
        TextField(
          controller: controller,
          maxLines: 6,
          minLines: 3,
          style: IntermediateTextStyles.input.copyWith(color: colors.ink),
          decoration: InputDecoration(
            hintText: t.advanced.settings.rulesHint,
            hintStyle:
                IntermediateTextStyles.input.copyWith(color: colors.muted),
            filled: true,
            fillColor: colors.surfaceVariant,
            border: OutlineInputBorder(
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
              borderSide: BorderSide(color: colors.divider),
            ),
          ),
          onSubmitted: (_) => onSave(),
        ),
        const SizedBox(height: IntermediateSpacing.sSm),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (templates.isNotEmpty)
              TextButton.icon(
                onPressed: onPickTemplate,
                icon: Icon(
                  Icons.bookmark_outline,
                  size: 16,
                  color: colors.primary,
                ),
                label: Text(
                  t.advanced.settings.rulesSelectTemplate,
                ),
              ),
            FilledButton(
              onPressed: onSave,
              child: Text(t.common.save),
            ),
          ],
        ),
      ],
    );
  }
}

/// 监督与工具分区体：监督预设开关 + 12 工具三态表（导演设置）。
///
/// 开关保留原位原交互（= 套用/清除「监督模式」预设）；其下三态表逐工具
/// 细调。开关态三值：关（map=null）/ 开（=监督预设）/ 自定义（有值且
/// ≠ 预设）——自定义时开关保持开启并显示「自定义」徽标。
class _SupervisionBody extends StatelessWidget {
  const _SupervisionBody({
    required this.state,
    required this.globalPermissions,
    required this.enabled,
    required this.sessionAllowCount,
    required this.onToggle,
    required this.onPermissionsChanged,
    required this.onClearSessionAllows,
  });

  final AdvancedChatState state;
  final Map<String, String> globalPermissions;
  final bool enabled;

  /// 本会话审批「总是允许」的生效工具数（徽标）
  final int sessionAllowCount;
  final ValueChanged<bool> onToggle;
  final ValueChanged<Map<String, String>?> onPermissionsChanged;
  final VoidCallback onClearSessionAllows;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final sessionMap = state.session.sessionToolPermissions;
    // 读侧判据=「map 含 ask/deny 约束」。批四快照宪法
    // 下拨「关」会写全 allow 快照（写侧不动），「关」在读侧只能靠「无任何
    // 约束」表达；全 allow 与 NULL 同为关。全局带入约束时拨关快照显示
    // 「开」是真实生效状态（真机验收项）。
    final hasConstraints = ToolPermissions.hasActiveConstraints(sessionMap);
    final isSupervised = sessionMap != null &&
        _mapEquals(sessionMap, ToolPermissions.supervised);
    final isCustom = hasConstraints && !isSupervised;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.advanced.settings.watchModeDesc,
          style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
        ),
        const SizedBox(height: IntermediateSpacing.sXs),
        SwitchListTile(
          // 开关值走 hasConstraints（全 allow 快照=关）
          value: hasConstraints,
          onChanged: enabled ? onToggle : null,
          activeThumbColor: colors.primary,
          contentPadding: EdgeInsets.zero,
          title: Row(
            children: [
              Text(
                t.advanced.settings.sectionWatchMode,
                style:
                    IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
              ),
              if (isCustom) ...[
                const SizedBox(width: IntermediateSpacing.sSm),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: colors.primaryDim,
                    borderRadius:
                        BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
                  ),
                  child: Text(
                    t.advanced.settings.customPreset,
                    style: IntermediateTextStyles.caption.copyWith(
                      color: colors.primary,
                      fontSize: 10,
                    ),
                  ),
                ),
              ],
            ],
          ),
          subtitle: Text(
            t.advanced.settings.watchModeHint,
            style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
          ),
        ),
        const SizedBox(height: IntermediateSpacing.sSm),
        // 生成中禁用改走组件 enabled 参数（视觉灰显
        /// + 不可点）——此前靠传空闭包吞点选，SegmentedButton 视觉可点、
        /// 点了无反馈
        DirectorToolPermissionsField(
          sessionPermissions: sessionMap,
          globalPermissions: globalPermissions,
          onChanged: onPermissionsChanged,
          enabled: enabled,
        ),
        // 会话级审批放行管理（「本会话总是允许」的记忆清除入口）
        const SizedBox(height: IntermediateSpacing.sSm),
        Row(
          children: [
            Expanded(
              child: Text(
                t.advanced.settings.sessionAllowDesc,
                style: IntermediateTextStyles.caption
                    .copyWith(color: colors.muted),
              ),
            ),
            if (sessionAllowCount > 0) ...[
              Text(
                t.advanced.settings.sessionAllowCount(n: sessionAllowCount),
                style: IntermediateTextStyles.caption
                    .copyWith(color: colors.primary),
              ),
              const SizedBox(width: IntermediateSpacing.sXs),
            ],
            TextButton(
              onPressed: sessionAllowCount > 0 ? onClearSessionAllows : null,
              child: Text(t.advanced.settings.clearSessionAllows),
            ),
          ],
        ),
      ],
    );
  }

  static bool _mapEquals(Map<String, String> a, Map<String, String> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}

/// 运行预算分区体：每轮最大步数 + 单轮时间预算（导演设置）。
class _BudgetBody extends StatelessWidget {
  const _BudgetBody({
    required this.state,
    required this.globalMaxDurationMinutes,
    required this.globalMaxSteps,
    required this.enabled,
    required this.draggingMaxSteps,
    required this.onDrag,
    required this.onDragEnd,
    required this.onUnlimitedToggle,
    required this.draggingMaxDuration,
    required this.onDurationDrag,
    required this.onDurationDragEnd,
    required this.onMaxDurationChanged,
  });

  final AdvancedChatState state;
  final int globalMaxDurationMinutes;

  /// 全局当前 maxSteps（advanced.defaults.max_steps），会话列 NULL
  /// 时的回显回退值——与 runner 预算读数同源。
  final int globalMaxSteps;
  final bool enabled;
  final int? draggingMaxSteps;
  final ValueChanged<int> onDrag;
  final ValueChanged<int> onDragEnd;
  final ValueChanged<bool> onUnlimitedToggle;

  /// 拖拽中的时间预算显示值（DP-3：null = 非拖拽，显示会话/全局生效值）。
  final int? draggingMaxDuration;
  final ValueChanged<int> onDurationDrag;
  final ValueChanged<int> onDurationDragEnd;

  /// 单轮时间预算（分钟）：null = 跟随全局。
  final ValueChanged<int?> onMaxDurationChanged;

  static const int _kUnlimitedMaxSteps = 0;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final session = state.session;

    final maxSteps =
        draggingMaxSteps ?? session.effectiveMaxSteps(globalMaxSteps);
    final unlimited = maxSteps == _kUnlimitedMaxSteps;
    final sessionDuration = session.maxDurationMinutes;
    // 会话列 NULL 时显示将生效的全局值（跟随全局语义）；
    // 拖拽中优先显示拖拽值（DP-3：拖拽不写库，显示与提交分离）
    final displayDuration =
        draggingMaxDuration ?? sessionDuration ?? globalMaxDurationMinutes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.advanced.settings.sectionBudgetDesc,
          style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
        ),
        const SizedBox(height: IntermediateSpacing.sSm),
        if (unlimited)
          Text(
            t.advanced.settings.maxStepsUnlimitedHint,
            style: IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
          )
        else
          Row(
            children: [
              Expanded(
                child: Slider(
                  value: maxSteps.toDouble(),
                  min: 1,
                  max: 32,
                  divisions: 31,
                  label: '$maxSteps',
                  onChanged: enabled ? (v) => onDrag(v.round()) : null,
                  onChangeEnd: (v) => onDragEnd(v.round()),
                ),
              ),
              SizedBox(
                width: 72,
                child: Text(
                  t.advanced.settings.maxSteps(n: maxSteps),
                  style:
                      IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
                ),
              ),
            ],
          ),
        Align(
          alignment: Alignment.centerRight,
          child: FilterChip(
            label: Text(t.advanced.settings.maxStepsUnlimited),
            selected: unlimited,
            showCheckmark: false,
            onSelected: enabled ? onUnlimitedToggle : null,
            selectedColor: colors.primary,
            backgroundColor: colors.surfaceVariant,
            labelStyle: IntermediateTextStyles.caption.copyWith(
              color: unlimited ? colors.bg : colors.muted,
            ),
          ),
        ),
        const SizedBox(height: IntermediateSpacing.sSm),

        // ── 单轮时间预算（会话覆盖， 新列）──────────────────
        Row(
          children: [
            Expanded(
              child: Text(
                t.settings.director.budget.maxDuration,
                style: IntermediateTextStyles.caption
                    .copyWith(color: colors.muted),
              ),
            ),
            GestureDetector(
              onTap: enabled
                  ? () => showNumericInputDialog(
                        context: context,
                        title: t.settings.director.budget.maxDuration,
                        currentValue: displayDuration.toDouble(),
                        min: 1,
                        max: 30,
                        decimals: 0,
                        onConfirmed: (v) => onMaxDurationChanged(v.round()),
                      )
                  : null,
              child: Text(
                //  白名单搭车归零：原硬编码 '$displayDuration 分钟'
                t.advanced.settings.maxDurationMinutes(n: displayDuration),
                style: IntermediateTextStyles.bodyUi.copyWith(
                  color: colors.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        Slider(
          value: displayDuration.toDouble().clamp(1, 30),
          min: 1,
          max: 30,
          divisions: 29,
          label: '$displayDuration',
          // DP-3：拖拽只更新本地显示值，松手（onChangeEnd）才提交一次
          onChanged: enabled ? (v) => onDurationDrag(v.round()) : null,
          onChangeEnd: (v) => onDurationDragEnd(v.round()),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: FilterChip(
            // 批 L：不再是「跟随全局」
            // 继承态开关——点击即把当前全局值快照写入会话列，此后互不影响
            label: Text(t.advanced.settings.resetToGlobalSnapshot),
            showCheckmark: false,
            onSelected: enabled
                ? (v) => onMaxDurationChanged(globalMaxDurationMinutes)
                : null,
            backgroundColor: colors.surfaceVariant,
            labelStyle: IntermediateTextStyles.caption.copyWith(
              color: colors.muted,
            ),
          ),
        ),
      ],
    );
  }
}

/// 会话作用域生效上下文窗口（_ContextBody 双显示分母）
///
/// 会话级 GM phaseModels / 窗口上限 override 优先，缺省回落全局 advanced
/// 值——与 resolveAdvancedSettings + _resolveContextWindow 的运行时口径
/// 一致；会话内改模型/上限即时重算（record family 参数变化即重新解析）。
final _sessionContextWindowProvider = FutureProvider.autoDispose
    .family<int, ({String? presetId, String? modelId, int? cap})>(
  (ref, args) =>
      ref.read(configurationResolverProvider).resolveContextWindowForPhase(
            presetId: args.presetId,
            modelId: args.modelId,
            effectiveContextLimit: args.cap,
          ),
);

/// 上下文与压缩分区体（上下文配置收敛 §2.1-7 +  快照化）：阈值双显示
/// + 窗口上限折叠。
///
/// 删除「跟随/自定义/全局」三态——会话
/// 阈值列恒具体值（新建/存量物化保底），面板恒显滑杆；重置 chip 写按下
/// 时的全局快照（不再置回 null）。故事三段式遗产两行已移除；窗口上限
/// （0=自动哨兵）在高级子折叠，重置同样写全局快照。
class _ContextBody extends ConsumerWidget {
  const _ContextBody({
    required this.state,
    required this.advanced,
    required this.enabled,
    required this.onChanged,
  });

  final AdvancedChatState state;
  final AdvancedConfig? advanced;
  final bool enabled;
  final ValueChanged<ChatSession> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final session = state.session;
    final globalTrigger = advanced?.contextBudget.compactionTriggerRatio ?? 0.5;
    // 物化后列恒有值；null 仅在物化失败的容错窗口出现，回退全局生效值
    final override = session.compactionTriggerRatioOverride ?? globalTrigger;

    final sessionGm = session.phaseModels;
    final gmPreset =
        sessionGm.generatingPresetId ?? _fallbackGmPreset(advanced);
    final gmModel = sessionGm.generatingModelId ?? _fallbackGmModel(advanced);
    final windowArgs = (
      presetId: gmPreset,
      modelId: gmModel,
      cap: session.effectiveContextLimit ??
          advanced?.context.effectiveContextLimit,
    );
    final effectiveWindow =
        ref.watch(_sessionContextWindowProvider(windowArgs)).valueOrNull ??
            ConfigurationResolver.defaultContextWindow;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DirectorCompactionThresholdField(
          ratio: override,
          effectiveWindow: effectiveWindow,
          enabled: enabled,
          onChanged: (v) => onChanged(
            session.copyWith(compactionTriggerRatioOverride: v),
          ),
          trailing: _ModeChip(
            label: t.advanced.settings.resetToGlobalSnapshot,
            selected: _nearlyEqual(override, globalTrigger),
            // 未装载窗口禁用重置——
            // 此前把硬编码 0.5 冒充全局快照写入
            enabled: enabled && advanced != null,
            onTap: () => onChanged(
              session.copyWith(compactionTriggerRatioOverride: globalTrigger),
            ),
          ),
        ),
        const SizedBox(height: IntermediateSpacing.sSm),

        // ── 高级子折叠：窗口上限（会话覆盖，0=自动哨兵）──────────
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: Text(
              t.settings.director.context.windowAdvanced,
              style:
                  IntermediateTextStyles.label.copyWith(color: colors.primary),
            ),
            children: [
              IntermediateEffectiveContextLimitSlider(
                value: session.effectiveContextLimit,
                onChanged: (v) => onChanged(
                  session.copyWith(effectiveContextLimit: v == 0 ? null : v),
                ),
                // 重置=写全局当前快照（全局 null=无限制→写 null，
                // 即「无限制」这一具体状态）。
                // 未装载窗口禁用重置——此前写显式 null，与「全局
                // 无限制」在该窗口不可区分（重建  已废除的跟随态）
                onReset: () => onChanged(
                  session.copyWith(
                    effectiveContextLimit:
                        advanced?.context.effectiveContextLimit,
                  ),
                ),
                enabled: enabled && advanced != null,
              ),
            ],
          ),
        ),
        //  审查移除：原此处的 IntermediateJsonModeSelector（会话级
        // json_mode_override）是故事结构化输出开关的照搬——导演 agent
        // 循环不消费该列，改了没反应
        const SizedBox(height: IntermediateSpacing.sXs),
        Text(
          t.advanced.settings.sectionContextDesc,
          style: IntermediateTextStyles.caption.copyWith(color: colors.faint),
        ),
      ],
    );
  }

  static String? _fallbackGmPreset(AdvancedConfig? advanced) =>
      advanced != null && advanced.generatingPresetId.isNotEmpty
          ? advanced.generatingPresetId
          : null;

  static String? _fallbackGmModel(AdvancedConfig? advanced) =>
      advanced != null && advanced.generatingModelId.isNotEmpty
          ? advanced.generatingModelId
          : null;
}

/// 紧凑模式 chip（选中态 primary，未选中 surfaceVariant；对齐故事侧
/// _OverrideModeToggle 视觉约定）。
class _ModeChip extends StatelessWidget {
  const _ModeChip({
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return Material(
      color: selected ? colors.primary : colors.surfaceVariant,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled && !selected ? onTap : null,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: IntermediateSpacing.sSm,
            vertical: 4,
          ),
          child: Text(
            label,
            style: IntermediateTextStyles.caption.copyWith(
              color: selected ? colors.bg : colors.muted,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

/// 剧情节奏三档（会话覆盖，剧情节奏档位设计 §5.7）：
/// NULL = 跟随全局（chip），点档位写入显式覆盖；下一轮生效。
class _PacingBody extends StatelessWidget {
  const _PacingBody({
    required this.session,
    required this.globalPacing,
    required this.enabled,
    required this.onChanged,
  });

  final ChatSession session;
  final NarrativePacing globalPacing;
  final bool enabled;
  final ValueChanged<NarrativePacing?> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final p = t.settings.director.pacing;
    final sessionRaw = session.narrativePacing;
    final effective =
        NarrativePacing.tryFromConfigValue(sessionRaw) ?? globalPacing;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.advanced.settings.sectionPacingDesc,
          style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
        ),
        const SizedBox(height: IntermediateSpacing.sSm),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<String>(
            segments: [
              for (final tier in NarrativePacing.values)
                ButtonSegment(
                  value: tier.configValue,
                  label: Text(
                    switch (tier) {
                      NarrativePacing.conservative => p.conservative,
                      NarrativePacing.balanced => p.balanced,
                      NarrativePacing.aggressive => p.aggressive,
                    },
                    style: TextStyle(
                      fontSize: 12,
                      color: effective == tier ? colors.bg : colors.muted,
                    ),
                  ),
                ),
            ],
            selected: {effective.configValue},
            showSelectedIcon: false,
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              side: WidgetStatePropertyAll(
                BorderSide(color: colors.divider),
              ),
              backgroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? colors.primary
                    : null,
              ),
              foregroundColor: WidgetStateProperty.resolveWith(
                (states) => states.contains(WidgetState.selected)
                    ? colors.bg
                    : colors.ink,
              ),
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
                ),
              ),
            ),
            onSelectionChanged: enabled
                ? (selection) =>
                    onChanged(NarrativePacing.fromConfigValue(selection.first))
                : null,
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: FilterChip(
            // 批 L：点击即把当前全局档位快照写入会话列（不再产生继承态）
            label: Text(t.advanced.settings.resetToGlobalSnapshot),
            showCheckmark: false,
            onSelected: enabled ? (v) => onChanged(globalPacing) : null,
            backgroundColor: colors.surfaceVariant,
            labelStyle: IntermediateTextStyles.caption.copyWith(
              color: colors.muted,
            ),
          ),
        ),
      ],
    );
  }
}
