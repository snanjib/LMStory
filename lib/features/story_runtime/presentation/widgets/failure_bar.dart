import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/shared/components/lm_arrival.dart';
import 'package:lmstory/core/theme/shared/components/lm_overflow_card.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/utils/secret_redactor.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 失败提示栏（DOC-06B §6.4）。
///
/// 两态展示：
/// - **收起态**：error 图标 + 通俗提示 + 展开箭头(▾) + 重试/清空按钮
/// - **展开态**：AnimatedSize 展开 surfaceElevated 详情区，含错误码/HTTP 状态/
///   失败阶段/错误类型/建议操作/原始异常（monospace + faint，可滚动）
///
/// 动效：200ms easeOutQuart，遵守 reduced-motion（：
/// `disableAnimations` 与 `accessibleNavigation` 任一命中即瞬时切换）
/// （减弱动效时瞬时切换）。
///
/// 视觉：顶部 1px error 分割线（非侧条），详情区 1px divider 分隔。
///
/// 对比度规则（DOC-06B §3.3 I-3）：
/// - 不用 error/0.12 底色（error 文字对比度仅 2.7:1，不达标）
/// - 改用 surface 底 + ink 文字（4.7:1 ✅）+ error 图标传递错误语义
class FailureBar extends StatefulWidget {
  const FailureBar({
    required this.failureContext,
    required this.onRetry,
    required this.onClear,
    // 2026-07-21 新增：E104 embedding 调用失败时显示的"临时降级继续"按钮回调。
    // 仅当 failureContext.errorCode == 'E104' 且非 null 时显示该按钮。
    this.onContinueWithFts5,
    // 2026-07-22 新增：所有失败阶段都显示的"从中断处继续"按钮回调。
    // 保留已完成阶段产出，从失败阶段继续重试（而非从 generating 重做）。
    // null 时不显示该按钮。
    this.onContinueFromFailed,
    // 2026-08-02 修复：由父级（IntermediateChatPage LayoutBuilder）精确计算并传入。
    // 替代原先内部 MediaQuery 估算（用 kToolbarHeight 56px 代替实际 AppBar ~270px，
    // 多算 ~214px 导致溢出）。null 时不限高（键盘未弹出场景）。
    this.maxHeight,
    // 中断正文保留——「以此收稿」回调 + 快照可用性。
    // 仅 generating/reviewing 失败且 partialReplySnapshot 非空时显示；
    // 此时「从中断处继续」按钮文案切换为「续写」（语义=带半截正文续跑）。
    this.onAcceptPartial,
    this.partialReplyAvailable = false,
    super.key,
  });

  /// 失败上下文（含错误码/分类/技术详情）
  final FailureContext failureContext;

  /// 点击"整轮重试"
  final VoidCallback onRetry;

  /// 点击"清空本轮"
  final VoidCallback onClear;

  /// 点击"临时降级继续"（仅 E104 显示，其他错误码传 null 即可）
  ///
  /// 2026-07-21 新增：E104 = embedding 调用失败，用户可选"临时降级为关键词检索"
  /// 继续本轮生成。null 时按钮不显示（其他错误码没有此选项）。
  final VoidCallback? onContinueWithFts5;

  /// 点击"从中断处继续"（所有失败阶段显示）
  ///
  /// 2026-07-22 新增：保留已完成阶段产出（如生成内容），从失败阶段继续重试。
  /// 用户决策：所有失败阶段都显示此按钮（包括 generating 失败，此时等价于整轮重试）。
  /// null 时不显示。
  final VoidCallback? onContinueFromFailed;

  /// FailureBar 最大高度限制（由父级精确计算传入）。
  ///
  /// 2026-08-02 修复：父级 LayoutBuilder 知道底部区域可用高度和其他组件高度，
  /// 能精确计算 FailureBar 可占用的最大高度。替代原先内部 MediaQuery 估算
  /// （用 kToolbarHeight 56px 代替实际 AppBar 高度，多算 ~214px 溢出）。
  /// null 时不限高（键盘未弹出时底部区域有足够空间）。
  final double? maxHeight;

  /// 以未完成正文收稿（replyText=快照直奔收稿链）。
  /// null = 按钮不显示。
  final VoidCallback? onAcceptPartial;

  /// 快照可用（页面从 state.partialReplySnapshot 计算）——true 时显示
  /// 「以此收稿」并把继续按钮文案切为「续写」。
  final bool partialReplyAvailable;

  @override
  State<FailureBar> createState() => _FailureBarState();
}

class _FailureBarState extends State<FailureBar> {
  bool _expanded = false;

  /// 用户手动设置的展开态（2026-08-02 修复：键盘弹出时底部区域溢出）。
  ///
  /// 键盘弹出会压缩可视区域，FailureBar 展开详情（最高 400px+）会挤占
  /// 输入框空间。策略：键盘弹出时强制收起详情让出空间，键盘收起后
  /// 恢复用户之前的选择（想看完整详情时收起键盘即可）。
  bool _userExpanded = false;

  /// 上一帧键盘 inset（用于检测键盘弹出/收起）
  double _lastViewInsets = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final insets = MediaQuery.viewInsetsOf(context).bottom;
    if (insets == _lastViewInsets) return;
    _lastViewInsets = insets;
    final keyboardOpen = insets > 0;
    var changed = false;
    if (keyboardOpen && _expanded) {
      // 键盘弹出：记住用户选择并强制收起，让出空间给输入框
      _userExpanded = true;
      _expanded = false;
      changed = true;
    } else if (!keyboardOpen && _userExpanded) {
      // 键盘收起：恢复用户之前的展开态
      _userExpanded = false;
      _expanded = true;
      changed = true;
    }
    // 2026-08-02 修复 v3：之前漏了 setState()，导致 _expanded 改了但 UI 不重建，
    // 键盘弹出时详情仍然展开，占满高度直接溢出。
    if (changed) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return LmArrival(child: _buildBody(context));
  }

  Widget _buildBody(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final ctx = widget.failureContext;
    // 键盘弹出时动画用 Duration.zero：避免 AnimatedSize 收起动画期间
    // 中间尺寸仍然超出 maxHeight 导致瞬态溢出（bottom overflowed）。
    // accessibleNavigation 时也用 Duration.zero（impeccable: reduced motion）。
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    final duration = (LmMotion.reducedMotion(context) || keyboardOpen)
        ? Duration.zero
        : LmMotion.base;
    const curve = LmMotion.easeSnap;

    // 2026-08-02 修复 v6：重新设计 FailureBar 滚动结构，分而治之。
    // v5 结构：整个 FailureBar 包在 SingleChildScrollView 里 → 标题行+按钮行
    // 和详情区一起滚 → FailureBar 受限时标题/按钮也会被挤到可视区域外，
    // 用户以为"显示不全"。
    // 通常固定标题与按钮；窄高或大字号时整体滚动，保证动作可达。
    // 常规结构：
    // - 外层 Container(maxHeight) → FailureBar 整体限高
    //   - Column(mainAxisSize.min)
    //     - 标题行 + 按钮行 → 始终固定在可视范围内，不参与滚动
    //     - 详情区 → 独立 _DetailArea 包裹：
    //         1) LayoutBuilder 拿到详情区父级给的真实可用高度 remH
    //         2) 当 FailureBar 整体有 maxHeight（非 ∞）时，详情区自身
    //            maxHeight = remH（外层 FailureBar 限高，标题按钮已占空间后剩余）
    //         3) 当 FailureBar 不限高时，详情区也自然高度，不限制
    //         4) 详情区卡片外再套一层 SingleChildScrollView，
    //            当超过 remH 时内部滚动，未超过时不滚。
    final effectiveMaxHeight = widget.maxHeight ?? double.infinity;

    final controls = Padding(
      padding: const EdgeInsets.fromLTRB(
        IntermediateSpacing.sLg,
        IntermediateSpacing.sMd,
        IntermediateSpacing.sLg,
        0,
      ),
      // 固定区域：标题行 + 按钮行 → 永远不滚动，始终可见
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 错误信息行：图标 + 文字 + 展开箭头
          Row(
            children: [
              Icon(Icons.error_outline, size: 20, color: colors.error),
              const SizedBox(width: IntermediateSpacing.sSm),
              Expanded(
                child: Text(
                  ctx.errorMessage,
                  style: IntermediateTextStyles.title.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                onPressed: _copyReport,
                icon: Icon(
                  Icons.copy_outlined,
                  size: 18,
                  color: colors.muted,
                ),
                tooltip: t.intermediate.chat.failure.copyError,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(
                  minWidth: 36,
                  minHeight: 36,
                ),
              ),
              IconButton(
                onPressed: () => setState(() => _expanded = !_expanded),
                icon: AnimatedRotation(
                  turns: _expanded ? 0.5 : 0,
                  duration: duration,
                  curve: curve,
                  child: Icon(
                    Icons.expand_more,
                    size: 20,
                    color: colors.muted,
                  ),
                ),
                tooltip: _expanded
                    ? t.intermediate.chat.failure.collapseDetail
                    : t.intermediate.chat.failure.expandDetail,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(
                  minWidth: 36,
                  minHeight: 36,
                ),
              ),
            ],
          ),
          const SizedBox(height: IntermediateSpacing.sMd),
          // 按钮区：E104 4 按钮时 Wrap 自动换行
          Wrap(
            alignment: WrapAlignment.end,
            spacing: IntermediateSpacing.sSm,
            runSpacing: IntermediateSpacing.sXs,
            children: [
              TextButton(
                onPressed: widget.onClear,
                style: TextButton.styleFrom(
                  foregroundColor: colors.muted,
                  minimumSize: const Size(0, 44),
                  textStyle: IntermediateTextStyles.label,
                ),
                child: Text(
                  t.intermediate.chat.clearRound,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.failureContext.errorCode == 'E104' &&
                  widget.onContinueWithFts5 != null)
                TextButton(
                  onPressed: widget.onContinueWithFts5,
                  style: TextButton.styleFrom(
                    foregroundColor: colors.muted,
                    minimumSize: const Size(0, 44),
                    textStyle: IntermediateTextStyles.label,
                  ),
                  child: Text(
                    t.intermediate.chat.failure.continueWithFts5,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              // 以此收稿（快照非空 + generating/
              // reviewing 失败时由页面判定 partialReplyAvailable）
              if (widget.partialReplyAvailable &&
                  widget.onAcceptPartial != null)
                TextButton(
                  onPressed: widget.onAcceptPartial,
                  style: TextButton.styleFrom(
                    foregroundColor: colors.primary,
                    minimumSize: const Size(0, 44),
                    textStyle: IntermediateTextStyles.label,
                  ),
                  child: Text(
                    t.intermediate.chat.failure.acceptPartial,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              if (widget.onContinueFromFailed != null)
                TextButton(
                  onPressed: widget.onContinueFromFailed,
                  style: TextButton.styleFrom(
                    foregroundColor: colors.ink,
                    minimumSize: const Size(0, 44),
                    textStyle: IntermediateTextStyles.label,
                  ),
                  child: Text(
                    // 快照可用时继续按钮语义升级为「续写」
                    //（带半截正文续跑），否则维持「从中断处继续」
                    widget.partialReplyAvailable
                        ? t.intermediate.chat.failure.continueWriting
                        : t.intermediate.chat.failure.continueFromFailed,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ElevatedButton(
                onPressed: widget.onRetry,
                style: ElevatedButton.styleFrom(
                  backgroundColor: colors.primary,
                  foregroundColor: colors.bg,
                  minimumSize: const Size(0, 44),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(
                      context.lmUi.radius(LmCorner.md),
                    ),
                  ),
                  textStyle: IntermediateTextStyles.label,
                ),
                child: Text(
                  t.intermediate.chat.retryRound,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
      ),
    );

    return Container(
      constraints: BoxConstraints(maxHeight: effectiveMaxHeight),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.error)),
      ),
      child: SafeArea(
        top: false,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final scale = MediaQuery.textScalerOf(context).scale(1);
            final compact = constraints.maxHeight.isFinite &&
                (constraints.maxHeight <
                        LmLayout.failureFixedControlsMinHeight ||
                    (scale > 1.3 &&
                        constraints.maxHeight <
                            LmLayout.failureLargeTextMinHeight));
            if (compact) {
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    controls,
                    _buildDetailArea(
                      colors,
                      t,
                      ctx,
                      duration,
                      curve,
                      double.infinity,
                    ),
                    const SizedBox(height: IntermediateSpacing.sMd),
                  ],
                ),
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                controls,
                // 详情区：独立约束高度，超出时自身滚动。
                // 用 LayoutBuilder 拿到 FailureBar 限高后的剩余空间。
                Flexible(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      // 剩余可用高度（标题按钮已占后，FailureBar maxHeight
                      // 还剩多少空间给详情）。
                      // 当 FailureBar 不限高（effectiveMaxHeight == ∞）时，
                      // 这里 maxHeight 也会很大 → 详情区不限制，按自然高度。
                      final detailMax = constraints.maxHeight;

                      return _buildDetailArea(
                        colors,
                        t,
                        ctx,
                        duration,
                        curve,
                        detailMax,
                      );
                    },
                  ),
                ),
                // 底部留白，避免详情紧贴 FailureBar 下边缘
                const SizedBox(height: IntermediateSpacing.sMd),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 构建详情区域。
  ///
  /// 正常模式：用 AnimatedSize 动画展开/收起。
  /// 减弱动效模式（duration == Duration.zero）：跳过 AnimatedSize 直接渲染，
  /// 避免 RenderAnimatedSize 在 performLayout 中自我标脏抛异常。
  ///
  /// 2026-08-02 v6：新增 [detailMaxHeight] 参数（来自外层 LayoutBuilder）。
  /// - 当 FailureBar 被外层限制了 maxHeight 时（如键盘弹出场景），
  ///   详情区高度被限制为 detailMaxHeight，超出时内部 SingleChildScrollView 滚动。
  /// - 当 FailureBar 不限高时（detailMaxHeight 接近 ∞），详情区按自然高度，
  ///   外层底部区 SingleChildScrollView 作为终极兜底滚动。
  Widget _buildDetailArea(
    LmPalette colors,
    Translations t,
    FailureContext ctx,
    Duration duration,
    Curve curve,
    double detailMaxHeight,
  ) {
    Widget child;
    if (!_expanded) {
      child = const SizedBox.shrink();
    } else {
      // 限高滚动区补底部渐隐（内测反馈"看不出能下滑"）；
      // 渐隐色取详情面板 surfaceElevated 底色
      child = LmOverflowCard(
        maxHeight: detailMaxHeight,
        padding: EdgeInsets.zero,
        fadeColor: colors.surfaceElevated,
        child: _buildDetailPanel(colors, t, ctx),
      );
    }
    if (duration == Duration.zero) {
      return child;
    }
    return AnimatedSize(
      duration: duration,
      curve: curve,
      alignment: Alignment.topCenter,
      child: child,
    );
  }

  /// 展开态技术详情面板（surfaceElevated 底色 + 顶部 1px divider 分隔）
  Widget _buildDetailPanel(
    LmPalette colors,
    Translations t,
    FailureContext ctx,
  ) {
    return Padding(
      padding: const EdgeInsets.only(top: IntermediateSpacing.sMd),
      child: Container(
        decoration: BoxDecoration(
          color: colors.surfaceElevated,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
          border: Border(top: BorderSide(color: colors.divider)),
        ),
        padding: const EdgeInsets.all(IntermediateSpacing.sMd),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _DetailSectionTitle(
              text: t.intermediate.chat.failure.technicalDetail,
              colors: colors,
            ),
            const SizedBox(height: IntermediateSpacing.sSm),
            _DetailRow(
              label: t.intermediate.chat.failure.detailLabels.code,
              value: ctx.errorCode,
              colors: colors,
            ),
            if (ctx.httpStatus != null)
              _DetailRow(
                label: t.intermediate.chat.failure.detailLabels.httpStatus,
                value: ctx.httpStatus.toString(),
                colors: colors,
              ),
            _DetailRow(
              label: t.intermediate.chat.failure.detailLabels.failedPhase,
              value: _resolvePhaseLabel(t, ctx.failedPhase),
              colors: colors,
            ),
            _DetailRow(
              label: t.intermediate.chat.failure.detailLabels.errorCategory,
              value: _resolveCategoryLabel(t, ctx.errorCategory),
              colors: colors,
            ),
            const SizedBox(height: IntermediateSpacing.sSm),
            Divider(height: 1, thickness: 1, color: colors.divider),
            const SizedBox(height: IntermediateSpacing.sSm),
            _DetailSectionTitle(
              text: t.intermediate.chat.failure.suggestedAction,
              colors: colors,
            ),
            const SizedBox(height: IntermediateSpacing.s2xs),
            Text(
              _resolveSuggestion(t, ctx.errorCategory),
              style: IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
            if (ctx.rawError != null) ...[
              const SizedBox(height: IntermediateSpacing.sSm),
              Divider(height: 1, thickness: 1, color: colors.divider),
              const SizedBox(height: IntermediateSpacing.sSm),
              _DetailSectionTitle(
                text: t.intermediate.chat.failure.detailLabels.rawError,
                colors: colors,
              ),
              const SizedBox(height: IntermediateSpacing.s2xs),
              // monospace + faint，可滚动（限制最大高度避免过长异常撑爆面板；
              // 底部渐隐提示可滚）
              LmOverflowCard(
                maxHeight: 120,
                padding: EdgeInsets.zero,
                fadeColor: colors.surfaceElevated,
                child: SelectableText(
                  ctx.rawError!,
                  style: TextStyle(
                    fontFamily: 'LMMono',
                    fontSize: 12,
                    height: 1.4,
                    color: colors.faint,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 一键复制完整故障报告（对齐详情面板字段，含原始异常全文——
  /// 详情面板里 rawError 有 120px 高度限制，复制的是不截断版本）
  void _copyReport() {
    final t = Translations.of(context);
    final ctx = widget.failureContext;
    final labels = t.intermediate.chat.failure.detailLabels;
    final buffer = StringBuffer('[${t.intermediate.chat.failure.reportHeader}]')
      ..write('\n${labels.code}: ${ctx.errorCode}');
    if (ctx.httpStatus != null) {
      buffer.write('\n${labels.httpStatus}: ${ctx.httpStatus}');
    }
    buffer
      ..write(
        '\n${labels.failedPhase}: ${_resolvePhaseLabel(t, ctx.failedPhase)}',
      )
      ..write(
        '\n${labels.errorCategory}: ${_resolveCategoryLabel(t, ctx.errorCategory)}',
      )
      ..write('\n${labels.message}: ${ctx.errorMessage}');
    final raw = ctx.rawError;
    if (raw != null && raw.isNotEmpty) {
      buffer.write('\n${labels.rawError}: $raw');
    }
    // 脱敏后再入剪贴板：rawError 可能含 API Key/Bearer 令牌等凭据
    Clipboard.setData(ClipboardData(text: redactSecrets(buffer.toString())));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(t.intermediate.chat.failure.copySuccess),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String _resolveSuggestion(Translations t, ErrorCategory category) {
    // 报点级建议覆盖优先（如导演主模型未配置需要
    // 指向导演设置的具体入口，通用 config 建议不足以定位）
    final override = widget.failureContext.suggestionOverride;
    if (override != null && override.isNotEmpty) {
      return override;
    }
    final actions = t.intermediate.chat.failure.suggestedActions;
    switch (category) {
      case ErrorCategory.config:
        return actions.config;
      case ErrorCategory.network:
        return actions.network;
      case ErrorCategory.auth:
        return actions.auth;
      case ErrorCategory.rateLimit:
        return actions.rateLimit;
      case ErrorCategory.server:
        return actions.server;
      case ErrorCategory.request:
        return actions.request;
      case ErrorCategory.timeout:
        return actions.timeout;
      case ErrorCategory.format:
        return actions.format;
      case ErrorCategory.persist:
        return actions.persist;
      case ErrorCategory.contextOverflow:
        return actions.contextOverflow;
      case ErrorCategory.unknown:
        return actions.unknown;
    }
  }

  String _resolveCategoryLabel(Translations t, ErrorCategory category) {
    final labels = t.intermediate.chat.failure.categoryLabels;
    switch (category) {
      case ErrorCategory.config:
        return labels.config;
      case ErrorCategory.network:
        return labels.network;
      case ErrorCategory.auth:
        return labels.auth;
      case ErrorCategory.rateLimit:
        return labels.rateLimit;
      case ErrorCategory.server:
        return labels.server;
      case ErrorCategory.request:
        return labels.request;
      case ErrorCategory.timeout:
        return labels.timeout;
      case ErrorCategory.format:
        return labels.format;
      case ErrorCategory.persist:
        return labels.persist;
      case ErrorCategory.contextOverflow:
        return labels.contextOverflow;
      case ErrorCategory.unknown:
        return labels.unknown;
    }
  }

  String _resolvePhaseLabel(Translations t, IntermediatePhase phase) {
    final labels = t.intermediate.chat.failure.phaseLabels;
    switch (phase) {
      case IntermediatePhase.compacting:
        return labels.compacting;
      case IntermediatePhase.generating:
        return labels.generating;
      case IntermediatePhase.generatingRetry:
        return labels.generatingRetry;
      case IntermediatePhase.extracting:
        return labels.extracting;
      case IntermediatePhase.extractingRetry:
        return labels.extractingRetry;
      case IntermediatePhase.retrieving:
        return labels.retrieving;
      case IntermediatePhase.retrievingRetry:
        return labels.retrievingRetry;
      case IntermediatePhase.reviewing:
        return labels.reviewing;
      case IntermediatePhase.reviewingRetry:
        return labels.reviewingRetry;
      case IntermediatePhase.summarizing:
        return labels.summarizing;
      case IntermediatePhase.summarizingRetry:
        return labels.summarizingRetry;
      case IntermediatePhase.persisting:
        return labels.persisting;
      case IntermediatePhase.failed:
        return labels.failed;
      case IntermediatePhase.idle:
        return labels.idle;
    }
  }
}

/// 详情区小节标题（caption + muted + 600 字重）
class _DetailSectionTitle extends StatelessWidget {
  const _DetailSectionTitle({required this.text, required this.colors});

  final String text;
  final LmPalette colors;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: IntermediateTextStyles.caption.copyWith(
        color: colors.muted,
        fontWeight: FontWeight.w600,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// 详情行：固定宽度标签 + 值（两列布局）
class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    required this.colors,
  });

  final String label;
  final String value;
  final LmPalette colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: IntermediateSpacing.s2xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: IntermediateTextStyles.caption.copyWith(
                color: colors.muted,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: IntermediateSpacing.sSm),
          Expanded(
            child: Text(
              value,
              style: IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
