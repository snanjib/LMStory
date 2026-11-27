import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/lm_activity_dots.dart';
import 'package:lmstory/core/theme/shared/components/lm_arrival.dart';
import 'package:lmstory/core/theme/shared/components/lm_state_transition.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 推荐回复气泡浮层（2026-07-29 新增）
///
/// 在输入框上方浮出展示 LLM 生成的候选用户回复，点击候选插入到输入框光标位置。
///
/// **视觉设计**（遵循 impeccable 原则 + 夜航配色）：
/// - 浮层效果：Material elevation + surfaceElevated 背景，营造"浮在最上方"观感
/// - Restrained 策略：仅在标题点（primary 色）和 hover 态使用琥珀金强调
/// - 圆角 rLg（16px）对齐卡片规范；内部分隔线用 divider 色
/// - 排版层次：标题（label）→ 候选气泡（input 样式）→ 操作图标（caption）
///
/// **三种状态**：
/// - generating：显示 loading 指示器 + "正在生成候选回复..."
/// - expanded：纵向排列所有候选气泡，每条可点击
/// - collapsed：折叠为单行 chip，显示候选数量，点击展开
///
/// **失败处理**：候选为空且非 generating 时显示"生成失败"提示。
///
/// **生命周期**：
/// - 由父组件（IntermediateChatPage）根据 state.suggestReplies 控制
/// - 用户点击 × → 调 [onClose] 回调，父组件调 controller.closeSuggest()
/// - 用户点击候选 → 调 [onSelect] 回调，父组件调 input.insertAtCursor
/// - 用户点击折叠/展开 → 调 [onToggle] 回调，父组件调 controller.toggleSuggest()
class SuggestReplyOverlay extends StatelessWidget {
  const SuggestReplyOverlay({
    required this.replies,
    required this.isGenerating,
    required this.isExpanded,
    required this.onSelect,
    required this.onClose,
    required this.onToggle,
    this.isFailed = false,
    this.failureMessage,
    this.onRetry,
    super.key,
  });

  /// 候选回复列表（空列表 + isGenerating=false + isFailed=false 表示初始态）
  final List<String> replies;

  /// 是否正在生成
  final bool isGenerating;

  /// 是否展开（true=展开显示所有候选；false=折叠为 chip）
  final bool isExpanded;

  /// 是否生成失败
  final bool isFailed;
  final String? failureMessage;

  /// 点击候选回复回调（index 越界由调用方处理）
  final void Function(int index) onSelect;

  /// 关闭浮层回调
  final VoidCallback onClose;

  /// 切换展开/折叠回调
  final VoidCallback onToggle;

  /// 重试生成回调（失败时显示重试按钮）
  final Future<bool> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return LmArrival(
      // 宽屏版心对齐——浮层与正文/工具栏同版心，不再通铺整窗。
      // 正文列的阅读限宽是无条件的（>800 即收窄），浮层须同口径用
      // 裸钳制而不是 LmMeasure 的 ≥1280 门，避免 800–1280 段错位。
      child: Center(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxWidth: LmLayout.readingWidthOf(context)),
          child: Container(
            // 浮层效果：elevation 阴影 + 圆角 + 提升层背景
            decoration: BoxDecoration(
              color: colors.surfaceElevated,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
              // 轻量阴影营造浮层感（不过度，符合 Restrained 策略）
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 12,
                  offset: const Offset(0, -2),
                ),
              ],
              border: Border.all(color: colors.divider, width: 0.5),
            ),
            // 限制最大高度，避免候选过多遮挡聊天区域
            constraints: const BoxConstraints(maxHeight: 280),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildHeader(colors, t),
                Flexible(
                  child: Semantics(
                    liveRegion: isGenerating || isFailed,
                    child: LmStateTransition(
                      stateKey: (
                        isGenerating,
                        isFailed,
                        replies.isEmpty,
                        isExpanded
                      ),
                      alignment: Alignment.topLeft,
                      child: isGenerating
                          ? _buildGeneratingState(colors, t)
                          : (isFailed
                              ? _buildFailedState(colors, t)
                              : (replies.isEmpty
                                  ? const SizedBox.shrink()
                                  : (isExpanded
                                      ? _buildExpandedList(colors, t)
                                      : _buildCollapsedChip(
                                          context,
                                          colors,
                                          t,
                                        )))),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 头部：标题 + 折叠/展开按钮 + 关闭按钮
  Widget _buildHeader(LmPalette colors, Translations t) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        LmSpacing.sMd,
        LmSpacing.sSm,
        LmSpacing.s2xs,
        LmSpacing.sSm,
      ),
      child: Row(
        children: [
          // 标题点（琥珀金小圆点，呼应夜航"点灯"隐喻）
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: colors.primary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: LmSpacing.sXs),
          Expanded(
            child: Text(
              t.intermediate.chat.suggestReply.title,
              style: LmNarrativeTextStyles.label.copyWith(color: colors.ink),
            ),
          ),
          // 折叠/展开按钮（仅在有候选时显示）
          if (replies.isNotEmpty && !isGenerating)
            IconButton(
              icon: Icon(
                isExpanded ? Icons.expand_less : Icons.expand_more,
                size: 18,
              ),
              color: colors.muted,
              onPressed: onToggle,
              tooltip: isExpanded
                  ? t.intermediate.chat.suggestReply.collapse
                  : t.intermediate.chat.suggestReply.expand,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(
                minWidth: 44,
                minHeight: 44,
              ),
            ),
          // 关闭按钮
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            color: colors.muted,
            onPressed: onClose,
            tooltip: t.intermediate.chat.suggestReply.close,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          ),
        ],
      ),
    );
  }

  /// 生成中状态
  Widget _buildGeneratingState(LmPalette colors, Translations t) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LmSpacing.sMd,
          vertical: LmSpacing.sMd,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            LmActivityDots(color: colors.primary),
            const SizedBox(width: LmSpacing.sSm),
            Flexible(
              child: Text(
                t.intermediate.chat.suggestReply.generating,
                style: LmNarrativeTextStyles.caption.copyWith(
                  color: colors.muted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 失败状态（生成失败时显示错误提示 + 重试按钮）
  Widget _buildFailedState(LmPalette colors, Translations t) {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: LmSpacing.sMd,
          vertical: LmSpacing.sMd,
        ),
        child: Wrap(
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: LmSpacing.sSm,
          runSpacing: LmSpacing.sXs,
          children: [
            Icon(
              Icons.error_outline,
              size: 14,
              color: colors.error,
            ),
            const SizedBox(width: LmSpacing.sXs),
            Text(
              failureMessage ?? t.intermediate.chat.suggestReply.failed,
              style: LmNarrativeTextStyles.caption.copyWith(
                color: colors.error,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(width: LmSpacing.sSm),
              TextButton(
                onPressed: onRetry,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: LmSpacing.sSm,
                  ),
                  minimumSize: const Size(44, 44),
                ),
                child: Text(
                  t.intermediate.chat.suggestReply.retry,
                  style: LmNarrativeTextStyles.caption.copyWith(
                    color: colors.primary,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 折叠态：单行 chip 显示候选数量
  Widget _buildCollapsedChip(
    BuildContext context,
    LmPalette colors,
    Translations t,
  ) {
    return InkWell(
      onTap: onToggle,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: LmSpacing.sMd,
          vertical: LmSpacing.sSm,
        ),
        margin: const EdgeInsets.only(
          left: LmSpacing.sMd,
          right: LmSpacing.sMd,
          bottom: LmSpacing.sSm,
        ),
        decoration: BoxDecoration(
          color: colors.primaryDim,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.lightbulb_outline,
              size: 14,
              color: colors.primary,
            ),
            const SizedBox(width: LmSpacing.sXs),
            Flexible(
              child: Text(
                '${replies.length} ${t.intermediate.chat.suggestReply.title}',
                style: LmNarrativeTextStyles.caption.copyWith(
                  color: colors.primary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: LmSpacing.sXs),
            Icon(
              Icons.expand_more,
              size: 14,
              color: colors.primary,
            ),
          ],
        ),
      ),
    );
  }

  /// 展开态：纵向排列所有候选气泡
  Widget _buildExpandedList(LmPalette colors, Translations t) {
    return ListView.separated(
      shrinkWrap: true,
      padding: const EdgeInsets.only(
        left: LmSpacing.sMd,
        right: LmSpacing.sMd,
        bottom: LmSpacing.sSm,
      ),
      itemCount: replies.length,
      separatorBuilder: (_, __) => Divider(
        height: 1,
        color: colors.divider,
      ),
      itemBuilder: (context, index) {
        final reply = replies[index];
        return _SuggestReplyItem(
          text: reply,
          index: index,
          onTap: () => onSelect(index),
          colors: colors,
        );
      },
    );
  }
}

/// 单条候选回复项
class _SuggestReplyItem extends StatefulWidget {
  const _SuggestReplyItem({
    required this.text,
    required this.index,
    required this.onTap,
    required this.colors,
  });

  final String text;
  final int index;
  final VoidCallback onTap;
  final LmPalette colors;

  @override
  State<_SuggestReplyItem> createState() => _SuggestReplyItemState();
}

class _SuggestReplyItemState extends State<_SuggestReplyItem> {
  bool _isHovered = false;
  bool _isFocused = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: InkWell(
        onTap: widget.onTap,
        onFocusChange: (focused) => setState(() => _isFocused = focused),
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
        child: AnimatedContainer(
          duration: LmMotion.durationFor(context, LmMotion.micro),
          padding: const EdgeInsets.symmetric(
            horizontal: LmSpacing.sSm,
            vertical: LmSpacing.sSm,
          ),
          decoration: BoxDecoration(
            color: _isHovered || _isFocused
                ? widget.colors.primaryDim
                : Colors.transparent,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 序号标记（琥珀金，呼应标题点）
              Container(
                constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                padding: const EdgeInsets.all(LmSpacing.s2xs),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: widget.colors.primaryDim,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '${widget.index + 1}',
                  style: LmNarrativeTextStyles.caption.copyWith(
                    color: widget.colors.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: LmSpacing.sSm),
              // 完整候选可在浮层内滚动阅读，选择后仍插入原文。
              Expanded(
                child: Text(
                  widget.text,
                  style: LmNarrativeTextStyles.input.copyWith(
                    color: widget.colors.ink,
                    height: 1.4,
                  ),
                  textAlign: TextAlign.left,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
