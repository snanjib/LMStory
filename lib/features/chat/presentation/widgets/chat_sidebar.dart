import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/brand_logo.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/presentation/pages/chat/chat_mode_page.dart';
import 'package:lmstory/features/chat/presentation/widgets/global_search_dialog.dart';
import 'package:lmstory/features/chat/presentation/widgets/sidebar_session_item.dart';
import 'package:lmstory/features/intermediate/presentation/intermediate_mode_flag.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// ChatBox-style sidebar with session list.
///
/// Contains (top to bottom):
/// 1. Header: App name + search + collapse button (desktop only)
/// 2. Search bar (shown when search is active)
/// 3. Session list: Scrollable list of sessions (starred first)
/// 4. Footer: "New Chat" + "New Story" / "New Director" + "Settings" buttons
class ChatSidebar extends ConsumerStatefulWidget {
  const ChatSidebar({
    required this.selectedSessionId,
    required this.onSessionSelected,
    required this.onNewChat,
    required this.onNewStory,
    required this.onSettings,
    required this.onCollapse,
    this.onNewDirector,
    this.showCollapseButton = true,
    this.onSessionUpdated,
    this.onSessionDeleted,
    this.onGoHome,
    this.refreshSignal = 0,
    this.generatingSessionIds = const {},
    super.key,
  });

  final String? selectedSessionId;

  /// 选择会话。`focusMessageId` 仅全局搜索命中进入时携带
  ///会话页据此滚动定位到命中消息。
  final void Function(ChatSession session, {String? focusMessageId})
      onSessionSelected;
  final VoidCallback onNewChat;

  /// 新建故事（intermediate 模式草稿）。
  final VoidCallback onNewStory;

  /// 新导演（advanced 模式草稿）。
  /// 仅当非 null 时显示（导演模式功能开关开启时由父组件传入）。
  final VoidCallback? onNewDirector;

  final VoidCallback onSettings;
  final VoidCallback onCollapse;
  final bool showCollapseButton;

  /// Called when a session is modified (rename, star, etc.) so the parent
  /// can refresh its cached selected session.
  final VoidCallback? onSessionUpdated;

  /// 删除会话成功后回调（携带被删会话）。
  ///
  /// 删除的是当前选中会话时，父组件
  ///（MainLayout）据此导航回主页——此前删除后主区仍停留在已删会话，
  /// controller 内存态仍在，继续发消息会写入数据库中已不存在的会话。
  final ValueChanged<ChatSession>? onSessionDeleted;

  /// Called when the user taps "Back to Home" button.
  /// Only shown when non-null (typically mobile drawer only).
  final VoidCallback? onGoHome;

  /// 刷新信号：值变化时触发会话列表重新加载。
  /// 用于在新建会话、删除会话等操作后通知侧边栏刷新。
  final int refreshSignal;

  /// 正在生成中的会话 ID 集合。
  ///
  /// 由 MainLayout 维护：遍历导航栈所有会话，读取 controller 状态，
  /// 收集 Simple.isStreaming / Intermediate 流式阶段的 sessionId。
  /// 集合中的会话在侧边栏显示呼吸点指示器，让用户在多会话切换或
  /// 后台生成时仍能感知"哪个会话在跑"。
  final Set<String> generatingSessionIds;

  @override
  ConsumerState<ChatSidebar> createState() => _ChatSidebarState();
}

class _ChatSidebarState extends ConsumerState<ChatSidebar> {
  List<ChatSession> _sessions = [];
  bool _isLoading = true;

  /// 首载失败标志（错误态 + 重试按钮）
  bool _loadFailed = false;
  bool _isSearching = false;
  String _searchQuery = '';
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadSessions();
  }

  @override
  void didUpdateWidget(covariant ChatSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 刷新信号变化时重新加载会话列表
    if (widget.refreshSignal != oldWidget.refreshSignal) {
      _refreshSessions();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadSessions() async {
    // 加载失败给出错误态+重试（与 GlobalSearchDialog 同款范式）
    try {
      final chatRepo = ref.read<ChatRepository>(chatRepositoryProvider);
      final sessions = await chatRepo.getAllSessions();
      if (mounted) {
        setState(() {
          _sessions = sessions;
          _isLoading = false;
          _loadFailed = false;
        });
      }
    } catch (e, stackTrace) {
      // e 此前未用——补诊断线索（对齐
      // global_search_dialog 的 debugPrint 口径）
      debugPrint('Sidebar sessions load failed: $e\n$stackTrace');
      if (mounted) {
        setState(() {
          _isLoading = false;
          _loadFailed = true;
        });
      }
    }
  }

  Future<void> _refreshSessions() async {
    try {
      final chatRepo = ref.read<ChatRepository>(chatRepositoryProvider);
      final sessions = await chatRepo.getAllSessions();
      if (mounted) {
        setState(() {
          _sessions = sessions;
          _loadFailed = false;
        });
      }
    } catch (_) {
      // 刷新失败保留现有列表；首载失败态由 _loadSessions 呈现
    }
  }

  /// Sessions sorted: starred first, then by sortOrder asc.
  /// If search is active, filter by title.
  List<ChatSession> get _displaySessions {
    var sessions = _sessions;

    // Filter by search query
    if (_searchQuery.isNotEmpty) {
      final query = _searchQuery.toLowerCase();
      sessions =
          sessions.where((s) => s.title.toLowerCase().contains(query)).toList();
    }

    // Sort: starred first, then by sortOrder asc
    final starred = sessions.where((s) => s.isStarred).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    final unstarred = sessions.where((s) => !s.isStarred).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

    return [...starred, ...unstarred];
  }

  Future<void> _deleteSession(ChatSession session) async {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    final confirmed = await showLmDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          t.chat.deleteSession,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        content: Text(
          t.chat.deleteConfirm,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.common.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: colors.error),
            child: Text(t.common.delete),
          ),
        ],
      ),
    );

    if (confirmed ?? false) {
      // 生成中的会话禁止删除——轮次仍持有该会话
      // 的 controller，删除后继续流式写入会向已删会话回写孤儿数据
      //（清理失效 + 烧 token）。与导演模式  的处置同向：先停止再删。
      if (widget.generatingSessionIds.contains(session.sessionId)) {
        if (mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                behavior: SnackBarBehavior.floating,
                content: Text(t.chat.failure.deleteBlockedWhileGenerating),
              ),
            );
        }
        return;
      }
      // 第五个写操作补失败反馈——此前裸 await，
      // DB 异常零提示，确认框关闭后用户以为删掉了（同族收尾）
      try {
        final chatRepo = ref.read<ChatRepository>(chatRepositoryProvider);
        await chatRepo.deleteSession(session.sessionId);
        // 删除即清——释放该会话 non-autoDispose family
        // 实例（全量 messages 常驻内存），invalidate 任意等值实例即命中
        ref.invalidate(chatModeControllerProvider(session));
        await _refreshSessions();
        widget.onSessionUpdated?.call();
        widget.onSessionDeleted?.call(session);
      } catch (e) {
        _showWriteFailed();
      }
    }
  }

  Future<void> _renameSession(ChatSession session) async {
    final t = Translations.of(context);
    // 控制器由对话框自持并在其 dispose 释放——
    // 此前 showDialog future 完成即 dispose，而对话框还有 ~150ms 退场
    // 动画，挂载中的 TextField 卸载时对已 dispose 的 notifier 移除监听
    // 可能触发 debug 断言（同库 message_edit_dialog 范式）。
    final newName = await showLmDialog<String>(
      context: context,
      builder: (ctx) => _RenameSessionDialog(
        title: session.title,
        dialogTitle: t.chat.rename,
        hint: t.chat.renameHint,
      ),
    );

    if (newName == null || newName.trim().isEmpty) return;
    try {
      final chatRepo = ref.read<ChatRepository>(chatRepositoryProvider);
      // 重命名走窄列接口——此前用列表缓存对象全列
      // 回写 updateSession，会把 messageCount/lastActiveAt 倒灌回上次
      // 加载的旧值（打开中的会话边聊边涨，重命名后主页最近排序被扰乱）。
      await chatRepo.updateSessionTitle(session.sessionId, newName.trim());
      await _refreshSessions();
      widget.onSessionUpdated?.call();
    } catch (e) {
      _showWriteFailed();
    }
  }

  Future<void> _toggleStar(ChatSession session) async {
    try {
      final chatRepo = ref.read<ChatRepository>(chatRepositoryProvider);
      // 收藏先读后写——列表缓存对象的元数据列是
      // 上次加载快照，直接全列回写会倒灌旧值；写前重读保证元数据新鲜
      //（收藏窄列接口待接口演进，见 01 册第六节改进项）。
      final fresh = await chatRepo.getSession(session.sessionId);
      await chatRepo.updateSession(
        fresh.copyWith(isStarred: !fresh.isStarred),
      );
      await _refreshSessions();
      widget.onSessionUpdated?.call();
    } catch (e) {
      _showWriteFailed();
    }
  }

  Future<void> _copySession(ChatSession session) async {
    try {
      final chatRepo = ref.read<ChatRepository>(chatRepositoryProvider);
      // CH-3c：副本标题后缀走 slang（此前仓库层硬编码英文）
      final newSession = await chatRepo.copySession(
        session.sessionId,
        copySuffix: t.chat.sidebar.copySuffix,
      );
      await _refreshSessions();
      widget.onSessionSelected(newSession);
    } catch (e) {
      _showWriteFailed();
    }
  }

  /// 会话写操作统一失败反馈——此前四处裸 await，
  /// DB 异常零提示；重排是乐观更新，失败后 UI 与 DB 脱钩、下次刷新静默
  /// 回弹。floating 规范同库其余 snackbar。
  void _showWriteFailed() {
    if (!mounted) return;
    final t = Translations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(t.chat.sidebar.writeFailed),
      ),
    );
  }

  /// Handle drag-to-reorder: update sortOrder for affected sessions.
  ///
  /// Sessions are split into starred (top) and unstarred (bottom) sections.
  /// Dragging within the same section reorders within that section.
  /// Dragging across sections is not allowed (starred stays starred).
  Future<void> _handleReorder(int oldIndex, int newIndex) async {
    // 搜索过滤期忽略重排——重算基于过滤后列表，
    // 被过滤掉的会话保留旧值，新网格与旧值交错撞值（Dart sort 非稳定，
    // 撞值时顺序不确定），排序持久化数据被静默污染。
    if (_searchQuery.isNotEmpty) return;
    // onReorderItem 已自动调整 newIndex（等价于旧 onReorder 的
    // `if (oldIndex < newIndex) newIndex -= 1`），无需再手动减一。
    final displaySessions = _displaySessions;
    if (oldIndex < 0 ||
        oldIndex >= displaySessions.length ||
        newIndex < 0 ||
        newIndex >= displaySessions.length) {
      return;
    }

    // Move the item in the local list
    final reordered = List<ChatSession>.from(displaySessions);
    final item = reordered.removeAt(oldIndex);
    reordered.insert(newIndex, item);

    // Recompute sortOrder for all sessions
    final sortOrders = <String, double>{};
    for (var i = 0; i < reordered.length; i++) {
      sortOrders[reordered[i].sessionId] = i.toDouble() * 1000.0;
    }

    // Optimistic update
    setState(() {
      _sessions = _sessions.map((s) {
        final newOrder = sortOrders[s.sessionId];
        if (newOrder != null) {
          return s.copyWith(sortOrder: newOrder);
        }
        return s;
      }).toList();
    });

    // Persist to database; on failure re-fetch to reconcile the optimistic
    // update with the persisted sort orders .
    try {
      final chatRepo = ref.read<ChatRepository>(chatRepositoryProvider);
      await chatRepo.updateSessionSortOrders(sortOrders);
    } catch (e) {
      _showWriteFailed();
      await _refreshSessions();
    }
  }

  void _openGlobalSearch() {
    showLmDialog<void>(
      context: context,
      builder: (ctx) => GlobalSearchDialog(
        // 携带 messageId 供会话页定位命中消息。
        onResultSelected: (result) {
          Navigator.of(ctx).pop();
          final session = _sessions.where(
            (s) => s.sessionId == result.sessionId,
          );
          if (session.isNotEmpty) {
            widget.onSessionSelected(
              session.first,
              focusMessageId: result.messageId,
            );
          }
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return Material(
      color: context.lmUi.sidebarSurfaceColor(context),
      child: Column(
        children: [
          // 顶部安全区域：统一避开状态栏，避免图标与状态栏重叠
          SizedBox(height: MediaQuery.of(context).padding.top),
          // Header
          _buildHeader(t, colors),
          // Search bar
          if (_isSearching) _buildSearchBar(t, colors),
          // 结构分隔线（侧栏边界）：dividerStrong 对 bg ≥3:1
          Divider(height: 1, thickness: 1, color: colors.dividerStrong),
          // Session list
          Expanded(child: _buildSessionList(colors)),
          // 结构分隔线（侧栏与页脚边界）
          Divider(height: 1, thickness: 1, color: colors.dividerStrong),
          // Footer
          _buildFooter(t, colors),
        ],
      ),
    );
  }

  Widget _buildHeader(Translations t, LmPalette colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SimpleSpacing.sMd,
        SimpleSpacing.sMd,
        SimpleSpacing.sSm,
        SimpleSpacing.s2xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 第一行：图标 + 标题（单行完整显示，不再被按钮挤占截断）
          Row(
            children: [
              const BrandLogo(size: 22),
              const SizedBox(width: SimpleSpacing.sSm),
              Flexible(
                child: Text(
                  t.chat.sidebar.title,
                  style: SimpleTextStyles.title3.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          // 第二行：按钮组（右对齐）
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              // Global search button
              Tooltip(
                message: t.chat.sidebar.globalSearch,
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: IconButton(
                    // Tooltip 只写 semantics 的 tooltip 属性
                    // （容器节点），读屏器读不到按钮名——label 挂到 icon 节点
                    // 合并进按钮语义
                    icon: Semantics(
                      label: t.chat.sidebar.globalSearch,
                      child: Icon(
                        Icons.search,
                        size: 18,
                        color: colors.muted,
                      ),
                    ),
                    onPressed: _openGlobalSearch,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                  ),
                ),
              ),
              // Local filter button
              Tooltip(
                message: t.chat.sidebar.search,
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: IconButton(
                    icon: Semantics(
                      label: t.chat.sidebar.search,
                      child: Icon(
                        _isSearching ? Icons.close : Icons.filter_list,
                        size: 18,
                        color: colors.muted,
                      ),
                    ),
                    onPressed: () {
                      setState(() {
                        _isSearching = !_isSearching;
                        if (!_isSearching) {
                          _searchQuery = '';
                          _searchController.clear();
                        }
                      });
                    },
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                  ),
                ),
              ),
              if (widget.showCollapseButton)
                Tooltip(
                  message: t.chat.sidebar.collapse,
                  child: SizedBox(
                    width: 36,
                    height: 36,
                    child: IconButton(
                      icon: Semantics(
                        label: t.chat.sidebar.collapse,
                        child: Icon(
                          Icons.chevron_left,
                          size: 20,
                          color: colors.muted,
                        ),
                      ),
                      onPressed: widget.onCollapse,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar(Translations t, LmPalette colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sMd,
        vertical: SimpleSpacing.s2xs,
      ),
      child: TextField(
        controller: _searchController,
        autofocus: true,
        style: SimpleTextStyles.bodySm.copyWith(color: colors.ink),
        decoration: InputDecoration(
          hintText: t.chat.sidebar.searchHint,
          hintStyle: SimpleTextStyles.bodySm.copyWith(color: colors.faint),
          prefixIcon: Icon(Icons.search, size: 16, color: colors.muted),
          suffixIcon: _searchQuery.isNotEmpty
              ? Semantics(
                  button: true,
                  label: t.common.clear,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      _searchController.clear();
                      setState(() => _searchQuery = '');
                    },
                    // 16px 图标直包点击 ≈16px 触控目标，垫到 44px
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: Icon(Icons.clear, size: 16, color: colors.muted),
                    ),
                  ),
                )
              : null,
          filled: true,
          fillColor: colors.surfaceElevated,
          border: OutlineInputBorder(
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(
            vertical: SimpleSpacing.s2xs,
          ),
          isDense: true,
        ),
        onChanged: (value) {
          setState(() => _searchQuery = value);
        },
      ),
    );
  }

  Widget _buildSessionList(LmPalette colors) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadFailed) {
      final t = Translations.of(context);
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              t.chat.sidebar.loadFailed,
              style: SimpleTextStyles.caption.copyWith(color: colors.muted),
            ),
            const SizedBox(height: SimpleSpacing.sSm),
            TextButton(
              onPressed: () {
                setState(() {
                  _isLoading = true;
                  _loadFailed = false;
                });
                _loadSessions();
              },
              child: Text(t.chat.sidebar.retryLoad),
            ),
          ],
        ),
      );
    }

    final displaySessions = _displaySessions;

    if (displaySessions.isEmpty) {
      return Center(
        child: Text(
          //  修复：空结果不再复用输入提示文案
          _searchQuery.isNotEmpty
              ? Translations.of(context).chat.sidebar.searchNoResults
              : Translations.of(context).chat.empty.noSession,
          style: SimpleTextStyles.caption.copyWith(color: colors.faint),
        ),
      );
    }

    return ReorderableListView.builder(
      padding: const EdgeInsets.symmetric(vertical: SimpleSpacing.s2xs),
      itemCount: displaySessions.length,
      onReorderItem: _handleReorder,
      // 禁用默认拖动把手（避免与三点菜单重叠 + 桌面端手势冲突）
      // 改由 SidebarSessionItem 内部显式渲染 ReorderableDragStartListener
      buildDefaultDragHandles: false,
      proxyDecorator: (child, index, animation) {
        return AnimatedBuilder(
          animation: animation,
          builder: (context, child) {
            final t = animation.value;
            return Transform.scale(
              scale: 1.0 + t * 0.02,
              child: Opacity(
                opacity: 0.9,
                child: child,
              ),
            );
          },
          // 拖动时 item 被移入 Overlay，失去原 Material 祖先，
          // 而 SidebarSessionItem 内部使用 InkWell 需要 Material，
          // 故用透明 Material 包裹，否则报 "No Material widget found"。
          child: Material(
            color: Colors.transparent,
            child: child,
          ),
        );
      },
      itemBuilder: (context, index) {
        final session = displaySessions[index];
        final isSelected = session.sessionId == widget.selectedSessionId;
        final isGenerating =
            widget.generatingSessionIds.contains(session.sessionId);
        return SidebarSessionItem(
          key: ValueKey(session.sessionId),
          session: session,
          index: index,
          isSelected: isSelected,
          isGenerating: isGenerating,
          onTap: () => widget.onSessionSelected(session),
          onDelete: () => _deleteSession(session),
          onRename: () => _renameSession(session),
          onToggleStar: () => _toggleStar(session),
          onCopy: () => _copySession(session),
        );
      },
    );
  }

  Widget _buildFooter(Translations t, LmPalette colors) {
    final storyVisible = ref.watch(intermediateModeFlagProvider);
    return Padding(
      padding: const EdgeInsets.all(SimpleSpacing.sSm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // New Chat button (primary)
          _buildFooterButton(
            icon: Icons.add,
            label: t.chat.sidebar.newChat,
            onTap: _handleNewChat,
            colors: colors,
            foregroundColor: colors.primary,
            backgroundColor: colors.primaryDim,
          ),
          const SizedBox(height: SimpleSpacing.s2xs),
          // New Story / New Director buttons (与首页入口同一组图标与文案)。
          // 故事入口默认隐藏（故事模式设置页可恢复）；隐藏时导演独占该行，
          // 两者皆不可用时不渲染该行
          if (storyVisible || widget.onNewDirector != null) ...[
            Row(
              children: [
                if (storyVisible)
                  Expanded(
                    child: _buildFooterButton(
                      icon: Icons.auto_stories,
                      label: t.intermediate.home.newStory,
                      onTap: widget.onNewStory,
                      colors: colors,
                      foregroundColor: colors.muted,
                    ),
                  ),
                if (storyVisible && widget.onNewDirector != null)
                  const SizedBox(width: SimpleSpacing.sXs),
                if (widget.onNewDirector != null)
                  Expanded(
                    child: _buildFooterButton(
                      icon: Icons.theater_comedy,
                      label: t.advanced.home.newDirector,
                      onTap: widget.onNewDirector!,
                      colors: colors,
                      foregroundColor: colors.muted,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: SimpleSpacing.s2xs),
          ],
          // Settings button
          _buildFooterButton(
            icon: Icons.settings_outlined,
            label: t.chat.sidebar.settings,
            onTap: widget.onSettings,
            colors: colors,
            foregroundColor: colors.muted,
          ),
          // Back to Home button (mobile only, when onGoHome is provided)
          if (widget.onGoHome != null) ...[
            const SizedBox(height: SimpleSpacing.s2xs),
            _buildFooterButton(
              icon: Icons.home_outlined,
              label: t.chat.sidebar.backToHome,
              onTap: widget.onGoHome!,
              colors: colors,
              foregroundColor: colors.muted,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFooterButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    required LmPalette colors,
    required Color foregroundColor,
    Color? backgroundColor,
  }) {
    return SizedBox(
      width: double.infinity,
      child: TextButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        label: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        style: TextButton.styleFrom(
          foregroundColor: foregroundColor,
          backgroundColor: backgroundColor,
          padding: const EdgeInsets.symmetric(
            vertical: SimpleSpacing.sSm,
          ),
          shape: RoundedRectangleBorder(
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
          ),
        ),
      ),
    );
  }

  /// 点击"新建对话"按钮：不立即创建数据库会话，而是通过 [ChatSidebar.onNewChat] 回调
  /// 通知父 widget 进入草稿状态。会话在用户发送第一条消息时才真正创建，
  /// 避免空会话残留。
  void _handleNewChat() {
    widget.onNewChat();
  }
}

/// 重命名对话框——控制器由 State 自持并在 dispose
/// 释放（调用方在 showDialog future 完成即 dispose 会与 ~150ms 退场动画
/// 中仍在挂载的 TextField 竞态，同库 message_edit_dialog 范式）。
class _RenameSessionDialog extends StatefulWidget {
  const _RenameSessionDialog({
    required this.title,
    required this.dialogTitle,
    required this.hint,
  });

  final String title;
  final String dialogTitle;
  final String hint;

  @override
  State<_RenameSessionDialog> createState() => _RenameSessionDialogState();
}

class _RenameSessionDialogState extends State<_RenameSessionDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.title);
    // 预选旧名——此前不选中文本，想全换名须手动
    // 删光旧名（两轮实测踩中）；预选后直接输入即整体覆盖，
    // 想微调可先点掉选区。
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.title.length,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    return AlertDialog(
      title: Text(
        widget.dialogTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: InputDecoration(hintText: widget.hint),
        textInputAction: TextInputAction.done,
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.common.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: Text(t.common.confirm),
        ),
      ],
    );
  }
}
