import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/components/simple_app_bar.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/system/lm_focus_order.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/features/diagnostics/presentation/pages/diagnostics_page.dart';
import 'package:lmstory/features/help/presentation/pages/wiki_home_page.dart';
import 'package:lmstory/features/resource_library/presentation/pages/resource_library_page.dart';
import 'package:lmstory/features/settings/presentation/pages/chat_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/data_management_page.dart';
import 'package:lmstory/features/settings/presentation/pages/director_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/general_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_settings_page.dart';
import 'package:lmstory/features/settings/presentation/widgets/adaptive_setting_card.dart';
import 'package:lmstory/features/templates/presentation/pages/template_management_page.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 设置主页（重构后）。
///
/// 一级菜单 9 项：
/// 通用设置 / 对话模式设置 / 故事模式设置 / 导演模式设置 / 提示词模板 /
/// 资源库 / 数据管理 / 诊断信息 / 帮助（合并新手引导入口 + 故事模式原理
/// wiki，置底可重复访问）。
///
/// 变更说明：
/// - 供应商入口 → 移入「通用设置」顶部
/// - 默认模型入口 → 拆分到「对话模式设置」（卡片入口）与「故事模式设置」（dropdown）
/// - 新手引导入口 → 已合并进「帮助」（2026-07-26 重构）
/// - 导演模式设置 / 资源库为 0.3 新增卡片（注释口径随之更新）
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Translations.of(context);

    return Scaffold(
      backgroundColor:
          context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
      appBar: SimpleAppBar(title: t.settings.title),
      // 单列内容页的 Tab 顺序显式声明（不靠「代码构造顺序碰巧对」）：
      // 页内次序由阅读顺序策略给出，区域本身则明确归入 content。
      body: LmFocusTraversal(
        child: LmFocusOrder(
          region: LmFocusRegion.content,
          child: LmMeasure(
            child: ListView(
              padding: const EdgeInsets.all(SimpleSpacing.sLg),
              children: [
                AdaptiveSettingCard(
                  icon: Icons.tune_outlined,
                  title: t.settings.general.title,
                  subtitle: t.settings.general.entrySubtitle,
                  onTap: () =>
                      _navigateTo(context, const GeneralSettingsPage()),
                ),
                const SizedBox(height: SimpleSpacing.sMd),
                AdaptiveSettingCard(
                  icon: Icons.chat_outlined,
                  title: t.settings.chatSettings.title,
                  subtitle: t.settings.chatSettings.entrySubtitle,
                  onTap: () => _navigateTo(context, const ChatSettingsPage()),
                ),
                const SizedBox(height: SimpleSpacing.sMd),
                AdaptiveSettingCard(
                  icon: Icons.auto_stories_outlined,
                  title: t.settings.intermediate.title,
                  subtitle: t.settings.intermediate.entrySubtitle,
                  onTap: () => _navigateTo(
                    context,
                    const IntermediateSettingsPage(),
                  ),
                ),
                const SizedBox(height: SimpleSpacing.sMd),
                // 导演模式设置（导演设置体系 P2：自包含单页，入口开关随页迁入）
                AdaptiveSettingCard(
                  icon: Icons.movie_filter_outlined,
                  title: t.settings.director.title,
                  subtitle: t.settings.director.entrySubtitle,
                  onTap: () => _navigateTo(
                    context,
                    const DirectorSettingsPage(),
                  ),
                ),
                const SizedBox(height: SimpleSpacing.sMd),
                AdaptiveSettingCard(
                  icon: Icons.description_outlined,
                  title: t.settings.template.title,
                  // 专用副标题键（原借用 filterAll 筛选文案）
                  subtitle: t.settings.template.entrySubtitle,
                  onTap: () =>
                      _navigateTo(context, const TemplateManagementPage()),
                ),
                const SizedBox(height: SimpleSpacing.sMd),
                AdaptiveSettingCard(
                  // 换专属图标（原与故事模式设置撞车）
                  icon: Icons.library_books_outlined,
                  title: t.settings.resourceLibrary.title,
                  subtitle: t.settings.resourceLibrary.entrySubtitle,
                  onTap: () =>
                      _navigateTo(context, const ResourceLibraryPage()),
                ),
                const SizedBox(height: SimpleSpacing.sMd),
                AdaptiveSettingCard(
                  icon: Icons.storage_outlined,
                  title: t.settings.data.title,
                  // 专用副标题键（原借用 export 动作文案）
                  subtitle: t.settings.data.entrySubtitle,
                  onTap: () => _navigateTo(context, const DataManagementPage()),
                ),
                const SizedBox(height: SimpleSpacing.sMd),
                AdaptiveSettingCard(
                  icon: Icons.bug_report_outlined,
                  title: t.settings.diagnostics.title,
                  subtitle: t.settings.diagnostics.entrySubtitle,
                  onTap: () => _navigateTo(context, const DiagnosticsPage()),
                ),
                const SizedBox(height: SimpleSpacing.sMd),
                // 帮助入口（2026-07-27 简化）：直接跳转 WikiHomePage（带搜索 +
                // 8 章节， 订正：2026-07 新增导演模式章后为 8 章；
                // 已完整覆盖原 HelpSettingsPage 的新手引导与故事模式原理 wiki）
                AdaptiveSettingCard(
                  icon: Icons.help_outline,
                  title: t.help.title,
                  subtitle: t.help.entrySubtitle,
                  onTap: () => _navigateTo(context, const WikiHomePage()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _navigateTo(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }
}
