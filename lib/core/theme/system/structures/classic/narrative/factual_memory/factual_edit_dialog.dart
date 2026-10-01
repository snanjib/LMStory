import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/i18n/strings.g.dart';

// 从 factual_memory_tab.dart 拆出（原 _EntityEditResult / _EntityEditDialog，
// 逐字符搬运，仅改公开）。

/// 实体编辑结果。
class FactualEntityEditResult {
  FactualEntityEditResult({
    required this.primaryName,
    required this.type,
    required this.importance,
    required this.category,
    required this.isArchived,
  });

  final String primaryName;
  final FactualEntityType type;
  final int importance;
  final String? category;
  final bool isArchived;
}

/// 实体编辑对话框。
class FactualEntityEditDialog extends StatefulWidget {
  const FactualEntityEditDialog({
    required this.entity,
    required this.title,
    super.key,
  });

  final FactualEntity? entity;
  final String title;

  @override
  State<FactualEntityEditDialog> createState() =>
      _FactualEntityEditDialogState();
}

class _FactualEntityEditDialogState extends State<FactualEntityEditDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _categoryController;
  late FactualEntityType _type;
  late int _importance;
  late bool _isArchived;

  /// 名称行内校验错误（空名提示）
  String? _nameError;

  @override
  void initState() {
    super.initState();
    final e = widget.entity;
    _nameController = TextEditingController(text: e?.primaryName ?? '');
    _categoryController = TextEditingController(text: e?.category ?? '');
    _type = e?.type ?? FactualEntityType.character;
    _importance = e?.importance ?? 3;
    _isArchived = e?.isArchived ?? false;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _categoryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return AlertDialog(
      title: Text(
        widget.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildField(
                _nameController,
                t.intermediate.memoryBrowser.fieldEntityName,
                helperText: t.intermediate.memoryBrowser.fieldEntityNameHint,
                errorText: _nameError,
              ),
              const SizedBox(height: LmSpacing.sSm),
              // 类型选择
              DropdownButtonFormField<FactualEntityType>(
                initialValue: _type,
                decoration: InputDecoration(
                  labelText: t.intermediate.memoryBrowser.fieldEntityType,
                  labelStyle: LmNarrativeTextStyles.label.copyWith(
                    color: colors.muted,
                  ),
                  helperText: t.intermediate.memoryBrowser.fieldEntityTypeHint,
                  helperStyle: LmNarrativeTextStyles.caption.copyWith(
                    color: colors.faint,
                  ),
                  helperMaxLines: 3,
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
                dropdownColor: colors.surfaceElevated,
                style: LmNarrativeTextStyles.input.copyWith(color: colors.ink),
                items: [
                  DropdownMenuItem(
                    value: FactualEntityType.character,
                    child: Text(t.intermediate.chat.factsTypeCharacter),
                  ),
                  DropdownMenuItem(
                    value: FactualEntityType.location,
                    child: Text(t.intermediate.chat.factsTypeLocation),
                  ),
                  DropdownMenuItem(
                    value: FactualEntityType.item,
                    child: Text(t.intermediate.chat.factsTypeItem),
                  ),
                  DropdownMenuItem(
                    value: FactualEntityType.lore,
                    child: Text(t.intermediate.chat.factsTypeLore),
                  ),
                  DropdownMenuItem(
                    value: FactualEntityType.organization,
                    child: Text(t.intermediate.chat.factsTypeOrganization),
                  ),
                  DropdownMenuItem(
                    value: FactualEntityType.misc,
                    child: Text(t.intermediate.chat.factsTypeMisc),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _type = v);
                },
              ),
              const SizedBox(height: LmSpacing.sSm),
              _buildField(
                _categoryController,
                t.intermediate.memoryBrowser.fieldCategory,
                helperText: t.intermediate.memoryBrowser.fieldCategoryHint,
              ),
              const SizedBox(height: LmSpacing.sSm),
              Row(
                children: [
                  Flexible(
                    child: Text(
                      t.intermediate.memoryBrowser.fieldImportance,
                      style: LmNarrativeTextStyles.label
                          .copyWith(color: colors.ink),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Expanded(
                    child: Slider(
                      value: _importance.toDouble(),
                      min: 1,
                      max: 5,
                      divisions: 4,
                      label: '$_importance',
                      activeColor: colors.primary,
                      onChanged: (v) => setState(() => _importance = v.round()),
                    ),
                  ),
                  Text(
                    '$_importance',
                    style: LmNarrativeTextStyles.label
                        .copyWith(color: colors.primary),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: LmSpacing.sSm),
                child: Text(
                  t.intermediate.memoryBrowser.fieldImportanceHint,
                  style: LmNarrativeTextStyles.caption
                      .copyWith(color: colors.faint),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SwitchListTile(
                title: Text(
                  t.intermediate.memoryBrowser.fieldArchived,
                  style:
                      LmNarrativeTextStyles.label.copyWith(color: colors.ink),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  t.intermediate.memoryBrowser.fieldArchivedHint,
                  style: LmNarrativeTextStyles.caption
                      .copyWith(color: colors.faint),
                  maxLines: 3,
                ),
                value: _isArchived,
                activeThumbColor: colors.primary,
                contentPadding: EdgeInsets.zero,
                onChanged: (v) => setState(() => _isArchived = v),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(
            t.common.cancel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        FilledButton(
          onPressed: _onSave,
          child: Text(
            t.common.save,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildField(
    TextEditingController controller,
    String label, {
    String? helperText,
    String? errorText,
  }) {
    final colors = context.lm.palette;
    return TextField(
      controller: controller,
      style: LmNarrativeTextStyles.input.copyWith(color: colors.ink),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: LmNarrativeTextStyles.label.copyWith(color: colors.muted),
        helperText: helperText,
        helperStyle: LmNarrativeTextStyles.caption.copyWith(
          color: colors.faint,
        ),
        helperMaxLines: 3,
        errorText: errorText,
        errorStyle: LmNarrativeTextStyles.caption.copyWith(
          color: colors.error,
        ),
        filled: true,
        fillColor: colors.surfaceVariant,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: LmSpacing.sMd,
          vertical: LmSpacing.sSm,
        ),
      ),
    );
  }

  void _onSave() {
    final t = Translations.of(context);
    final name = _nameController.text.trim();
    // 空名不再静默无反应，给出可行动的行内提示
    if (name.isEmpty) {
      setState(() => _nameError = t.intermediate.memoryBrowser.nameRequired);
      return;
    }
    if (_nameError != null) setState(() => _nameError = null);
    final category = _categoryController.text.trim();

    Navigator.pop(
      context,
      FactualEntityEditResult(
        primaryName: name,
        type: _type,
        importance: _importance,
        category: category.isEmpty ? null : category,
        isArchived: _isArchived,
      ),
    );
  }
}
