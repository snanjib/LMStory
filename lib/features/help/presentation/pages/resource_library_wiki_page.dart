import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/resource_seed_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页：角色卡与世界书（资源库）（2026-08-19 新增，v0.3）。
///
/// 种子流程示意图 + 支持格式 + 只读语义 + 同名提示。
///
/// 措辞与项目定位一致：种子不是门票；兼容酒馆生态、不贬低。
class ResourceLibraryWikiPage extends StatelessWidget {
  const ResourceLibraryWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context).help.resourceLibrary;
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: Translations.of(context).help.resourceLibraryWiki.title,
      children: [
        Text(
          t.intro,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
        WikiSectionTitle(
          title: t.diagramTitle,
          subtitle: '',
        ),
        const ResourceSeedDiagram(),
        WikiSectionTitle(
          title: t.formatsTitle,
          subtitle: '',
        ),
        Text(
          t.formatsBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
        WikiSectionTitle(
          title: t.readonlyTitle,
          subtitle: '',
        ),
        Text(
          t.readonlyBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
        WikiSectionTitle(
          title: t.dupTitle,
          subtitle: '',
        ),
        Text(
          t.dupBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
        // 2026-09-16：AI 建卡（此前仅功能索引提及，本页缺收）
        WikiSectionTitle(
          title: t.aiTitle,
          subtitle: '',
        ),
        Text(
          t.aiBody,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),
      ],
    );
  }
}
