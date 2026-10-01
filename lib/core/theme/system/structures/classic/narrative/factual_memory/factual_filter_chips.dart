import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_radius.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';
// 从 factual_memory_tab.dart 拆出（原 _buildFilterChips / _buildChip /
// _buildFilterDivider，逐字符搬运；各 Chip 点击经回调交回 Tab State
// setState，取值口径不变）。

/// 筛选标签栏（可折叠）：实体类型 / 重要性 / 归档状态 三组单选 Chip。
/// （原 _FactualMemoryTabState._buildFilterChips）
class FactualFilterChips extends StatelessWidget {
  const FactualFilterChips({
    required this.colors,
    required this.t,
    required this.expanded,
    required this.typeFilter,
    required this.importanceFilter,
    required this.archiveFilter,
    required this.onTypeFilterChanged,
    required this.onImportanceFilterChanged,
    required this.onArchiveFilterChanged,
    super.key,
  });

  final LmPalette colors;
  final Translations t;

  /// 筛选栏展开/折叠（原 _filterExpanded）
  final bool expanded;

  /// 0=全部, 1=character, 2=location, 3=item, 4=lore, 5=organization, 6=misc
  final int typeFilter;

  /// 0=全部, 1=关键(4-5), 2=普通(1-3)
  final int importanceFilter;

  /// 0=全部, 1=活跃, 2=已归档（默认 1）
  final int archiveFilter;
  final ValueChanged<int> onTypeFilterChanged;
  final ValueChanged<int> onImportanceFilterChanged;
  final ValueChanged<int> onArchiveFilterChanged;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: LmMotion.base,
      curve: LmMotion.easeBoth,
      alignment: Alignment.topCenter,
      child: expanded
          ? Container(
              padding: const EdgeInsets.fromLTRB(
                LmSpacing.sLg,
                LmSpacing.sXs,
                LmSpacing.sLg,
                LmSpacing.sSm,
              ),
              color: colors.bg,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    // ── 实体类型筛选 ──
                    _buildChip(
                      colors,
                      t.intermediate.memoryBrowser.filterAll,
                      typeFilter == 0,
                      () => onTypeFilterChanged(0),
                    ),
                    const SizedBox(width: LmSpacing.s2xs),
                    _buildChip(
                      colors,
                      t.intermediate.chat.factsTypeCharacter,
                      typeFilter == 1,
                      () => onTypeFilterChanged(1),
                    ),
                    const SizedBox(width: LmSpacing.s2xs),
                    _buildChip(
                      colors,
                      t.intermediate.chat.factsTypeLocation,
                      typeFilter == 2,
                      () => onTypeFilterChanged(2),
                    ),
                    const SizedBox(width: LmSpacing.s2xs),
                    _buildChip(
                      colors,
                      t.intermediate.chat.factsTypeItem,
                      typeFilter == 3,
                      () => onTypeFilterChanged(3),
                    ),
                    const SizedBox(width: LmSpacing.s2xs),
                    _buildChip(
                      colors,
                      t.intermediate.chat.factsTypeLore,
                      typeFilter == 4,
                      () => onTypeFilterChanged(4),
                    ),
                    const SizedBox(width: LmSpacing.s2xs),
                    _buildChip(
                      colors,
                      t.intermediate.chat.factsTypeOrganization,
                      typeFilter == 5,
                      () => onTypeFilterChanged(5),
                    ),
                    const SizedBox(width: LmSpacing.s2xs),
                    _buildChip(
                      colors,
                      t.intermediate.chat.factsTypeMisc,
                      typeFilter == 6,
                      () => onTypeFilterChanged(6),
                    ),
                    _buildFilterDivider(colors),
                    // ── 重要性筛选 ──
                    _buildChip(
                      colors,
                      t.intermediate.memoryBrowser.filterAll,
                      importanceFilter == 0,
                      () => onImportanceFilterChanged(0),
                    ),
                    const SizedBox(width: LmSpacing.s2xs),
                    _buildChip(
                      colors,
                      t.intermediate.memoryBrowser.filterKey,
                      importanceFilter == 1,
                      () => onImportanceFilterChanged(1),
                    ),
                    const SizedBox(width: LmSpacing.s2xs),
                    _buildChip(
                      colors,
                      t.intermediate.memoryBrowser.filterNormal,
                      importanceFilter == 2,
                      () => onImportanceFilterChanged(2),
                    ),
                    _buildFilterDivider(colors),
                    // ── 归档状态筛选 ──
                    _buildChip(
                      colors,
                      t.intermediate.memoryBrowser.filterAll,
                      archiveFilter == 0,
                      () => onArchiveFilterChanged(0),
                    ),
                    const SizedBox(width: LmSpacing.s2xs),
                    _buildChip(
                      colors,
                      t.intermediate.memoryBrowser.filterActive,
                      archiveFilter == 1,
                      () => onArchiveFilterChanged(1),
                    ),
                    const SizedBox(width: LmSpacing.s2xs),
                    _buildChip(
                      colors,
                      t.intermediate.memoryBrowser.filterArchived,
                      archiveFilter == 2,
                      () => onArchiveFilterChanged(2),
                    ),
                  ],
                ),
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}

/// 单个筛选 Chip：选中用 accent 背景，未选中透明 + 边框。
/// （原 _FactualMemoryTabState._buildChip）
Widget _buildChip(
  LmPalette colors,
  String label,
  bool selected,
  VoidCallback onTap,
) {
  return GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(
        horizontal: LmSpacing.sSm,
        vertical: LmSpacing.s2xs,
      ),
      decoration: BoxDecoration(
        color: selected ? colors.accent : Colors.transparent,
        borderRadius: BorderRadius.circular(LmRadius.rFull),
        border: Border.all(color: selected ? colors.accent : colors.divider),
      ),
      child: Text(
        label,
        style: LmNarrativeTextStyles.caption.copyWith(
          color: selected ? colors.bg : colors.muted,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
  );
}

/// 筛选 Chip 组之间的竖线分隔符。
/// （原 _FactualMemoryTabState._buildFilterDivider）
Widget _buildFilterDivider(LmPalette colors) {
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: LmSpacing.sXs),
    child: Container(width: 1, height: 16, color: colors.divider),
  );
}
