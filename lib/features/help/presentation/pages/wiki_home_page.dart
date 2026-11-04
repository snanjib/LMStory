import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_data.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_entry_view.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_search_bar.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_view.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 主目录页（2026-07-26 新增）。
///
/// 作为整个软件的说明书入口，设计参考 iOS/Android 系统设置搜索：
/// - 顶部固定搜索框（不自动聚焦，避免移动端键盘弹出）
/// - 输入时实时过滤匹配（标题+副标题）
/// - 8 个章节分组，章节下有若干条目（全部可点击进入；「即将上线」
///   待建设机制已随移除，新增待建设条目时按需恢复）
///
/// 章节组织（用户视角分类）见 [buildWikiSections]。
class WikiHomePage extends StatefulWidget {
  const WikiHomePage({super.key});

  @override
  State<WikiHomePage> createState() => _WikiHomePageState();
}

class _WikiHomePageState extends State<WikiHomePage> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Scaffold(
      backgroundColor: context.scaffoldBgOf(colors.bg),
      appBar: context.lmUi.appBar(context, title: t.help.wikiHome.title),
      body: LmMeasure(
        maxWidth: LmLayout.listMeasure,
        child: Column(
          children: [
            WikiSearchBar(
              controller: _searchController,
              hint: t.help.wikiHome.searchHint,
              onChanged: (value) =>
                  setState(() => _query = value.toLowerCase()),
              onClear: () {
                _searchController.clear();
                setState(() => _query = '');
              },
            ),
            Expanded(
              child: _query.isEmpty
                  ? _buildSectionList(context)
                  : _buildSearchResultList(context),
            ),
          ],
        ),
      ),
    );
  }

  /// 全部章节列表（无搜索时显示）。
  Widget _buildSectionList(BuildContext context) {
    final sections = buildWikiSections(context);
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        SimpleSpacing.sLg,
        SimpleSpacing.sMd,
        SimpleSpacing.sLg,
        SimpleSpacing.s2xl,
      ),
      itemCount: sections.length,
      itemBuilder: (_, index) {
        return WikiSectionView(
          section: sections[index],
          isLast: index == sections.length - 1,
        );
      },
    );
  }

  /// 搜索结果列表（扁平化所有条目，过滤匹配）。
  Widget _buildSearchResultList(BuildContext context) {
    final allEntries = buildWikiSections(context)
        .expand((section) => section.entries)
        .toList();
    final filtered =
        allEntries.where((entry) => entry.searchText.contains(_query)).toList();

    if (filtered.isEmpty) {
      return _buildEmptyState(context);
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(
        SimpleSpacing.sLg,
        SimpleSpacing.sMd,
        SimpleSpacing.sLg,
        SimpleSpacing.s2xl,
      ),
      itemCount: filtered.length,
      itemBuilder: (_, index) {
        return Padding(
          padding: const EdgeInsets.only(bottom: SimpleSpacing.sSm),
          child: WikiEntryView(entry: filtered[index]),
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    // 居中布局防护（项目规则 §9/§10）：本页含搜索框（WikiSearchBar/TextField），
    // 键盘弹出时 Expanded 可视高度减少 30%-50%，裸 Center+Column 会溢出。
    // 使用 LayoutBuilder + SingleChildScrollView + ConstrainedBox(minHeight) 模式。
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.search_off_rounded, color: colors.faint, size: 56),
                const SizedBox(height: SimpleSpacing.sMd),
                Text(
                  t.help.wikiHome.noResults,
                  style: SimpleTextStyles.body.copyWith(color: colors.muted),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
