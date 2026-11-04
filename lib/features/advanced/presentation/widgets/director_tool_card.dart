import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/utils/secret_redactor.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/domain/services/agent_log_recovery.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_readable_color.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 导演模式 L2 审计步骤卡（体验重构 §4.3.3：剧场语言为表、CLI 为里）
///
/// 头部 = 舞台动词（i18n toolName 映射）+ 人话标题（工具结果信封 title，
/// 如 `翻阅前情 ·「古碑」· 12 处命中`）；等宽工具名/原始参数/耗时全部
/// 下沉到展开层。三态：running（spinner + 标题微光，不可展开）/
/// done（静态）/ error（红色变体）。生成中与生成结束共用本组件——
/// 只有 [AgentWorkStep.status] 变化，结构不变（布局稳定优先）。
class DirectorToolCard extends StatefulWidget {
  const DirectorToolCard({
    required this.step,
    this.runningEnabled = true,
    super.key,
  });

  final AgentWorkStep step;
  final bool runningEnabled;

  /// 崩溃恢复占位标题本地化映射（兼容存量与各语言环境下持久化事件）
  static String localizedTitle(String title, Translations t) {
    if (AgentLogRecoveryService.isPlaceholderTitle(title)) {
      return t.advanced.process.interruptedToolPlaceholder;
    }
    return title;
  }

  /// 崩溃恢复占位输出本地化映射（协议持久化事件保持原样，渲染层映射）
  static String localizedOutput(String output, Translations t) {
    if (AgentLogRecoveryService.isInterruptedOutput(output)) {
      return t.advanced.process.interruptedToolOutput;
    }
    return output;
  }

  @override
  State<DirectorToolCard> createState() => _DirectorToolCardState();
}

class _DirectorToolCardState extends State<DirectorToolCard> {
  var _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final step = widget.step;
    final isRunning = step.isRunning && widget.runningEnabled;
    final isError = step.isError;
    final isWarning = step.isWarning;
    final canExpand = !step.isRunning &&
        (step.output.isNotEmpty || step.argsPreview.isNotEmpty);

    // DD2：可恢复失败（warning）用黄色，只有中断本轮（error）才用红色。
    final statusColor = isError
        ? colors.error
        : isWarning
            ? colors.warning
            : colors.muted;
    final titleColor = statusColor;
    final borderColor = isError || isWarning
        ? statusColor
        : colors.divider.withValues(alpha: 0.6);

    final heading = _heading(step, t);

    return AnimatedContainer(
      duration: LmMotion.unfold,
      curve: LmMotion.easeStandard,
      margin: const EdgeInsets.only(bottom: IntermediateSpacing.sXs),
      decoration: BoxDecoration(
        color: isError || isWarning
            ? statusColor.withValues(alpha: 0.08)
            : colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
        border: Border.all(color: borderColor, width: 0.5),
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: IntermediateSpacing.sMd,
        vertical: 6,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap:
                canExpand ? () => setState(() => _expanded = !_expanded) : null,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
            child: Row(
              children: [
                // 前导指示：running 用 spinner，失败用小图标，done 无图标
                if (isRunning)
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.5,
                      color: colors.muted,
                    ),
                  )
                else if (isError)
                  Icon(Icons.error_outline, size: 13, color: colors.error)
                else if (isWarning)
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 13,
                    color: colors.warning,
                  ),
                if (isRunning || isError || isWarning)
                  const SizedBox(width: IntermediateSpacing.sSm),
                // 标题：舞台动词 + 人话标题（信封 title），完成后一次淡入加深
                Expanded(
                  child: isRunning
                      ? ShimmerText(
                          heading,
                          style: IntermediateTextStyles.caption.copyWith(
                            color: colors.muted,
                          ),
                        )
                      : AnimatedDefaultTextStyle(
                          duration: LmMotion.unfold,
                          curve: LmMotion.easeStandard,
                          style: IntermediateTextStyles.caption.copyWith(
                            color: titleColor,
                          ),
                          child: Text(
                            heading,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                ),
                if (canExpand)
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: colors.faint,
                  ),
              ],
            ),
          ),
          // L2 展开层：等宽工具名/参数/输出/耗时（审计区，CLI 为里）
          if (_expanded && canExpand)
            RepaintBoundary(
              child: Padding(
                padding: const EdgeInsets.only(top: IntermediateSpacing.sXs),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(
                              context.lmUi.radius(LmCorner.xs),
                            ),
                            border: Border.all(
                              color: colors.divider,
                              width: 0.5,
                            ),
                          ),
                          child: Text(
                            t.advanced.audit.toolLabel(name: step.toolName),
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              height: 1.2,
                              color: colors.faint,
                            ),
                          ),
                        ),
                        if (step.durationMs > 0) ...[
                          const SizedBox(width: IntermediateSpacing.sSm),
                          Text(
                            '${(step.durationMs / 1000).toStringAsFixed(1)}s',
                            style: TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              height: 1.2,
                              color: colors.faint,
                            ),
                          ),
                        ],
                        // 失败步骤（红/黄）：一键复制完整信息（便于反馈；
                        // 成功步骤输出已在展开层可选中复制，不加按钮保持安静）
                        if (isError || isWarning) ...[
                          const Spacer(),
                          _CopyStepButton(step: step),
                        ],
                      ],
                    ),
                    if (step.argsPreview.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(
                          top: IntermediateSpacing.s2xs,
                        ),
                        child: Text(
                          step.argsPreview,
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 11,
                            height: 1.4,
                            color: colors.faint,
                          ),
                        ),
                      ),
                    if (step.output.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(
                          top: IntermediateSpacing.s2xs,
                        ),
                        child: SelectableText(
                          DirectorToolCard.localizedOutput(step.output, t),
                          style: TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.5,
                            color: colors.muted,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 头部一行：舞台动词 + 人话标题（running 占位时 title 为空，仅动词）
  String _heading(AgentWorkStep step, Translations t) {
    final verb = stageVerbOf(step.toolName, t);
    if (step.title.isEmpty) return verb;
    return '$verb · ${DirectorToolCard.localizedTitle(step.title, t)}';
  }
}

/// 错误步骤的一键复制按钮（工具名/参数/输出全文，便于用户反馈）
class _CopyStepButton extends StatelessWidget {
  const _CopyStepButton({required this.step});

  final AgentWorkStep step;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    return IconButton(
      onPressed: () {
        final buffer = StringBuffer(
          '[${t.advanced.audit.toolLabel(name: step.toolName)}]',
        );
        if (step.argsPreview.isNotEmpty) {
          buffer.write('\n${step.argsPreview}');
        }
        if (step.output.isNotEmpty) {
          buffer.write(
            '\n${DirectorToolCard.localizedOutput(step.output, t)}',
          );
        }
        // 脱敏后再入剪贴板（工具输出理论上不应含凭据，防御性处理）
        Clipboard.setData(
          ClipboardData(text: redactSecrets(buffer.toString())),
        );
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(t.advanced.audit.copyStepSuccess),
            duration: const Duration(seconds: 2),
          ),
        );
      },
      icon: Icon(Icons.copy_outlined, size: 14, color: colors.muted),
      tooltip: t.advanced.audit.copyStep,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
    );
  }
}

/// 工具名 → 舞台动词（i18n 映射；未知工具回落"幕后工作"）
String stageVerbOf(String toolName, Translations t) {
  final stage = t.advanced.stage;
  return switch (toolName) {
    'search_story' => stage.searchStory,
    'search_story_text' => stage.searchStoryText,
    'read_story' => stage.readStory,
    'query_facts' => stage.queryFacts,
    'read_compact_summary' => stage.readCompactSummary,
    'update_facts' => stage.updateFacts,
    'record_event_memory' => stage.recordEventMemory,
    // 补齐遗漏映射——此前落 fallback「幕后工作」
    'update_story_anchor' => stage.updateStoryAnchor,
    'merge_entities' => stage.mergeEntities,
    'ask_user' => stage.askUser,
    'finish_round' => stage.finishRound,
    'read_skill' => stage.readSkill,
    'spawn' => stage.spawn,
    _ => stage.fallback,
  };
}

/// 运行态标题微光扫过（opencode TextShimmer 的轻量版）
///
/// 用 ShaderMask + 滑动渐变模拟文字上掠过的亮带；reduced-motion 下静止。
class ShimmerText extends StatefulWidget {
  const ShimmerText(this.text, {required this.style, super.key});

  final String text;
  final TextStyle style;

  @override
  State<ShimmerText> createState() => ShimmerTextState();
}

class ShimmerTextState extends State<ShimmerText>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = AnimationController(
      duration: LmMotion.loop,
      vsync: this,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    //  reduced-motion：减弱动态下不启动扫光动画（MediaQuery 依赖只能在
    // didChangeDependencies 读取）；判据统一走 LmMotion。
    _syncAnimation();
  }

  void _syncAnimation() {
    final animate = _foreground &&
        TickerMode.valuesOf(context).enabled &&
        LmMotion.shouldAnimate(context);
    if (animate && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!animate) {
      _controller.stop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncAnimation();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 扫光基色兜底 = faint 令牌（：原为手抄 #9B9990 魔数）；
    // 扫光高亮向 ink 提亮（主题感知，原为硬编码白）。
    final colors = context.lm.palette;
    final base = directorReadableColor(colors, widget.style.color);
    final highlight = Color.lerp(base, colors.ink, 0.55) ?? colors.ink;

    if (!LmMotion.shouldAnimate(context)) {
      return Text(widget.text, style: widget.style.copyWith(color: base));
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final shift = _controller.value * 2 - 1;
        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment(shift - 1, 0),
            end: Alignment(shift + 0.5, 0),
            colors: [base, highlight, base],
            stops: const [0.2, 0.5, 0.8],
          ).createShader(bounds),
          child: child,
        );
      },
      child: Text(
        widget.text,
        style: widget.style.copyWith(color: base),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
