import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/panel_heading.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/model_capability.dart';
import 'package:lmstory/features/settings/presentation/widgets/manual_model_id_confirmation.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 模型编辑弹窗
///
/// 对标 ChatBox 的 ModelEdit modal。新建或编辑模型时弹出，让用户配置完整的
/// 模型元数据：类型、能力、上下文窗口、最大输出。提供"测试模型"按钮，通过
/// 发送实际请求自动探测 vision/tool_use 能力。
///
/// - [existingModel] 非 null 时为编辑模式，modelId 字段只读。
/// - [presetId] 用于 Test Model 调用 API。
class ModelEditDialog extends ConsumerStatefulWidget {
  const ModelEditDialog({
    required this.presetId,
    this.existingModel,
    super.key,
  });

  final String presetId;
  final ModelInfo? existingModel;

  @override
  ConsumerState<ModelEditDialog> createState() => _ModelEditDialogState();
}

class _ModelEditDialogState extends ConsumerState<ModelEditDialog> {
  final _idFocus = FocusNode();
  late final TextEditingController _idController;
  late final TextEditingController _nameController;
  late final TextEditingController _contextController;
  late final TextEditingController _maxOutputController;

  late ModelType _type;
  late Set<ModelCapability> _capabilities;
  bool _isTesting = false;
  String? _testMessage;
  bool? _testSuccess;

  bool get _isEditing => widget.existingModel != null;

  @override
  void initState() {
    super.initState();
    final m = widget.existingModel;
    _idController = TextEditingController(text: m?.modelId ?? '');
    _nameController = TextEditingController(text: m?.displayName ?? '');
    _contextController = TextEditingController(
      text: m?.contextWindow?.toString() ?? '',
    );
    _maxOutputController = TextEditingController(
      text: m?.maxOutput?.toString() ?? '',
    );
    _type = m?.type ?? ModelType.chat;
    _capabilities = {...?m?.capabilities};
  }

  @override
  void dispose() {
    _idFocus.dispose();
    _idController.dispose();
    _nameController.dispose();
    _contextController.dispose();
    _maxOutputController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return Dialog(
      insetPadding: const EdgeInsets.all(SimpleSpacing.sLg),
      child: Container(
        constraints: const BoxConstraints(
          maxWidth: LmLayout.dialogNarrowWidth,
        ),
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _header(t, colors),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(SimpleSpacing.sLg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _field(
                      label: t.settings.provider.modelId,
                      child: TextField(
                        controller: _idController,
                        focusNode: _idFocus,
                        autocorrect: false,
                        enableSuggestions: false,
                        enabled: !_isEditing,
                        decoration: _inputDecoration(
                          colors,
                          hint: t.settings.provider.modelIdHint,
                          readOnlyHint: _isEditing
                              ? t.settings.provider.modelIdReadonly
                              : null,
                        ),
                      ),
                    ),
                    _field(
                      label: t.settings.provider.modelDisplayName,
                      child: TextField(
                        controller: _nameController,
                        decoration: _inputDecoration(
                          colors,
                          hint: t.settings.provider.modelDisplayNameHint,
                        ),
                      ),
                    ),
                    _field(
                      label: t.settings.provider.modelType,
                      child: _typeDropdown(t, colors),
                    ),
                    if (_type == ModelType.chat) ...[
                      _capabilitySection(t, colors),
                    ],
                    _field(
                      label: t.settings.provider.contextWindow,
                      child: _numericField(
                        _contextController,
                        colors,
                        hint: t.settings.provider.contextWindowHint,
                      ),
                    ),
                    _field(
                      label: t.settings.provider.maxOutput,
                      child: _numericField(
                        _maxOutputController,
                        colors,
                        hint: t.settings.provider.maxOutputHint,
                      ),
                    ),
                    const SizedBox(height: SimpleSpacing.sXs),
                    _testModelSection(t, colors),
                  ],
                ),
              ),
            ),
            _footer(t, colors),
          ],
        ),
      ),
    );
  }

  Widget _header(Translations t, LmPalette colors) => Padding(
        padding: const EdgeInsets.fromLTRB(
          SimpleSpacing.sLg,
          SimpleSpacing.sLg,
          SimpleSpacing.sMd,
          SimpleSpacing.sMd,
        ),
        child: PanelHeading(
          title: _isEditing
              ? t.settings.provider.editModel
              : t.settings.provider.addModel,
          actions: [
            IconButton(
              //  语义缺口：复用 common.close（不新增 i18n key）。
              tooltip: t.common.close,
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      );

  InputDecoration _inputDecoration(
    LmPalette colors, {
    required String hint,
    String? readOnlyHint,
  }) =>
      InputDecoration(
        hintText: readOnlyHint ?? hint,
        hintStyle: SimpleTextStyles.body.copyWith(color: colors.muted),
        isDense: true,
        filled: true,
        fillColor: colors.surfaceVariant,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
          borderSide: BorderSide(color: colors.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
          borderSide: BorderSide(color: colors.primary, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: SimpleSpacing.sMd,
          vertical: SimpleSpacing.sSm,
        ),
      );

  Widget _field({required String label, required Widget child}) => Padding(
        padding: const EdgeInsets.only(bottom: SimpleSpacing.sMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: SimpleSpacing.s2xs),
              child: Text(
                label,
                style: SimpleTextStyles.caption.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            child,
          ],
        ),
      );

  Widget _typeDropdown(Translations t, LmPalette colors) {
    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
        border: Border.all(color: colors.divider),
      ),
      padding: const EdgeInsets.symmetric(horizontal: SimpleSpacing.sMd),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<ModelType>(
          value: _type,
          isExpanded: true,
          style: DefaultTextStyle.of(context)
              .style
              .merge(SimpleTextStyles.body)
              .copyWith(color: colors.ink),
          items: [
            _dropdownItem(
              t.settings.provider.modelTypeOptions.chat,
              ModelType.chat,
              Icons.chat_bubble_outline,
            ),
            _dropdownItem(
              t.settings.provider.modelTypeOptions.embedding,
              ModelType.embedding,
              Icons.memory_outlined,
            ),
            _dropdownItem(
              t.settings.provider.modelTypeOptions.rerank,
              ModelType.rerank,
              Icons.sort,
            ),
          ],
          onChanged: (v) {
            if (v == null) return;
            setState(() {
              _type = v;
              if (v != ModelType.chat) {
                _capabilities.clear();
              }
            });
          },
        ),
      ),
    );
  }

  DropdownMenuItem<ModelType> _dropdownItem(
    String label,
    ModelType value,
    IconData icon,
  ) =>
      DropdownMenuItem<ModelType>(
        value: value,
        child: Row(
          children: [
            Icon(icon, size: 18, color: colors.faint),
            const SizedBox(width: SimpleSpacing.sSm),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );

  LmPalette get colors => context.lm.palette;

  Widget _capabilitySection(Translations t, LmPalette colors) {
    return Padding(
      padding: const EdgeInsets.only(bottom: SimpleSpacing.sMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(
                  t.settings.provider.modelCapabilities,
                  style: SimpleTextStyles.caption.copyWith(
                    color: colors.muted,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: SimpleSpacing.sXs),
              Flexible(
                child: Text(
                  t.settings.provider.modelCapabilitiesHint,
                  style:
                      SimpleTextStyles.overline.copyWith(color: colors.faint),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: SimpleSpacing.s2xs),
          Wrap(
            spacing: SimpleSpacing.sXs,
            runSpacing: SimpleSpacing.sXs,
            children: ModelCapability.values.map((cap) {
              final selected = _capabilities.contains(cap);
              return _CapabilityChip(
                label: _capabilityLabel(t, cap),
                icon: _capabilityIcon(cap),
                selected: selected,
                onChanged: (v) => setState(() {
                  if (v) {
                    _capabilities.add(cap);
                  } else {
                    _capabilities.remove(cap);
                  }
                }),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  String _capabilityLabel(Translations t, ModelCapability cap) {
    final opts = t.settings.provider.modelCapabilitiesOptions;
    switch (cap) {
      case ModelCapability.vision:
        return opts.vision;
      case ModelCapability.reasoning:
        return opts.reasoning;
      case ModelCapability.toolUse:
        return opts.toolUse;
      case ModelCapability.webSearch:
        return opts.webSearch;
    }
  }

  IconData _capabilityIcon(ModelCapability cap) {
    switch (cap) {
      case ModelCapability.vision:
        return Icons.visibility_outlined;
      case ModelCapability.reasoning:
        return Icons.lightbulb_outline;
      case ModelCapability.toolUse:
        return Icons.build_outlined;
      case ModelCapability.webSearch:
        return Icons.travel_explore_outlined;
    }
  }

  Widget _numericField(
    TextEditingController controller,
    LmPalette colors, {
    required String hint,
  }) =>
      TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: _inputDecoration(colors, hint: hint).copyWith(
          suffixText: 'tokens',
          suffixStyle: SimpleTextStyles.overline.copyWith(color: colors.faint),
        ),
      );

  Widget _testModelSection(Translations t, LmPalette colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _isTesting ? null : _runTest,
            icon: _isTesting
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.science_outlined, size: 18),
            label: Text(
              _isTesting
                  ? t.settings.provider.testingModel
                  : t.settings.provider.testModel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        if (_testMessage != null) ...[
          const SizedBox(height: SimpleSpacing.sXs),
          Row(
            children: [
              Icon(
                (_testSuccess ?? false)
                    ? Icons.check_circle
                    : Icons.error_outline,
                size: 14,
                color: (_testSuccess ?? false) ? colors.success : colors.error,
              ),
              const SizedBox(width: SimpleSpacing.s2xs),
              Expanded(
                child: Text(
                  _testMessage!,
                  style: SimpleTextStyles.overline.copyWith(
                    color:
                        (_testSuccess ?? false) ? colors.muted : colors.error,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Future<void> _runTest() async {
    final id = _idController.text.trim();
    if (id.isEmpty) return;

    setState(() {
      _isTesting = true;
      _testMessage = null;
    });

    try {
      final service = ref.read(modelTestServiceProvider);
      final result = await service.testModel(
        presetId: widget.presetId,
        modelId: id,
      );

      if (!mounted) return;

      final t = Translations.of(context);
      if (result.hasError) {
        setState(() {
          _isTesting = false;
          _testSuccess = false;
          _testMessage = t.settings.provider.testModelUnavailable;
        });
        return;
      }

      // 自动勾选检测到的能力
      setState(() {
        _isTesting = false;
        _testSuccess = true;
        if (result.visionSupported ?? false) {
          _capabilities.add(ModelCapability.vision);
        }
        if (result.toolUseSupported ?? false) {
          _capabilities.add(ModelCapability.toolUse);
        }
        _testMessage = t.settings.provider.testModelSuccess(
          vision: (result.visionSupported ?? false) ? '✓' : '✗',
          tool: (result.toolUseSupported ?? false) ? '✓' : '✗',
        );
      });
    } on Exception catch (e) {
      if (!mounted) return;
      final t = Translations.of(context);
      setState(() {
        _isTesting = false;
        _testSuccess = false;
        _testMessage = t.settings.provider.testModelFail(error: '$e');
      });
    }
  }

  Widget _footer(Translations t, LmPalette colors) => Container(
        decoration: BoxDecoration(
          border: Border(top: BorderSide(color: colors.divider)),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: SimpleSpacing.sLg,
          vertical: SimpleSpacing.sSm,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                t.common.cancel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: SimpleSpacing.sSm),
            ElevatedButton(
              onPressed: _save,
              child: Text(
                t.common.save,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );

  Future<void> _save() async {
    final id = widget.existingModel?.modelId ?? _idController.text.trim();
    if (id.isEmpty) return;

    if (!_isEditing) {
      final confirmed = await confirmManualModelId(context, id);
      if (!mounted) return;
      if (!confirmed) {
        _idFocus.requestFocus();
        return;
      }
      if (_idController.text.trim() != id) return;
    }

    final contextWindow = int.tryParse(_contextController.text.trim());
    final maxOutput = int.tryParse(_maxOutputController.text.trim());
    final name = _nameController.text.trim();

    Navigator.of(context).pop(
      ModelInfo(
        modelId: id,
        displayName: name.isEmpty ? null : name,
        type: _type,
        capabilities: _capabilities.toList(),
        contextWindow: contextWindow,
        maxOutput: maxOutput,
        labels: widget.existingModel?.labels ?? const [],
      ),
    );
  }
}

/// 能力选择 chip
class _CapabilityChip extends StatelessWidget {
  const _CapabilityChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onChanged,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return Material(
      color: selected ? colors.primaryDim : colors.surfaceVariant,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
      child: InkWell(
        onTap: () => onChanged(!selected),
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: SimpleSpacing.sSm,
            vertical: SimpleSpacing.s2xs,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 14,
                color: selected ? colors.primary : colors.faint,
              ),
              const SizedBox(width: SimpleSpacing.s2xs),
              Flexible(
                child: Text(
                  label,
                  style: SimpleTextStyles.overline.copyWith(
                    color: selected ? colors.primary : colors.muted,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: SimpleSpacing.s2xs),
              Icon(
                selected ? Icons.check_circle : Icons.add_circle_outline,
                size: 14,
                color: selected ? colors.primary : colors.faint,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
