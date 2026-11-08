import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

// 从 factual_memory_tab.dart 拆出（原 _buildSearchBar，逐字符搬运，
// 状态与回调由 Tab State 构造注入；搜索 controller 仍归 State 持有/释放）。

/// 搜索工具栏：搜索输入 + 排序菜单 + 筛选展开/折叠 + 找相似 +
/// 多选切换 + 新增实体（原 _FactualMemoryTabState._buildSearchBar）。
class FactualSearchHeader extends StatelessWidget {
  const FactualSearchHeader({
    required this.colors,
    required this.t,
    required this.searchController,
    required this.searchQuery,
    required this.sortBy,
    required this.filterExpanded,
    required this.hasActiveFilter,
    required this.multiSelectMode,
    required this.onSortChanged,
    required this.onToggleFilterExpanded,
    required this.onFindSimilar,
    required this.onToggleMultiSelect,
    required this.onAddEntity,
    this.readOnly = false,
    super.key,
  });

  final LmPalette colors;
  final Translations t;
  final TextEditingController searchController;
  final String searchQuery;

  /// 0=重要性, 1=名称, 2=创建时间
  final int sortBy;
  final bool filterExpanded;
  final bool hasActiveFilter;
  final bool multiSelectMode;
  final ValueChanged<int> onSortChanged;
  final VoidCallback onToggleFilterExpanded;
  final VoidCallback onFindSimilar;
  final VoidCallback onToggleMultiSelect;
  final VoidCallback onAddEntity;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        LmSpacing.sLg,
        LmSpacing.sSm,
        LmSpacing.sLg,
        LmSpacing.sSm,
      ),
      color: colors.bg,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: searchController,
              style: LmNarrativeTextStyles.input.copyWith(color: colors.ink),
              decoration: InputDecoration(
                hintText: t.intermediate.memoryBrowser.searchHint,
                hintStyle:
                    LmNarrativeTextStyles.input.copyWith(color: colors.muted),
                prefixIcon: Icon(Icons.search, color: colors.muted, size: 20),
                suffixIcon: searchQuery.isNotEmpty
                    ? IconButton(
                        icon: Icon(Icons.clear, color: colors.muted, size: 18),
                        tooltip: t.common.clear,
                        onPressed: searchController.clear,
                      )
                    : null,
                filled: true,
                fillColor: colors.surfaceVariant,
                border: OutlineInputBorder(
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: LmSpacing.sMd,
                  vertical: LmSpacing.sSm,
                ),
              ),
            ),
          ),
          const SizedBox(width: LmSpacing.sSm),
          // 排序按钮（PopupMenu）
          PopupMenuButton<int>(
            icon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.sort, color: colors.muted, size: 20),
                Icon(
                  sortBy == 1 ? Icons.arrow_upward : Icons.arrow_downward,
                  color: colors.muted,
                  size: 12,
                ),
              ],
            ),
            color: colors.surfaceElevated,
            tooltip: t.intermediate.memoryBrowser.sortBy,
            onSelected: onSortChanged,
            itemBuilder: (ctx) => [
              PopupMenuItem(
                value: 0,
                child: Row(
                  children: [
                    Icon(
                      sortBy == 0 ? Icons.check : null,
                      size: 16,
                      color: colors.primary,
                    ),
                    const SizedBox(width: LmSpacing.sSm),
                    Flexible(
                      child: Text(
                        t.intermediate.memoryBrowser.sortByImportance,
                        style: LmNarrativeTextStyles.bodyUi
                            .copyWith(color: colors.ink),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 1,
                child: Row(
                  children: [
                    Icon(
                      sortBy == 1 ? Icons.check : null,
                      size: 16,
                      color: colors.primary,
                    ),
                    const SizedBox(width: LmSpacing.sSm),
                    Flexible(
                      child: Text(
                        t.intermediate.memoryBrowser.sortByName,
                        style: LmNarrativeTextStyles.bodyUi
                            .copyWith(color: colors.ink),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 2,
                child: Row(
                  children: [
                    Icon(
                      sortBy == 2 ? Icons.check : null,
                      size: 16,
                      color: colors.primary,
                    ),
                    const SizedBox(width: LmSpacing.sSm),
                    Flexible(
                      child: Text(
                        t.intermediate.memoryBrowser.sortByCreatedAt,
                        style: LmNarrativeTextStyles.bodyUi
                            .copyWith(color: colors.ink),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // 过滤器展开/折叠按钮
          IconButton(
            icon: Icon(
              filterExpanded ? Icons.filter_list : Icons.filter_list_outlined,
              color: hasActiveFilter ? colors.primary : colors.muted,
              size: 20,
            ),
            tooltip: t.intermediate.memoryBrowser.filterToggle,
            onPressed: onToggleFilterExpanded,
          ),
          if (!readOnly) ...[
            // 找相似——包含关系聚类分组，一键预选进多选归并
            IconButton(
              icon: const Icon(Icons.hub_outlined),
              color: colors.muted,
              tooltip: t.intermediate.memoryBrowser.findSimilar,
              onPressed: onFindSimilar,
            ),
            IconButton(
              icon: Icon(
                multiSelectMode ? Icons.done : Icons.checklist,
                color: multiSelectMode ? colors.primary : colors.muted,
                size: 20,
              ),
              tooltip: multiSelectMode
                  ? t.intermediate.memoryBrowser.multiSelectExit
                  : t.intermediate.memoryBrowser.multiSelectMode,
              onPressed: onToggleMultiSelect,
            ),
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              color: colors.primary,
              tooltip: t.intermediate.memoryBrowser.addEntityTitle,
              onPressed: onAddEntity,
            ),
          ],
        ],
      ),
    );
  }
}
