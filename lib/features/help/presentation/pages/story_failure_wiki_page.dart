import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式 wiki 子页 3：失败处理。
///
/// 通俗解释原子事务原则、各阶段失败处理、UI 保留时序、手动重试逻辑、
/// 事实层特殊失败降级。
///
/// 内容来源：用户产品 wiki，由设计文档 DOC-08/09/11 提炼。
class StoryFailureWikiPage extends StatelessWidget {
  const StoryFailureWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.failureWiki.title,
      children: [
        // 引言
        Text(
          t.help.failure.intro,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
        // 原子事务原则
        WikiSection(
          title: t.help.failure.atomicityTitle,
          body: t.help.failure.atomicityBody,
        ),
        // 各阶段失败处理
        WikiSection(
          title: t.help.failure.retryTableTitle,
          body: t.help.failure.retryTableBody,
        ),
        // UI 保留时序
        WikiSection(
          title: t.help.failure.uiRetentionTitle,
          body: t.help.failure.uiRetentionBody,
        ),
        // 手动重试逻辑
        WikiSection(
          title: t.help.failure.manualRetryTitle,
          body: t.help.failure.manualRetryBody,
        ),
        // 事实层特殊失败降级
        WikiSection(
          title: t.help.failure.factualFallbackTitle,
          body: t.help.failure.factualFallbackBody,
        ),
      ],
    );
  }
}
