import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 消息流示意图（2026-07-27 新增）。
///
/// 用于「发送消息与流式输出」wiki 页顶部主视觉。
///
/// 设计：
/// - 左侧：输入区域结构（5 个区块从上到下）
/// - 右侧：流式输出时序（4 个节点：发送→占位气泡→首 token→流式更新）
///
/// 视觉传达：输入框结构完整 + 流式输出体验（避免空白等待）
class MessageFlowDiagram extends StatelessWidget {
  const MessageFlowDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 左侧：输入区域结构
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
                t.help.messageFlow.diagramInputLabel,
                style: SimpleTextStyles.bodySm.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              _InputBlock(
                icon: Icons.format_quote_outlined,
                label: t.help.messageFlow.blockQuoteLabel,
                desc: t.help.messageFlow.blockQuoteDesc,
                optional: true,
              ),
              _InputBlock(
                icon: Icons.attach_file_outlined,
                label: t.help.messageFlow.blockAttachLabel,
                desc: t.help.messageFlow.blockAttachDesc,
                optional: true,
              ),
              _InputBlock(
                icon: Icons.edit_outlined,
                label: t.help.messageFlow.blockInputFieldLabel,
                desc: t.help.messageFlow.blockInputFieldDesc,
                optional: false,
              ),
              _InputBlock(
                icon: Icons.add_circle_outline,
                label: t.help.messageFlow.blockToolbarLabel,
                desc: t.help.messageFlow.blockToolbarDesc,
                optional: false,
              ),
            ],
          ),
        ),
        const SizedBox(height: SimpleSpacing.sMd),

        // 右侧：流式输出时序
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
                t.help.messageFlow.diagramStreamLabel,
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
                    child: _StreamStep(
                      icon: Icons.send_outlined,
                      label: t.help.messageFlow.stream1Label,
                      desc: t.help.messageFlow.stream1Desc,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: colors.faint,
                    size: 16,
                  ),
                  Expanded(
                    child: _StreamStep(
                      icon: Icons.hourglass_top_outlined,
                      label: t.help.messageFlow.stream2Label,
                      desc: t.help.messageFlow.stream2Desc,
                      highlight: true,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: colors.faint,
                    size: 16,
                  ),
                  Expanded(
                    child: _StreamStep(
                      icon: Icons.text_fields,
                      label: t.help.messageFlow.stream3Label,
                      desc: t.help.messageFlow.stream3Desc,
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

class _InputBlock extends StatelessWidget {
  const _InputBlock({
    required this.icon,
    required this.label,
    required this.desc,
    required this.optional,
  });

  final IconData icon;
  final String label;
  final String desc;
  final bool optional;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SimpleSpacing.s2xs),
      child: Row(
        children: [
          Icon(icon, color: colors.primary, size: 18),
          const SizedBox(width: SimpleSpacing.sSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        label,
                        style: SimpleTextStyles.bodySm.copyWith(
                          color: colors.ink,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (optional) ...[
                      const SizedBox(width: SimpleSpacing.s2xs),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: colors.accentDim,
                          borderRadius: BorderRadius.circular(
                            context.lmUi.radius(LmCorner.full),
                          ),
                        ),
                        child: Text(
                          'opt',
                          style: SimpleTextStyles.caption.copyWith(
                            color: colors.accent,
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ],
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

class _StreamStep extends StatelessWidget {
  const _StreamStep({
    required this.icon,
    required this.label,
    required this.desc,
    this.highlight = false,
  });

  final IconData icon;
  final String label;
  final String desc;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Column(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: highlight ? colors.primary : colors.primaryDim,
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            color: highlight ? colors.surface : colors.primary,
            size: 16,
          ),
        ),
        const SizedBox(height: SimpleSpacing.s2xs),
        Text(
          label,
          style: SimpleTextStyles.caption.copyWith(
            color: colors.ink,
            fontWeight: FontWeight.w600,
            fontSize: 11,
          ),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          desc,
          style: SimpleTextStyles.caption.copyWith(
            color: colors.muted,
            fontSize: 10,
            height: 1.3,
          ),
          textAlign: TextAlign.center,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
