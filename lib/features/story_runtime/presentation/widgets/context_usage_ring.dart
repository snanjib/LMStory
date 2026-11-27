import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lmstory/core/llm/llm_usage.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/shared/components/streaming_fade_text.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/utils/token_format.dart' as token_format;
import 'package:lmstory/i18n/strings.g.dart';

/// 上下文用量环形指示器（上下文用量指示设计 §4.1， 自导演泛化下沉）。
///
/// 故事/导演两模式共用（story_runtime）：sweep = numerator / denominator，
/// 满刻度 = 压缩触发线（不是窗口）。状态色即无文字告警通道：常态 muted、
/// ≥70% warning、≥100% error、无数据空轨道。交互（点击/Tooltip/hover 着装）
/// 在 [ContextUsageChip]。
class ContextUsageRing extends StatelessWidget {
  const ContextUsageRing({
    required this.numerator,
    required this.denominator,
    this.size = 16,
    this.strokeWidth = 2,
    super.key,
  });

  /// 最近一次主请求 promptTokens（null = 无数据：旧会话未回填/端点无 usage）
  final int? numerator;

  /// 压缩触发线 token（contextWindow × compactionTriggerRatio）
  final int? denominator;

  /// 环外沿边长（px）
  final double size;

  /// 环线宽（px）
  final double strokeWidth;

  /// 进度语义色（环与详情面板用量条共用）：常态 muted、≥70% warning、
  /// ≥100% error。入参一律「相对压缩触发线」的比值（满刻度口径与环一致）。
  static Color semanticColorFor(
    LmPalette colors,
    double ratioToTrigger,
  ) {
    if (ratioToTrigger >= 1.0) return colors.error;
    if (ratioToTrigger >= 0.7) return colors.warning;
    return colors.muted;
  }

  @visibleForTesting
  Color progressColorFor(LmPalette colors) {
    final total = denominator ?? 0;
    final hasData = numerator != null && total > 0;
    if (!hasData) return colors.divider;
    return semanticColorFor(colors, (numerator! / total).clamp(0.0, 1.0));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final total = denominator ?? 0;
    final hasData = numerator != null && total > 0;
    final ratio = hasData ? (numerator! / total).clamp(0.0, 1.0) : 0.0;

    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _RingPainter(
          ratio: ratio,
          hasData: hasData,
          trackColor: colors.divider,
          progressColor: progressColorFor(colors),
          strokeWidth: strokeWidth,
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.ratio,
    required this.hasData,
    required this.trackColor,
    required this.progressColor,
    required this.strokeWidth,
  });

  final double ratio;
  final bool hasData;
  final Color trackColor;
  final Color progressColor;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) - strokeWidth) / 2;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..color = trackColor,
    );
    if (!hasData || ratio <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * ratio,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..color = progressColor,
    );
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.ratio != ratio ||
      oldDelegate.hasData != hasData ||
      oldDelegate.progressColor != progressColor ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.strokeWidth != strokeWidth;
}

/// 圆环的 chip 外衣（长会话退化治理 ：圆环重嵌入输入区工具栏）。
///
/// 与工具栏 `_ToolbarButton` 同语言：rSm 圆角 + 0.5px divider 描边 +
/// hover primaryDim 背景，纯环无文字。
/// 命中区 ≥32px（PRODUCT.md 触达标准），Tooltip 补充语义。
/// 环从 16px 放大到 20px（可发现性），其余语言不变。
class ContextUsageChip extends StatefulWidget {
  const ContextUsageChip({
    required this.numerator,
    required this.denominator,
    this.onTap,
    super.key,
  });

  /// 最近一次主请求 promptTokens（null = 无数据：旧会话未回填/端点无 usage）
  final int? numerator;

  /// 压缩触发线 token（contextWindow × compactionTriggerRatio）
  final int? denominator;

  final VoidCallback? onTap;

  @override
  State<ContextUsageChip> createState() => _ContextUsageChipState();
}

class _ContextUsageChipState extends State<ContextUsageChip> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final isEnabled = widget.onTap != null;

    return Tooltip(
      message: Translations.of(context).common.contextRing.ringTooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
          child: AnimatedContainer(
            duration: LmMotion.micro,
            constraints: const BoxConstraints(minHeight: 32),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(
              horizontal: IntermediateSpacing.sSm,
            ),
            decoration: BoxDecoration(
              color: _isHovered && isEnabled
                  ? colors.primaryDim
                  : Colors.transparent,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
              border: Border.all(
                color: _isHovered && isEnabled
                    ? colors.primary.withValues(alpha: 0.3)
                    : colors.divider,
                width: 0.5,
              ),
            ),
            child: ContextUsageRing(
              // 默认 16px 在 32px 命中区里过小难发现，
              // 放大到 20px/2.5px 线宽
              size: 20,
              strokeWidth: 2.5,
              numerator: widget.numerator,
              denominator: widget.denominator,
            ),
          ),
        ),
      ),
    );
  }
}

/// 上下文构成单段（详情面板构成区数据）
///
/// 纯展示值对象：[fraction] 为该段字符占比（0–1），[tokens] 为按最近一次
/// 请求 promptTokens 拆分的估算值（null=无请求数据，仅展示占比）。
class ContextCompositionSegment {
  const ContextCompositionSegment({
    required this.label,
    required this.fraction,
    this.tokens,
  });

  final String label;
  final double fraction;
  final int? tokens;
}

/// 详情面板（设计 §4.1 sheet + §4.3 手动压缩，故事/导演共用）。
///
/// 纯展示组件：字段由各模式页面从 provider state 组装传入，手动压缩
/// 动作回调到各控制器的 `manualCompact()`。压缩流式过程通过
/// [manualCompactionDelta] 在带标注的固定高滚动区原位渲染（Riverpod
/// watch 驱动刷新）。
///
/// 2026-09-04 面板重排（用户反馈两则）：token 数弃「万」改通用 k/M
/// 格式并显式标注 tokens 单位；统计信息改分区键值行扫读（标签左、
/// 数值右），替代整句混排。流式摘要区固定高度 + 整面超高可滚动
/// 布局不再被流式追加挤压。
///
/// 可选 [composition]（导演侧装配期埋点）在面板增加「上下文构成」
/// 区——堆叠条 + 各段 token/占比键值行（估算口径，面板内标注）。
class ContextUsageDetailSheet extends StatefulWidget {
  const ContextUsageDetailSheet({
    required this.contextWindowTokens,
    required this.compactionTriggerTokens,
    required this.lastPromptTokens,
    required this.lastCompletionTokens,
    required this.lastCacheReadTokens,
    required this.averageCacheHit,
    required this.sessionRounds,
    required this.isManualCompacting,
    required this.manualCompactionDelta,
    required this.manualCompactionError,
    required this.isRoundActive,
    required this.onManualCompact,
    this.composition,
    this.compositionNote,
    this.isEstimated = false,
    this.currentEstimateTokens,
    this.currentEstimateIsLocal,
    this.lastRequestInputTokens,
    this.requestInputIsComplete = false,
    this.lastRequestAt,
    this.cacheCoveredRounds,
    this.lastCacheHitRatio,
    this.lastCacheSampleInvalid = false,
    super.key,
  });

  final int? contextWindowTokens;
  final int? compactionTriggerTokens;
  final int? lastPromptTokens;
  final int? lastCompletionTokens;
  final int? lastCacheReadTokens;
  final double? averageCacheHit;
  final int sessionRounds;

  /// 当前预计上下文（hero/进度条主数字）。null = 沿用 [lastPromptTokens]
  ///（向后兼容旧调用点/测试），调用方应尽量显式传入。
  final int? currentEstimateTokens;

  /// 主数字是否为本地估算（压缩/删除后调整值，UI 显示 ≈）
  final bool? currentEstimateIsLocal;

  /// 最近一次主请求的完整输入 token（命中率分母/「最近请求」区）
  ///
  /// null = 旧调用方未拆分口径，回退 [lastPromptTokens]（旧公式保持）。
  final int? lastRequestInputTokens;

  /// [lastRequestInputTokens] 是否为协议无关的完整输入面（新调用点）。
  ///
  /// true 时 null 表示「本次请求完整输入未知」——显示「—」，不得回退
  /// 协议原生 prompt（Anthropic 的 prompt 不含 cache read/creation，
  /// 会把命中率算成几百个百分点）。
  final bool requestInputIsComplete;

  /// 最近请求的发生时刻（口径脚注展示；未知为 null）
  final DateTime? lastRequestAt;

  /// 命中率累计覆盖的轮数（只统计可比样本；null = 不展示覆盖行）
  final int? cacheCoveredRounds;

  /// 已校验的最近请求命中率（异常/不可比时为 null）。
  ///
  /// 由调用方用 `LlmUsage.hitRateOf` 等统一校验后传入；面板不再自行
  /// 用原始分项直接相除，避免越界/冲突样本被展示成 120% 等精确假象。
  final double? lastCacheHitRatio;

  /// 最近请求分项是否因冲突/越界等异常不可比较（true → 命中率显示「—」
  /// 并附计量异常说明）。
  final bool lastCacheSampleInvalid;
  final bool isManualCompacting;
  final String manualCompactionDelta;
  final String? manualCompactionError;

  /// 生成/自动压缩轮进行中（：按钮与手动压缩互斥置灰）
  final bool isRoundActive;

  final VoidCallback onManualCompact;

  /// 最近一轮分项是否为本地估算兜底（端点未回 usage 时由各模式控制器
  /// 用 tiktoken 估算 prompt/completion 写入）。true 时 hero 与
  /// 输入/输出行加「≈」前缀，面板底部显示口径脚注；缓存分项本地
  /// 不可估算，恒为端点真实数据或「—」。
  final bool isEstimated;

  /// 上下文构成段（null = 未装配，不渲染构成区）
  final List<ContextCompositionSegment>? composition;

  /// 构成估算口径说明（调用方注入本地化文案）
  final String? compositionNote;

  /// token 数通用格式（收敛）：实现移至
  /// core/utils/token_format.dart 全仓唯一入口，此处保留静态别名
  ///（既有测试与既有调用点不改）。
  @visibleForTesting
  static String formatTokenCount(int tokens) =>
      token_format.formatTokenCount(tokens);

  @override
  State<ContextUsageDetailSheet> createState() =>
      _ContextUsageDetailSheetState();
}

class _ContextUsageDetailSheetState extends State<ContextUsageDetailSheet> {
  final ScrollController _deltaScrollController = ScrollController();

  @override
  void didUpdateWidget(ContextUsageDetailSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 流式追加时钉住底部：等新内容布局完成再跳到最新一行。
    if (widget.manualCompactionDelta.length >
        oldWidget.manualCompactionDelta.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_deltaScrollController.hasClients) return;
        _deltaScrollController
            .jumpTo(_deltaScrollController.position.maxScrollExtent);
      });
    }
  }

  @override
  void dispose() {
    _deltaScrollController.dispose();
    super.dispose();
  }

  String _formatRatio(double? ratio) =>
      ratio == null ? '—' : '${(ratio * 100).toStringAsFixed(1)}%';

  String _tokenLabel(int? tokens, Translations t, {bool estimated = false}) =>
      tokens == null
          ? t.common.contextRing.noData
          : estimated
              ? t.common.contextRing.estTokenCount(
                  count: ContextUsageDetailSheet.formatTokenCount(tokens),
                )
              : t.common.contextRing.tokenCount(
                  count: ContextUsageDetailSheet.formatTokenCount(tokens),
                );

  /// 「—」/「≈」口径脚注显隐：分项缺失（端点未回 usage/端点不提供
  /// 缓存统计）或展示的是本地估算值时显示，消除「面板是不是坏了」
  /// 的误读（内测反馈：全「—」以为模型不支持）。
  bool get _showUsageNote =>
      widget.isEstimated ||
      _estimateIsLocal ||
      widget.lastCompletionTokens == null ||
      widget.lastCacheReadTokens == null;

  /// 主数字：当前预计上下文
  ///
  /// 显式传了 [ContextUsageDetailSheet.currentEstimateIsLocal]（新调用点）
  /// 时按原值展示，null 即无数据；旧调用点未拆分口径才回退 lastPromptTokens。
  int? get _estimateTokens {
    if (widget.currentEstimateIsLocal != null) {
      return widget.currentEstimateTokens;
    }
    return widget.currentEstimateTokens ?? widget.lastPromptTokens;
  }

  /// 主数字是否为本地估算
  bool get _estimateIsLocal =>
      widget.currentEstimateIsLocal ?? widget.isEstimated;

  /// 最近请求实际输入（命中率分母）
  ///
  /// 新调用点（requestInputIsComplete）只认 lastRequestInputTokens，
  /// 缺失即 null；旧调用点保留 prompt 回退。
  int? get _lastRequestInput => widget.requestInputIsComplete
      ? widget.lastRequestInputTokens
      : widget.lastRequestInputTokens ?? widget.lastPromptTokens;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final hasUsage = _estimateTokens != null &&
        widget.contextWindowTokens != null &&
        widget.contextWindowTokens! > 0;

    return SafeArea(
      child: ConstrainedBox(
        // 整面超高可滚动（isScrollControlled 由调用方开启）：流式摘要区
        // 出现时内容可超出一屏，Column 必须有滚动兜底（并入 ）。
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.9,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              IntermediateSpacing.sLg,
              IntermediateSpacing.sSm,
              IntermediateSpacing.sLg,
              IntermediateSpacing.sLg,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // handle bar（sheet 抓手，对齐 director_session_settings_sheet）
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: colors.divider,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: IntermediateSpacing.sMd),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        t.common.contextRing.title,
                        style: IntermediateTextStyles.title,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      color: colors.muted,
                      tooltip: t.common.close,
                      onPressed: () => Navigator.of(context).pop(),
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 32,
                        minHeight: 32,
                      ),
                      padding: EdgeInsets.zero,
                    ),
                  ],
                ),
                const SizedBox(height: IntermediateSpacing.sLg),
                if (widget.currentEstimateTokens != null) ...[
                  Text(
                    t.common.contextRing.currentEstimateLabel,
                    style: IntermediateTextStyles.caption
                        .copyWith(color: colors.muted),
                  ),
                  const SizedBox(height: IntermediateSpacing.s2xs),
                ],
                _buildUsageHero(colors, t, hasUsage: hasUsage),
                const SizedBox(height: IntermediateSpacing.sSm),
                _buildUsageBar(colors),
                if (widget.compactionTriggerTokens != null &&
                    widget.compactionTriggerTokens! > 0) ...[
                  const SizedBox(height: IntermediateSpacing.sSm),
                  Text(
                    t.common.contextRing.triggerLine(
                      tokens: _tokenLabel(widget.compactionTriggerTokens, t),
                    ),
                    style: IntermediateTextStyles.caption
                        .copyWith(color: colors.muted),
                  ),
                ],
                const SizedBox(height: IntermediateSpacing.sLg),
                if (widget.composition != null &&
                    widget.composition!.isNotEmpty) ...[
                  _buildCompositionSection(colors, t),
                  const SizedBox(height: IntermediateSpacing.sLg),
                ],
                _buildCacheSection(colors, t),
                const SizedBox(height: IntermediateSpacing.sLg),
                _buildLastRequestSection(colors, t),
                const SizedBox(height: IntermediateSpacing.sLg),
                _buildSessionSection(colors, t),
                if (_showUsageNote) ...[
                  const SizedBox(height: IntermediateSpacing.sXs),
                  Text(
                    t.common.contextRing.usageNote,
                    style: IntermediateTextStyles.caption.copyWith(
                      color: colors.faint,
                    ),
                  ),
                ],
                if (widget.isManualCompacting) ...[
                  const SizedBox(height: IntermediateSpacing.sLg),
                  _buildStreamingBlock(colors, t),
                ],
                if (widget.manualCompactionError != null) ...[
                  const SizedBox(height: IntermediateSpacing.sXs),
                  Text(
                    t.common.contextRing.compactFailed(
                      error: widget.manualCompactionError!,
                    ),
                    style: IntermediateTextStyles.caption
                        .copyWith(color: colors.error),
                  ),
                ],
                const SizedBox(height: IntermediateSpacing.sLg),
                FilledButton(
                  // 手动压缩中或轮进行中都置灰；失败态文案换「重试」
                  onPressed: (widget.isManualCompacting || widget.isRoundActive)
                      ? null
                      : widget.onManualCompact,
                  child: Text(
                    widget.isManualCompacting
                        ? t.common.contextRing.compactRunning
                        : widget.manualCompactionError != null
                            ? t.common.retry
                            : t.common.contextRing.compactNow,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── 用量主区：一行分数+占比，下方进度条（触发线位置打刻度）────────

  Widget _buildUsageHero(
    LmPalette colors,
    Translations t, {
    required bool hasUsage,
  }) {
    if (!hasUsage) {
      return Text(
        t.common.contextRing.noData,
        style: IntermediateTextStyles.title.copyWith(color: colors.muted),
      );
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Expanded(
          child: Text(
            '${_estimateIsLocal ? '≈ ' : ''}'
            '${t.common.contextRing.usageFraction(
              used: ContextUsageDetailSheet.formatTokenCount(
                _estimateTokens!,
              ),
              total: ContextUsageDetailSheet.formatTokenCount(
                widget.contextWindowTokens!,
              ),
            )}',
            style: _valueStyle().copyWith(
              fontSize: IntermediateTextStyles.title.fontSize,
              fontWeight: IntermediateTextStyles.title.fontWeight,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: IntermediateSpacing.sMd),
        Text(
          '${_estimateIsLocal ? '≈' : ''}'
          '${(_estimateTokens! / widget.contextWindowTokens! * 100).toStringAsFixed(1)}%',
          style: _valueStyle().copyWith(
            fontSize: IntermediateTextStyles.title.fontSize,
            fontWeight: IntermediateTextStyles.title.fontWeight,
          ),
        ),
      ],
    );
  }

  Widget _buildUsageBar(LmPalette colors) {
    final window = widget.contextWindowTokens ?? 0;
    final used = _estimateTokens;
    if (window <= 0 || used == null) return const SizedBox.shrink();
    final fillFraction = (used / window).clamp(0.0, 1.0);
    final trigger = widget.compactionTriggerTokens;
    // 颜色语义沿用环形指示器口径：比值相对压缩触发线（非窗口）。
    final ratioToTrigger = trigger != null && trigger > 0
        ? (used / trigger).clamp(0.0, 1.0)
        : fillFraction;
    final tickFraction = trigger != null && trigger > 0
        ? (trigger / window).clamp(0.0, 1.0)
        : null;

    return LayoutBuilder(
      builder: (context, constraints) => ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: SizedBox(
          height: 6,
          child: Stack(
            children: [
              Positioned.fill(
                child: ColoredBox(color: colors.divider),
              ),
              Positioned.fill(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: fillFraction,
                    child: ColoredBox(
                      color: ContextUsageRing.semanticColorFor(
                        colors,
                        ratioToTrigger,
                      ),
                    ),
                  ),
                ),
              ),
              if (tickFraction != null && tickFraction > 0)
                Positioned(
                  left: math.max(0, constraints.maxWidth * tickFraction - 1),
                  top: 0,
                  bottom: 0,
                  width: 2,
                  child: ColoredBox(color: colors.bg),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 分区键值行（标签左、数值右，等宽数字纵向对齐）─────────────────

  TextStyle _valueStyle() => IntermediateTextStyles.bodyUi.copyWith(
        fontWeight: FontWeight.w500,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  Widget _sectionHeader(String text, LmPalette colors) => Text(
        text,
        style: IntermediateTextStyles.label.copyWith(color: colors.ink),
      );

  Widget _kvRow(String label, String value, LmPalette colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: IntermediateSpacing.s2xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: IntermediateTextStyles.bodyUi.copyWith(
                color: colors.muted,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: IntermediateSpacing.sMd),
          Text(
            value,
            style: _valueStyle(),
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  /// 上下文构成区——堆叠条 + 各段键值行（估算口径随注）
  Widget _buildCompositionSection(
    LmPalette colors,
    Translations t,
  ) {
    final segments = widget.composition!;
    final palette = [
      colors.primary,
      colors.accent,
      colors.success,
      colors.warning,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(t.common.contextRing.compositionTitle, colors),
        const SizedBox(height: IntermediateSpacing.sXs),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            height: 6,
            child: Row(
              children: [
                for (var i = 0; i < segments.length; i++)
                  Expanded(
                    flex: math.max(
                      1,
                      (segments[i].fraction * 1000).round(),
                    ),
                    child: ColoredBox(
                      color: palette[i % palette.length].withValues(
                        alpha: 0.85,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: IntermediateSpacing.sXs),
        for (var i = 0; i < segments.length; i++)
          _kvRow(
            '${segments[i].label}'
            '（${(segments[i].fraction * 100).toStringAsFixed(0)}%）',
            segments[i].tokens == null
                ? '—'
                : t.common.contextRing.tokenCount(
                    count: ContextUsageDetailSheet.formatTokenCount(
                      segments[i].tokens!,
                    ),
                  ),
            colors,
          ),
        if (widget.compositionNote != null)
          Text(
            widget.compositionNote!,
            style: IntermediateTextStyles.caption.copyWith(
              color: colors.faint,
            ),
          ),
      ],
    );
  }

  Widget _buildCacheSection(LmPalette colors, Translations t) {
    final lastPrompt = widget.lastPromptTokens;
    final input = widget.requestInputIsComplete
        ? widget.lastRequestInputTokens
        : widget.lastRequestInputTokens ?? widget.lastPromptTokens;
    final legacyDenominator =
        !widget.requestInputIsComplete && widget.lastRequestInputTokens == null;
    // 命中率只消费已校验结果：异常样本（冲突/越界）显示未知；新调用点
    // 优先用调用方传入的校验值，旧调用点保留 C/(C+P) 兼容。
    final double? lastHitRatio;
    if (widget.lastCacheSampleInvalid) {
      lastHitRatio = null;
    } else if (legacyDenominator) {
      final cacheRead = widget.lastCacheReadTokens;
      final denominator =
          cacheRead == null || lastPrompt == null ? 0 : cacheRead + lastPrompt;
      lastHitRatio =
          cacheRead != null && denominator > 0 ? cacheRead / denominator : null;
    } else {
      lastHitRatio = widget.lastCacheHitRatio ??
          LlmUsage.hitRateOf(
            cacheReadTokens: widget.lastCacheReadTokens,
            inputTokens: input,
          );
    }
    // 未显式标注异常时，按原始分项是否被校验公式拒绝推导：
    // 有缓存读取、有分母、却算不出合法比例 → 不可比较。
    final sampleInvalid = widget.lastCacheSampleInvalid ||
        (!legacyDenominator &&
            widget.lastCacheReadTokens != null &&
            input != null &&
            lastHitRatio == null);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(t.common.contextRing.cacheTitle, colors),
        const SizedBox(height: IntermediateSpacing.sXs),
        _kvRow(
          t.common.contextRing.cacheHitLast,
          _formatRatio(lastHitRatio),
          colors,
        ),
        _kvRow(
          t.common.contextRing.cacheHitAverage,
          _formatRatio(widget.averageCacheHit),
          colors,
        ),
        if (widget.cacheCoveredRounds != null)
          _kvRow(
            t.common.contextRing.cacheCoverageLabel,
            t.common.contextRing.cacheCoverageValue(
              count: '${widget.cacheCoveredRounds}',
            ),
            colors,
          ),
        if (sampleInvalid)
          Padding(
            padding: const EdgeInsets.only(top: IntermediateSpacing.sXs),
            child: Text(
              t.common.contextRing.cacheSampleInvalid,
              style: IntermediateTextStyles.caption.copyWith(
                color: colors.faint,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildLastRequestSection(LmPalette colors, Translations t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(t.common.contextRing.lastRequestTitle, colors),
        const SizedBox(height: IntermediateSpacing.sXs),
        _kvRow(
          t.common.contextRing.inputLabel,
          // 估算兜底时输入/输出行同加「≈」前缀；缓存读取本地不可估算
          _tokenLabel(
            _lastRequestInput,
            t,
            estimated: widget.isEstimated,
          ),
          colors,
        ),
        _kvRow(
          t.common.contextRing.outputLabel,
          _tokenLabel(
            widget.lastCompletionTokens,
            t,
            estimated: widget.isEstimated,
          ),
          colors,
        ),
        _kvRow(
          t.common.contextRing.cacheReadLabel,
          _tokenLabel(widget.lastCacheReadTokens, t),
          colors,
        ),
        if (widget.lastRequestAt != null)
          _kvRow(
            t.common.contextRing.updatedAtLabel,
            MaterialLocalizations.of(context).formatTimeOfDay(
              TimeOfDay.fromDateTime(widget.lastRequestAt!.toLocal()),
            ),
            colors,
          ),
      ],
    );
  }

  Widget _buildSessionSection(LmPalette colors, Translations t) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(t.common.contextRing.sessionTitle, colors),
        const SizedBox(height: IntermediateSpacing.sXs),
        _kvRow(
          t.common.contextRing.roundsRowLabel,
          '${widget.sessionRounds}',
          colors,
        ),
      ],
    );
  }

  // ── 手动压缩流式区：带标注 + 固定高滚动，按钮位置不随流式追加跳动 ──

  Widget _buildStreamingBlock(LmPalette colors, Translations t) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(IntermediateSpacing.sMd),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.primary,
                ),
              ),
              const SizedBox(width: IntermediateSpacing.sSm),
              Expanded(
                child: Text(
                  // 标注正在生成的是前情摘要——流式文本读起来像正文，
                  // 无标注时用户会误以为是剧情生成（用户反馈原文）。
                  t.common.contextRing.compactStreamingTitle,
                  style: IntermediateTextStyles.label.copyWith(
                    color: colors.muted,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: IntermediateSpacing.sSm),
          SizedBox(
            height: 96,
            width: double.infinity,
            child: SingleChildScrollView(
              controller: _deltaScrollController,
              // （R1）：压缩摘要流式增长文本接共享淡入载体
              // pace：直连载体的流式面自行配速。
              child: StreamingFadeText(
                data: widget.manualCompactionDelta,
                pace: true,
                style: IntermediateTextStyles.caption.copyWith(
                  color: colors.muted,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
