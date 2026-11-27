import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/shared/components/lm_state_transition.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/settings/domain/entities/input_keys.dart'
    show NewlineKey, SendKey;
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 中级模式输入框（DOC-06B 独立组件，不复用 Simple 的 ChatInput）。
///
/// 简化版（P1）：
/// - 文本输入 + 发送/停止按钮
/// - 无附件、无 token 计数、无模型选择器（P2 扩展）
/// - idle 可输入可发送；非 idle 显示"停止"按钮
///
/// 2026-07-29 推荐回复：State 改为公开类 [IntermediateChatInputState]，
/// 暴露 [IntermediateChatInputState.insertAtCursor] 供父组件通过 `GlobalKey<IntermediateChatInputState>`
/// 调用，实现"添加引号"/"添加括号"/"选择推荐回复"在光标位置插入文本。
class IntermediateChatInput extends StatefulWidget {
  const IntermediateChatInput({
    required this.phase,
    required this.onSend,
    required this.onCancel,
    this.onTextChanged,
    this.isStopping = false,
    this.isManualCompacting = false,
    this.isPreparingRegenerate = false,
    this.sendKey = SendKey.enter,
    this.newlineKey = NewlineKey.shiftEnter,
    this.isDirector = false,
    this.preserveWhitespace = false,
    this.locked = false,
    super.key,
  });

  final IntermediatePhase phase;
  final void Function(String text) onSend;

  /// 输入文本变化透传（可选；宿主挂草稿防抖落库等，去抖由宿主负责）。
  final void Function(String text)? onTextChanged;
  final VoidCallback onCancel;
  final SendKey sendKey;
  final NewlineKey newlineKey;

  /// 是否正在停止生成（2026-08-10 新增）
  ///
  /// true 时停止按钮显示灰色"正在终止"态（带脉冲动画），
  /// 发送按钮显示 loading，禁止发送新消息。
  final bool isStopping;

  /// 手动压缩进行中
  ///
  /// 手动压缩全程 phase 恒为 idle，发送判据若只看 phase 会放行——
  /// 控制器 sendMessage 遇 isManualCompacting 静默 return，用户点了
  /// 没反应。true 时发送按钮禁用（与控制器守卫同口径）。
  final bool isManualCompacting;

  /// 重生成/编辑重发「准备中」窗口
  ///
  /// 该窗口 phase 仍为 idle 但控制器拒收新消息——发送判据不同步时，
  /// 输入框会先清空再被控制器静默拒绝，内容蒸发。true 时发送禁用，
  /// 文本保留在输入框。
  final bool isPreparingRegenerate;

  /// 导演模式（修复 2026-08-23）：占位符用「给导演的指令…」而非
  /// 故事模式的「推动故事发展...」（导演与故事的输入语义不同）。
  final bool isDirector;
  final bool preserveWhitespace;

  /// 输入锁定（通用能力）：true 时文本只读（编辑/粘贴/输入法组合全
  /// 禁），发送按钮仍可用——文本由宿主经 controller 设定，用户必须
  /// 亲自点击发送。默认 false（正式会话零影响）。
  final bool locked;

  @override
  State<IntermediateChatInput> createState() => IntermediateChatInputState();
}

/// 中级模式输入框 State（公开类，供 GlobalKey 调用 [insertAtCursor]）
class IntermediateChatInputState extends State<IntermediateChatInput> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  /// 输入锁校正（宿主经 GlobalKey 调用；widget 自身无 provider 依赖）
  void enforceLockedText(String fixedText) {
    if (_controller.text != fixedText) {
      _controller
        ..text = fixedText
        ..selection = TextSelection.collapsed(offset: fixedText.length);
    }
  }

  void _onTextChanged() {
    widget.onTextChanged?.call(_controller.text);
    final hasText = _controller.text.isNotEmpty;
    if (hasText != _hasText) {
      setState(() => _hasText = hasText);
    }
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onTextChanged)
      ..dispose();
    _focusNode.dispose();
    super.dispose();
  }

  bool get _isBusy =>
      widget.phase != IntermediatePhase.idle &&
      widget.phase != IntermediatePhase.failed;

  /// 是否处于"忙碌"状态（生成中或停止中），控制停止按钮/loading 显示
  bool get _isBusyOrStopping => _isBusy || widget.isStopping;

  /// 输入框是否可输入：始终允许输入。
  ///
  ///  修复：原逻辑仅在 idle 时允许输入，导致生成过程中
  /// 用户无法提前编辑下次准备发送的内容。新逻辑：输入框始终可输入，
  /// 仅发送按钮根据 _isBusy/_canSend 禁用。
  bool get _inputEnabled => true;

  /// 是否允许发送：idle/failed 且非停止中、非手动压缩中、非重生成
  /// 准备中允许发送。
  ///
  /// failed 阶段放行直发新消息（控制器先事务性清掉失败轮残留），
  /// 用户不必先点「清空本轮」。
  /// 停止中禁止发送（防止与后台 cancel 竞态）。
  /// 手动压缩中禁止发送（：压缩全程 phase=idle，控制器静默
  /// no-op，UI 必须同口径禁用）。
  /// 重生成准备中禁止发送（同上静默 no-op 窗口，且清空先于拒绝发生
  /// 会蒸发输入）。
  bool get _canSend =>
      (widget.phase == IntermediatePhase.idle ||
          widget.phase == IntermediatePhase.failed) &&
      !widget.isStopping &&
      !widget.isManualCompacting &&
      !widget.isPreparingRegenerate;

  void _handleSend() {
    final text = _controller.text;
    final trimmed = text.trim();
    if (trimmed.isEmpty || !_canSend) return;
    _controller.clear();
    widget.onSend(widget.preserveWhitespace ? text : trimmed);
  }

  /// 在光标位置插入换行符（Ctrl+Enter / Alt+Enter 换行时调用）。
  void _insertNewlineAtCursor() {
    final selection = _controller.selection;
    final text = _controller.text;
    final newText = text.replaceRange(selection.start, selection.end, '\n');
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: selection.start + 1),
    );
  }

  /// 键盘事件处理：根据 sendKey / newlineKey 配置响应回车键。
  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!isEnter) return KeyEventResult.ignored;

    final isCtrl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final isShift = HardwareKeyboard.instance.isShiftPressed;
    final isAlt = HardwareKeyboard.instance.isAltPressed;

    // 匹配发送键
    if (_matchesSendKey(widget.sendKey, isCtrl, isShift, isAlt)) {
      _handleSend();
      return KeyEventResult.handled;
    }

    // 匹配换行键
    if (_matchesNewlineKey(widget.newlineKey, isCtrl, isShift, isAlt)) {
      if (widget.newlineKey == NewlineKey.ctrlEnter ||
          widget.newlineKey == NewlineKey.altEnter) {
        _insertNewlineAtCursor();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    return KeyEventResult.ignored;
  }

  static bool _matchesSendKey(
    SendKey key,
    bool isCtrl,
    bool isShift,
    bool isAlt,
  ) {
    switch (key) {
      case SendKey.enter:
        return !isCtrl && !isShift && !isAlt;
      case SendKey.shiftEnter:
        return isShift && !isCtrl && !isAlt;
      case SendKey.ctrlEnter:
        return isCtrl && !isShift && !isAlt;
      case SendKey.button:
        return false;
    }
  }

  static bool _matchesNewlineKey(
    NewlineKey key,
    bool isCtrl,
    bool isShift,
    bool isAlt,
  ) {
    switch (key) {
      case NewlineKey.enter:
        return !isCtrl && !isShift && !isAlt;
      case NewlineKey.shiftEnter:
        return isShift && !isCtrl && !isAlt;
      case NewlineKey.ctrlEnter:
        return isCtrl && !isShift && !isAlt;
      case NewlineKey.altEnter:
        return isAlt && !isCtrl && !isShift;
    }
  }

  /// 在光标位置插入文本（2026-07-29 新增）
  ///
  /// 供"添加引号"/"添加括号"/"选择推荐回复"按钮通过 GlobalKey 调用。
  /// 插入后自动请求焦点并将光标移到插入文本之后。
  ///
  /// - 若输入框已有选中文本，替换选中文本
  /// - 若无选中，在光标位置插入
  ///
  /// [cursorOffsetFromStart]：插入后光标相对于插入文本起始位置的偏移。
  /// - null（默认）：光标移到插入文本末尾（常规文本插入）
  /// - 1：光标移到插入文本的第 1 个字符之后（用于成对符号如 `""` / `()`，
  ///   让光标停在两个符号中间）
  void insertAtCursor(String text, {int? cursorOffsetFromStart}) {
    final selection = _controller.selection;
    final currentText = _controller.text;

    int insertStart;
    String newText;
    if (selection.isValid && selection.start >= 0) {
      // 替换选中文本或在光标位置插入
      insertStart = selection.start;
      newText = currentText.replaceRange(selection.start, selection.end, text);
    } else {
      // 兜底：追加到末尾
      insertStart = currentText.length;
      newText = currentText + text;
    }

    // 计算最终光标位置
    final cursorOffset = cursorOffsetFromStart ?? text.length;
    final finalCursor = (insertStart + cursorOffset).clamp(0, newText.length);

    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: finalCursor),
    );

    // 请求焦点让输入框获得焦点（键盘弹出）
    if (!_focusNode.hasFocus) {
      _focusNode.requestFocus();
    }
  }

  /// 替换输入框全部内容并聚焦（失败"整轮取消"后回填用户消息）
  ///
  /// 与 [insertAtCursor] 的区别：本方法替换整个文本（而非光标处插入），
  /// 用于失败栏"整轮取消"回调——把本轮用户输入回填到输入框，方便用户
  /// 修改后重新发送。光标移到文本末尾，并请求焦点让键盘弹出。
  /// 当前输入文本（：页面切会话时暂存/恢复草稿用）
  String get currentText => _controller.text;

  /// 清空输入框内容并失焦
  void clear() {
    _controller.clear();
    _focusNode.unfocus();
  }

  void setText(String text, {bool requestFocus = true}) {
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    if (requestFocus && !_focusNode.hasFocus) {
      _focusNode.requestFocus();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return context.lmUi.inputArea(
      context,
      Padding(
        padding: const EdgeInsets.fromLTRB(
          IntermediateSpacing.sMd,
          IntermediateSpacing.sSm,
          IntermediateSpacing.sMd,
          IntermediateSpacing.sMd,
        ),
        child: SafeArea(
          top: false,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // 停止按钮（busy 或 stopping 时显示）
              if (_isBusyOrStopping)
                _StopButton(
                  onPressed: widget.onCancel,
                  colors: colors,
                  isStopping: widget.isStopping,
                )
              else
                const SizedBox(width: 0),
              const SizedBox(width: IntermediateSpacing.sSm),
              // 输入框 + 发送按钮
              Expanded(
                child: Container(
                  //  修复：maxHeight 120→200，提升屏占比
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: Focus(
                    onKeyEvent: _handleKeyEvent,
                    child: TextField(
                      focusNode: _focusNode,
                      controller: _controller,
                      enabled: _inputEnabled,
                      // 输入锁定（通用能力）：只读但保持可聚焦（辅助技术可达）
                      readOnly: widget.locked,
                      maxLines: null,
                      // 发送键为 enter 时键盘右下角显示"发送"，其他模式显示"换行"
                      textInputAction:
                          _isBusyOrStopping || widget.sendKey != SendKey.enter
                              ? TextInputAction.newline
                              : TextInputAction.send,
                      onSubmitted: (!_isBusyOrStopping &&
                              widget.sendKey == SendKey.enter)
                          ? (_) => _handleSend()
                          : null,
                      style: IntermediateTextStyles.input.copyWith(
                        color: _inputEnabled ? colors.ink : colors.faint,
                      ),
                      decoration: InputDecoration(
                        //  修复：导演模式用专属占位符（复活此前从未接线的
                        // advanced.input.hint），失败态文案两模式各自保留
                        hintText: widget.phase == IntermediatePhase.failed
                            ? t.intermediate.chat.inputPlaceholderFailed
                            : widget.isDirector
                                ? t.advanced.input.hint
                                : t.intermediate.chat.inputPlaceholder,
                        // 占位符用 muted（4.5:1 ✅，DOC-06B §3.2 B-10）
                        hintStyle: IntermediateTextStyles.input.copyWith(
                          color: colors.muted,
                        ),
                        filled: true,
                        fillColor: Colors.transparent,
                        //  修复：优化 padding 提升屏占比
                        contentPadding: const EdgeInsets.fromLTRB(
                          IntermediateSpacing.sMd,
                          12,
                          4,
                          12,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(
                            context.lmUi.radius(LmCorner.md),
                          ),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(
                            context.lmUi.radius(LmCorner.md),
                          ),
                          borderSide: BorderSide.none,
                        ),
                        disabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(
                            context.lmUi.radius(LmCorner.md),
                          ),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(
                            context.lmUi.radius(LmCorner.md),
                          ),
                          borderSide: BorderSide(
                            color: colors.primary,
                            width: 1.5,
                          ),
                        ),
                        suffixIcon: _buildSendButton(colors, t),
                        suffixIconConstraints: const BoxConstraints(
                          minWidth: 44,
                          minHeight: 44,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      narrative: true,
    );
  }

  Widget _buildSendButton(LmPalette colors, Translations t) {
    return LmStateTransition(
      stateKey: _isBusyOrStopping,
      alignment: Alignment.center,
      child: _buildSendButtonContent(colors, t),
    );
  }

  Widget _buildSendButtonContent(LmPalette colors, Translations t) {
    if (_isBusyOrStopping) {
      return SizedBox(
        width: 36,
        height: 36,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.primary,
            ),
          ),
        ),
      );
    }

    //  修复：发送按钮根据 _canSend 决定，
    // 而非 _inputEnabled（输入框始终可输入，仅发送按钮在生成中/失败时禁用）
    final canSend = _hasText && _canSend;
    return IconButton(
      icon: const Icon(Icons.send_rounded, size: 20),
      color: canSend ? colors.bg : colors.faint,
      onPressed: canSend ? _handleSend : null,
      onLongPress: _insertNewlineAtCursor,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      style: IconButton.styleFrom(
        backgroundColor: canSend ? colors.primary : Colors.transparent,
        shape: const CircleBorder(),
      ),
      tooltip: t.intermediate.chat.send,
    );
  }
}

/// 停止按钮
///
/// 两种状态：
/// - 正常（生成中）：琥珀色调，可点击触发取消
/// - 停止中（isStopping=true）：灰色调 + 脉冲动画，仍可点击（幂等，cancel 有守卫）
///
/// 动画遵循 impeccable 指南：ease-out 曲线，尊重 reduced-motion 偏好。
class _StopButton extends StatefulWidget {
  const _StopButton({
    required this.onPressed,
    required this.colors,
    this.isStopping = false,
  });

  final VoidCallback onPressed;
  final LmPalette colors;
  final bool isStopping;

  @override
  State<_StopButton> createState() => _StopButtonState();
}

class _StopButtonState extends State<_StopButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _pulse;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: LmMotion.pulseSoft,
      vsync: this,
    );
    // 脉冲：0.45 -> 1.0 往返，ease-out 曲线（impeccable 指南）
    _pulse = Tween<double>(begin: 0.45, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: LmMotion.easeBoth),
    );
  }

  ///  reduced-motion：减弱动态下不启动脉冲循环。
  bool _shouldPulse(BuildContext context) =>
      widget.isStopping && LmMotion.shouldAnimate(context);

  void _syncPulse() {
    if (_shouldPulse(context)) {
      if (!_controller.isAnimating) _controller.repeat(reverse: true);
    } else if (_controller.isAnimating) {
      _controller
        ..stop()
        ..reset();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(_StopButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isStopping != oldWidget.isStopping) {
      _syncPulse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = widget.colors;

    // 停止中：灰色调；正常：琥珀调
    final bgColor = widget.isStopping ? colors.divider : colors.accentDim;
    final iconColor = widget.isStopping ? colors.faint : colors.accent;

    // 尊重 reduced-motion 偏好（impeccable 指南）
    final disableAnimations = LmMotion.reducedMotion(context);

    Widget button = Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: bgColor,
        shape: BoxShape.circle,
      ),
      child: IconButton(
        icon: const Icon(Icons.stop_rounded, size: 18),
        color: iconColor,
        // 停止中仍可点击（cancel 方法有幂等守卫，重复调用无副作用）
        onPressed: widget.onPressed,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        tooltip: widget.isStopping
            ? t.intermediate.chat.stopping
            : t.intermediate.chat.stop,
      ),
    );

    // 停止中 + 动画允许：包裹脉冲动画
    if (widget.isStopping && !disableAnimations) {
      button = AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) {
          return Opacity(opacity: _pulse.value, child: child);
        },
        child: button,
      );
    }

    return button;
  }
}
