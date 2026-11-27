import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/lm_activity_dots.dart';
import 'package:lmstory/core/theme/shared/components/streaming_fade_text.dart';
import 'package:lmstory/core/theme/shared/components/streaming_markdown_body.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_markdown_body.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_message_actions.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 中级模式消息气泡（DOC-06B §6.1）。
///
/// 与 Simple 模式差异：
/// - 助手消息用衬线字体（叙事感）
/// - Assistant prose uses the full reading column without a bubble face.
/// - User input keeps a distinct surface and a 92% column-width limit.
///
/// 入场动画（从下方上浮 + 淡入 250ms ease-out，DOC-06B §5.3）。
/// 仅在 widget 首次构建时播放一次；reduced-motion 下瞬时显示。
///
/// 接入横排纯图标动作按钮行（IntermediateMessageActions，Grok 风格）。
/// tap 气泡切换动作可见性，3s 自动隐藏；最后一条助手消息常驻；
/// 流式生成时不显示动作。
class IntermediateMessageBubble extends StatefulWidget {
  const IntermediateMessageBubble({
    required this.content,
    required this.isUser,
    this.thinkingContent,
    this.isStreaming = false,
    this.isLastAssistantMessage = false,
    this.canOperate = true,
    this.windowRounds = 5,
    this.actionsEnabled = true,
    this.animateEntrance = true,
    this.softLineBreak = false,
    this.fontScale = 1.0,
    this.onCopy = _noop,
    this.onRegenerate = _noop,
    this.onEdit = _noop,
    this.onDeleteRound = _noop,
    super.key,
  });

  /// 消息文本内容
  final String content;

  /// User input is right-aligned; assistant prose sits directly on the page.
  final bool isUser;

  /// LLM 思考/推理内容（仅助手消息，null = 无思考内容）
  ///
  /// 来自模型的 `reasoning_content` / `reasoning` 字段，
  /// 在气泡中以可折叠的"思考过程"区块展示。
  final String? thinkingContent;

  /// 是否正在流式生成（仅助手消息适用）
  final bool isStreaming;

  /// 是否为最后一条助手消息（true 时动作常驻显示）
  final bool isLastAssistantMessage;

  /// 当前消息是否可操作（在 Fork 窗口范围内）
  final bool canOperate;

  /// 窗口轮数（用于 canOperate=false 时的提示文案）
  final int windowRounds;

  /// 全局动作开关（phase != idle 时为 false，隐藏所有动作菜单避免生成中误操作）
  final bool actionsEnabled;

  /// Whether to animate the first mount of this bubble.
  ///
  /// Persisted history disables this so lazy list recycling does not replay
  /// entrance motion while the user scrolls. New and streaming messages keep
  /// the transition.
  final bool animateEntrance;

  final bool softLineBreak;

  /// 字体缩放比例（来自通用设置"字体大小"，与 SimpleMessageBubble 共享计算公式）。
  ///
  /// fontScale = fontSize.clamp(12, 22) / 15。默认 1.0（fontSize=15）。
  /// 应用到消息正文（助手 narrativeBody 16px / 用户 bodyUi 15px）与
  /// 思考区块（narrativeQuote 14px）的字号，保留双字体策略与字号差异，
  /// 仅在基准上按 fontScale 缩放。UI 标签（caption/label）不受影响。
  final double fontScale;

  /// 复制回调（始终可用）
  final VoidCallback onCopy;

  /// 重新生成回调（仅助手消息 + canOperate）
  final VoidCallback onRegenerate;

  /// 编辑重发回调（仅用户消息 + canOperate）
  final VoidCallback onEdit;

  /// 删除整轮回调（canOperate）
  final VoidCallback onDeleteRound;

  /// 空操作默认值，让无回调场景仍可 const 构造
  static void _noop() {}

  @override
  State<IntermediateMessageBubble> createState() =>
      _IntermediateMessageBubbleState();
}

/// 气泡 memo 签名（结构化 == 的 record，照抄 chat 侧
/// simple_message_bubble.dart 的  批1 模式）
typedef _BubbleMemoSignature = ({
  bool isUser,
  bool isStreaming,
  bool isLastAssistantMessage,
  bool canOperate,
  bool actionsEnabled,
  int windowRounds,
  double fontScale,
  Brightness brightness,
  bool actionsVisible,
});

class _IntermediateMessageBubbleState extends State<IntermediateMessageBubble>
    with SingleTickerProviderStateMixin {
  // ── ：气泡级 identical memo ──────────────────────
  //
  // 流式期间页面每 32ms 整页重建，可见历史气泡的 itemBuilder 全部重跑。
  // content/thinkingContent 实例 identical 且全部标量输入未变时返回上次
  // 构建的同一 content child 实例 → Flutter updateChild 剪枝整棵子树
  //（IntermediateMarkdownBody memo 只救 markdown 子树，本 memo 把剪枝
  // 上提到气泡级）。入场动画与动作条在 memo 子树之外，不受影响。
  Widget? _memoChild;
  String? _memoContent;
  String? _memoThinking;
  _BubbleMemoSignature? _memoSignature;

  _BubbleMemoSignature _memoSignatureOf(Brightness brightness) => (
        isUser: widget.isUser,
        isStreaming: widget.isStreaming,
        isLastAssistantMessage: widget.isLastAssistantMessage,
        canOperate: widget.canOperate,
        actionsEnabled: widget.actionsEnabled,
        windowRounds: widget.windowRounds,
        fontScale: widget.fontScale,
        brightness: brightness,
        // 动作菜单可见性影响 _buildContent 之外的布局，但入签名保证
        // 翻转时整体重建语义简单（与 chat 侧一致）
        actionsVisible: _actionsVisible,
      );

  // 入场动画控制器（懒初始化：reduced-motion 下不创建，避免无用资源）
  // 使用 late final + bool flag 模式而非 nullable，符合 very_good_analysis 规范
  bool _animationInitialized = false;
  bool _animationStarted = false;
  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slideOffset;

  // ⋮ 动作菜单可见性状态
  // 默认隐藏；tap 气泡切换；3 秒自动隐藏（最后一条助手消息常驻）
  bool _actionsVisible = false;
  Timer? _autoHideTimer;

  /// 动作菜单是否显示
  /// - 最后一条助手消息：常驻显示
  /// - 其他消息：tap 切换 + 3s 自动隐藏
  /// - 流式生成中：不显示
  /// - 全局开关关闭（phase != idle）：不显示
  bool get _showActions =>
      (widget.isLastAssistantMessage || _actionsVisible) &&
      !widget.isStreaming &&
      widget.actionsEnabled;

  /// 切换动作菜单可见性（tap 气泡触发）
  /// 显示后 3 秒自动隐藏；最后一条助手消息不启动 timer（常驻）
  void _toggleActions() {
    setState(() {
      _actionsVisible = !_actionsVisible;
    });
    _autoHideTimer?.cancel();
    if (_actionsVisible && !widget.isLastAssistantMessage) {
      _autoHideTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() {
            _actionsVisible = false;
          });
        }
      });
    }
  }

  void _ensureAnimationInit() {
    if (_animationInitialized) return;
    _animationInitialized = true;
    _controller = AnimationController(
      duration: LmMotion.slow,
      vsync: this,
    );
    _opacity = CurvedAnimation(
      parent: _controller,
      curve: LmMotion.easeStandard,
    );
    // 从下方 10% 偏移上浮到原位（DOC-06B §5.3）
    _slideOffset = Tween<Offset>(
      begin: const Offset(0, 0.1),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _controller, curve: LmMotion.easeStandard),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reducedMotion = LmMotion.reducedMotion(context);
    if (widget.animateEntrance && !reducedMotion && !_animationStarted) {
      _ensureAnimationInit();
      _animationStarted = true;
      // 首次构建后启动入场动画
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _controller.forward();
        }
      });
    }
  }

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    if (_animationInitialized) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final reducedMotion = LmMotion.reducedMotion(context);

    // 用 GestureDetector 包裹气泡，tap 切换动作菜单可见性
    // 行为用 opaque，让气泡空白区域也能响应 tap
    final bubble = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleActions,
      child: Align(
        alignment: widget.isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: LayoutBuilder(
          builder: (context, constraints) => ConstrainedBox(
            // 92% 取「列宽」而非「视口宽」——与对话模式气泡
            // （simple_message_bubble 同款 LayoutBuilder 写法）同一口径。
            // 按视口取宽既会让窗口变大直接拉长正文行（2560 窗口下 ~2355px），
            // 也会在正文列被限宽后反过来贴满整列（92% 形同虚设）。
            constraints: BoxConstraints(
              maxWidth: constraints.maxWidth * (widget.isUser ? 0.92 : 1),
            ),
            child: context.lmUi.messageBubble(
              context,
              isUser: widget.isUser,
              standardLayout: false,
              narrative: true,
              child: _buildContent(colors),
            ),
          ),
        ),
      ),
    );

    // 入场动画包裹气泡（actions 不参与入场动画，独立显示）
    final animatedBubble = (reducedMotion || !_animationInitialized)
        ? bubble
        : FadeTransition(
            opacity: _opacity,
            child: SlideTransition(
              position: _slideOffset,
              child: bubble,
            ),
          );

    // 在气泡下方渲染横排动作按钮行（Grok 风格纯图标）
    // actions 放在动画 widget 之外：入场动画结束后 actions 即可用
    // 对齐由 IntermediateMessageActions 内部 Align 处理（用户右/助手左）
    final showActions = _showActions;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        animatedBubble,
        if (showActions) ...[
          const SizedBox(height: LmSpacing.sXs),
          IntermediateMessageActions(
            isUser: widget.isUser,
            canOperate: widget.canOperate,
            windowRounds: widget.windowRounds,
            onCopy: widget.onCopy,
            onRegenerate: widget.onRegenerate,
            onEdit: widget.onEdit,
            onDeleteRound: widget.onDeleteRound,
          ),
        ],
      ],
    );
  }

  Widget _buildContent(LmPalette colors) {
    //  memo：identical content/thinkingContent + 同签名 → 返回缓存
    // child（剪枝整棵内容子树）
    final signature = _memoSignatureOf(Theme.of(context).brightness);
    if (_memoChild != null &&
        identical(widget.content, _memoContent) &&
        identical(widget.thinkingContent, _memoThinking) &&
        signature == _memoSignature) {
      return _memoChild!;
    }
    final child = _buildContentUncached(colors);
    _memoChild = child;
    _memoContent = widget.content;
    _memoThinking = widget.thinkingContent;
    _memoSignature = signature;
    return child;
  }

  Widget _buildContentUncached(LmPalette colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 思考过程（可折叠，仅助手消息且有思考内容时显示）
        if (!widget.isUser &&
            widget.thinkingContent != null &&
            widget.thinkingContent!.isNotEmpty)
          _ThinkingSection(
            content: widget.thinkingContent!,
            colors: colors,
            fontScale: widget.fontScale,
          ),
        // 有限 Markdown 渲染（DOC-06B §6.1）：
        // - 助手消息：衬线叙事字体，启用基础 CommonMark 语法（加粗/斜体/引用/列表/分隔线/行内代码/链接）
        // - 用户消息：无衬线 UI 字体，同样启用基础 Markdown（用户可能输入 *强调* 等）
        // - 长按选择文字：MarkdownBody selectable=true
        // - 点击交互：selectable Markdown 会消费文字区域的 tap，因此通过
        //   onTapText 显式转发；外层 GestureDetector 继续覆盖气泡留白区域
        // - 链接点击：MarkdownBody 的 onTapLink 处理，打开外部浏览器
        // - 流式生成中：走冻结前缀分块渲染——每帧
        //   只重解析尾部未闭合窗口（O(尾块) 而非 O(全文)；此前
        //   IntermediateMarkdownBody 无 memo，全文重解析是长会话卡顿主源
        //   之一）；完成/中断后回整文渲染
        if (widget.isStreaming && widget.content.isEmpty)
          LmActivityDots(color: colors.primary)
        else if (widget.isStreaming)
          StreamingMarkdownBody(
            data: widget.content,
            blockGap: LmSpacing.s2xs,
            cacheKey: (widget.isUser, widget.fontScale),
            // 平滑揭示配速（消除批量上屏的蹦字感）。
            revealPacing: true,
            // 纯文本单块尾段走 Text 快速路径（样式与
            // styleSheet.p 同源）——叙事散文无空行流式时免全文重解析。
            // 中级配色当前恒为夜航单实例，样式输入仅 isUser/fontScale，
            // cacheKey 已覆盖。
            plainTextStyle: IntermediateMarkdownBody.paragraphStyle(
              colors: colors,
              isUser: widget.isUser,
              fontScale: widget.fontScale,
            ),
            blockBuilder: (segment) => IntermediateMarkdownBody(
              data: segment,
              isUser: widget.isUser,
              fontScale: widget.fontScale,
              onTapText: _toggleActions,
            ),
          )
        else
          IntermediateMarkdownBody(
            data: widget.content,
            isUser: widget.isUser,
            softLineBreak: widget.softLineBreak,
            fontScale: widget.fontScale,
            onTapText: _toggleActions,
          ),
        // 流式生成时显示光标
        if (widget.isStreaming && !widget.isUser) ...[
          const SizedBox(height: LmSpacing.s2xs),
          _StreamingCursor(colors: colors),
        ],
      ],
    );
  }
}

/// 流式生成光标（呼吸闪烁的小圆点）
class _StreamingCursor extends StatefulWidget {
  const _StreamingCursor({required this.colors});

  final LmPalette colors;

  @override
  State<_StreamingCursor> createState() => _StreamingCursorState();
}

class _StreamingCursorState extends State<_StreamingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: LmMotion.pulse,
      vsync: this,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    //  reduced-motion：减弱动态下**不启动**循环脉冲（不是启动后再停）。
    if (LmMotion.shouldAnimate(context)) {
      if (!_controller.isAnimating) _controller.repeat(reverse: true);
    } else {
      _controller
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // reduced-motion：光标不闪烁，保持静态显示
    if (!LmMotion.shouldAnimate(context)) {
      return Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          color: widget.colors.primary,
          shape: BoxShape.circle,
        ),
      );
    }
    return FadeTransition(
      opacity: _controller,
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          color: widget.colors.primary,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// 思考过程展示区块（可折叠，默认折叠）。
///
/// 设计对齐 Night Voyage 审美（DOC-06B）：
/// - 折叠态：chevron 图标 + "思考过程" 标签，caption 字号，muted 色
/// - 展开态：思考内容用衬线斜体（narrativeQuote 风格），muted 色
/// - 无背景/边框，仅用间距分隔，保持沉浸感
class _ThinkingSection extends StatefulWidget {
  const _ThinkingSection({
    required this.content,
    required this.colors,
    required this.fontScale,
  });

  final String content;
  final LmPalette colors;

  /// 字体缩放比例（与宿主气泡共享），应用到展开态思考内容字号。
  /// 折叠态的"思考过程"标签使用 caption 字号，不随 fontScale 缩放，
  /// 保持 UI 元素与内容的视觉层次。
  final double fontScale;

  @override
  State<_ThinkingSection> createState() => _ThinkingSectionState();
}

class _ThinkingSectionState extends State<_ThinkingSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => setState(() => _expanded = !_expanded),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _expanded ? Icons.expand_more : Icons.chevron_right,
                size: 16,
                color: widget.colors.muted,
              ),
              const SizedBox(width: LmSpacing.s2xs),
              Text(
                _expanded
                    ? t.intermediate.chat.thinking.collapse
                    : t.intermediate.chat.thinking.expand,
                style: LmNarrativeTextStyles.caption.copyWith(
                  color: widget.colors.muted,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: LmSpacing.sXs),
          // （R1）：思考流式增长文本接共享淡入载体
          // pace：直连载体的流式面自行配速。
          StreamingFadeText(
            data: widget.content,
            pace: true,
            style: LmNarrativeTextStyles.narrativeQuote.copyWith(
              color: widget.colors.muted,
              fontSize: 14 * widget.fontScale,
            ),
          ),
          const SizedBox(height: LmSpacing.sSm),
        ],
      ],
    );
  }
}
