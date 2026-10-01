import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/streaming_markdown_body.dart';
import 'package:lmstory/core/theme/shared/search_highlight.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/message_bubble/bubble_error_message.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/message_bubble/bubble_image_gallery.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/message_bubble/bubble_shared.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/message_bubble/bubble_thinking_card.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/message_bubble/bubble_tool_call.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_markdown_body.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';

// =============================================================================
// Message bubble content
// （从 simple_message_bubble.dart 拆出，主文件装配引用）
// =============================================================================

class BubbleMessageContent extends StatelessWidget {
  const BubbleMessageContent({
    required this.message,
    required this.isStreaming,
    required this.isThinking,
    required this.isUser,
    required this.isSummary,
    required this.colors,
    super.key,
    this.isStandardMode = false,
    this.fontScale = 1.0,
    this.searchQuery,
  });

  final ChatMessage message;
  final bool isStreaming;
  final bool isThinking;
  final bool isUser;
  final bool isSummary;
  final LmPalette colors;
  final bool isStandardMode;

  /// 字体缩放比例（来自设置中的字体大小选项）
  final double fontScale;

  /// 会话内搜索命中高亮（2026-09-08 搜索体验修复）：非 null 时该消息为
  /// 搜索命中，气泡顶部渲染「命中上下文条」——围绕首命中的片段 + 关键字
  /// 高亮，解决此前只有整条消息闪烁定位、看不到关键字在哪的问题。
  final String? searchQuery;

  @override
  Widget build(BuildContext context) {
    final isStandardMode = this.isStandardMode;
    final content = message.content ?? '';

    // In standard mode: user messages use ink text color (not white)
    // In bubble mode: user messages use onPrimary on primary background——
    // 波尔多夜 primary=白药丸（onPrimary=深酒字），日 primary=酒药丸
    // （onPrimary=浅字）；硬编码白会在夜间白底上不可读。
    final userTextColor = isStandardMode ? colors.ink : colors.onPrimary;

    return context.lmUi.messageBubble(
      context,
      isUser: isUser,
      standardLayout: isStandardMode,
      summary: isSummary,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 会话内搜索命中上下文条：正文是 Markdown，
          // 不在正文中做高亮（侵入解析层），以「片段 + 关键字高亮」的
          // 引用条形式给出关键字位置，与全局搜索预览同语言。
          if (searchQuery != null && searchQuery!.isNotEmpty)
            _SearchMatchStrip(
              content: content,
              query: searchQuery!,
              colors: colors,
              onPrimaryBackground: !isStandardMode && isUser,
            ),
          // Attachment previews (images and files)
          if (message.attachments != null && message.attachments!.isNotEmpty)
            BubbleAttachmentPreview(
              attachments: message.attachments!,
              isUser: isUser,
              colors: colors,
            ),
          // Thinking content section (above main content)
          if (!isUser && (message.thinkingContent != null || isThinking))
            BubbleThinkingSection(
              thinkingContent: message.thinkingContent,
              thinkingDuration: message.thinkingDuration,
              isThinking: isThinking,
              colors: colors,
            ),
          // Main content
          if (isStreaming && !isThinking && content.isEmpty)
            BubbleBouncingDotsIndicator(colors: colors)
          else if (content.isNotEmpty || (isStreaming && !isThinking))
            Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Flexible(
                  // 用户消息用 SelectableText 支持部分文字选择复制；
                  // 助手消息用 SimpleMarkdownBody（内部 selectable: true）。
                  // 长按事件由 SelectableText/MarkdownBody 自行处理触发文字选择。
                  // 点击交互：SelectableText 未选中文字时，tap 可传递到外层
                  // GestureDetector 切换操作按钮；有选中文字时 tap 会先清除选中。
                  // 点击气泡空白区域始终能切换操作按钮。
                  child: isUser
                      ? SelectableText(
                          content,
                          style: LmUiTextStyles.body.copyWith(
                            color: userTextColor,
                            fontSize: (LmUiTextStyles.body.fontSize ?? 15) *
                                fontScale,
                            fontStyle: isSummary ? FontStyle.italic : null,
                          ),
                          // 点击工具栏的"复制"按钮时复制全部，
                          // 用户也可以长按手动选择部分文字复制。
                        )
                      : isStreaming
                          ? StreamingMarkdownBody(
                              //  批2：流式期间冻结前缀分块渲染——每帧
                              // 只重解析尾部未闭合窗口（O(尾块) 而非
                              // O(全文)），完成/中断后切回下方整文渲染
                              //（一次终解析由 SimpleMarkdownBody memo 接管）
                              //
                              // 纯文本单块尾段走 Text
                              // 快速路径（样式与 styleSheet.p 同源），
                              // 叙事散文无空行流式时免全文 Markdown 重解析。
                              // cacheKey 纳入 colors：浅/深主题切换时冻结块
                              // 与尾段同步失效重建。
                              data: content,
                              blockGap: LmSpacing.s2xs,
                              cacheKey: (fontScale, colors),
                              // 平滑揭示配速（消除模型输出
                              // 快时每 32ms 一整批字同时上屏的蹦字感）。
                              revealPacing: true,
                              plainTextStyle: SimpleMarkdownBody.paragraphStyle(
                                colors: colors,
                                fontScale: fontScale,
                              ),
                              blockBuilder: (segment) => SimpleMarkdownBody(
                                data: segment,
                                fontScale: fontScale,
                              ),
                            )
                          : SimpleMarkdownBody(
                              data: content,
                              fontScale: fontScale,
                            ),
                ),
                if (isStreaming && !isThinking) const BubbleStreamingCursor(),
              ],
            ),
          // Error message (persisted, shown when not streaming)
          if (!isUser && message.error != null && !isStreaming)
            BubbleErrorMessage(errorText: message.error!, colors: colors),
          // Tool call sections (below main content)
          if (!isUser && message.toolCalls != null)
            BubbleToolCallSection(
              toolCalls: message.parsedToolCalls,
              colors: colors,
            ),
        ],
      ),
    );
  }
}

// =============================================================================
// 会话内搜索命中上下文条（2026-09-08 搜索体验修复）
// =============================================================================

/// 搜索命中消息顶部的「命中上下文条」：围绕首命中截取片段并高亮关键字。
///
/// 此前会话内搜索只有整条消息的短暂闪示（1200ms 后消失），用户看不到
/// 关键字在消息中的位置。该条在搜索条可见期间常驻于命中消息顶部，
/// 与全局搜索结果预览同一套高亮语言（core/theme/shared/search_highlight）。
class _SearchMatchStrip extends StatelessWidget {
  const _SearchMatchStrip({
    required this.content,
    required this.query,
    required this.colors,
    required this.onPrimaryBackground,
  });

  final String content;
  final String query;
  final LmPalette colors;

  /// 气泡模式下的用户消息（primary 背景）：条内改用透明底 + 白系文字，
  /// 避免 primaryDim 叠 primary 的低对比。
  final bool onPrimaryBackground;

  @override
  Widget build(BuildContext context) {
    final idx = findQueryIndex(content, query);
    // 未命中（理论上不该发生——调用方只对命中消息传 query）不渲染，
    /// 宁可无声降级也不能显示一条空/误导的引用条。
    if (idx < 0) return const SizedBox.shrink();

    final snippet = buildContextSnippet(content, idx, query.length);
    // onPrimary 族的半透明台阶随配色自适应（夜=深酒字于白药丸底，
    // 日=浅字于酒药丸底）；硬编码白在夜间白底上不可见。
    final baseColor = onPrimaryBackground
        ? colors.onPrimary.withValues(alpha: 0.9)
        : colors.ink;
    final highlightColor =
        onPrimaryBackground ? colors.onPrimary : colors.primary;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: LmSpacing.sXs),
      padding: const EdgeInsets.symmetric(
        horizontal: LmSpacing.sSm,
        vertical: LmSpacing.s2xs,
      ),
      decoration: BoxDecoration(
        color: onPrimaryBackground
            ? colors.onPrimary.withValues(alpha: 0.12)
            : colors.primaryDim,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
      ),
      child: Row(
        children: [
          Icon(
            Icons.search,
            size: 12,
            color: highlightColor.withValues(alpha: 0.8),
          ),
          const SizedBox(width: LmSpacing.sXs),
          Expanded(
            child: RichText(
              text: buildSearchHighlightSpans(
                text: snippet,
                query: query,
                baseStyle: LmUiTextStyles.caption.copyWith(color: baseColor),
                highlightStyle: LmUiTextStyles.caption.copyWith(
                  color: highlightColor,
                  fontWeight: FontWeight.w700,
                  backgroundColor: onPrimaryBackground
                      ? colors.onPrimary.withValues(alpha: 0.25)
                      : colors.primary.withValues(alpha: 0.18),
                ),
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
