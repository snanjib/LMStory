import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/shared/components/lm_arrival.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';

/// 可折叠的设置分区（DOC-14 §3.4）。
///
/// 故事模式会话设置「两级视觉层次」中的**分区（强边界）**：填充圆角卡 +
/// 可点击标题行（标题 + 展开箭头）+ 动画展开体。配合 [SettingsTile]
/// （单项弱边界）形成层次区分，解决扁平列表"单项边界感弱"的问题。
///
/// 折叠状态由父组件（会话设置 sheet）持有并持久化（全局记忆，DOC-14 §3.4），
/// 本组件仅负责展示与动画。
class CollapsibleSettingsSection extends StatelessWidget {
  const CollapsibleSettingsSection({
    required this.title,
    required this.isExpanded,
    required this.onToggle,
    required this.child,
    super.key,
  });

  final String title;
  final bool isExpanded;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: IntermediateSpacing.sLg,
                vertical: IntermediateSpacing.sMd,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: LmNarrativeTextStyles.narrativeDisplay.copyWith(
                        color: colors.ink,
                        fontSize: 20,
                        height: 1.35,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  AnimatedRotation(
                    turns: isExpanded ? 0.5 : 0,
                    duration: LmMotion.durationFor(context, LmMotion.fold),
                    curve: LmMotion.easeBoth,
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      color: colors.muted,
                      size: 20,
                    ),
                  ),
                ],
              ),
            ),
          ),
          AnimatedSize(
            duration: LmMotion.reducedMotion(context)
                ? LmMotion.instant
                : LmMotion.fold,
            alignment: Alignment.topCenter,
            curve: LmMotion.easeBoth,
            child: isExpanded
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(
                      IntermediateSpacing.sMd,
                      0,
                      IntermediateSpacing.sMd,
                      IntermediateSpacing.sMd,
                    ),
                    child: LmArrival(child: child),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }
}

/// 设置单项瓦片（DOC-14 §3.4）。
///
/// 故事模式会话设置「两级视觉层次」中的**单项（弱边界）**：内嵌描边圆角
/// 容器包络单个配置项，使分区内每个配置项都有清晰边界，与外层分区卡
/// （[CollapsibleSettingsSection]）形成层次区分。
class SettingsTile extends StatelessWidget {
  const SettingsTile({
    required this.child,
    this.padding,
    super.key,
  });

  final Widget child;

  /// 瓦片内边距，默认与配置行对齐。
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return Container(
      width: double.infinity,
      padding: padding ??
          const EdgeInsets.symmetric(
            horizontal: IntermediateSpacing.sMd,
            vertical: IntermediateSpacing.sSm,
          ),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
        border: Border.all(color: colors.divider),
      ),
      child: child,
    );
  }
}
