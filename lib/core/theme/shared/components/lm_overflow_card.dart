import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';

/// 滚动溢出提示卡（"限高滚动区看不出能下滑"）。
///
/// 结构：固定卡框（背景/描边/圆角/内边距由本组件提供）+ 内部
/// [SingleChildScrollView] + 底部渐隐遮罩与「下滑查看更多」提示 pill。
/// 卡框不随内容滚动——边界与描边恒定可见，内容溢出时渐隐遮罩给出
/// "下面还有"的视觉线索，滚到底自动隐藏；提示 pill 可点击直达底部。
///
/// - 内容未溢出：与普通卡片无异（零提示、按内容收高）。
/// - [scrollHintLabel] 为 null：只保留渐隐遮罩，不渲染提示 pill
///   （卡内子滚动区等低噪声场合）。
/// - [backgroundColor] 与 [borderColor] 均为 null：退化为纯滚动容器
///   （无卡框），供已有卡内的子滚动区复用；此时渐隐色须显式传
///   [fadeColor]（宿主卡的底色）。
class LmOverflowCard extends StatefulWidget {
  const LmOverflowCard({
    required this.child,
    this.maxHeight,
    this.margin,
    this.padding = const EdgeInsets.all(LmSpacing.sMd),
    this.backgroundColor,
    this.borderColor,
    this.fadeColor,
    this.scrollHintLabel,
    super.key,
  });

  /// 滚动区最大高度；null = 不限（依赖外层约束）。
  final double? maxHeight;

  final EdgeInsetsGeometry? margin;

  /// 滚动内容内边距（卡框内侧）。
  final EdgeInsetsGeometry padding;

  /// 卡框底色；null = 透明（无框模式）。
  final Color? backgroundColor;

  /// 卡框描边；null = 无描边。
  final Color? borderColor;

  /// 底部渐隐色；缺省取 [backgroundColor]，透明卡须显式传宿主卡色。
  final Color? fadeColor;

  /// 「下滑查看更多」提示文案；null = 不渲染提示 pill。
  final String? scrollHintLabel;

  final Widget child;

  @override
  State<LmOverflowCard> createState() => _LmOverflowCardState();
}

class _LmOverflowCardState extends State<LmOverflowCard> {
  final _scrollController = ScrollController();

  /// 内容还有未滚到的部分（渐隐与提示 pill 的显隐源）
  bool _hasMoreBelow = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_updateOverflow);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateOverflow());
  }

  @override
  void didUpdateWidget(covariant LmOverflowCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 内容变化（如选项刷新）后重判溢出
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateOverflow());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _updateOverflow() {
    if (!mounted || !_scrollController.hasClients) return;
    final hasMore = _scrollController.position.maxScrollExtent -
            _scrollController.position.pixels >
        8;
    if (hasMore != _hasMoreBelow) setState(() => _hasMoreBelow = hasMore);
  }

  void _scrollToBottom() {
    if (!_scrollController.hasClients) return;
    _scrollController.animateTo(
      _scrollController.position.maxScrollExtent,
      duration: LmMotion.slow,
      curve: LmMotion.easeEmphasis,
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final fadeColor = widget.fadeColor ?? widget.backgroundColor ?? colors.bg;

    Widget area = SingleChildScrollView(
      controller: _scrollController,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      child: Padding(padding: widget.padding, child: widget.child),
    );
    if (widget.maxHeight != null) {
      area = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight!),
        child: area,
      );
    }

    Widget stack = Stack(
      children: [
        area,
        // 底部渐隐：内容溢出的通用线索（不可交互，点击穿透到滚动）
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            child: AnimatedOpacity(
              duration: LmMotion.micro,
              opacity: _hasMoreBelow ? 1 : 0,
              child: Container(
                height: 48,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      fadeColor.withValues(alpha: 0),
                      fadeColor,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        // 「下滑查看更多」提示 pill：点击直达底部（可交互）。
        // AnimatedSwitcher 条件挂载——隐藏态组件离树（AnimatedOpacity
        // 零透明仍在树内，finder/无障碍都会命中）。
        if (widget.scrollHintLabel != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: LmSpacing.sXs,
            child: Center(
              child: AnimatedSwitcher(
                duration: LmMotion.micro,
                child: _hasMoreBelow
                    ? Material(
                        key: const ValueKey('lm-overflow-hint'),
                        color: colors.surface,
                        shape: StadiumBorder(
                          side: BorderSide(
                            color: colors.dividerStrong,
                            width: 0.5,
                          ),
                        ),
                        child: InkWell(
                          onTap: _scrollToBottom,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: LmSpacing.sSm,
                              vertical: LmSpacing.s2xs,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.expand_more,
                                  size: 14,
                                  color: colors.primary,
                                ),
                                const SizedBox(width: LmSpacing.s2xs),
                                Text(
                                  widget.scrollHintLabel!,
                                  style: LmNarrativeTextStyles.caption.copyWith(
                                    color: colors.ink,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      )
                    : const SizedBox.shrink(
                        key: ValueKey('lm-overflow-hint-gone'),
                      ),
              ),
            ),
          ),
      ],
    );
    // 宽度吃满可用空间：卡是内容列的一部分（非 stretch 上下文），
    // 不约束则 Stack 收缩到最宽子项宽度，提示 pill 反而溢出。
    stack = ConstrainedBox(
      constraints: const BoxConstraints(minWidth: double.infinity),
      child: stack,
    );

    final hasFrame =
        widget.backgroundColor != null || widget.borderColor != null;
    if (hasFrame) {
      final radius = BorderRadius.circular(
        context.lmUi.radius(LmCorner.md),
      );
      stack = DecoratedBox(
        decoration: BoxDecoration(
          color: widget.backgroundColor,
          border: widget.borderColor == null
              ? null
              : Border.all(color: widget.borderColor!),
          borderRadius: radius,
        ),
        child: ClipRRect(borderRadius: radius, child: stack),
      );
    }
    if (widget.margin != null) {
      stack = Padding(padding: widget.margin!, child: stack);
    }
    return stack;
  }
}
