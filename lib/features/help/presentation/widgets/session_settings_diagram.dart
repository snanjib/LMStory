import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 会话设置示意图（2026-07-27 新增）。
///
/// 用于「会话设置」wiki 页顶部主视觉。
///
/// 设计：
/// - 上段：三级配置优先级链（会话级 > 全局默认 > 内置兜底）
/// - 下段：会话设置 Sheet 的 4 个区段（模型与供应商 / 提示词 / 生成参数 / 上下文窗口）
///
/// 视觉传达：会话级覆盖全局 + 设置项分区
class SessionSettingsDiagram extends StatelessWidget {
  const SessionSettingsDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 上段：三级配置优先级链
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
                t.help.sessionSettings.diagramPriorityTitle,
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
                    child: _PriorityLevel(
                      icon: Icons.layers_outlined,
                      label: t.help.sessionSettings.level1Label,
                      desc: t.help.sessionSettings.level1Desc,
                      highlight: true,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: colors.faint,
                    size: 18,
                  ),
                  Expanded(
                    child: _PriorityLevel(
                      icon: Icons.public_outlined,
                      label: t.help.sessionSettings.level2Label,
                      desc: t.help.sessionSettings.level2Desc,
                      highlight: false,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: colors.faint,
                    size: 18,
                  ),
                  Expanded(
                    child: _PriorityLevel(
                      icon: Icons.build_outlined,
                      label: t.help.sessionSettings.level3Label,
                      desc: t.help.sessionSettings.level3Desc,
                      highlight: false,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: SimpleSpacing.sMd),

        // 下段：会话设置 Sheet 的 4 个区段
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
                t.help.sessionSettings.diagramSectionsTitle,
                style: SimpleTextStyles.bodySm.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              _SectionItem(
                icon: Icons.cloud_outlined,
                label: t.help.sessionSettings.sectionModel,
                desc: t.help.sessionSettings.sectionModelDesc,
              ),
              _SectionItem(
                icon: Icons.description_outlined,
                label: t.help.sessionSettings.sectionPrompt,
                desc: t.help.sessionSettings.sectionPromptDesc,
              ),
              _SectionItem(
                icon: Icons.tune_outlined,
                label: t.help.sessionSettings.sectionGen,
                desc: t.help.sessionSettings.sectionGenDesc,
              ),
              _SectionItem(
                icon: Icons.view_module_outlined,
                label: t.help.sessionSettings.sectionContext,
                desc: t.help.sessionSettings.sectionContextDesc,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PriorityLevel extends StatelessWidget {
  const _PriorityLevel({
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
            fontSize: 10,
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
            fontSize: 9,
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

class _SectionItem extends StatelessWidget {
  const _SectionItem({
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
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: colors.primaryDim,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
            ),
            child: Icon(icon, color: colors.primary, size: 16),
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
