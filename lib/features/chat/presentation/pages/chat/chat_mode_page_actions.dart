// part of ChatModePage，仅拆分用途，不引入新逻辑。
// 详见 chat_mode_page.dart 顶部说明。
//
// 拆分：extension 不是 State 子类，访问 `setState` 等 protected 成员
// 触发 invalid_use_of_protected_member。这是 part + extension 拆分方案
// 的固有约束，运行无误，文件级忽略（沿用 advanced_chat_controller 先例）。
// ignore_for_file: invalid_use_of_protected_member

part of 'chat_mode_page.dart';

/// 拆分到本 part 文件的消息动作/忙态判定方法（拆分）
///
/// 通过 extension 机制让方法仍属于 [_ChatModePageState] 类成员，
/// 可访问主文件中的私有字段（_roundDoneHintTimer / _roundDoneHintArmed
/// 等）。
extension _ChatModePageActions on _ChatModePageState {
  /// 是否处于生成类工作态（流式/思考/压缩）——
  /// 决定右下角浮层显示「回到最新」胶囊还是四键导航条。
  bool _isWorking(ChatModeState state) =>
      state.isStreaming || state.isThinking || state.isCompressing;

  /// 用户触发类操作（重生成/编辑重发/摘要编辑/
  /// 手动压缩）的忙态判定——与 controller 守卫同源（isSending ||
  /// isStreaming || isCompressing）。
  bool _isBusyForUserActions(ChatModeState state) =>
      state.isSending || state.isStreaming || state.isCompressing;

  /// 忙态统一 floating SnackBar 反馈（此前 controller 守卫静默
  /// return，点击无任何反应）。
  void _showBusyHint() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(t.chat.failure.busyOperation),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  int _lastContextTokens(List<ChatMessage> messages) {
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.tokensUsed != null) {
        return m.tokensUsed!;
      }
    }
    return 0;
  }

  void _handleSend(String text, List<MessageAttachment> attachments) {
    ref
        .read(chatModeControllerProvider(widget.session).notifier)
        .sendMessage(text, attachments: attachments);
    _forceToBottomWithSettle();
  }

  void _handleCancel() {
    // 压缩中停止键=停止压缩（流静默中止+占位摘要清理）
    final stateNow = ref.read(chatModeControllerProvider(widget.session));
    if (stateNow.isCompressing && !stateNow.isStreaming) {
      ref
          .read(chatModeControllerProvider(widget.session).notifier)
          .cancelCompaction();
      return;
    }
    // 使用 cancelSendingWithRollback 而非 cancelSending
    // 确保重新生成/编辑重发过程中终止时，回滚 Fork 分支并刷新导航按钮
    _roundDoneHintArmed = false; // 用户主动停止：完成胶囊不弹
    ref
        .read(chatModeControllerProvider(widget.session).notifier)
        .cancelSendingWithRollback();
  }

  /// 最新摘要消息 id——getCompressedMessages 取
  /// 最新压缩点，删旧摘要不改上下文，只有这张卡给「撤销压缩」语义。
  String? _latestSummaryId(ChatModeState state) {
    for (final m in state.messages.reversed) {
      if (m.isSummary && m.error == null) return m.messageId;
    }
    return null;
  }

  /// 显示轮完成胶囊（5s 自动消失）
  void _showRoundDoneHint() {
    _roundDoneHintTimer?.cancel();
    setState(() => _roundDoneHintVisible = true);
    _roundDoneHintTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _roundDoneHintVisible = false);
    });
  }

  /// 复制消息内容到剪贴板
  void _handleCopy(String content) {
    Clipboard.setData(ClipboardData(text: content));
    // 与故事/导演模式同口径——复制带反馈，
    // 对话模式此前静默（三模式同操作反馈不一致）
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(t.chat.messageActions.copySuccess),
        ),
      );
  }

  /// 删除消息
  Future<void> _handleDelete(String messageId) async {
    // controller 守卫静默 return 的页面侧前置反馈
    //（与  已修四路同口径，此前本路与删摘要/关失败卡/继续生成/
    // 清空消息同为静默 no-op）
    if (_isBusyForUserActions(
      ref.read(chatModeControllerProvider(widget.session)),
    )) {
      _showBusyHint();
      return;
    }
    await ref
        .read(chatModeControllerProvider(widget.session).notifier)
        .deleteMessage(messageId);
  }

  /// 删除摘要消息（对标 ChatBox SummaryMessage onDelete）
  ///
  /// 删除摘要 + 关联的 CompactionPoint，原始消息恢复到上下文。
  Future<void> _handleDeleteSummary(String messageId) async {
    // 同 _handleDelete 的忙态前置反馈
    if (_isBusyForUserActions(
      ref.read(chatModeControllerProvider(widget.session)),
    )) {
      _showBusyHint();
      return;
    }
    await ref
        .read(chatModeControllerProvider(widget.session).notifier)
        .deleteSummary(messageId);
  }

  /// 编辑摘要内容（对标 ChatBox SummaryMessage handleEdit）
  Future<void> _handleEditSummary(
    String messageId,
    String currentContent,
  ) async {
    final result = await MessageEditDialog.show(
      context,
      messageId: messageId,
      initialContent: currentContent,
    );

    if (result == null || !mounted) return;

    // controller 守卫静默 return 的页面侧前置反馈（同重生成）
    if (_isBusyForUserActions(
      ref.read(chatModeControllerProvider(widget.session)),
    )) {
      _showBusyHint();
      return;
    }
    await ref
        .read(chatModeControllerProvider(widget.session).notifier)
        .editSummary(messageId, result.content);
  }

  /// 重试压缩（删除失败摘要后重新触发流式压缩）
  Future<void> _handleRetryCompaction(String failedMessageId) async {
    // 入口先查忙——此前先删失败卡再进 compressHistory
    // 的防抖锁，busy 返回值被丢弃：生成中点重试会把失败卡删掉、
    // state.messages 被 DB 快照整替（未落库的流式气泡被清出屏幕），
    // 最后零提示收场。
    if (_isBusyForUserActions(
      ref.read(chatModeControllerProvider(widget.session)),
    )) {
      _showBusyHint();
      return;
    }
    await ref
        .read(chatModeControllerProvider(widget.session).notifier)
        .retryCompaction(failedMessageId);
  }

  /// 关闭失败摘要卡片（从对话流删除失败摘要消息）
  Future<void> _handleCloseFailedSummary(String messageId) async {
    // 同 _handleDelete 的忙态前置反馈
    if (_isBusyForUserActions(
      ref.read(chatModeControllerProvider(widget.session)),
    )) {
      _showBusyHint();
      return;
    }
    await ref
        .read(chatModeControllerProvider(widget.session).notifier)
        .deleteFailedSummary(messageId);
  }

  /// 重新生成助手消息（在新分支中生成）
  void _handleRegenerate(String assistantMessageId) {
    // controller 守卫静默 return 的页面侧前置反馈（此前点击无反应）
    if (_isBusyForUserActions(
      ref.read(chatModeControllerProvider(widget.session)),
    )) {
      _showBusyHint();
      return;
    }
    _roundDoneHintArmed = true;
    ref
        .read(chatModeControllerProvider(widget.session).notifier)
        .regenerateInNewFork(assistantMessageId);
    _forceToBottomWithSettle();
  }

  /// 引用消息
  void _handleQuote(String messageId) {
    ref
        .read(chatModeControllerProvider(widget.session).notifier)
        .quoteMessage(messageId);
  }

  /// 切换 Fork 分支
  Future<void> _handleForkSwitch(
    String anchorUserMsgId,
    ForkSwitchDirection direction,
  ) async {
    await ref
        .read(chatModeControllerProvider(widget.session).notifier)
        .switchFork(anchorUserMsgId, direction);
  }

  /// 编辑用户消息（打开编辑弹窗）
  Future<void> _handleEdit(String messageId, String currentContent) async {
    final result = await MessageEditDialog.show(
      context,
      messageId: messageId,
      initialContent: currentContent,
    );

    if (result == null || !mounted) return;

    if (result.saveAndResend) {
      // 编辑弹窗打开期间可能进入生成态——controller 守卫静默
      /// return 的页面侧前置反馈（此前「保存并重发」点击无反应）
      if (_isBusyForUserActions(
        ref.read(chatModeControllerProvider(widget.session)),
      )) {
        _showBusyHint();
        return;
      }
      await ref
          .read(chatModeControllerProvider(widget.session).notifier)
          .editAndResendInNewFork(result.messageId, result.content);
      _forceToBottomWithSettle();
    } else {
      // 仅保存与保存并重发同款忙态
      // 前置反馈——生成/流式期间原地保存用户消息，随后取消/失败触发的
      // pendingForkRollback 会用 originalContent 覆盖刚保存的编辑。
      if (_isBusyForUserActions(
        ref.read(chatModeControllerProvider(widget.session)),
      )) {
        _showBusyHint();
        return;
      }
      // 仅保存：原地更新内容
      await ref
          .read(chatModeControllerProvider(widget.session).notifier)
          .editMessageContent(result.messageId, result.content);
    }
  }
}
