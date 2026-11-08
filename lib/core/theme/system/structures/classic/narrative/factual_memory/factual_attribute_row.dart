import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';
import 'package:lmstory/i18n/strings.g.dart';

// 从 factual_memory_tab.dart 拆出（原 _AttributeRow，逐字符搬运，
// 仅改公开以便实体卡子库引用）。

/// 单行属性展示。
///
/// （只读语义 2.0）：attrKey 旁行级徽标——基线行（source 只读）标
/// 「基线」，同键并存的 auto 行标「演变」（[baselineKeys] 为本实体全部
/// 基线键集合，auto 行的键在其中 ⇔ 存在同键基线行）；纯 auto 实体无徽标。
class FactualAttributeRow extends StatelessWidget {
  const FactualAttributeRow({
    required this.attribute,
    required this.entityType,
    required this.baselineKeys,
    required this.colors,
    required this.t,
    required this.onEdit,
    required this.onDelete,
    this.readOnly = false,
    super.key,
  });

  final FactualAttribute attribute;

  /// 属性行显示本地化标签——
  /// 新增对话框/编辑对话框/事实变更明细都已本地化，行内裸显英文键
  /// 形成同屏双口径。自定义键回退原文（存储键保持英文不动）。
  final FactualEntityType entityType;

  /// 本实体基线行（source != auto）的 attrKey 集合
  final Set<String> baselineKeys;
  final LmPalette colors;
  final Translations t;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    //  语义缺口：属性行的编辑/删除是纯图标按钮，读屏器只能播报
    // 「button N」——复用 common.edit / common.delete（不新增 i18n key）。
    final t = Translations.of(context);
    final isBaseline = attribute.source.isReadOnly;
    final isEvolved = !isBaseline && baselineKeys.contains(attribute.attrKey);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (attribute.isKeyAttribute)
            Padding(
              padding: const EdgeInsets.only(right: 2, top: 2),
              child: Icon(Icons.star, color: colors.primary, size: 10),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        AttributeSchema.labelFor(
                              entityType,
                              attribute.attrKey,
                            ) ??
                            attribute.attrKey,
                        style: LmNarrativeTextStyles.caption.copyWith(
                          color: colors.muted,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isBaseline) ...[
                      const SizedBox(width: LmSpacing.s2xs),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: colors.surfaceVariant,
                          borderRadius: BorderRadius.circular(
                            context.lmUi.radius(LmCorner.xs),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.lock_outline,
                              size: 10,
                              color: colors.muted,
                            ),
                            const SizedBox(width: 2),
                            Text(
                              t.intermediate.memoryBrowser.baselineBadge,
                              style: LmNarrativeTextStyles.caption
                                  .copyWith(color: colors.muted),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (isEvolved) ...[
                      const SizedBox(width: LmSpacing.s2xs),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          // 仿常驻徽标样式（primary 14% 透明底）
                          color: colors.primary.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(
                            context.lmUi.radius(LmCorner.xs),
                          ),
                        ),
                        child: Text(
                          t.intermediate.memoryBrowser.evolvedBadge,
                          style: LmNarrativeTextStyles.caption
                              .copyWith(color: colors.primary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _formatValue(attribute),
                  style:
                      LmNarrativeTextStyles.bodyUi.copyWith(color: colors.ink),
                ),
              ],
            ),
          ),
          if (!readOnly) ...[
            IconButton(
              tooltip: t.common.edit,
              icon: const Icon(Icons.edit_outlined, size: 14),
              color: colors.muted,
              onPressed: onEdit,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              tooltip: t.common.delete,
              icon: const Icon(Icons.delete_outline, size: 14),
              color: colors.error,
              onPressed: onDelete,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ],
      ),
    );
  }

  String _formatValue(FactualAttribute attr) {
    switch (attr.valueType) {
      case AttributeValueType.single:
        return attr.value;
      case AttributeValueType.list:
        final list = attr.listValue;
        return list.isEmpty ? '[]' : list.join(', ');
      case AttributeValueType.dict:
        // 尝试格式化为 k: v 列表
        try {
          final decoded = jsonDecode(attr.value);
          if (decoded is Map) {
            return decoded.entries
                .map((e) => '${e.key}: ${e.value}')
                .join(', ');
          }
        } catch (_) {
          // 解析失败显示原始值
        }
        return attr.value;
    }
  }
}
