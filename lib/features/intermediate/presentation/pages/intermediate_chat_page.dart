import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_shortcuts.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/widgets/model_config_banner.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/presentation/widgets/in_session_search_bar.dart';
import 'package:lmstory/features/intermediate/domain/entities/intermediate_chat_state.dart';
import 'package:lmstory/features/intermediate/presentation/controllers/intermediate_chat_controller.dart';
import 'package:lmstory/features/intermediate/presentation/pages/intermediate_chat_body.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/intermediate_session_settings_sheet.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/story_export_sheet.dart';
import 'package:lmstory/features/memory/domain/services/fact_context_builder.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_models_settings_page.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/font_size_selector_section.dart';
import 'package:lmstory/features/story_runtime/domain/services/manual_compact_result.dart';
import 'package:lmstory/features/story_runtime/domain/services/memory_consolidator.dart';
import 'package:lmstory/features/story_runtime/domain/services/round_history_utils.dart';
import 'package:lmstory/features/story_runtime/domain/services/session_title_generator.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/context_usage_ring.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/failure_bar.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/intermediate_chat_input.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 中级模式聊天页面（DOC-06B §5 进入转场 + 页面级夜航主题）。
///
/// 与 ChatModePage 接口对齐（session/scaffoldKey/drawer/showHamburgerMenu/
/// onHamburgerPressed/onSessionDeleted），由 main_layout 按 session.mode 统一分发。
///
/// 关键设计（母计划）：
/// - 配色随全局主题（夜航已收编为全局夜间基础）；顶层 Theme 仅覆盖
///   snackbar inset（避让输入区）
/// - 内层 `EntryTransition` 包裹（进入时播放夜航转场）
/// - body 用 Column 叠加消息列表 + FailureBar（：FailureBar 固定底部条）
class IntermediateChatPage extends ConsumerStatefulWidget {
  const IntermediateChatPage({
    required this.session,
    this.scaffoldKey,
    this.drawer,
    this.showHamburgerMenu = false,
    this.onBackToHome,
    this.onHamburgerPressed,
    this.onSessionDeleted,
    this.initialFocusMessageId,
    super.key,
  });

  final ChatSession session;

  /// 是否显示汉堡菜单（移动端）
  final bool showHamburgerMenu;
  final VoidCallback? onBackToHome;

  /// 汉堡菜单回调
  final VoidCallback? onHamburgerPressed;

  /// 当前会话被删除时回调（返回主界面）
  final VoidCallback? onSessionDeleted;

  /// 全局搜索命中进入时携带：消息加载完成后滚动定位
  /// 并短暂高亮该消息。普通进入为 null。
  final String? initialFocusMessageId;

  /// Scaffold key（移动端控制 Drawer）
  final GlobalKey<ScaffoldState>? scaffoldKey;

  /// Drawer widget（移动端）
  final Widget? drawer;

  @override
  ConsumerState<IntermediateChatPage> createState() =>
      _IntermediateChatPageState();
}

class _IntermediateChatPageState extends ConsumerState<IntermediateChatPage> {
  // 2026-07-21：用户主动关闭「未配置嵌入模型」Banner 后，本会话内不再显示
  // 重启 App 或切换会话后重新检测（若仍未配置则再次显示）
  bool _embeddingBannerDismissed = false;

  /// 世界状态条关闭标记（页面 State 生命周期内记住）
  bool _worldBarDismissed = false;

  // 2026-07-29 推荐回复：输入框 GlobalKey，供工具栏按钮调用 insertAtCursor
  // 工具栏的"添加引号/括号/推荐回复"通过此 key 在光标位置插入文本。
  /// 按会话隔离的输入草稿（与对话模式 ChatModePage._inputDrafts 同款）
  final Map<String, String> _inputDrafts = {};

  /// 输入防抖落库计时器（500ms 静默后写窄列；dispose 只取消不写）。
  Timer? _draftDebounce;

  /// 未发送草稿窄列持久化（fire-and-forget；空串=清空，发送后调用）。

  /// 输入文本变化 → 防抖 500ms 落库（退出兜底主力；dispose 只取消）。
  void _onDraftTextChanged(String text) {
    _draftDebounce?.cancel();
    final sessionId = widget.session.sessionId;
    // lm-motion-exempt: 草稿落库去抖（交互节流，非过渡动效）
    _draftDebounce = Timer(const Duration(milliseconds: 500), () {
      _persistDraftColumn(sessionId, text);
    });
  }

  void _persistDraftColumn(String sessionId, String text) {
    // 同步+异步双兜底：持久化失败静默降级（草稿非关键路径，不炸页面）
    unawaited(
      () async {
        try {
          await ref
              .read<ChatRepository>(chatRepositoryProvider)
              .setSessionDraft(sessionId, text.isEmpty ? null : text);
        } catch (_) {}
      }(),
    );
  }

  /// 跨重启恢复：页面级 Map 未命中时读库（输入框仍空才落，不覆盖新输入）。
  Future<void> _restoreDraftFromDb(String sessionId) async {
    final String? draft;
    try {
      draft = await ref
          .read<ChatRepository>(chatRepositoryProvider)
          .getSessionDraft(sessionId);
    } catch (_) {
      return; // 读库失败静默降级（不炸页面）
    }
    if (!mounted || draft == null || draft.isEmpty) return;
    if (widget.session.sessionId != sessionId) return;
    final current = _inputKey.currentState?.currentText ?? '';
    if (current.isEmpty) {
      _inputKey.currentState?.setText(draft);
    }
  }

  final GlobalKey<IntermediateChatInputState> _inputKey =
      GlobalKey<IntermediateChatInputState>();

  /// body 句柄——会话内搜索命中定位（revealAndFlash）
  final GlobalKey<IntermediateChatBodyState> _bodyKey =
      GlobalKey<IntermediateChatBodyState>();

  // ── ：会话内搜索（自 ChatModePage 移植）──────────
  bool _inSessionSearchVisible = false;
  String _searchQuery = '';
  List<String> _searchMatchIds = const [];
  int _searchMatchCount = -1; // -1 = 搜索中（尚未回填）
  int _currentMatchIndex = 0; // 1 起；0 = 尚未定位
  int _searchSeq = 0; // 过期请求哨兵（口径）
  Timer? _searchDebounce;
  int _searchFocusTick = 0;
  bool _searchTruncated = false; // 命中达 SQL LIMIT（口径）

  // 底部输入区域（InputToolbar + IntermediateChatInput）实际高度。
  // 用于 SnackBar margin 计算：SnackBar 上移至输入框上方，避免遮挡。
  double _bottomAreaHeight = 100;
  final _bottomAreaKey = GlobalKey();
  bool _bottomAreaMeasurementScheduled = false;

  // 2026-07-22 修复：历史消息加载已移至 IntermediateChatController 构造函数，
  // 与 ChatModeController 一致。之前在 initState 中调用 loadHistory()，
  // 但故事模式->故事模式切换会话时 State 被复用（widget 类型相同且无 key），
  // initState 不重新调用，导致新会话消息不加载、UI 显示空状态。

  @override
  void initState() {
    super.initState();
    _scheduleBottomAreaMeasurement();
    // 页面首次创建时检查是否需要回写草稿（如异常中断后重新进入）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tryRestoreDraft();
      // 跨重启恢复：控制器 userInput 无待恢复时读库（Map 冷启动恒空）
      if (mounted) unawaited(_restoreDraftFromDb(widget.session.sessionId));
    });
  }

  @override
  void didUpdateWidget(covariant IntermediateChatPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切会话时检查新会话是否需要回写草稿
    if (oldWidget.session.sessionId != widget.session.sessionId) {
      // 搜索态随会话切换全量复位——搜索条带着 A
      // 查询与命中数残留在 B 上方（口径）
      _resetSearchState();
      // 会话级关闭标记随会话切换复位——注释口径
      // （Banner「切换会话后重新检测」）与旧行为相反，世界状态条同理；
      // 两标记都是页面 State，故事→故事原地复用时不复位会跨会话泄漏。
      if (_embeddingBannerDismissed || _worldBarDismissed) {
        setState(() {
          _embeddingBannerDismissed = false;
          _worldBarDismissed = false;
        });
      }
      // 切走前暂存未发送文字（对话模式早有
      /// _inputDrafts，故事/导演此前切走即清空——丢的是创作内容）
      final oldText = _inputKey.currentState?.currentText ?? '';
      if (oldText.isNotEmpty) {
        _inputDrafts[oldWidget.session.sessionId] = oldText;
      } else {
        _inputDrafts.remove(oldWidget.session.sessionId);
      }
      _draftDebounce?.cancel();
      _persistDraftColumn(oldWidget.session.sessionId, oldText);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final state =
            ref.read(intermediateChatControllerProvider(widget.session));
        final restorable = state.pendingUserMessage == null &&
            state.userInput != null &&
            state.userInput!.isNotEmpty &&
            state.phase == IntermediatePhase.idle;
        if (restorable) {
          _tryRestoreDraft();
        } else {
          // 无待恢复草稿时优先用页面级暂存，
          // 都没有才清空（防上一会话文字串台）
          final stashed = _inputDrafts[widget.session.sessionId] ?? '';
          if (stashed.isNotEmpty) {
            _inputKey.currentState?.setText(stashed);
          } else {
            _inputKey.currentState?.setText('');
            // 跨重启恢复：同 State 会话内暂存未命中时读库
            unawaited(_restoreDraftFromDb(widget.session.sessionId));
          }
        }
      });
    }
  }

  @override
  void dispose() {
    _draftDebounce?.cancel();
    _searchDebounce?.cancel();
    super.dispose();
  }

  // ── ：会话内搜索（自 ChatModePage :172-302 移植）───

  /// 不可见时打开；已可见时=聚焦输入框并全选（重按 Ctrl+F 不再关闭——
  /// 关闭走 Esc/×，符合「找东西」的心智）。
  void _toggleInSessionSearch() {
    if (_inSessionSearchVisible) {
      setState(() => _searchFocusTick++);
      return;
    }
    setState(() => _inSessionSearchVisible = true);
  }

  /// 关闭搜索条并复位瞬态（Esc/× 与切会话共用口径）
  void _closeInSessionSearch() {
    _resetSearchState();
  }

  /// 搜索相关瞬态全量复位（关闭搜索条与切会话共用）。
  void _resetSearchState() {
    _searchDebounce?.cancel();
    _searchDebounce = null;
    _searchSeq++; // 使在途请求过期
    if (!_inSessionSearchVisible &&
        _searchQuery.isEmpty &&
        _searchMatchIds.isEmpty &&
        _searchMatchCount < 0 &&
        _currentMatchIndex == 0) {
      return;
    }
    setState(() {
      _inSessionSearchVisible = false;
      _searchQuery = '';
      _searchMatchIds = const [];
      _searchMatchCount = -1;
      _currentMatchIndex = 0;
      _searchTruncated = false;
    });
  }

  void _onSearchQueryChanged(String value) {
    _searchDebounce?.cancel();
    if (value.trim().isEmpty) {
      _searchSeq++; // 使在途请求过期
      setState(() {
        _searchQuery = value;
        _searchMatchIds = const [];
        _searchMatchCount = -1;
        _currentMatchIndex = 0;
        _searchTruncated = false;
      });
      return;
    }
    // 300ms 防抖：打字过程中不逐键打库
    _searchDebounce = debounceSearch(const Duration(milliseconds: 300), () {
      // lm-motion-exempt: 搜索去抖（交互节流，非过渡动效）
      _runInSessionSearch(value.trim());
    });
  }

  Future<void> _runInSessionSearch(String query) async {
    final seq = ++_searchSeq;
    final controllerState = ref.read(
      intermediateChatControllerProvider(widget.session),
    );
    final results = await ref
        .read(chatRepositoryProvider)
        .searchMessagesInSession(controllerState.session.sessionId, query);
    // 仅最新请求可落地，过期响应直接丢弃
    if (!mounted || seq != _searchSeq) return;
    setState(() => _searchQuery = query);
    // 只保留当前可见消息（命中定位必须落在能渲染的行；压缩归档的旧消息
    // 由  同款回退兜底）
    final visibleIds = controllerState.messages.map((m) => m.messageId).toSet();
    final ids = [
      for (final r in results)
        if (visibleIds.contains(r.messageId)) r.messageId,
    ];
    setState(() {
      _searchMatchIds = ids;
      _searchMatchCount = ids.length;
      _currentMatchIndex = 0;
      _searchTruncated = results.length >= ChatRepository.inSessionSearchLimit;
    });
    if (ids.isNotEmpty) _gotoMatch(0);
  }

  void _gotoMatch(int index) {
    if (index < 0 || index >= _searchMatchIds.length) return;
    setState(() => _currentMatchIndex = index + 1);
    _bodyKey.currentState?.revealAndFlash(_searchMatchIds[index]);
  }

  void _gotoNextMatch() {
    final n = _searchMatchIds.length;
    if (n == 0) return;
    _gotoMatch(_currentMatchIndex % n);
  }

  void _gotoPrevMatch() {
    final n = _searchMatchIds.length;
    if (n == 0) return;
    final target =
        _currentMatchIndex <= 0 ? n - 1 : (_currentMatchIndex - 2 + n) % n;
    _gotoMatch(target);
  }

  /// 导出稿件（AppBar 菜单入口）
  Future<void> _showExportSheet() async {
    final state = ref.read(intermediateChatControllerProvider(widget.session));
    await StoryExportSheet.show(context, state);
  }

  /// 检测中断后需要回写输入框的场景，把 userInput 回写到输入框。
  ///
  /// 触发条件：pendingUserMessage 为空（气泡已消失）+ userInput 非空
  /// + phase=idle。覆盖取消生成、后台恢复中断、清空本轮等场景。
  /// 回写后立即清空 userInput，避免重复触发。
  void _tryRestoreDraft() {
    final state = ref.read(
      intermediateChatControllerProvider(widget.session),
    );
    if (state.pendingUserMessage == null &&
        state.userInput != null &&
        state.userInput!.isNotEmpty &&
        state.phase == IntermediatePhase.idle) {
      _inputKey.currentState?.setText(state.userInput!);
      ref
          .read(intermediateChatControllerProvider(widget.session).notifier)
          .clearUserInput();
    }
  }

  void _scheduleBottomAreaMeasurement() {
    if (_bottomAreaMeasurementScheduled) return;
    _bottomAreaMeasurementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bottomAreaMeasurementScheduled = false;
      if (!mounted) return;
      final box =
          _bottomAreaKey.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) return;
      final height = box.size.height + 8;
      if ((height - _bottomAreaHeight).abs() > 1) {
        setState(() => _bottomAreaHeight = height);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(
      intermediateChatControllerProvider(widget.session),
    );

    // 监听 state 变化：中断后（cancel/recoverIfStuck/clearRound 清空
    // pendingUserMessage + 保留 userInput）自动回写到输入框
    ref.listen<IntermediateChatState>(
      intermediateChatControllerProvider(widget.session),
      (previous, next) {
        if (previous?.pendingUserMessage != null &&
            next.pendingUserMessage == null &&
            next.userInput != null &&
            next.userInput!.isNotEmpty &&
            next.phase == IntermediatePhase.idle) {
          _tryRestoreDraft();
        }
      },
    );

    // 1. 顶层 Theme 包裹夜航主题（页面级，不改全局）
    // SnackBar insetPadding 覆盖：上移至输入框上方，避免遮挡输入框
    return NotificationListener<SizeChangedLayoutNotification>(
      onNotification: (_) {
        _scheduleBottomAreaMeasurement();
        return false;
      },
      child: Theme(
        // 仅覆盖 snackbar inset（避让输入区）；配色随全局主题。
        data: Theme.of(context).copyWith(
          snackBarTheme: Theme.of(context).snackBarTheme.copyWith(
                insetPadding: EdgeInsets.fromLTRB(16, 0, 16, _bottomAreaHeight),
              ),
        ),
        child: context.lmUi
            .entryTransition(context, child: _buildScaffold(context, state)),
      ),
    );
  }

  Widget _buildScaffold(BuildContext context, IntermediateChatState state) {
    final colors = context.lm.palette;
    // 读取 stream 配置中的折叠延迟，传给 IntermediateChatBody
    // 配置未加载时用 null，body 内部默认值兜底（generatingFoldDelayMs=2000, retrievalFoldDelayMs=1000）
    final intermediateConfig =
        ref.watch(intermediateConfigProvider).valueOrNull;
    final streamConfig = intermediateConfig?.stream;
    // 读取 fork 配置中的窗口轮数，传给 IntermediateChatBody
    // 配置未加载时用默认值 5（ForkConfig 构造函数默认值）
    final forkConfig = intermediateConfig?.fork;
    final windowRounds = forkConfig?.regenerateWindowRounds ??
        const ForkConfig().regenerateWindowRounds;
    final controller = ref.read(
      intermediateChatControllerProvider(widget.session).notifier,
    );
    final t = Translations.of(context);

    // 空态模型未配置引导（判定链与 _precheckAndMaterializeDraft 同源：
    // generating 不可用且 extracting 亦不可用）。解析期间不显示。
    final modelsReady = ref.watch(storyModelsReadyProvider(state.session));

    // 字体大小 → 缩放比例（与 ChatModePage 共享 kFontSizeBaseSize）
    // 故事模式基准字号（助手 16px / 用户 15px）保持不变，fontScale 应用到基准上，
    // 让通用设置中的"字体大小"同时控制两种模式的显示大小。
    final fontSize = ref.watch(
      settingsNotifierProvider.select((s) => s.fontSize),
    );
    final fontScale =
        fontSize.clamp(kFontSizeMin, kFontSizeMax) / kFontSizeBaseSize;
    final sendKey = ref.watch(
      settingsNotifierProvider.select((s) => s.sendKey),
    );
    final newlineKey = ref.watch(
      settingsNotifierProvider.select((s) => s.newlineKey),
    );

    // 返回手势由外层 MainLayout 的 PopScope 统一处理（与 ChatModePage 对齐）。
    // controller 是 non-autoDispose，生成中返回后台继续，重新进入可查看进度。
    // 桌面键盘心智：Ctrl/Cmd+F 呼出会话内搜索，Esc 收起。
    // 键位与平台变体来自 `LmShortcuts.registry`（会话页作用域）——
    // 与对话模式页共用同一条注册项，不再各写一份。
    return LmShortcutHost(
      scope: LmShortcutScope.session,
      handlers: {
        LmShortcuts.idSessionSearch: _toggleInSessionSearch,
        if (_inSessionSearchVisible)
          LmShortcuts.idSessionSearchClose: _closeInSessionSearch,
      },
      child: Scaffold(
        key: widget.scaffoldKey,
        drawer: widget.drawer,
        // 琉璃结构：透明底透出场地渐变；阅读/流式区零 blur（红线）。
        backgroundColor: context.scaffoldBgOf(colors.bg),
        appBar: AppBar(
          leading: widget.onBackToHome != null
              ? IconButton(
                  //  语义缺口：复用框架本地化文案（不新增 i18n key）。
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  icon: const Icon(Icons.arrow_back),
                  onPressed: widget.onBackToHome,
                )
              : widget.showHamburgerMenu
                  ? IconButton(
                      //  语义缺口：复用框架本地化文案（不新增 i18n key）。
                      tooltip: MaterialLocalizations.of(context)
                          .openAppDrawerTooltip,
                      icon: const Icon(Icons.menu),
                      onPressed: widget.onHamburgerPressed,
                    )
                  : null,
          title: Text(
            state.session.title,
            style: IntermediateTextStyles.title.copyWith(color: colors.ink),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          backgroundColor: context.scaffoldBgOf(colors.bg),
          foregroundColor: colors.ink,
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
          actions: [
            // 会话菜单——会话内搜索 / 稿件导出
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert),
              tooltip: t.intermediate.chat.export.menuLabel,
              onSelected: (value) {
                switch (value) {
                  case 'search':
                    _toggleInSessionSearch();
                  case 'export':
                    _showExportSheet();
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'search',
                  child: Row(
                    children: [
                      const Icon(Icons.search, size: 18),
                      const SizedBox(width: IntermediateSpacing.sSm),
                      Text(t.chat.inSessionSearch.menuTitle),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'export',
                  child: Row(
                    children: [
                      const Icon(Icons.file_download_outlined, size: 18),
                      const SizedBox(width: IntermediateSpacing.sSm),
                      Text(t.intermediate.chat.export.menuLabel),
                    ],
                  ),
                ),
              ],
            ),
            // 会话设置入口：弹出 IntermediateSessionSettingsSheet
            // 生成中也可查看设置（sheet 内部通过 phase 守卫禁用控件）
            IconButton(
              icon: const Icon(Icons.settings_outlined),
              tooltip: t.intermediate.chat.sessionSettings.title,
              onPressed: _showSessionSettings,
            ),
          ],
        ),
        // 2026-08-02 修复 v5（一次性全部 4 场景 + 正常状态无空白）。
        // 历史失败原因：
        // v1: Flexible(loose) 不强制收缩 + 内层估算高度不准
        // v2: LayoutBuilder 放 Column 末尾非 Flexible child → height unbounded → ∞
        // v3: Flexible(tight, flex=4/2) → 收起态撑满份额 → 大片空白
        // v3.1: 去 Flexible → Column(mainAxisSize.min) + ConstrainedBox(minHeight=0)
        //       → Flutter 视为"自然高度"，展开详情直接溢出
        // v4: SizedBox(height=H*70%) + SingleChildScrollView
        //       → 正常状态（无 FailureBar）强行占 70% body 高度 → 输入框跑到屏幕中间
        //
        // v5 最终方案（差异化架构，正常/失败态分别处理）：
        // - Scaffold body 整体 LayoutBuilder，拿到 bodyMaxHeight 用于后续计算
        // - 正常状态（phase != failed）：底部区直接用 Column(mainAxisSize.min)，
        //   不强制占比，紧贴屏幕底部，无空白。外层无限高，内部各自渲染。
        // - 失败状态（phase == failed）：底部区外层套
        //   ConstrainedBox(maxHeight: H × 55%/70%) + SingleChildScrollView
        //   → 终极兜底。FailureBar 详情、SuggestOverlay、工具栏、输入框叠加
        //   高度超过 bottomMaxHeight 时内部滚动，不溢出黄黑条纹。
        // - FailureBar 双层约束：外层 ConstrainedBox(maxHeight: bottomMaxHeight×60%)
        //   + 内部 Container(maxHeight) + SingleChildScrollView。
        // - 收起态 FailureBar 用 mainAxisSize.min 只占自身高度，不留空白。
        body: LayoutBuilder(
          builder: (context, constraints) {
            final bodyMaxHeight = constraints.maxHeight;
            final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
            final isFailed = state.phase == IntermediatePhase.failed &&
                state.failureContext != null;

            // 只有失败态才需要计算最大高度；正常态不限高，按自然高度紧贴底部
            final bottomMaxHeight =
                isFailed ? bodyMaxHeight * (keyboardOpen ? 0.55 : 0.70) : null;

            // FailureBar 最大可用高度（失败态 + 键盘弹出时受限）
            final failureBarMaxHeight =
                (isFailed && keyboardOpen && bottomMaxHeight != null)
                    ? bottomMaxHeight * 0.60
                    : null;

            final hasSuggestOverlay = _shouldShowSuggestOverlay(state);

            return Column(
              children: [
                // 会话顶部世界状态条（叙事时间 + 最近事实一行，
                // 折叠可关；会话有叙事时间或已检索事实才显示）
                if (!_worldBarDismissed && _hasWorldStatus(state))
                  _buildWorldStatusBar(colors, state),
                // 空态模型未配置引导（更根本的断崖，置于嵌入横幅之上）
                if (state.messages.isEmpty && modelsReady.value == false)
                  ModelConfigBanner(
                    title: t.intermediate.chat.modelConfigBanner.title,
                    message: t.intermediate.chat.modelConfigBanner.message,
                    actionLabel:
                        t.intermediate.chat.modelConfigBanner.configure,
                    dismissTooltip:
                        t.intermediate.chat.modelConfigBanner.dismiss,
                    onConfigure: _goToModelsConfig,
                  ),
                // 2026-07-21：未配置 embedding 模型时常驻提示 Banner
                if (intermediateConfig != null &&
                    !_embeddingBannerDismissed &&
                    (intermediateConfig.embeddingPresetId.isEmpty ||
                        intermediateConfig.embeddingModelId.isEmpty))
                  context.lmUi.embeddingMissingBanner(
                    context,
                    onConfigure: _goToEmbeddingSettings,
                    onDismiss: () =>
                        setState(() => _embeddingBannerDismissed = true),
                  ),
                // 会话内搜索条（非模态内联，AppBar 之下
                // 滑入；组件复用 chat 侧 InSessionSearchBar）
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
                // 消息列表：占剩余空间（故事模式六步面板；导演模式已拆分至
                // AdvancedChatPage + DirectorChatBody）
                Expanded(
                  child: IntermediateChatBody(
                    key: _bodyKey,
                    state: state,
                    onRetryRetrieval: controller.retry,
                    windowRounds: windowRounds,
                    canOperate: (msg) => controller.canOperateMessage(
                      msg,
                      windowRounds: windowRounds,
                    ),
                    onCopy: _handleCopy,
                    onRegenerate: _handleRegenerate,
                    onEdit: _handleEdit,
                    onDeleteRound: _handleDeleteRound,
                    // 稿件变体切换
                    onSwitchVariant: controller.switchMessageVariant,
                    onDeleteVariant: controller.deleteMessageVariant,
                    onVariantFlashConsumed: controller.clearVariantFlash,
                    // U2（2026-09-04 撤销压缩）
                    onUndoCompaction: _handleUndoCompaction,
                    generatingFoldDelayMs:
                        streamConfig?.generatingFoldDelayMs ??
                            StreamConfig.generatingFoldDelayMsDefault,
                    retrievalFoldDelayMs: streamConfig?.retrievalFoldDelayMs ??
                        StreamConfig.retrievalFoldDelayMsDefault,
                    embeddingConfigured: intermediateConfig != null &&
                        intermediateConfig.embeddingPresetId.isNotEmpty &&
                        intermediateConfig.embeddingModelId.isNotEmpty,
                    fontScale: fontScale,
                    initialFocusMessageId: widget.initialFocusMessageId,
                    // 示例开场一键填入输入框
                    onUseExample: (example) =>
                        _inputKey.currentState?.setText(example),
                  ),
                ),
                // ── 底部区域：正常态/失败态分架构 ────────────────────
                if (!isFailed)
                  // 正常态：Column(mainAxisSize.min)，按自然高度，紧贴底部。
                  // 不套任何 SizedBox/ConstrainedBox 以免留下空白。
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (hasSuggestOverlay)
                        Padding(
                          padding: const EdgeInsets.only(
                            bottom: IntermediateSpacing.sMd,
                          ),
                          child: context.lmUi.suggestReplyOverlay(
                            context,
                            replies: state.suggestReplies,
                            isGenerating: state.isGeneratingSuggest,
                            isExpanded: state.suggestExpanded,
                            isFailed: state.suggestFailed,
                            onSelect: (index) =>
                                _handleSelectSuggest(controller, index),
                            onClose: controller.closeSuggest,
                            onToggle: controller.toggleSuggest,
                            onRetry: controller.generateSuggestReplies,
                          ),
                        ),
                      // 输入区域（工具栏 + 输入框）：用 GlobalKey 测量实际高度，
                      // 供 SnackBar margin 计算使用
                      SizeChangedLayoutNotifier(
                        child: Container(
                          key: _bottomAreaKey,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              context.lmUi.inputToolbar(
                                context,
                                onAddQuote: () => _handleInsertText('""', 1),
                                onAddParen: () => _handleInsertText('()', 1),
                                onSuggest: controller.generateSuggestReplies,
                                isGeneratingSuggest: state.isGeneratingSuggest,
                                canSuggest: state.messages.isNotEmpty,
                                // 上下文圆环 chip 挂工具栏行末（满刻度=
                                // 压缩触发线；与导演同位同款）
                                trailing: ContextUsageChip(
                                  numerator: state.lastPromptTokens,
                                  denominator: state.compactionTriggerTokens,
                                  onTap: _showContextCapacitySheet,
                                ),
                              ),
                              IntermediateChatInput(
                                key: _inputKey,
                                phase: state.phase,
                                isStopping: state.isStopping,
                                // 手动压缩中禁用发送（控制器静默
                                // no-op，UI 必须同口径禁用）
                                isManualCompacting: state.isManualCompacting,
                                onSend: _handleSend,
                                onTextChanged: _onDraftTextChanged,
                                onCancel: controller.cancel,
                                sendKey: sendKey,
                                newlineKey: newlineKey,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  )
                else
                  // 失败态：外层 ConstrainedBox(maxHeight) 限制底部区总高。
                  // v6.1 修复：v6 把所有组件都包在一个 SingleChildScrollView 里 →
                  // 输入框也会被滚走，违背直觉。v6.1 拆分：只有 FailureBar +
                  // SuggestOverlay 参与滚动，工具栏 + 输入框永远固定在底部。
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: bottomMaxHeight!),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // 可滚动区域：FailureBar + SuggestOverlay
                        // Flexible(loose) 占剩余空间但不超过，内容不满时
                        // 只占自身高度（无空白），超高时 SingleChildScrollView 滚动。
                        Flexible(
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                FailureBar(
                                  failureContext: state.failureContext!,
                                  onRetry: controller.retry,
                                  onClear: () {
                                    controller.clearRound();
                                    _tryRestoreDraft();
                                  },
                                  onContinueWithFts5:
                                      controller.continueWithFts5Only,
                                  onContinueFromFailed:
                                      controller.continueFromFailed,
                                  // 以此收稿——仅正文
                                  // 生成/审查失败且快照非空时 FailureBar 显示
                                  onAcceptPartial:
                                      controller.acceptPartialReplyAsFinal,
                                  // 与控制器守卫同源：summarizing/persisting
                                  // 失败时快照也非空，但收稿出口是 no-op
                                  //（无法跳过已失败的摘要步），不显示按钮，
                                  // 继续按钮也维持「从中断处继续」语义。
                                  partialReplyAvailable: canAcceptPartialReply(
                                    state.partialReplySnapshot,
                                    state.failureContext?.failedPhase,
                                  ),
                                  maxHeight: failureBarMaxHeight,
                                ),
                                if (hasSuggestOverlay)
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      bottom: IntermediateSpacing.sMd,
                                    ),
                                    child: context.lmUi.suggestReplyOverlay(
                                      context,
                                      replies: state.suggestReplies,
                                      isGenerating: state.isGeneratingSuggest,
                                      isExpanded: state.suggestExpanded,
                                      isFailed: state.suggestFailed,
                                      onSelect: (index) => _handleSelectSuggest(
                                        controller,
                                        index,
                                      ),
                                      onClose: controller.closeSuggest,
                                      onToggle: controller.toggleSuggest,
                                      onRetry:
                                          controller.generateSuggestReplies,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        // 固定区域：工具栏 + 输入框，永远不滚动，始终在底部
                        // 用 GlobalKey 测量实际高度，供 SnackBar margin 计算
                        SizeChangedLayoutNotifier(
                          child: Container(
                            key: _bottomAreaKey,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                context.lmUi.inputToolbar(
                                  context,
                                  onAddQuote: () => _handleInsertText('""', 1),
                                  onAddParen: () => _handleInsertText('()', 1),
                                  onSuggest: controller.generateSuggestReplies,
                                  isGeneratingSuggest:
                                      state.isGeneratingSuggest,
                                  canSuggest: state.messages.isNotEmpty,
                                  // 上下文圆环 chip（失败态分支同款）
                                  trailing: ContextUsageChip(
                                    numerator: state.lastPromptTokens,
                                    denominator: state.compactionTriggerTokens,
                                    onTap: _showContextCapacitySheet,
                                  ),
                                ),
                                IntermediateChatInput(
                                  key: _inputKey,
                                  phase: state.phase,
                                  isStopping: state.isStopping,
                                  // 手动压缩中禁用发送（失败态分支同款）
                                  isManualCompacting: state.isManualCompacting,
                                  onSend: _handleSend,
                                  onTextChanged: _onDraftTextChanged,
                                  onCancel: controller.cancel,
                                  sendKey: sendKey,
                                  newlineKey: newlineKey,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  // ── 世界状态条────────────────────────────────────────

  /// 有叙事时间或最近检索事实任一存在才显示
  bool _hasWorldStatus(IntermediateChatState state) {
    final time = state.session.currentNarrativeTime;
    final facts = _worldStatusFacts(state);
    return (time != null && time.isNotEmpty) ||
        (facts != null && facts.isNotEmpty);
  }

  /// 事实槽取值优先轮内实时值
  /// （state.retrievedFacts，检索阶段即时出现），persist 清空轮内中间态
  /// 后回落到最新一轮 artifacts——进出会话生命周期一致，
  /// 不再「轮完成即消失」每轮闪烁。
  List<RetrievedFact>? _worldStatusFacts(IntermediateChatState state) {
    final live = state.retrievedFacts;
    if (live != null) return live;
    final artifacts = state.artifactsByTurnNumber;
    if (artifacts == null || artifacts.isEmpty) return null;
    final lastTurn = artifacts.keys.reduce((a, b) => a > b ? a : b);
    return artifacts[lastTurn]?.retrievedFacts;
  }

  /// 叙事时间 + 最近一轮检索事实摘要的一行状态条（可关闭）
  Widget _buildWorldStatusBar(
    LmPalette colors,
    IntermediateChatState state,
  ) {
    final t = Translations.of(context);
    final time = state.session.currentNarrativeTime;
    final facts = _worldStatusFacts(state);
    // 摘要：最近一轮检索到的实体名串（前几个；无检索结果则只显时间）
    final factSummary = facts == null || facts.isEmpty
        ? ''
        : facts.take(3).map((f) => f.entity.primaryName).join('、');

    return Container(
      margin: const EdgeInsets.fromLTRB(
        IntermediateSpacing.sMd,
        IntermediateSpacing.sSm,
        IntermediateSpacing.sMd,
        0,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: IntermediateSpacing.sMd,
        vertical: 6,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceElevated,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
        border: Border.all(color: colors.divider, width: 0.5),
      ),
      child: Row(
        children: [
          Icon(Icons.public_outlined, size: 12, color: colors.primary),
          const SizedBox(width: IntermediateSpacing.sXs),
          Expanded(
            child: Text(
              // 三态模板——首轮检索事实已到而叙事
              // 时间未落库（persist 后才有）时，空时间槽会产生
              // 「世界状态 ·  · X」双间隔断，纯事实走摘要模板。
              factSummary.isEmpty
                  ? t.intermediate.chat.worldStatusBarTime(time: time ?? '')
                  : (time == null || time.isEmpty)
                      ? t.intermediate.chat
                          .worldStatusBarSummary(summary: factSummary)
                      : t.intermediate.chat.worldStatusBar(
                          time: time,
                          summary: factSummary,
                        ),
              style: IntermediateTextStyles.caption.copyWith(
                color: colors.muted,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // 13px 裸图标垫到 32px 命中区。
          //  语义缺口：裸 InkWell+Icon 无角色也无名字，读屏器当静态文本
          // ——补 button 角色 + 复用 common.close 文案（不新增 i18n key）。
          Semantics(
            button: true,
            label: t.common.close,
            child: InkWell(
              onTap: () => setState(() => _worldBarDismissed = true),
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
              child: SizedBox(
                width: 32,
                height: 32,
                child: Icon(Icons.close, size: 14, color: colors.faint),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── ：会话设置入口 ─────────────────────────────────────────────

  /// 弹出会话设置面板（IntermediateSessionSettingsSheet）。
  ///
  /// sheet 内部通过 [intermediateChatControllerProvider] 直接读写 controller，
  /// 无需回调。生成中也可打开（sheet 通过 phase 守卫禁用控件）。
  /// backgroundColor: transparent 让 sheet 自带的圆角容器背景生效。
  void _showSessionSettings() {
    showLmSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      // 内容自绘 Handle。
      glassHandle: false,
      builder: (_) => IntermediateSessionSettingsSheet(session: widget.session),
    );
  }

  // ── 上下文用量指示（上下文用量指示 §4.1/§4.3）────────────────

  /// 上下文用量详情面板（sheet 内 Consumer watch，流式打字自动刷新）
  void _showContextCapacitySheet() {
    unawaited(
      showLmSheet<void>(
        context: context,
        // 面板自限 0.9 屏高 + 内部滚动兜底（压缩流式区出现时不被 9/16
        // 默认上限挤压溢出）
        isScrollControlled: true,
        builder: (_) => Consumer(
          builder: (context, ref, _) {
            final state = ref.watch(
              intermediateChatControllerProvider(widget.session),
            );
            return ContextUsageDetailSheet(
              contextWindowTokens: state.contextWindowTokens,
              compactionTriggerTokens: state.compactionTriggerTokens,
              lastPromptTokens: state.lastPromptTokens,
              lastCompletionTokens: state.lastCompletionTokens,
              lastCacheReadTokens: state.lastCacheReadTokens,
              // 端点未回 usage 的轮次为本地估算值，面板加「≈」+ 脚注
              isEstimated: state.lastUsageIsEstimated,
              averageCacheHit: state.averageCacheHit,
              sessionRounds: completedTurnCount(
                compactedTurnBase: state.compactedTurnBase,
                messages: state.messages,
              ),
              isManualCompacting: state.isManualCompacting,
              manualCompactionDelta: state.manualCompactionDelta,
              manualCompactionError: state.manualCompactionError,
              // 生成/压缩轮进行中按钮置灰（controller busy 守卫兜底）
              isRoundActive: state.phase != IntermediatePhase.idle &&
                  state.phase != IntermediatePhase.failed,
              onManualCompact: () {
                // 消费返回值——insufficient/busy 不再静默无反馈
                final messenger = ScaffoldMessenger.of(context);
                unawaited(
                  ref
                      .read(
                        intermediateChatControllerProvider(
                          widget.session,
                        ).notifier,
                      )
                      .manualCompact()
                      .then((result) {
                    if (!mounted) return;
                    switch (result) {
                      case ManualCompactResult.insufficient:
                        messenger.showSnackBar(
                          SnackBar(
                            behavior: SnackBarBehavior.floating,
                            content: Text(
                              t.common.contextRing.compactInsufficient,
                            ),
                          ),
                        );
                      case ManualCompactResult.busy:
                        messenger.showSnackBar(
                          SnackBar(
                            behavior: SnackBarBehavior.floating,
                            content: Text(t.common.contextRing.compactBusy),
                          ),
                        );
                      case ManualCompactResult.failed:
                        // 失败详情走 manualCompactionError（面板内展示）
                        break;
                      case ManualCompactResult.success:
                        // 2026-09-08：成功不再静默（与导演侧同款反馈）
                        messenger.showSnackBar(
                          SnackBar(
                            behavior: SnackBarBehavior.floating,
                            content: Text(
                              t.common.contextRing.compactDone,
                            ),
                          ),
                        );
                    }
                  }),
                );
              },
            );
          },
        ),
      ),
    );
  }

  // 2026-07-21：跳转到故事模式设置→嵌入模型页
  // 由「未配置嵌入模型」Banner 的「去配置」按钮调用。
  //  后嵌入模型区双模式恒显，跳转即普通导航。
  void _goToEmbeddingSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const IntermediateModelsSettingsPage(),
      ),
    );
  }

  /// 空态「故事模型未配置」横幅「去配置」：直达故事模式设置→模型。
  ///
  /// 折返后失效判定 provider 重估（配置完成横幅即消失）。
  Future<void> _goToModelsConfig() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const IntermediateModelsSettingsPage(),
      ),
    );
    if (mounted) {
      ref.invalidate(
        storyModelsReadyProvider(
          ref.read(intermediateChatControllerProvider(widget.session)).session,
        ),
      );
    }
  }

  // ──  Fork 动作回调处理 ──────────────────────────────────────────

  /// 2026-07-29 推荐回复：判断是否显示气泡浮层
  ///
  /// 显示条件：正在生成 OR 已有候选回复 OR 生成失败
  /// 不显示：无候选且非生成中且非失败（初始态/已关闭/已发送）
  bool _shouldShowSuggestOverlay(IntermediateChatState state) {
    return state.isGeneratingSuggest ||
        state.suggestReplies.isNotEmpty ||
        state.suggestFailed;
  }

  /// 2026-07-29 推荐回复：在输入框光标位置插入成对符号
  ///
  /// 供"添加引号"/"添加括号"按钮使用。插入成对符号后光标移到中间位置。
  /// - 引号 `""`：光标在两个引号之间
  /// - 括号 `()`：光标在两个括号之间
  void _handleInsertText(String text, int cursorOffset) {
    _inputKey.currentState
        ?.insertAtCursor(text, cursorOffsetFromStart: cursorOffset);
  }

  /// 2026-07-29 推荐回复：选择某条候选回复
  ///
  /// 从 controller 获取选中条文本，插入到输入框光标位置。
  /// 不清空候选列表（用户可能想再选其他条）。
  void _handleSelectSuggest(
    IntermediateChatController controller,
    int index,
  ) {
    final selected = controller.selectSuggestReply(index);
    if (selected != null) {
      _inputKey.currentState?.insertAtCursor(selected);
    }
  }

  /// 发送消息：检测残留 pendingUserMessage 时弹确认框
  ///
  /// P3 修订（DOC-09A-2 §6.5）：失败/取消后 pendingUserMessage 保留在 UI。
  /// 若用户未处理旧消息就发新消息，弹确认框询问是否覆盖，避免静默丢失。
  Future<void> _handleSend(String userInput) async {
    final currentState = ref.read(
      intermediateChatControllerProvider(widget.session),
    );
    if (currentState.pendingUserMessage != null &&
        currentState.phase != IntermediatePhase.failed) {
      final t = Translations.of(context);
      final confirmed = await context.lmUi.confirmDialog(
        context,
        title: t.intermediate.chat.messageActions.overwritePendingTitle,
        content: t.intermediate.chat.messageActions.overwritePendingConfirm,
        confirmLabel: t.common.confirm,
      );
      if (!confirmed || !mounted) return;
    }
    await ref
        .read(intermediateChatControllerProvider(widget.session).notifier)
        .sendMessage(userInput);
    // 已发送即不再是草稿（清窄列；Map 由切走分支维护）
    _persistDraftColumn(widget.session.sessionId, '');
  }

  /// 复制消息内容到剪贴板，并显示 SnackBar 反馈
  void _handleCopy(ChatMessage message) {
    final content = message.content ?? '';
    if (content.isEmpty) return;
    Clipboard.setData(ClipboardData(text: content));
    final t = Translations.of(context);
    // 与 chat 修复口径一致——floating + 防叠
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            t.intermediate.chat.messageActions.copySuccess,
          ),
        ),
      );
  }

  /// 重新生成：pendingUserMessage → 重发本轮（未落库，无 DB 删除）；
  /// 已持久化消息 → regenerateMessage（保留 user_N，删 assistant_N + 下游重写）
  ///
  /// 2026-08-17 修复：此前 pending 气泡/悬空末尾 user 消息点「重新生成」
  /// 会静默 no-op（regenerateMessage 找不到成对 assistant 直接 return）。
  Future<void> _handleRegenerate(ChatMessage message) async {
    final currentState = ref.read(
      intermediateChatControllerProvider(widget.session),
    );
    final controller = ref.read(
      intermediateChatControllerProvider(widget.session).notifier,
    );
    if (currentState.pendingUserMessage?.messageId == message.messageId) {
      await controller.retryPendingUserMessage();
      return;
    }
    await controller.regenerateMessage(message);
  }

  /// 编辑消息（保存 / 保存并发送）
  ///
  /// - pendingUserMessage：保存=更新内存文本；保存并发送=editPendingUserMessage
  /// - 已持久化用户消息：保存=editMessageContent；保存并发送=editAndResend
  /// - 已持久化助手消息：只有保存=editMessageContent
  Future<void> _handleEdit(ChatMessage message) async {
    final currentState = ref.read(
      intermediateChatControllerProvider(widget.session),
    );
    final isPending =
        currentState.pendingUserMessage?.messageId == message.messageId;

    final allowResend = isPending || message.role == 'user';

    final result = await context.lmUi.editDialog(
      context,
      initialContent: message.content ?? '',
      allowResend: allowResend,
    );
    if (result == null || !mounted) return;

    final controller = ref.read(
      intermediateChatControllerProvider(widget.session).notifier,
    );
    if (isPending) {
      if (result.resend) {
        await controller.editPendingUserMessage(result.content);
      } else {
        controller.updatePendingUserMessageContent(result.content);
      }
    } else if (result.resend) {
      await controller.editAndResend(message, result.content);
    } else {
      // 仅保存不再静默，按结果弹 floating SnackBar。
      final saved = await controller.editMessageContent(
        message,
        result.content,
      );
      if (!mounted) return;
      final t = Translations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            saved
                ? t.intermediate.chat.messageActions.saved
                : t.intermediate.chat.messageActions.saveFailed,
          ),
        ),
      );
    }
  }

  /// 删除整轮 / 删除 pendingUserMessage
  ///
  /// P3 修订：检测 targetMessage 是否为 pendingUserMessage（未持久化）。
  /// - 是 pendingUserMessage → 调 controller.deletePendingUserMessage（无 DB 删除）
  /// - 否 → 调 controller.deleteRound（删 DB 记录）
  /// 两种场景用不同确认文案，让用户清楚自己在删什么。
  Future<void> _handleDeleteRound(ChatMessage message) async {
    final currentState = ref.read(
      intermediateChatControllerProvider(widget.session),
    );
    final isPending =
        currentState.pendingUserMessage?.messageId == message.messageId;

    final t = Translations.of(context);
    final confirmed = await context.lmUi.confirmDialog(
      context,
      title: isPending
          ? t.intermediate.chat.messageActions.deletePendingTitle
          : t.intermediate.chat.messageActions.deleteTitle,
      content: isPending
          ? t.intermediate.chat.messageActions.deletePendingConfirm
          : t.intermediate.chat.messageActions.deleteConfirm,
      confirmLabel: t.common.delete,
    );
    if (!confirmed || !mounted) return;

    final controller = ref.read(
      intermediateChatControllerProvider(widget.session).notifier,
    );
    if (isPending) {
      controller.deletePendingUserMessage();
    } else {
      await controller.deleteRound(message);
    }
  }

  /// 撤销压缩（U2，2026-09-04）：控制器守卫兜底，结果用 snackbar 反馈
  Future<void> _handleUndoCompaction() async {
    final controller = ref.read(
      intermediateChatControllerProvider(widget.session).notifier,
    );
    final ok = await controller.undoCompaction();
    if (!mounted) return;
    final t = Translations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          ok
              ? t.intermediate.chat.compaction.undoSuccess
              : t.intermediate.chat.compaction.undoFailed,
        ),
      ),
    );
  }
}

/// 「以此收稿」可用性与控制器守卫（acceptPartialReplyAsFinal）同源：
/// 仅 generating/reviewing 失败且快照非空时可用。summarizing/persisting
/// 失败时流式缓冲仍满（快照非空），但收稿无法跳过已失败的摘要步——
/// 按钮点了是 no-op，「续写」文案也会误导（实为重跑摘要）。
bool canAcceptPartialReply(
  String? partialReplySnapshot,
  IntermediatePhase? failedPhase,
) =>
    (partialReplySnapshot ?? '').isNotEmpty &&
    (failedPhase == IntermediatePhase.generating ||
        failedPhase == IntermediatePhase.reviewing);

/// IntermediateChatController Provider
///
/// 仿 chatModeControllerProvider，按 ChatSession.family 创建。
/// P2 解耦后仅服务故事模式会话；导演依赖（事实层/事件日志）在
/// advancedChatControllerProvider 注入。
/// ConfigurationResolver 内联构造（与 ChatModeController 不同，中级模式无
/// presetRepository/settingsRepository 直接依赖，通过 ConfigurationResolver 封装）。
/// 故事模式模型可解析性（空态配置引导横幅显隐判定）。
///
/// 判定链与 _precheckAndMaterializeDraft 同源：generating 不可用且
/// extracting 亦不可用。key 为当前会话对象——面板改模型后即重估。
final storyModelsReadyProvider =
    FutureProvider.autoDispose.family<bool, ChatSession>((ref, session) async {
  final resolver = ref.read(configurationResolverProvider);
  final generating = await resolver.resolveIntermediatePhaseNamingConfig(
    session,
    'generating',
  );
  final extracting = generating ??
      await resolver.resolveIntermediatePhaseNamingConfig(
        session,
        'extracting',
      );
  return extracting != null;
});

final intermediateChatControllerProvider = StateNotifierProvider.family<
    IntermediateChatController, IntermediateChatState, ChatSession>(
  (ref, session) {
    return IntermediateChatController(
      chatRepository: ref.read(chatRepositoryProvider),
      configurationResolver: ConfigurationResolver(
        presetRepository: ref.read(apiPresetRepositoryProvider),
        settingsRepository: ref.read(settingsRepositoryProvider),
        logger: ref.read(loggerProvider),
      ),
      llmService: ref.read(llmServiceProvider),
      experienceRepository: ref.read(experienceRepositoryProvider),
      embeddingService: ref.read(embeddingServiceProvider),
      persistenceService: ref.read(intermediatePersistenceServiceProvider),
      failureLogRepository: ref.read(failureLogRepositoryProvider),
      tokenCounter: ref.read(tokenCounterProvider),
      getConfig: () => ref.read(intermediateConfigProvider.future),
      logger: ref.read(loggerProvider),
      session: session,
      titleGenerator: SessionTitleGenerator(
        llmService: ref.read(llmServiceProvider),
      ),
      consolidator: MemoryConsolidator(
        llmService: ref.read(llmServiceProvider),
      ),
      // 2026-07-21 修复：原 provider 创建时未注入 factContextBuilder，
      // 导致事实层检索路径完全断开（extract_facts 只写不读，state.retrievedFacts
      // 永远为 null，RetrievalPanel 永远不显示【相关事实】分区）。
      // 现注入 FactContextBuilder，让 retrieving 阶段正常查询事实实体并注入上下文。
      factContextBuilder: FactContextBuilder(
        repository: ref.read(factualRepositoryProvider),
      ),
      // 2026-08-04 修复：原生产代码未注入 compactionService，导致
      // compacting 阶段被跳过（service=null → 直接进 extracting），
      // 但 phase 已被设为 compacting → UI 每轮闪现"正在压缩对话历史"。
      // 注入后压缩可正常触发与执行，phase 与实际行为一致。
      compactionService: ref.read(intermediateCompactionServiceProvider),
    );
  },
);
