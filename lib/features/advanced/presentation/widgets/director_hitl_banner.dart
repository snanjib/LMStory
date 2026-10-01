import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_tool_card.dart'
    show stageVerbOf;
import 'package:lmstory/i18n/strings.g.dart';

/// ask_user 横幅（体验重构）：导演决策卡
///
/// 问题 + 选项 chips（点击即答）+ 自由输入 + 跳过。跳过/超时 → 模型收到
/// "导演未回答，按你判断继续并注明"。
///
/// [timeout] 驱动头部 muted 倒计时（每分钟跳动；null = 「一直等待你的
/// 回复」）；[showIntro] 为 true 时（页面侧保证每会话仅首次 HITL 横幅出现）
/// 头部多一行解释，见完经 [onIntroSeen] 回告。
class DirectorAskBanner extends StatefulWidget {
  const DirectorAskBanner({
    required this.prompt,
    required this.onAnswer,
    required this.onSkip,
    this.timeout,
    this.showIntro = false,
    this.onIntroSeen,
    super.key,
  });

  final AgentAskPrompt prompt;
  final void Function(String answer) onAnswer;
  final VoidCallback onSkip;

  /// 挂起超时（advanced.hitl.ask_user_timeout_minutes；null = 永不超时）
  final Duration? timeout;

  /// 首次出现（本会话首张 HITL 横幅）时显示一行解释
  final bool showIntro;
  final VoidCallback? onIntroSeen;

  @override
  State<DirectorAskBanner> createState() => _DirectorAskBannerState();
}

class _DirectorAskBannerState extends State<DirectorAskBanner> {
  final _controller = TextEditingController();
  Timer? _ticker;

  /// 挂起起始时刻（倒计时锚点；横幅出现时一次定值）
  late final DateTime _appearedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    // 每分钟跳动的倒计时（无超时档不计时）
    if (widget.timeout != null) {
      _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
        if (mounted) setState(() {});
      });
    }
    if (widget.showIntro) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onIntroSeen?.call();
      });
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isNotEmpty) widget.onAnswer(text);
  }

  /// 头部倒计时/等待说明行（muted）
  Widget _buildCountdownRow(LmPalette colors, Translations t) {
    final timeout = widget.timeout;
    final String text;
    if (timeout == null) {
      text = t.advanced.hitl.waitForever;
    } else {
      // 展示口径：剩余分钟数向上取整（3 分钟挂起全程显示 3，最后一分钟显示 1）
      text = t.advanced.hitl.countdownAsk(
        minutes: _remainingMinutes(timeout),
      );
    }
    return Row(
      children: [
        Icon(Icons.timer_outlined, size: 12, color: colors.muted),
        const SizedBox(width: IntermediateSpacing.sXs),
        Text(
          text,
          style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
        ),
      ],
    );
  }

  /// 剩余分钟数（向上取整，下限 1）：按秒取整避免时钟同刻时 inMinutes+1 进位
  int _remainingMinutes(Duration timeout) {
    final seconds =
        _appearedAt.add(timeout).difference(DateTime.now()).inSeconds;
    final minutes = (seconds / 60).ceil();
    return minutes < 1 ? 1 : minutes;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Container(
      margin: const EdgeInsets.fromLTRB(
        IntermediateSpacing.sMd,
        IntermediateSpacing.sSm,
        IntermediateSpacing.sMd,
        0,
      ),
      padding: const EdgeInsets.all(IntermediateSpacing.sMd),
      decoration: BoxDecoration(
        color: colors.surfaceElevated,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        border: Border.all(color: colors.primary.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.help_outline, size: 14, color: colors.primary),
              const SizedBox(width: IntermediateSpacing.sSm),
              Text(
                t.advanced.askUser.title,
                style: IntermediateTextStyles.caption.copyWith(
                  color: colors.primary,
                ),
              ),
              const Spacer(),
              _buildCountdownRow(colors, t),
            ],
          ),
          if (widget.showIntro) ...[
            const SizedBox(height: IntermediateSpacing.s2xs),
            Text(
              t.advanced.hitl.introAsk,
              style: IntermediateTextStyles.caption.copyWith(
                color: colors.muted,
              ),
            ),
          ],
          const SizedBox(height: IntermediateSpacing.sXs),
          Text(
            widget.prompt.question,
            style: IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
          ),
          if (widget.prompt.options.isNotEmpty) ...[
            const SizedBox(height: IntermediateSpacing.sSm),
            Wrap(
              spacing: IntermediateSpacing.sSm,
              runSpacing: IntermediateSpacing.s2xs,
              children: [
                for (final option in widget.prompt.options)
                  ActionChip(
                    label: Text(option),
                    onPressed: () => widget.onAnswer(option),
                    backgroundColor: colors.surfaceVariant,
                    side: BorderSide(color: colors.divider, width: 0.5),
                    labelStyle: IntermediateTextStyles.caption.copyWith(
                      color: colors.ink,
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: IntermediateSpacing.sSm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  style: IntermediateTextStyles.bodyUi.copyWith(
                    color: colors.ink,
                  ),
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: t.advanced.askUser.inputHint,
                    hintStyle: IntermediateTextStyles.caption.copyWith(
                      color: colors.muted,
                    ),
                    filled: true,
                    fillColor: colors.surfaceVariant,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(
                        context.lmUi.radius(LmCorner.sm),
                      ),
                      borderSide: BorderSide(color: colors.divider),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: IntermediateSpacing.sSm),
              IconButton(
                onPressed: _submit,
                icon: const Icon(Icons.send_outlined, size: 18),
                color: colors.primary,
                tooltip: t.common.confirm,
              ),
              TextButton(
                onPressed: widget.onSkip,
                child: Text(
                  t.advanced.askUser.skip,
                  style: IntermediateTextStyles.caption.copyWith(
                    color: colors.muted,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 监督模式审批横幅（体验重构）：写入确认卡
///
/// 人话摘要 + 允许/拒绝（fail-closed：超时视同拒绝， 明确不开放
/// 「一直等待」档——安全语义维持）。
///
/// 第三按钮「本会话总是允许」——本次放行同时把该工具记入会话级
/// 放行集，后续同工具不再弹横幅（设置面板可清除）。
class DirectorApprovalBanner extends StatefulWidget {
  const DirectorApprovalBanner({
    required this.prompt,
    required this.onResolve,
    required this.timeout,
    this.showIntro = false,
    this.onIntroSeen,
    super.key,
  });

  final AgentApprovalPrompt prompt;

  /// 处置结论；`allow=true` 且 `always=true` = 本会话总是允许
  final void Function({required bool allow, bool always}) onResolve;

  /// 挂起超时（advanced.hitl.approval_timeout_minutes；fail-closed 必有超时）
  final Duration timeout;

  /// 首次出现（本会话首张 HITL 横幅）时显示一行解释
  final bool showIntro;
  final VoidCallback? onIntroSeen;

  @override
  State<DirectorApprovalBanner> createState() => _DirectorApprovalBannerState();
}

class _DirectorApprovalBannerState extends State<DirectorApprovalBanner> {
  Timer? _ticker;

  /// 挂起起始时刻（倒计时锚点；横幅出现时一次定值）
  late final DateTime _appearedAt = DateTime.now();

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    if (widget.showIntro) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onIntroSeen?.call();
      });
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    // 展示口径：剩余分钟数向上取整（同 ask 横幅）
    final seconds =
        _appearedAt.add(widget.timeout).difference(DateTime.now()).inSeconds;
    final remaining = ((seconds / 60).ceil()) < 1 ? 1 : (seconds / 60).ceil();

    return Container(
      margin: const EdgeInsets.fromLTRB(
        IntermediateSpacing.sMd,
        IntermediateSpacing.sSm,
        IntermediateSpacing.sMd,
        0,
      ),
      padding: const EdgeInsets.all(IntermediateSpacing.sMd),
      decoration: BoxDecoration(
        color: colors.surfaceElevated,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        border: Border.all(color: colors.warning.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined, size: 14, color: colors.warning),
              const SizedBox(width: IntermediateSpacing.sSm),
              Expanded(
                child: Text(
                  //  修复：舞台动词替代裸英文工具名——
                  // 「确认写入：修订设定集」而非「确认写入：update_facts」，
                  // 与同卡片的人话摘要保持同一语言体系
                  t.advanced.approval.title(
                    tool: stageVerbOf(widget.prompt.toolName, t),
                  ),
                  style: IntermediateTextStyles.caption.copyWith(
                    color: colors.warning,
                  ),
                ),
              ),
              Row(
                children: [
                  Icon(Icons.timer_outlined, size: 12, color: colors.muted),
                  const SizedBox(width: IntermediateSpacing.sXs),
                  Text(
                    t.advanced.hitl.countdownApproval(
                      minutes: remaining < 1 ? 1 : remaining,
                    ),
                    style: IntermediateTextStyles.caption.copyWith(
                      color: colors.muted,
                    ),
                  ),
                ],
              ),
            ],
          ),
          if (widget.showIntro) ...[
            const SizedBox(height: IntermediateSpacing.s2xs),
            Text(
              t.advanced.hitl.introApproval,
              style: IntermediateTextStyles.caption.copyWith(
                color: colors.muted,
              ),
            ),
          ],
          const SizedBox(height: IntermediateSpacing.sXs),
          Text(
            widget.prompt.summary,
            style: IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
          ),
          const SizedBox(height: IntermediateSpacing.sSm),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              // 本会话总是允许（第三按钮，弱视觉位防误触——
              // 与「允许」同效果但叠加会话级放行记忆）
              TextButton(
                onPressed: () => widget.onResolve(allow: true, always: true),
                child: Text(
                  t.advanced.approval.alwaysAllow,
                  style: IntermediateTextStyles.caption.copyWith(
                    color: colors.primary,
                  ),
                ),
              ),
              const SizedBox(width: IntermediateSpacing.sSm),
              FilledButton(
                onPressed: () => widget.onResolve(allow: true),
                style: FilledButton.styleFrom(
                  backgroundColor: colors.primary,
                  foregroundColor: colors.bg,
                ),
                child: Text(t.advanced.approval.allow),
              ),
              const SizedBox(width: IntermediateSpacing.sSm),
              OutlinedButton(
                onPressed: () => widget.onResolve(allow: false),
                child: Text(t.advanced.approval.deny),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
