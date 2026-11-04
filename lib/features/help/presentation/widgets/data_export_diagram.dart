import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 数据导出与导入示意图（2026-07-27 新增）。
///
/// 用于「数据导出与导入」wiki 页顶部主视觉。
///
/// 设计：
/// - 上段：3 类备份内容 + API Key 独立开关
/// - 下段：导入 2 种模式（追加 / 覆盖）
class DataExportDiagram extends StatelessWidget {
  const DataExportDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 上段：3 类备份内容 + API Key 开关
        Container(
          padding: const EdgeInsets.all(SimpleSpacing.sMd),
          decoration: BoxDecoration(
            color: colors.surfaceVariant,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.help.dataExport.diagramExportTitle,
                style: SimpleTextStyles.bodySm.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              _ExportItem(
                icon: Icons.forum_outlined,
                label: t.help.dataExport.exportItemSessions,
                desc: t.help.dataExport.exportItemSessionsDesc,
                highlight: true,
              ),
              _ExportItem(
                icon: Icons.cloud_outlined,
                label: t.help.dataExport.exportItemPresets,
                desc: t.help.dataExport.exportItemPresetsDesc,
                highlight: false,
              ),
              _ExportItem(
                icon: Icons.tune_outlined,
                label: t.help.dataExport.exportItemPreferences,
                desc: t.help.dataExport.exportItemPreferencesDesc,
                highlight: false,
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: SimpleSpacing.sSm,
                  vertical: SimpleSpacing.s2xs,
                ),
                decoration: BoxDecoration(
                  color: colors.warning.withValues(alpha: 0.12),
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.key_rounded, size: 14, color: colors.warning),
                    const SizedBox(width: SimpleSpacing.s2xs),
                    Flexible(
                      child: Text(
                        '${t.help.dataExport.exportApiKeySwitch}：${t.help.dataExport.exportApiKeySwitchDesc}',
                        style: SimpleTextStyles.caption.copyWith(
                          color: colors.warning,
                          fontWeight: FontWeight.w600,
                          fontSize: 11,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: SimpleSpacing.sMd),

        // 下段：导入 2 种模式
        Container(
          padding: const EdgeInsets.all(SimpleSpacing.sMd),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
            border: Border.all(color: colors.divider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.help.dataExport.diagramImportTitle,
                style: SimpleTextStyles.bodySm.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              Row(
                children: [
                  Expanded(
                    child: _ImportModeCard(
                      icon: Icons.add_circle_outline,
                      label: t.help.dataExport.importModeAppend,
                      desc: t.help.dataExport.importModeAppendDesc,
                      color: colors.success,
                    ),
                  ),
                  const SizedBox(width: SimpleSpacing.sSm),
                  Expanded(
                    child: _ImportModeCard(
                      icon: Icons.delete_forever_outlined,
                      label: t.help.dataExport.importModeOverwrite,
                      desc: t.help.dataExport.importModeOverwriteDesc,
                      color: colors.error,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ExportItem extends StatelessWidget {
  const _ExportItem({
    required this.icon,
    required this.label,
    required this.desc,
    required this.highlight,
  });

  final IconData icon;
  final String label;
  final String desc;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SimpleSpacing.s2xs),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: highlight ? colors.primary : colors.primaryDim,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
            ),
            child: Icon(
              icon,
              color: highlight ? colors.surface : colors.primary,
              size: 16,
            ),
          ),
          const SizedBox(width: SimpleSpacing.sSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: SimpleTextStyles.bodySm.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  desc,
                  style: SimpleTextStyles.caption.copyWith(
                    color: colors.muted,
                    fontSize: 11,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Icon(
            highlight ? Icons.check_box : Icons.check_box_outline_blank,
            color: highlight ? colors.primary : colors.faint,
            size: 18,
          ),
        ],
      ),
    );
  }
}

class _ImportModeCard extends StatelessWidget {
  const _ImportModeCard({
    required this.icon,
    required this.label,
    required this.desc,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String desc;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sSm),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(height: SimpleSpacing.s2xs),
          Text(
            label,
            style: SimpleTextStyles.bodySm.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            desc,
            style: SimpleTextStyles.caption.copyWith(
              color: colors.muted,
              fontSize: 11,
              height: 1.4,
            ),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
