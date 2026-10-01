import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/components/history_panel_shell.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/story_runtime/domain/entities/classified_keywords.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 关键词提取小窗（DOC-06B §6.2A，V2 四步重构）。
///
/// 状态映射：
/// - extracting：surfaceElevated 底 + "提取关键词中..."（结构化步骤无流式）
/// - 完成：先展开 [foldDelayMs] 毫秒展示关键词列表（entities/events 分组），
///   然后自动折叠为单行 "▸ 关键词：N 个"；用户点击可重新展开/折叠
/// - 失败：AnimatedOpacity + 灰度滤镜过渡到 0.4（300ms ease-out，DOC-06B §5.3）
/// - 历史态（[artifacts] != null）：用 [HistoryPanelShell] 渲染，默认折叠、
///   muted 箭头、入场淡入、无自动折叠定时器、无失败态
///
/// 与 GeneratePanel 同级样式（surfaceElevated 底、rMd 圆角、muted 箭头），
/// 保持小窗系列一致性。结构化步骤无流式显示（解析完成后一次性更新 state）。
///
/// compact 降级场景：当 keywords 为空时，ExtractPanel 显示 "▸ 关键词：0 个"。
///
/// 统一组件（避免"四合二"闪动）：本组件同时承载"生成中"和"完成后"两种态，
/// 通过 [artifacts] 参数切换数据源。历史态从 `artifacts.extractedKeywords` 读取
/// 扁平化关键词列表（历史快照不保留 entities/events 分类，统一以标签展示）。
class ExtractPanel extends StatefulWidget {
  const ExtractPanel({
    required this.phase,
    required this.keywords,
    required this.failureContext,
    this.foldDelayMs = 1000,
    this.artifacts,
    super.key,
  });

  final IntermediatePhase phase;
  final ClassifiedKeywords? keywords;
  final FailureContext? failureContext;

  /// 自动折叠延迟（毫秒）。复用 StreamConfig.retrievalFoldDelayMs
  /// （结构化步骤与检索小窗共用折叠时序）。
  final int foldDelayMs;

  /// 历史快照（非 null 时进入历史态渲染）。
  ///
  /// 完成后的轮次通过此参数传入持久化的 [StoryRoundArtifacts]，
  /// 组件从 `artifacts.extractedKeywords` 读取扁平化关键词列表。
  /// 历史态忽略 [phase]/[keywords]/[failureContext]。
  final StoryRoundArtifacts? artifacts;

  @override
  State<ExtractPanel> createState() => _ExtractPanelState();
}

class _ExtractPanelState extends State<ExtractPanel> {
  bool _expanded = false;
  Timer? _autoFoldTimer;

  /// 是否已完成自动折叠（用户已交互或定时器已触发，之后不再自动折叠）
  bool _hasAutoFolded = false;

  /// 可见时延迟折叠的已重试次数（2026-07-16 修复问题3）
  int _foldRetryCount = 0;
  static const int _maxFoldRetries = 2;

  /// 是否已渲染过实时态（非历史态）。
  /// 用于检测从实时态切换到历史态时跳过 HistoryPanelShell 的淡入动画（问题1修复）。

  bool get _isExtracting =>
      widget.phase == IntermediatePhase.extracting ||
      widget.phase == IntermediatePhase.extractingRetry;
  bool get _isFailed =>
      widget.phase == IntermediatePhase.failed &&
      widget.failureContext?.failedPhase == IntermediatePhase.extracting;
  bool get _isCompleted =>
      !_isExtracting && !_isFailed && widget.keywords != null;

  @override
  void didUpdateWidget(ExtractPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 新轮次开始：从 idle/failed → extracting，重置自动折叠状态
    // （防御性：统一组件重构后 panel 可能跨轮次复用 State）
    final wasIdleOrFailed = oldWidget.phase == IntermediatePhase.idle ||
        oldWidget.phase == IntermediatePhase.failed;
    if (wasIdleOrFailed && _isExtracting) {
      _hasAutoFolded = false;
      _expanded = false;
      _autoFoldTimer?.cancel();
      _autoFoldTimer = null;
    }
    // 检测从 extracting 转 _isCompleted：进入完成态，启动自动折叠时序
    final wasExtracting = oldWidget.phase == IntermediatePhase.extracting ||
        oldWidget.phase == IntermediatePhase.extractingRetry;
    if (wasExtracting && _isCompleted && !_hasAutoFolded) {
      _expanded = true;
      _foldRetryCount = 0; // 重置可见延迟计数
      _autoFoldTimer?.cancel();
      if (widget.foldDelayMs <= 0) {
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
    return offset.dy < screenHeight && offset.dy + renderObject.size.height > 0;
  }

  void _toggleExpanded() {
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
    final reducedMotion = LmMotion.reducedMotion(context);

    return AnimatedSize(
      duration: reducedMotion ? Duration.zero : LmMotion.base,
      curve: LmMotion.easeBoth,
      child: Container(
        margin: const EdgeInsets.symmetric(
          horizontal: IntermediateSpacing.sLg,
          vertical: IntermediateSpacing.sXs,
        ),
        decoration: BoxDecoration(
          color: colors.surfaceElevated,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        ),
        child: _buildContent(colors, t, reducedMotion),
      ),
    );
  }

  /// 历史态渲染：用 [HistoryPanelShell] 容器 + 关键词标签列表展开内容。
  Widget _buildHistory(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final artifacts = widget.artifacts!;
    final keywords = artifacts.extractedKeywords;
    final summary = t.intermediate.chat.historyExtractingReady(
      turn: artifacts.turnNumber,
      count: keywords.length,
    );

    return HistoryPanelShell(
      key: ValueKey('history-extract-${artifacts.turnNumber}'),
      summary: summary,
      animateEntrance: false,
      expandedContent: keywords.isEmpty
          ? const SizedBox.shrink()
          : Wrap(
              spacing: IntermediateSpacing.sXs,
              runSpacing: IntermediateSpacing.s2xs,
              children: keywords
                  .map(
                    (kw) => Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: IntermediateSpacing.sSm,
                        vertical: IntermediateSpacing.s3xs,
                      ),
                      decoration: BoxDecoration(
                        color: colors.accentDim,
                        borderRadius: BorderRadius.circular(
                          context.lmUi.radius(LmCorner.full),
                        ),
                      ),
                      child: Text(
                        kw,
                        style: IntermediateTextStyles.caption.copyWith(
                          color: colors.accent,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
    );
  }

  Widget _buildContent(
    LmPalette colors,
    Translations t,
    bool reducedMotion,
  ) {
    if (_isExtracting) {
      return _buildExtracting(colors, t);
    }
    if (_isFailed) {
      return _buildFailed(colors, t, reducedMotion);
    }
    if (_isCompleted) {
      return _buildCompleted(colors, t);
    }
    return const SizedBox.shrink();
  }

  /// extracting 阶段：标题 + 加载指示（无流式，结构化步骤）
  Widget _buildExtracting(LmPalette colors, Translations t) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: IntermediateSpacing.sMd,
        vertical: IntermediateSpacing.sSm,
      ),
      child: Row(
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
            t.intermediate.chat.extractingHint,
            style: IntermediateTextStyles.caption.copyWith(
              color: colors.muted,
            ),
          ),
        ],
      ),
    );
  }

  /// 完成态：折叠行（点击展开关键词列表）
  Widget _buildCompleted(LmPalette colors, Translations t) {
    final keywords = widget.keywords ?? const ClassifiedKeywords();
    final summary = t.intermediate.chat.extractingReady(count: keywords.length);

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
                  ),
                ),
              ],
            ),
            if (_expanded && keywords.isNotEmpty) ...[
              const SizedBox(height: IntermediateSpacing.sSm),
              Divider(height: 1, color: colors.divider),
              const SizedBox(height: IntermediateSpacing.sSm),
              _buildKeywordGroups(colors, t, keywords),
            ],
          ],
        ),
      ),
    );
  }

  /// 关键词分组列表（entities / events，琥珀金标注）
  Widget _buildKeywordGroups(
    LmPalette colors,
    Translations t,
    ClassifiedKeywords keywords,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (keywords.entityTerms.isNotEmpty)
          _buildKeywordGroup(colors, t, keywords.entityTerms, isEntities: true),
        if (keywords.entityTerms.isNotEmpty && keywords.eventTerms.isNotEmpty)
          const SizedBox(height: IntermediateSpacing.sSm),
        if (keywords.eventTerms.isNotEmpty)
          _buildKeywordGroup(colors, t, keywords.eventTerms, isEntities: false),
      ],
    );
  }

  Widget _buildKeywordGroup(
    LmPalette colors,
    Translations t,
    List<String> items, {
    required bool isEntities,
  }) {
    return Wrap(
      spacing: IntermediateSpacing.sXs,
      runSpacing: IntermediateSpacing.sXs,
      children: [
        for (final keyword in items)
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: IntermediateSpacing.sSm,
              vertical: IntermediateSpacing.s2xs,
            ),
            decoration: BoxDecoration(
              color: colors.primaryDim,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
            ),
            child: Text(
              keyword,
              style: IntermediateTextStyles.caption.copyWith(
                color: colors.primary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
      ],
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
                  t.intermediate.chat.extractFailed,
                  style: IntermediateTextStyles.caption.copyWith(
                    color: colors.muted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
