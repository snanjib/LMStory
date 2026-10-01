import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页 5.8：生成参数（v0.2.2 新增）。
///
/// 解释温度/TopP/最大Token数/存在惩罚/频率惩罚 5 个生成参数的作用，
/// 及其作用范围（仅生成和审查阶段，结构化任务阶段使用固定参数）。
///
/// 设计原则：示意图优先，顶部主视觉展示 5 个参数徽章，下方逐项说明。
class GenerationParamsWikiPage extends StatelessWidget {
  const GenerationParamsWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.generationParamsWiki.title,
      children: [
        Text(
          t.help.generationParams.intro,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
        WikiSectionTitle(
          title: t.help.generationParams.diagramTitle,
          subtitle: t.help.generationParams.diagramSubtitle,
        ),
        const _GenerationParamsDiagram(),
        WikiSection(
          title: t.help.generationParams.param1Title,
          body: t.help.generationParams.param1Body,
        ),
        WikiSection(
          title: t.help.generationParams.param2Title,
          body: t.help.generationParams.param2Body,
        ),
        WikiSection(
          title: t.help.generationParams.param3Title,
          body: t.help.generationParams.param3Body,
        ),
        WikiSection(
          title: t.help.generationParams.param4Title,
          body: t.help.generationParams.param4Body,
        ),
        WikiSection(
          title: t.help.generationParams.param5Title,
          body: t.help.generationParams.param5Body,
        ),
        WikiSection(
          title: t.help.generationParams.scopeTitle,
          body: t.help.generationParams.scopeBody,
        ),
        WikiSection(
          title: t.help.generationParams.entryTitle,
          body: t.help.generationParams.entryBody,
        ),
      ],
    );
  }
}

/// 5 个生成参数徽章示意图。
///
/// 视觉传达：5 个参数用图标 + 名称的徽章平铺，直观展示参数集合。
class _GenerationParamsDiagram extends StatelessWidget {
  const _GenerationParamsDiagram();

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sMd),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
        border: Border.all(color: colors.divider),
      ),
      child: Wrap(
        spacing: SimpleSpacing.sSm,
        runSpacing: SimpleSpacing.sSm,
        children: [
          _Badge(
            icon: Icons.thermostat_outlined,
            label: t.help.generationParams.param1Title,
          ),
          _Badge(
            icon: Icons.science_outlined,
            label: t.help.generationParams.param2Title,
          ),
          _Badge(
            icon: Icons.straighten_outlined,
            label: t.help.generationParams.param3Title,
          ),
          _Badge(
            icon: Icons.new_label_outlined,
            label: t.help.generationParams.param4Title,
          ),
          _Badge(
            icon: Icons.repeat_outlined,
            label: t.help.generationParams.param5Title,
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sSm,
        vertical: SimpleSpacing.s2xs,
      ),
      decoration: BoxDecoration(
        color: colors.primaryDim,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: colors.primary, size: 14),
          const SizedBox(width: SimpleSpacing.s2xs),
          Flexible(
            child: Text(
              label,
              style: SimpleTextStyles.caption.copyWith(
                color: colors.ink,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
