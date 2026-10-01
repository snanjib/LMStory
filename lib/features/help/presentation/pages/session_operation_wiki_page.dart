import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/session_operation_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 对话模式 wiki 子页 2.1：创建与切换会话（2026-07-27 新增）。
///
/// 介绍草稿会话机制、侧边栏 6 种操作、全局搜索、移动/桌面端差异。
///
/// 设计原则：
/// - 示意图优先，顶部主视觉展示生成→入库 + 侧边栏操作矩阵
/// - 6 步 WikiStepCard 列举核心操作
/// - 移动/桌面差异用对比卡片
class SessionOperationWikiPage extends StatelessWidget {
  const SessionOperationWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.sessionOpWiki.title,
      children: [
        // 引言
        Text(
          t.help.sessionOp.intro,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 主视觉
        WikiSectionTitle(
          title: t.help.sessionOp.flowTitle,
          subtitle: t.help.sessionOp.flowSubtitle,
        ),
        const SessionOperationDiagram(),

        // 6 步操作
        WikiSectionTitle(
          title: t.help.sessionOp.operationsTitle,
          subtitle: t.help.sessionOp.operationsSubtitle,
        ),
        WikiStepCard(
          step: 1,
          title: t.help.sessionOp.step1Title,
          body: t.help.sessionOp.step1Body,
        ),
        WikiStepCard(
          step: 2,
          title: t.help.sessionOp.step2Title,
          body: t.help.sessionOp.step2Body,
        ),
        WikiStepCard(
          step: 3,
          title: t.help.sessionOp.step3Title,
          body: t.help.sessionOp.step3Body,
        ),
        WikiStepCard(
          step: 4,
          title: t.help.sessionOp.step4Title,
          body: t.help.sessionOp.step4Body,
        ),
        WikiStepCard(
          step: 5,
          title: t.help.sessionOp.step5Title,
          body: t.help.sessionOp.step5Body,
        ),
        WikiStepCard(
          step: 6,
          title: t.help.sessionOp.step6Title,
          body: t.help.sessionOp.step6Body,
        ),

        // 全局搜索
        WikiSectionTitle(
          title: t.help.sessionOp.searchTitle,
          subtitle: '',
        ),
        Text(
          t.help.sessionOp.searchBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 平台差异
        WikiSectionTitle(
          title: t.help.sessionOp.platformTitle,
          subtitle: '',
        ),
        Text(
          t.help.sessionOp.platformBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
      ],
    );
  }
}
