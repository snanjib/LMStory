import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 数据恢复与表修复示意图（2026-07-27 新增）。
///
/// 用于「数据恢复与表修复」wiki 页顶部主视觉。
///
/// 设计：
/// - 上段：孤立消息恢复 2 步流程（扫描 → 重组）
/// - 下段：表结构修复 3 个动作（创建表 / 补齐列 / 重建索引）
class DataRecoveryDiagram extends StatelessWidget {
  const DataRecoveryDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 上段：孤立消息恢复 2 步流程
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
                t.help.dataRecovery.diagramRecoveryTitle,
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
                    child: _RecoveryStep(
                      label: t.help.dataRecovery.recoveryStep1,
                      desc: t.help.dataRecovery.recoveryStep1Desc,
                      highlight: true,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: colors.faint,
                    size: 18,
                  ),
                  Expanded(
                    child: _RecoveryStep(
                      label: t.help.dataRecovery.recoveryStep2,
                      desc: t.help.dataRecovery.recoveryStep2Desc,
                      highlight: false,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              Row(
                children: [
                  Icon(
                    Icons.check_circle_outline,
                    size: 14,
                    color: colors.success,
                  ),
                  const SizedBox(width: SimpleSpacing.s2xs),
                  Expanded(
                    child: Text(
                      '${t.help.dataRecovery.recoveryResult}：${t.help.dataRecovery.recoveryResultDesc}',
                      style: SimpleTextStyles.caption.copyWith(
                        color: colors.muted,
                        fontSize: 11,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: SimpleSpacing.sMd),

        // 下段：表结构修复 3 个动作
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
                t.help.dataRecovery.diagramRepairTitle,
                style: SimpleTextStyles.bodySm.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: SimpleSpacing.s2xs),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: SimpleSpacing.sSm,
                  vertical: SimpleSpacing.s2xs,
                ),
                decoration: BoxDecoration(
                  color: colors.primaryDim,
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.shield_outlined,
                      size: 14,
                      color: colors.primary,
                    ),
                    const SizedBox(width: SimpleSpacing.s2xs),
                    Flexible(
                      child: Text(
                        '${t.help.dataRecovery.repairStrategy}：${t.help.dataRecovery.repairStrategyDesc}',
                        style: SimpleTextStyles.caption.copyWith(
                          color: colors.primary,
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
              const SizedBox(height: SimpleSpacing.sSm),
              _RepairAction(
                index: 1,
                label: t.help.dataRecovery.repairAction1,
                desc: t.help.dataRecovery.repairAction1Desc,
              ),
              _RepairAction(
                index: 2,
                label: t.help.dataRecovery.repairAction2,
                desc: t.help.dataRecovery.repairAction2Desc,
              ),
              _RepairAction(
                index: 3,
                label: t.help.dataRecovery.repairAction3,
                desc: t.help.dataRecovery.repairAction3Desc,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RecoveryStep extends StatelessWidget {
  const _RecoveryStep({
    required this.label,
    required this.desc,
    required this.highlight,
  });

  final String label;
  final String desc;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sSm),
      decoration: BoxDecoration(
        color: highlight ? colors.primaryDim : colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        border: highlight ? null : Border.all(color: colors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: SimpleTextStyles.bodySm.copyWith(
              color: highlight ? colors.primary : colors.ink,
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
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _RepairAction extends StatelessWidget {
  const _RepairAction({
    required this.index,
    required this.label,
    required this.desc,
  });

  final int index;
  final String label;
  final String desc;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SimpleSpacing.s2xs),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: colors.primaryDim,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                '$index',
                style: SimpleTextStyles.caption.copyWith(
                  color: colors.primary,
                  fontWeight: FontWeight.w700,
                  fontSize: 11,
                ),
              ),
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
        ],
      ),
    );
  }
}
