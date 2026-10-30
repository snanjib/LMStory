import 'package:flutter/material.dart';
import 'package:lmstory/core/meta/app_meta.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/help/presentation/widgets/version_history_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页 7.4：版本更新记录（2026-07-27 新增）。
class VersionHistoryWikiPage extends StatelessWidget {
  const VersionHistoryWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.versionHistoryWiki.title,
      children: [
        Text(
          // 版本号/Schema 号从代码真源注入（kAppVersion 对账 pubspec，
          // AppDatabase.currentSchemaVersion 对账 drift），文案不再手写数字
          t.help.versionHistory.intro(
            appVersion: kAppVersion,
            schemaVersion: AppDatabase.currentSchemaVersion,
          ),
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
        WikiSectionTitle(
          title: t.help.versionHistory.diagramTitle,
          subtitle: t.help.versionHistory.diagramSubtitle,
        ),
        const VersionHistoryDiagram(),
        WikiSectionTitle(title: t.help.versionHistory.v01Title, subtitle: ''),
        _VersionBlock(
          body: t.help.versionHistory.v01Body,
          color: colors.success,
        ),
        WikiSectionTitle(title: t.help.versionHistory.v02Title, subtitle: ''),
        _VersionBlock(
          body: t.help.versionHistory.v02Body,
          color: colors.warning,
        ),
        WikiSectionTitle(title: t.help.versionHistory.v03Title, subtitle: ''),
        _VersionBlock(
          body: t.help.versionHistory.v03Body,
          color: colors.muted,
        ),
        WikiSectionTitle(
          title: t.help.versionHistory.milestonesTitle,
          subtitle: '',
        ),
        for (final text in t.help.versionHistory.milestones)
          _MilestoneItem(text: text),
        WikiSectionTitle(title: t.help.versionHistory.entryTitle, subtitle: ''),
        Text(
          t.help.versionHistory.entryBody,
          style:
              SimpleTextStyles.body.copyWith(color: colors.muted, height: 1.7),
        ),
      ],
    );
  }
}

class _VersionBlock extends StatelessWidget {
  const _VersionBlock({required this.body, required this.color});

  final String body;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sSm),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
        border: Border.all(color: colors.divider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 4,
            constraints: const BoxConstraints(minHeight: 80),
            decoration: BoxDecoration(
              color: color,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
            ),
          ),
          const SizedBox(width: SimpleSpacing.sSm),
          Expanded(
            child: Text(
              body,
              style: SimpleTextStyles.bodySm.copyWith(
                color: colors.ink,
                height: 1.7,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MilestoneItem extends StatelessWidget {
  const _MilestoneItem({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 6),
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: colors.primary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: SimpleSpacing.sSm),
          Expanded(
            child: Text(
              text,
              style: SimpleTextStyles.caption.copyWith(
                color: colors.muted,
                fontSize: 11,
                height: 1.5,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
