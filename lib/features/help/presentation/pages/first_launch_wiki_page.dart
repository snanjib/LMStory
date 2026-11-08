import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/demo/data/demo_state_store.dart';
import 'package:lmstory/features/demo/presentation/demo_runtime.dart';
import 'package:lmstory/features/help/presentation/widgets/first_launch_flow_diagram.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_page_scaffold.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_section_title.dart';
import 'package:lmstory/features/help/presentation/widgets/wiki_step_card.dart';
import 'package:lmstory/features/onboarding/presentation/controllers/onboarding_controller.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Wiki 子页 1.1：第一次打开 App（2026-07-27 新增）。
///
/// 通俗介绍首次启动的完整流程：启动 → 6 步新手引导 → 进入主界面。
///
/// 设计原则（遵循用户要求）：
/// - 示意图优先，拒绝大段文字
/// - 顶部主视觉图展示首次启动流程
/// - 6 步引导用 WikiStepCard 紧凑列表（步骤编号 + 一句话说明）
/// - API Key 提示用独立卡片强调
///
/// 内容来源：onboarding_page.dart 实际实现。
class FirstLaunchWikiPage extends StatelessWidget {
  const FirstLaunchWikiPage({super.key});

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return WikiPageScaffold(
      title: t.help.firstLaunchWiki.title,
      children: [
        // 引言
        Text(
          t.help.firstLaunch.intro,
          style: SimpleTextStyles.body.copyWith(
            color: colors.muted,
            height: 1.7,
          ),
        ),

        // 演示重看入口（onboarding 完成且包可用时显示；见 _DemoReplayEntry）
        const _DemoReplayEntry(),
        const SizedBox(height: SimpleSpacing.sMd),

        // 主视觉：首次启动流程示意图
        WikiSectionTitle(
          title: t.help.firstLaunch.flowTitle,
          subtitle: t.help.firstLaunch.flowSubtitle,
        ),
        const FirstLaunchFlowDiagram(),

        // 6 步引导内容
        WikiSectionTitle(
          title: t.help.firstLaunch.guideStepsTitle,
          subtitle: t.help.firstLaunch.guideStepsSubtitle,
        ),
        WikiStepCard(
          step: 1,
          title: t.help.firstLaunch.step1Title,
          body: t.help.firstLaunch.step1Body,
        ),
        const SizedBox(height: SimpleSpacing.sSm),
        WikiStepCard(
          step: 2,
          title: t.help.firstLaunch.step2Title,
          body: t.help.firstLaunch.step2Body,
        ),
        const SizedBox(height: SimpleSpacing.sSm),
        WikiStepCard(
          step: 3,
          title: t.help.firstLaunch.step3Title,
          body: t.help.firstLaunch.step3Body,
        ),
        const SizedBox(height: SimpleSpacing.sSm),
        WikiStepCard(
          step: 4,
          title: t.help.firstLaunch.step4Title,
          body: t.help.firstLaunch.step4Body,
        ),
        const SizedBox(height: SimpleSpacing.sSm),
        WikiStepCard(
          step: 5,
          title: t.help.firstLaunch.step5Title,
          body: t.help.firstLaunch.step5Body,
        ),
        const SizedBox(height: SimpleSpacing.sSm),
        WikiStepCard(
          step: 6,
          title: t.help.firstLaunch.step6Title,
          body: t.help.firstLaunch.step6Body,
        ),

        // API Key 提示
        WikiSectionTitle(
          title: t.help.firstLaunch.apiKeyTitle,
          subtitle: '',
        ),
        _ApiKeyHintCard(
          icon: Icons.key_outlined,
          title: t.help.firstLaunch.apiKeyCardTitle,
          body: t.help.firstLaunch.apiKeyCardBody,
        ),
      ],
    );
  }
}

/// API Key 提示卡片：图标 + 标题 + 短句说明。
///
/// 用 warning 色调强调"未配置"状态，与首页 _buildApiKeyMissingBanner 视觉呼应。
class _ApiKeyHintCard extends StatelessWidget {
  const _ApiKeyHintCard({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sMd),
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: colors.warning.withValues(alpha: 0.2),
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
            ),
            child: Icon(icon, color: colors.warning, size: 20),
          ),
          const SizedBox(width: SimpleSpacing.sSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: SimpleTextStyles.body.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: SimpleTextStyles.caption.copyWith(
                    color: colors.muted,
                    height: 1.6,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 手动体验入口卡：完整引导演示的再入口（首问拒绝/完成后可用，或中断后恢复）。
/// 当演示处于 running 但当前未激活作用域时，暴露可达的后续入口，允许重新进入恢复决策/重开或放弃；
/// 当 onboarding 已完成、演示未在途且当前 locale 包可用时，显示重新体验入口。
class _DemoReplayEntry extends ConsumerWidget {
  const _DemoReplayEntry();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final onboarding = ref.watch(
      onboardingProvider.select((s) => s.completed),
    );
    final demo = ref.watch(demoRuntimeProvider);

    // 当演示曾被中断且未在当前作用域激活（如不兼容恢复被取消、异常中断或退出保留），
    // 暴露可达的后续入口，允许重新进入恢复决策/重开或放弃，避免页面死锁。
    if (onboarding &&
        demo.loaded &&
        demo.packAvailable &&
        !demo.scopeActive &&
        demo.state.phase == DemoPhase.running) {
      return OutlinedButton.icon(
        onPressed: () => handleDemoResumeFlow(demo, context),
        icon: Icon(Icons.play_circle_outline, size: 18, color: colors.primary),
        label: Text(t.demo.resume.continueDemo),
      );
    }

    final eligible = onboarding &&
        demo.loaded &&
        demo.packAvailable &&
        !demo.scopeActive &&
        demo.state.phase != DemoPhase.running;
    if (!eligible) return const SizedBox.shrink();

    return OutlinedButton.icon(
      onPressed: () async {
        if (context.mounted) {
          Navigator.of(context).popUntil((route) => route.isFirst);
          // lm-motion-exempt: 路由退出动画完成等待窗口（非过渡动效，手动启动演示前的时序缓冲）
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        await demo.start(fresh: true);
      },
      icon: Icon(Icons.play_circle_outline, size: 18, color: colors.primary),
      label: Text(t.demo.invite.accept),
    );
  }
}
