import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 会话内搜索条
///
/// 设计取舍：
/// - **非模态**：AppBar 下方内联滑入（200ms easeOut），不抢走阅读位置，
///   关闭后原地消失——搜索是阅读的临时侧事，不是任务切换；
/// - **受控组件**：查询/结果/导航状态由宿主页持有（跨重建保留），本条
///   只渲染 query、计数与四个动作，回调上抛；
/// - 键盘：Enter 下一条 / Shift+Enter 上一条 / Esc 关闭（桌面心智）；
/// - 触控目标全部 ≥44dp；计数与占位文案走 muted 色，主输入文字用 ink。
class InSessionSearchBar extends StatefulWidget {
  const InSessionSearchBar({
    required this.visible,
    required this.query,
    required this.matchCount,
    required this.currentMatch,
    required this.onQueryChanged,
    required this.onNext,
    required this.onPrev,
    required this.onClose,
    this.focusTick = 0,
    this.truncationHint,
    super.key,
  });

  final bool visible;

  /// 当前查询词（受控——页面 debounce 后回填，避免重建丢字）
  final String query;

  /// 命中消息数；-1 = 搜索中（尚未回填）
  final int matchCount;

  /// 当前定位第几个命中（1 起；0 = 尚未定位）
  final int currentMatch;

  /// 递增即请求聚焦输入框并全选——已可见时 Ctrl+F
  /// 的重聚焦通道（关闭语义走 Esc/×，不再由快捷键承担）。
  final int focusTick;

  /// 命中数达 SQL LIMIT 时的截断提示；null=不显示。
  final String? truncationHint;

  final ValueChanged<String> onQueryChanged;
  final VoidCallback onNext;
  final VoidCallback onPrev;
  final VoidCallback onClose;

  @override
  State<InSessionSearchBar> createState() => _InSessionSearchBarState();
}

class _InSessionSearchBarState extends State<InSessionSearchBar> {
  late final TextEditingController _controller;
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.query);
    // 打开时聚焦全选——替换式输入是搜索条的第一动作
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.visible) {
        _focusNode.requestFocus();
        _controller.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _controller.text.length,
        );
      }
    });
  }

  @override
  void didUpdateWidget(InSessionSearchBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部清空（关闭再开）时同步受控文本
    if (widget.visible && !oldWidget.visible && widget.query.isEmpty) {
      _controller.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
    // 已可见时的重聚焦请求（Ctrl+F 再按）
    if (widget.visible && widget.focusTick != oldWidget.focusTick) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _focusNode.requestFocus();
        _controller.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _controller.text.length,
        );
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onClose();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      // 键盘路径与导航钮 disabled 同口径——无命中时
      // 吞掉 Enter，避免宿主对空命中列表取模抛 IntegerDivisionByZeroException
      if (widget.matchCount <= 0) return KeyEventResult.handled;
      if (HardwareKeyboard.instance.isShiftPressed) {
        widget.onPrev();
      } else {
        widget.onNext();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String _countLabel(Translations t) {
    if (widget.matchCount < 0) return '…';
    if (widget.matchCount == 0) return t.chat.inSessionSearch.noResults;
    if (widget.currentMatch <= 0) return '${widget.matchCount}';
    return '${widget.currentMatch}/${widget.matchCount}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final canNavigate = widget.matchCount > 0;

    return AnimatedSize(
      duration: LmMotion.base,
      curve: LmMotion.easeEmphasis,
      alignment: Alignment.topCenter,
      child: widget.visible
          ? Material(
              color: colors.surfaceElevated,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: colors.divider),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SimpleSpacing.sMd,
                    vertical: SimpleSpacing.s2xs,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.search,
                            size: 18,
                            color: colors.muted,
                          ),
                          const SizedBox(width: SimpleSpacing.sSm),
                          Expanded(
                            child: Focus(
                              onKeyEvent: _onKey,
                              child: TextField(
                                controller: _controller,
                                focusNode: _focusNode,
                                style: SimpleTextStyles.body.copyWith(
                                  color: colors.ink,
                                ),
                                decoration: InputDecoration(
                                  hintText: t.chat.inSessionSearch.placeholder,
                                  hintStyle: SimpleTextStyles.body.copyWith(
                                    color: colors.faint,
                                  ),
                                  border: InputBorder.none,
                                  isDense: true,
                                ),
                                onChanged: widget.onQueryChanged,
                              ),
                            ),
                          ),
                          const SizedBox(width: SimpleSpacing.sSm),
                          AnimatedSwitcher(
                            duration: LmMotion.fast,
                            child: Text(
                              _countLabel(t),
                              key: ValueKey(_countLabel(t)),
                              style: SimpleTextStyles.caption.copyWith(
                                color: widget.matchCount == 0
                                    ? colors.muted
                                    : colors.ink,
                              ),
                            ),
                          ),
                          _NavButton(
                            icon: Icons.keyboard_arrow_up,
                            tooltip: t.chat.inSessionSearch.prev,
                            enabled: canNavigate,
                            colors: colors,
                            onTap: widget.onPrev,
                          ),
                          _NavButton(
                            icon: Icons.keyboard_arrow_down,
                            tooltip: t.chat.inSessionSearch.next,
                            enabled: canNavigate,
                            colors: colors,
                            onTap: widget.onNext,
                          ),
                          _NavButton(
                            icon: Icons.close,
                            tooltip: t.chat.inSessionSearch.close,
                            enabled: true,
                            colors: colors,
                            onTap: widget.onClose,
                          ),
                        ],
                      ),
                      if (widget.truncationHint != null)
                        Padding(
                          padding: const EdgeInsets.only(
                            left: SimpleSpacing.sMd + 18 + SimpleSpacing.sSm,
                            bottom: SimpleSpacing.s2xs,
                          ),
                          child: Text(
                            widget.truncationHint!,
                            style: SimpleTextStyles.caption.copyWith(
                              color: colors.muted,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}

/// 44dp 触控目标的方形导航按钮（同尺寸三枚，词汇一致）
class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.colors,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final bool enabled;
  final LmPalette colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 20),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      // 44dp 触控目标（品牌可达性基线）
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      color: enabled ? colors.ink : colors.faint,
      onPressed: enabled ? onTap : null,
    );
  }
}

/// 搜索防抖：调用方（页面）持 Timer，`debounce` 归零后执行一次 [action]
Timer debounceSearch(Duration duration, void Function() action) {
  return Timer(duration, action);
}
