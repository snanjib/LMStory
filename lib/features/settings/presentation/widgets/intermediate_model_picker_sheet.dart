import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/model_capability.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/pages/provider_list_page.dart';
import 'package:lmstory/features/settings/presentation/widgets/model_capability_badges.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式模型选择底部 sheet（夜航主题，单菜单模式）。
///
/// **2026-07-24 双菜单→单菜单统一改造**：与 Simple 模式的 `DefaultModelPickerSheet`
/// 结构对齐，但用夜航主题（IntermediateColors/Spacing/Radius/TextStyles）保持故事模式
/// 视觉独立性。项目规则要求"故事模式必须用独立 UI 组件不复用 Simple 模式组件"，
/// 故此 sheet 独立实现，逻辑与 Simple 版本保持一致。
///
/// 从所有供应商中收集指定 [modelType] 类型的模型，按供应商分组展示。
/// 用户选中后通过 [onModelSelected] 回调持久化，sheet 关闭并显示成功 snackbar。
///
/// 支持的扩展参数（与 Simple 版本一致）：
/// - [modelType]：模型类型过滤，默认 [ModelType.chat]
/// - [clearLabel]：非 null 时在列表顶部显示"清除/使用全局"按钮
/// - [clearSuccessMessage]：清除成功 snackbar 文案
/// - [onBeforeSelect]：选择前异步确认钩子（嵌入模型切换确认）
/// - [onModelSelected] 接受 null 表示"清除选择/跟随全局"
///
/// 与 Simple 版本的视觉差异：
/// - 配色：surfaceVariant 容器 + ink/muted/faint 文字（夜航主题）
/// - 字体：IntermediateTextStyles（label/bodyUi/caption/overline）
/// - 圆角：IntermediateRadius.rMd（夜航主题）
/// - 间距：IntermediateSpacing（夜航主题）
/// - 配色随全局主题（夜航已收编为全局夜间基础，局部包裹已拆除）
class IntermediateModelPickerSheet extends ConsumerStatefulWidget {
  const IntermediateModelPickerSheet({
    required this.selectedPresetId,
    required this.selectedModelId,
    required this.title,
    required this.onModelSelected,
    this.successMessage,
    this.modelType = ModelType.chat,
    this.clearLabel,
    this.clearSuccessMessage,
    this.onBeforeSelect,
    super.key,
  });

  final String? selectedPresetId;
  final String? selectedModelId;

  /// AppBar 标题（必填，故事模式无默认文案可借用）。
  final String title;

  /// 选择回调（必填，故事模式无默认 setDefaultModel 路径可走）。
  ///
  /// 接受 null 表示"清除选择/跟随全局"。
  final Future<void> Function(String? presetId, String? modelId)
      onModelSelected;

  /// 自定义成功 snackbar 文案。null 时不显示 snackbar。
  final String? successMessage;

  /// 模型类型过滤。默认 [ModelType.chat]。
  final ModelType modelType;

  /// 清除按钮文案。非 null 时在列表顶部显示一个"清除/使用全局"tile。
  final String? clearLabel;

  /// 清除成功 snackbar 文案。null 时不显示 snackbar。
  final String? clearSuccessMessage;

  /// 选择前异步确认钩子。
  final Future<bool> Function(String presetId, String modelId)? onBeforeSelect;

  @override
  ConsumerState<IntermediateModelPickerSheet> createState() =>
      _IntermediateModelPickerSheetState();
}

class _IntermediateModelPickerSheetState
    extends ConsumerState<IntermediateModelPickerSheet> {
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
  /// 与 DefaultModelPickerSheet._collectGroups 逻辑保持一致。
  /// [ModelInfo.type] 字段非空（默认 [ModelType.chat]），无需旧数据兼容逻辑。
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
    final colors = context.lm.palette;

    final groups = _collectGroups(state.presets);
    final isLoading = state.isLoading && groups.isEmpty;

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.85,
      child: Scaffold(
        // 琉璃下面层让位 GlassBottomSheet 工厂；经典保持原槽位零变化。
        backgroundColor: context.lmSheetFaceColor(colors.bg),
        appBar: AppBar(
          title: FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              widget.title,
              style: IntermediateTextStyles.title.copyWith(color: colors.ink),
            ),
          ),
          backgroundColor: context.lmSheetFaceColor(colors.bg),
          foregroundColor: colors.ink,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
        ),
        body: isLoading
            ? _buildLoading(context)
            : (groups.isEmpty
                ? _buildEmpty(context, t)
                : _buildList(context, groups)),
      ),
    );
  }

  Widget _buildLoading(BuildContext context) {
    final colors = context.lm.palette;
    return Center(
      child: SizedBox(
        width: 32,
        height: 32,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          color: colors.primary,
        ),
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
          const SizedBox(height: IntermediateSpacing.sLg),
          Text(
            t.settings.chatSettings.defaultModel.empty,
            style: IntermediateTextStyles.caption.copyWith(color: colors.faint),
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: IntermediateSpacing.sMd),
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
  ) {
    return ListView.builder(
      padding: const EdgeInsets.all(IntermediateSpacing.sLg),
      itemCount: groups.length + (widget.clearLabel != null ? 1 : 0),
      itemBuilder: (context, index) {
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
    if (widget.onBeforeSelect != null) {
      final confirmed = await widget.onBeforeSelect!(
        group.preset.presetId,
        model.modelId,
      );
      if (!confirmed) return;
    }

    await widget.onModelSelected(
      group.preset.presetId,
      model.modelId,
    );
    if (!context.mounted) return;
    Navigator.of(context).pop();
    if (widget.successMessage != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            widget.successMessage!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  /// 处理清除选择：返回 (null, null) 给调用方
  Future<void> _handleClear(BuildContext context) async {
    await widget.onModelSelected(null, null);
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

/// 顶部"清除选择/使用全局配置"tile（夜航主题）。
class _ClearSelectionTile extends StatelessWidget {
  const _ClearSelectionTile({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: IntermediateSpacing.sMd),
      child: Material(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: IntermediateSpacing.sMd,
              vertical: IntermediateSpacing.sSm + 2,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.layers_clear_outlined,
                  size: 18,
                  color: colors.muted,
                ),
                const SizedBox(width: IntermediateSpacing.sSm),
                Expanded(
                  child: Text(
                    label,
                    style: IntermediateTextStyles.bodyUi.copyWith(
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

/// 供应商分组：可折叠的组标题 + 模型列表容器（夜航主题）。
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
  /// 折叠状态：包含当前选中模型的供应商默认展开，其他默认收起。
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
        Padding(
          padding: const EdgeInsets.only(top: IntermediateSpacing.sSm),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _toggle,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: IntermediateSpacing.sXs,
                  vertical: IntermediateSpacing.sXs,
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.keyboard_arrow_down,
                      size: 18,
                      color: colors.faint,
                    ),
                    const SizedBox(width: IntermediateSpacing.sXs),
                    Expanded(
                      child: Text(
                        widget.presetName,
                        style: IntermediateTextStyles.bodyUi.copyWith(
                          fontWeight: FontWeight.w600,
                          color: colors.muted,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: IntermediateSpacing.sXs),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: IntermediateSpacing.sXs,
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
                        style: IntermediateTextStyles.caption.copyWith(
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
        AnimatedSize(
          duration: LmMotion.base,
          curve: LmMotion.easeEmphasis,
          alignment: Alignment.topCenter,
          child: _isCollapsed
              ? const SizedBox.shrink()
              : Container(
                  margin: const EdgeInsets.only(
                    top: IntermediateSpacing.sXs,
                    bottom: IntermediateSpacing.sMd,
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
          horizontal: IntermediateSpacing.sMd,
          vertical: IntermediateSpacing.sSm,
        ),
        child: Row(
          children: [
            Icon(
              Icons.smart_toy_outlined,
              size: 18,
              color: isSelected ? colors.primary : colors.faint,
            ),
            const SizedBox(width: IntermediateSpacing.sSm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          model.displayName ?? model.modelId,
                          style: IntermediateTextStyles.bodyUi.copyWith(
                            color: isSelected ? colors.primary : null,
                            fontWeight:
                                isSelected ? FontWeight.w600 : FontWeight.w400,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (model.capabilities.isNotEmpty) ...[
                        const SizedBox(width: IntermediateSpacing.sXs),
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
                            style: IntermediateTextStyles.caption,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      if (model.contextWindow != null) ...[
                        const SizedBox(width: IntermediateSpacing.sXs),
                        _metaChip(
                          colors,
                          Icons.straighten,
                          _formatTokens(model.contextWindow!),
                        ),
                      ],
                      if (model.maxOutput != null) ...[
                        const SizedBox(width: IntermediateSpacing.sXs),
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
              // 2026-07-24 修复：IntermediateTextStyles 无 overline getter，用 caption 替代
              style:
                  IntermediateTextStyles.caption.copyWith(color: colors.faint),
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
