import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 诊断信息示意图（2026-07-27 新增）。
///
/// 用于「诊断信息」wiki 页顶部主视觉。
///
/// 设计：
/// - 上段：5 个区块概览（状态概览 + 日志级别 + 调试开关 + 运行日志 + 失败历史）
/// - 下段：日志文件 3 个特性（来源 / 末尾 500 行 / 按级别着色）
class DiagnosticsDiagram extends StatelessWidget {
  const DiagnosticsDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 上段：5 个区块
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
              // 区块 1：状态概览
              _BlockHeader(
                index: 1,
                title: t.help.diagnostics.diagramOverviewTitle,
              ),
              const SizedBox(height: SimpleSpacing.s2xs),
              _BlockRow(
                label: t.help.diagnostics.overviewFailure,
                desc: t.help.diagnostics.overviewFailureDesc,
                color: colors.error,
              ),
              _BlockRow(
                label: t.help.diagnostics.overviewLevel,
                desc: t.help.diagnostics.overviewLevelDesc,
                color: colors.primary,
              ),
              const Divider(height: SimpleSpacing.sMd),

              // 区块 2：日志级别
              _BlockHeader(
                index: 2,
                title: t.help.diagnostics.diagramLevelTitle,
              ),
              const SizedBox(height: SimpleSpacing.s2xs),
              Wrap(
                spacing: SimpleSpacing.sXs,
                runSpacing: SimpleSpacing.sXs,
                children: [
                  _LevelChip(
                    label: t.help.diagnostics.levelDebug,
                    color: colors.faint,
                  ),
                  _LevelChip(
                    label: t.help.diagnostics.levelInfo,
                    color: colors.success,
                  ),
                  _LevelChip(
                    label: t.help.diagnostics.levelWarn,
                    color: colors.warning,
                  ),
                  _LevelChip(
                    label: t.help.diagnostics.levelError,
                    color: colors.error,
                  ),
                ],
              ),
              const Divider(height: SimpleSpacing.sMd),

              // 区块 3：调试开关
              _BlockHeader(
                index: 3,
                title: t.help.diagnostics.diagramDebugTitle,
              ),
              const SizedBox(height: SimpleSpacing.s2xs),
              _SwitchRow(label: t.help.diagnostics.debugPrompts),
              _SwitchRow(label: t.help.diagnostics.debugResponses),
              _SwitchRow(label: t.help.diagnostics.debugMemories),
              _SwitchRow(label: t.help.diagnostics.debugKeywords),
              _SwitchRow(label: t.help.diagnostics.debugPayloads),
              const Divider(height: SimpleSpacing.sMd),

              // 区块 4：运行日志
              _BlockHeader(
                index: 4,
                title: t.help.diagnostics.diagramLogTitle,
              ),
              const SizedBox(height: SimpleSpacing.s2xs),
              _BlockRow(
                label: t.help.diagnostics.logSource,
                desc: t.help.diagnostics.logSourceDesc,
                color: colors.primary,
              ),
              _BlockRow(
                label: t.help.diagnostics.logTail,
                desc: t.help.diagnostics.logTailDesc,
                color: colors.primary,
              ),
              _BlockRow(
                label: t.help.diagnostics.logColor,
                desc: t.help.diagnostics.logColorDesc,
                color: colors.primary,
              ),
              const Divider(height: SimpleSpacing.sMd),

              // 区块 5：失败历史
              _BlockHeader(
                index: 5,
                title: t.help.diagnostics.diagramFailureTitle,
              ),
              const SizedBox(height: SimpleSpacing.s2xs),
              _BlockRow(
                label: t.help.diagnostics.failureSource,
                desc: t.help.diagnostics.failureSourceDesc,
                color: colors.error,
              ),
              _BlockRow(
                label: t.help.diagnostics.failureDetail,
                desc: t.help.diagnostics.failureDetailDesc,
                color: colors.error,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _BlockHeader extends StatelessWidget {
  const _BlockHeader({required this.index, required this.title});

  final int index;
  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Row(
      children: [
        Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            color: colors.primary,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              '$index',
              style: SimpleTextStyles.caption.copyWith(
                color: colors.surface,
                fontWeight: FontWeight.w700,
                fontSize: 11,
              ),
            ),
          ),
        ),
        const SizedBox(width: SimpleSpacing.sSm),
        Flexible(
          child: Text(
            title,
            style: SimpleTextStyles.bodySm.copyWith(
              color: colors.ink,
              fontWeight: FontWeight.w700,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class _BlockRow extends StatelessWidget {
  const _BlockRow({
    required this.label,
    required this.desc,
    required this.color,
  });

  final String label;
  final String desc;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 4),
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: SimpleSpacing.sSm),
          Expanded(
            child: RichText(
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              text: TextSpan(
                style: SimpleTextStyles.caption.copyWith(
                  color: colors.muted,
                  fontSize: 11,
                  height: 1.5,
                ),
                children: [
                  TextSpan(
                    text: '$label：',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: colors.ink,
                    ),
                  ),
                  TextSpan(text: desc),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LevelChip extends StatelessWidget {
  const _LevelChip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sSm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: SimpleTextStyles.caption.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
          fontSize: 11,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Icon(
            Icons.toggle_off_outlined,
            size: 16,
            color: colors.faint,
          ),
          const SizedBox(width: SimpleSpacing.s2xs),
          Expanded(
            child: Text(
              label,
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
    );
  }
}
