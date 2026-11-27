import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_radius.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/memory_detail_dialog.dart'
    show MemoryDetailDialog;
import 'package:lmstory/features/intermediate/presentation/widgets/panels/retrieval_panel.dart'
    show RetrievalPanel;
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/services/fact_context_builder.dart';
import 'package:lmstory/i18n/factual_labels.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 事实层实体详情临时小窗（DOC-11 §6.1，2026-07-20 新增）。
///
/// 触发场景：用户在 [RetrievalPanel] 展开态点击事实类条目，
/// 弹出本窗展示实体完整属性、别名、登场轮次等元数据。
///
/// 临时性：通过 [showDialog] 实现，用户点击小窗外区域或右上角关闭按钮即可关闭，
/// 不修改任何状态。视觉规范与 [MemoryDetailDialog] 对齐（DOC-06B §6.3C）。
///
/// 展示内容：
/// - 标题行：实体主名 + 关闭按钮
/// - 元数据栏：类型标签 + 重要性星标 + 关键/命中/归档徽章
/// - 属性列表：每属性独立成块（attrKey label + value 两行），按 attrKey 顺序
/// - 元数据底栏：登场轮次 / 创建时间 / 修改轮次
class FactualDetailDialog {
  FactualDetailDialog._();

  /// 显示事实层实体详情
  static Future<void> show(
    BuildContext context, {
    required RetrievedFact fact,
  }) {
    return showLmDialog<void>(
      context: context,
      builder: (context) => _FactualDetailDialog(fact: fact),
    );
  }
}

class _FactualDetailDialog extends StatelessWidget {
  const _FactualDetailDialog({required this.fact});

  final RetrievedFact fact;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(
          maxWidth: LmLayout.dialogNarrowWidth,
        ),
        child: Padding(
          padding: const EdgeInsets.all(LmSpacing.sLg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(context, colors, t),
              const SizedBox(height: LmSpacing.sMd),
              _buildMetadataRow(colors, t),
              const SizedBox(height: LmSpacing.sMd),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: _buildAttributeFields(colors, t),
                  ),
                ),
              ),
              const SizedBox(height: LmSpacing.sMd),
              _buildFooter(colors, t),
            ],
          ),
        ),
      ),
    );
  }

  /// 标题行：实体主名 + 关闭按钮
  Widget _buildHeader(
    BuildContext context,
    LmPalette colors,
    Translations t,
  ) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Expanded(
          child: Text(
            fact.entity.primaryName,
            style: LmNarrativeTextStyles.title.copyWith(color: colors.ink),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close, size: 20),
          color: colors.muted,
          tooltip: t.intermediate.chat.factDetail.close,
          onPressed: () => Navigator.of(context).pop(),
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          padding: EdgeInsets.zero,
        ),
      ],
    );
  }

  /// 元数据栏：类型标签 + 重要性星标 + 徽章组
  Widget _buildMetadataRow(LmPalette colors, Translations t) {
    final entity = fact.entity;
    final typeLabel = _typeLabel(entity.type, t);

    return Wrap(
      spacing: LmSpacing.sXs,
      runSpacing: LmSpacing.sXs,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // 类型标签
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: LmSpacing.sSm,
            vertical: LmSpacing.s2xs,
          ),
          decoration: BoxDecoration(
            color: colors.surfaceVariant,
            borderRadius: BorderRadius.circular(LmRadius.rXs),
          ),
          child: Text(
            '${t.intermediate.chat.factDetail.type}：$typeLabel',
            style: LmNarrativeTextStyles.caption.copyWith(
              color: colors.muted,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        // 重要性星标（1-5 琥珀金）
        for (var i = 0; i < 5; i++)
          Icon(
            i < entity.importance ? Icons.star : Icons.star_border,
            size: 14,
            color: i < entity.importance ? colors.primary : colors.faint,
          ),
        // 关键实体徽章
        if (fact.isKeyEntity)
          _buildBadge(
            colors,
            text: t.intermediate.chat.factsKeyEntityBadge,
            color: colors.primary,
            bgColor: colors.primaryDim,
          ),
        // 关键词命中徽章
        if (fact.isKeywordMatched)
          _buildBadge(
            colors,
            text: t.intermediate.chat.factsMatchedBadge,
            color: colors.ink,
            bgColor: colors.surfaceVariant,
          ),
        // 归档徽章
        if (entity.isArchived)
          _buildBadge(
            colors,
            text: t.intermediate.chat.factsArchivedBadge,
            color: colors.error,
            bgColor: colors.surfaceVariant,
          ),
      ],
    );
  }

  Widget _buildBadge(
    LmPalette colors, {
    required String text,
    required Color color,
    required Color bgColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: LmSpacing.sSm,
        vertical: LmSpacing.s2xs,
      ),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(LmRadius.rXs),
      ),
      child: Text(
        text,
        style: LmNarrativeTextStyles.caption.copyWith(
          color: color,
          fontWeight: FontWeight.w500,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  /// 属性字段列表
  List<Widget> _buildAttributeFields(
    LmPalette colors,
    Translations t,
  ) {
    final attributes = fact.attributes;
    if (attributes.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: LmSpacing.sMd),
          child: Text(
            t.intermediate.chat.factDetail.noAttributes,
            style: LmNarrativeTextStyles.narrativeBody.copyWith(
              color: colors.faint,
              fontStyle: FontStyle.italic,
            ),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ];
    }

    // 标题
    final fields = <Widget>[
      Padding(
        padding: const EdgeInsets.only(bottom: LmSpacing.sSm),
        child: Text(
          t.intermediate.chat.factDetail.attributes,
          style: LmNarrativeTextStyles.label.copyWith(color: colors.muted),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    ];

    // 按属性重要性降序、attrKey 字典序排列
    final sorted = [...attributes]..sort((a, b) {
        if (a.importance != b.importance) {
          return b.importance.compareTo(a.importance);
        }
        return a.attrKey.compareTo(b.attrKey);
      });

    for (final attr in sorted) {
      fields.add(_buildAttributeItem(colors, attr));
    }

    return fields;
  }

  /// 单个属性条目
  Widget _buildAttributeItem(
    LmPalette colors,
    FactualAttribute attr,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: LmSpacing.sSm),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: LmSpacing.sSm,
          vertical: LmSpacing.sXs,
        ),
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(LmRadius.rXs),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Flexible(
                  child: Text(
                    // 与记忆库属性行同口径——本地化标签，
                    // 自定义键回退原文
                    factualAttributeLabel(t, fact.entity.type, attr.attrKey) ??
                        attr.attrKey,
                    style: LmNarrativeTextStyles.caption.copyWith(
                      color: colors.muted,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: LmSpacing.sXs),
                // 关键属性星标
                if (attr.isKeyAttribute) const Icon(Icons.star, size: 10),
              ],
            ),
            const SizedBox(height: LmSpacing.s2xs),
            Text(
              _formatAttributeValue(attr, t),
              style: LmNarrativeTextStyles.narrativeBody.copyWith(
                color: colors.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 格式化属性值（list 类型用顿号分隔，dict 直接展示原始 JSON）
  String _formatAttributeValue(FactualAttribute attr, Translations t) {
    switch (attr.valueType) {
      case AttributeValueType.list:
        final list = attr.listValue;
        if (list.isEmpty) return t.intermediate.memoryBrowser.emptyListValue;
        return list.join('、');
      case AttributeValueType.single:
      case AttributeValueType.dict:
        return attr.value;
    }
  }

  /// 元数据底栏：登场轮次 + 修改轮次 + 创建时间
  Widget _buildFooter(LmPalette colors, Translations t) {
    final entity = fact.entity;
    final parts = <String>[
      '${t.intermediate.chat.factDetail.createdTurn}：${entity.createdTurn}',
      if (entity.updatedTurn != null)
        '${t.intermediate.chat.factDetail.updatedTurn}：${entity.updatedTurn}',
      '${t.intermediate.chat.factDetail.createdAt}：${_formatDateTime(entity.createdAt)}',
      if (entity.updatedAt != null)
        '${t.intermediate.chat.factDetail.updatedAt}：${_formatDateTime(entity.updatedAt!)}',
    ];

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: LmSpacing.sSm,
        vertical: LmSpacing.sXs,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(LmRadius.rXs),
      ),
      child: Text(
        parts.join(' · '),
        style: LmNarrativeTextStyles.caption.copyWith(color: colors.faint),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.year.toString().padLeft(4, '0')}-'
        '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }

  /// 类型对应的中文标签（与 i18n factDetail.type* 一致）
  String _typeLabel(FactualEntityType type, Translations t) {
    switch (type) {
      case FactualEntityType.character:
        return t.intermediate.chat.factDetail.typeCharacter;
      case FactualEntityType.location:
        return t.intermediate.chat.factDetail.typeLocation;
      case FactualEntityType.item:
        return t.intermediate.chat.factDetail.typeItem;
      case FactualEntityType.lore:
        return t.intermediate.chat.factDetail.typeLore;
      case FactualEntityType.organization:
        return t.intermediate.chat.factDetail.typeOrganization;
      case FactualEntityType.misc:
        return t.intermediate.chat.factDetail.typeMisc;
    }
  }
}
