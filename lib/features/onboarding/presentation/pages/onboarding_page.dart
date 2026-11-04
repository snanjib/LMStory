import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/brand_logo.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/onboarding/presentation/controllers/onboarding_controller.dart';
import 'package:lmstory/features/settings/presentation/pages/provider_list_page.dart';
import 'package:lmstory/features/templates/presentation/pages/template_management_page.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 新手引导页（2026-07-20 新增）
///
/// 6 步详细版：欢迎 → 三种模式 → API Key → 模板 → 记忆 → 开始使用
///
/// 两种入口模式：
/// - **首次启动**（`isReview: false`）：MainLayout 全屏覆盖显示，右上角显示
///   「跳过」按钮，完成后调用 [OnboardingNotifier.markCompleted] 并关闭
/// - **设置主页重看**（`isReview: true`）：从 SettingsPage push 进入，右上角
///   显示「关闭」按钮，完成时不写入 completed 标记
///
/// 视觉：Simple 模式风格（黑白单色·等宽字体·rXs 直角边缘·克制高效），
/// 遵循 DOC-06A Simple 模式视觉规范。
class OnboardingPage extends ConsumerStatefulWidget {
  const OnboardingPage({
    this.isReview = false,
    super.key,
  });

  /// 是否为「重看」模式（从设置进入）
  ///
  /// true：右上角显示「关闭」，完成时不写入 completed
  /// false：右上角显示「跳过」，完成时写入 completed
  final bool isReview;

  @override
  ConsumerState<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends ConsumerState<OnboardingPage> {
  final PageController _pageController = PageController();
  int _currentStep = 0;

  static const int _kTotalSteps = 6;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _goToStep(int index) {
    if (index < 0 || index >= _kTotalSteps) return;
    _pageController.animateToPage(
      index,
      duration: LmMotion.step,
      curve: LmMotion.easeEmphasis,
    );
  }

  void _next() {
    if (_currentStep < _kTotalSteps - 1) {
      _goToStep(_currentStep + 1);
    } else {
      _finish();
    }
  }

  void _prev() {
    if (_currentStep > 0) _goToStep(_currentStep - 1);
  }

  /// 完成引导（点击「开始使用」或「跳过」时调用）
  ///
  /// - 首次启动模式（`isReview: false`）：调用 markCompleted，
  ///   MainLayout 监听到状态变化后自动隐藏 OnboardingPage，无需手动 pop
  /// - review 模式（`isReview: true`）：不写入 completed（用户随时可重看，
  ///   不应改变首次启动状态），手动 pop 关闭页面
  Future<void> _finish() async {
    if (widget.isReview) {
      if (mounted) await Navigator.of(context).maybePop();
    } else {
      await ref.read(onboardingProvider.notifier).markCompleted();
    }
  }

  /// Step 3「去配置」按钮：跳转到供应商列表页
  void _goToProviderSettings() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const ProviderListPage()),
    );
  }

  /// Step 4「去查看」按钮：跳转到模板管理页
  void _goToTemplateManagement() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const TemplateManagementPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return context.lmVenue(
      // 首屏是身份建立的第一屏，必须与进去之后的世界同构——
      // 琉璃下消费场地渐变（此前直接用 colors.bg 平涂，实测边缘亮度
      // range 恒为 0，与 home 页的 0.35 形成连续性断裂）。
      // 场地由本页**自承载**（不依赖祖先幕布），再按框架口径取 Scaffold 底色。
      Builder(
        builder: (context) => Scaffold(
          backgroundColor: context.scaffoldBgOf(colors.bg),
          appBar: AppBar(
            backgroundColor: context.scaffoldBgOf(colors.bg),
            foregroundColor: colors.ink,
            elevation: 0,
            scrolledUnderElevation: 0,
            surfaceTintColor: Colors.transparent,
            actions: [
              TextButton(
                onPressed: _finish,
                child: Text(
                  widget.isReview ? t.onboarding.close : t.onboarding.skip,
                  style: SimpleTextStyles.bodySm.copyWith(color: colors.muted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          body: SafeArea(
            child: Column(
              children: [
                // 步骤指示器
                _buildStepIndicator(colors, t),
                // 主内容区：PageView
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    onPageChanged: (index) {
                      setState(() => _currentStep = index);
                    },
                    children: [
                      _buildWelcomeStep(colors, t),
                      _buildModesStep(colors, t),
                      _buildApiKeyStep(colors, t),
                      _buildTemplateStep(colors, t),
                      _buildMemoryStep(colors, t),
                      _buildReadyStep(colors, t),
                    ],
                  ),
                ),
                // 底部导航按钮
                _buildBottomBar(colors, t),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── 步骤指示器 ─────────────────────────────────────────────────────

  Widget _buildStepIndicator(LmPalette colors, Translations t) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sLg,
        vertical: SimpleSpacing.sSm,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxWidth: LmLayout.readingWidthOf(context)),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  t.onboarding.stepIndicator(
                    current: _currentStep + 1,
                    total: _kTotalSteps,
                  ),
                  style: SimpleTextStyles.caption.copyWith(color: colors.faint),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: SimpleSpacing.sMd),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final segmentWidth =
                        (constraints.maxWidth - (_kTotalSteps - 1) * 4) /
                            _kTotalSteps;
                    return Row(
                      children: List.generate(_kTotalSteps, (i) {
                        final isDone = i < _currentStep;
                        final isCurrent = i == _currentStep;
                        // segmentWidth 只扣了 n-1 个间隔，
                        // 逐段右 margin 会让 Row 总宽超 4px（debug 溢出黄黑条/
                        // release 末段裁切）——末段不带 margin。
                        return Container(
                          width: segmentWidth,
                          height: 3,
                          margin: i == _kTotalSteps - 1
                              ? EdgeInsets.zero
                              : const EdgeInsets.only(right: 4),
                          decoration: BoxDecoration(
                            color: isCurrent
                                ? colors.primary
                                : (isDone
                                    ? colors.muted
                                    : colors.surfaceVariant),
                            borderRadius: BorderRadius.circular(
                              context.lmUi.radius(LmCorner.xs),
                            ),
                          ),
                        );
                      }),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Step 1: 欢迎介绍 ──────────────────────────────────────────────

  Widget _buildWelcomeStep(LmPalette colors, Translations t) {
    return _StepScaffold(
      colors: colors,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _HeroLogo(colors: colors),
          const SizedBox(height: SimpleSpacing.sXl),
          Text(
            t.onboarding.welcome.title,
            style: LmNarrativeTextStyles.narrativeHeadline.copyWith(
              color: colors.ink,
              fontSize: 40,
            ),
            textAlign: TextAlign.start,
          ),
          const SizedBox(height: SimpleSpacing.sSm),
          Text(
            t.onboarding.welcome.subtitle,
            style: SimpleTextStyles.title3.copyWith(color: colors.primary),
            textAlign: TextAlign.start,
          ),
          const SizedBox(height: SimpleSpacing.sLg),
          Text(
            t.onboarding.welcome.desc,
            style: SimpleTextStyles.body.copyWith(color: colors.muted),
            textAlign: TextAlign.start,
          ),
        ],
      ),
    );
  }

  // ── Step 2: 三模式说明 ────────────────────────────────────────────

  Widget _buildModesStep(LmPalette colors, Translations t) {
    return _StepScaffold(
      colors: colors,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            t.onboarding.modes.title,
            style: LmNarrativeTextStyles.narrativeHeadline.copyWith(
              color: colors.ink,
              fontSize: 28,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: SimpleSpacing.s2xs),
          Text(
            t.onboarding.modes.subtitle,
            style: SimpleTextStyles.bodySm.copyWith(color: colors.muted),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: SimpleSpacing.sXl),
          // 三卡对比
          _ModeCard(
            colors: colors,
            icon: Icons.chat_outlined,
            iconColor: colors.primary,
            iconBg: colors.primaryDim,
            title: t.onboarding.modes.chatTitle,
            desc: t.onboarding.modes.chatDesc,
          ),
          const SizedBox(height: SimpleSpacing.sMd),
          // 卡序对齐首页主推层级：对话与导演并排主推、故事默认隐藏
          _ModeCard(
            colors: colors,
            icon: Icons.theater_comedy_outlined,
            iconColor: colors.warning,
            iconBg: colors.warning.withValues(alpha: 0.12),
            title: t.onboarding.modes.directorTitle,
            desc: t.onboarding.modes.directorDesc,
          ),
          const SizedBox(height: SimpleSpacing.sMd),
          _ModeCard(
            colors: colors,
            icon: Icons.auto_stories_outlined,
            iconColor: colors.accent,
            iconBg: colors.accentDim,
            title: t.onboarding.modes.storyTitle,
            desc: t.onboarding.modes.storyDesc,
          ),
        ],
      ),
    );
  }

  // ── Step 3: API Key 配置引导 ──────────────────────────────────────

  Widget _buildApiKeyStep(LmPalette colors, Translations t) {
    return _StepScaffold(
      colors: colors,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _HeroIcon(
            icon: Icons.key_rounded,
            colors: colors,
          ),
          const SizedBox(height: SimpleSpacing.sXl),
          Text(
            t.onboarding.apiKey.title,
            style: LmNarrativeTextStyles.narrativeHeadline.copyWith(
              color: colors.ink,
              fontSize: 28,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: SimpleSpacing.s2xs),
          Text(
            t.onboarding.apiKey.subtitle,
            style: SimpleTextStyles.bodySm.copyWith(color: colors.primary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: SimpleSpacing.sLg),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SimpleSpacing.sLg,
            ),
            child: Text(
              t.onboarding.apiKey.desc,
              style: SimpleTextStyles.body.copyWith(color: colors.muted),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: SimpleSpacing.sXl),
          // 「去配置」按钮（不强制，下一步可继续）
          _PrimaryButton(
            colors: colors,
            label: t.onboarding.apiKey.goConfig,
            icon: Icons.arrow_forward,
            onPressed: _goToProviderSettings,
          ),
          const SizedBox(height: SimpleSpacing.sSm),
          Text(
            t.onboarding.apiKey.later,
            style: SimpleTextStyles.caption.copyWith(color: colors.faint),
          ),
        ],
      ),
    );
  }

  // ── Step 4: 提示词模板介绍 ────────────────────────────────────────

  Widget _buildTemplateStep(LmPalette colors, Translations t) {
    return _StepScaffold(
      colors: colors,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _HeroIcon(
            icon: Icons.description_outlined,
            colors: colors,
          ),
          const SizedBox(height: SimpleSpacing.sXl),
          Text(
            t.onboarding.template.title,
            style: LmNarrativeTextStyles.narrativeHeadline.copyWith(
              color: colors.ink,
              fontSize: 28,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: SimpleSpacing.s2xs),
          Text(
            t.onboarding.template.subtitle,
            style: SimpleTextStyles.bodySm.copyWith(color: colors.primary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: SimpleSpacing.sLg),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SimpleSpacing.sLg,
            ),
            child: Text(
              t.onboarding.template.desc,
              style: SimpleTextStyles.body.copyWith(color: colors.muted),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: SimpleSpacing.sXl),
          _PrimaryButton(
            colors: colors,
            label: t.onboarding.template.goView,
            icon: Icons.arrow_forward,
            onPressed: _goToTemplateManagement,
          ),
        ],
      ),
    );
  }

  // ── Step 5: 记忆机制简介（故事模式） ──────────────────────────────

  Widget _buildMemoryStep(LmPalette colors, Translations t) {
    return _StepScaffold(
      colors: colors,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _HeroIcon(
            icon: Icons.psychology_outlined,
            colors: colors,
          ),
          const SizedBox(height: SimpleSpacing.sXl),
          Text(
            t.onboarding.memory.title,
            style: LmNarrativeTextStyles.narrativeHeadline.copyWith(
              color: colors.ink,
              fontSize: 28,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: SimpleSpacing.s2xs),
          Text(
            t.onboarding.memory.subtitle,
            style: SimpleTextStyles.bodySm.copyWith(color: colors.primary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: SimpleSpacing.sLg),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SimpleSpacing.sMd,
            ),
            child: Text(
              t.onboarding.memory.desc,
              style: SimpleTextStyles.body.copyWith(color: colors.muted),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: SimpleSpacing.sXl),
          // 4 步流程图示
          _MemoryFlowDiagram(colors: colors, t: t),
        ],
      ),
    );
  }

  // ── Step 6: 开始使用 ──────────────────────────────────────────────

  Widget _buildReadyStep(LmPalette colors, Translations t) {
    return _StepScaffold(
      colors: colors,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _HeroIcon(
            icon: Icons.rocket_launch_outlined,
            colors: colors,
          ),
          const SizedBox(height: SimpleSpacing.sXl),
          Text(
            t.onboarding.ready.title,
            style: LmNarrativeTextStyles.narrativeHeadline.copyWith(
              color: colors.ink,
              fontSize: 40,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: SimpleSpacing.sSm),
          Text(
            t.onboarding.ready.subtitle,
            style: SimpleTextStyles.title3.copyWith(color: colors.primary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: SimpleSpacing.sLg),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SimpleSpacing.sLg,
            ),
            child: Text(
              t.onboarding.ready.desc,
              style: SimpleTextStyles.body.copyWith(color: colors.muted),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  // ── 底部导航栏 ────────────────────────────────────────────────────

  Widget _buildBottomBar(LmPalette colors, Translations t) {
    final isLast = _currentStep == _kTotalSteps - 1;
    final isFirst = _currentStep == 0;

    return Container(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.divider)),
        // 同 Scaffold：琉璃下让场地透上来，不再压一条平涂带。
        color: context.scaffoldBgOf(colors.bg),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sLg,
        vertical: SimpleSpacing.sMd,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxWidth: LmLayout.readingWidthOf(context)),
          child: Row(
            children: [
              // 上一步
              Expanded(
                child: isFirst
                    ? const SizedBox()
                    : Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton(
                          onPressed: _prev,
                          child: Text(
                            t.onboarding.prev,
                            style: SimpleTextStyles.bodySm
                                .copyWith(color: colors.muted),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
              ),
              const SizedBox(width: SimpleSpacing.sMd),
              // 下一步 / 开始使用
              Expanded(
                child: ElevatedButton(
                  onPressed: _next,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: colors.primary,
                    foregroundColor: colors.surface,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(
                      horizontal: SimpleSpacing.sLg,
                      vertical: SimpleSpacing.sMd,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(
                        context.lmUi.radius(LmCorner.xs),
                      ),
                    ),
                  ),
                  child: Text(
                    isLast ? t.onboarding.done : t.onboarding.next,
                    style: SimpleTextStyles.body.copyWith(
                      color: colors.surface,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── 私有组件 ──────────────────────────────────────────────────────────

/// 单步内容骨架：水平 padding + 垂直可滚动
class _StepScaffold extends StatelessWidget {
  const _StepScaffold({required this.colors, required this.child});

  final LmPalette colors;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: LmLayout.readingWidthOf(context)),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(
            horizontal: SimpleSpacing.sLg,
            vertical: SimpleSpacing.sMd,
          ),
          physics: const ClampingScrollPhysics(),
          child: SizedBox(width: double.infinity, child: child),
        ),
      ),
    );
  }
}

/// 大尺寸 hero 图标
class _HeroIcon extends StatelessWidget {
  const _HeroIcon({required this.icon, required this.colors});

  final IconData icon;
  final LmPalette colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        color: colors.primaryDim,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
      ),
      child: Icon(
        icon,
        size: 48,
        color: colors.primary,
      ),
    );
  }
}

/// 品牌首屏专用 logo hero，其他引导步骤继续使用语义化功能图标。
class _HeroLogo extends StatelessWidget {
  const _HeroLogo({required this.colors});

  final LmPalette colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        color: colors.primaryDim,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
      ),
      padding: const EdgeInsets.all(12),
      child: const BrandLogo(size: 72),
    );
  }
}

/// 三种模式卡片（Step 2 用）
class _ModeCard extends StatelessWidget {
  const _ModeCard({
    required this.colors,
    required this.icon,
    required this.iconColor,
    required this.iconBg,
    required this.title,
    required this.desc,
  });

  final LmPalette colors;
  final IconData icon;
  final Color iconColor;
  final Color iconBg;
  final String title;
  final String desc;

  @override
  Widget build(BuildContext context) {
    return context.lmUi.card(
      context,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: iconBg,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          const SizedBox(width: SimpleSpacing.sMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: LmNarrativeTextStyles.narrativeDisplay.copyWith(
                    color: colors.ink,
                    fontSize: 22,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: SimpleSpacing.s2xs),
                Text(
                  desc,
                  style: SimpleTextStyles.bodySm.copyWith(color: colors.muted),
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

/// 主要 CTA 按钮（Step 3 / 4 用）
class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.colors,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final LmPalette colors;
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16, color: colors.primary),
      label: Text(
        label,
        style: SimpleTextStyles.bodySm
            .copyWith(color: colors.primary, fontWeight: FontWeight.w600),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      style: OutlinedButton.styleFrom(
        side: BorderSide(color: colors.primary, width: 1.5),
        padding: const EdgeInsets.symmetric(
          horizontal: SimpleSpacing.sLg,
          vertical: SimpleSpacing.sMd,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
        ),
      ),
    );
  }
}

/// 记忆机制流程图示（Step 5 用）
///
/// 4 步流程：用户输入 → 生成 → 检索相关记忆 → 融合记忆的最终回复
class _MemoryFlowDiagram extends StatelessWidget {
  const _MemoryFlowDiagram({required this.colors, required this.t});

  final LmPalette colors;
  final Translations t;

  @override
  Widget build(BuildContext context) {
    final steps = [
      _FlowNode(icon: Icons.edit_outlined, label: t.onboarding.memory.flow1),
      _FlowNode(
        icon: Icons.edit_note_outlined,
        label: t.onboarding.memory.flow2,
      ),
      _FlowNode(
        icon: Icons.manage_search_outlined,
        label: t.onboarding.memory.flow3,
      ),
      _FlowNode(
        icon: Icons.auto_awesome_outlined,
        label: t.onboarding.memory.flow4,
      ),
    ];

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sLg),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
        border: Border.all(color: colors.divider),
      ),
      child: Column(
        children: [
          for (int i = 0; i < steps.length; i++) ...[
            steps[i],
            if (i < steps.length - 1)
              Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: SimpleSpacing.s2xs,
                ),
                child: Icon(
                  Icons.arrow_downward,
                  size: 16,
                  color: colors.faint,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

class _FlowNode extends StatelessWidget {
  const _FlowNode({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return Row(
      children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: colors.primaryDim,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
          ),
          child: Icon(icon, size: 16, color: colors.primary),
        ),
        const SizedBox(width: SimpleSpacing.sMd),
        Expanded(
          child: Text(
            label,
            style: SimpleTextStyles.bodySm.copyWith(color: colors.ink),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
