import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/components/history_panel_shell.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 生成小窗（DOC-06B §6.2，V2 四步重构）。
///
/// 状态映射：
/// - generating：surfaceElevated 底 + "正在生成..." + 流式 streamingGenerated
/// - 完成：先展开 [foldDelayMs] 毫秒展示生成全文，然后自动折叠为
///   单行 "▸ 已生成"；用户点击可重新展开/折叠
/// - 失败：AnimatedOpacity + 灰度滤镜过渡到 0.4（300ms ease-out，DOC-06B §5.3）
/// - 历史态（[artifacts] != null）：用 [HistoryPanelShell] 渲染，默认折叠、
///   muted 箭头、入场淡入、无自动折叠定时器、无失败态
///
/// V2 四步重构：generating 产出纯文本生成内容（不含关键词），关键词由 extracting
/// 步骤产出。完成态文案不再显示关键词数。
///
/// 自动折叠时序（DOC-09B §7.3）、easeInOut 曲线、reduced-motion 备选。
///
/// 统一组件（避免"四合二"闪动）：本组件同时承载"生成中"和"完成后"两种态，
/// 通过 [artifacts] 参数切换数据源。完成后无需销毁实时 Widget、创建历史 Widget，
/// 只需将数据源从 streaming 切换到 artifacts 快照。
class GeneratePanel extends StatefulWidget {
  const GeneratePanel({
    required this.phase,
    required this.streamingGenerated,
    required this.generatedText,
    required this.failureContext,
    this.streamingGeneratedThinking,
    this.foldDelayMs = 2000,
    this.artifacts,
    super.key,
  });

  final IntermediatePhase phase;
  final String? streamingGenerated;
  final String? generatedText;
  final FailureContext? failureContext;

  /// generating 阶段的流式思考/推理内容（来自 reasoning_content 字段）
  ///
  /// 2026-07-29 新增：在生成过程中，若模型支持思考且返回了 reasoning_content，
  /// 通过此字段实时传递到 UI，以可折叠的"思考过程"区块展示在生成正文上方。
  /// null 或空字符串表示无思考内容（模型不支持思考或未返回思考链）。
  final String? streamingGeneratedThinking;

  /// 自动折叠延迟（毫秒）。从 `StreamConfig.generatingFoldDelayMs` 传入。
  /// 进入完成态后展开展示该时长，然后自动折叠。0 = 立即折叠。
  final int foldDelayMs;

  /// 历史快照（非 null 时进入历史态渲染）。
  ///
  /// 完成后的轮次通过此参数传入持久化的 [StoryRoundArtifacts]，
  /// 组件从 `artifacts.generatedText` 读取生成全文，用 [HistoryPanelShell]
  /// 渲染折叠/展开态。历史态忽略 [phase]/[streamingGenerated]/[failureContext]。
  final StoryRoundArtifacts? artifacts;

  @override
  State<GeneratePanel> createState() => _GeneratePanelState();
}

class _GeneratePanelState extends State<GeneratePanel> {
  bool _expanded = false;
  Timer? _autoFoldTimer;

  /// 是否已完成自动折叠（用户已交互或定时器已触发，之后不再自动折叠）
  bool _hasAutoFolded = false;

  /// 可见时延迟折叠的已重试次数（2026-07-16 修复问题3）
  int _foldRetryCount = 0;

  /// 可见时最大延迟折叠次数——超过后面板强制折叠让出空间。
  /// 总阅读时间 ≈ foldDelayMs × (_maxFoldRetries + 1)。
  static const int _maxFoldRetries = 2;

  /// 是否已渲染过实时态（非历史态）。
  /// 用于检测从实时态切换到历史态时跳过 HistoryPanelShell 的淡入动画（问题1修复）。

  // 含 generatingRetry（自动重试时小窗保持 generating 视觉态）
  bool get _isGenerating =>
      widget.phase == IntermediatePhase.generating ||
      widget.phase == IntermediatePhase.generatingRetry;
  bool get _isFailed =>
      widget.phase == IntermediatePhase.failed &&
      widget.failureContext?.failedPhase == IntermediatePhase.generating;
  bool get _isCompleted =>
      !_isGenerating && !_isFailed && widget.generatedText != null;

  @override
  void didUpdateWidget(GeneratePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 新轮次开始：从 idle/failed → generating，重置自动折叠状态
    // （统一组件重构后 GeneratePanel 跨轮次复用 State，需手动重置，
    //   否则第 2 轮起 _hasAutoFolded 仍为 true，自动折叠动效失效）
    final wasIdleOrFailed = oldWidget.phase == IntermediatePhase.idle ||
        oldWidget.phase == IntermediatePhase.failed;
    if (wasIdleOrFailed && _isGenerating) {
      _hasAutoFolded = false;
      _expanded = false;
      _autoFoldTimer?.cancel();
      _autoFoldTimer = null;
    }
    // 检测从 generating 转 _isCompleted：进入完成态，启动自动折叠时序
    final wasGenerating = oldWidget.phase == IntermediatePhase.generating ||
        oldWidget.phase == IntermediatePhase.generatingRetry;
    if (wasGenerating && _isCompleted && !_hasAutoFolded) {
      // 进入完成态：先展开展示生成全文
      _expanded = true;
      _foldRetryCount = 0; // 重置可见延迟计数
      _autoFoldTimer?.cancel();
      if (widget.foldDelayMs <= 0) {
        // foldDelayMs=0：立即折叠
        _hasAutoFolded = true;
        _expanded = false;
      } else if (widget.phase == IntermediatePhase.idle) {
        _autoFoldTimer = Timer(
          Duration(milliseconds: widget.foldDelayMs),
          _doAutoFold,
        );
      }
      // 问题4+5修复：生成中（非 idle）不自动折叠，保持展开供用户阅读
    }
  }

  void _doAutoFold() {
    if (mounted) {
      // 2026-07-16 修复问题3：面板在视口可见时延迟折叠，避免打断用户阅读。
      // 定时器到期时如果面板仍可见（用户可能在看）且未超过最大延迟次数，重新计时；
      // 超过最大延迟次数或用户滚走后面板不可见，才真正折叠。
      if (_isVisibleInViewport() && _foldRetryCount < _maxFoldRetries) {
        _foldRetryCount++;
        _autoFoldTimer = Timer(
          Duration(milliseconds: widget.foldDelayMs),
          _doAutoFold,
        );
        return;
      }
      setState(() {
        _expanded = false;
        _hasAutoFolded = true;
      });
    }
  }

  /// 检测当前面板是否在视口可见（用于自动折叠前判断用户是否在阅读）。
  bool _isVisibleInViewport() {
    if (!mounted) return false;
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox) return false;
    final offset = renderObject.localToGlobal(Offset.zero);
    final screenHeight = MediaQuery.of(context).size.height;
    // 顶部在屏幕底部上方 且 底部在屏幕顶部下方 = 有可见部分
    return offset.dy < screenHeight && offset.dy + renderObject.size.height > 0;
  }

  void _toggleExpanded() {
    // 用户手动点击：取消自动折叠定时器，标记已交互
    _autoFoldTimer?.cancel();
    _autoFoldTimer = null;
    setState(() {
      _expanded = !_expanded;
      _hasAutoFolded = true;
    });
  }

  @override
  void dispose() {
    _autoFoldTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 历史态：用 HistoryPanelShell 渲染（默认折叠、muted 箭头、入场淡入）
    if (widget.artifacts != null) {
      return _buildHistory(context);
    }

    // 标记已渲染实时态，用于切换到历史态时跳过淡入动画（问题1修复）

    final colors = context.lm.palette;
    final t = Translations.of(context);
    // reduced-motion：动效时长改 0（DOC-06B §5.1）
    // 自动折叠延时仍生效（属时序逻辑，非动效），让用户仍有时间看清内容
    final reducedMotion = LmMotion.reducedMotion(context);

    // 流式生成中（_isGenerating）：完全不使用 AnimatedSize，避免每个 token
    // 到达时 child size 变化触发 RenderAnimatedSize.performLayout 在 layout
    // 中 markNeedsLayout 自己（"A RenderObject must not re-dirty itself while
    // still being laid out" 错误，2026-07-17 修复）。
    // 仅在状态切换（generating→completed / 展开↔折叠）时启用尺寸动画。
    // reduced-motion：也不用 AnimatedSize（无动画降级更干净）。
    final content = Container(
      margin: const EdgeInsets.symmetric(
        horizontal: IntermediateSpacing.sLg,
        vertical: IntermediateSpacing.sXs,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceElevated,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
      ),
      child: _buildContent(colors, t, reducedMotion),
    );

    if (_isGenerating || reducedMotion) {
      return content;
    }

    return AnimatedSize(
      duration: LmMotion.base,
      // easeOut → easeInOut（DOC-06B §5.3 小窗折叠要求）
      curve: LmMotion.easeBoth,
      child: content,
    );
  }

  /// 历史态渲染：用 [HistoryPanelShell] 容器 + 生成全文展开内容。
  Widget _buildHistory(BuildContext context) {
    final t = Translations.of(context);
    final artifacts = widget.artifacts!;
    final summary = t.intermediate.chat.historyGeneratedReady(
      turn: artifacts.turnNumber,
    );

    return HistoryPanelShell(
      key: ValueKey('history-generate-${artifacts.turnNumber}'),
      summary: summary,
      animateEntrance: false,
      expandedContent:
          artifacts.generatedText != null && artifacts.generatedText!.isNotEmpty
              ? Text(
                  artifacts.generatedText!,
                  style: IntermediateTextStyles.narrativeBody.copyWith(
                    color: context.lm.palette.ink,
                  ),
                )
              : const SizedBox.shrink(),
    );
  }

  Widget _buildContent(
    LmPalette colors,
    Translations t,
    bool reducedMotion,
  ) {
    if (_isGenerating) {
      return _buildGenerating(colors, t);
    }
    if (_isFailed) {
      return _buildFailed(colors, t, reducedMotion);
    }
    if (_isCompleted) {
      return _buildCompleted(colors, t);
    }
    return const SizedBox.shrink();
  }

  /// generating 阶段：标题 + 流式思考内容 + 流式生成正文
  Widget _buildGenerating(LmPalette colors, Translations t) {
    return Padding(
      padding: const EdgeInsets.all(IntermediateSpacing.sMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: colors.primary,
                ),
              ),
              const SizedBox(width: IntermediateSpacing.sXs),
              Text(
                t.intermediate.chat.generating,
                style: IntermediateTextStyles.caption.copyWith(
                  color: colors.muted,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
          // 2026-07-29 新增：流式思考内容（reasoning_content）
          // 模型支持思考时，reasoning_content 通常先于正文输出，
          // 在生成正文上方以可折叠区块展示，让用户确认模型确实在思考。
          if (widget.streamingGeneratedThinking != null &&
              widget.streamingGeneratedThinking!.isNotEmpty) ...[
            const SizedBox(height: IntermediateSpacing.sXs),
            _StreamingThinkingSection(
              content: widget.streamingGeneratedThinking!,
              colors: colors,
            ),
          ],
          if (widget.streamingGenerated != null &&
              widget.streamingGenerated!.isNotEmpty) ...[
            const SizedBox(height: IntermediateSpacing.sXs),
            // 移除 maxLines 限制：让生成内容在生成过程中从头到尾完整可读，
            // 避免用户等待时只能看到前几行的割裂感。
            // 外层滚动视图会处理生成内容过长的情况。
            Text(
              widget.streamingGenerated!,
              style: IntermediateTextStyles.narrativeBody.copyWith(
                color: colors.ink,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 完成态：折叠行（点击展开）
  Widget _buildCompleted(LmPalette colors, Translations t) {
    // V2 四步重构：generating 不再产出关键词，完成态文案不含关键词数
    final summary = t.intermediate.chat.generatedReady;

    return InkWell(
      onTap: _toggleExpanded,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: IntermediateSpacing.sMd,
          vertical: IntermediateSpacing.sSm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right,
                  size: 16,
                  color: colors.primary,
                ),
                const SizedBox(width: IntermediateSpacing.sXs),
                Expanded(
                  child: Text(
                    summary,
                    style: IntermediateTextStyles.caption.copyWith(
                      color: colors.muted,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            if (_expanded) ...[
              const SizedBox(height: IntermediateSpacing.sSm),
              Divider(height: 1, color: colors.divider),
              const SizedBox(height: IntermediateSpacing.sSm),
              // 生成全文（V2：纯文本，无关键词列表）
              Text(
                widget.generatedText ?? '',
                style: IntermediateTextStyles.narrativeBody.copyWith(
                  color: colors.ink,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 失败态：AnimatedOpacity + 灰度滤镜（DOC-06B §5.3 300ms ease-out）
  Widget _buildFailed(
    LmPalette colors,
    Translations t,
    bool reducedMotion,
  ) {
    return AnimatedOpacity(
      opacity: 0.4,
      duration: reducedMotion ? Duration.zero : LmMotion.emphasis,
      curve: LmMotion.easeStandard,
      child: ColorFiltered(
        // 灰度滤镜：饱和度 0（保留明度，去除色相）
        colorFilter: const ColorFilter.matrix(<double>[
          0.2126,
          0.7152,
          0.0722,
          0,
          0,
          0.2126,
          0.7152,
          0.0722,
          0,
          0,
          0.2126,
          0.7152,
          0.0722,
          0,
          0,
          0,
          0,
          0,
          1,
          0,
        ]),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: IntermediateSpacing.sMd,
            vertical: IntermediateSpacing.sSm,
          ),
          child: Row(
            children: [
              Icon(Icons.error_outline, size: 16, color: colors.error),
              const SizedBox(width: IntermediateSpacing.sXs),
              Expanded(
                child: Text(
                  widget.failureContext?.errorMessage ??
                      t.intermediate.chat.retrievalFailed,
                  style: IntermediateTextStyles.caption.copyWith(
                    color: colors.muted,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 生成中的流式思考内容区块（可折叠，默认展开）。
///
/// 2026-07-29 新增：与中级模式消息气泡的思考区块类似，但默认展开
///（生成中用户想看模型在思考什么），且用流式样式（无展开/收起动画，
/// 避免每个 token 到达时触发动画）。
///
/// 设计对齐 Night Voyage 审美（DOC-06B）：
/// - 折叠态：chevron 图标 + "思考过程" 标签，caption 字号，muted 色
/// - 展开态：思考内容用衬线斜体（narrativeQuote 风格），muted 色
/// - 无背景/边框，仅用间距分隔，保持沉浸感
class _StreamingThinkingSection extends StatefulWidget {
  const _StreamingThinkingSection({
    required this.content,
    required this.colors,
  });

  final String content;
  final LmPalette colors;

  @override
  State<_StreamingThinkingSection> createState() =>
      _StreamingThinkingSectionState();
}

class _StreamingThinkingSectionState extends State<_StreamingThinkingSection> {
  // 默认展开：生成中用户想看模型在思考什么
  // 若用户主动折叠，后续保持折叠态（尊重用户选择）
  bool _expanded = true;

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
              const SizedBox(width: IntermediateSpacing.s2xs),
              Text(
                _expanded
                    ? t.intermediate.chat.thinking.collapse
                    : t.intermediate.chat.thinking.expand,
                style: IntermediateTextStyles.caption.copyWith(
                  color: widget.colors.muted,
                ),
              ),
            ],
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: IntermediateSpacing.sXs),
          Text(
            widget.content,
            style: IntermediateTextStyles.narrativeQuote.copyWith(
              color: widget.colors.muted,
              fontSize: 14,
            ),
          ),
        ],
      ],
    );
  }
}
