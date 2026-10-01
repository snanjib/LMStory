import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_radius.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 导出选项 BottomSheet
///
/// 多选导出内容（会话 / API 供应商 / 个人偏好）+ 独立的 API Key 开关。
/// 返回 [DataExportOptions]；用户取消返回 null。
class ExportOptionsSheet extends StatefulWidget {
  const ExportOptionsSheet({super.key});

  @override
  State<ExportOptionsSheet> createState() => _ExportOptionsSheetState();

  /// 以 BottomSheet 形式展示，返回用户选择；取消时返回 null。
  static Future<DataExportOptions?> show(BuildContext context) {
    return showLmSheet<DataExportOptions>(
      context: context,
      isScrollControlled: true,
      // 内容自绘 _Handle；shape 仅经典组合消费（琉璃形状由工厂锁定）。
      glassHandle: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(LmRadius.rXl),
        ),
      ),
      builder: (_) => const ExportOptionsSheet(),
    );
  }
}

class _ExportOptionsSheetState extends State<ExportOptionsSheet> {
  bool _includeSessions = true;
  bool _includePresets = false;
  bool _includePreferences = false;
  bool _includeApiKeys = false;
  bool _includeGlobalAssets = true; // 默认勾选

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          SimpleSpacing.sLg,
          SimpleSpacing.sMd,
          SimpleSpacing.sLg,
          SimpleSpacing.sLg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Handle(colors: colors),
            const SizedBox(height: SimpleSpacing.sMd),
            Text(
              t.settings.data.exportOptions.title,
              style: SimpleTextStyles.title2.copyWith(
                color: colors.ink,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: SimpleSpacing.sMd),
            _OptionTile(
              label: t.settings.data.exportOptions.sessions,
              value: _includeSessions,
              onChanged: (v) => setState(() => _includeSessions = v),
            ),
            _OptionTile(
              label: t.settings.data.exportOptions.presets,
              value: _includePresets,
              onChanged: (v) => setState(() {
                _includePresets = v;
                if (!v) _includeApiKeys = false;
              }),
            ),
            _OptionTile(
              label: t.settings.data.exportOptions.preferences,
              value: _includePreferences,
              onChanged: (v) => setState(() => _includePreferences = v),
            ),
            // 第四选项——全局世界资产（默认勾选）
            _OptionTile(
              label: t.settings.data.exportOptions.globalAssets,
              value: _includeGlobalAssets,
              onChanged: (v) => setState(() => _includeGlobalAssets = v),
            ),
            const Divider(height: SimpleSpacing.sXl),
            // API Key 独立开关：仅当选择 API 供应商时可用
            Opacity(
              opacity: _includePresets ? 1.0 : 0.5,
              child: _SwitchTile(
                label: t.settings.data.exportOptions.includeApiKeys,
                value: _includeApiKeys,
                onChanged: _includePresets
                    ? (v) => setState(() => _includeApiKeys = v)
                    : null,
              ),
            ),
            if (_includeApiKeys && _includePresets) ...[
              const SizedBox(height: SimpleSpacing.sSm),
              Container(
                padding: const EdgeInsets.all(SimpleSpacing.sMd),
                decoration: BoxDecoration(
                  color: colors.warning.withValues(alpha: 0.12),
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: colors.warning,
                    ),
                    const SizedBox(width: SimpleSpacing.sSm),
                    Expanded(
                      child: Text(
                        t.settings.data.exportOptions.apiKeyWarning,
                        style: SimpleTextStyles.caption.copyWith(
                          color: colors.warning,
                        ),
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: SimpleSpacing.sXl),
            _Actions(
              confirmLabel: t.settings.data.exportOptions.export,
              confirmEnabled:
                  _includeSessions || _includePresets || _includePreferences,
              onCancel: () => Navigator.of(context).pop(),
              onConfirm: () {
                final options = DataExportOptions(
                  includeSessions: _includeSessions,
                  includePresets: _includePresets,
                  includePreferences: _includePreferences,
                  includeApiKeys: _includeApiKeys,
                  includeGlobalAssets: _includeGlobalAssets,
                );
                if (options.isEmpty) return;
                Navigator.of(context).pop(options);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 导入模式 BottomSheet
///
/// 让用户在追加 / 覆盖两种模式间选择。返回 [ImportMode]；取消返回 null。
class ImportModeSheetResult {
  const ImportModeSheetResult({
    required this.mode,
    required this.importApiKeys,
  });

  final ImportMode mode;

  /// 是否导入备份中的 API Key（默认不导入，
  /// 含 Key 备份须在面板显式勾选才覆盖本机密钥）。
  final bool importApiKeys;
}

class ImportModeSheet extends StatefulWidget {
  const ImportModeSheet({
    super.key,
    this.backupSessionCount,
    this.backupContainsSecrets = false,
  });

  /// 备份中包含的会话数（修复 2026-08-23）。
  ///
  /// 已知时在覆盖模式警告中展示具体数量；单会话/空备份的覆盖
  /// 由页面层追加二次确认。
  final int? backupSessionCount;

  /// 备份是否携带 API Key（contains_secrets 标记或任一预设带
  /// api_key/apiKey 字段）。true 时面板显示风险提示与默认关闭的导入开关。
  final bool backupContainsSecrets;

  @override
  State<ImportModeSheet> createState() => _ImportModeSheetState();

  static Future<ImportModeSheetResult?> show(
    BuildContext context, {
    int? backupSessionCount,
    bool backupContainsSecrets = false,
  }) {
    return showLmSheet<ImportModeSheetResult>(
      context: context,
      isScrollControlled: true,
      // 内容自绘 _Handle；shape 仅经典组合消费（琉璃形状由工厂锁定）。
      glassHandle: false,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(LmRadius.rXl),
        ),
      ),
      builder: (_) => ImportModeSheet(
        backupSessionCount: backupSessionCount,
        backupContainsSecrets: backupContainsSecrets,
      ),
    );
  }
}

class _ImportModeSheetState extends State<ImportModeSheet> {
  ImportMode? _mode = ImportMode.append;
  bool _importApiKeys = false;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          SimpleSpacing.sLg,
          SimpleSpacing.sMd,
          SimpleSpacing.sLg,
          SimpleSpacing.sLg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Handle(colors: colors),
            const SizedBox(height: SimpleSpacing.sMd),
            Text(
              t.settings.data.importMode.title,
              style: SimpleTextStyles.title2.copyWith(
                color: colors.ink,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: SimpleSpacing.sMd),
            _ModeTile(
              title: t.settings.data.importMode.append,
              desc: t.settings.data.importMode.appendDesc,
              value: ImportMode.append,
              groupValue: _mode,
              onChanged: (v) => setState(() => _mode = v),
            ),
            _ModeTile(
              title: t.settings.data.importMode.overwrite,
              desc: t.settings.data.importMode.overwriteDesc,
              value: ImportMode.overwrite,
              groupValue: _mode,
              onChanged: (v) => setState(() => _mode = v),
              isDestructive: true,
            ),
            if (_mode == ImportMode.overwrite) ...[
              const SizedBox(height: SimpleSpacing.sSm),
              Container(
                padding: const EdgeInsets.all(SimpleSpacing.sMd),
                decoration: BoxDecoration(
                  color: colors.error.withValues(alpha: 0.12),
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 18,
                      color: colors.error,
                    ),
                    const SizedBox(width: SimpleSpacing.sSm),
                    Expanded(
                      child: Text(
                        //  修复：单会话/空备份覆盖时展示计数感知的强警示
                        (widget.backupSessionCount == 0)
                            ? t.settings.data.importMode.overwriteNoSessionsHint
                            : (widget.backupSessionCount != null &&
                                    widget.backupSessionCount! <= 1)
                                ? t.settings.data.importMode
                                    .overwriteSingleHint(
                                    n: widget.backupSessionCount!,
                                    count: widget.backupSessionCount!,
                                  )
                                : t.settings.data.importMode.overwriteWarning,
                        style: SimpleTextStyles.caption.copyWith(
                          color: colors.error,
                        ),
                        maxLines: 6,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: SimpleSpacing.sXs),
              // 快照安全网说明（中性色调——与上方
              // 红色危险警示区分，这是兜底而非鼓励）。
              // web 无本地备份目录，页面侧不注入
              // preImportSnapshot——承诺「会自动快照」的提示不得在无快照
              // 兜底的平台上渲染
              if (!kIsWeb)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.history_outlined,
                      size: 16,
                      color: colors.muted,
                    ),
                    const SizedBox(width: SimpleSpacing.sSm),
                    Expanded(
                      child: Text(
                        t.settings.data.importMode.snapshotHint,
                        style: SimpleTextStyles.caption.copyWith(
                          color: colors.muted,
                        ),
                      ),
                    ),
                  ],
                ),
            ],
            const SizedBox(height: SimpleSpacing.sXl),
            // 含 Key 备份——风险提示 + 默认关闭
            // 的导入开关（Key 是敏感凭据，显式勾选才覆盖本机密钥）
            if (widget.backupContainsSecrets) ...[
              const SizedBox(height: SimpleSpacing.sXs),
              Container(
                padding: const EdgeInsets.all(SimpleSpacing.sMd),
                decoration: BoxDecoration(
                  color: colors.error.withValues(alpha: 0.12),
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.key_outlined,
                      size: 18,
                      color: colors.error,
                    ),
                    const SizedBox(width: SimpleSpacing.sSm),
                    Expanded(
                      child: Text(
                        t.settings.data.importMode.secretsNotice,
                        style: SimpleTextStyles.caption.copyWith(
                          color: colors.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              CheckboxListTile(
                value: _importApiKeys,
                onChanged: (v) => setState(() => _importApiKeys = v ?? false),
                title: Text(
                  t.settings.data.importMode.importApiKeysLabel,
                  style: SimpleTextStyles.caption.copyWith(color: colors.ink),
                ),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
              ),
            ],
            _Actions(
              confirmLabel: t.common.confirm,
              confirmEnabled: _mode != null,
              onCancel: () => Navigator.of(context).pop(),
              onConfirm: () => Navigator.of(context).pop(
                ImportModeSheetResult(
                  mode: _mode!,
                  importApiKeys: _importApiKeys,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ==================== 共享内部组件 ====================

class _Handle extends StatelessWidget {
  const _Handle({required this.colors});

  final LmPalette colors;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: colors.divider,
          borderRadius:
              BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
        ),
      ),
    );
  }
}

class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return InkWell(
      onTap: () => onChanged(!value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: SimpleSpacing.sSm),
        child: Row(
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Checkbox(
                value: value,
                onChanged: (v) {
                  if (v != null) onChanged(v);
                },
                visualDensity: VisualDensity.compact,
                shape: RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
                ),
              ),
            ),
            const SizedBox(width: SimpleSpacing.sMd),
            Expanded(
              child: Text(
                label,
                style: SimpleTextStyles.body.copyWith(color: colors.ink),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  const _SwitchTile({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return MergeSemantics(
      child: InkWell(
        onTap: onChanged == null ? null : () => onChanged!(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: SimpleSpacing.sSm),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: SimpleTextStyles.body.copyWith(color: colors.ink),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Switch(
                value: value,
                onChanged: onChanged,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModeTile extends StatelessWidget {
  const _ModeTile({
    required this.title,
    required this.desc,
    required this.value,
    required this.groupValue,
    required this.onChanged,
    this.isDestructive = false,
  });

  final String title;
  final String desc;
  final ImportMode value;
  final ImportMode? groupValue;
  final ValueChanged<ImportMode> onChanged;
  final bool isDestructive;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final titleColor = isDestructive ? colors.error : colors.ink;
    final isSelected = groupValue == value;
    return InkWell(
      onTap: () => onChanged(value),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: SimpleSpacing.sSm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 24,
              height: 24,
              child: Icon(
                isSelected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 22,
                color: isDestructive ? colors.error : colors.primary,
              ),
            ),
            const SizedBox(width: SimpleSpacing.sMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: SimpleTextStyles.body.copyWith(
                      color: titleColor,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    desc,
                    style: SimpleTextStyles.caption.copyWith(
                      color: colors.muted,
                    ),
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.confirmLabel,
    required this.confirmEnabled,
    required this.onCancel,
    required this.onConfirm,
  });

  final String confirmLabel;
  final bool confirmEnabled;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    return Row(
      children: [
        Expanded(
          child: TextButton(
            onPressed: onCancel,
            style: TextButton.styleFrom(
              foregroundColor: colors.muted,
              minimumSize: const Size.fromHeight(44),
            ),
            child: Text(
              t.common.cancel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        const SizedBox(width: SimpleSpacing.sSm),
        Expanded(
          child: FilledButton(
            onPressed: confirmEnabled ? onConfirm : null,
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(44),
              shape: RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
              ),
            ),
            child: Text(
              confirmLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );
  }
}
