import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/components/simple_app_bar.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/model_capability.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/pages/provider_list_page.dart';
import 'package:lmstory/features/settings/presentation/widgets/model_capability_badges.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 默认模型选择底部 sheet（单菜单模式：按供应商分组列出全部模型）。
///
/// 从所有供应商中收集指定 [modelType] 类型的模型，按供应商分组展示。
/// 用户选中后直接持久化（通过 [onModelSelected] 回调或默认的
/// [SettingsNotifier.setDefaultModel]），sheet 自行关闭并显示成功 snackbar。
///
/// **2026-07-24 双菜单→单菜单统一改造**：
/// - 新增 [modelType] 参数（默认 [ModelType.chat]），支持过滤 embedding 等类型
/// - 新增 [clearLabel] 参数：非 null 时在列表顶部显示"清除/使用全局"按钮，
///   会话级模式下点击返回 (null, null) 表示"跟随全局"
/// - 新增 [clearSuccessMessage] 参数：清除成功 snackbar 文案
/// - 新增 [onBeforeSelect] 钩子：选择前异步确认（如嵌入模型切换确认），
///   返回 false 取消选择
/// - [onModelSelected] 签名改为支持 null（清除语义）
///
/// 2026-07-21 复用扩展：新增 [title] / [onModelSelected] / [successMessage]
/// 参数，支持复用于"会话标题模型"等场景。未提供时走默认的 setDefaultModel 路径。
///
/// 设计取舍：去掉类型过滤 chip（原 DefaultModelPage 的全部/对话/嵌入/重排），
/// 因为"对话模式默认模型"语义上只关心对话模型，嵌入/重排在此无意义。
/// 简化后 sheet 更聚焦，降低非技术用户的认知负担。
class DefaultModelPickerSheet extends ConsumerStatefulWidget {
  const DefaultModelPickerSheet({
    required this.selectedPresetId,
    required this.selectedModelId,
    this.title,
    this.onModelSelected,
    this.successMessage,
    this.modelType = ModelType.chat,
    this.clearLabel,
    this.clearSuccessMessage,
    this.onBeforeSelect,
    super.key,
  });

  final String? selectedPresetId;
  final String? selectedModelId;

  /// 自定义 AppBar 标题。null 时使用 defaultModel.select。
  final String? title;

  /// 自定义选择回调。null 时走默认的 setDefaultModel 路径。
  ///
  /// 复用场景（如会话标题模型、会话级模型覆盖）传入此回调，写入不同的
  /// user_overrides key 或会话字段。接受 null 表示"清除选择/跟随全局"。
  final Future<void> Function(String? presetId, String? modelId)?
      onModelSelected;

  /// 自定义成功 snackbar 文案。null 时使用 defaultModel.selected。
  final String? successMessage;

  /// 模型类型过滤。默认 [ModelType.chat]。
  ///
  /// 嵌入模型场景传 [ModelType.embedding]；故事模式 4 阶段都是 chat 类型。
  /// 注：运行时 resolveEmbeddingConfig 不检查 type，UI 严于运行时是过度设计，
  /// 但 sheet 内过滤能让用户更聚焦（避免在嵌入场景看到 chat 模型列表）。
  /// 当供应商的 cachedModels 全部 type=null（旧数据或 API 未返回）时，
  /// 不做过滤直接展示，避免空列表误导用户。
  final ModelType modelType;

  /// 清除按钮文案。非 null 时在列表顶部显示一个"清除/使用全局"tile。
  ///
  /// 会话级模式下传"使用全局配置"，点击返回 (null, null) 表示跟随全局；
  /// 全局级模式下传"清除选择"或不传（不显示清除按钮）。
  final String? clearLabel;

  /// 清除成功 snackbar 文案。null 时不显示 snackbar（静默清除）。
  final String? clearSuccessMessage;

  /// 选择前异步确认钩子。
  ///
  /// 嵌入模型切换时已有向量会失效，传此钩子弹确认对话框。
  /// 返回 false 取消选择，true 继续持久化。
  /// 清除操作不触发此钩子（清除无需确认，由 [clearLabel] 自身语义承担）。
  final Future<bool> Function(String presetId, String modelId)? onBeforeSelect;

  @override
  ConsumerState<DefaultModelPickerSheet> createState() =>
      _DefaultModelPickerSheetState();
}

class _DefaultModelPickerSheetState
    extends ConsumerState<DefaultModelPickerSheet> {
  @override
  void initState() {
    super.initState();
    Future.microtask(
      () {
        // 已有数据时静默刷新（不闪全屏 spinner）。
        final hasData = ref.read(settingsNotifierProvider).presets.isNotEmpty;
        return ref
            .read(settingsNotifierProvider.notifier)
            .refresh(silent: hasData);
      },
    );
  }

  /// 收集所有供应商的指定类型模型
  ///
  /// 2026-07-24 改造：原实现固定按 chat 类型过滤，现改为按 `widget.modelType`
  /// 过滤。
  ///
  /// 注：`ModelInfo.type` 字段非空，默认 `ModelType.chat`（从 JSON 加载时
  /// `ModelType.fromString(null)` 也返回 `chat`）。所以无需额外的"旧数据兼容"
  /// 逻辑——所有模型至少有 `chat` 类型，过滤结果准确。
  List<_ProviderGroupData> _collectGroups(List<ApiPreset> presets) {
    final groups = <_ProviderGroupData>[];
    for (final preset in presets) {
      final models =
          preset.cachedModels.where((m) => m.type == widget.modelType).toList();
      if (models.isEmpty) continue;
      groups.add(_ProviderGroupData(preset: preset, models: models));
    }
    return groups;
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final state = ref.watch(settingsNotifierProvider);

    final groups = _collectGroups(state.presets);

    //  修复：区分"加载中"和"真正无数据"
    final isLoading = state.isLoading && groups.isEmpty;

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.85,
      child: Scaffold(
        // 琉璃下面层让位 GlassBottomSheet 工厂；经典保持原槽位零变化。
        backgroundColor: context.lmSheetFaceColor(context.lm.palette.bg),
        appBar: SimpleAppBar(
          title: widget.title ?? t.settings.chatSettings.defaultModel.select,
        ),
        body: isLoading
            ? _buildLoading(context)
            : (groups.isEmpty
                ? _buildEmpty(context, t)
                : _buildList(context, groups, t)),
      ),
    );
  }

  Widget _buildLoading(BuildContext context) {
    final colors = context.lm.palette;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: colors.primary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty(BuildContext context, Translations t) {
    final colors = context.lm.palette;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.smart_toy_outlined, size: 64, color: colors.faint),
          const SizedBox(height: SimpleSpacing.sLg),
          Text(
            t.settings.chatSettings.defaultModel.empty,
            style: SimpleTextStyles.caption,
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: SimpleSpacing.sMd),
          ElevatedButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const ProviderListPage(),
                ),
              );
            },
            icon: const Icon(Icons.dns_outlined, size: 18),
            label: Text(
              t.settings.chatSettings.defaultModel.emptyAction,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(
    BuildContext context,
    List<_ProviderGroupData> groups,
    Translations t,
  ) {
    return ListView.builder(
      padding: const EdgeInsets.all(SimpleSpacing.sLg),
      itemCount: groups.length + (widget.clearLabel != null ? 1 : 0),
      itemBuilder: (context, index) {
        // 顶部"清除/使用全局"按钮
        if (widget.clearLabel != null && index == 0) {
          return _ClearSelectionTile(
            label: widget.clearLabel!,
            onTap: () => _handleClear(context),
          );
        }
        final groupIndex = widget.clearLabel != null ? index - 1 : index;
        final group = groups[groupIndex];
        return _ProviderGroup(
          presetId: group.preset.presetId,
          presetName: group.preset.name,
          models: group.models,
          selectedPresetId: widget.selectedPresetId,
          selectedModelId: widget.selectedModelId,
          onSelect: (model) => _handleSelect(context, group, model),
        );
      },
    );
  }

  /// 处理模型选择：onBeforeSelect 钩子 → 持久化 → 关闭 sheet → snackbar
  Future<void> _handleSelect(
    BuildContext context,
    _ProviderGroupData group,
    ModelInfo model,
  ) async {
    // 选择前确认钩子（如嵌入模型切换确认）
    if (widget.onBeforeSelect != null) {
      final confirmed = await widget.onBeforeSelect!(
        group.preset.presetId,
        model.modelId,
      );
      if (!confirmed) return; // 用户取消，不关闭 sheet
    }

    if (widget.onModelSelected != null) {
      await widget.onModelSelected!(
        group.preset.presetId,
        model.modelId,
      );
    } else {
      await ref.read(settingsNotifierProvider.notifier).setDefaultModel(
            presetId: group.preset.presetId,
            modelId: model.modelId,
          );
    }
    if (!context.mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          widget.successMessage ??
              t.settings.chatSettings.defaultModel.selected,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  /// 处理清除选择：返回 (null, null) 给调用方
  Future<void> _handleClear(BuildContext context) async {
    if (widget.onModelSelected != null) {
      await widget.onModelSelected!(null, null);
    } else {
      await ref.read(settingsNotifierProvider.notifier).setDefaultModel(
            presetId: null,
            modelId: null,
          );
    }
    if (!context.mounted) return;
    Navigator.of(context).pop();
    if (widget.clearSuccessMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            widget.clearSuccessMessage!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }
}

/// 顶部"清除选择/使用全局配置"tile。
///
/// 视觉：与模型项一致的高度，但用 surfaceVariant 背景 + 居中文案 + 不同图标，
/// 让用户一眼识别这是"特殊选项"而非具体模型。
class _ClearSelectionTile extends StatelessWidget {
  const _ClearSelectionTile({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: SimpleSpacing.sMd),
      child: Material(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SimpleSpacing.sMd,
              vertical: SimpleSpacing.sSm + 2,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.layers_clear_outlined,
                  size: 18,
                  color: colors.muted,
                ),
                const SizedBox(width: SimpleSpacing.sSm),
                Expanded(
                  child: Text(
                    label,
                    style: SimpleTextStyles.body.copyWith(
                      color: colors.muted,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 单个供应商分组数据。
class _ProviderGroupData {
  const _ProviderGroupData({required this.preset, required this.models});
  final ApiPreset preset;
  final List<ModelInfo> models;
}

/// 供应商分组：可折叠的组标题 + 模型列表容器。
///
/// **2026-07-24 折叠功能**（对标 ChatBox MobileModelSelector）：
/// 默认展开，点击组标题可收起/展开。组标题显示 chevron 图标 + 供应商名 +
/// 模型数量 badge。收起时仅显示标题，展开时显示模型列表。
/// 折叠状态为 sheet 内局部 state，关闭 sheet 后重置。
class _ProviderGroup extends StatefulWidget {
  const _ProviderGroup({
    required this.presetId,
    required this.presetName,
    required this.models,
    required this.selectedPresetId,
    required this.selectedModelId,
    required this.onSelect,
  });

  final String presetId;
  final String presetName;
  final List<ModelInfo> models;
  final String? selectedPresetId;
  final String? selectedModelId;
  final ValueChanged<ModelInfo> onSelect;

  @override
  State<_ProviderGroup> createState() => _ProviderGroupState();
}

class _ProviderGroupState extends State<_ProviderGroup> {
  /// 折叠状态：false = 展开（默认），true = 收起。
  ///
  /// 默认展开（对标 ChatBox：`collapsedProviders[provider.id] || false`），
  /// 用户可点击组标题切换。包含当前选中模型的供应商默认展开，
  /// 让用户一眼看到自己的选择。
  late bool _isCollapsed = !_containsSelectedModel();

  bool _containsSelectedModel() {
    if (widget.selectedPresetId != widget.presetId) return false;
    return widget.models.any((m) => m.modelId == widget.selectedModelId);
  }

  void _toggle() {
    setState(() => _isCollapsed = !_isCollapsed);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 组标题：可点击折叠/展开
        // 用 Material+InkWell 让点击产生水波纹反馈，而非 GestureDetector（无视觉反馈）
        Padding(
          padding: const EdgeInsets.only(top: SimpleSpacing.sSm),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _toggle,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: SimpleSpacing.sXs,
                  vertical: SimpleSpacing.sXs,
                ),
                child: Row(
                  children: [
                    // Chevron 图标：展开时向下，收起时向右
                    // 对标 ChatBox IconChevronDown + clsx('transition-transform', isCollapsed ? '-rotate-90' : '')
                    Icon(
                      Icons.keyboard_arrow_down,
                      size: 18,
                      color: colors.faint,
                    ),
                    const SizedBox(width: SimpleSpacing.sXs),
                    Expanded(
                      child: Text(
                        widget.presetName,
                        style: SimpleTextStyles.body.copyWith(
                          fontWeight: FontWeight.w600,
                          color: colors.muted,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: SimpleSpacing.sXs),
                    // 模型数量 badge
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: SimpleSpacing.sXs,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: colors.faint.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(
                          context.lmUi.radius(LmCorner.xs),
                        ),
                      ),
                      child: Text(
                        '${widget.models.length}',
                        style: SimpleTextStyles.overline.copyWith(
                          color: colors.faint,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        // 模型列表：使用 AnimatedSize 实现平滑折叠动画
        AnimatedSize(
          duration: LmMotion.base,
          curve: LmMotion.easeEmphasis,
          alignment: Alignment.topCenter,
          child: _isCollapsed
              ? const SizedBox.shrink()
              : Container(
                  margin: const EdgeInsets.only(
                    top: SimpleSpacing.sXs,
                    bottom: SimpleSpacing.sMd,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surfaceVariant,
                    borderRadius:
                        BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: widget.models.length,
                    separatorBuilder: (_, __) => Divider(
                      height: 1,
                      thickness: 1,
                      color: colors.divider,
                    ),
                    itemBuilder: (context, index) {
                      final model = widget.models[index];
                      // 选中态：必须 presetId 与 modelId 同时匹配，避免跨供应商同名误判
                      final isSelected =
                          widget.presetId == widget.selectedPresetId &&
                              widget.selectedModelId == model.modelId;
                      return _ModelItem(
                        model: model,
                        isSelected: isSelected,
                        onTap: () => widget.onSelect(model),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

/// 单个模型项：图标 + 名称 + 能力 badge + 元数据 + 选中勾号。
class _ModelItem extends StatelessWidget {
  const _ModelItem({
    required this.model,
    required this.isSelected,
    required this.onTap,
  });

  final ModelInfo model;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SimpleSpacing.sMd,
          vertical: SimpleSpacing.sSm,
        ),
        child: Row(
          children: [
            Icon(
              Icons.smart_toy_outlined,
              size: 18,
              color: isSelected ? colors.primary : colors.faint,
            ),
            const SizedBox(width: SimpleSpacing.sSm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          model.displayName ?? model.modelId,
                          style: SimpleTextStyles.body.copyWith(
                            color: isSelected ? colors.primary : null,
                            fontWeight:
                                isSelected ? FontWeight.w600 : FontWeight.w400,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (model.capabilities.isNotEmpty) ...[
                        const SizedBox(width: SimpleSpacing.sXs),
                        ModelCapabilityBadges(
                          capabilities: model.capabilities,
                          size: 13,
                        ),
                      ],
                    ],
                  ),
                  Row(
                    children: [
                      if (model.displayName != null)
                        Flexible(
                          child: Text(
                            model.modelId,
                            style: SimpleTextStyles.overline,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      if (model.contextWindow != null) ...[
                        const SizedBox(width: SimpleSpacing.sXs),
                        _metaChip(
                          colors,
                          Icons.straighten,
                          _formatTokens(model.contextWindow!),
                        ),
                      ],
                      if (model.maxOutput != null) ...[
                        const SizedBox(width: SimpleSpacing.sXs),
                        _metaChip(
                          colors,
                          Icons.output,
                          _formatTokens(model.maxOutput!),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(Icons.check_circle, size: 18, color: colors.primary),
          ],
        ),
      ),
    );
  }

  Widget _metaChip(LmPalette colors, IconData icon, String text) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: colors.faint),
          const SizedBox(width: 2),
          Flexible(
            child: Text(
              text,
              style: SimpleTextStyles.overline.copyWith(color: colors.faint),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );

  String _formatTokens(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).round()}K';
    return '$n';
  }
}
