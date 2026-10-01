import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/components/simple_chat_input.dart';
import 'package:lmstory/core/theme/simple/components/simple_message_bubble.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_shortcuts.dart';
import 'package:lmstory/core/theme/system/lm_structure.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/utils/follow_scroll_executor.dart';
import 'package:lmstory/core/utils/smooth_follow_scroller.dart'
    show streamingFollowCushionPx;
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/fork_anchor.dart';
import 'package:lmstory/features/chat/domain/entities/message_attachment.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/presentation/controllers/chat_mode_controller.dart';
import 'package:lmstory/features/chat/presentation/pages/chat/widgets/chat_background_generating_banner.dart';
import 'package:lmstory/features/chat/presentation/pages/chat/widgets/chat_empty_view.dart';
import 'package:lmstory/features/chat/presentation/pages/chat/widgets/chat_error_banner.dart';
import 'package:lmstory/features/chat/presentation/pages/chat/widgets/chat_generating_placeholder.dart';
import 'package:lmstory/features/chat/presentation/pages/chat/widgets/chat_message_navigation_overlay.dart';
import 'package:lmstory/features/chat/presentation/pages/chat/widgets/chat_mode_app_bar.dart';
import 'package:lmstory/features/chat/presentation/pages/chat/widgets/chat_round_done_hint.dart';
import 'package:lmstory/features/chat/presentation/utils/scroll_position_cache.dart';
import 'package:lmstory/features/chat/presentation/widgets/in_session_search_bar.dart';
import 'package:lmstory/features/chat/presentation/widgets/message_edit_dialog.dart';
import 'package:lmstory/features/chat/presentation/widgets/session_settings_sheet.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/widgets/default_model_picker_sheet.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/font_size_selector_section.dart';
import 'package:lmstory/features/settings/presentation/widgets/session_export_helper.dart';
import 'package:lmstory/features/story_runtime/domain/services/round_history_utils.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/context_usage_ring.dart';
import 'package:lmstory/i18n/strings.g.dart';

// 巨型文件物理拆解（模式同 message_bubble/、factual_memory/ 与
// advanced_chat_controller* 先例）：
// - 视图子件外移 widgets/ 独立成库（公开 Chat 前缀命名）；
// - State 业务方法按职责 part + extension 外移到下列 part 文件，
//   逻辑逐字符搬运，不引入新行为。
part 'chat_mode_page_actions.dart';
part 'chat_mode_page_input_area.dart';
part 'chat_mode_page_menus.dart';
part 'chat_mode_page_message_list.dart';
part 'chat_mode_page_scroll.dart';
part 'chat_mode_page_search.dart';

/// 对话模式聊天页面
///
/// 主文件只保留：State 字段与生命周期（controller/focusNode/
/// scrollController 的创建与 dispose）、Scaffold 骨架与组件编排。
/// 视觉子件见 widgets/，State 业务方法见上方各 part 文件。
class ChatModePage extends ConsumerStatefulWidget {
  const ChatModePage({
    required this.session,
    this.onHamburgerPressed,
    this.onSessionDeleted,
    this.showHamburgerMenu = false,
    this.scaffoldKey,
    this.drawer,
    this.initialFocusMessageId,
    super.key,
  });

  final ChatSession session;

  /// Whether to show the hamburger menu button in the AppBar.
  final bool showHamburgerMenu;

  /// Callback when the hamburger menu button is pressed.
  final VoidCallback? onHamburgerPressed;

  /// Callback when the current session is deleted.
  final VoidCallback? onSessionDeleted;

  /// Optional scaffold key (used on mobile to control the drawer).
  /// When null, the page builds its own internal key.
  final GlobalKey<ScaffoldState>? scaffoldKey;

  /// Optional drawer (used on mobile). When provided, this page acts as the
  /// top-level Scaffold so the AppBar correctly handles the status bar.
  final Widget? drawer;

  /// 全局搜索命中进入时携带：消息加载完成后滚动定位
  /// 并短暂高亮该消息。普通进入为 null。
  final String? initialFocusMessageId;

  @override
  ConsumerState<ChatModePage> createState() => _ChatModePageState();
}

class _ChatModePageState extends ConsumerState<ChatModePage>
    with SingleTickerProviderStateMixin {
  final _scrollController = ScrollController();
  final _inputController = TextEditingController();
  final _inputFocusNode = FocusNode();

  /// Token 计数相关
  int _tokenCount = 0;
  Timer? _tokenDebounce;
  String? _lastCountedText;

  /// 消息导航相关（对标 ChatBox MessageNavigation）
  /// 滚动位置状态：是否在底部、是否向上滚动过
  bool _atBottom = true;

  ///  滚动终案（照抄 director_chat_body 终案蓝图）：普通方向列表下的
  /// 贴底跟随语义。reverse 列表在阅读态直播增长（尾部 child 变高）会把
  /// 视口内容逐帧顶走、事后补偿慢一帧，流式高频更新下闪屏——普通方向
  /// 列表尾部增长发生在视口外，历史内容坐标天然稳定。
  ///
  /// 用户主动上滚 = 阅读态，停止贴底跟随；滚回底部（或点
  /// 「回到最新」）复位恢复跟随。裁决与执行交给 [FollowScrollExecutor]
  /// （单源，chatbox 语义移植）：状态机裁决「是否跟随」（任一上划
  /// 非内容收缩首帧即停、滚回距底 ≤4px 自动恢复、发送/胶囊强制回底），
  /// 执行按平台分派——桌面 ticker 逐帧指数趋近平滑贴底、移动 postFrame
  /// jumpTo 直贴（行为不回归）。
  late final FollowScrollExecutor _followExecutor;

  /// 底部容差（普通方向列表：maxExtent - offset 为距底距离）：80px 内视为贴底。
  static const double _bottomTolerance = 80;

  /// 滚动活动状态：用户正在滑动时为 true，停止 2 秒后自动设为 false
  /// 导航按钮在滑动时出现，停止后自动消失，避免遮挡阅读
  bool _isScrollActive = false;
  Timer? _scrollIdleTimer;

  /// 当前动态定位/跳转的目标消息 ID
  String? _targetScrollMessageId;

  /// 动态按需挂载的目标消息 GlobalKey 集合（不再为全量历史消息常驻几百个 GlobalKey）
  final Map<String, GlobalKey> _messageKeys = {};

  /// 输入区域实际高度，用于 SnackBar margin 计算（上移避免遮挡输入框）
  final _inputAreaKey = GlobalKey();
  double _inputAreaHeight = 100;

  /// 按会话隔离的输入草稿。
  ///
  /// 桌面端切换会话是原地替换导航栈顶，同类型 ChatModePage 的 State 被
  /// 复用，页面级 _inputController 随之跨会话存活——A 会话未发送的文字
  /// 会残留在 B 会话输入框（串台）。切走暂存、切入恢复。
  final Map<String, String> _inputDrafts = {};

  // ── 批 K：会话内搜索 ────────────────────────────
  bool _inSessionSearchVisible = false;
  int _searchFocusTick = 0; // 已可见时 Ctrl+F 的重聚焦信号
  bool _searchTruncated = false; // 命中达 SQL LIMIT（结果可能不完整）
  // 轮完成轻提示（复刻故事侧  胶囊）
  bool _roundDoneHintVisible = false;
  Timer? _roundDoneHintTimer;
  bool _roundDoneHintArmed = false;
  Timer? _searchDebounce;
  String _searchQuery = '';

  /// 命中的 messageId（升序=阅读方向）
  List<String> _searchMatchIds = const [];
  int _searchMatchCount = -1; // -1 = 搜索中
  int _currentMatchIndex = 0; // 0 = 尚未定位

  /// 请求序号守卫（对照全局搜索）——防抖
  /// 只能挡「还没发出去的」，挡不住已发出未返回的慢响应。
  int _searchSeq = 0;

  /// 搜索定位闪示：非空时该消息气泡底色短暂着色，
  /// [_flashTimer] 到时清除。
  String? _flashMessageId;
  Timer? _flashTimer;

  /// 已定位过的深链消息 id。原为布尔哨兵，
  /// 但同型页面原地复用时永不复位，会封死同 State 内的第二次全局搜索
  /// 深链——改为记录已处理 id，新焦点 id（不同消息）仍可再次定位。
  String? _focusedMessageId;

  @override
  void didUpdateWidget(covariant ChatModePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session.sessionId != widget.session.sessionId) {
      final oldText = _inputController.text;
      if (oldText.isNotEmpty) {
        _inputDrafts[oldWidget.session.sessionId] = oldText;
      } else {
        _inputDrafts.remove(oldWidget.session.sessionId);
      }
      _inputController.text = _inputDrafts[widget.session.sessionId] ?? '';
      // 同型页面原地复用（桌面 replace/同型
      // 连推），State 不随会话重建——搜索态/闪示/焦点哨兵/挂起防抖一并复位。
      _resetSearchState();
      // 完成轻提示胶囊的 5s 窗口若未走完，会悬到新会话顶部——一并复位。
      _roundDoneHintVisible = false;
      // 旧会话的
      // 滚动游标/冻结态会漏进新会话——入口跳转产生的负 delta 会被状态机
      // 误判成用户上划，新会话流式不跟随。story/director 同场景均有
      // reset（intermediate_chat_body:193 / director_chat_body:191），
      // reset 后由下方初燃定位重新建立位置。
      _followExecutor.reset();
      // 控制器缓存（非 autoDispose）+ build 内
      // ref.listen 无初燃——切到「已打开过」的会话永不出现「空→非空」
      // 跃迁，恢复阅读位置/跳底/深链定位全部失效。主动补一次初燃定位
      // （消息未就绪时仍等 listen 的真实跃迁）。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _applyEntryScrollPosition();
      });
    }
    // 桌面端同一会话再次被全局搜索命中时页面壳原地替换、State
    // 存活——initialFocusMessageId 变化是唯一的重新定位信号（哨兵按
    // 消息 id 记录，允许新焦点再次定位）。
    if (widget.initialFocusMessageId != null &&
        widget.initialFocusMessageId != oldWidget.initialFocusMessageId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _focusInitialMessage(
          ref.read(chatModeControllerProvider(widget.session)).messages,
        );
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _followExecutor = FollowScrollExecutor(
      controller: _scrollController,
      vsync: this,
    );
    _inputController.addListener(_onInputChanged);
    _scrollController.addListener(_onScroll);
    // fresh-mount 半边——HomePage↔ChatModePage 是
    // 不同 runtimeType 的同位替换，State 全新；控制器缓存（非
    // autoDispose）下 listen 永无「空→非空」跃迁，重进「已打开过」的
    // 会话既不恢复上次位置也不贴底（停在 offset 0 的最旧消息顶部）。
    // 与 didUpdateWidget 同段三选一逻辑（见 _applyEntryScrollPosition）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _applyEntryScrollPosition();
    });
  }

  @override
  void dispose() {
    // 保存当前滚动位置，以便再次进入会话时恢复
    // 2026-07-22 修复：用 controller.state.session.sessionId（物化后的真实 id），
    // 而非 widget.session.sessionId（可能是 draft id）。物化后若用 draft id
    // 保存，下次从侧边栏进入用 real id 查不到缓存，滚动位置丢失。
    if (_scrollController.hasClients) {
      final realSessionId = ref
          .read(chatModeControllerProvider(widget.session))
          .session
          .sessionId;
      ref.read(scrollPositionCacheProvider).save(
            realSessionId,
            _scrollController.offset,
          );
    }
    _tokenDebounce?.cancel();
    _scrollIdleTimer?.cancel();
    _flashTimer?.cancel();
    _roundDoneHintTimer?.cancel();
    _inputController.removeListener(_onInputChanged);
    _followExecutor.dispose();
    _scrollController
      ..removeListener(_onScroll)
      ..dispose();
    _inputController.dispose();
    _inputFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(chatModeControllerProvider(widget.session));
    //  修复：loadMessages/clearMessages/deleteSummary 等
    // 失败写入 state.error，但页面此前从未渲染——错误被静默吞掉。
    // 流式过程中自动滚动到底部（对标 ChatBox）：仅当用户已在底部附近时
    // 才自动滚动，避免用户向上查看历史时被强制拉回——回调体见
    // _handleChatStateChanged（chat_mode_page_scroll.dart）。
    ref.listen<ChatModeState>(
      chatModeControllerProvider(widget.session),
      _handleChatStateChanged,
    );

    // 测量输入区域高度，用于 SnackBar 上移避免遮挡输入框
    _scheduleInputAreaMeasure();

    // Theme override：SnackBar insetPadding 上移至输入框上方，避免遮挡输入框
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        snackBarTheme: theme.snackBarTheme.copyWith(
          insetPadding: EdgeInsets.fromLTRB(16, 0, 16, _inputAreaHeight),
        ),
      ),
      child: Scaffold(
        key: widget.scaffoldKey,
        drawer: widget.drawer,
        // 琉璃结构：会话页透明底透出场地渐变；Classic 用主题底色。
        backgroundColor: context.scaffoldBgOf(theme.scaffoldBackgroundColor),
        appBar: ChatModeAppBar(
          sessionTitle: state.session.title,
          showHamburgerMenu: widget.showHamburgerMenu,
          onHamburgerPressed: widget.onHamburgerPressed,
          onMenuPressed: () => _showChatMenu(context),
        ),
        body: LmShortcutHost(
          // 桌面键盘心智：Ctrl/Cmd+F 呼出会话内搜索，Esc 收起。
          // 键位与平台变体来自 `LmShortcuts.registry`（会话页作用域）。
          scope: LmShortcutScope.session,
          handlers: {
            LmShortcuts.idSessionSearch: _toggleInSessionSearch,
            if (_inSessionSearchVisible)
              LmShortcuts.idSessionSearchClose: _closeInSessionSearch,
          },
          child: Column(
            children: [
              // 批 K：会话内搜索条（非模态内联，AppBar 之下滑入）
              InSessionSearchBar(
                visible: _inSessionSearchVisible,
                focusTick: _searchFocusTick,
                truncationHint: _searchTruncated
                    ? t.chat.inSessionSearch.truncated(
                        n: ChatRepository.inSessionSearchLimit,
                      )
                    : null,
                query: _searchQuery,
                matchCount: _searchMatchCount,
                currentMatch: _currentMatchIndex,
                onQueryChanged: _onSearchQueryChanged,
                onNext: _gotoNextMatch,
                onPrev: _gotoPrevMatch,
                onClose: _closeInSessionSearch,
              ),
              // 消息列表 + 导航浮层
              _buildMessageListArea(state),
              //  修复：加载/清除/摘要操作失败此前写入
              // state.error 但从未渲染——错误被静默吞掉。此处内联展示，
              // 下次发送消息时 controller 会置 null 自动消失；关闭按钮供
              // 用户不再发送消息时主动清除（此前只能重进会话）。
              if (state.error != null && state.error!.isNotEmpty)
                ChatErrorBanner(
                  message: state.error!,
                  onDismiss: () => ref
                      .read(
                        chatModeControllerProvider(widget.session).notifier,
                      )
                      .clearError(),
                ),
              // 后台分支生成中——轻量指示见件内注释。
              if (state.isGeneratingInBackground)
                const ChatBackgroundGeneratingBanner(),
              // 输入区域（key 用于测量高度，供 SnackBar margin 计算）
              _buildInputArea(state),
            ],
          ),
        ),
      ),
    );
  }
}

/// ChatModeController Provider
final chatModeControllerProvider = StateNotifierProvider.family<
    ChatModeController, ChatModeState, ChatSession>(
  (ref, session) {
    return ChatModeController(
      chatRepository: ref.read(chatRepositoryProvider),
      presetRepository: ref.read(apiPresetRepositoryProvider),
      settingsRepository: ref.read(settingsRepositoryProvider),
      compactionService: ref.read(compactionServiceProvider),
      llmService: ref.read(llmServiceProvider),
      logger: ref.read(loggerProvider),
      failureLogRepository: ref.read(failureLogRepositoryProvider),
      session: session,
    );
  },
);
