import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/compaction_failed_card.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/message_bubble/bubble_action_bar.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/message_bubble/bubble_avatar.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/message_bubble/bubble_compaction_card.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/message_bubble/bubble_content.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/message_bubble/bubble_meta.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_fork_nav.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/settings/domain/entities/display_preferences.dart';

// 拆分说明：本文件原为 ~2900 行巨型组件，已按职责物理拆解到
// message_bubble/ 子目录（各拆分文件 < 600 行），本文件只保留
// SimpleMessageBubble 主框架装配。为保持外部 import 路径与符号不变，
// 下方 export 转发全部拆分产物；子文件禁止反向 import 本文件。
export 'message_bubble/bubble_action_bar.dart';
export 'message_bubble/bubble_avatar.dart';
export 'message_bubble/bubble_compaction_card.dart';
export 'message_bubble/bubble_content.dart';
export 'message_bubble/bubble_error_message.dart';
export 'message_bubble/bubble_image_gallery.dart';
export 'message_bubble/bubble_meta.dart';
export 'message_bubble/bubble_shared.dart';
export 'message_bubble/bubble_thinking_card.dart';
export 'message_bubble/bubble_tool_call.dart';

/// Simple mode message bubble.
///
/// Visual differentiation:
/// - **User**: primary background, white text, right-aligned,
///   bottom-right corner reduced to 4 px (tail effect).
/// - **Assistant**: surfaceVariant background, ink text,
///   left-aligned, bottom-left corner reduced to 4 px (tail effect).
/// - **Summary** (isSummary=true): left border accent + italic text.
///
/// 操作按钮显示策略（对标 ChatBox）：
/// - 最后一条助手消息：始终显示操作按钮
/// - 其他消息：点击消息内容切换显示操作按钮，3 秒后自动隐藏
/// - 不可见时不渲染（不留白、不可点击），避免"留白但不可见"的体验问题
class SimpleMessageBubble extends StatefulWidget {
  const SimpleMessageBubble({
    required this.message,
    required this.isStreaming,
    required this.isConsecutive,
    super.key,
    this.isThinking = false,
    this.isGenerating = false,
    this.onCopy,
    this.onEdit,
    this.onDelete,
    this.onRegenerate,
    this.onContinueGenerating,
    this.onQuote,
    this.forkIndex,
    this.forkCount,
    this.onForkPrev,
    this.onForkNext,
    this.isLastAssistantMessage = false,
    this.displayPreferences = const DisplayPreferences(),
    this.modelName,
    this.fontScale = 1.0,
    this.onEditSummary,
    this.onDeleteSummary,
    this.isLatestSummary = false,
    this.onRetryCompaction,
    this.onCloseFailedSummary,
    this.isCompactionStreaming = false,
    this.searchQuery,
  });

  final ChatMessage message;
  final bool isStreaming;
  final bool isConsecutive;

  /// 字体缩放比例（来自设置中的字体大小选项）
  /// - small: 0.9
  /// - medium: 1.0
  /// - large: 1.15
  final double fontScale;

  /// Whether the assistant is currently in a thinking/reasoning state.
  final bool isThinking;

  /// Whether this message is currently being generated (streaming or thinking).
  /// Used to show a rotating icon on the avatar.
  final bool isGenerating;

  /// Callback when the user taps "copy" on this message.
  final VoidCallback? onCopy;

  /// Callback when the user taps "edit" on this message (user messages only).
  final VoidCallback? onEdit;

  /// Callback when the user taps "delete" on this message.
  final VoidCallback? onDelete;

  /// Callback when the user taps "regenerate" on an assistant message.
  final VoidCallback? onRegenerate;

  /// Callback when the user taps "continue generating" on a user message.
  final VoidCallback? onContinueGenerating;

  /// Callback when the user taps "quote" on this message.
  final VoidCallback? onQuote;

  /// Current fork index (1-based). Null if no forks exist.
  final int? forkIndex;

  /// Total number of forks. Null if no forks exist.
  final int? forkCount;

  /// Callback when the user taps the previous fork arrow.
  final VoidCallback? onForkPrev;

  /// Callback when the user taps the next fork arrow.
  final VoidCallback? onForkNext;

  /// Whether this is the last assistant message in the conversation.
  /// Used to always show action bar (not just on hover).
  final bool isLastAssistantMessage;

  /// Display preferences controlling visibility of avatar, timestamp, etc.
  final DisplayPreferences displayPreferences;

  /// Model name to display below assistant messages.
  final String? modelName;

  /// 会话内搜索命中时的查询词（非 null = 该消息命中，渲染命中上下文条）
  final String? searchQuery;

  /// Callback when the user taps "edit" on a summary message.
  /// 对标 ChatBox SummaryMessage handleEdit。
  final VoidCallback? onEditSummary;

  /// Callback when the user taps "delete" on a summary message.
  /// 对标 ChatBox SummaryMessage onDelete。删除摘要后原始消息恢复到上下文。
  final VoidCallback? onDeleteSummary;

  /// 本摘要是否为最新压缩（决定撤销/删除文案）
  final bool isLatestSummary;

  /// Callback when the user taps "retry" on a failed compaction summary.
  ///
  /// 失败摘要消息（isSummary && error != null）点重试时触发，
  /// 删除失败摘要后重新触发流式压缩。
  final VoidCallback? onRetryCompaction;

  /// Callback when the user taps "close" on a failed compaction summary.
  ///
  /// 失败摘要消息点关闭时触发，从对话流删除该失败摘要（无 CompactionPoint，安全）。
  final VoidCallback? onCloseFailedSummary;

  /// 当前这条摘要消息是否正在流式生成内容（压缩进行中）。
  ///
  /// 仅当 `state.isCompressing && message.messageId == state.currentCompactionSummaryId`
  /// 时为 true。UI 据此切换渲染：
  /// - 折叠态：标签行显示"正在生成摘要..." + 加载动画；下方小窗实时预览流式内容
  ///   的最后几行，末尾闪烁光标
  /// - 展开态：正常显示流式内容，末尾闪烁光标
  ///
  /// 对标 ChatBox 的 CompactionStatus 组件 + 流式光标组合。
  final bool isCompactionStreaming;

  @override
  State<SimpleMessageBubble> createState() => _SimpleMessageBubbleState();
}

///  批1：气泡 memo 签名（结构化 == 的 record）
typedef _BubbleMemoSignature = ({
  bool isStreaming,
  bool isConsecutive,
  bool isThinking,
  bool isGenerating,
  bool isLastAssistantMessage,
  bool isCompactionStreaming,
  double fontScale,
  int? forkIndex,
  int? forkCount,
  String? modelName,
  DisplayPreferences displayPreferences,
  Brightness brightness,
  bool actionsVisible,
  bool actionsHovered,
  String? searchQuery,
});

class _SimpleMessageBubbleState extends State<SimpleMessageBubble> {
  /// 点击消息内容时切换显示操作按钮
  /// 3 秒后自动隐藏（对标 ChatBox 移动端交互）
  /// 使用 onTap 而非 onLongPress，避免触发文字选择
  bool _actionsVisible = false;

  /// 桌面悬停态——此前 MouseRegion 挂在
  /// [BubbleMessageActions] 内部，不可见时整块不渲染（SizedBox.shrink），
  /// hover 永远无法置位，用户/历史消息必须先点击气泡才能唤出操作条。
  /// 改为消息行级 MouseRegion（见 build 返回值）置位本标志；与点击态
  /// [_actionsVisible] 分离，互不抢占对方的隐藏节奏（触屏无 mouse
  /// pointer 不触发，不影响移动端点击交互）。
  bool _actionsHovered = false;

  // ──  批1：气泡级 identical memo ──────────────────────
  //
  // 流式期间页面每 32ms 整页重建，可见历史气泡的 itemBuilder 全部重跑。
  // message 实例 identical 且全部标量输入未变时返回上次构建的同一 child
  // 实例 → Flutter updateChild 剪枝整棵子树（SimpleMarkdownBody memo 只
  // 救 markdown 子树，本 memo 把剪枝上提到气泡级）。缓存子树持有的旧
  // 闭包与新建闭包在相同失效输入下行为等价（闭包捕获 message 实例与
  // 页面 State 方法，均稳定）。
  Widget? _memoChild;
  ChatMessage? _memoMessage;
  _BubbleMemoSignature? _memoSignature;

  /// memo 签名：build 方法直接消费的全部「非闭包」输入（record 结构化
  /// ==）。闭包不比较——其可见性由签名内字段（role/isSummary/fork*/
  /// isStreaming 等，经 message 实例与标量传递）派生，签名相同则闭包
  /// 集合语义相同。
  _BubbleMemoSignature _memoSignatureOf(Brightness brightness) => (
        isStreaming: widget.isStreaming,
        isConsecutive: widget.isConsecutive,
        isThinking: widget.isThinking,
        isGenerating: widget.isGenerating,
        isLastAssistantMessage: widget.isLastAssistantMessage,
        isCompactionStreaming: widget.isCompactionStreaming,
        fontScale: widget.fontScale,
        forkIndex: widget.forkIndex,
        forkCount: widget.forkCount,
        modelName: widget.modelName,
        displayPreferences: widget.displayPreferences,
        brightness: brightness,
        actionsVisible: _actionsVisible,
        // 悬停态入签名——不入会被 identical 剪枝，hover 置位不重建
        actionsHovered: _actionsHovered,
        // 2026-09-08：会话内搜索命中条入签名——搜索开/关只改该字段，
        // 不入签名会被 identical 剪枝命中条残留（关闭搜索后不消失）。
        searchQuery: widget.searchQuery,
      );

  void _toggleActions() {
    setState(() => _actionsVisible = !_actionsVisible);
    if (_actionsVisible) {
      // 3 秒后自动隐藏
      Future.delayed(const Duration(seconds: 3), () {
        if (mounted) setState(() => _actionsVisible = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final message = widget.message;
    final isUser = message.role == 'user';
    final isSummary = message.isSummary;
    final isStreaming = widget.isStreaming;
    final isConsecutive = widget.isConsecutive;
    final displayPreferences = widget.displayPreferences;

    //  memo：identical 消息 + 同签名 → 返回缓存 child（剪枝整棵子树）
    final signature = _memoSignatureOf(Theme.of(context).brightness);
    if (_memoChild != null &&
        identical(message, _memoMessage) &&
        signature == _memoSignature) {
      return _memoChild!;
    }
    final child = _buildContent(
      colors: colors,
      message: message,
      isUser: isUser,
      isSummary: isSummary,
      isStreaming: isStreaming,
      isConsecutive: isConsecutive,
      displayPreferences: displayPreferences,
    );
    _memoChild = child;
    _memoMessage = message;
    _memoSignature = signature;
    return child;
  }

  Widget _buildContent({
    required LmPalette colors,
    required ChatMessage message,
    required bool isUser,
    required bool isSummary,
    required bool isStreaming,
    required bool isConsecutive,
    required DisplayPreferences displayPreferences,
  }) {
    // Summary messages (CompactionPoint) are rendered as expandable cards.
    // 失败摘要（isSummary && error != null）渲染为常驻失败卡片。
    if (isSummary) {
      if (message.error != null) {
        return CompactionFailedCard(
          message: message,
          colors: colors,
          onRetry: widget.onRetryCompaction ?? () {},
          onClose: widget.onCloseFailedSummary ?? () {},
        );
      }
      return BubbleCompactionSummaryCard(
        message: message,
        colors: colors,
        isStreaming: widget.isCompactionStreaming,
        isLatestSummary: widget.isLatestSummary,
        onEdit: widget.onEditSummary,
        onDelete: widget.onDeleteSummary,
      );
    }

    final isStandardMode =
        displayPreferences.messageLayoutMode == MessageLayoutMode.standard;

    // 构建头像组件（对标 ChatBox）
    // - Standard 模式：用户和 AI 头像都在左侧
    // - Bubble 模式：用户头像在右侧，AI 头像在左侧
    // - 连续消息时用等宽占位保持对齐，不显示头像图标
    Widget? avatarWidget;
    if (displayPreferences.showAvatar) {
      avatarWidget = isConsecutive
          ? const SizedBox(width: 32)
          : BubbleMessageAvatar(
              isUser: isUser,
              colors: colors,
              isGenerating: widget.isGenerating,
            );
    }

    // 操作按钮是否始终可见：
    // - 最后一条助手消息：始终可见
    // - 点击消息内容后：临时可见
    // - 桌面悬停消息行期间：临时可见
    final actionsAlwaysVisible =
        widget.isLastAssistantMessage || _actionsVisible || _actionsHovered;

    // 构建消息内容区域
    //
    // 宽度策略（对标 ChatBox 列占位方式）：
    // - Expanded 自动占据头像之外的剩余空间，不需要手动减去头像宽度
    // - 用户消息（Bubble 模式）：最大宽度 92%，右对齐（增大宽度减少换行）
    // - AI 助手消息：撑满剩余空间，左对齐（与标准模式宽度一致）
    // - Standard 模式：所有消息撑满剩余空间
    final contentWidget = Expanded(
      child: Align(
        alignment: isStandardMode
            ? Alignment.centerLeft
            : (isUser ? Alignment.centerRight : Alignment.centerLeft),
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 用户消息（气泡模式）限制 92% 宽度，减少移动端换行
            // 其他情况撑满可用宽度
            final maxWidth = isStandardMode || !isUser
                ? constraints.maxWidth
                : constraints.maxWidth * 0.92;

            return ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth),
              child: GestureDetector(
                // 点击消息内容切换操作按钮显示/隐藏（移动端主要交互方式）
                // 使用 onTap 而非 onLongPress，避免触发文字选择
                // GestureDetector.onTap 只在子组件未处理点击时触发，
                // 因此不会干扰 Markdown 链接点击
                onTap: _toggleActions,
                child: Column(
                  crossAxisAlignment: isStandardMode
                      ? CrossAxisAlignment.start
                      : (isUser
                          ? CrossAxisAlignment.end
                          : CrossAxisAlignment.start),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Fork navigator (assistant messages with multiple branches)
                    if (!isUser &&
                        widget.forkIndex != null &&
                        widget.forkCount != null &&
                        widget.forkCount! > 1)
                      SimpleForkNav(
                        currentIndex: widget.forkIndex!,
                        totalCount: widget.forkCount!,
                        onPrev: widget.onForkPrev ?? () {},
                        onNext: widget.onForkNext ?? () {},
                      ),
                    // Bubble
                    BubbleMessageContent(
                      message: message,
                      isStreaming: isStreaming,
                      isThinking: widget.isThinking,
                      isUser: isUser,
                      isSummary: isSummary,
                      colors: colors,
                      isStandardMode: isStandardMode,
                      fontScale: widget.fontScale,
                      searchQuery: widget.searchQuery,
                    ),
                    // Meta info line (对标 ChatBox tips: 模型名·tokens·字数·延迟·时间)
                    BubbleMessageMeta(
                      message: message,
                      isStreaming: isStreaming,
                      isUser: isUser,
                      displayPreferences: displayPreferences,
                      colors: colors,
                      modelNameFallback: widget.modelName,
                    ),
                    // Action buttons (show on hover / long-press)
                    if (!isStreaming &&
                        (widget.onCopy != null ||
                            widget.onEdit != null ||
                            widget.onDelete != null ||
                            widget.onRegenerate != null ||
                            widget.onContinueGenerating != null ||
                            widget.onQuote != null))
                      BubbleMessageActions(
                        isUser: isUser,
                        messageContent: message.content ?? '',
                        onCopy: widget.onCopy,
                        onEdit: widget.onEdit,
                        onDelete: widget.onDelete,
                        onRegenerate: widget.onRegenerate,
                        onContinueGenerating: widget.onContinueGenerating,
                        onQuote: widget.onQuote,
                        alwaysVisible: actionsAlwaysVisible,
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );

    // 构建 Row（对标 ChatBox 列占位方式）
    // - Standard 模式：头像在左，内容在右（用户和 AI 一致）
    // - Bubble 模式用户消息：内容在左，头像在右（右对齐）
    // - Bubble 模式 AI 消息：头像在左，内容在右（与标准模式一致）
    final rowChildren = <Widget>[];
    if (avatarWidget != null) {
      if (isUser && !isStandardMode) {
        // 气泡模式用户消息：内容在前，头像在后（右侧）
        rowChildren
          ..add(contentWidget)
          ..add(const SizedBox(width: LmSpacing.sSm))
          ..add(avatarWidget);
      } else {
        // 标准模式所有消息 + 气泡模式 AI 消息：头像在前（左侧），内容在后
        rowChildren
          ..add(avatarWidget)
          ..add(const SizedBox(width: LmSpacing.sSm))
          ..add(contentWidget);
      }
    } else {
      rowChildren.add(contentWidget);
    }

    return MouseRegion(
      // 消息行级悬停唤出操作条（见 _actionsHovered
      // 注释）——MouseRegion 上提包裹整行，进入即显、离开即隐。
      onEnter: (_) {
        if (!_actionsHovered) setState(() => _actionsHovered = true);
      },
      onExit: (_) {
        if (_actionsHovered) setState(() => _actionsHovered = false);
      },
      child: Padding(
        padding: EdgeInsets.only(
          bottom: isConsecutive ? LmSpacing.s2xs : LmSpacing.sSm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: rowChildren,
        ),
      ),
    );
  }
}
