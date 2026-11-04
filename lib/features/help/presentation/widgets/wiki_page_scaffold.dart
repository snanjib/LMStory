import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';

/// Wiki 子页通用骨架：AppBar + 可滚动正文。
///
/// 3 个 wiki 子页（四步流程 / 记忆机制 / 失败处理）共用此骨架，
/// 子页只需传入 [title] 和 [children]。
///
/// 设计：
/// - 顶部 SimpleAppBar，左对齐标题，底部 divider
/// - 正文 ListView，水平 padding 16px，章节之间 24px 间距
/// - 不使用 Card 嵌套，让内容直接呼吸
class WikiPageScaffold extends StatelessWidget {
  const WikiPageScaffold({
    required this.title,
    required this.children,
    super.key,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Scaffold(
      backgroundColor: context.scaffoldBgOf(colors.bg),
      appBar: context.lmUi.appBar(context, title: title),
      body: LmMeasure(
        maxWidth: LmLayout.readingMeasure,
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(
            SimpleSpacing.sLg,
            SimpleSpacing.sLg,
            SimpleSpacing.sLg,
            SimpleSpacing.s2xl,
          ),
          itemCount: children.length,
          separatorBuilder: (_, __) =>
              const SizedBox(height: SimpleSpacing.sXl),
          itemBuilder: (_, index) => children[index],
        ),
      ),
    );
  }
}
