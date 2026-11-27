import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/config_visibility.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/widgets/advanced_level_hint.dart';
import 'package:lmstory/features/intermediate/presentation/intermediate_mode_flag.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_generation_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_help_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_models_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_prompts_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_suggest_reply_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_system_prompt_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_tools_memory_settings_page.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式设置页（2026-07-19 子页化重构）。
///
/// 用户反馈：「故事模式的设置点开后很乱很长，我要求同类型的设置收为
/// 同一个子模块，像手机系统设置那样，醒目标题严格分区」。
///
/// 本页改造为 iOS/Android Settings 风格的顶层分类卡片列表：
/// 5 个分类卡片，每个点击进入对应子页查看具体设置项。
///
/// - 模型配置（默认模型 + 分步骤模型 + 嵌入模型）→ [IntermediateModelsSettingsPage]
/// - 系统提示词（故事角色设定 + dirty check）→ [IntermediateSystemPromptSettingsPage]
/// - 工具与记忆（工具调用 + 记忆配置）→ [IntermediateToolsMemorySettingsPage]
/// - 提示词模板（8 段可编辑提示词）→ [IntermediatePromptsSettingsPage]
/// - 推荐回复（模型 + 提示词 + 生成参数）→ [IntermediateSuggestReplySettingsPage]
/// - 使用帮助（配置说明）→ [IntermediateHelpSettingsPage]
///
/// 各子页独立持有自己的状态（dirty check / 即时持久化等），本页无 dirty state，
/// 离开无需弹确认对话框。
///
/// 组装层按配置显示模式过滤：简单模式保留模型配置/系统提示词/生成参数
/// （思考预算）/使用帮助四卡；工具与记忆、提示词模板、推荐回复仅进阶
/// 模式渲染（子页无可留项或属管线调参面）。过滤只动展示层，被隐藏子页
/// 的配置项与已有用户值继续生效。
///
/// 视觉：跟随全局外观（故事/导演会话局部夜航已随外观体系 v2 收编为
/// 全局夜间基础）。
class IntermediateSettingsPage extends ConsumerWidget {
  const IntermediateSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final level = ref.watch(configLevelProvider);

    final cards = <Widget>[
      if (ConfigVisibility.of(ConfigVisibilityKeys.storyHubModels, level))
        context.lmUi.settingCard(
          context,
          narrative: true,
          icon: Icons.psychology_outlined,
          title: t.settings.intermediate.categories.models.title,
          subtitle: t.settings.intermediate.categories.models.subtitle,
          onTap: () => _push(
            context,
            const IntermediateModelsSettingsPage(),
          ),
        ),
      if (ConfigVisibility.of(ConfigVisibilityKeys.storyHubSystemPrompt, level))
        context.lmUi.settingCard(
          context,
          narrative: true,
          icon: Icons.description_outlined,
          title: t.settings.intermediate.categories.systemPrompt.title,
          subtitle: t.settings.intermediate.categories.systemPrompt.subtitle,
          onTap: () => _push(
            context,
            const IntermediateSystemPromptSettingsPage(),
          ),
        ),
      if (ConfigVisibility.of(ConfigVisibilityKeys.storyHubToolsMemory, level))
        context.lmUi.settingCard(
          context,
          narrative: true,
          icon: Icons.hub_outlined,
          title: t.settings.intermediate.categories.toolsMemory.title,
          subtitle: t.settings.intermediate.categories.toolsMemory.subtitle,
          onTap: () => _push(
            context,
            const IntermediateToolsMemorySettingsPage(),
          ),
        ),
      // v0.2.2 阶段 2-B 新增：生成参数全局配置入口
      // 5 个参数（温度/Top P/最大 Token/存在惩罚/频率惩罚）独立子页，
      // 与会话级生成参数对齐，作为新会话物化的快照源。
      if (ConfigVisibility.of(ConfigVisibilityKeys.storyHubGeneration, level))
        context.lmUi.settingCard(
          context,
          narrative: true,
          icon: Icons.tune_outlined,
          title: t.settings.intermediate.categories.generation.title,
          subtitle: t.settings.intermediate.categories.generation.subtitle,
          onTap: () => _push(
            context,
            const IntermediateGenerationSettingsPage(),
          ),
        ),
      if (ConfigVisibility.of(ConfigVisibilityKeys.storyHubPrompts, level))
        context.lmUi.settingCard(
          context,
          narrative: true,
          icon: Icons.edit_note_outlined,
          title: t.settings.intermediate.categories.prompts.title,
          subtitle: t.settings.intermediate.categories.prompts.subtitle,
          onTap: () => _push(
            context,
            const IntermediatePromptsSettingsPage(),
          ),
        ),
      if (ConfigVisibility.of(ConfigVisibilityKeys.storyHubSuggestReply, level))
        context.lmUi.settingCard(
          context,
          narrative: true,
          icon: Icons.auto_awesome_outlined,
          title: t.settings.intermediate.categories.suggestReply.title,
          subtitle: t.settings.intermediate.categories.suggestReply.subtitle,
          onTap: () => _push(
            context,
            const IntermediateSuggestReplySettingsPage(),
          ),
        ),
      context.lmUi.settingCard(
        context,
        narrative: true,
        icon: Icons.help_outline,
        title: t.settings.intermediate.categories.help.title,
        subtitle: t.settings.intermediate.categories.help.subtitle,
        onTap: () => _push(
          context,
          const IntermediateHelpSettingsPage(),
        ),
      ),
    ];

    // 设置树撤除入场转场（穿越动画只保留在模式会话页），
    // 逐页 500ms 淡入让深层导航迟滞。
    return Scaffold(
      backgroundColor:
          context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
      appBar: AppBar(
        title: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            t.settings.intermediate.title,
            style: IntermediateTextStyles.title.copyWith(color: colors.ink),
          ),
        ),
        backgroundColor:
            context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
        foregroundColor: colors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      body: LmMeasure(
        child: ListView(
          padding: const EdgeInsets.all(IntermediateSpacing.sLg),
          children: [
            // 入口开关卡置顶：故事模式入口默认隐藏，这里是恢复入口
            const _StoryModeToggleCard(),
            const SizedBox(height: IntermediateSpacing.sMd),
            for (var i = 0; i < cards.length; i++) ...[
              if (i > 0) const SizedBox(height: IntermediateSpacing.sMd),
              cards[i],
            ],
            const AdvancedLevelHint(
              surfaceId: ConfigVisibilitySurfaces.storyHub,
            ),
          ],
        ),
      ),
    );
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }
}

/// 故事模式入口开关卡：控制首页/侧边栏「新建故事」入口可见性（默认隐藏）。
/// 开关只藏入口，不影响已有故事会话、模板与配置。
class _StoryModeToggleCard extends ConsumerWidget {
  const _StoryModeToggleCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Translations.of(context);
    final enabled = ref.watch(intermediateModeFlagProvider);
    final colors = context.lm.palette;

    return Material(
      color: colors.surfaceVariant,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      clipBehavior: Clip.antiAlias,
      child: SwitchListTile(
        value: enabled,
        onChanged: (value) => ref
            .read(intermediateModeFlagProvider.notifier)
            .setEnabled(enabled: value),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: IntermediateSpacing.sLg,
        ),
        horizontalTitleGap: IntermediateSpacing.sMd,
        minVerticalPadding: IntermediateSpacing.sLg,
        secondary: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: colors.accent.withValues(alpha: 0.15),
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
          ),
          child: Icon(Icons.auto_stories, color: colors.accent, size: 22),
        ),
        title: Text(
          t.intermediate.settings.title,
          style: IntermediateTextStyles.bodyUi.copyWith(
            color: colors.ink,
            fontWeight: FontWeight.w600,
            fontSize: 15,
          ),
        ),
        subtitle: Text(
          t.intermediate.settings.desc,
          style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
        ),
      ),
    );
  }
}
