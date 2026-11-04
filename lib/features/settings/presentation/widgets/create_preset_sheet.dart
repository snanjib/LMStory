import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/panel_heading.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/settings/data/provider_templates.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';
import 'package:lmstory/features/settings/presentation/utils/protocol_display.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 新建供应商结果
///
/// - [templateId] 非空：基于模板创建，[protocol]/`baseUrl` 来自模板
/// - [templateId] 为 null：自定义创建，使用 [protocol]（baseUrl 留空，详情页补全）
class CreatePresetResult {
  const CreatePresetResult({
    required this.name,
    this.templateId,
    this.protocol,
  });

  final String name;
  final String? templateId;
  final LlmProtocol? protocol;
}

/// 新建供应商 BottomSheet（DOC-12 §9.2）
///
/// 两步流程：
/// 1. 模板选择：列出 7 个内置模板 + 1 个"自定义"列表项
/// 2. 命名：输入供应商名称，预览协议/baseUrl
///    - 选模板：协议和 baseUrl 来自模板（只读预览）
///    - 选自定义：选择协议（4 选 1），baseUrl 留空到详情页补全
///
/// 设计对齐 Simple Mode 规范（DOC-06 / DOC-06A）：
/// - surfaceElevated 背景 + xl 顶部圆角 + grabber handle
/// - 模板列表项单列纵向排列，样式对齐 ProviderListPage._ProviderCard
///   （左图标 + 中信息 + 右箭头），点击即进入命名步骤
/// - 底部固定操作区，主按钮 filled，次按钮 ghost
class CreatePresetSheet extends StatefulWidget {
  const CreatePresetSheet({super.key});

  @override
  State<CreatePresetSheet> createState() => _CreatePresetSheetState();
}

class _CreatePresetSheetState extends State<CreatePresetSheet> {
  _Step _step = _Step.template;
  ProviderTemplate? _selectedTemplate;
  LlmProtocol _customProtocol = LlmProtocol.openaiCompatible;
  final _nameController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    return SafeArea(
      top: false,
      child: Container(
        decoration: BoxDecoration(
          // 琉璃下面层让位 GlassBottomSheet 工厂；经典保持原槽位零变化。
          color: context.lmSheetFaceColor(colors.surfaceElevated),
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(context.lmUi.radius(LmCorner.xl)),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _Grabber(),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                SimpleSpacing.sLg,
                SimpleSpacing.sSm,
                SimpleSpacing.sLg,
                SimpleSpacing.sMd,
              ),
              child: PanelHeading(
                title: _step == _Step.template
                    ? t.settings.provider.templatePicker.title
                    : _selectedTemplate?.name ??
                        t.settings.provider.templatePicker.custom,
                subtitle: _step == _Step.template
                    ? t.settings.provider.templatePicker.subtitle
                    : t.settings.provider.templatePicker.nameStep,
                leading: _step == _Step.name
                    ? IconButton(
                        icon: const Icon(Icons.arrow_back, size: 20),
                        constraints:
                            const BoxConstraints(minWidth: 44, minHeight: 44),
                        tooltip: t.settings.provider.templatePicker.back,
                        onPressed: () => setState(() {
                          _step = _Step.template;
                          _nameController.clear();
                        }),
                      )
                    : null,
              ),
            ),
            Flexible(
              child: _step == _Step.template
                  ? _buildTemplateList(context)
                  : _buildNameStep(context),
            ),
            _buildActions(context),
          ],
        ),
      ),
    );
  }

  Widget _buildTemplateList(BuildContext context) {
    final items = <_TemplateItem>[
      ...ProviderTemplates.all.map(
        (t) => _TemplateItem(
          template: t,
          isSelected: _selectedTemplate?.templateId == t.templateId &&
              _step == _Step.name,
        ),
      ),
      _TemplateItem(
        template: null,
        isSelected: _selectedTemplate == null && _step == _Step.name,
      ),
    ];

    return ListView.builder(
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sLg,
        vertical: SimpleSpacing.sXs,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: SimpleSpacing.sSm),
          child: _TemplateCard(
            item: item,
            onTap: () => _onTemplateTap(item.template),
          ),
        );
      },
    );
  }

  Widget _buildNameStep(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        SimpleSpacing.sLg,
        SimpleSpacing.sXs,
        SimpleSpacing.sLg,
        SimpleSpacing.sLg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.settings.provider.name,
            style: SimpleTextStyles.bodySm.copyWith(
              fontWeight: FontWeight.w600,
              color: colors.ink,
            ),
          ),
          const SizedBox(height: SimpleSpacing.sXs),
          TextField(
            controller: _nameController,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              hintText: t.settings.provider.templatePicker.nameHint,
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: SimpleSpacing.sLg),
          Text(
            t.settings.provider.protocol,
            style: SimpleTextStyles.bodySm.copyWith(
              fontWeight: FontWeight.w600,
              color: colors.ink,
            ),
          ),
          const SizedBox(height: SimpleSpacing.sXs),
          if (_selectedTemplate != null)
            _ProtocolReadOnly(protocol: _selectedTemplate!.protocol)
          else
            _ProtocolSelector(
              protocol: _customProtocol,
              onChanged: (p) => setState(() => _customProtocol = p),
            ),
          if (_selectedTemplate != null) ...[
            const SizedBox(height: SimpleSpacing.sLg),
            Text(
              t.settings.provider.templatePicker.templatePreview,
              style: SimpleTextStyles.bodySm.copyWith(
                fontWeight: FontWeight.w600,
                color: colors.ink,
              ),
            ),
            const SizedBox(height: SimpleSpacing.sXs),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: SimpleSpacing.sSm,
                vertical: SimpleSpacing.sXs,
              ),
              decoration: BoxDecoration(
                color: colors.surfaceVariant,
                borderRadius:
                    BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
              ),
              child: Text(
                _selectedTemplate!.defaultBaseUrl,
                style: SimpleTextStyles.overline.copyWith(color: colors.faint),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildActions(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    // 命名步骤且名称非空时才可提交
    final canSubmit =
        _step == _Step.name && _nameController.text.trim().isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.divider)),
      ),
      padding: const EdgeInsets.fromLTRB(
        SimpleSpacing.sLg,
        SimpleSpacing.sSm,
        SimpleSpacing.sLg,
        SimpleSpacing.sMd,
      ),
      child: Row(
        children: [
          Expanded(
            child: TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(
                t.common.cancel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(width: SimpleSpacing.sSm),
          Expanded(
            // 模板选择步骤不显示主按钮（避免禁用态造成困惑）
            // 命名步骤显示"创建"按钮，名称为空时禁用
            child: _step == _Step.template
                ? const SizedBox.shrink()
                : FilledButton(
                    onPressed: canSubmit ? _submit : null,
                    child: Text(
                      t.settings.provider.templatePicker.create,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  void _onTemplateTap(ProviderTemplate? template) {
    setState(() {
      _selectedTemplate = template;
      _step = _Step.name;
      // 基于模板创建时，默认填入模板名作为供应商名（用户可修改）
      // 完全自定义时清空，让用户自行输入
      _nameController.text = template?.name ?? '';
    });
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    Navigator.of(context).pop(
      CreatePresetResult(
        name: name,
        templateId: _selectedTemplate?.templateId,
        protocol: _selectedTemplate == null ? _customProtocol : null,
      ),
    );
  }
}

enum _Step { template, name }

class _TemplateItem {
  const _TemplateItem({required this.template, this.isSelected = false});
  final ProviderTemplate? template;
  final bool isSelected;
}

/// 模板列表项
///
/// 横向布局对齐 ProviderListPage._ProviderCard：
/// 左图标容器（40×40，primaryDim 背景）+ 中信息列（名称/协议/baseUrl）
/// + 右 chevron_right。点击即进入命名步骤，无持续选中态视觉。
class _TemplateCard extends StatelessWidget {
  const _TemplateCard({required this.item, required this.onTap});

  final _TemplateItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final isCustom = item.template == null;
    final template = item.template;
    final protocol = template?.protocol ?? LlmProtocol.openaiCompatible;
    final protocolLabel = protocolDisplayName(protocol, t);

    return Container(
      decoration: BoxDecoration(
        color: item.isSelected ? colors.primaryDim : colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
        border: item.isSelected
            ? Border.all(color: colors.primary, width: 1.5)
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
          child: Padding(
            padding: const EdgeInsets.all(SimpleSpacing.sMd),
            child: Row(
              children: [
                // 图标容器
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: item.isSelected
                        ? colors.primary.withValues(alpha: 0.15)
                        : colors.primaryDim,
                    borderRadius:
                        BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
                  ),
                  child: Icon(
                    isCustom ? Icons.tune : Icons.cloud_outlined,
                    size: 20,
                    color: item.isSelected ? colors.primary : colors.muted,
                  ),
                ),
                const SizedBox(width: SimpleSpacing.sMd),
                // 信息列
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isCustom
                            ? t.settings.provider.templatePicker.custom
                            : template!.name,
                        style: SimpleTextStyles.body.copyWith(
                          fontWeight: FontWeight.w600,
                          color: colors.ink,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: SimpleSpacing.s2xs),
                      Text(
                        protocolLabel,
                        style: SimpleTextStyles.caption.copyWith(
                          color: colors.muted,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: SimpleSpacing.s2xs),
                      Text(
                        isCustom
                            ? t.settings.provider.templatePicker.customDesc
                            : template!.defaultBaseUrl,
                        style: SimpleTextStyles.overline.copyWith(
                          color: colors.faint,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: SimpleSpacing.sSm),
                Icon(
                  Icons.chevron_right,
                  color: colors.faint,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 协议只读显示（基于模板创建时）
class _ProtocolReadOnly extends StatelessWidget {
  const _ProtocolReadOnly({required this.protocol});
  final LlmProtocol protocol;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sSm,
        vertical: SimpleSpacing.sXs + 2,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.lock_outline, size: 14, color: colors.muted),
              const SizedBox(width: SimpleSpacing.sXs),
              Expanded(
                child: Text(
                  protocolDisplayName(protocol, t),
                  style: SimpleTextStyles.bodySm.copyWith(color: colors.ink),
                ),
              ),
            ],
          ),
          const SizedBox(height: SimpleSpacing.sXs),
          Text(
            t.settings.provider.protocolReadOnly,
            style: SimpleTextStyles.caption.copyWith(color: colors.muted),
          ),
        ],
      ),
    );
  }
}

/// 协议选择器（自定义创建时，4 选 1）
class _ProtocolSelector extends StatelessWidget {
  const _ProtocolSelector({
    required this.protocol,
    required this.onChanged,
  });

  final LlmProtocol protocol;
  final ValueChanged<LlmProtocol> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    return Wrap(
      spacing: SimpleSpacing.sXs,
      runSpacing: SimpleSpacing.sXs,
      children: LlmProtocol.values.map((p) {
        final selected = p == protocol;
        return _ProtocolChip(
          label: protocolDisplayName(p, t),
          selected: selected,
          onTap: () => onChanged(p),
        );
      }).toList(),
    );
  }
}

class _ProtocolChip extends StatelessWidget {
  const _ProtocolChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return Material(
      color: selected ? colors.primaryDim : colors.surfaceVariant,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: SimpleSpacing.sSm + 2,
            vertical: SimpleSpacing.sXs,
          ),
          decoration: BoxDecoration(
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
            border: selected
                ? Border.all(color: colors.primary, width: 1.5)
                : Border.all(color: colors.divider),
          ),
          child: Text(
            label,
            style: SimpleTextStyles.caption.copyWith(
              color: selected ? colors.primary : colors.muted,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}

class _Grabber extends StatelessWidget {
  const _Grabber();

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return Container(
      margin: const EdgeInsets.only(
        top: SimpleSpacing.sXs,
        bottom: SimpleSpacing.s2xs,
      ),
      width: 32,
      height: 4,
      decoration: BoxDecoration(
        color: colors.faint.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
      ),
    );
  }
}
