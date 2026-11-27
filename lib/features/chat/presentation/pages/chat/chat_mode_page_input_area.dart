// part of ChatModePage，仅拆分用途，不引入新逻辑。
// 详见 chat_mode_page.dart 顶部说明。
//
// 拆分：extension 不是 State 子类，访问 `setState` 等 protected 成员
// 触发 invalid_use_of_protected_member。这是 part + extension 拆分方案
// 的固有约束，运行无误，文件级忽略（沿用 advanced_chat_controller 先例）。
// ignore_for_file: invalid_use_of_protected_member

part of 'chat_mode_page.dart';

/// 拆分到本 part 文件的输入区装配/草稿 token 计数方法（拆分）
///
/// 通过 extension 机制让方法仍属于 [_ChatModePageState] 类成员，
/// 可访问主文件中的私有字段（_inputController / _inputAreaKey /
/// _inputAreaHeight / _tokenCount / _tokenDebounce / _lastCountedText）。
extension _ChatModePageInputArea on _ChatModePageState {
  /// 输入内容变化时 debounced 计算 token 数
  void _onInputChanged() {
    final text = _inputController.text;
    if (text == _lastCountedText) return;
    _lastCountedText = text;

    _tokenDebounce?.cancel();
    // 草稿防抖落库（与 token 计数同窗）：输入中随时退出最多丢 500ms。
    // dispose 不写库（Riverpod 生命周期禁 ref），此路径是退出兜底主力。
    _draftDebounce?.cancel();
    if (!_settingDraftText) {
      final sessionId = widget.session.sessionId;
      // lm-motion-exempt: 草稿落库去抖（交互节流，非过渡动效）
      _draftDebounce = Timer(const Duration(milliseconds: 500), () {
        _persistDraftColumn(sessionId, text);
      });
    }
    if (text.isEmpty) {
      setState(() => _tokenCount = 0);
      return;
    }
    _tokenDebounce = Timer(const Duration(milliseconds: 500), () {
      // lm-motion-exempt: 输入去抖（交互节流，非过渡动效）
      _updateTokenCount(text);
    });
  }

  Future<void> _updateTokenCount(String text) async {
    try {
      final tokenCounter = ref.read(tokenCounterProvider);
      final count = await tokenCounter.countTokens(text);
      if (mounted && _lastCountedText == text) {
        setState(() => _tokenCount = count);
      }
    } catch (_) {
      // token 计数失败时静默忽略
    }
  }

  /// 测量输入区域高度（原 build 内 postFrameCallback 块，仅拆分用途），
  /// 用于 SnackBar 上移避免遮挡输入框。
  void _scheduleInputAreaMeasure() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box =
          _inputAreaKey.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        final h = box.size.height + 8; // 8px 间距
        if ((h - _inputAreaHeight).abs() > 1) {
          setState(() => _inputAreaHeight = h);
        }
      }
    });
  }

  /// 输入区域装配（原 build 内 ChatModeInputArea 块，逻辑原样搬运；
  /// key 用于测量高度，供 SnackBar margin 计算）。
  Widget _buildInputArea(ChatModeState state) {
    final sendKey = ref.watch(
      settingsNotifierProvider.select((s) => s.sendKey),
    );
    final newlineKey = ref.watch(
      settingsNotifierProvider.select((s) => s.newlineKey),
    );
    return ChatModeInputArea(
      key: _inputAreaKey,
      draftSessionId: widget.session.sessionId,
      controller: _inputController,
      focusNode: _inputFocusNode,
      onSend: _handleSend,
      onCancel: _handleCancel,
      isSending: state.isSending,
      isStreaming: state.isStreaming,
      isCompressing: state.isCompressing,
      // 启用历史输入——空输入框按 ↑ 召回
      // 上一条用户消息（最新在前，组件按索引向旧遍历）。
      inputHistory: [
        for (final m in state.messages.reversed)
          if (m.role == 'user' && (m.content?.isNotEmpty ?? false)) m.content!,
      ],
      sendKey: sendKey,
      newlineKey: newlineKey,
      // 上下文用量圆环（与故事/导演同款）：主数字 = 当前预计上下文
      //（真实装配材料的本地计数 + 草稿）；满刻度 = 压缩触发线。
      // core 不依赖 features，圆环经 contextSlot 注入。
      contextSlot: ContextUsageChip(
        // 当前预计上下文（含草稿）；null → 圆环空态，不显示 0%
        numerator: _currentContextTokens(state),
        denominator: state.compactionTriggerTokens,
        onTap: _showContextUsageSheet,
      ),
      currentModelName: state.currentModelName,
      currentProviderName: state.currentProviderName,
      onModelSelect: _showModelSelector,
      onSessionSettings: _showSessionSettings,
      quoteText: state.quoteText,
      onClearQuote: () => ref
          .read(chatModeControllerProvider(widget.session).notifier)
          .clearQuote(),
    );
  }
}
