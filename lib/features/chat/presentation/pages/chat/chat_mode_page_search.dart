// part of ChatModePage，仅拆分用途，不引入新逻辑。
// 详见 chat_mode_page.dart 顶部说明。
//
// 拆分：extension 不是 State 子类，访问 `setState` 等 protected 成员
// 触发 invalid_use_of_protected_member。这是 part + extension 拆分方案
// 的固有约束，运行无误，文件级忽略（沿用 advanced_chat_controller 先例）。
// ignore_for_file: invalid_use_of_protected_member

part of 'chat_mode_page.dart';

/// 拆分到本 part 文件的会话内搜索/深链定位方法（拆分）
///
/// 通过 extension 机制让方法仍属于 [_ChatModePageState] 类成员，
/// 可访问主文件中的私有字段（_searchDebounce / _searchSeq / _flashTimer
/// / _messageKeys / _followExecutor 等）。
extension _ChatModePageSearch on _ChatModePageState {
  void _focusInitialMessage(List<ChatMessage> messages) {
    final id = widget.initialFocusMessageId;
    if (id == null || _focusedMessageId == id) return;
    if (!messages.any((m) => m.messageId == id)) return;
    _focusedMessageId = id;
    _flashTimer?.cancel();
    // 闪示顺延到 reveal 收敛后：估算定位期间气泡可能尚未构建，闪在
    // 不存在的气泡上无视觉效果（同族处理）
    _revealMessageWithEstimate(id, onSettled: () => _startFlash(id));
  }

  /// 命中气泡短暂着色（闪示基建）
  void _startFlash(String messageId, {int durationMs = 1200}) {
    if (!mounted) return;
    setState(() => _flashMessageId = messageId);
    _flashTimer = Timer(Duration(milliseconds: durationMs), () {
      if (mounted) setState(() => _flashMessageId = null);
    });
  }

  // ── 批 K：会话内搜索动作 ──────────────────────────────────────────

  /// 不可见时打开；已可见时=聚焦输入框并全选（重按
  /// Ctrl+F 不再关闭——关闭走 Esc/×，符合「找东西」的心智）。
  void _toggleInSessionSearch() {
    if (_inSessionSearchVisible) {
      setState(() => _searchFocusTick++);
      return;
    }
    setState(() => _inSessionSearchVisible = true);
  }

  /// 关闭搜索条并复位瞬态（Esc/× 与切会话共用口径）
  void _closeInSessionSearch() {
    setState(() => _inSessionSearchVisible = false);
    _resetSearchState();
  }

  /// 搜索相关瞬态全量复位。关闭搜索条与
  /// 同型页面切会话共用——后者若不复位，搜索条带着 A 的查询与命中数
  /// 残留在 B 上方，挂起防抖还会以 A 的查询对 B 落库。
  void _resetSearchState() {
    _searchDebounce?.cancel();
    _searchDebounce = null;
    _searchSeq++; // 使在途请求过期
    _flashTimer?.cancel();
    _flashTimer = null;
    if (!_inSessionSearchVisible &&
        _searchQuery.isEmpty &&
        _searchMatchIds.isEmpty &&
        _searchMatchCount < 0 &&
        _currentMatchIndex == 0 &&
        _flashMessageId == null &&
        _focusedMessageId == null) {
      return;
    }
    setState(() {
      _inSessionSearchVisible = false;
      _searchQuery = '';
      _searchMatchIds = const [];
      _searchMatchCount = -1;
      _currentMatchIndex = 0;
      _flashMessageId = null;
      _focusedMessageId = null;
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
    // 300ms 防抖：打字过程中不逐键打库（product register：不打断输入流）
    _searchDebounce = debounceSearch(const Duration(milliseconds: 300), () {
      // lm-motion-exempt: 搜索去抖（交互节流，非过渡动效）
      _runInSessionSearch(value.trim());
    });
  }

  Future<void> _runInSessionSearch(String query) async {
    final seq = ++_searchSeq;
    final sessionId =
        ref.read(chatModeControllerProvider(widget.session)).session.sessionId;
    final results = await ref
        .read(chatRepositoryProvider)
        .searchMessagesInSession(sessionId, query);
    // 仅最新请求可落地，过期响应直接丢弃（对照全局搜索）
    if (!mounted || seq != _searchSeq) return;
    // await 后重读控制器：visibleIds 取更新的消息快照（分支一致性）
    final controllerState = ref.read(
      chatModeControllerProvider(widget.session),
    );
    setState(() => _searchQuery = query);
    // 消息仍在加载时 visibleIds 是空集，会把全部
    // 命中滤成「无结果」假态——保持「搜索中」计数，等空→非空跃迁重跑
    //（listen 回调内接线）。
    if (controllerState.isLoading) return;
    // 只保留当前查看分支可见的消息（分支一致性：跳转必须落在能渲染的行）
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
    final id = _searchMatchIds[index];
    // 懒加载列表的远端命中无 RenderObject，
    // `_scrollToMessage` 静默 return——长会话（搜索最高频场景）定位
    // 全失效。改走同页既有的三段式估算定位（同 `_focusInitialMessage`）；
    // 闪示顺延到气泡真实构建后（闪在未构建气泡上无视觉效果）。
    _flashTimer?.cancel();
    _revealMessageWithEstimate(id, onSettled: () => _startFlash(id));
  }

  // 空命中列表对 0 取模抛 IntegerDivisionByZeroException；
  // Prev 在尚未定位（0）时旧公式错跳 len-2——语义应为末条。
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
}
