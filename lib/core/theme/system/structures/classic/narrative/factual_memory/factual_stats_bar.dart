import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/i18n/strings.g.dart';

// 从 factual_memory_tab.dart 拆出（原 _buildStatsBar /
// _showImportanceGuideDialog / _buildImportanceTier，逐字符搬运）。

/// 统计概览栏：展示实体总数与各类型数量，筛选时切换为"显示 X / N"。
/// （原 _FactualMemoryTabState._buildStatsBar；各计数逻辑原样搬运）
class FactualStatsBar extends StatelessWidget {
  const FactualStatsBar({
    required this.colors,
    required this.t,
    required this.allEntities,
    required this.filteredCount,
    required this.hasActiveFilter,
    super.key,
  });

  final LmPalette colors;
  final Translations t;
  final List<FactualEntity> allEntities;

  /// 当前筛选后实体数（原 _filteredEntities.length）
  final int filteredCount;

  /// 当前是否有任意筛选条件生效（原 _hasActiveFilter）
  final bool hasActiveFilter;

  @override
  Widget build(BuildContext context) {
    final totalCount = allEntities.length;
    final characterCount =
        allEntities.where((e) => e.type == FactualEntityType.character).length;
    final locationCount =
        allEntities.where((e) => e.type == FactualEntityType.location).length;
    final itemCount =
        allEntities.where((e) => e.type == FactualEntityType.item).length;
    final loreCount =
        allEntities.where((e) => e.type == FactualEntityType.lore).length;
    final organizationCount = allEntities
        .where((e) => e.type == FactualEntityType.organization)
        .length;

    final text = hasActiveFilter
        ? t.intermediate.memoryBrowser
            .statsEntitiesFiltered(shown: filteredCount, total: totalCount)
        : t.intermediate.memoryBrowser.statsEntitiesSummary(
            n: totalCount,
            character: characterCount,
            location: locationCount,
            item: itemCount,
            lore: loreCount,
            organization: organizationCount,
          );

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LmSpacing.sLg,
        LmSpacing.sSm,
        LmSpacing.sLg,
        0,
      ),
      child: Row(
        children: [
          Flexible(
            child: Text(
              text,
              style:
                  LmNarrativeTextStyles.caption.copyWith(color: colors.muted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: LmSpacing.sXs),
          //  语义缺口：裸 InkWell+Icon 无角色也无名字 → 补 button 角色
          // + 复用 importanceGuideTitle（该图标正是打开此说明弹层）。
          Semantics(
            button: true,
            label: t.intermediate.memoryBrowser.importanceGuideTitle,
            child: InkWell(
              onTap: () => showFactualImportanceGuideDialog(context, colors, t),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(
                  Icons.info_outline,
                  size: 14,
                  color: colors.muted,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 重要性评分引导对话框
///
/// 向用户解释每个评分档位的含义和对检索注入的影响。
/// （原 _FactualMemoryTabState._showImportanceGuideDialog）
void showFactualImportanceGuideDialog(
  BuildContext context,
  LmPalette colors,
  Translations t,
) {
  showLmDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(
        t.intermediate.memoryBrowser.importanceGuideTitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              t.intermediate.memoryBrowser.importanceGuideDesc,
              style:
                  LmNarrativeTextStyles.caption.copyWith(color: colors.muted),
            ),
            const SizedBox(height: LmSpacing.sMd),
            _buildImportanceTier(
              colors,
              '★★★★★ 5',
              t.intermediate.memoryBrowser.importanceTier5,
              t.intermediate.memoryBrowser.importanceTier5Behavior,
              isKey: true,
            ),
            _buildImportanceTier(
              colors,
              '★★★★ 4',
              t.intermediate.memoryBrowser.importanceTier4,
              t.intermediate.memoryBrowser.importanceTier4Behavior,
            ),
            _buildImportanceTier(
              colors,
              '★★★ 3',
              t.intermediate.memoryBrowser.importanceTier3,
              t.intermediate.memoryBrowser.importanceTier3Behavior,
            ),
            _buildImportanceTier(
              colors,
              '★★ 2',
              t.intermediate.memoryBrowser.importanceTier2,
              t.intermediate.memoryBrowser.importanceTier2Behavior,
            ),
            _buildImportanceTier(
              colors,
              '★ 1',
              t.intermediate.memoryBrowser.importanceTier1,
              t.intermediate.memoryBrowser.importanceTier1Behavior,
            ),
            const SizedBox(height: LmSpacing.sSm),
            Text(
              t.intermediate.memoryBrowser.importanceGuideHint,
              style:
                  LmNarrativeTextStyles.caption.copyWith(color: colors.muted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(
            t.common.confirm,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );
}

/// 构建单条评分档位说明（原 _FactualMemoryTabState._buildImportanceTier）
Widget _buildImportanceTier(
  LmPalette colors,
  String score,
  String label,
  String behavior, {
  bool isKey = false,
}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: LmSpacing.sSm),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            score,
            style: LmNarrativeTextStyles.label.copyWith(
              color: isKey ? colors.warning : colors.muted,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: LmNarrativeTextStyles.bodyUi.copyWith(color: colors.ink),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                behavior,
                style:
                    LmNarrativeTextStyles.caption.copyWith(color: colors.muted),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
