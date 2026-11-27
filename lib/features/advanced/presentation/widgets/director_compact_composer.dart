import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/shared/components/lm_state_transition.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/settings/domain/entities/input_keys.dart'
    show NewlineKey, SendKey;
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/context_usage_ring.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Compact composer for director mode.
///
/// Keeps quick writing helpers (quote, parenthesis, and suggested replies)
/// permanently accessible in a compact strip above the input field, while
/// embedding [ContextUsageChip] inline before the primary send/stop control.
class DirectorCompactComposer extends StatefulWidget {
  const DirectorCompactComposer({
    required this.phase,
    required this.onSend,
    required this.onCancel,
    required this.onAddQuote,
    required this.onAddParen,
    required this.onSuggest,
    required this.isGeneratingSuggest,
    required this.canSuggest,
    this.onTextChanged,
    this.isStopping = false,
    this.isManualCompacting = false,
    this.isPreparingRegenerate = false,
    this.sendKey = SendKey.enter,
    this.newlineKey = NewlineKey.shiftEnter,
    this.preserveWhitespace = false,
    this.locked = false,
    this.contextNumerator,
    this.contextDenominator,
    this.onContextTap,
    this.queuedMessageSlot,
    super.key,
  });

  final IntermediatePhase phase;
  final void Function(String text) onSend;
  final void Function(String text)? onTextChanged;
  final VoidCallback onCancel;
  final VoidCallback onAddQuote;
  final VoidCallback onAddParen;
  final VoidCallback onSuggest;
  final bool isGeneratingSuggest;
  final bool canSuggest;
  final bool isStopping;
  final bool isManualCompacting;
  final bool isPreparingRegenerate;
  final SendKey sendKey;
  final NewlineKey newlineKey;
  final bool preserveWhitespace;
  final bool locked;
  final int? contextNumerator;
  final int? contextDenominator;
  final VoidCallback? onContextTap;
  final Widget? queuedMessageSlot;

  @override
  State<DirectorCompactComposer> createState() =>
      DirectorCompactComposerState();
}

/// Public state exposing text manipulation methods for draft recovery,
/// cursor insertion, and demo input locking.
class DirectorCompactComposerState extends State<DirectorCompactComposer> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  /// Synchronizes the text field to [fixedText] while input lock is active.
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

  bool get _isBusyOrStopping => _isBusy || widget.isStopping;

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

  void _insertNewlineAtCursor() {
    if (widget.locked) return;
    final selection = _controller.selection;
    final text = _controller.text;
    if (!selection.isValid || selection.start < 0) {
      _controller.value = TextEditingValue(
        text: '$text\n',
        selection: TextSelection.collapsed(offset: text.length + 1),
      );
      return;
    }
    final newText = text.replaceRange(selection.start, selection.end, '\n');
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: selection.start + 1),
    );
  }

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

    if (_matchesSendKey(widget.sendKey, isCtrl, isShift, isAlt)) {
      _handleSend();
      return KeyEventResult.handled;
    }

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

  /// Inserts [text] at the current selection and optionally places the cursor
  /// at [cursorOffsetFromStart] from the inserted start.
  void insertAtCursor(String text, {int? cursorOffsetFromStart}) {
    final selection = _controller.selection;
    final currentText = _controller.text;

    int insertStart;
    String newText;
    if (selection.isValid && selection.start >= 0) {
      insertStart = selection.start;
      newText = currentText.replaceRange(selection.start, selection.end, text);
    } else {
      insertStart = currentText.length;
      newText = currentText + text;
    }

    final cursorOffset = cursorOffsetFromStart ?? text.length;
    final finalCursor = (insertStart + cursorOffset).clamp(0, newText.length);

    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: finalCursor),
    );

    if (!_focusNode.hasFocus) {
      _focusNode.requestFocus();
    }
  }

  /// Current text inside the composer.
  String get currentText => _controller.text;

  /// Clears the composer text and releases focus.
  void clear() {
    _controller.clear();
    _focusNode.unfocus();
  }

  /// Replaces the composer text and moves the cursor to the end.
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
    final readingWidth = LmLayout.readingWidthOf(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Persistent compact writing helper strip above the input surface.
        Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: readingWidth),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                IntermediateSpacing.sMd,
                IntermediateSpacing.s2xs,
                IntermediateSpacing.sMd,
                IntermediateSpacing.s2xs,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Wrap(
                  spacing: IntermediateSpacing.sSm,
                  runSpacing: IntermediateSpacing.sXs,
                  children: [
                    _HelperPill(
                      key: const ValueKey(
                        'director-composer-add-quote',
                      ),
                      icon: Icons.format_quote_outlined,
                      label: t.advanced.composer.quoteButton,
                      tooltip: t.intermediate.chat.toolbar.addQuote,
                      onPressed: widget.locked ? null : widget.onAddQuote,
                    ),
                    _HelperPill(
                      key: const ValueKey(
                        'director-composer-add-paren',
                      ),
                      icon: Icons.rounded_corner,
                      label: t.advanced.composer.parenButton,
                      tooltip: t.intermediate.chat.toolbar.addParen,
                      onPressed: widget.locked ? null : widget.onAddParen,
                    ),
                    _HelperPill(
                      key: const ValueKey(
                        'director-composer-suggest',
                      ),
                      icon: Icons.auto_awesome_outlined,
                      label: t.intermediate.chat.toolbar.suggest,
                      tooltip: t.intermediate.chat.toolbar.suggestTooltip,
                      isLoading: widget.isGeneratingSuggest,
                      onPressed:
                          widget.canSuggest && !widget.isGeneratingSuggest
                              ? widget.onSuggest
                              : null,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        if (widget.queuedMessageSlot != null)
          Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: readingWidth),
              child: widget.queuedMessageSlot,
            ),
          ),
        context.lmUi.inputArea(
          context,
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                IntermediateSpacing.sMd,
                IntermediateSpacing.sXs,
                IntermediateSpacing.sSm,
                IntermediateSpacing.sXs,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 200),
                      child: Focus(
                        onKeyEvent: _handleKeyEvent,
                        child: TextField(
                          focusNode: _focusNode,
                          controller: _controller,
                          readOnly: widget.locked,
                          maxLines: null,
                          textInputAction: _isBusyOrStopping ||
                                  widget.sendKey != SendKey.enter
                              ? TextInputAction.newline
                              : TextInputAction.send,
                          onSubmitted: (!_isBusyOrStopping &&
                                  widget.sendKey == SendKey.enter)
                              ? (_) => _handleSend()
                              : null,
                          style: IntermediateTextStyles.input.copyWith(
                            fontSize: 14.5,
                            color: colors.ink,
                          ),
                          decoration: InputDecoration(
                            hintText: widget.phase == IntermediatePhase.failed
                                ? t.intermediate.chat.inputPlaceholderFailed
                                : t.advanced.input.hint,
                            hintStyle: IntermediateTextStyles.input.copyWith(
                              fontSize: 14.5,
                              color: colors.muted,
                            ),
                            isDense: true,
                            filled: false,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: IntermediateSpacing.sXs,
                              vertical: 11,
                            ),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            disabledBorder: InputBorder.none,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: IntermediateSpacing.sXs),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: ContextUsageChip(
                      numerator: widget.contextNumerator,
                      denominator: widget.contextDenominator,
                      onTap: widget.onContextTap,
                    ),
                  ),
                  const SizedBox(width: IntermediateSpacing.sXs),
                  _buildPrimaryAction(colors, t),
                ],
              ),
            ),
          ),
          narrative: true,
        ),
      ],
    );
  }

  Widget _buildPrimaryAction(LmPalette colors, Translations t) {
    return LmStateTransition(
      stateKey: _isBusyOrStopping,
      alignment: Alignment.center,
      child: _isBusyOrStopping
          ? _CompactStopButton(
              onPressed: widget.onCancel,
              colors: colors,
              isStopping: widget.isStopping,
            )
          : _buildSendButton(colors, t),
    );
  }

  Widget _buildSendButton(LmPalette colors, Translations t) {
    final canSend = _hasText && _canSend;
    return IconButton(
      icon: const Icon(Icons.send_rounded, size: 19),
      color: canSend ? colors.onPrimary : colors.faint,
      onPressed: canSend ? _handleSend : null,
      onLongPress: _insertNewlineAtCursor,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      style: IconButton.styleFrom(
        backgroundColor: canSend ? colors.primary : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
            context.lmUi.radius(LmCorner.full),
          ),
        ),
      ),
      tooltip: t.intermediate.chat.send,
    );
  }
}

class _HelperPill extends StatefulWidget {
  const _HelperPill({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.isLoading = false,
    this.tooltip,
    super.key,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool isLoading;
  final String? tooltip;

  @override
  State<_HelperPill> createState() => _HelperPillState();
}

class _HelperPillState extends State<_HelperPill> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final enabled = widget.onPressed != null;
    final iconColor = enabled ? colors.primary : colors.faint;
    final radius = BorderRadius.circular(context.lmUi.radius(LmCorner.full));

    final pill = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: widget.onPressed,
          borderRadius: radius,
          child: AnimatedContainer(
            duration: LmMotion.durationFor(context, LmMotion.micro),
            constraints: const BoxConstraints(minHeight: 34),
            padding: const EdgeInsets.symmetric(
              horizontal: IntermediateSpacing.sMd,
              vertical: IntermediateSpacing.sXs,
            ),
            decoration: BoxDecoration(
              color: _hovered && enabled
                  ? colors.primaryDim
                  : colors.surfaceVariant,
              borderRadius: radius,
              border: Border.all(
                color: _hovered && enabled
                    ? colors.primary.withValues(alpha: 0.35)
                    : colors.divider,
                width: 0.5,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.isLoading)
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: iconColor,
                    ),
                  )
                else
                  Icon(widget.icon, size: 14, color: iconColor),
                const SizedBox(width: IntermediateSpacing.s2xs),
                Flexible(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: IntermediateTextStyles.caption.copyWith(
                      color: enabled ? colors.ink : colors.faint,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    if (widget.tooltip != null) {
      return Tooltip(message: widget.tooltip, child: pill);
    }
    return pill;
  }
}

class _CompactStopButton extends StatefulWidget {
  const _CompactStopButton({
    required this.onPressed,
    required this.colors,
    this.isStopping = false,
  });

  final VoidCallback onPressed;
  final LmPalette colors;
  final bool isStopping;

  @override
  State<_CompactStopButton> createState() => _CompactStopButtonState();
}

class _CompactStopButtonState extends State<_CompactStopButton>
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
    _pulse = Tween<double>(begin: 0.45, end: 1).animate(
      CurvedAnimation(parent: _controller, curve: LmMotion.easeBoth),
    );
  }

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
  void didUpdateWidget(_CompactStopButton oldWidget) {
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
    final bgColor = widget.isStopping
        ? colors.divider
        : colors.primary.withValues(alpha: 0.14);
    final iconColor = widget.isStopping ? colors.faint : colors.primary;
    final disableAnimations = LmMotion.reducedMotion(context);

    Widget button = SizedBox(
      width: 44,
      height: 44,
      child: Center(
        child: Container(
          width: 38,
          height: 38,
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(
              context.lmUi.radius(LmCorner.full),
            ),
            border: widget.isStopping
                ? null
                : Border.all(
                    color: colors.primary.withValues(alpha: 0.28),
                    width: 0.5,
                  ),
          ),
          child: IconButton(
            icon: const Icon(Icons.stop_rounded, size: 18),
            color: iconColor,
            onPressed: widget.onPressed,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            tooltip: widget.isStopping
                ? t.intermediate.chat.stopping
                : t.intermediate.chat.stop,
          ),
        ),
      ),
    );

    if (widget.isStopping && !disableAnimations) {
      button = AnimatedBuilder(
        animation: _pulse,
        builder: (context, child) => Opacity(
          opacity: _pulse.value,
          child: child,
        ),
        child: button,
      );
    }
    return button;
  }
}
