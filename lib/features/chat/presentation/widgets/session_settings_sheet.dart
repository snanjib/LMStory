import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/config_visibility.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/components/simple_setting_card.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/widgets/editable_value_text.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/presentation/pages/chat/chat_mode_page.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/pages/chat_settings_page.dart';
import 'package:lmstory/features/settings/presentation/widgets/default_model_picker_sheet.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 温度/TopP 的「值恰等于全局」判定用
/// 容差——滑杆量化存在 double 累积误差（同款），精确比较多数档位
/// 不等；null 视为未设置（不自定义）。
bool _nearlyEqualDoubles(double? a, double? b) {
  if (a == null || b == null) return a == b;
  return (a - b).abs() < 1e-9;
}

/// Bottom sheet for configuring per-session settings in Simple mode.
class SessionSettingsSheet extends ConsumerStatefulWidget {
  const SessionSettingsSheet({
    required this.session,
    required this.onSessionUpdated,
    required this.onSessionDeleted,
    super.key,
  });

  final ChatSession session;
  final ValueChanged<ChatSession> onSessionUpdated;
  final VoidCallback onSessionDeleted;

  @override
  ConsumerState<SessionSettingsSheet> createState() =>
      _SessionSettingsSheetState();
}

class _SessionSettingsSheetState extends ConsumerState<SessionSettingsSheet> {
  late ChatSession _session;
  late TextEditingController _systemPromptController;
  late TextEditingController _maxTokensController;
  late final FocusNode _maxTokensFocusNode;
  Timer? _systemPromptDebounce;
  List<ApiPreset> _presets = [];
  List<Template> _systemPromptTemplates = [];
  bool _isLoading = true;
  bool _titleUpdating = false; // 「更新标题」按钮在途

  /// 配置解析器（用于"重置为全局当前值"按钮重新快照全局默认）
  late final ConfigurationResolver _resolver;

  /// 全局默认快照（用于会话级字段为 null 时显示真实全局值，而非硬编码默认）
  ///
  /// 2026-07-22 新增：第一次打开 sheet 时加载一次，让用户看到当前生效的
  /// 全局配置（如温度 1.2），而不是硬编码的 0.8。会话字段仍保持 null 语义
  ///（表示"跟随全局"），只是 UI 显示用快照值兜底。
  GlobalDefaultsSnapshot _globalSnapshot = const GlobalDefaultsSnapshot();

  @override
  void initState() {
    super.initState();
    // 2026-07-22 修复：从 controller.state.session 读取最新 session，
    // 而非 widget.session（可能过时）。物化后 widget.session 仍是草稿，
    // 但 controller.state.session 已是真实 session（含保存的配置）。
    // 修复"关闭设置再打开，配置变回默认"的 bug。
    _session = ref.read(chatModeControllerProvider(widget.session)).session;
    _systemPromptController = TextEditingController(
      text: _session.systemPromptOverride ?? '',
    );
    _maxTokensController = TextEditingController(
      text: _session.maxTokens?.toString() ?? '',
    );
    _maxTokensFocusNode = FocusNode();
    // 失焦即提交（与回车同语义），此前仅回车提交——
    // 点别处失焦时输入静默丢失且界面仍显示未生效值。
    _maxTokensFocusNode.addListener(_onMaxTokensFocusChanged);
    _loadPresets();
  }

  @override
  void dispose() {
    _systemPromptDebounce?.cancel();
    _maxTokensFocusNode
      ..removeListener(_onMaxTokensFocusChanged)
      ..dispose();
    _systemPromptController.dispose();
    _maxTokensController.dispose();
    super.dispose();
  }

  void _onMaxTokensFocusChanged() {
    if (_maxTokensFocusNode.hasFocus) return;
    _commitMaxTokens(_maxTokensController.text);
  }

  /// 提交 maxTokens 输入（回车与失焦共用）：可解析则持久化；空=写全局
  /// 当前快照（不再置 null 跟随态；全局未配置写 0=
  /// 无上限哨兵），与当前会话值一致时 no-op。
  /// 快照尚未装载完成时，空输入
  /// no-op——此时拿不到真实全局值，写 0 会把「无上限」静默钉进会话；
  /// 待装载完成后再次提交即可。
  void _commitMaxTokens(String value) {
    final parsed = int.tryParse(value.trim());
    if (parsed == _session.maxTokens) return;
    if (parsed == null && !_isLoading) {
      _updateSession(
        _session.copyWith(maxTokens: _globalSnapshot.maxTokens ?? 0),
      );
    }
  }

  Future<void> _loadPresets() async {
    final presetRepo =
        ref.read<ApiPresetRepository>(apiPresetRepositoryProvider);
    final templateRepo =
        ref.read<TemplateRepository>(templateRepositoryProvider);
    final settingsRepo =
        ref.read<SettingsRepository>(settingsRepositoryProvider);

    _resolver = ConfigurationResolver(
      presetRepository: presetRepo,
      settingsRepository: settingsRepo,
      logger: const Logger('SessionSettingsSheet'),
    );

    final results = await Future.wait([
      presetRepo.getAllPresets(),
      templateRepo.getTemplatesByKind(TemplateKind.systemPrompt),
      _resolver.snapshotSimpleDefaults(),
    ]);
    final presets = results[0] as List<ApiPreset>;
    final templates = results[1] as List<Template>;
    final snapshot = results[2] as GlobalDefaultsSnapshot;

    if (!mounted) return;

    // 2026-07-24 双菜单→单菜单改造：移除 _selectedPresetId 跟踪逻辑。
    // 模型选择改为通过 DefaultModelPickerSheet 完成，本 sheet 仅负责
    // 显示当前选择（从 _session.presetId/modelId 读取，_presets 用于解析名称）。
    setState(() {
      _presets = presets;
      _systemPromptTemplates = templates;
      _globalSnapshot = snapshot;
      _isLoading = false;
    });
  }

  Future<void> _updateSession(ChatSession updated) async {
    // 2026-07-22 修复：通过 controller 持久化，确保草稿会话的物化逻辑被触发。
    // 之前直接调用 chatRepo.updateSession 会绕过 controller 的 _materializeDraftSessionWith，
    // 导致草稿期间修改配置不触发物化（需求 1 失效）。
    // 从 controller.state.session 同步本地副本，
    // 避免草稿物化后 sessionId 从 __draft_xxx 变成 real-xxx，
    // 但 sheet 仍持有旧草稿 sessionId 导致第二次修改失败。
    // 必须用 widget.session（原始草稿 key）查找 controller，
    // 不能用 _session（物化后会变化）。family provider 按 key 区分实例，
    // 若 key 变化会创建新 controller，导致第二次修改不反映到聊天页面监听的草稿 controller。
    final controller =
        ref.read(chatModeControllerProvider(widget.session).notifier);
    try {
      await controller.updateSession(updated);
      // controller.updateSession 内部已持久化并更新 state，
      // 物化后 sessionId 可能变化，必须从 provider 读取最新 session 同步。
      if (!mounted) return;
      final persisted =
          ref.read(chatModeControllerProvider(widget.session)).session;
      setState(() => _session = persisted);
      widget.onSessionUpdated(persisted);
    } catch (e) {
      const Logger('SessionSettingsSheet')
          .error('Failed to update session', detail: '$e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(Translations.of(context).error.generic),
        ),
      );
    }
  }

  /// 重置指定字段为当前全局默认值（快照语义：使用此刻的全局值）
  ///
  /// 用户需求："保留重置按钮"——重置时读取当前全局配置的具体值，
  /// 覆盖会话级字段。调用 [ConfigurationResolver.snapshotSimpleDefaults] 获取快照。
  Future<void> _resetFieldToGlobal(
    ChatSession Function(GlobalDefaultsSnapshot snapshot) updater,
  ) async {
    final snapshot = await _resolver.snapshotSimpleDefaults();
    await _updateSession(updater(snapshot));
  }

  /// 构建字段标题行（标题 + 重置按钮）
  ///
  /// 用户需求："保留重置按钮"——每个可重置字段标题右侧
  /// 显示一个重置图标按钮，点击后用当前全局默认值覆盖会话级字段。
  Widget _buildFieldLabel(
    Translations t,
    LmPalette colors,
    String label, {
    required VoidCallback onReset,
    bool isCustomized = true,
    String? globalValueText,
  }) {
    final showGlobalBadge =
        !isCustomized && globalValueText != null && globalValueText.isNotEmpty;
    return Row(
      children: [
        Flexible(
          child: Text(
            label,
            style: SimpleTextStyles.caption.copyWith(color: colors.muted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (showGlobalBadge) ...[
          const SizedBox(width: SimpleSpacing.s2xs),
          Text(
            t.common.followingGlobal(value: globalValueText),
            style: SimpleTextStyles.overline.copyWith(color: colors.faint),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        const Spacer(),
        IconButton(
          icon: Icon(Icons.refresh, size: 16, color: colors.faint),
          onPressed: isCustomized ? onReset : null,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          tooltip: t.chat.sessionSettings.resetToGlobal,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    // 2026-07-28 修复：监听 controller 状态变化，自动同步 _session。
    // 场景：sheet 打开期间，外部（如输入框下方的模型切换）修改了 session，
    // sheet 需要实时刷新显示。原代码只在 initState 和 _updateSession 中更新 _session，
    // 无法响应外部状态变化。
    // 注意：ref.listen 只能在 ConsumerWidget/ConsumerStatefulWidget 的 build 方法中
    // 使用，不能放在 initState 中。之前把 ref.listen 放 initState 里导致运行时断言失败。
    // 必须用 widget.session（原始草稿 key）查找 controller，否则会拿到新实例。
    ref.listen(
      chatModeControllerProvider(widget.session),
      (previous, next) {
        if (!mounted) return;
        if (previous?.session != next.session) {
          setState(() => _session = next.session);
        }
      },
    );

    // 根容器用 Material（而非 Container+BoxDecoration(color))：
    // showModalBottomSheet 已提供 Material 祖先，但 Container 的 color 会作为
    // ColoredBox 渲染在 Material 与 ListTile/SwitchListTile/InkWell 之间，遮蔽
    // ink splash 水波纹。改为 Material(color) 让色层本身成为 ink splash 的宿主，
    // clipBehavior: Clip.antiAlias 配合 borderRadius 处理圆角裁剪。
    //
    // 字段级按配置显示模式过滤：简单模式保留模型/系统提示词/思考预算
    // （与删除、全局设置链接两个非配置项）；采样参数/上下文/流式字段
    // 仅进阶模式渲染。过滤只动展示层，被隐藏字段已有用户值继续生效。
    final level = ref.watch(configLevelProvider);

    return Material(
      // 琉璃下面层让位 GlassBottomSheet 工厂；经典保持原槽位零变化。
      color: context.lmSheetFaceColor(colors.surface),
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle
            Padding(
              padding: const EdgeInsets.only(top: SimpleSpacing.sSm),
              child: Container(
                width: 32,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.faint.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // Title
            Padding(
              padding: const EdgeInsets.all(SimpleSpacing.sLg),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      t.chat.sessionSettings.title,
                      style: SimpleTextStyles.title2.copyWith(
                        color: colors.ink,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, color: colors.muted, size: 20),
                    tooltip: t.common.close,
                    onPressed: () => Navigator.of(context).pop(),
                    padding: EdgeInsets.zero,
                    // P0-E 修复：触控目标 ≥44x44（移动端可访问性规范）
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                  ),
                ],
              ),
            ),
            // Content
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.all(SimpleSpacing.s3xl),
                child: CircularProgressIndicator(),
              )
            else
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SimpleSpacing.sLg,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildModelCard(t, colors),
                      const SizedBox(height: SimpleSpacing.sLg),
                      _buildSystemPrompt(t, colors),
                      if (ConfigVisibility.of(
                        ConfigVisibilityKeys.chatPanelTemperature,
                        level,
                      )) ...[
                        const SizedBox(height: SimpleSpacing.sLg),
                        _buildTemperatureSlider(t, colors),
                      ],
                      if (ConfigVisibility.of(
                        ConfigVisibilityKeys.chatPanelTopP,
                        level,
                      )) ...[
                        const SizedBox(height: SimpleSpacing.sLg),
                        _buildTopPSlider(t, colors),
                      ],
                      if (ConfigVisibility.of(
                        ConfigVisibilityKeys.chatPanelMaxTokens,
                        level,
                      )) ...[
                        const SizedBox(height: SimpleSpacing.sLg),
                        _buildMaxTokens(t, colors),
                      ],
                      if (ConfigVisibility.of(
                        ConfigVisibilityKeys.chatPanelMaxContextMessages,
                        level,
                      )) ...[
                        const SizedBox(height: SimpleSpacing.sLg),
                        _buildMaxContextMessages(t, colors),
                      ],
                      if (ConfigVisibility.of(
                        ConfigVisibilityKeys.chatPanelStreamEnabled,
                        level,
                      )) ...[
                        const SizedBox(height: SimpleSpacing.sLg),
                        _buildStreamToggle(t, colors),
                      ],
                      // 2026-07-20：思考预算无条件显示（原条件 _currentModelSupportsReasoning
                      // 依赖模型在 cached_models 中声明 capabilities.reasoning，
                      // 但许多 API 供应商不返回 capabilities 字段导致开关隐藏，
                      // 用户体验差。改为无条件显示，模型不支持时选了不生效即可。）
                      const SizedBox(height: SimpleSpacing.sLg),
                      _buildReasoningEffort(t, colors),
                      const SizedBox(height: SimpleSpacing.sXl),
                      _buildDeleteButton(t, colors),
                      const SizedBox(height: SimpleSpacing.sLg),
                      _buildGlobalSettingsLink(t, colors),
                      SizedBox(
                        height: MediaQuery.of(context).viewInsets.bottom +
                            MediaQuery.of(context).padding.bottom +
                            SimpleSpacing.sLg,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Model card (单菜单模式：卡片入口 + DefaultModelPickerSheet)
  //
  // 2026-07-24 双菜单→单菜单改造：
  // 原 _buildProviderSelector + _buildModelSelector 两个 DropdownButtonFormField
  // 合并为一个 SimpleSettingCard。点击卡片打开 DefaultModelPickerSheet，
  // 在 sheet 内按供应商分组选择模型（支持折叠/展开）。
  //
  // 卡片副标题显示规则：
  // - 会话级已配 preset+model → "供应商名 · 模型名"
  // - 会话级为 null，全局已配 → "全局：供应商名 · 模型名"
  // - 都未配 → "未配置"
  // ---------------------------------------------------------------------------

  Widget _buildModelCard(Translations t, LmPalette colors) {
    // 解析当前会话级选择
    final sessionPreset = _session.presetId == null
        ? null
        : _presets.where((p) => p.presetId == _session.presetId).firstOrNull;
    final sessionModel = sessionPreset?.cachedModels
        .where((m) => m.modelId == _session.modelId)
        .firstOrNull;

    // 解析全局默认（用于会话级为 null 时显示当前生效值）
    final globalPreset = _globalSnapshot.presetId == null
        ? null
        : _presets
            .where((p) => p.presetId == _globalSnapshot.presetId)
            .firstOrNull;
    final globalModel = globalPreset?.cachedModels
        .where((m) => m.modelId == _globalSnapshot.modelId)
        .firstOrNull;

    final hasSessionSelection = sessionPreset != null && sessionModel != null;
    final hasGlobalSelection = globalPreset != null && globalModel != null;

    final String subtitle;
    if (hasSessionSelection) {
      subtitle =
          '${sessionPreset.name} · ${sessionModel.displayName ?? sessionModel.modelId}';
    } else if (hasGlobalSelection) {
      // 会话级未配置，但全局已配 → 显示"全局：xxx · yyy"
      final globalDesc =
          '${globalPreset.name} · ${globalModel.displayName ?? globalModel.modelId}';
      subtitle = t.chat.sessionSettings.usingGlobalPrefix(prefix: globalDesc);
    } else {
      subtitle = t.chat.sessionSettings.notConfigured;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildFieldLabel(
          t,
          colors,
          t.chat.sessionSettings.model,
          onReset: () => _resetFieldToGlobal(
            (s) => _session.copyWith(
              presetId: s.presetId,
              modelId: s.modelId,
            ),
          ),
        ),
        const SizedBox(height: SimpleSpacing.sXs),
        SimpleSettingCard(
          icon: Icons.smart_toy_outlined,
          title: t.chat.sessionSettings.model,
          subtitle: subtitle,
          onTap: () => _showModelPicker(t),
        ),
        const SizedBox(height: SimpleSpacing.sXs),
        // 手动「更新标题」——自动重试不做，用户随时
        // 触发强制命名（失败不落截断名，见 controller _autoNameSession）。
        SimpleSettingCard(
          icon: Icons.title_outlined,
          title: t.chat.sessionSettings.updateTitle,
          subtitle: _titleUpdating
              ? t.chat.sessionSettings.titleUpdating
              : t.chat.sessionSettings.updateTitleHint,
          onTap: _titleUpdating ? () {} : _updateTitle,
        ),
      ],
    );
  }

  /// 强制更新标题 + floating SnackBar 反馈
  Future<void> _updateTitle() async {
    setState(() => _titleUpdating = true);
    try {
      final updated = await ref
          .read(chatModeControllerProvider(widget.session).notifier)
          .updateTitleFromSummary(force: true);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            updated
                ? Translations.of(context).chat.sessionSettings.titleUpdated
                : Translations.of(context).chat.sessionSettings.titleFailed,
          ),
        ),
      );
      if (updated) {
        // 标题变了：刷新本地 _session（面板头部等处同步）
        setState(() {
          _session =
              ref.read(chatModeControllerProvider(widget.session)).session;
        });
      }
    } finally {
      if (mounted) setState(() => _titleUpdating = false);
    }
  }

  /// 弹出 DefaultModelPickerSheet 选择模型。
  ///
  /// 选中后通过 [_updateSession] 持久化到会话级字段。
  /// 清除选项：写全局当前快照（不再置 null 跟随态）；
  /// 全局未配置时保持会话原值（同为「未配置」具体态）。
  void _showModelPicker(Translations t) {
    showLmSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DefaultModelPickerSheet(
        selectedPresetId: _session.presetId,
        selectedModelId: _session.modelId,
        title: t.chat.sessionSettings.model,
        successMessage: t.chat.sessionSettings.modelSelected,
        clearLabel: t.chat.sessionSettings.resetToGlobal,
        clearSuccessMessage: t.chat.sessionSettings.modelCleared,
        onModelSelected: (presetId, modelId) => _updateSession(
          presetId == null && modelId == null
              ? _session.copyWith(
                  presetId: _globalSnapshot.presetId ?? _session.presetId,
                  modelId: _globalSnapshot.modelId ?? _session.modelId,
                )
              : _session.copyWith(presetId: presetId, modelId: modelId),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // System prompt
  // ---------------------------------------------------------------------------

  Widget _buildSystemPrompt(Translations t, LmPalette colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                t.chat.sessionSettings.systemPrompt,
                style: SimpleTextStyles.caption.copyWith(color: colors.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Spacer(),
            // 选择模板按钮：LMStory 增强，偏离 ChatBox（ChatBox 仅有纯文本框）
            // 原因：LMStory 已有模板系统（TemplateRepository），复用现有资产
            if (_systemPromptTemplates.isNotEmpty)
              TextButton.icon(
                onPressed: () => _showTemplatePicker(t, colors),
                icon: Icon(
                  Icons.bookmark_outline,
                  size: 16,
                  color: colors.primary,
                ),
                label: Text(
                  t.chat.sessionSettings.selectTemplate,
                  style: SimpleTextStyles.caption.copyWith(
                    color: colors.primary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SimpleSpacing.sXs,
                  ),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            IconButton(
              icon: Icon(Icons.refresh, size: 16, color: colors.faint),
              onPressed: () {
                _systemPromptController.clear();
                _updateSession(
                  _session.copyWith(systemPromptOverride: null),
                );
              },
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: t.chat.sessionSettings.resetToGlobal,
            ),
          ],
        ),
        const SizedBox(height: SimpleSpacing.sXs),
        TextField(
          controller: _systemPromptController,
          maxLines: 5,
          minLines: 1,
          style: SimpleTextStyles.bodySm.copyWith(color: colors.ink),
          decoration: InputDecoration(
            filled: true,
            fillColor: colors.surfaceElevated,
            border: OutlineInputBorder(
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
              borderSide: BorderSide.none,
            ),
            hintText: t.chat.sessionSettings.systemPromptHint,
            hintStyle: SimpleTextStyles.bodySm.copyWith(color: colors.faint),
            contentPadding: const EdgeInsets.all(SimpleSpacing.sMd),
          ),
          onChanged: (value) {
            // 500ms 防抖落库（原为逐击键写库），
            // 对齐导演模式项目规则输入的节奏。
            _systemPromptDebounce?.cancel();
            _systemPromptDebounce =
                Timer(const Duration(milliseconds: 500), () {
              // lm-motion-exempt: 面板内延迟回调（编排节流，非过渡动效）
              if (!mounted) return;
              _updateSession(
                _session.copyWith(
                  systemPromptOverride: value.isEmpty ? null : value,
                ),
              );
            });
          },
        ),
      ],
    );
  }

  /// 系统提示词模板选择弹窗。
  ///
  /// 选中模板后将其内容填入文本框，用户可继续编辑。
  /// 不持久化"选择了哪个模板"——因为用户编辑后模板关联无意义。
  void _showTemplatePicker(Translations t, LmPalette colors) {
    showLmDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(
            t.chat.sessionSettings.selectTemplate,
            style: SimpleTextStyles.title3.copyWith(color: colors.ink),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          backgroundColor: colors.surfaceElevated,
          shape: RoundedRectangleBorder(
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
          ),
          contentPadding: const EdgeInsets.only(top: SimpleSpacing.sSm),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: _systemPromptTemplates.length,
              separatorBuilder: (_, __) => Divider(
                height: 1,
                color: colors.divider,
              ),
              itemBuilder: (_, index) {
                final template = _systemPromptTemplates[index];
                return ListTile(
                  title: Text(
                    template.name,
                    style: SimpleTextStyles.bodySm.copyWith(
                      color: colors.ink,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    template.content,
                    style:
                        SimpleTextStyles.caption.copyWith(color: colors.muted),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: SimpleSpacing.sLg,
                    vertical: SimpleSpacing.sXs,
                  ),
                  onTap: () {
                    // 填入文本框并更新会话
                    _systemPromptController.text = template.content;
                    _systemPromptController.selection =
                        TextSelection.fromPosition(
                      TextPosition(offset: template.content.length),
                    );
                    _updateSession(
                      _session.copyWith(
                        systemPromptOverride: template.content,
                      ),
                    );
                    Navigator.pop(ctx);
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(t.common.cancel),
            ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Temperature slider
  // ---------------------------------------------------------------------------

  Widget _buildTemperatureSlider(Translations t, LmPalette colors) {
    const maxVal = 2.0;
    const step = 0.01;
    const fallbackDefault = 0.7;
    final globalTemp = _globalSnapshot.temperature ?? fallbackDefault;
    final value = _session.temperature ?? globalTemp;
    // 对齐  值比较口径——物化后列恒
    // 非 null，null 判据让「改回同值」后「全局 X」标注永久消失，与同屏
    // maxTokens/流式输出两行矛盾。滑杆量化误差用容差判定（同款）。
    final isCustomized = _session.temperature != null &&
        !_nearlyEqualDoubles(
          _session.temperature,
          globalTemp,
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                t.chat.sessionSettings.temperature,
                style: SimpleTextStyles.caption.copyWith(color: colors.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Spacer(),
            if (!isCustomized)
              Padding(
                padding: const EdgeInsets.only(right: SimpleSpacing.s2xs),
                child: Text(
                  t.common
                      .followingGlobal(value: globalTemp.toStringAsFixed(2)),
                  style:
                      SimpleTextStyles.overline.copyWith(color: colors.faint),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            // 值可点按编辑改为可视（图标+Tooltip+按钮语义），
            // 原为裸 GestureDetector 包纯文本，入口不可发现。
            EditableValueText(
              value: value.toStringAsFixed(2),
              label: t.chat.sessionSettings.temperature,
              tooltip: t.chat.sessionSettings.inputHint(
                min: '0',
                max: maxVal.toStringAsFixed(1),
              ),
              textStyle: SimpleTextStyles.caption.copyWith(color: colors.ink),
              iconColor: colors.faint,
              onTap: () => _showNumericInputDialog(
                context: context,
                title: t.chat.sessionSettings.temperature,
                currentValue: value,
                min: 0,
                max: maxVal,
                onConfirmed: (newValue) {
                  _updateSession(_session.copyWith(temperature: newValue));
                },
              ),
            ),
            IconButton(
              icon: Icon(Icons.refresh, size: 16, color: colors.faint),
              onPressed: isCustomized
                  ? () => _resetFieldToGlobal(
                        (s) => _session.copyWith(temperature: s.temperature),
                      )
                  : null,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: t.chat.sessionSettings.resetToGlobal,
            ),
          ],
        ),
        Slider(
          value: value,
          max: maxVal,
          divisions: (maxVal / step).round(),
          activeColor: colors.primary,
          inactiveColor: colors.primaryDim,
          label: value.toStringAsFixed(2),
          onChangeEnd: (newValue) {
            _updateSession(_session.copyWith(temperature: newValue));
          },
          onChanged: (newValue) {
            setState(() {
              _session = _session.copyWith(temperature: newValue);
            });
          },
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Top P slider
  // ---------------------------------------------------------------------------

  Widget _buildTopPSlider(Translations t, LmPalette colors) {
    const fallbackDefault = 1.0;
    final globalTopP = _globalSnapshot.topP ?? fallbackDefault;
    final value = _session.topP ?? globalTopP;
    // 同温度行——值比较 + 容差（口径）
    final isCustomized = _session.topP != null &&
        !_nearlyEqualDoubles(_session.topP, globalTopP);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                t.chat.sessionSettings.topP,
                style: SimpleTextStyles.caption.copyWith(color: colors.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Spacer(),
            if (!isCustomized)
              Padding(
                padding: const EdgeInsets.only(right: SimpleSpacing.s2xs),
                child: Text(
                  t.common
                      .followingGlobal(value: globalTopP.toStringAsFixed(2)),
                  style:
                      SimpleTextStyles.overline.copyWith(color: colors.faint),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            EditableValueText(
              value: value.toStringAsFixed(2),
              label: t.chat.sessionSettings.topP,
              tooltip: t.chat.sessionSettings.inputHint(
                min: '0',
                max: '1.0',
              ),
              textStyle: SimpleTextStyles.caption.copyWith(color: colors.ink),
              iconColor: colors.faint,
              onTap: () => _showNumericInputDialog(
                context: context,
                title: t.chat.sessionSettings.topP,
                currentValue: value,
                min: 0,
                max: 1,
                onConfirmed: (newValue) {
                  _updateSession(_session.copyWith(topP: newValue));
                },
              ),
            ),
            IconButton(
              icon: Icon(Icons.refresh, size: 16, color: colors.faint),
              onPressed: isCustomized
                  ? () => _resetFieldToGlobal(
                        (s) => _session.copyWith(topP: s.topP),
                      )
                  : null,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: t.chat.sessionSettings.resetToGlobal,
            ),
          ],
        ),
        Slider(
          value: value,
          divisions: 100,
          activeColor: colors.primary,
          inactiveColor: colors.primaryDim,
          label: value.toStringAsFixed(2),
          onChangeEnd: (newValue) {
            _updateSession(_session.copyWith(topP: newValue));
          },
          onChanged: (newValue) {
            setState(() {
              _session = _session.copyWith(topP: newValue);
            });
          },
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Numeric input dialog
  // ---------------------------------------------------------------------------

  void _showNumericInputDialog({
    required BuildContext context,
    required String title,
    required double currentValue,
    required double min,
    required double max,
    required ValueChanged<double> onConfirmed,
  }) {
    final t = Translations.of(context);
    final controller = TextEditingController(
      text: currentValue.toStringAsFixed(2),
    );

    showLmDialog<void>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          content: TextField(
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp('[0-9.]')),
            ],
            decoration: InputDecoration(
              hintText: t.chat.sessionSettings.inputHint(
                min: min.toStringAsFixed(1),
                max: max.toStringAsFixed(1),
              ),
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(t.common.cancel),
            ),
            TextButton(
              onPressed: () {
                final parsed = double.tryParse(controller.text);
                if (parsed == null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      behavior: SnackBarBehavior.floating,
                      content: Text(t.chat.sessionSettings.inputInvalid),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                  return;
                }
                if (parsed < min || parsed > max) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      behavior: SnackBarBehavior.floating,
                      content: Text(t.chat.sessionSettings.inputOutOfRange),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                  return;
                }
                Navigator.pop(ctx);
                onConfirmed(parsed);
              },
              child: Text(t.common.confirm),
            ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Max tokens
  // ---------------------------------------------------------------------------

  Widget _buildMaxTokens(Translations t, LmPalette colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildFieldLabel(
          t,
          colors,
          t.chat.sessionSettings.maxTokens,
          // 物化后列恒非 null，改值比较
          isCustomized: _session.maxTokens != _globalSnapshot.maxTokens,
          globalValueText: _globalSnapshot.maxTokens?.toString(),
          onReset: () => _resetFieldToGlobal(
            (s) => _session.copyWith(maxTokens: s.maxTokens ?? 0),
          ),
        ),
        const SizedBox(height: SimpleSpacing.sXs),
        TextField(
          controller: _maxTokensController,
          focusNode: _maxTokensFocusNode,
          keyboardType: TextInputType.number,
          style: SimpleTextStyles.bodySm.copyWith(color: colors.ink),
          decoration: InputDecoration(
            filled: true,
            fillColor: colors.surfaceElevated,
            border: OutlineInputBorder(
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
              borderSide: BorderSide.none,
            ),
            hintText: t.chat.sessionSettings.maxTokensHint,
            hintStyle: SimpleTextStyles.bodySm.copyWith(color: colors.faint),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: SimpleSpacing.sMd,
              vertical: SimpleSpacing.sSm,
            ),
          ),
          onSubmitted: _commitMaxTokens,
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Max context messages (nonlinear slider, per ChatBox)
  // ---------------------------------------------------------------------------

  /// Nonlinear scale options matching ChatBox's MaxContextMessageCountSlider.
  /// Index 0 = "No Limit" (0), rest are actual message counts.
  static const _contextMsgOptions = [0, 2, 4, 6, 8, 10, 20, 50, 100];

  Widget _buildMaxContextMessages(Translations t, LmPalette colors) {
    // null = no limit (maps to 0), otherwise use the value
    final value =
        _session.maxContextMessages ?? _globalSnapshot.maxContextMessages ?? 0;

    // Find the closest slider index for the current value
    var sliderIndex = 0;
    if (value > 0) {
      for (var i = _contextMsgOptions.length - 1; i >= 0; i--) {
        if (_contextMsgOptions[i] <= value) {
          // If value is between two options, snap to the lower one
          sliderIndex = i;
          break;
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              t.chat.sessionSettings.maxContextMessages,
              style: SimpleTextStyles.caption.copyWith(color: colors.muted),
            ),
            if (_session.maxContextMessages == null) ...[
              const SizedBox(width: SimpleSpacing.s2xs),
              Text(
                t.common.followingGlobal(
                  value: (_globalSnapshot.maxContextMessages ?? 0).toString(),
                ),
                style: SimpleTextStyles.overline.copyWith(color: colors.faint),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const Spacer(),
            Text(
              value == 0
                  ? t.chat.sessionSettings.maxContextMessagesNoLimit
                  : value.toString(),
              style: SimpleTextStyles.caption.copyWith(
                color: value > 0 ? colors.ink : colors.faint,
              ),
            ),
            IconButton(
              icon: Icon(Icons.refresh, size: 16, color: colors.faint),
              onPressed: _session.maxContextMessages != null
                  ? () => _resetFieldToGlobal(
                        (s) => _session.copyWith(
                          maxContextMessages: s.maxContextMessages,
                        ),
                      )
                  : null,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: t.chat.sessionSettings.resetToGlobal,
            ),
          ],
        ),
        Slider(
          value: sliderIndex.toDouble(),
          max: (_contextMsgOptions.length - 1).toDouble(),
          divisions: _contextMsgOptions.length - 1,
          activeColor: colors.primary,
          inactiveColor: colors.primaryDim,
          label: value == 0
              ? t.chat.sessionSettings.maxContextMessagesNoLimit
              : value.toString(),
          onChangeEnd: (newIndex) {
            final newValue = _contextMsgOptions[newIndex.round()];
            _updateSession(
              _session.copyWith(
                maxContextMessages: newValue == 0 ? null : newValue,
              ),
            );
          },
          onChanged: (newIndex) {
            final newValue = _contextMsgOptions[newIndex.round()];
            setState(() {
              _session = _session.copyWith(
                maxContextMessages: newValue == 0 ? null : newValue,
              );
            });
          },
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Stream toggle
  // ---------------------------------------------------------------------------

  Widget _buildStreamToggle(Translations t, LmPalette colors) {
    const fallbackDefault = true;
    final value = _session.streamEnabled ??
        _globalSnapshot.streamEnabled ??
        fallbackDefault;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildFieldLabel(
          t,
          colors,
          t.chat.sessionSettings.streamEnabled,
          // 物化后列恒非 null，改值比较
          isCustomized: _session.streamEnabled != _globalSnapshot.streamEnabled,
          globalValueText: (_globalSnapshot.streamEnabled ?? true)
              ? t.chat.sessionSettings.streamEnabledOn
              : t.chat.sessionSettings.streamEnabledOff,
          onReset: () => _resetFieldToGlobal(
            (s) => _session.copyWith(streamEnabled: s.streamEnabled),
          ),
        ),
        SwitchListTile(
          title: Text(
            value
                ? t.chat.sessionSettings.streamEnabledOn
                : t.chat.sessionSettings.streamEnabledOff,
            style: SimpleTextStyles.body.copyWith(color: colors.ink),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          value: value,
          activeThumbColor: colors.primary,
          contentPadding: EdgeInsets.zero,
          onChanged: (newValue) {
            _updateSession(_session.copyWith(streamEnabled: newValue));
          },
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Reasoning effort (思考预算)
  // ---------------------------------------------------------------------------

  Widget _buildReasoningEffort(Translations t, LmPalette colors) {
    // 2026-07-28 修复：从 4 档改为 5 档，对齐全局设置的 notSet/disabled/low/medium/high
    // 原代码只有 4 档（disabled/low/medium/high），缺"跟随全局"档位，
    // 且 null fallback 显示成 disabled，让用户误判当前状态。
    // 现在明确区分：
    // - null（跟随全局）→ 不发参数，跟随模型默认行为
    // - disabled（显式禁用）→ 发送厂商原生关闭参数，强制关闭思考
    final sessionEffort = _session.reasoningEffort;
    // 当会话级为 null 时，显示当前生效的全局值（fallback 到 disabled 仅用于显示）
    final globalEffort =
        _globalSnapshot.reasoningEffort ?? ReasoningEffort.disabled;
    final effectiveEffort = sessionEffort ?? globalEffort;
    final effectiveLabel = _effortLabel(t, effectiveEffort);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildFieldLabel(
          t,
          colors,
          t.chat.sessionSettings.reasoningEffort,
          onReset: () => _resetFieldToGlobal(
            (s) => _session.copyWith(reasoningEffort: s.reasoningEffort),
          ),
        ),
        // 当会话级为 null（跟随全局）时，显示当前生效的全局值
        if (sessionEffort == null)
          Padding(
            padding: const EdgeInsets.only(top: SimpleSpacing.s2xs),
            child: Text(
              t.chat.sessionSettings.reasoningEffortCurrentEffect(
                prefix: effectiveLabel,
              ),
              style: SimpleTextStyles.caption.copyWith(color: colors.faint),
            ),
          ),
        const SizedBox(height: SimpleSpacing.sXs),
        // 用 Material（而非 Container+BoxDecoration(color)）作为色层：
        // Container 的 color 会作为 ColoredBox 渲染在 Material 与 InkWell 之间，
        // 遮蔽 ink splash 水波纹。改为 Material(color) 让色层本身成为 ink splash 宿主。
        Material(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              _ReasoningEffortOption(
                label: t.chat.sessionSettings.reasoningEffortOptions.notSet,
                isSelected: sessionEffort == null,
                onTap: () => _updateSession(
                  _session.copyWith(reasoningEffort: null),
                ),
                colors: colors,
              ),
              Divider(
                height: 1,
                color: colors.divider,
                indent: SimpleSpacing.sLg,
              ),
              _ReasoningEffortOption(
                label: t.chat.sessionSettings.reasoningEffortOptions.disabled,
                isSelected: sessionEffort == ReasoningEffort.disabled,
                onTap: () => _updateSession(
                  _session.copyWith(reasoningEffort: ReasoningEffort.disabled),
                ),
                colors: colors,
              ),
              Divider(
                height: 1,
                color: colors.divider,
                indent: SimpleSpacing.sLg,
              ),
              _ReasoningEffortOption(
                label: t.chat.sessionSettings.reasoningEffortOptions.low,
                isSelected: sessionEffort == ReasoningEffort.low,
                onTap: () => _updateSession(
                  _session.copyWith(reasoningEffort: ReasoningEffort.low),
                ),
                colors: colors,
              ),
              Divider(
                height: 1,
                color: colors.divider,
                indent: SimpleSpacing.sLg,
              ),
              _ReasoningEffortOption(
                label: t.chat.sessionSettings.reasoningEffortOptions.medium,
                isSelected: sessionEffort == ReasoningEffort.medium,
                onTap: () => _updateSession(
                  _session.copyWith(reasoningEffort: ReasoningEffort.medium),
                ),
                colors: colors,
              ),
              Divider(
                height: 1,
                color: colors.divider,
                indent: SimpleSpacing.sLg,
              ),
              _ReasoningEffortOption(
                label: t.chat.sessionSettings.reasoningEffortOptions.high,
                isSelected: sessionEffort == ReasoningEffort.high,
                onTap: () => _updateSession(
                  _session.copyWith(reasoningEffort: ReasoningEffort.high),
                ),
                colors: colors,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 获取思考等级的中文名（用于"跟随全局"时显示当前生效值）
  String _effortLabel(Translations t, ReasoningEffort effort) {
    switch (effort) {
      case ReasoningEffort.disabled:
        return t.chat.sessionSettings.reasoningEffortOptions.disabled;
      case ReasoningEffort.low:
        return t.chat.sessionSettings.reasoningEffortOptions.low;
      case ReasoningEffort.medium:
        return t.chat.sessionSettings.reasoningEffortOptions.medium;
      case ReasoningEffort.high:
        return t.chat.sessionSettings.reasoningEffortOptions.high;
    }
  }

  // ---------------------------------------------------------------------------
  // Delete session
  // ---------------------------------------------------------------------------

  Widget _buildDeleteButton(Translations t, LmPalette colors) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: colors.error,
          side: BorderSide(color: colors.error.withValues(alpha: 0.3)),
          padding: const EdgeInsets.symmetric(vertical: SimpleSpacing.sMd),
          shape: RoundedRectangleBorder(
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
          ),
        ),
        onPressed: () async {
          final confirmed = await showLmDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(
                t.chat.sessionSettings.deleteSession,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              content: Text(
                t.chat.sessionSettings.deleteConfirm,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(t.common.cancel),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: TextButton.styleFrom(
                    foregroundColor: colors.error,
                  ),
                  child: Text(t.common.delete),
                ),
              ],
            ),
          );

          if (confirmed ?? false) {
            if (!mounted) return;
            // 会话设置面板是对话模式第三条
            // 删除路径，侧边栏有生成中禁删守卫而此处没有——流式轮仍持有
            // controller，删除后继续向已删会话回写孤儿数据
            final controllerState =
                ref.read(chatModeControllerProvider(_session));
            // 与 chat_mode_page 菜单守卫同口径（补 isSending 窗口）
            if (controllerState.isSending ||
                controllerState.isStreaming ||
                controllerState.isCompressing) {
              ScaffoldMessenger.of(context)
                ..hideCurrentSnackBar()
                ..showSnackBar(
                  SnackBar(
                    behavior: SnackBarBehavior.floating,
                    content: Text(t.chat.failure.deleteBlockedWhileGenerating),
                  ),
                );
              return;
            }
            final chatRepo = ref.read<ChatRepository>(chatRepositoryProvider);
            await chatRepo.deleteSession(_session.sessionId);
            // 删除即清（non-autoDispose family 实例）
            ref.invalidate(chatModeControllerProvider(widget.session));
            widget.onSessionDeleted();
          }
        },
        child: Text(
          t.chat.sessionSettings.deleteSession,
          style: SimpleTextStyles.bodySm.copyWith(
            color: colors.error,
            fontWeight: FontWeight.w500,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  /// 前往对话模式默认配置（全局设置）
  void _navigateToGlobalSettings() {
    Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const ChatSettingsPage(),
      ),
    );
  }

  Widget _buildGlobalSettingsLink(Translations t, LmPalette colors) {
    return Center(
      child: TextButton.icon(
        onPressed: _navigateToGlobalSettings,
        icon: Icon(
          Icons.settings_outlined,
          size: 16,
          color: colors.primary,
        ),
        label: Text(
          t.chat.sessionSettings.openGlobalSettings,
          style: SimpleTextStyles.caption.copyWith(color: colors.primary),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

/// 思考预算选项组件（列表式，对标通用设置的 _SelectionOption 样式）
class _ReasoningEffortOption extends StatelessWidget {
  const _ReasoningEffortOption({
    required this.label,
    required this.isSelected,
    required this.onTap,
    required this.colors,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final LmPalette colors;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SimpleSpacing.sLg,
          vertical: SimpleSpacing.sMd,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: SimpleTextStyles.body.copyWith(
                  color: colors.ink,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isSelected) Icon(Icons.check, size: 20, color: colors.primary),
          ],
        ),
      ),
    );
  }
}
