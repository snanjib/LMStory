import 'package:flutter/material.dart';
import 'package:lmstory/features/help/presentation/pages/advanced_settings_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/api_provider_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/appearance_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/clear_data_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/compaction_flow_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/context_budget_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/data_export_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/data_recovery_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/diagnostics_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/director_failure_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/director_first_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/director_log_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/director_mode_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/director_process_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/director_settings_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/director_watch_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/faq_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/feature_index_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/final_review_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/first_launch_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/first_story_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/generation_params_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/glossary_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/home_overview_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/language_input_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/macro_summary_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/memory_browser_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/message_actions_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/message_flow_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/message_navigation_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/model_strategy_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/prompt_template_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/resource_library_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/session_operation_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/session_settings_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/story_failure_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/story_flow_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/story_memory_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/story_message_actions_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/story_prompt_custom_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/story_session_settings_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/story_suggest_reply_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/story_vs_chat_wiki_page.dart';
import 'package:lmstory/features/help/presentation/pages/version_history_wiki_page.dart';
import 'package:lmstory/features/onboarding/presentation/pages/onboarding_page.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 主目录的章节数据结构。
class WikiSection {
  const WikiSection({
    required this.title,
    required this.subtitle,
    required this.entries,
  });

  final String title;
  final String subtitle;
  final List<WikiEntry> entries;
}

/// Wiki 主目录的条目数据结构。
///
/// [searchText] 用于搜索过滤，由 title + subtitle 拼接（小写）。
///
/// 架构树观察7 收口：全部章节落地两月后
/// 「待建设条目」机制零消费——pageBuilder 非空化，禁用样式分支随
/// WikiEntryView 一并移除；未来新增待建设条目时再按需恢复。
class WikiEntry {
  WikiEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.pageBuilder,
  }) : searchText = '${title.toLowerCase()} ${subtitle.toLowerCase()}';

  final IconData icon;
  final String title;
  final String subtitle;
  final WidgetBuilder pageBuilder;
  final String searchText;
}

/// 构建 Wiki 主目录的 8 个章节。
///
/// 章节组织（用户视角分类）：
/// 1. 开始使用（阶段 2 实现，1.3 已可直接跳新手引导）
/// 2. 对话模式用法（阶段 3 实现）
/// 3. 故事模式用法（阶段 3 实现）
/// 4. 故事模式原理（4.1-4.3 已有，4.4 阶段 1 新增）
/// 5. 导演模式（2026-08-19 新增，v0.3 实验性）
/// 6. 配置与个性化（阶段 4 实现）
/// 7. 数据与维护（阶段 4 实现）
/// 8. 附录（阶段 4 实现）
List<WikiSection> buildWikiSections(BuildContext context) {
  final help = Translations.of(context).help;

  return [
    // ── 第一部分：开始使用 ──
    WikiSection(
      title: help.wikiHome.section1Title,
      subtitle: help.wikiHome.section1Subtitle,
      entries: [
        WikiEntry(
          icon: Icons.rocket_launch_outlined,
          title: help.wikiHome.entry_1_1_title,
          subtitle: help.wikiHome.entry_1_1_subtitle,
          pageBuilder: (context) => const FirstLaunchWikiPage(),
        ),
        WikiEntry(
          icon: Icons.view_quilt_outlined,
          title: help.wikiHome.entry_1_2_title,
          subtitle: help.wikiHome.entry_1_2_subtitle,
          pageBuilder: (context) => const HomeOverviewWikiPage(),
        ),
        WikiEntry(
          icon: Icons.school_outlined,
          title: help.wikiHome.entry_1_3_title,
          subtitle: help.wikiHome.entry_1_3_subtitle,
          pageBuilder: (context) => const OnboardingPage(isReview: true),
        ),
      ],
    ),

    // ── 第二部分：对话模式用法 ──
    WikiSection(
      title: help.wikiHome.section2Title,
      subtitle: help.wikiHome.section2Subtitle,
      entries: [
        WikiEntry(
          icon: Icons.forum_outlined,
          title: help.wikiHome.entry_2_1_title,
          subtitle: help.wikiHome.entry_2_1_subtitle,
          pageBuilder: (context) => const SessionOperationWikiPage(),
        ),
        WikiEntry(
          icon: Icons.send_outlined,
          title: help.wikiHome.entry_2_2_title,
          subtitle: help.wikiHome.entry_2_2_subtitle,
          pageBuilder: (context) => const MessageFlowWikiPage(),
        ),
        WikiEntry(
          icon: Icons.touch_app_outlined,
          title: help.wikiHome.entry_2_3_title,
          subtitle: help.wikiHome.entry_2_3_subtitle,
          pageBuilder: (context) => const MessageActionsWikiPage(),
        ),
        WikiEntry(
          icon: Icons.navigation_outlined,
          title: help.wikiHome.entry_2_4_title,
          subtitle: help.wikiHome.entry_2_4_subtitle,
          pageBuilder: (context) => const MessageNavigationWikiPage(),
        ),
        WikiEntry(
          icon: Icons.tune_outlined,
          title: help.wikiHome.entry_2_5_title,
          subtitle: help.wikiHome.entry_2_5_subtitle,
          pageBuilder: (context) => const SessionSettingsWikiPage(),
        ),
        WikiEntry(
          icon: Icons.compress_outlined,
          title: help.wikiHome.entry_2_6_title,
          subtitle: help.wikiHome.entry_2_6_subtitle,
          pageBuilder: (context) => const CompactionFlowWikiPage(),
        ),
      ],
    ),

    // ── 第三部分：故事模式用法 ──
    WikiSection(
      title: help.wikiHome.section3Title,
      subtitle: help.wikiHome.section3Subtitle,
      entries: [
        WikiEntry(
          icon: Icons.compare_arrows_outlined,
          title: help.wikiHome.entry_3_1_title,
          subtitle: help.wikiHome.entry_3_1_subtitle,
          pageBuilder: (context) => const StoryVsChatWikiPage(),
        ),
        WikiEntry(
          icon: Icons.auto_stories_outlined,
          title: help.wikiHome.entry_3_2_title,
          subtitle: help.wikiHome.entry_3_2_subtitle,
          pageBuilder: (context) => const FirstStoryWikiPage(),
        ),
        WikiEntry(
          icon: Icons.timeline_outlined,
          title: help.wikiHome.entry_3_3_title,
          subtitle: help.wikiHome.entry_3_3_subtitle,
          pageBuilder: (context) => const StoryFlowWikiPage(),
        ),
        WikiEntry(
          icon: Icons.touch_app_outlined,
          title: help.wikiHome.entry_3_4_title,
          subtitle: help.wikiHome.entry_3_4_subtitle,
          pageBuilder: (context) => const StoryMessageActionsWikiPage(),
        ),
        WikiEntry(
          icon: Icons.error_outline,
          title: help.wikiHome.entry_3_5_title,
          subtitle: help.wikiHome.entry_3_5_subtitle,
          pageBuilder: (context) => const StoryFailureWikiPage(),
        ),
        WikiEntry(
          icon: Icons.tune_outlined,
          title: help.wikiHome.entry_3_6_title,
          subtitle: help.wikiHome.entry_3_6_subtitle,
          pageBuilder: (context) => const StorySessionSettingsWikiPage(),
        ),
        WikiEntry(
          icon: Icons.library_books_outlined,
          title: help.wikiHome.entry_3_7_title,
          subtitle: help.wikiHome.entry_3_7_subtitle,
          pageBuilder: (context) => const MemoryBrowserWikiPage(),
        ),
        WikiEntry(
          icon: Icons.auto_awesome_outlined,
          title: help.wikiHome.entry_3_8_title,
          subtitle: help.wikiHome.entry_3_8_subtitle,
          pageBuilder: (context) => const StorySuggestReplyWikiPage(),
        ),
      ],
    ),

    // ── 第四部分：故事模式原理 ──
    WikiSection(
      title: help.wikiHome.section4Title,
      subtitle: help.wikiHome.section4Subtitle,
      entries: [
        WikiEntry(
          icon: Icons.timeline_outlined,
          title: help.wikiHome.entry_4_1_title,
          subtitle: help.wikiHome.entry_4_1_subtitle,
          pageBuilder: (context) => const StoryFlowWikiPage(),
        ),
        WikiEntry(
          icon: Icons.psychology_outlined,
          title: help.wikiHome.entry_4_2_title,
          subtitle: help.wikiHome.entry_4_2_subtitle,
          pageBuilder: (context) => const StoryMemoryWikiPage(),
        ),
        WikiEntry(
          icon: Icons.error_outline,
          title: help.wikiHome.entry_4_3_title,
          subtitle: help.wikiHome.entry_4_3_subtitle,
          pageBuilder: (context) => const StoryFailureWikiPage(),
        ),
        WikiEntry(
          icon: Icons.library_add_check_outlined,
          title: help.wikiHome.entry_4_4_title,
          subtitle: help.wikiHome.entry_4_4_subtitle,
          pageBuilder: (context) => const MacroSummaryWikiPage(),
        ),
        WikiEntry(
          icon: Icons.tune_outlined,
          title: help.wikiHome.entry_4_5_title,
          subtitle: help.wikiHome.entry_4_5_subtitle,
          pageBuilder: (context) => const ContextBudgetWikiPage(),
        ),
        WikiEntry(
          icon: Icons.fact_check_outlined,
          title: help.wikiHome.entry_4_6_title,
          subtitle: help.wikiHome.entry_4_6_subtitle,
          pageBuilder: (context) => const FinalReviewWikiPage(),
        ),
      ],
    ),

    // ── 第五部分：导演模式（2026-08-19 新增，v0.3 实验性）──
    WikiSection(
      title: help.wikiHome.sectionDirectorTitle,
      subtitle: help.wikiHome.sectionDirectorSubtitle,
      entries: [
        WikiEntry(
          icon: Icons.theater_comedy_outlined,
          title: help.wikiHome.entryDirector1Title,
          subtitle: help.wikiHome.entryDirector1Subtitle,
          pageBuilder: (context) => const DirectorModeWikiPage(),
        ),
        WikiEntry(
          icon: Icons.post_add_outlined,
          title: help.wikiHome.entryDirector2Title,
          subtitle: help.wikiHome.entryDirector2Subtitle,
          pageBuilder: (context) => const DirectorFirstWikiPage(),
        ),
        WikiEntry(
          icon: Icons.rule_outlined,
          title: help.wikiHome.entryDirector3Title,
          subtitle: help.wikiHome.entryDirector3Subtitle,
          pageBuilder: (context) => const DirectorWatchWikiPage(),
        ),
        WikiEntry(
          icon: Icons.layers_outlined,
          title: help.wikiHome.entryDirector5Title,
          subtitle: help.wikiHome.entryDirector5Subtitle,
          pageBuilder: (context) => const DirectorProcessWikiPage(),
        ),
        WikiEntry(
          icon: Icons.restore_outlined,
          title: help.wikiHome.entryDirector6Title,
          subtitle: help.wikiHome.entryDirector6Subtitle,
          pageBuilder: (context) => const DirectorLogWikiPage(),
        ),
        WikiEntry(
          icon: Icons.error_outline,
          title: help.wikiHome.entryDirector7Title,
          subtitle: help.wikiHome.entryDirector7Subtitle,
          pageBuilder: (context) => const DirectorFailureWikiPage(),
        ),
        WikiEntry(
          icon: Icons.tune_outlined,
          title: help.wikiHome.entryDirector8Title,
          subtitle: help.wikiHome.entryDirector8Subtitle,
          pageBuilder: (context) => const DirectorSettingsWikiPage(),
        ),
      ],
    ),

    // ── 第六部分：配置与个性化──
    WikiSection(
      title: help.wikiHome.section5Title,
      subtitle: help.wikiHome.section5Subtitle,
      entries: [
        WikiEntry(
          icon: Icons.cloud_outlined,
          title: help.wikiHome.entry_5_1_title,
          subtitle: help.wikiHome.entry_5_1_subtitle,
          pageBuilder: (context) => const ApiProviderWikiPage(),
        ),
        WikiEntry(
          icon: Icons.tune_outlined,
          title: help.wikiHome.entry_5_2_title,
          subtitle: help.wikiHome.entry_5_2_subtitle,
          pageBuilder: (context) => const ModelStrategyWikiPage(),
        ),
        WikiEntry(
          icon: Icons.description_outlined,
          title: help.wikiHome.entry_5_3_title,
          subtitle: help.wikiHome.entry_5_3_subtitle,
          pageBuilder: (context) => const PromptTemplateWikiPage(),
        ),
        WikiEntry(
          icon: Icons.edit_note_outlined,
          title: help.wikiHome.entry_5_4_title,
          subtitle: help.wikiHome.entry_5_4_subtitle,
          pageBuilder: (context) => const StoryPromptCustomWikiPage(),
        ),
        WikiEntry(
          icon: Icons.palette_outlined,
          title: help.wikiHome.entry_5_5_title,
          subtitle: help.wikiHome.entry_5_5_subtitle,
          pageBuilder: (context) => const AppearanceWikiPage(),
        ),
        WikiEntry(
          icon: Icons.language_outlined,
          title: help.wikiHome.entry_5_6_title,
          subtitle: help.wikiHome.entry_5_6_subtitle,
          pageBuilder: (context) => const LanguageInputWikiPage(),
        ),
        // 注：Icons 不存在 advanced_outlined，使用 settings_suggest_outlined 替代
        WikiEntry(
          icon: Icons.settings_suggest_outlined,
          title: help.wikiHome.entry_5_7_title,
          subtitle: help.wikiHome.entry_5_7_subtitle,
          pageBuilder: (context) => const AdvancedSettingsWikiPage(),
        ),
        WikiEntry(
          icon: Icons.tune_outlined,
          title: help.wikiHome.entry_5_8_title,
          subtitle: help.wikiHome.entry_5_8_subtitle,
          pageBuilder: (context) => const GenerationParamsWikiPage(),
        ),
        WikiEntry(
          icon: Icons.local_florist_outlined,
          title: help.wikiHome.entry_5_9_title,
          subtitle: help.wikiHome.entry_5_9_subtitle,
          pageBuilder: (context) => const ResourceLibraryWikiPage(),
        ),
      ],
    ),

    // ── 第七部分：数据与维护──
    WikiSection(
      title: help.wikiHome.section6Title,
      subtitle: help.wikiHome.section6Subtitle,
      entries: [
        WikiEntry(
          icon: Icons.swap_horiz_outlined,
          title: help.wikiHome.entry_6_1_title,
          subtitle: help.wikiHome.entry_6_1_subtitle,
          pageBuilder: (context) => const DataExportWikiPage(),
        ),
        WikiEntry(
          icon: Icons.healing_outlined,
          title: help.wikiHome.entry_6_2_title,
          subtitle: help.wikiHome.entry_6_2_subtitle,
          pageBuilder: (context) => const DataRecoveryWikiPage(),
        ),
        WikiEntry(
          icon: Icons.delete_forever_outlined,
          title: help.wikiHome.entry_6_3_title,
          subtitle: help.wikiHome.entry_6_3_subtitle,
          pageBuilder: (context) => const ClearDataWikiPage(),
        ),
        WikiEntry(
          icon: Icons.bug_report_outlined,
          title: help.wikiHome.entry_6_4_title,
          subtitle: help.wikiHome.entry_6_4_subtitle,
          pageBuilder: (context) => const DiagnosticsWikiPage(),
        ),
      ],
    ),

    // ── 第八部分：附录──
    WikiSection(
      title: help.wikiHome.section7Title,
      subtitle: help.wikiHome.section7Subtitle,
      entries: [
        WikiEntry(
          icon: Icons.help_outline,
          title: help.wikiHome.entry_7_1_title,
          subtitle: help.wikiHome.entry_7_1_subtitle,
          pageBuilder: (context) => const FaqWikiPage(),
        ),
        WikiEntry(
          icon: Icons.menu_book_outlined,
          title: help.wikiHome.entry_7_2_title,
          subtitle: help.wikiHome.entry_7_2_subtitle,
          pageBuilder: (context) => const GlossaryWikiPage(),
        ),
        WikiEntry(
          icon: Icons.list_outlined,
          title: help.wikiHome.entry_7_3_title,
          subtitle: help.wikiHome.entry_7_3_subtitle,
          pageBuilder: (context) => const FeatureIndexWikiPage(),
        ),
        WikiEntry(
          icon: Icons.history_outlined,
          title: help.wikiHome.entry_7_4_title,
          subtitle: help.wikiHome.entry_7_4_subtitle,
          pageBuilder: (context) => const VersionHistoryWikiPage(),
        ),
      ],
    ),
  ];
}
