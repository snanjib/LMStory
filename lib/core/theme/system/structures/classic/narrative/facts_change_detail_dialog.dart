import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_radius.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/factual_detail_dialog.dart'
    show FactualDetailDialog;
import 'package:lmstory/core/theme/system/structures/classic/narrative/memory_detail_dialog.dart'
    show MemoryDetailDialog;
import 'package:lmstory/features/intermediate/presentation/widgets/panels/facts_change_panel.dart'
    show FactsChangePanel;
import 'package:lmstory/features/memory/domain/entities/facts_change_record.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 事实层单条变更详情弹窗（事实层变更小窗配套，DOC-11 §4）。
///
/// 由 [FactsChangePanel] 在用户点击某条变更记录时弹出，展示该条变更的完整
/// 信息：动作徽章 + 实体（名 + 类型）+ 属性 + 变更前/变更后 + 原因 + 置信度。
///
/// 与 [MemoryDetailDialog]（5W1E 事件叙事）字段语义不同，不复用其抽象源，
/// 独立实现。视觉风格参照 [FactualDetailDialog] 的徽章 + label/value 两行块。
class FactsChangeDetailDialog {
  const FactsChangeDetailDialog._();

  /// 弹出单条事实变更详情。
  static Future<void> show(
    BuildContext context, {
    required FactsChangeRecord record,
  }) {
    return showLmDialog<void>(
      context: context,
      builder: (_) => _FactsChangeDetailDialog(record: record),
    );
  }
}

class _FactsChangeDetailDialog extends StatelessWidget {
  const _FactsChangeDetailDialog({required this.record});

  final FactsChangeRecord record;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    return Dialog(
      backgroundColor: colors.surfaceElevated,
      insetPadding: const EdgeInsets.symmetric(
        horizontal: LmSpacing.sLg,
        vertical: LmSpacing.sXl,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          LmSpacing.sMd,
          LmSpacing.sMd,
          LmSpacing.sMd,
          LmSpacing.sSm,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(colors, t, context),
            const SizedBox(height: LmSpacing.sSm),
            // 实体（名 + 类型标签）
            if (_entityTitle(colors, t).isNotEmpty)
              _addField(
                colors,
                label: t.intermediate.chat.factsChangeEntityLabel,
                value: _entityTitle(colors, t),
              ),
            // 属性（如有）
            if (_attrLabel != null)
              _addField(
                colors,
                label: t.intermediate.chat.factsChangeAttrLabel,
                value: _attrLabel!,
              ),
            // 变更前（如有：update/append/remove 的 old）
            if (record.oldValue != null)
              _addField(
                colors,
                label: t.intermediate.chat.factsChangeOldValue,
                value: record.oldValue!,
              ),
            // 变更后（如有：create/update/append/remove/addAlias 的 new）
            if (record.newValue != null)
              _addField(
                colors,
                label: t.intermediate.chat.factsChangeNewValue,
                value: record.newValue!,
              ),
            // 原因（如有）
            if (record.reason != null && record.reason!.isNotEmpty)
              _addField(
                colors,
                label: t.intermediate.chat.factsChangeReason,
                value: record.reason!,
              ),
            // 置信度
            _addField(
              colors,
              label: t.intermediate.chat.factsChangeConfidence,
              value: '${record.confidence} / 5',
            ),
          ],
        ),
      ),
    );
  }

  /// 顶部：动作徽章 + 关闭按钮
  Widget _buildHeader(
    LmPalette colors,
    Translations t,
    BuildContext context,
  ) {
    return Row(
      children: [
        _buildActionBadge(colors, t),
        const Spacer(),
        IconButton(
          //  语义缺口：复用 common.close（不新增 i18n key）。
          tooltip: t.common.close,
          icon: Icon(Icons.close, size: 18, color: colors.muted),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
    );
  }

  /// 动作徽章（新增/更新/追加/移除/别名/归档）
  Widget _buildActionBadge(LmPalette colors, Translations t) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: LmSpacing.sSm,
        vertical: LmSpacing.s2xs,
      ),
      decoration: BoxDecoration(
        color: colors.primaryDim,
        borderRadius: BorderRadius.circular(LmRadius.rXs),
      ),
      child: Text(
        _actionLabel(t),
        style: LmNarrativeTextStyles.caption.copyWith(
          color: colors.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// 实体标题：主名（或 entityId）+ 类型标签
  String _entityTitle(LmPalette colors, Translations t) {
    final name = record.primaryName ?? record.entityId ?? '';
    final typeLabel = _typeLabel(t);
    if (name.isEmpty) return typeLabel;
    if (typeLabel.isEmpty) return name;
    return '$name · $typeLabel';
  }

  /// 动作中文标签
  String _actionLabel(Translations t) {
    final chat = t.intermediate.chat;
    switch (record.action) {
      case FactAction.createEntity:
        return chat.factsActionCreateEntity;
      case FactAction.updateAttr:
        return chat.factsActionUpdateAttr;
      case FactAction.appendList:
        return chat.factsActionAppendList;
      case FactAction.removeFromList:
        return chat.factsActionRemoveFromList;
      case FactAction.addAlias:
        return chat.factsActionAddAlias;
      case FactAction.archiveEntity:
        return chat.factsActionArchiveEntity;
    }
  }

  /// 类型中文标签（来自 entityType 字符串）
  String _typeLabel(Translations t) {
    if (record.entityType == null) return '';
    final type = _parseType(record.entityType!);
    if (type == null) return '';
    final chat = t.intermediate.chat;
    switch (type) {
      case FactualEntityType.character:
        return chat.factsTypeCharacter;
      case FactualEntityType.location:
        return chat.factsTypeLocation;
      case FactualEntityType.item:
        return chat.factsTypeItem;
      case FactualEntityType.lore:
        return chat.factsTypeLore;
      case FactualEntityType.organization:
        return chat.factsTypeOrganization;
      case FactualEntityType.misc:
        return chat.factsTypeMisc;
    }
  }

  /// 属性中文标签（经 AttributeSchema 标准化；自定义属性回退原 attrKey）
  String? get _attrLabel {
    final attrKey = record.attrKey;
    if (attrKey == null) return null;
    final type = _parseType(record.entityType ?? '');
    if (type == null) return attrKey;
    return AttributeSchema.labelFor(type, attrKey) ?? attrKey;
  }

  FactualEntityType? _parseType(String value) {
    try {
      return FactualEntityType.fromString(value);
    } catch (_) {
      return null;
    }
  }

  /// label + value 两行字段块
  Widget _addField(
    LmPalette colors, {
    required String label,
    required String value,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: LmSpacing.sSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: LmNarrativeTextStyles.caption.copyWith(color: colors.muted),
          ),
          const SizedBox(height: LmSpacing.s2xs),
          Text(
            value,
            style: LmNarrativeTextStyles.narrativeBody.copyWith(
              color: colors.ink,
            ),
          ),
        ],
      ),
    );
  }
}
