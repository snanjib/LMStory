import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 创建第一个故事流程示意图（2026-07-27 新增）。
///
/// 用于「创建第一个故事」wiki 页顶部主视觉。
///
/// 设计：
/// - 上段：3 步流程（点击新建故事 → 配置模型/提示词 → 发送首条消息启动四步生成）
/// - 下段：嵌入模型缺失时的 Banner 提示（warning 色虚线边框）
///
/// 视觉传达：新建故事 + 必要配置 + 嵌入模型提示
class FirstStoryFlowDiagram extends StatelessWidget {
  const FirstStoryFlowDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 上段：3 步流程
        Container(
          padding: const EdgeInsets.all(SimpleSpacing.sMd),
          decoration: BoxDecoration(
            color: colors.surfaceVariant,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
          ),
          child: Row(
            children: [
              Expanded(
                child: _FlowStep(
                  icon: Icons.add_circle_outline,
                  label: t.help.firstStory.flow1Label,
                  desc: t.help.firstStory.flow1Desc,
                  highlight: false,
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: colors.faint, size: 18),
              Expanded(
                child: _FlowStep(
                  icon: Icons.tune_outlined,
                  label: t.help.firstStory.flow2Label,
                  desc: t.help.firstStory.flow2Desc,
                  highlight: true,
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: colors.faint, size: 18),
              Expanded(
                child: _FlowStep(
                  icon: Icons.auto_stories,
                  label: t.help.firstStory.flow3Label,
                  desc: t.help.firstStory.flow3Desc,
                  highlight: false,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: SimpleSpacing.sMd),

        // 下段：嵌入模型缺失 Banner 提示
        Container(
          padding: const EdgeInsets.all(SimpleSpacing.sSm),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
            border: Border.all(color: colors.warning, width: 1.5),
          ),
          child: Row(
            children: [
              Icon(
                Icons.warning_amber_outlined,
                color: colors.warning,
                size: 18,
              ),
              const SizedBox(width: SimpleSpacing.s2xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.help.firstStory.bannerTitle,
                      style: SimpleTextStyles.bodySm.copyWith(
                        color: colors.warning,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      t.help.firstStory.bannerDesc,
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
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: SimpleSpacing.sSm,
                  vertical: SimpleSpacing.s2xs,
                ),
                decoration: BoxDecoration(
                  color: colors.warning,
                  borderRadius:
                      BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
                ),
                child: Text(
                  t.help.firstStory.bannerAction,
                  style: SimpleTextStyles.caption.copyWith(
                    color: colors.surface,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _FlowStep extends StatelessWidget {
  const _FlowStep({
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

    return Column(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: highlight ? colors.accent : colors.accentDim,
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            color: highlight ? colors.surface : colors.accent,
            size: 18,
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
          maxLines: 1,
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
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
