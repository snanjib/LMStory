import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/brand_logo.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/advanced/presentation/advanced_mode_flag.dart';
import 'package:lmstory/features/chat/domain/entities/chat_mode.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
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
        // 只取最近 5 个会话
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
            return RefreshIndicator(
              onRefresh: _loadRecentSessions,
              child: RepaintBoundary(
                child: CustomScrollView(
                  // 首页内容恒定一屏：唯一滚动子项的高度恒等于视口高度，
                  // 滚动范围恒为 0，页面不可上下滑动；唯一保留的手势是
                  // 顶部 overscroll 触发的下拉刷新（内容不足一屏时同样可用）。
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: constraints.maxHeight,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // App 标题区域
                            _buildHeader(t, colors),
                            //  修复：首次启动无 API Key 引导卡片
                            if (!_isLoading && !_hasAnyApiKey)
                              _buildApiKeyMissingBanner(t, colors),
                            // 双卡入口：新建对话 + 新建故事
                            _buildEntryCards(t, colors),
                            // 最近会话标题
                            _buildSectionTitle(t, colors),
                            // 最近会话：占满剩余空间并按高度整行裁切
                            Flexible(
                              child: _buildRecentSessionsArea(t, colors),
                            ),
                            // 底部操作区（恒定在屏底）
                            _buildFooter(t, colors),
                            // 底部间距
                            const SizedBox(height: SimpleSpacing.s2xl),
                          ],
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

  Widget _buildHeader(Translations t, LmPalette colors) {
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
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: colors.primaryDim,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
            ),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: BrandLogo(size: 40),
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

  Widget _buildEntryCards(Translations t, LmPalette colors) {
    // 导演入口可用性：flag 开启且接线方提供回调（未开启不出现在可选 UI）
    final directorAvailable =
        ref.watch(advancedModeFlagProvider) && widget.onNewDirector != null;
    // 故事模式入口开关：默认隐藏，在故事模式设置页可恢复；
    // 恢复后回到「对话+故事双卡 + 导演横卡」的既有布局
    final storyVisible = ref.watch(intermediateModeFlagProvider);
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
              t: t,
              colors: colors,
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
      ],
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

  Widget _buildRecentSessionsArea(Translations t, LmPalette colors) {
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

    return LayoutBuilder(
      builder: (context, constraints) {
        final visibleCount = math.min(
          _recentSessions.length,
          _fittingSessionCount(
            constraints.maxHeight,
            MediaQuery.textScalerOf(context),
          ),
        );
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
              _buildSessionItem(_recentSessions[i], colors),
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
