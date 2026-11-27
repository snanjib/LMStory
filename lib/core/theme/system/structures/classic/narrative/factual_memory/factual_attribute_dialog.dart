import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/services/attribute_schema.dart';
import 'package:lmstory/i18n/factual_labels.dart';
import 'package:lmstory/i18n/strings.g.dart';

// 从 factual_memory_tab.dart 拆出（原 _AttributeEditResult /
// _AttributeEditDialog，逐字符搬运，仅改公开）。

/// 属性编辑结果。
class FactualAttributeEditResult {
  FactualAttributeEditResult({
    required this.attrKey,
    required this.value,
    required this.valueType,
    required this.importance,
  });

  final String attrKey;
  final String value;
  final AttributeValueType valueType;
  final int importance;
}

/// 属性编辑对话框。
class FactualAttributeEditDialog extends StatefulWidget {
  const FactualAttributeEditDialog({
    required this.attribute,
    required this.entityType,
    required this.title,
    super.key,
  });

  final FactualAttribute? attribute;
  final FactualEntityType entityType;
  final String title;

  @override
  State<FactualAttributeEditDialog> createState() =>
      _FactualAttributeEditDialogState();
}

class _FactualAttributeEditDialogState
    extends State<FactualAttributeEditDialog> {
  late final TextEditingController _customKeyController;
  late final TextEditingController _valueController;

  /// 选中的预定义 attrKey。null 表示"自定义"选项。
  String? _selectedAttrKey;
  late AttributeValueType _valueType;
  late int _importance;

  @override
  void initState() {
    super.initState();
    final a = widget.attribute;
    _customKeyController = TextEditingController(text: a?.attrKey ?? '');
    _valueController = TextEditingController(text: _decodeValueForDisplay(a));

    if (a != null) {
      // 编辑模式：检查 attrKey 是否在白名单内
      final isInSchema = AttributeSchema.isAttrKeyAllowed(
        widget.entityType,
        a.attrKey,
      );
      _selectedAttrKey = isInSchema ? a.attrKey : null;
      _valueType = a.valueType;
    } else {
      // 新增模式：默认选第一个预定义属性。：
      // 跳过 name 键——手动新增 name 属性会落 auto 行，此后 AI 对该实体的
      // 任何 update_attr name 一律转别名（先于 auto 行查找），该行成为
      // AI 永不可写、又与头部主名同屏展示的混淆行。
      final keys = AttributeSchema.attrKeysFor(widget.entityType);
      final selectable = keys.where((k) => k != 'name').toList();
      _selectedAttrKey = selectable.isNotEmpty ? selectable.first : null;
      _valueType = _selectedAttrKey != null
          ? AttributeSchema.valueTypeOf(widget.entityType, _selectedAttrKey!)
          : AttributeValueType.single;
    }
    _importance = a?.importance ?? 3;
  }

  @override
  void dispose() {
    _customKeyController.dispose();
    _valueController.dispose();
    super.dispose();
  }

  /// 当前是否为自定义属性键模式
  bool get _isCustom => _selectedAttrKey == null;

  /// 显示用的属性键文本（编辑模式只读展示）
  String _displayAttrKey(Translations t) {
    final a = widget.attribute;
    if (a == null) return '';
    final label = factualAttributeLabel(t, widget.entityType, a.attrKey);
    if (label != null) return label;
    return t.intermediate.memoryBrowser.attributeLabels.custom(key: a.attrKey);
  }

  /// 将属性值从存储格式解码为显示格式
  ///
  /// - single：直接返回原始值
  /// - list：JSON 数组 -> 每行一个值
  /// - dict：JSON 对象 -> 每行"键: 值"
  String _decodeValueForDisplay(FactualAttribute? a) {
    if (a == null) return '';
    switch (a.valueType) {
      case AttributeValueType.single:
        return a.value;
      case AttributeValueType.list:
        return a.listValue.join('\n');
      case AttributeValueType.dict:
        try {
          final decoded = jsonDecode(a.value);
          if (decoded is Map) {
            return decoded.entries
                .map((e) => '${e.key}: ${e.value}')
                .join('\n');
          }
        } catch (_) {
          // 解析失败显示原始值
        }
        return a.value;
    }
  }

  /// 将显示格式编码为存储格式
  ///
  /// 返回 null 表示值为空（调用方应阻止保存）。
  String? _encodeValueForStorage(String displayValue) {
    switch (_valueType) {
      case AttributeValueType.single:
        final trimmed = displayValue.trim();
        return trimmed.isEmpty ? null : trimmed;
      case AttributeValueType.list:
        final lines = displayValue
            .split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList();
        return lines.isEmpty ? null : jsonEncode(lines);
      case AttributeValueType.dict:
        final map = <String, String>{};
        for (final line in displayValue.split('\n')) {
          final trimmed = line.trim();
          if (trimmed.isEmpty) continue;
          final idx = trimmed.indexOf(':');
          if (idx <= 0) continue; // 跳过无效行
          final key = trimmed.substring(0, idx).trim();
          final value = trimmed.substring(idx + 1).trim();
          if (key.isNotEmpty) map[key] = value;
        }
        return map.isEmpty ? null : jsonEncode(map);
    }
  }

  String _valueHint(Translations t) {
    switch (_valueType) {
      case AttributeValueType.single:
        return t.intermediate.memoryBrowser.valueTypeHintSingle;
      case AttributeValueType.list:
        return t.intermediate.memoryBrowser.valueTypeHintList;
      case AttributeValueType.dict:
        return t.intermediate.memoryBrowser.valueTypeHintDict;
    }
  }

  InputDecoration _inputDecoration(
    LmPalette colors, {
    required String label,
    String? helperText,
  }) {
    return InputDecoration(
      labelText: label,
      labelStyle: LmNarrativeTextStyles.label.copyWith(color: colors.muted),
      helperText: helperText,
      helperStyle: LmNarrativeTextStyles.caption.copyWith(color: colors.faint),
      helperMaxLines: 3,
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
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final isEdit = widget.attribute != null;
    // 新增模式下拉不提供 name 键——
    // 手动新增 name 属性会与头部主名同屏混淆，且此后 AI 的 update_attr
    // name 一律转别名，该行成为死行。编辑模式不受影响（只读展示）。
    final keys = AttributeSchema.attrKeysFor(widget.entityType)
        .where((k) => isEdit || k != 'name')
        .toList();

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
              // 属性键
              if (isEdit)
                // 编辑模式：只读显示（不可改属性键，避免数据不一致）
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LmSpacing.sMd,
                    vertical: LmSpacing.sSm,
                  ),
                  decoration: BoxDecoration(
                    color: colors.surfaceVariant,
                    borderRadius:
                        BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.intermediate.memoryBrowser.fieldAttrKey,
                        style: LmNarrativeTextStyles.label.copyWith(
                          color: colors.muted,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _displayAttrKey(t),
                        style: LmNarrativeTextStyles.input.copyWith(
                          color: colors.ink,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _isCustom
                            ? t.intermediate.memoryBrowser
                                .fieldCustomAttrKeyHint
                            : t.intermediate.memoryBrowser.fieldAttrKeyHint,
                        style: LmNarrativeTextStyles.caption.copyWith(
                          color: colors.faint,
                        ),
                        maxLines: 3,
                      ),
                    ],
                  ),
                )
              else
                // 新增模式：下拉选择（预定义 + 自定义）
                DropdownButtonFormField<String?>(
                  initialValue: _selectedAttrKey,
                  decoration: _inputDecoration(
                    colors,
                    label: t.intermediate.memoryBrowser.fieldAttrKey,
                    helperText: t.intermediate.memoryBrowser.fieldAttrKeyHint,
                  ),
                  dropdownColor: colors.surfaceElevated,
                  style: LmNarrativeTextStyles.input.copyWith(
                    color: colors.ink,
                  ),
                  items: [
                    for (final key in keys)
                      DropdownMenuItem(
                        value: key,
                        child: Text(
                          factualAttributeLabel(t, widget.entityType, key) ??
                              key,
                        ),
                      ),
                    DropdownMenuItem(
                      child: Text(
                        t.intermediate.memoryBrowser.customAttrKeyOption,
                      ),
                    ),
                  ],
                  onChanged: (v) {
                    setState(() {
                      _selectedAttrKey = v;
                      if (v != null) {
                        // 预定义属性：自动确定值类型
                        _valueType = AttributeSchema.valueTypeOf(
                          widget.entityType,
                          v,
                        );
                      }
                    });
                  },
                ),
              // 自定义属性键输入（仅新增 + 自定义模式）
              if (!isEdit && _isCustom) ...[
                const SizedBox(height: LmSpacing.sSm),
                TextField(
                  controller: _customKeyController,
                  style: LmNarrativeTextStyles.input.copyWith(
                    color: colors.ink,
                  ),
                  decoration: _inputDecoration(
                    colors,
                    label: t.intermediate.memoryBrowser.fieldCustomAttrKey,
                    helperText:
                        t.intermediate.memoryBrowser.fieldCustomAttrKeyHint,
                  ),
                ),
              ],
              // 值类型选择（仅新增 + 自定义属性；编辑时值类型不可改，
              // 因 FactualRepository.updateAttributeValue 不更新 valueType）
              if (!isEdit && _isCustom) ...[
                const SizedBox(height: LmSpacing.sSm),
                DropdownButtonFormField<AttributeValueType>(
                  initialValue: _valueType,
                  decoration: _inputDecoration(
                    colors,
                    label: t.intermediate.memoryBrowser.fieldValueType,
                  ),
                  dropdownColor: colors.surfaceElevated,
                  style: LmNarrativeTextStyles.input.copyWith(
                    color: colors.ink,
                  ),
                  items: [
                    DropdownMenuItem(
                      value: AttributeValueType.single,
                      child: Text(t.intermediate.memoryBrowser.valueTypeSingle),
                    ),
                    DropdownMenuItem(
                      value: AttributeValueType.list,
                      child: Text(t.intermediate.memoryBrowser.valueTypeList),
                    ),
                    DropdownMenuItem(
                      value: AttributeValueType.dict,
                      child: Text(t.intermediate.memoryBrowser.valueTypeDict),
                    ),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _valueType = v);
                  },
                ),
              ],
              const SizedBox(height: LmSpacing.sSm),
              // 属性值输入（根据值类型自适应行数）
              TextField(
                controller: _valueController,
                maxLines: _valueType == AttributeValueType.single ? 2 : 5,
                style: LmNarrativeTextStyles.input.copyWith(color: colors.ink),
                decoration: _inputDecoration(
                  colors,
                  label: t.intermediate.memoryBrowser.fieldAttrValue,
                  helperText: _valueHint(t),
                ),
              ),
              const SizedBox(height: LmSpacing.sSm),
              // 重要性
              Row(
                children: [
                  Flexible(
                    child: Text(
                      t.intermediate.memoryBrowser.fieldImportance,
                      style: LmNarrativeTextStyles.label.copyWith(
                        color: colors.ink,
                      ),
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
                    style: LmNarrativeTextStyles.label.copyWith(
                      color: colors.primary,
                    ),
                  ),
                ],
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

  void _onSave() {
    final displayValue = _valueController.text.trim();
    if (displayValue.isEmpty) return;

    final attrKey =
        _isCustom ? _customKeyController.text.trim() : _selectedAttrKey;
    if (attrKey == null || attrKey.isEmpty) return;

    final encodedValue = _encodeValueForStorage(displayValue);
    if (encodedValue == null) return;

    Navigator.pop(
      context,
      FactualAttributeEditResult(
        attrKey: attrKey,
        value: encodedValue,
        valueType: _valueType,
        importance: _importance,
      ),
    );
  }
}
