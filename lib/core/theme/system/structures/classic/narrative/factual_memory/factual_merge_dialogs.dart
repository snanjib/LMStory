import 'package:flutter/material.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';
import 'package:lmstory/features/memory/domain/services/facts_merge_service.dart';
import 'package:lmstory/i18n/strings.g.dart';

// 从 factual_memory_tab.dart 拆出的手动归并弹层（原 _onFindSimilar 内的
// showModalBottomSheet 与 _showMergePreviewDialog，逐字符搬运；
// 两弹层均不依赖 Tab State，仅吃 context + 数据）。

/// 找相似聚类选择弹层：逐簇展示可预选归并的相似实体组，点选返回该簇
/// 实体 id 列表（取消返回 null）。
/// （原 _FactualMemoryTabState._onFindSimilar 内的 bottom sheet）
Future<List<String>?> showFactualSimilarClustersSheet({
  required BuildContext context,
  required List<List<FactualEntity>> clusters,
}) {
  final t = Translations.of(context);
  return showLmSheet<List<String>>(
    context: context,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.all(LmSpacing.sMd),
            child: Text(
              t.intermediate.memoryBrowser.findSimilarTitle,
              style: LmNarrativeTextStyles.title,
            ),
          ),
          for (final cluster in clusters)
            ListTile(
              leading: const Icon(Icons.account_tree_outlined, size: 18),
              title: Text(
                cluster.map((e) => e.primaryName).join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                t.intermediate.memoryBrowser.findSimilarGroupCount(
                  count: cluster.length,
                ),
              ),
              onTap: () => Navigator.pop(
                ctx,
                cluster.map((e) => e.entityId).toList(),
              ),
            ),
        ],
      ),
    ),
  );
}

/// 归并方案预览弹窗：展示规范名/别名/重要度/属性/备注/被吸收条目，
/// 确认返回 true。
/// （原 _FactualMemoryTabState._showMergePreviewDialog）
Future<bool?> showFactualMergePreviewDialog({
  required BuildContext context,
  required MergePlan plan,
  required List<FactualEntity> selected,
}) {
  final t = Translations.of(context);
  final colors = context.lm.palette;
  final absorbed =
      selected.where((e) => e.entityId != plan.targetEntityId).toList();
  // 别名余量预演——与 _applyMergePlan 落库循环同口径
  //（canonical 剔除/长度过滤/上限封顶先到先得），超限部分灰字披露，
  // 不再「静默丢弃」。
  final target = selected.firstWhere((e) => e.entityId == plan.targetEntityId);
  final targetIsReadonly = target.source.isReadOnly;
  final canonicalName =
      targetIsReadonly ? target.primaryName : plan.primaryName;
  final projectedAliases = <String>{...target.aliases}..remove(canonicalName);
  var addedFromPlan = 0;
  var droppedAliases = 0;
  for (final alias in plan.aliases) {
    if (projectedAliases.length >= FactApplier.kMaxAliasesPerEntity) {
      droppedAliases = plan.aliases.length - addedFromPlan;
      break;
    }
    if (alias.length > const FactualConfig().maxAttrValueLength) continue;
    projectedAliases.add(alias);
    addedFromPlan++;
  }
  return showLmDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(t.intermediate.memoryBrowser.mergePreviewTitle),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.intermediate.memoryBrowser.mergePreviewCanonical(
                  name: plan.primaryName,
                ),
                style: LmNarrativeTextStyles.title,
              ),
              if (plan.aliases.isNotEmpty)
                Text(
                  t.intermediate.memoryBrowser.mergePreviewAliases(
                    aliases: plan.aliases.join('、'),
                  ),
                ),
              if (droppedAliases > 0)
                Text(
                  t.intermediate.memoryBrowser.mergeAliasCapWarning(
                    count: droppedAliases,
                    cap: FactApplier.kMaxAliasesPerEntity,
                  ),
                  style: LmNarrativeTextStyles.caption.copyWith(
                    color: colors.muted,
                  ),
                ),
              Text(
                t.intermediate.memoryBrowser.mergePreviewImportance(
                  n: plan.importance,
                ),
              ),
              const SizedBox(height: LmSpacing.sSm),
              for (final attr in plan.attributes)
                Padding(
                  padding: const EdgeInsets.only(bottom: LmSpacing.sXs),
                  child: Text('${attr.attrKey}: ${attr.value}'),
                ),
              if (plan.notes != null) ...[
                const SizedBox(height: LmSpacing.sSm),
                Text(
                  t.intermediate.memoryBrowser.mergePreviewNotes(
                    notes: plan.notes!,
                  ),
                  style: LmNarrativeTextStyles.caption.copyWith(
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
              const SizedBox(height: LmSpacing.sSm),
              Text(
                t.intermediate.memoryBrowser.mergePreviewAbsorbed(
                  names: absorbed.map((e) => e.primaryName).join('、'),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(t.intermediate.memoryBrowser.mergeCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(t.intermediate.memoryBrowser.mergeApply),
        ),
      ],
    ),
  );
}
