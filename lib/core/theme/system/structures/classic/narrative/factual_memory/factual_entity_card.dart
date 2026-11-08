import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/factual_memory/factual_attribute_row.dart';
import 'package:lmstory/core/tutorial/spotlight_target.dart';
import 'package:lmstory/features/demo/domain/demo_scene.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/features/memory/domain/entities/force_inject_target.dart';
import 'package:lmstory/i18n/strings.g.dart';

// 从 factual_memory_tab.dart 拆出（原 _EntityTypeGroup / _EntityCard，
// 逐字符搬运，仅改公开 + _AttributeRow → FactualAttributeRow 引用）。

/// 实体类型分组（带类型标题 + 实体卡片列表）。
class FactualEntityTypeGroup extends StatelessWidget {
  const FactualEntityTypeGroup({
    required this.type,
    required this.entities,
    required this.attributesByEntity,
    required this.colors,
    required this.t,
    required this.onEditEntity,
    required this.onDeleteEntity,
    required this.onRestoreEntity,
    required this.onArchiveEntity,
    required this.onToggleEntityInjection,
    required this.onEditAttribute,
    required this.onDeleteAttribute,
    this.selectedIds,
    this.onToggleSelect,
    this.readOnly = false,
    this.isFirstGroup = false,
    super.key,
  });

  final FactualEntityType type;
  final List<FactualEntity> entities;
  final Map<String, List<FactualAttribute>> attributesByEntity;
  final LmPalette colors;
  final Translations t;
  final void Function(FactualEntity) onEditEntity;
  final void Function(FactualEntity) onDeleteEntity;
  final void Function(FactualEntity) onRestoreEntity;

  /// 手动归档活跃实体
  final void Function(FactualEntity) onArchiveEntity;

  /// 批 J-b：词条级注入停用/恢复
  final void Function(FactualEntity) onToggleEntityInjection;
  final void Function(FactualEntity, FactualAttribute?) onEditAttribute;
  final void Function(FactualAttribute) onDeleteAttribute;
  final Set<String>? selectedIds;
  final void Function(FactualEntity)? onToggleSelect;
  final bool readOnly;
  final bool isFirstGroup;

  String get _typeLabel {
    switch (type) {
      case FactualEntityType.character:
        return t.intermediate.chat.factsTypeCharacter;
      case FactualEntityType.location:
        return t.intermediate.chat.factsTypeLocation;
      case FactualEntityType.item:
        return t.intermediate.chat.factsTypeItem;
      case FactualEntityType.lore:
        return t.intermediate.chat.factsTypeLore;
      case FactualEntityType.organization:
        return t.intermediate.chat.factsTypeOrganization;
      case FactualEntityType.misc:
        return t.intermediate.chat.factsTypeMisc;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: LmSpacing.sSm),
          child: Text(
            '$_typeLabel（${entities.length}）',
            style: LmNarrativeTextStyles.narrativeDisplay.copyWith(
              fontSize: 20,
              color: colors.ink,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        ...entities.asMap().entries.map((entry) {
          final index = entry.key;
          final entity = entry.value;
          final card = FactualEntityCard(
            entity: entity,
            attributes: attributesByEntity[entity.entityId] ?? const [],
            colors: colors,
            t: t,
            readOnly: readOnly,
            onEdit: () => onEditEntity(entity),
            onDelete: () => onDeleteEntity(entity),
            onRestore: () => onRestoreEntity(entity),
            onArchive: () => onArchiveEntity(entity),
            onToggleInjection: entity.isArchived
                ? null
                : () => onToggleEntityInjection(entity),
            onAddAttribute: () => onEditAttribute(entity, null),
            onEditAttribute: (attr) => onEditAttribute(entity, attr),
            onDeleteAttribute: onDeleteAttribute,
            selected: selectedIds?.contains(entity.entityId) ?? false,
            onToggleSelect:
                onToggleSelect == null ? null : () => onToggleSelect!(entity),
          );
          if (isFirstGroup && index == 0 && readOnly) {
            return SpotlightTarget(
              id: DemoTargetIds.memoryFactualItem,
              child: card,
            );
          }
          return card;
        }),
      ],
    );
  }
}

/// 单个实体卡片（可展开看属性）。
class FactualEntityCard extends StatefulWidget {
  const FactualEntityCard({
    required this.entity,
    required this.attributes,
    required this.colors,
    required this.t,
    required this.onEdit,
    required this.onDelete,
    required this.onRestore,
    required this.onAddAttribute,
    required this.onEditAttribute,
    required this.onDeleteAttribute,
    this.onArchive,
    this.selected = false,
    this.onToggleSelect,
    this.onToggleInjection,
    this.readOnly = false,
    super.key,
  });

  final FactualEntity entity;
  final List<FactualAttribute> attributes;
  final LmPalette colors;
  final Translations t;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onRestore;

  /// 手动归档（null=不显示菜单项）
  final VoidCallback? onArchive;

  /// 批 J-b：词条级注入停用/恢复（null = 归档实体无此操作）
  final VoidCallback? onToggleInjection;
  final VoidCallback onAddAttribute;
  final void Function(FactualAttribute) onEditAttribute;
  final void Function(FactualAttribute) onDeleteAttribute;
  final bool selected;
  final VoidCallback? onToggleSelect;
  final bool readOnly;

  @override
  State<FactualEntityCard> createState() => _FactualEntityCardState();
}

class _FactualEntityCardState extends State<FactualEntityCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: LmSpacing.sSm),
      decoration: BoxDecoration(
        color: widget.colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
      ),
      child: Column(
        children: [
          _buildHeader(),
          if (_expanded) _buildAttributes(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final e = widget.entity;
    return InkWell(
      onTap:
          widget.onToggleSelect ?? () => setState(() => _expanded = !_expanded),
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
      child: Padding(
        padding: const EdgeInsets.all(LmSpacing.sMd),
        child: Row(
          children: [
            Icon(
              widget.onToggleSelect != null
                  ? (widget.selected
                      ? Icons.check_box
                      : Icons.check_box_outline_blank)
                  : (_expanded ? Icons.expand_more : Icons.chevron_right),
              color: widget.onToggleSelect != null
                  ? widget.colors.primary
                  : widget.colors.muted,
              size: 20,
            ),
            const SizedBox(width: LmSpacing.sXs),
            // 关键实体星标
            if (e.isKeyEntity)
              Padding(
                padding: const EdgeInsets.only(right: LmSpacing.s2xs),
                child: Icon(Icons.star, color: widget.colors.primary, size: 14),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    e.primaryName,
                    style: LmNarrativeTextStyles.narrativeDisplay.copyWith(
                      fontSize: 20,
                      color: widget.colors.ink,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (e.aliases.isNotEmpty)
                    Text(
                      e.aliases.join(', '),
                      style: LmNarrativeTextStyles.caption
                          .copyWith(color: widget.colors.muted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            // 批 J-b：种子来源/常驻/停用徽标——
            // 「种子 vs 生长」差异化卖点的可见化（与 archived 徽标同词汇）
            if (e.source == FactualSource.card ||
                e.source == FactualSource.worldbook)
              Container(
                margin: const EdgeInsets.only(right: LmSpacing.s2xs),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: widget.colors.surfaceVariant,
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      e.source == FactualSource.card
                          ? Icons.person_outline
                          : Icons.auto_stories_outlined,
                      size: 10,
                      color: widget.colors.muted,
                    ),
                    const SizedBox(width: 2),
                    Text(
                      e.source == FactualSource.card
                          ? widget.t.intermediate.memoryBrowser.sourceBadgeCard
                          : widget.t.intermediate.memoryBrowser.sourceBadgeBook,
                      style: LmNarrativeTextStyles.caption
                          .copyWith(color: widget.colors.muted),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            if (e.forceInject != ForceInjectTarget.none)
              Container(
                margin: const EdgeInsets.only(right: LmSpacing.s2xs),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: widget.colors.primary.withValues(alpha: 0.14),
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
                ),
                child: Text(
                  e.forceInject == ForceInjectTarget.world
                      ? widget.t.intermediate.memoryBrowser.pinWorldBadge
                      : widget.t.intermediate.memoryBrowser.pinDirectiveBadge,
                  style: LmNarrativeTextStyles.caption
                      .copyWith(color: widget.colors.primary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (e.injectionDisabled)
              Container(
                margin: const EdgeInsets.only(right: LmSpacing.s2xs),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: widget.colors.error.withValues(alpha: 0.12),
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
                ),
                child: Text(
                  widget.t.intermediate.memoryBrowser.injectionDisabledBadge,
                  style: LmNarrativeTextStyles.caption
                      .copyWith(color: widget.colors.error),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            if (e.isArchived)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(
                  color: widget.colors.surfaceVariant,
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
                ),
                child: Text(
                  widget.t.intermediate.chat.factsArchivedBadge,
                  style: LmNarrativeTextStyles.caption
                      .copyWith(color: widget.colors.faint),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            const SizedBox(width: LmSpacing.sXs),
            Text(
              '${widget.attributes.length}',
              style: LmNarrativeTextStyles.caption
                  .copyWith(color: widget.colors.muted),
            ),
            if (!widget.readOnly)
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert, color: widget.colors.muted, size: 18),
              color: widget.colors.surfaceElevated,
              onSelected: (value) {
                switch (value) {
                  case 'edit':
                    widget.onEdit();
                  case 'delete':
                    widget.onDelete();
                  case 'restore':
                    widget.onRestore();
                  case 'archive':
                    widget.onArchive?.call();
                  case 'toggleInjection':
                    widget.onToggleInjection?.call();
                }
              },
              itemBuilder: (ctx) => [
                // 已归档实体置顶"恢复"直达项（兑现"（可恢复）"文案承诺，
                // 此前只能从编辑对话框里的归档开关绕路）
                if (widget.entity.isArchived)
                  PopupMenuItem(
                    value: 'restore',
                    child: Row(
                      children: [
                        Icon(
                          Icons.restore,
                          size: 18,
                          color: widget.colors.success,
                        ),
                        const SizedBox(width: LmSpacing.sSm),
                        Flexible(
                          child: Text(
                            widget.t.intermediate.memoryBrowser.restoreEntity,
                            style: LmNarrativeTextStyles.bodyUi
                                .copyWith(color: widget.colors.ink),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                // 活跃实体归档直达项（可逆，恢复项在
                // 已归档态置顶显示）
                if (!widget.entity.isArchived && widget.onArchive != null)
                  PopupMenuItem(
                    value: 'archive',
                    child: Row(
                      children: [
                        Icon(
                          Icons.archive_outlined,
                          size: 18,
                          color: widget.colors.muted,
                        ),
                        const SizedBox(width: LmSpacing.sSm),
                        Flexible(
                          child: Text(
                            widget
                                .t.intermediate.memoryBrowser.archiveEntityItem,
                            style: LmNarrativeTextStyles.bodyUi
                                .copyWith(color: widget.colors.ink),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (!widget.entity.isArchived)
                  PopupMenuItem(
                    value: 'toggleInjection',
                    child: Row(
                      children: [
                        Icon(
                          widget.entity.injectionDisabled
                              ? Icons.notifications_active_outlined
                              : Icons.notifications_off_outlined,
                          size: 18,
                          color: widget.entity.injectionDisabled
                              ? widget.colors.success
                              : widget.colors.muted,
                        ),
                        const SizedBox(width: LmSpacing.sSm),
                        Flexible(
                          child: Text(
                            widget.entity.injectionDisabled
                                ? widget.t.intermediate.memoryBrowser
                                    .injectionEnableItem
                                : widget.t.intermediate.memoryBrowser
                                    .injectionDisableItem,
                            style: LmNarrativeTextStyles.bodyUi
                                .copyWith(color: widget.colors.ink),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                PopupMenuItem(
                  value: 'edit',
                  child: Row(
                    children: [
                      Icon(
                        Icons.edit_outlined,
                        size: 18,
                        color: widget.colors.muted,
                      ),
                      const SizedBox(width: LmSpacing.sSm),
                      Flexible(
                        child: Text(
                          widget.t.common.edit,
                          style: LmNarrativeTextStyles.bodyUi
                              .copyWith(color: widget.colors.ink),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(
                        Icons.delete_outline,
                        size: 18,
                        color: widget.colors.error,
                      ),
                      const SizedBox(width: LmSpacing.sSm),
                      Flexible(
                        child: Text(
                          widget.t.common.delete,
                          style: LmNarrativeTextStyles.bodyUi
                              .copyWith(color: widget.colors.ink),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAttributes() {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        LmSpacing.sMd,
        0,
        LmSpacing.sMd,
        LmSpacing.sMd,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.attributes.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: LmSpacing.sSm),
              child: Text(
                widget.t.intermediate.memoryBrowser.noAttributes,
                style: LmNarrativeTextStyles.caption.copyWith(
                  color: widget.colors.faint,
                  fontStyle: FontStyle.italic,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            )
          else
            ..._attributeRows(),

          // 新增属性按钮
          if (!widget.readOnly)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: widget.onAddAttribute,
                icon: Icon(Icons.add, size: 16, color: widget.colors.primary),
                label: Text(
                  widget.t.intermediate.memoryBrowser.addAttributeTitle,
                  style: LmNarrativeTextStyles.caption
                      .copyWith(color: widget.colors.primary),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LmSpacing.sXs,
                    vertical: LmSpacing.s2xs,
                  ),
                  minimumSize: const Size(0, 32),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 属性行列表：预计算基线键集合一次，供各行的「演变」徽标判定。
  /// 同键双行时基线行标「基线」、auto 行标「演变」；纯 auto 实体
  /// （无任何基线行）的行无徽标。
  List<Widget> _attributeRows() {
    final baselineKeys = <String>{
      for (final attr in widget.attributes)
        if (attr.source.isReadOnly) attr.attrKey,
    };
    return [
      for (final attr in widget.attributes)
        FactualAttributeRow(
          attribute: attr,
          entityType: widget.entity.type,
          baselineKeys: baselineKeys,
          colors: widget.colors,
          t: widget.t,
          readOnly: widget.readOnly,
          onEdit: () => widget.onEditAttribute(attr),
          onDelete: () => widget.onDeleteAttribute(attr),
        ),
    ];
  }
}
