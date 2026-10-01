// part of ChatModePage，仅拆分用途，不引入新逻辑。
// 详见 chat_mode_page.dart 顶部说明。
//
// 拆分：extension 不是 State 子类，访问 `setState` 等 protected 成员
// 触发 invalid_use_of_protected_member。这是 part + extension 拆分方案
// 的固有约束，运行无误，文件级忽略（沿用 advanced_chat_controller 先例）。
// ignore_for_file: invalid_use_of_protected_member

part of 'chat_mode_page.dart';

/// 拆分到本 part 文件的消息列表区构建方法（拆分）
///
/// 通过 extension 机制让方法仍属于 [_ChatModePageState] 类成员，
/// 可访问主文件中的私有字段（_messageKeys / _flashMessageId /
/// _searchMatchIds / _atBottom / _isScrollActive 等）与同库各 extension
/// 的消息动作方法。
extension _ChatModePageMessageList on _ChatModePageState {
  /// 消息列表 + 导航浮层（原 build 内 Expanded(Stack(...)) 块，
  /// 逻辑原样搬运）。
  Widget _buildMessageListArea(ChatModeState state) {
    final colors = context.lm.palette;
    final displayPreferences = ref.watch(
      settingsNotifierProvider.select((s) => s.displayPreferences),
    );
    // 字体大小 → 缩放比例（与 FontSizeSelectorSection 共享 kFontSizeBaseSize）
    // fontSize 默认 15（= SimpleTextStyles.body 基准字号），fontScale = fontSize / 15
    final fontSize = ref.watch(
      settingsNotifierProvider.select((s) => s.fontSize),
    );
    final fontScale =
        fontSize.clamp(kFontSizeMin, kFontSizeMax) / kFontSizeBaseSize;

    // 构建 Fork 锚点查找表：parentUserMsgId -> ForkAnchor
    final forkAnchorMap = <String, ForkAnchor>{
      for (final a in state.forkAnchors) a.parentUserMsgId: a,
    };

    // 是否显示"生成中"占位气泡（发送后/重生成后，等待第一个 token 期间）
    // 对标 ChatBox：等待首个 token 时显示空助手气泡 + loading 指示器
    // 后台分支生成中（流式中切看旧分支）不得在被
    // 查看分支尾部渲染该占位——生成实际发生在生成分支，此处显示会让
    // 用户误以为旧分支正在追加回复；改由输入区上方轻量指示告知。
    final showGeneratingPlaceholder = state.isStreaming &&
        state.currentAssistantMessageId == null &&
        !state.isGeneratingInBackground;

    // 最后一条用户消息 ID（：仅它允许「继续生成」，避免旧锚点续写错位）
    String? lastUserMessageId;
    for (final m in state.messages.reversed) {
      if (m.role == 'user') {
        lastUserMessageId = m.messageId;
        break;
      }
    }

    return Expanded(
      child: Stack(
        children: [
          //  修复：空会话不再是白板——给出空态引导
          // 加载期不闪现空态（isLoading 到位前不判定为空）
          // 接 SimpleEmptyState 的 action——
          // 「开始对话」聚焦输入框
          if (state.messages.isEmpty &&
              !showGeneratingPlaceholder &&
              !state.isLoading)
            ChatEmptyView(onStart: _inputFocusNode.requestFocus)
          else
            // 阅读限宽：正文行长钳制到 LmReadingConstraints.width 并居中。
            // 不限宽时宽屏一行可达 200+ 字符，眼动回扫距离过长；导演模式
            // 早已施加同一 token（经 IntermediateSpacing 桥接），主会话不限宽
            // 会让两处来回切换时行长突变。限宽含左右 padding（padding 在
            // ListView 内部），且只作用于列表自身——Stack 内的导航浮层等
            // 兄弟节点仍铺满，定位与宽度不受影响；视口窄于上限时取满宽，
            // 行为与改动前一致。
            Center(
              child: RepaintBoundary(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: LmReadingConstraints.width,
                  ),
                  child: ListView.builder(
                    controller: _scrollController,
                    scrollCacheExtent: const ScrollCacheExtent.pixels(600),
                    //  滚动终案：普通方向列表（index 0 = 最旧，末尾 = 最新）。
                    // reverse 列表在阅读态直播增长会把视口内容逐帧顶走、
                    // 补偿慢一帧导致闪屏（导演模式 2026-08-31 已终案验证）。
                    // 2026-09-10：底部缓冲留白（惰性跟随用）——写入行
                    // 在缓冲内下走时视口不动，已读文字保持静止。
                    padding: const EdgeInsets.fromLTRB(
                      SimpleSpacing.sMd,
                      SimpleSpacing.sMd,
                      SimpleSpacing.sMd,
                      SimpleSpacing.sMd + streamingFollowCushionPx,
                    ),
                    itemCount: state.messages.length +
                        (showGeneratingPlaceholder ? 1 : 0),
                    itemBuilder: (context, index) {
                      // "生成中"占位气泡放最末尾（视觉底部），即生成中
                      // 助手回复的最终落点；复用 SimpleMessageBubble
                      // （空助手消息 + isStreaming=true）自动渲染旋转头像
                      // + bouncing dots 指示器
                      if (showGeneratingPlaceholder &&
                          index == state.messages.length) {
                        // 查找占位气泡对应的 Fork 锚点（regenerate/editAndResend 时）
                        final placeholderAnchor =
                            state.generatingAnchorUserMsgId != null
                                ? forkAnchorMap[state.generatingAnchorUserMsgId]
                                : null;
                        final placeholderHasFork = placeholderAnchor != null;
                        return RepaintBoundary(
                          key: const ValueKey(
                            '__generating_placeholder__',
                          ),
                          child: ChatGeneratingPlaceholderBubble(
                            // 2026-07-22 修复：用 state.session.sessionId（物化后的真实 id），
                            // 而非 widget.session.sessionId（可能是 draft id）。
                            sessionId: state.session.sessionId,
                            parentUserMsgId: state.generatingAnchorUserMsgId,
                            displayPreferences: displayPreferences,
                            fontScale: fontScale,
                            forkIndex: placeholderHasFork
                                ? placeholderAnchor.activeIndex + 1
                                : null,
                            forkCount: placeholderHasFork
                                ? placeholderAnchor.branchCount
                                : null,
                            onForkPrev: placeholderHasFork
                                ? () => _handleForkSwitch(
                                      state.generatingAnchorUserMsgId!,
                                      ForkSwitchDirection.prev,
                                    )
                                : null,
                            onForkNext: placeholderHasFork
                                ? () => _handleForkSwitch(
                                      state.generatingAnchorUserMsgId!,
                                      ForkSwitchDirection.next,
                                    )
                                : null,
                          ),
                        );
                      }
                      // 普通方向列表：index 与 state.messages 升序一一对应
                      final message = state.messages[index];
                      final msgIndex = index;
                      final isLastAssistant =
                          msgIndex == state.messages.length - 1 &&
                              message.role == 'assistant';

                      // 查找该助手消息的 Fork 锚点
                      final anchor = message.role == 'assistant' &&
                              message.parentUserMsgId != null
                          ? forkAnchorMap[message.parentUserMsgId]
                          : null;
                      final hasFork = anchor != null;
                      final forkIndex = hasFork ? anchor.activeIndex + 1 : null;
                      final forkCount = hasFork ? anchor.branchCount : null;

                      // 判断该消息是否正在生成中（用于头像旋转动画）
                      final isGenerating = (state.isStreaming ||
                              state.isThinking) &&
                          state.currentAssistantMessageId == message.messageId;

                      // 判断该条摘要消息是否正在流式生成内容（压缩进行中）
                      // 仅占位摘要消息且无 error 时展示流式状态
                      final isCompactionStreaming = state.isCompressing &&
                          message.isSummary &&
                          message.messageId ==
                              state.currentCompactionSummaryId &&
                          message.error == null;

                      // 搜索命中的消息短暂着色闪示。
                      final isFlashTarget =
                          _flashMessageId == message.messageId;
                      // 2026-09-08：命中消息在搜索条可见期间常驻
                      // 「命中上下文条」（片段 + 关键字高亮）——闪示
                      // 1.2s 后消失，用户仍不知道关键字在消息哪里。
                      final searchHitQuery = _inSessionSearchVisible &&
                              _searchQuery.trim().isNotEmpty &&
                              _searchMatchIds.contains(message.messageId)
                          ? _searchQuery.trim()
                          : null;

                      final item = AnimatedContainer(
                        duration: LmMotion.enter,
                        color: isFlashTarget
                            ? colors.primaryDim
                            : Colors.transparent,
                        child: SimpleMessageBubble(
                          key: (message.messageId == _targetScrollMessageId ||
                                  message.messageId == _flashMessageId ||
                                  message.messageId ==
                                      widget.initialFocusMessageId)
                              ? _messageKeys.putIfAbsent(
                                  message.messageId,
                                  GlobalKey.new,
                                )
                              : ValueKey<String>(message.messageId),
                          message: message,
                          searchQuery: searchHitQuery,
                          isStreaming: state.isStreaming &&
                              state.currentAssistantMessageId ==
                                  message.messageId,
                          isConsecutive: msgIndex > 0 &&
                              state.messages[msgIndex - 1].role == message.role,
                          isThinking: state.isThinking &&
                              state.currentAssistantMessageId ==
                                  message.messageId,
                          isLastAssistantMessage: isLastAssistant,
                          displayPreferences: displayPreferences,
                          fontScale: fontScale,
                          modelName: message.role == 'assistant'
                              ? state.currentModelName
                              : null,
                          isGenerating: isGenerating,
                          isCompactionStreaming: isCompactionStreaming,
                          onCopy: () => _handleCopy(message.content ?? ''),
                          onEdit: message.role == 'user'
                              ? () => _handleEdit(
                                    message.messageId,
                                    message.content ?? '',
                                  )
                              : null,
                          onDelete: () => _handleDelete(message.messageId),
                          //  修复：接通「继续生成」——仅最后一条
                          // 用户消息、非生成中可用（中断的回复以追加气泡续写）
                          onContinueGenerating:
                              message.messageId == lastUserMessageId &&
                                      !_isBusyForUserActions(state)
                                  ? () => ref
                                      .read(
                                        chatModeControllerProvider(
                                          widget.session,
                                        ).notifier,
                                      )
                                      .continueGenerating()
                                  : null,
                          onRegenerate: message.role == 'assistant'
                              ? () => _handleRegenerate(message.messageId)
                              : null,
                          onQuote: () => _handleQuote(message.messageId),
                          forkIndex: forkIndex,
                          forkCount: forkCount,
                          onForkPrev: hasFork
                              ? () => _handleForkSwitch(
                                    message.parentUserMsgId!,
                                    ForkSwitchDirection.prev,
                                  )
                              : null,
                          onForkNext: hasFork
                              ? () => _handleForkSwitch(
                                    message.parentUserMsgId!,
                                    ForkSwitchDirection.next,
                                  )
                              : null,
                          onEditSummary:
                              message.isSummary && message.error == null
                                  ? () => _handleEditSummary(
                                        message.messageId,
                                        message.content ?? '',
                                      )
                                  : null,
                          onDeleteSummary: message.isSummary &&
                                  message.error == null
                              ? () => _handleDeleteSummary(message.messageId)
                              : null,
                          // 仅最新摘要显示「撤销压缩」
                          isLatestSummary:
                              message.messageId == _latestSummaryId(state),
                          onRetryCompaction: message.isSummary &&
                                  message.error != null &&
                                  // 重试按钮与生成态联动禁用
                                  //（此前常驻可点，生成中点了先删卡）
                                  !_isBusyForUserActions(state)
                              ? () => _handleRetryCompaction(
                                    message.messageId,
                                  )
                              : null,
                          onCloseFailedSummary:
                              message.isSummary && message.error != null
                                  ? () => _handleCloseFailedSummary(
                                        message.messageId,
                                      )
                                  : null,
                        ),
                      );
                      // 流式活跃气泡单独成层：32ms 合帧期间的重绘
                      // 只落在活跃气泡自己的 layer，已生成消息不重绘
                      return (isGenerating || isCompactionStreaming)
                          ? RepaintBoundary(child: item)
                          : item;
                    },
                  ),
                ),
              ),
            ),
          // 消息导航浮层（滚动终案，导演终案同款互斥）：
          // 生成中上滚脱离底部 = 醒目「回到最新」胶囊；
          // 收工后 = 四键导航条（滑动时出现，停止 2 秒消失）。
          ChatMessageNavigationOverlay(
            working: _isWorking(state),
            pillVisible: !_atBottom,
            pillOnTap: _jumpToBottom,
            navigationVisible: _isScrollActive && !_atBottom,
            onJumpToTop: _jumpToTop,
            onJumpToBottom: _jumpToBottom,
            onPrevUserMessage: _jumpToPrevUserMessage,
            onNextUserMessage: _jumpToNextUserMessage,
          ),
          // 收工态顶部完成胶囊
          //（复刻故事侧 ：5s 自动消失，点按跳底）。
          if (_roundDoneHintVisible)
            ChatRoundDoneHint(
              onTap: () {
                setState(() => _roundDoneHintVisible = false);
                _jumpToBottom();
              },
            ),
        ],
      ),
    );
  }
}
