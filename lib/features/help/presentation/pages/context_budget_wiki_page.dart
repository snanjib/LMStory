import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页 4.5：上下文预算（v0.2.2 新增）。
///
/// 解释故事模式上下文的三段式结构（摘要前缀 + 原文区 + 检索区）
/// 及三个核心比例参数（压缩触发线 / 原文区下限 / 检索区比例）+
/// 单次请求 Token 上限的配置方法和效果。
///
/// 设计原则：示意图优先，顶部主视觉展示三段式结构，下方逐项说明。
class ContextBudgetWikiPage extends StatelessWidget {
  const ContextBudgetWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.contextBudgetWiki.title,
      children: [
        Text(
          t.help.contextBudget.intro,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
        WikiSectionTitle(
          title: t.help.contextBudget.diagramTitle,
          subtitle: t.help.contextBudget.diagramSubtitle,
        ),
        const _ContextBudgetDiagram(),
        WikiSection(
          title: t.help.contextBudget.param1Title,
          body: t.help.contextBudget.param1Body,
        ),
        WikiSection(
          title: t.help.contextBudget.param2Title,
          body: t.help.contextBudget.param2Body,
        ),
        WikiSection(
          title: t.help.contextBudget.param3Title,
          body: t.help.contextBudget.param3Body,
        ),
        WikiSection(
          title: t.help.contextBudget.limitTitle,
          body: t.help.contextBudget.limitBody,
        ),
        WikiSection(
          title: t.help.contextBudget.entryTitle,
          body: t.help.contextBudget.entryBody,
        ),
        // 故事模式移植上下文环形指示器 + 手动压缩（与导演共用组件）
        WikiSection(
          title: t.help.contextBudget.usageTitle,
          body: t.help.contextBudget.usageBody,
        ),
      ],
    );
  }
}

/// 上下文三段式结构示意图：摘要前缀 + 原文区 + 检索区纵向堆叠。
///
/// 视觉传达：三段占比不同（原文区最大），用色块高度差异体现。
class _ContextBudgetDiagram extends StatelessWidget {
  const _ContextBudgetDiagram();

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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Segment(
            color: colors.primaryDim,
            label: t.help.contextBudget.diagramPrefixLabel,
            desc: t.help.contextBudget.diagramPrefixDesc,
            height: 40,
          ),
          const SizedBox(height: SimpleSpacing.s2xs),
          _Segment(
            color: colors.surfaceVariant,
            label: t.help.contextBudget.diagramRecentLabel,
            desc: t.help.contextBudget.diagramRecentDesc,
            height: 56,
          ),
          const SizedBox(height: SimpleSpacing.s2xs),
          _Segment(
            color: colors.primaryDim,
            label: t.help.contextBudget.diagramRetrievalLabel,
            desc: t.help.contextBudget.diagramRetrievalDesc,
            height: 32,
          ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.color,
    required this.label,
    required this.desc,
    required this.height,
  });

  final Color color;
  final String label;
  final String desc;
  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      width: double.infinity,
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: SimpleSpacing.sSm),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
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
            style: SimpleTextStyles.caption.copyWith(color: colors.muted),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
