import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 清除所有数据示意图（2026-07-27 新增）。
///
/// 用于「清除所有数据」wiki 页顶部主视觉。
///
/// 设计：
/// - 上段：会清空的 4 类表（error 色调）
/// - 下段：会保留的 2 类配置（success 色调）
class ClearDataDiagram extends StatelessWidget {
  const ClearDataDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 上段：会清空（10 张表归为 4 类）
        Container(
          padding: const EdgeInsets.all(SimpleSpacing.sMd),
          decoration: BoxDecoration(
            color: colors.error.withValues(alpha: 0.06),
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
            border: Border.all(color: colors.error.withValues(alpha: 0.25)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.delete_forever_outlined,
                    size: 16,
                    color: colors.error,
                  ),
                  const SizedBox(width: SimpleSpacing.s2xs),
                  Flexible(
                    child: Text(
                      t.help.clearData.diagramClearTitle,
                      style: SimpleTextStyles.bodySm.copyWith(
                        color: colors.error,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              _ClearItem(
                label: t.help.clearData.clearTableSessions,
                desc: t.help.clearData.clearTableSessionsDesc,
              ),
              _ClearItem(
                label: t.help.clearData.clearTableMemory,
                desc: t.help.clearData.clearTableMemoryDesc,
              ),
              _ClearItem(
                label: t.help.clearData.clearTableCompaction,
                desc: t.help.clearData.clearTableCompactionDesc,
              ),
              _ClearItem(
                label: t.help.clearData.clearTableFailure,
                desc: t.help.clearData.clearTableFailureDesc,
              ),
            ],
          ),
        ),
        const SizedBox(height: SimpleSpacing.sMd),

        // 下段：会保留
        Container(
          padding: const EdgeInsets.all(SimpleSpacing.sMd),
          decoration: BoxDecoration(
            color: colors.success.withValues(alpha: 0.08),
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
            border: Border.all(color: colors.success.withValues(alpha: 0.3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.shield_outlined, size: 16, color: colors.success),
                  const SizedBox(width: SimpleSpacing.s2xs),
                  Flexible(
                    child: Text(
                      t.help.clearData.diagramKeepTitle,
                      style: SimpleTextStyles.bodySm.copyWith(
                        color: colors.success,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              _KeepItem(
                icon: Icons.cloud_outlined,
                label: t.help.clearData.keepPresets,
                desc: t.help.clearData.keepPresetsDesc,
              ),
              _KeepItem(
                icon: Icons.description_outlined,
                label: t.help.clearData.keepTemplates,
                desc: t.help.clearData.keepTemplatesDesc,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ClearItem extends StatelessWidget {
  const _ClearItem({required this.label, required this.desc});

  final String label;
  final String desc;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SimpleSpacing.s2xs),
      child: Row(
        children: [
          Icon(Icons.close_rounded, size: 14, color: colors.error),
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
        ],
      ),
    );
  }
}

class _KeepItem extends StatelessWidget {
  const _KeepItem({
    required this.icon,
    required this.label,
    required this.desc,
  });

  final IconData icon;
  final String label;
  final String desc;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SimpleSpacing.s2xs),
      child: Row(
        children: [
          Icon(Icons.check_rounded, size: 14, color: colors.success),
          const SizedBox(width: SimpleSpacing.sSm),
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: colors.success.withValues(alpha: 0.12),
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
            ),
            child: Icon(icon, color: colors.success, size: 16),
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
        ],
      ),
    );
  }
}
