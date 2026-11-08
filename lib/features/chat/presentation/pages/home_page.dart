import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/brand_logo.dart';
import 'package:lmstory/core/theme/shared/components/lm_arrival.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_button_metrics.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/tutorial/spotlight_target.dart';
import 'package:lmstory/features/advanced/presentation/advanced_mode_flag.dart';
import 'package:lmstory/features/chat/domain/entities/chat_mode.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/presentation/widgets/continuing_story_card.dart';
import 'package:lmstory/features/demo/domain/demo_scene.dart';
import 'package:lmstory/features/intermediate/presentation/intermediate_mode_flag.dart';
import 'package:lmstory/features/settings/presentation/pages/provider_list_page.dart';
import 'package:lmstory/features/settings/presentation/pages/settings_page.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// LMStory 主界面
///
/// 作为 app 的入口页面，提供：
/// - App 标题/Logo
/// - 模式入口卡：新建对话 + 新建导演主推并排；新建故事默认隐藏
///   （故事模式设置页可恢复入口，恢复后回到对话+故事双卡布局）
/// - 最近会话列表（按剩余高度整行裁切，超出的会话不显示）
/// - 设置入口（恒定在屏底）
///
/// 布局不变量：内容恒定一屏，页面不可上下滑动——滚动视图唯一子项的
/// 高度恒等于视口高度，滚动范围恒为 0；唯一保留的手势是顶部
/// overscroll 触发的下拉刷新。
class HomePage extends ConsumerStatefulWidget {
  const HomePage({
    required this.onNewChat,
    required this.onNewStory,
    required this.onSessionSelected,
    this.onNewDirector,
    this.onDirectorWizard,
    this.showHamburgerMenu = false,
    this.onHamburgerPressed,
    this.scaffoldKey,
    this.drawer,
    this.refreshSignal = 0,
    super.key,
  });

  /// 点击"新建对话"（Simple 模式）
  final VoidCallback onNewChat;

  /// 点击"新建故事"（Intermediate 模式）
  final VoidCallback onNewStory;

  /// 点击"新导演"（Advanced 模式，v0.3 实验入口；flag 关闭时为 null）
  final VoidCallback? onNewDirector;

  /// 点击"导演模式向导"入口行（2026-10-17 需求；与「新导演」直进
  /// 并存，flag 关闭时为 null；compact 布局下入口行隐藏）
  final VoidCallback? onDirectorWizard;

  /// 点击某个最近会话
  final ValueChanged<ChatSession> onSessionSelected;

  /// 是否显示汉堡菜单（移动端）
  final bool showHamburgerMenu;

  /// 汉堡菜单回调
  final VoidCallback? onHamburgerPressed;

  /// Scaffold key（移动端控制 Drawer）
  final GlobalKey<ScaffoldState>? scaffoldKey;

  /// Drawer widget（移动端）
  final Widget? drawer;

  /// 数据刷新信号（修复 2026-08-23）：随侧边栏信号一起递增。
  ///
  /// 此前 HomePage 仅 initState 加载一次——配完 Key 折返黄条不消失、
  /// 新建/删除会话后"最近会话"不更新，唯一出路是手动下拉刷新。
  final int refreshSignal;

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  List<ChatSession> _recentSessions = [];
  ChatSession? _continuingStory;
  bool _isLoading = true;

  /// 加载失败标志（错误态提示；主页有下拉刷新自救，无需按钮）
  bool _loadFailed = false;
  //  修复：首次启动 API Key 检测引导
  bool _hasAnyApiKey = true;
  int _lastHandledSignal = 0;

  @override
  void initState() {
    super.initState();
    _lastHandledSignal = widget.refreshSignal;
    _loadRecentSessions();
  }

  @override
  void didUpdateWidget(HomePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    //  修复：外部信号递增时自动重载（含 API Key 状态复检）
    if (widget.refreshSignal != _lastHandledSignal) {
      _lastHandledSignal = widget.refreshSignal;
      _loadRecentSessions();
    }
  }

  Future<void> _loadRecentSessions() async {
    try {
      await _loadRecentSessionsCore();
    } catch (e, stackTrace) {
      // UI 有错误态但日志零线索——对齐
      /// global_search_dialog 的 debugPrint 口径，DB 损坏/迁移异常可诊断
      debugPrint('Recent sessions load failed: $e\n$stackTrace');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _loadFailed = true;
        });
      }
    }
  }

  Future<void> _loadRecentSessionsCore() async {
    final chatRepo = ref.read<ChatRepository>(chatRepositoryProvider);
    final sessions = await chatRepo.getAllSessions();
    // 检测是否有任何 API Key 配置（任一 preset 的 apiKey 非空即视为已配置）
    final presetRepo = ref.read(apiPresetRepositoryProvider);
    final settingsRepo = ref.read(settingsRepositoryProvider);
    final presets = await presetRepo.getAllPresets();
    var hasKey = false;
    for (final preset in presets) {
      final apiKey = await settingsRepo.getApiKey(preset.presetId);
      if (apiKey != null && apiKey.isNotEmpty) {
        hasKey = true;
        break;
      }
    }
    if (mounted) {
      setState(() {
        final stories = sessions
            .where(
              (session) =>
                  session.mode == ChatMode.intermediate ||
                  session.mode == ChatMode.advanced,
            )
            .toList()
          ..sort((a, b) => b.lastActiveAt.compareTo(a.lastActiveAt));
        _continuingStory = stories.isEmpty ? null : stories.first;
        // Keep the recent list separate from the featured narrative session.
        _recentSessions = sessions.take(5).toList();
        _isLoading = false;
        _loadFailed = false;
        _hasAnyApiKey = hasKey;
      });
    }
  }

  // 异常即错误态（数据库损坏/迁移异常时首页不再永久转圈）

  Future<void> _onSettings() async {
    // 设置页里也能配 Key（供应商入口），
    /// 返回后重载——与 _goToProviderSettings 同构，此前经此路径配完 Key
    /// 折返黄条不消失
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
    );
    if (mounted) {
      await _loadRecentSessions();
    }
  }

  /// 跳转到供应商列表页配置 API Key
  ///
  /// await 返回后重载——配完 Key 折返时黄条
  /// 此前不消失（此路径不经过父级刷新信号，HomePage 自身也不重载），
  /// 唯一出路是手动下拉刷新。
  Future<void> _goToProviderSettings() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(builder: (_) => const ProviderListPage()),
    );
    if (mounted) {
      await _loadRecentSessions();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return Scaffold(
      key: widget.scaffoldKey,
      drawer: widget.drawer,
      backgroundColor: context.scaffoldBgOf(colors.bg),
      appBar: AppBar(
        leading: widget.showHamburgerMenu
            ? IconButton(
                //  语义缺口：纯图标汉堡按钮无 label，读屏器只播报
                // 「button N」。复用框架本地化文案（不新增 i18n key）。
                tooltip: MaterialLocalizations.of(context).openAppDrawerTooltip,
                icon: const Icon(Icons.menu),
                onPressed: widget.onHamburgerPressed,
              )
            : null,
        backgroundColor: context.scaffoldBgOf(colors.bg),
        foregroundColor: colors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      body: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final textScale = MediaQuery.textScalerOf(context).scale(16) / 16;
            final wizardAvailable = ref.watch(advancedModeFlagProvider) &&
                widget.onDirectorWizard != null;
            final extraBannersHeight =
                (!_hasAnyApiKey ? 96.0 : 0.0) + (wizardAvailable ? 80.0 : 0.0);
            final minHeightForStory =
                (520.0 + extraBannersHeight) * textScale;
            final showStory = !_isLoading &&
                !_loadFailed &&
                _continuingStory != null &&
                constraints.maxHeight >= minHeightForStory;
            final compactLayout = showStory ||
                constraints.maxHeight < LmLayout.homeCompactHeight * textScale;
            final featured = showStory ? _continuingStory : null;
            final storyCardCompact =
                constraints.maxHeight < (720.0 + extraBannersHeight) * textScale;

            // 极限短屏兜底：当非弹性元素总高度超过视口时，高度下界保护以允许纵向滑动，
            // 杜绝 RenderFlex 底部溢出。
            final minFixedRequired = (
                80.0 +
                (!_hasAnyApiKey ? 88.0 : 0.0) +
                (featured != null ? (storyCardCompact ? 96.0 : 270.0) : 0.0) +
                (compactLayout ? 60.0 : 72.0) +
                (wizardAvailable ? 72.0 : 0.0) +
                56.0 +
                105.0
            ) * textScale;
            return RefreshIndicator(
              onRefresh: _loadRecentSessions,
              child: RepaintBoundary(
                child: CustomScrollView(
                  // 首页内容固定一屏优先；在极限短屏或大字号下，
                  // 最小所需高度自适应扩展并允许纵向滚动，杜绝 RenderFlex 底部溢出。
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: math.max(
                          constraints.maxHeight,
                          minFixedRequired,
                        ),
                        child: Center(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: LmLayout.readingWidthOf(context),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                // App 标题区域
                                _buildHeader(t, colors, compact: compactLayout),
                                //  修复：首次启动无 API Key 引导卡片
                                if (!_isLoading && !_hasAnyApiKey)
                                  _buildApiKeyMissingBanner(t, colors),
                                // 双卡入口：新建对话 + 新建故事
                                if (featured != null)
                                  Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: SimpleSpacing.sLg,
                                      vertical: SimpleSpacing.sSm,
                                    ),
                                    child: ContinuingStoryCard(
                                      session: featured,
                                      compact: storyCardCompact,
                                      onTap: () => widget.onSessionSelected(
                                        featured,
                                      ),
                                    ),
                                  ),
                                _buildEntryCards(
                                  t,
                                  colors,
                                  compact: compactLayout,
                                ),
                                // 最近会话标题
                                _buildSectionTitle(t, colors),
                                // 最近会话：占满剩余空间并按高度整行裁切
                                Expanded(
                                  child: _buildRecentSessionsArea(
                                    t,
                                    colors,
                                    featuredId: showStory
                                        ? _continuingStory?.sessionId
                                        : null,
                                  ),
                                ),
                                // 底部操作区（恒定在屏底）
                                _buildFooter(t, colors),
                                // 底部间距
                                if (!compactLayout)
                                  const SizedBox(height: SimpleSpacing.s2xl),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  // ── App 标题/Logo ─────────────────────────────────────────────────

  Widget _buildHeader(
    Translations t,
    LmPalette colors, {
    bool compact = false,
  }) {
    return LmArrival(
      child: _buildHeaderContent(t, colors, compact: compact),
    );
  }

  Widget _buildHeaderContent(
    Translations t,
    LmPalette colors, {
    bool compact = false,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SimpleSpacing.sLg,
        SimpleSpacing.sMd,
        SimpleSpacing.sLg,
        SimpleSpacing.sMd,
      ),
      child: Row(
        children: [
          Container(
            width: compact ? 36 : 48,
            height: compact ? 36 : 48,
            decoration: BoxDecoration(
              color: colors.primaryDim,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: BrandLogo(size: compact ? 28 : 40),
            ),
          ),
          const SizedBox(width: SimpleSpacing.sMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.chat.home.title,
                  style: SimpleTextStyles.title1.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  t.chat.home.subtitle,
                  style: SimpleTextStyles.caption.copyWith(
                    color: colors.muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── 模式入口卡：对话 + （故事 | 导演） ────────────────────────────

  Widget _buildEntryCards(
    Translations t,
    LmPalette colors, {
    bool compact = false,
  }) {
    return LmArrival(
      delay: LmMotion.base,
      child: _buildEntryCardsContent(t, colors, compact: compact),
    );
  }

  Widget _buildEntryCardsContent(
    Translations t,
    LmPalette colors, {
    bool compact = false,
  }) {
    // 导演入口可用性：flag 开启且接线方提供回调（未开启不出现在可选 UI）
    final directorAvailable =
        ref.watch(advancedModeFlagProvider) && widget.onNewDirector != null;
    // 向导入口行：独立于「新导演」直进（双入口并存、用户自选）
    final wizardAvailable =
        ref.watch(advancedModeFlagProvider) && widget.onDirectorWizard != null;
    // 故事模式入口开关：默认隐藏，在故事模式设置页可恢复；
    // 恢复后回到「对话+故事双卡 + 导演横卡」的既有布局
    final storyVisible = ref.watch(intermediateModeFlagProvider);
    if (compact) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SimpleSpacing.sLg,
              vertical: SimpleSpacing.sSm,
            ),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _compactEntry(
                      t.chat.home.newChat,
                      Icons.add,
                      widget.onNewChat,
                    ),
                  ),
                  if (storyVisible) ...[
                    const SizedBox(width: SimpleSpacing.sSm),
                    Expanded(
                      child: _compactEntry(
                        t.intermediate.home.newStory,
                        Icons.auto_stories,
                        widget.onNewStory,
                      ),
                    ),
                  ],
                  if (directorAvailable) ...[
                    const SizedBox(width: SimpleSpacing.sSm),
                    Expanded(
                      child: _compactEntry(
                        t.advanced.home.newDirector,
                        Icons.theater_comedy,
                        widget.onNewDirector!,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          // 向导引导卡：compact 形态同样渲染（小卡行之后），
          // 短屏预算由最近会话区整行裁切机制兜底
          if (wizardAvailable)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                SimpleSpacing.sLg,
                0,
                SimpleSpacing.sLg,
                SimpleSpacing.sSm,
              ),
              child: _buildWizardGuideCard(
                t,
                colors,
                onTap: widget.onDirectorWizard!,
              ),
            ),
        ],
      );
    }
    // 第二卡分流：故事隐藏时导演升为并排主推卡；两者皆不可用时
    // 对话卡独占整行
    final secondCard = storyVisible
        ? _buildEntryCard(
            t: t,
            colors: colors,
            icon: Icons.auto_stories,
            iconColor: colors.surface,
            iconBg: colors.accent,
            cardBg: colors.accentDim,
            title: t.intermediate.home.newStory,
            desc: t.intermediate.home.newStoryDesc,
            onTap: widget.onNewStory,
          )
        : directorAvailable
            ? _buildEntryCard(
                t: t,
                colors: colors,
                icon: Icons.theater_comedy,
                iconColor: colors.surface,
                iconBg: colors.warning,
                cardBg: colors.warning.withValues(alpha: 0.12),
                title: t.advanced.home.newDirector,
                desc: t.advanced.home.newDirectorDesc,
                onTap: widget.onNewDirector!,
              )
            : null;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: SimpleSpacing.sLg,
            vertical: SimpleSpacing.sSm,
          ),
          // IntrinsicHeight 包裹 Row，使两个 Expanded 卡片高度对齐
          // （修复描述文本行数不同时卡片高度不一致的问题）
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 卡片 1：新建对话（Simple 模式）
                Expanded(
                  child: _buildEntryCard(
                    t: t,
                    colors: colors,
                    icon: Icons.add,
                    iconColor: colors.surface,
                    iconBg: colors.primary,
                    cardBg: colors.primaryDim,
                    title: t.chat.home.newChat,
                    desc: t.chat.home.newChatDesc,
                    onTap: widget.onNewChat,
                  ),
                ),
                if (secondCard != null) ...[
                  const SizedBox(width: SimpleSpacing.sSm),
                  Expanded(child: secondCard),
                ],
              ],
            ),
          ),
        ),
        if (storyVisible && directorAvailable)
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: SimpleSpacing.sLg,
            ),
            child: _buildEntryCard(
              colors: colors,
              t: t,
              icon: Icons.theater_comedy,
              iconColor: colors.surface,
              iconBg: colors.warning,
              cardBg: colors.warning.withValues(alpha: 0.12),
              title: t.advanced.home.newDirector,
              desc: t.advanced.home.newDirectorDesc,
              onTap: widget.onNewDirector!,
              horizontal: true,
            ),
          ),
        // 向导引导卡：创建区之后的独立单行强调入口（向导地位高于普通
        // 创建按钮，与双卡视觉区分，标题+介绍留「这是个什么」的余地）
        if (wizardAvailable)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SimpleSpacing.sLg,
              SimpleSpacing.sSm,
              SimpleSpacing.sLg,
              SimpleSpacing.sSm,
            ),
            child: _buildWizardGuideCard(
              t,
              colors,
              onTap: widget.onDirectorWizard!,
            ),
          ),
      ],
    );
  }

  /// 向导独立引导卡：primaryDim 底 + primary 描边的整行强调卡
  /// （参照设置页 _TemplateCard 选中容器范式；徽章 primary 底白图标，
  /// 标题 title3 + 介绍 caption 双行，尾部 chevron）
  Widget _buildWizardGuideCard(
    Translations t,
    LmPalette colors, {
    required VoidCallback onTap,
  }) {
    // Spotlight 语义目标（教程定位用；无教程活动零开销）
    return SpotlightTarget(
      id: DemoTargetIds.homeWizardCard,
      child: Container(
        decoration: BoxDecoration(
          color: colors.primaryDim,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
          border: Border.all(color: colors.primary, width: 1.5),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(
              context.lmUi.radius(LmCorner.lg),
            ),
            child: Padding(
              padding: const EdgeInsets.all(SimpleSpacing.sMd),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  minHeight: LmButtonMetrics.minInteractiveHeight,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: colors.primary,
                        borderRadius: BorderRadius.circular(
                          context.lmUi.radius(LmCorner.md),
                        ),
                      ),
                      child: Icon(
                        Icons.auto_awesome,
                        color: colors.surface,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: SimpleSpacing.sMd),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            t.directorWizard.entryTitle,
                            style: SimpleTextStyles.title3.copyWith(
                              color: colors.ink,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          Text(
                            t.directorWizard.entryDesc,
                            style: SimpleTextStyles.caption.copyWith(
                              color: colors.muted,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right, color: colors.muted),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _compactEntry(String title, IconData icon, VoidCallback onTap) {
    final colors = context.lm.palette;
    return context.lmUi.entryCard(
      context,
      onTap: onTap,
      fallbackColor: colors.surfaceVariant,
      horizontal: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: colors.muted, size: 20),
          const SizedBox(height: SimpleSpacing.sXs),
          Text(
            title,
            style: SimpleTextStyles.bodySm.copyWith(color: colors.ink),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildEntryCard({
    required Translations t,
    required LmPalette colors,
    required IconData icon,
    required Color iconColor,
    required Color iconBg,
    required Color cardBg,
    required String title,
    required String desc,
    required VoidCallback onTap,
    bool horizontal = false,
  }) {
    return context.lmUi.entryCard(
      context,
      onTap: onTap,
      fallbackColor: cardBg,
      horizontal: horizontal,
      child: horizontal
          ? Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: iconBg,
                    borderRadius:
                        BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
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
                        style: context.lmUi.entryTitleStyle(
                          context,
                          SimpleTextStyles.title3.copyWith(
                            color: colors.ink,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        desc,
                        style: SimpleTextStyles.caption
                            .copyWith(color: colors.muted),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: colors.muted),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: iconBg,
                    borderRadius:
                        BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
                  ),
                  child: Icon(icon, color: iconColor, size: 22),
                ),
                const SizedBox(height: SimpleSpacing.sSm),
                Text(
                  title,
                  style: context.lmUi.entryTitleStyle(
                    context,
                    SimpleTextStyles.title3.copyWith(
                      color: colors.ink,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: SimpleSpacing.s2xs),
                Text(
                  desc,
                  style: SimpleTextStyles.caption.copyWith(color: colors.muted),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
    );
  }

  // ── 最近会话标题 ──────────────────────────────────────────────────

  Widget _buildSectionTitle(Translations t, LmPalette colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SimpleSpacing.sLg,
        SimpleSpacing.sLg,
        SimpleSpacing.sLg,
        SimpleSpacing.sSm,
      ),
      child: Text(
        t.chat.home.recentSessions,
        style: SimpleTextStyles.title3.copyWith(
          color: colors.muted,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  // ── 最近会话区域（剩余视口内整行裁切） ─────────────────────────────

  Widget _buildRecentSessionsArea(
    Translations t,
    LmPalette colors, {
    String? featuredId,
  }) {
    final sessions = _recentSessions
        .where(
          (session) => session.sessionId != featuredId,
        )
        .toList();
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_loadFailed) {
      return Center(
        // 区域过小（小窗/横屏）时整体等比缩小，不溢出
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                t.chat.home.loadFailed,
                style: SimpleTextStyles.caption.copyWith(color: colors.muted),
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              // 失败态就地重试——此前仅靠下拉刷新手势，
              // Windows 桌面鼠标下不可发现。
              TextButton.icon(
                onPressed: () {
                  setState(() {
                    _isLoading = true;
                    _loadFailed = false;
                  });
                  _loadRecentSessions();
                },
                icon: const Icon(Icons.refresh, size: 16),
                label: Text(t.chat.sidebar.retryLoad),
              ),
            ],
          ),
        ),
      );
    }

    if (_recentSessions.isEmpty) {
      return _buildEmptyState(t, colors);
    }
    if (sessions.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(
      builder: (context, constraints) {
        final visibleCount = math.min(
          sessions.length,
          _fittingSessionCount(
            constraints.maxHeight,
            MediaQuery.textScalerOf(context),
          ),
        );
        // 剩余高度一行也放不下（短屏/横屏把 5 条全裁掉）时不再留空白——
        // 给一行指路提示（固定一屏形态不动，完整列表在侧边栏）。
        if (visibleCount == 0) {
          if (constraints.maxHeight < 24) {
            return const SizedBox.shrink();
          }
          return Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.menu_open_outlined, size: 14, color: colors.muted),
                  const SizedBox(width: SimpleSpacing.sXs),
                  Flexible(
                    child: Text(
                      t.chat.home.recentAllInSidebar,
                      style: SimpleTextStyles.caption.copyWith(
                        color: colors.muted,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < visibleCount; i++) ...[
              if (i > 0)
                Divider(
                  height: 1,
                  thickness: 1,
                  color: colors.divider,
                  indent: SimpleSpacing.sLg,
                  endIndent: SimpleSpacing.sLg,
                ),
              _buildSessionItem(sessions[i], colors),
            ],
          ],
        );
      },
    );
  }

  /// 两行会话行（标题 + 摘要，样式行高恒定）的行高上界；无摘要的行
  /// 实际更矮，但不高于该值——按它计数可保证裁切后总高度不超剩余空间。
  double _sessionRowExtent(TextScaler textScaler) {
    final twoLines = _lineExtent(SimpleTextStyles.body, textScaler) +
        _lineExtent(SimpleTextStyles.caption, textScaler);
    return 2 * SimpleSpacing.sMd + math.max(20, twoLines);
  }

  double _lineExtent(TextStyle style, TextScaler textScaler) {
    return textScaler.scale(style.fontSize ?? 16) * (style.height ?? 1.5);
  }

  /// 剩余高度内能完整放下的会话行数（行间 1px 分隔线）。
  int _fittingSessionCount(double availableHeight, TextScaler textScaler) {
    const dividerExtent = 1.0;
    final rowExtent = _sessionRowExtent(textScaler);
    if (availableHeight < rowExtent) {
      return 0;
    }
    return ((availableHeight + dividerExtent) / (rowExtent + dividerExtent))
        .floor();
  }

  Widget _buildSessionItem(ChatSession session, LmPalette colors) {
    // 最近会话复用侧边栏同款三态模式标识
    // （图标+色板同源 sidebar_session_item），star 不覆盖模式图标。
    final mode = session.mode;
    final isStory = mode == ChatMode.intermediate;
    final isDirector = mode == ChatMode.advanced;
    final modeColor = isDirector
        ? colors.warning
        : isStory
            ? colors.accent
            : colors.primary;
    final modeIcon = isDirector
        ? Icons.theater_comedy
        : isStory
            ? Icons.auto_stories
            : Icons.chat_bubble_outline;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => widget.onSessionSelected(session),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: SimpleSpacing.sLg,
            vertical: SimpleSpacing.sMd,
          ),
          child: Row(
            children: [
              Icon(modeIcon, size: 20, color: modeColor),
              const SizedBox(width: SimpleSpacing.sMd),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      session.title,
                      style: SimpleTextStyles.body.copyWith(
                        color: colors.ink,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (session.lastMessagePreview != null &&
                        session.lastMessagePreview!.isNotEmpty)
                      Text(
                        session.lastMessagePreview!,
                        style: SimpleTextStyles.caption.copyWith(
                          color: colors.faint,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              if (session.isStarred) ...[
                const SizedBox(width: SimpleSpacing.sSm),
                Icon(Icons.star, size: 14, color: colors.accent),
              ],
              Icon(
                Icons.chevron_right,
                color: colors.faint,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(Translations t, LmPalette colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: SimpleSpacing.s3xl,
        horizontal: SimpleSpacing.sLg,
      ),
      child: Center(
        // 区域过小（小窗/横屏）时整体等比缩小，不溢出
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.chat_bubble_outline_rounded,
                size: 40,
                color: colors.faint,
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              Text(
                t.chat.home.noRecentSessions,
                style: SimpleTextStyles.body.copyWith(color: colors.muted),
              ),
              const SizedBox(height: SimpleSpacing.s2xs),
              Text(
                t.chat.home.noRecentSessionsDesc,
                style: SimpleTextStyles.caption.copyWith(color: colors.faint),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── ：API Key 缺失引导卡片 ───────────────────

  Widget _buildApiKeyMissingBanner(Translations t, LmPalette colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SimpleSpacing.sLg,
        SimpleSpacing.sSm,
        SimpleSpacing.sLg,
        SimpleSpacing.sSm,
      ),
      child: Material(
        color: colors.warning.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        child: InkWell(
          onTap: _goToProviderSettings,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
          child: Padding(
            padding: const EdgeInsets.all(SimpleSpacing.sMd),
            child: Row(
              children: [
                Icon(
                  Icons.key_rounded,
                  size: 24,
                  color: colors.warning,
                ),
                const SizedBox(width: SimpleSpacing.sMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        t.chat.home.apiKeyMissing,
                        style: SimpleTextStyles.body.copyWith(
                          color: colors.ink,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: SimpleSpacing.s2xs),
                      Text(
                        t.chat.home.apiKeyMissingDesc,
                        style: SimpleTextStyles.caption.copyWith(
                          color: colors.muted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: SimpleSpacing.sSm),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: colors.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── 底部操作区：设置入口 ─────────────────────────────────────────

  Widget _buildFooter(Translations t, LmPalette colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SimpleSpacing.sLg,
        SimpleSpacing.sXl,
        SimpleSpacing.sLg,
        SimpleSpacing.sMd,
      ),
      child: Column(
        children: [
          Divider(
            height: 1,
            thickness: 1,
            color: colors.divider,
          ),
          // 设置入口
          ListTile(
            leading: Icon(Icons.settings_outlined, color: colors.muted),
            title: Text(
              t.chat.home.settings,
              style: SimpleTextStyles.body.copyWith(color: colors.ink),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Icon(
              Icons.chevron_right,
              color: colors.faint,
              size: 20,
            ),
            onTap: _onSettings,
          ),
        ],
      ),
    );
  }
}
