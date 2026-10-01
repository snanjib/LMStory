// part of ChatModePage，仅拆分用途，不引入新逻辑。
// 详见 chat_mode_page.dart 顶部说明。
//
// 拆分：extension 不是 State 子类，访问 `setState` 等 protected 成员
// 触发 invalid_use_of_protected_member。这是 part + extension 拆分方案
// 的固有约束，运行无误，文件级忽略（沿用 advanced_chat_controller 先例）。
// ignore_for_file: invalid_use_of_protected_member

part of 'chat_mode_page.dart';

/// 拆分到本 part 文件的滚动定位/贴底跟随方法（拆分）
///
/// 通过 extension 机制让方法仍属于 [_ChatModePageState] 类成员，
/// 可访问主文件中的私有字段（_scrollController / _followExecutor /
/// _messageKeys / _atBottom / _isScrollActive 等）。
extension _ChatModePageScroll on _ChatModePageState {
  /// 懒加载列表的远端消息无 RenderObject——先按索引比例跳到附近，
  /// 再逐视口校准到精确 reveal 偏移（故事模式同款三段式）。
  /// [onSettled] 在消息已构建（精确 reveal 或尝试耗尽）后回调一次。
  void _revealMessageWithEstimate(
    String messageId, {
    int attempts = 8,
    void Function()? onSettled,
  }) {
    _followExecutor.stop(); // 宿主自驱滚动：避免与桌面 ticker 抢帧
    _targetScrollMessageId = messageId;
    final key = _messageKeys.putIfAbsent(messageId, GlobalKey.new);
    final ctx = key.currentContext;
    if (ctx != null) {
      final renderObject = ctx.findRenderObject();
      if (renderObject != null) {
        final viewport = RenderAbstractViewport.of(renderObject);
        final target = viewport.getOffsetToReveal(renderObject, 0).offset;
        _scrollController.animateTo(
          target,
          duration: LmMotion.emphasis,
          curve: LmMotion.easeStandard,
        );
        onSettled?.call();
        return;
      }
    }
    if (!_scrollController.hasClients || attempts <= 0) {
      onSettled?.call();
      return;
    }
    final state = ref.read(chatModeControllerProvider(widget.session));
    final targetIndex =
        state.messages.indexWhere((m) => m.messageId == messageId);
    if (targetIndex < 0) {
      onSettled?.call();
      return;
    }
    final position = _scrollController.position;
    final estimate = state.messages.length > 1
        ? position.maxScrollExtent * targetIndex / (state.messages.length - 1)
        : 0.0;
    _scrollController.jumpTo(estimate.clamp(0.0, position.maxScrollExtent));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _revealMessageWithEstimate(
          messageId,
          attempts: attempts - 1,
          onSettled: onSettled,
        );
      }
    });
  }

  /// 进入会话后的初始定位——「深链 > 恢复
  /// 缓存 > 贴底」三选一。didUpdateWidget（同型页面原地复用切会话）与
  /// initState（fresh-mount，见下）共用；消息未就绪时仍等 listen 的
  /// 真实「空→非空」跃迁。
  ///
  /// 深链焦点不存在于当前会话（main_layout 陈旧 _focusMessageId
  /// 跨会话残留）时不得吞掉恢复缓存/贴底——先校验再走深链分支。
  void _applyEntryScrollPosition() {
    if (!mounted) return;
    final next = ref.read(chatModeControllerProvider(widget.session));
    if (next.messages.isEmpty) return;
    final focusId = widget.initialFocusMessageId;
    if (focusId != null && next.messages.any((m) => m.messageId == focusId)) {
      _focusInitialMessage(next.messages);
      return;
    }
    // 2026-07-22 修复：用 next.session.sessionId（物化后的真实 id），
    // 而非 widget.session.sessionId（可能是 draft id）。
    final cachedOffset =
        ref.read(scrollPositionCacheProvider).restore(next.session.sessionId);
    if (cachedOffset != null) {
      _jumpToOffsetImmediate(cachedOffset);
    } else {
      _jumpToBottomImmediate();
    }
  }

  /// 即时跳到指定偏移量（无动画），用于恢复上次查看的位置。
  /// 偏移量 clamp 到当前可滚动范围，避免消息数量变化后越界。
  /// （缓存为进程内 Map：App 升级重启即清空，不存在旧 reverse 语义残留。）
  void _jumpToOffsetImmediate(double offset) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        final maxExtent = _scrollController.position.maxScrollExtent;
        _scrollController.jumpTo(offset.clamp(0, maxExtent));
      }
    });
  }

  /// 强制回底（发送/重生成/编辑重发）：执行器恢复跟随并即时贴底
  /// （两平台一致，桌面也不走平滑），settle 校准挂 postFrame 下一帧——
  /// 发送有「一次到位」预期，懒加载列表 maxScrollExtent 修正后做单次
  /// 校准（稳态下距离 ≤1 直接 no-op；沿用  改造前发送路径的
  /// 单次 settle 语义，流式跟随路径零 settle）。
  void _forceToBottomWithSettle() {
    _followExecutor.forceToBottom();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _settleAtBottom(1);
      }
    });
  }

  /// 即时跳到底部（无动画），用于会话首次加载完成后的初始定位。
  /// 普通方向列表初始停在顶部（最旧），须显式跳底 + 收敛校准
  /// （懒加载列表的 maxScrollExtent 在远端内容布局后会修正）。
  void _jumpToBottomImmediate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
        _settleAtBottom();
      }
    });
  }

  /// 懒加载列表的 maxScrollExtent 在远端内容布局后修正；到位后再逐帧
  /// 校准，保证精确贴底（收敛至最多 3 拍，消除 8 帧级联重排风暴）。
  void _settleAtBottom([int attemptsRemaining = 3]) {
    if (!mounted ||
        attemptsRemaining <= 0 ||
        !_followExecutor.state.following) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_scrollController.hasClients ||
          !_followExecutor.state.following) {
        return;
      }
      final position = _scrollController.position;
      final distance = position.maxScrollExtent - position.pixels;
      if (distance.abs() <= 1) return;
      _scrollController.jumpTo(position.maxScrollExtent);
      if (attemptsRemaining > 1) {
        _settleAtBottom(attemptsRemaining - 1);
      }
    });
  }

  /// 滚动监听：跟随执行器喂入 + atBottom/导航可见性。
  ///
  /// - 上划即停：pixels 下降（且非内容收缩钳位）→ 冻结贴底跟随
  /// - 滚回距底 ≤4px → 自动恢复跟随
  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    final offset = position.pixels;
    final atBottom =
        position.maxScrollExtent - offset < _ChatModePageState._bottomTolerance;

    // 滚动活动状态：滑动时显示导航按钮，停止 2 秒后自动隐藏
    if (!_isScrollActive) {
      setState(() => _isScrollActive = true);
    }
    _scrollIdleTimer?.cancel();
    _scrollIdleTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _isScrollActive = false);
    });

    _followExecutor.handleScrollMetrics(offset, position.maxScrollExtent);

    if (atBottom != _atBottom) {
      setState(() => _atBottom = atBottom);
    }
  }

  /// 跳到顶部（普通方向列表：顶部 = 最旧消息 = offset 0）
  void _jumpToTop() {
    if (!_scrollController.hasClients) return;
    _followExecutor.stop(); // 宿主自驱滚动：避免与桌面 ticker 抢帧
    _scrollController.animateTo(
      0,
      duration: LmMotion.emphasis,
      curve: LmMotion.easeStandard,
    );
  }

  /// 跳到底部（普通方向列表：底部 = 最新消息 = maxScrollExtent）。
  /// 用户主动回底 = 强制恢复贴底跟随。
  void _jumpToBottom() {
    if (!_scrollController.hasClients) return;
    _followExecutor.state.forceFollowing();
    _followExecutor.stop(); // 宿主自驱滚动：避免与桌面 ticker 抢帧
    _scrollController
        .animateTo(
      _scrollController.position.maxScrollExtent,
      duration: LmMotion.slow,
      curve: LmMotion.easeEmphasis,
    )
        .whenComplete(() {
      if (mounted) _settleAtBottom(1);
    });
  }

  /// 跳到上一条用户消息（对标 ChatBox handleScrollToPrev）
  void _jumpToPrevUserMessage() {
    final messages =
        ref.read(chatModeControllerProvider(widget.session)).messages;
    final firstVisible = _findFirstVisibleIndex(messages);
    if (firstVisible == null) return;

    // 从当前可见消息向前查找 user 消息
    for (var i = firstVisible - 1; i >= 0; i--) {
      if (messages[i].role == 'user') {
        _scrollToMessage(messages[i].messageId);
        return;
      }
    }
    // 没有上一条 → 滚到顶部
    _jumpToTop();
  }

  /// 跳到下一条用户消息（对标 ChatBox handleScrollToNext）
  void _jumpToNextUserMessage() {
    final messages =
        ref.read(chatModeControllerProvider(widget.session)).messages;
    final firstVisible = _findFirstVisibleIndex(messages);
    if (firstVisible == null) return;

    // 从当前可见消息向后查找 user 消息
    for (var i = firstVisible + 1; i < messages.length; i++) {
      if (messages[i].role == 'user') {
        _scrollToMessage(messages[i].messageId);
        return;
      }
    }
    // 没有下一条 → 滚到底部
    _jumpToBottom();
  }

  /// 查找当前视口中第一个可见消息的索引（方向无关，reverse/非 reverse 都正确）
  ///
  /// 返回升序 messages 数组中"最旧的一条可见消息"的索引，供 prev/next
  /// 导航按钮使用（prev = 索引减 1 向更旧找，next = 索引加 1 向更新找）。
  int? _findFirstVisibleIndex(List<ChatMessage> messages) {
    if (!_scrollController.hasClients || messages.isEmpty) return null;
    final scrollOffset = _scrollController.offset;
    final viewportExtent = _scrollController.position.viewportDimension;
    // 优先从已挂载 RenderObject 的动态 Key 快速查找
    for (var i = 0; i < messages.length; i++) {
      final key = _messageKeys[messages[i].messageId];
      if (key == null) continue;
      final renderObject = key.currentContext?.findRenderObject();
      if (renderObject == null) continue;
      final viewport = RenderAbstractViewport.of(renderObject);
      final revealTop = viewport.getOffsetToReveal(renderObject, 0).offset;
      final revealBottom = viewport.getOffsetToReveal(renderObject, 1).offset;
      if (revealBottom >= scrollOffset &&
          revealTop <= scrollOffset + viewportExtent) {
        return i;
      }
    }
    // 绝大多数常规气泡走滚动百分比与索引估算，彻底解耦数百个常驻 GlobalKey
    final maxScroll = _scrollController.position.maxScrollExtent;
    if (maxScroll > 0) {
      final ratio = (scrollOffset / maxScroll).clamp(0.0, 1.0);
      return (ratio * (messages.length - 1))
          .round()
          .clamp(0, messages.length - 1);
    }
    return 0;
  }

  /// 滚动到指定消息（顶部对齐）
  void _scrollToMessage(String messageId) {
    if (!_scrollController.hasClients) return;
    _followExecutor.stop(); // 宿主自驱滚动：避免与桌面 ticker 抢帧
    _targetScrollMessageId = messageId;
    final key = _messageKeys.putIfAbsent(messageId, GlobalKey.new);
    final renderObject = key.currentContext?.findRenderObject();
    if (renderObject == null) {
      // CH13U-1：懒加载列表未构建的气泡不再静默失效——
      // 复用同页搜索定位的三段式估算（比例跳转 + postFrame 校准）。
      _revealMessageWithEstimate(messageId);
      return;
    }
    final viewport = RenderAbstractViewport.of(renderObject);
    final targetOffset = viewport.getOffsetToReveal(renderObject, 0).offset;
    _scrollController.animateTo(
      targetOffset,
      duration: LmMotion.emphasis,
      curve: LmMotion.easeStandard,
    );
  }

  /// 清理不再存在或不再处于聚焦状态的动态 GlobalKey，避免内存泄漏
  void _cleanupMessageKeys(List<ChatMessage> currentMessages) {
    final currentIds = {
      for (final m in currentMessages) m.messageId,
    };
    _messageKeys.removeWhere(
      (id, _) =>
          !currentIds.contains(id) ||
          (id != _targetScrollMessageId &&
              id != _flashMessageId &&
              id != widget.initialFocusMessageId),
    );
  }

  /// 流式过程中自动滚动到底部（对标 ChatBox）——build 内 ref.listen 的
  /// 回调体（仅拆分用途，逻辑原样搬运）。
  ///
  /// 仅当用户已在底部附近时才自动滚动，避免用户向上查看历史时被强制拉回。
  void _handleChatStateChanged(ChatModeState? previous, ChatModeState next) {
    // messages 变化时清理不再存在的消息对应的 GlobalKey
    // （从 build 移出，避免每次 build O(N) 遍历）
    if (previous?.messages != next.messages) {
      _cleanupMessageKeys(next.messages);
    }
    // 会话首次加载消息完成后，定位到合适位置
    // 有缓存 → 恢复上次查看的位置；无缓存 → 定位到底部（最新消息）
    if ((previous?.messages.isEmpty ?? true) &&
        next.messages.isNotEmpty &&
        !next.isStreaming) {
      // 加载空窗期发起的搜索在消息就绪后重跑
      //（matchCount 保持 -1 = 搜索中；序号守卫照常丢弃过期重跑）
      if (_inSessionSearchVisible &&
          _searchQuery.trim().isNotEmpty &&
          _searchMatchCount < 0) {
        _runInSessionSearch(_searchQuery.trim());
      }
      // 2026-07-22 修复：用 next.session.sessionId（物化后的真实 id），
      // 而非 widget.session.sessionId（可能是 draft id）。
      final cachedOffset =
          ref.read(scrollPositionCacheProvider).restore(next.session.sessionId);
      // 搜索命中进入优先定位命中消息（覆盖缓存恢复）。
      if (widget.initialFocusMessageId != null &&
          next.messages.any(
            (m) => m.messageId == widget.initialFocusMessageId,
          )) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focusInitialMessage(next.messages);
        });
        return;
      }
      if (cachedOffset != null) {
        _jumpToOffsetImmediate(cachedOffset);
      } else {
        _jumpToBottomImmediate();
      }
      return;
    }
    //  滚动终案（导演终案同语义）：
    // 发送瞬间（末尾新增 user 消息）= 用户意图明确看最新，
    // 强制回底并恢复跟随（绕过阅读态判定）。
    final userJustSent =
        (next.messages.length > (previous?.messages.length ?? 0)) &&
            next.messages.isNotEmpty &&
            next.messages.last.role == 'user';
    if (userJustSent) {
      _roundDoneHintArmed = true;
      _forceToBottomWithSettle();
      return;
    }
    // 轮完成轻提示——streaming/thinking
    // true→false 边沿且无 error 时弹顶部胶囊（5s 自动消失，点按跳底）。
    // 取消=入口清 armed；失败=error 非空；压缩紧随=nowSettled 排除；
    // 后台收工=fromBackground 排除。
    final wasActive =
        (previous?.isStreaming ?? false) || (previous?.isThinking ?? false);
    final nowSettled = !next.isStreaming &&
        !next.isThinking &&
        !next.isCompressing &&
        !next.isGeneratingInBackground;
    final fromBackground = previous?.isGeneratingInBackground ?? false;
    if (wasActive && nowSettled && !fromBackground) {
      if (next.error == null && _roundDoneHintArmed) {
        _showRoundDoneHint();
      }
      _roundDoneHintArmed = false;
    }
    final working = next.isStreaming || next.isThinking || next.isCompressing;
    if (!working) return;
    // 流式过程中 state 每次变化都触发滚动（蹦字效果需要），
    // 跟随 gate 全权交给执行器（上划即停/回底 ≤4px 自动恢复；
    // 桌面平滑趋近、移动直贴）
    if (_followExecutor.state.following) {
      _followExecutor.followGrowth();
    }
  }
}
