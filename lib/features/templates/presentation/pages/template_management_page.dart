import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/components/simple_app_bar.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 模板管理页面（设置子页面，含筛选/创建/编辑/删除/复制）
class TemplateManagementPage extends ConsumerStatefulWidget {
  const TemplateManagementPage({super.key});

  @override
  ConsumerState<TemplateManagementPage> createState() =>
      _TemplateManagementPageState();
}

class _TemplateManagementPageState
    extends ConsumerState<TemplateManagementPage> {
  TemplateKind? _filterKind;

  @override
  void initState() {
    super.initState();
    Future.microtask(
      () {
        // 已有数据时静默刷新（不闪全屏 spinner）。
        final hasData = ref.read(settingsNotifierProvider).presets.isNotEmpty;
        return ref
            .read(settingsNotifierProvider.notifier)
            .refresh(silent: hasData);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    // 仅订阅本页消费的字段切片：其它设置字段的变更不再触发本页重建
    final templates = ref.watch(
      settingsNotifierProvider.select((s) => s.templates),
    );
    final isLoading = ref.watch(
      settingsNotifierProvider.select((s) => s.isLoading),
    );

    final filteredTemplates = _filterKind == null
        ? templates
        : templates.where((t) => t.kind == _filterKind).toList();

    return Scaffold(
      backgroundColor: context.scaffoldBgOf(context.lm.palette.bg),
      appBar: SimpleAppBar(
        title: t.settings.template.title,
      ),
      body: LmMeasure(
        maxWidth: LmLayout.listMeasure,
        child: Column(
          children: [
            // 筛选 Chips
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _FilterChip(
                      label: t.settings.template.filterAll,
                      selected: _filterKind == null,
                      onSelected: () => setState(() => _filterKind = null),
                    ),
                    const SizedBox(width: 8),
                    _FilterChip(
                      label: t.settings.template.type.systemPrompt,
                      selected: _filterKind == TemplateKind.systemPrompt,
                      onSelected: () => setState(
                        () => _filterKind = TemplateKind.systemPrompt,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            // 模板列表
            Expanded(
              child: _buildList(context, isLoading, filteredTemplates),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showTemplateDialog(context),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildList(
    BuildContext context,
    bool isLoading,
    List<Template> templates,
  ) {
    final colors = context.lm.palette;

    if (isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (templates.isEmpty) {
      final t = Translations.of(context);
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.description_outlined,
              size: 64,
              color: colors.faint,
            ),
            const SizedBox(height: 16),
            Text(
              t.settings.template.emptyList,
              style: SimpleTextStyles.caption,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 80),
      itemCount: templates.length,
      itemBuilder: (context, index) {
        final template = templates[index];
        return _TemplateCard(
          template: template,
          onEdit: () => _showTemplateDialog(context, template: template),
          onCopy: () => _copyTemplate(template),
          onDelete: template.isBuiltIn ? null : () => _confirmDelete(template),
        );
      },
    );
  }

  Future<void> _showTemplateDialog(
    BuildContext context, {
    Template? template,
  }) async {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final isEdit = template != null;
    final nameController = TextEditingController(text: template?.name ?? '');
    final contentController =
        TextEditingController(text: template?.content ?? '');
    var selectedKind = template?.kind ?? TemplateKind.systemPrompt;
    // 名称必填校验错误文案；null = 无错误。
    // 用户输入时实时清除错误提示，保存时若仍为空则显示。
    String? nameError;

    final result = await showLmDialog<_TemplateFormData>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(
            isEdit ? t.settings.template.edit : t.settings.template.add,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: !isEdit,
                  textInputAction: TextInputAction.next,
                  // TP13-1：内置模板不可修改——
                  // 此前可编辑可保存，但仓储对 isBuiltIn 抛错被吞，弹窗正常
                  // 关闭零反馈（保存必然失败）。
                  readOnly: isEdit && template.isBuiltIn,
                  decoration: InputDecoration(
                    labelText: t.settings.template.name,
                    hintText: t.settings.template.nameHint,
                    errorText: nameError,
                  ),
                  onChanged: (value) {
                    // 用户开始输入即清除错误提示
                    if (nameError != null && value.trim().isNotEmpty) {
                      setDialogState(() => nameError = null);
                    }
                  },
                ),
                const SizedBox(height: 12),
                // 类型选择
                DropdownButtonFormField<TemplateKind>(
                  initialValue: selectedKind,
                  decoration: InputDecoration(
                    // CF-6：类型下拉此前错用「全部」筛选文案
                    labelText: t.settings.template.typeLabel,
                  ),
                  // isExpanded: true 防止下拉项文字过长时触发 RenderFlex overflow
                  isExpanded: true,
                  items: [
                    DropdownMenuItem(
                      value: TemplateKind.systemPrompt,
                      child: Text(
                        t.settings.template.type.systemPrompt,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // 折叠模板（consolidation）
                    // 下架——编辑不生效，创建下拉不再提供该选项
                  ],
                  onChanged: isEdit
                      ? null
                      : (value) {
                          if (value != null) {
                            setDialogState(() => selectedKind = value);
                          }
                        },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: contentController,
                  readOnly: isEdit && template.isBuiltIn,
                  decoration: InputDecoration(
                    labelText: t.settings.template.content,
                    hintText: t.settings.template.contentHint,
                  ),
                  maxLines: 6,
                ),
                if (isEdit && template.isBuiltIn) ...[
                  const SizedBox(height: 12),
                  Text(
                    t.settings.template.builtIn,
                    style: SimpleTextStyles.caption.copyWith(
                      color: colors.warning,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(t.common.cancel),
            ),
            ElevatedButton(
              // 名称必填：空则阻止保存并显示错误，不关闭对话框。
              // 这避免用户误以为已保存但实际未创建模板的情况。
              // TP13-1：内置模板保存禁用（仓储必拒且异常被吞零反馈）。
              onPressed: (isEdit && template.isBuiltIn)
                  ? null
                  : () {
                      final trimmedName = nameController.text.trim();
                      if (trimmedName.isEmpty) {
                        setDialogState(
                          () => nameError = t.settings.template.nameRequired,
                        );
                        return;
                      }
                      Navigator.of(ctx).pop(
                        _TemplateFormData(
                          name: trimmedName,
                          kind: selectedKind,
                          content: contentController.text.trim(),
                        ),
                      );
                    },
              child: Text(t.common.save),
            ),
          ],
        ),
      ),
    );

    if (result == null || !mounted) return;

    final notifier = ref.read(settingsNotifierProvider.notifier);
    // TP13-2：CRUD 失败反馈——此前异常只进
    // state.error 无任何消费者，页面不弹不打日志（TP13-1 的最坏触发场景）。
    if (isEdit) {
      final updated = await notifier.updateTemplate(
        template.templateId,
        name: result.name,
        content: result.content,
      );
      _reportTemplateOpFailure(updated, t);
    } else {
      final created = await notifier.createTemplate(
        name: result.name,
        kind: result.kind,
        content: result.content,
      );
      _reportTemplateOpFailure(created, t);
    }
  }

  /// TP13-2：失败（null=异常被 settings notifier 吞进 state.error）时弹
  /// floating Snackbar 并清除 error 供后续操作。
  void _reportTemplateOpFailure(Object? result, Translations t) {
    if (result != null || !mounted) return;
    ref.read(settingsNotifierProvider.notifier).clearError();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(t.settings.template.opFailed),
      ),
    );
  }

  Future<void> _copyTemplate(Template template) async {
    // TP13-3：副本名走 i18n（数据层默认中文 '(副本)' 绕过 slang，
    // 英文 locale 上线后仍是中文）
    final copied =
        await ref.read(settingsNotifierProvider.notifier).copyTemplate(
              template.templateId,
              newName: t.settings.template.copyOf(name: template.name),
            );
    _reportTemplateOpFailure(copied, t);
  }

  Future<void> _confirmDelete(Template template) async {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final confirmed = await showLmDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(t.common.delete),
        content: Text(
          t.settings.template.deleteConfirm(name: template.name),
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.common.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: colors.error),
            child: Text(t.common.delete),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final deleted = await ref
        .read(settingsNotifierProvider.notifier)
        .deleteTemplate(template.templateId);
    _reportTemplateOpFailure(deleted ? true : null, t);
  }
}

/// 模板表单数据
class _TemplateFormData {
  const _TemplateFormData({
    required this.name,
    required this.kind,
    required this.content,
  });

  final String name;
  final TemplateKind kind;
  final String content;
}

/// 筛选 Chip
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return ChoiceChip(
      label: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      selected: selected,
      onSelected: (_) => onSelected(),
      selectedColor: colors.primary.withValues(alpha: 0.2),
      backgroundColor: colors.surface,
      side: BorderSide(
        color: selected ? colors.primary : colors.divider,
      ),
      labelStyle: SimpleTextStyles.caption.copyWith(
        color: selected ? colors.primary : colors.muted,
      ),
    );
  }
}

/// 模板卡片
class _TemplateCard extends StatelessWidget {
  const _TemplateCard({
    required this.template,
    required this.onEdit,
    required this.onCopy,
    this.onDelete,
  });

  final Template template;
  final VoidCallback onEdit;
  final VoidCallback onCopy;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final kindLabel = switch (template.kind) {
      TemplateKind.systemPrompt => t.settings.template.type.systemPrompt,
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 第一行：名称 + 类型标签
            Row(
              children: [
                Expanded(
                  child: Text(
                    template.name,
                    style: SimpleTextStyles.body.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: colors.divider,
                    borderRadius:
                        BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
                  ),
                  child: Text(
                    kindLabel,
                    style: SimpleTextStyles.overline.copyWith(
                      color: colors.accent,
                      fontSize: 11,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 内容预览
            Text(
              template.content,
              style: SimpleTextStyles.caption,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            // 操作按钮
            Row(
              children: [
                _ActionButton(
                  icon: Icons.edit_outlined,
                  label: t.common.edit,
                  onTap: onEdit,
                ),
                const SizedBox(width: 8),
                _ActionButton(
                  icon: Icons.content_copy,
                  label: t.common.copy,
                  onTap: onCopy,
                ),
                if (onDelete != null) ...[
                  const SizedBox(width: 8),
                  _ActionButton(
                    icon: Icons.delete_outline,
                    label: t.common.delete,
                    onTap: onDelete,
                    color: colors.error,
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 操作按钮
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final effectiveColor = color ?? colors.muted;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: effectiveColor),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                style:
                    SimpleTextStyles.overline.copyWith(color: effectiveColor),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
