import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/streaming_fade_text.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart';
import 'package:lmstory/i18n/strings.g.dart';
// =============================================================================
// Thinking / reasoning content section
// （从 simple_message_bubble.dart 拆出，内容区引用）
// =============================================================================

/// Collapsible section showing the LLM's thinking/reasoning content.
///
/// When collapsed: shows "Thought for Xs" with a lightbulb icon.
/// When expanded: shows the thinking text in a muted, smaller font.
/// During streaming: shows a pulsing "Thinking..." indicator.
class BubbleThinkingSection extends StatefulWidget {
  const BubbleThinkingSection({
    required this.thinkingContent,
    required this.thinkingDuration,
    required this.isThinking,
    required this.colors,
    super.key,
  });

  final String? thinkingContent;
  final int? thinkingDuration;
  final bool isThinking;
  final LmPalette colors;

  @override
  State<BubbleThinkingSection> createState() => _BubbleThinkingSectionState();
}

class _BubbleThinkingSectionState extends State<BubbleThinkingSection>
    with SingleTickerProviderStateMixin {
  bool _isExpanded = false;
  late AnimationController _pulseController;

  // 流式思考体验——思考中自动展开（用户手动收起则尊重），
  // 正文开始输出（isThinking 转假）时自动收起（让位正文）。
  bool _userCollapsedDuringThinking = false;

  @override
  void initState() {
    super.initState();
    // 思考中默认自动展开（推理模型用户想看实时思路）
    _isExpanded = widget.isThinking;
    _pulseController = AnimationController(
      vsync: this,
      duration: LmMotion.loop,
    );
  }

  ///  reduced-motion：减弱动态下不启动脉冲循环。
  bool _shouldPulse(BuildContext context) =>
      widget.isThinking && LmMotion.shouldAnimate(context);

  void _syncPulse() {
    //  批5：仅思考中启动呼吸动画——此前无条件 repeat，思考结束后
    //（图标已切静态分支）ticker 仍每帧空转，历史气泡人手一个白耗帧预算
    if (_shouldPulse(context)) {
      if (!_pulseController.isAnimating) _pulseController.repeat(reverse: true);
    } else if (_pulseController.isAnimating) {
      _pulseController.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(BubbleThinkingSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    //  批5：随 isThinking 翻转启停 ticker
    _syncPulse();
    if (widget.isThinking != oldWidget.isThinking) {
      if (widget.isThinking) {
        // 思考开始：自动展开（除非上一段思考被用户手动收起）
        if (!_userCollapsedDuringThinking) {
          _isExpanded = true;
        }
      } else {
        // 思考结束（正文首 delta 已到）：自动收起让位正文；
        // 重置用户偏好标记（下一段思考重新默认展开）
        _isExpanded = false;
        _userCollapsedDuringThinking = false;
      }
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  void _toggleExpanded() {
    setState(() {
      _isExpanded = !_isExpanded;
      // 思考中手动收起 = 记住偏好（本段思考内不再自动展开）
      if (widget.isThinking && !_isExpanded) {
        _userCollapsedDuringThinking = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: LmSpacing.sXs),
      child: Container(
        decoration: BoxDecoration(
          color: widget.colors.surfaceElevated,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
          child: InkWell(
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
            onTap: _toggleExpanded,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: LmSpacing.sSm,
                vertical: LmSpacing.sXs,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // Lightbulb icon with pulse during thinking
                      // （减弱动态下不进动画分支：控制器未启动，value 恒 0，
                      //  若仍走 FadeTransition 图标会隐形—— 实锤）
                      if (_shouldPulse(context))
                        FadeTransition(
                          opacity: _pulseController,
                          child: Icon(
                            Icons.lightbulb_outline,
                            size: 14,
                            color: widget.colors.accent,
                          ),
                        )
                      else
                        Icon(
                          Icons.lightbulb_outline,
                          size: 14,
                          color: widget.colors.accent,
                        ),
                      const SizedBox(width: LmSpacing.s2xs),
                      Expanded(
                        child: Text(
                          widget.isThinking
                              ? t.chat.thinking.title
                              : widget.thinkingDuration != null
                                  ? t.chat.thinking.thoughtFor(
                                      duration: widget.thinkingDuration!,
                                    )
                                  : t.chat.thinking.title,
                          style: LmUiTextStyles.caption.copyWith(
                            color: widget.colors.muted,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      // 展开态一键复制思考内容
                      if (_isExpanded && widget.thinkingContent != null)
                        Semantics(
                          label: t.chat.messageActions.copy,
                          button: true,
                          child: InkWell(
                            onTap: () {
                              Clipboard.setData(
                                ClipboardData(text: widget.thinkingContent!),
                              );
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  behavior: SnackBarBehavior.floating,
                                  content: Text(
                                    t.chat.messageActions.copySuccess,
                                  ),
                                ),
                              );
                            },
                            borderRadius: BorderRadius.circular(
                              context.lmUi.radius(LmCorner.sm),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(LmSpacing.s2xs),
                              child: Icon(
                                Icons.copy_outlined,
                                size: 13,
                                color: widget.colors.faint,
                              ),
                            ),
                          ),
                        ),
                      Icon(
                        _isExpanded ? Icons.expand_less : Icons.expand_more,
                        size: 16,
                        color: widget.colors.faint,
                      ),
                    ],
                  ),
                  if (_isExpanded && widget.thinkingContent != null) ...[
                    const SizedBox(height: LmSpacing.s2xs),
                    Divider(
                      height: 1,
                      color: widget.colors.divider,
                    ),
                    const SizedBox(height: LmSpacing.s2xs),
                    // 展开态限高滚动（长思考不再砌墙）
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 220),
                      child: SingleChildScrollView(
                        // （R1）：思考流式增长文本接共享淡入载体
                        // pace：直连载体的流式面自行配速。
                        child: StreamingFadeText(
                          data: widget.thinkingContent!,
                          pace: true,
                          style: LmUiTextStyles.bodySm.copyWith(
                            color: widget.colors.faint,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
