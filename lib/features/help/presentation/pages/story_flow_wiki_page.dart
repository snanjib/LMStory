import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/flow_overview_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/flow_step_card.dart';
import 'package:lmstory/features/help/presentation/widgets/role_flow_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/visual_flow_timeline.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式 wiki 子页 1：四步生成流程（v2 图形化版）。
///
/// v2 重构：
/// - 顶部主流程图（6 节点竖向）
/// - 编辑部角色流程图（5 角色横向）
/// - 6 个增强步骤卡片（图标 + 输入/输出图 + 要点列表）
/// - 视觉时间轴（用户在屏幕看到的流程）
///
/// 设计原则：
/// - 拒绝大段文字，用图形示意图+少量补充文字
/// - 每个章节配独立图示，让用户一眼看清逻辑
/// - 间距稀疏，重点突出
class StoryFlowWikiPage extends StatelessWidget {
  const StoryFlowWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.flowWiki.title,
      children: [
        // 顶部：引言（短文）
        Text(
          t.help.flow.intro,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 区块 1：主流程图
        WikiSectionTitle(
          title: t.help.flow.overviewTitle,
          subtitle: t.help.flow.overviewSubtitle,
        ),
        const FlowOverviewDiagram(),

        // 区块 2：编辑部比喻
        WikiSectionTitle(
          title: t.help.flow.metaphorTitle,
          subtitle: t.help.flow.metaphorSubtitle,
        ),
        const RoleFlowDiagram(),

        // 区块 3：6 个步骤详解
        // v0.2.2：步骤顺序 提取→检索→生成→审查（可选）→摘要→入库
        FlowStepCard(
          step: 1,
          icon: Icons.search_outlined,
          title: t.help.flow.step1Title,
          input: t.help.flow.step1Input,
          output: t.help.flow.step1Output,
          keyPoints: t.help.flow.step1Points,
        ),
        FlowStepCard(
          step: 2,
          icon: Icons.library_books_outlined,
          title: t.help.flow.step2Title,
          input: t.help.flow.step2Input,
          output: t.help.flow.step2Output,
          keyPoints: t.help.flow.step2Points,
        ),
        FlowStepCard(
          step: 3,
          icon: Icons.edit_outlined,
          title: t.help.flow.step3Title,
          input: t.help.flow.step3Input,
          output: t.help.flow.step3Output,
          keyPoints: t.help.flow.step3Points,
        ),
        FlowStepCard(
          step: 4,
          icon: Icons.auto_awesome_outlined,
          title: t.help.flow.step4Title,
          input: t.help.flow.step4Input,
          output: t.help.flow.step4Output,
          keyPoints: t.help.flow.step4Points,
        ),
        FlowStepCard(
          step: 5,
          icon: Icons.summarize_outlined,
          title: t.help.flow.step5Title,
          input: t.help.flow.step5Input,
          output: t.help.flow.step5Output,
          keyPoints: t.help.flow.step5Points,
        ),
        FlowStepCard(
          step: 6,
          icon: Icons.save_outlined,
          title: t.help.flow.step6Title,
          input: t.help.flow.step6Input,
          output: t.help.flow.step6Output,
          keyPoints: t.help.flow.step6Points,
        ),

        // 区块 4：视觉时间轴
        WikiSectionTitle(
          title: t.help.flow.visualFlowTitle,
          subtitle: t.help.flow.visualFlowSubtitle,
        ),
        // wiki 教学页展示完整流程（含压缩节点），reviewing 默认显示
        const VisualFlowTimeline(showCompacting: true),
      ],
    );
  }
}
