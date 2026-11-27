import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/shared/components/lm_arrival.dart';
import 'package:lmstory/core/theme/shared/components/lm_overflow_card.dart';
import 'package:lmstory/core/theme/system/lm_button_metrics.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/presentation/utils/agent_approval_labels.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_tool_card.dart'
    show stageVerbOf;
import 'package:lmstory/i18n/strings.g.dart';

/// Keeps a long decision readable beside the story and the open keyboard.
///
/// 卡框（surfaceElevated 底 + 强调色描边 +
/// 限高滚动 + 底部渐隐与「下滑查看更多」提示）由 [LmOverflowCard] 统一
/// 提供——卡框不随内容滚动，边界恒定可见；内容溢出时渐隐+提示 pill
/// 给出"下面还有"的线索。[accentColor] 为描边强调色（决策卡=primary、
/// 审批卡=warning；缺省 primary）。
class DirectorDecisionViewport extends StatelessWidget {
  const DirectorDecisionViewport({
    required this.maxHeight,
    required this.child,
    this.accentColor,
    super.key,
  });

  final double maxHeight;
  final Widget child;

  /// 卡框描边强调色（null = primary）
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    // 正文列的阅读限宽是无条件的（>800 即收窄），决策卡外框须同口径用
    // 裸钳制而不是 LmMeasure 的 ≥1280 门，避免 800–1280 段与正文错位。
    return LmArrival(
      child: Center(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxWidth: LmLayout.readingWidthOf(context)),
          child: LmOverflowCard(
            maxHeight: maxHeight,
            margin: const EdgeInsets.fromLTRB(
              IntermediateSpacing.sMd,
              IntermediateSpacing.sSm,
              IntermediateSpacing.sMd,
              0,
            ),
            backgroundColor: colors.surfaceElevated,
            borderColor:
                (accentColor ?? colors.primary).withValues(alpha: 0.45),
            scrollHintLabel: Translations.of(context).advanced.hitl.scrollMore,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// ask_user 横幅（体验重构）：导演决策卡
///
/// 问题 + 选项行按钮（点击即答）+ 自由输入 + 跳过。跳过/超时 → 模型收到
/// "导演未回答，按你判断继续并注明"。卡框由 [DirectorDecisionViewport]
/// 提供——此前选项是 12px 低对比 ActionChip 且溢出无提示，内测用户
/// "看不出能点/看不出能下滑"。
///
/// [timeout] 驱动头部 muted 倒计时（每分钟跳动；null = 「一直等待你的
/// 回复」）；[showIntro] 为 true 时（页面侧保证每会话仅首次 HITL 横幅出现）
/// 头部多一行解释，见完经 [onIntroSeen] 回告；[fontScale] 为「字体大小」
/// 设置缩放比，作用于问题正文（叙事内容），UI 字不随动。
class DirectorAskBanner extends StatefulWidget {
  const DirectorAskBanner({
    required this.prompt,
    required this.onAnswer,
    required this.onSkip,
    this.timeout,
    this.showIntro = false,
    this.onIntroSeen,
    this.fontScale = 1.0,
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

  /// 「字体大小」设置缩放比（问题正文随其缩放；缺省 1.0）
  final double fontScale;

  @override
  State<DirectorAskBanner> createState() => _DirectorAskBannerState();
}

class _DirectorAskBannerState extends State<DirectorAskBanner> {
  final _controller = TextEditingController();
  Timer? _ticker;

  /// 挂起起始时刻（倒计时锚点；可变——输入活动时重置，P2 同盖）。
  /// 经 clock.now() 取时（非 DateTime.now()）——widget 测试假时钟可控。
  DateTime _appearedAt = clock.now();

  @override
  void initState() {
    super.initState();
    // 每分钟跳动的倒计时（无超时档不计时）
    if (widget.timeout != null) {
      _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
        if (mounted) setState(() {});
      });
    }
    // 有未发送文字 = 交互活动，重置倒计时锚（P2：防「人在打字被超时」）
    _controller.addListener(_resetCountdown);
    if (widget.showIntro) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onIntroSeen?.call();
      });
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_resetCountdown);
    _ticker?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _resetCountdown() {
    _appearedAt = clock.now();
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
        Icon(Icons.timer_outlined, size: 14, color: colors.muted),
        const SizedBox(width: IntermediateSpacing.sXs),
        Expanded(
          child: Text(
            text,
            // 12px caption → 14px（内测反馈"状态行字太小"）
            style: IntermediateTextStyles.label.copyWith(
              color: colors.muted,
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
      ],
    );
  }

  /// 剩余分钟数（向上取整，下限 1）：按秒取整避免时钟同刻时 inMinutes+1 进位
  int _remainingMinutes(Duration timeout) {
    final seconds = _appearedAt.add(timeout).difference(clock.now()).inSeconds;
    final minutes = (seconds / 60).ceil();
    return minutes < 1 ? 1 : minutes;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          header: true,
          liveRegion: true,
          child: Text(
            t.advanced.askUser.title,
            style: IntermediateTextStyles.label.copyWith(color: colors.primary),
          ),
        ),
        const SizedBox(height: IntermediateSpacing.sXs),
        _buildCountdownRow(colors, t),
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
          style: LmNarrativeTextStyles.narrativeDisplay
              .copyWith(color: colors.ink),
          // 「字体大小」设置联动（决策卡此前写死字号
          // 不受设置影响）——问题正文属叙事内容随 fontScale 缩放，选项/
          // 倒计时等 UI 字保持 UI 档。
          textScaler: TextScaler.linear(widget.fontScale.clamp(0.5, 2.0)),
        ),
        if (widget.prompt.options.isNotEmpty) ...[
          const SizedBox(height: IntermediateSpacing.sSm),
          // 选项从 12px 低对比 ActionChip 改为整行
          // 按钮——dividerStrong 描边 + 44px 触控高 + 尾部 chevron，
          // 按钮感与可点性明确；多选项纵排，超高由卡框滚动+溢出提示兜住。
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (i, option) in widget.prompt.options.indexed) ...[
                if (i > 0) const SizedBox(height: IntermediateSpacing.sXs),
                _AskOptionButton(
                  label: option,
                  onTap: () => widget.onAnswer(option),
                ),
              ],
            ],
          ),
        ],
        const SizedBox(height: IntermediateSpacing.sSm),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
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
            const SizedBox(height: IntermediateSpacing.sXs),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: IntermediateSpacing.sSm,
              runSpacing: IntermediateSpacing.sXs,
              children: [
                IconButton(
                  onPressed: _submit,
                  icon: const Icon(Icons.send_outlined, size: 18),
                  color: colors.primary,
                  tooltip: t.common.confirm,
                ),
                // 跳过从 muted 裸 TextButton（视觉近纯文本）
                // 升为描边按钮——次要动作但仍是动作。
                OutlinedButton(
                  onPressed: widget.onSkip,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: colors.muted,
                    side: BorderSide(color: colors.divider, width: 0.5),
                    minimumSize: const Size(
                      48,
                      LmButtonMetrics.minInteractiveHeight,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: IntermediateSpacing.sMd,
                    ),
                    textStyle: IntermediateTextStyles.label,
                  ),
                  child: Text(t.advanced.askUser.skip),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

/// 决策选项行按钮：整行可点、左文右 chevron（
/// "看不出这里可以点击"）。
class _AskOptionButton extends StatelessWidget {
  const _AskOptionButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        backgroundColor: colors.surface,
        foregroundColor: colors.ink,
        side: BorderSide(color: colors.dividerStrong),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(
            context.lmUi.radius(LmCorner.sm),
          ),
        ),
        minimumSize: const Size(64, LmButtonMetrics.minInteractiveHeight),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(
          horizontal: IntermediateSpacing.sSm,
          vertical: IntermediateSpacing.sXs,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              textAlign: TextAlign.left,
              style: IntermediateTextStyles.bodyUi.copyWith(
                color: colors.ink,
              ),
            ),
          ),
          Icon(Icons.chevron_right, size: 18, color: colors.muted),
        ],
      ),
    );
  }
}

/// 监督模式审批横幅（体验重构）：写入确认卡
///
/// 摘要行 + 可展开变更明细 + 共用批注区（2026-10-15 批 C，P1–P4）+
/// 允许/拒绝。fail-closed 默认超时视同拒绝；P2 永等开关（
/// advanced.hitl.approval_timeout_enabled）关闭时 [timeout] 为 null——
/// 横幅永不超时一直等待。横幅内有交互活动（明细展开/批注聚焦或有
/// 未发送文字）会重置倒计时锚——fail-closed 防的是「人不在场」，
/// 不再误伤「人在细看」。
///
/// merge_entities 永不进会话放行集（P4）：不显示「本会话总是允许」，
/// 永远逐次审批。
class DirectorApprovalBanner extends StatefulWidget {
  const DirectorApprovalBanner({
    required this.prompt,
    required this.onResolve,
    required this.timeout,
    this.showIntro = false,
    this.onIntroSeen,
    this.now,
    super.key,
  });

  /// 时间源（倒计时锚点与剩余计算）。null = clock.now()（生产同
  /// DateTime.now()）；测试注入可控时钟（widget 假时钟不动 DateTime.now，
  /// 此版本 flutter_test 亦不可设置 binding.clock，故显式注入）。
  final DateTime Function()? now;

  final AgentApprovalPrompt prompt;

  /// 处置结论；`allow=true` 且 `always=true` = 本会话总是允许；
  /// feedback 为共用批注：允许时随批准信封下发、拒绝时走既有拒绝
  /// 留言通道；空 = 纯处置，什么都不追加。
  final void Function({required bool allow, bool always, String? feedback})
      onResolve;

  /// 挂起超时（advanced.hitl.approval_timeout_enabled 开 = fail-closed
  /// 必有超时；关 = null 永不超时）
  final Duration? timeout;

  /// 首次出现（本会话首张 HITL 横幅）时显示一行解释
  final bool showIntro;
  final VoidCallback? onIntroSeen;

  @override
  State<DirectorApprovalBanner> createState() => _DirectorApprovalBannerState();
}

class _DirectorApprovalBannerState extends State<DirectorApprovalBanner> {
  Timer? _ticker;

  /// 挂起起始时刻（倒计时锚点；**可变**——横幅内交互活动时重置，P2）
  late DateTime _appearedAt = _now();

  DateTime Function() get _now => widget.now ?? clock.now;

  /// 变更明细展开态（默认收起：明细可达 30+ 行，不拖慢快速批准）
  bool _changesExpanded = false;

  /// 共用批注区展开态与输入（允许/拒绝共用一个框，P1）
  bool _commentExpanded = false;
  late final TextEditingController _commentController = TextEditingController();

  /// 批注字数上限（与属性值上限一致；超限截断——超出部分随输入丢弃）
  static const int _maxCommentLength = 500;

  @override
  void initState() {
    super.initState();
    if (widget.timeout != null) {
      _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
        if (mounted) setState(() {});
      });
    }
    // 有未发送文字 = 持续交互活动，重置倒计时锚（P2）
    _commentController.addListener(_onCommentActivity);
    if (widget.showIntro) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onIntroSeen?.call();
      });
    }
  }

  @override
  void dispose() {
    _commentController.removeListener(_onCommentActivity);
    _commentController.dispose();
    _ticker?.cancel();
    super.dispose();
  }

  void _onCommentActivity() {
    final text = _commentController.text;
    // 500 字截断（超限丢弃尾部并截到上限）
    if (text.length > _maxCommentLength) {
      _commentController.text = text.substring(0, _maxCommentLength);
    }
    _resetCountdown();
  }

  /// 交互活动重置倒计时锚（P2：fail-closed 防人不在场，不误伤人在细看）
  void _resetCountdown() {
    _appearedAt = _now();
  }

  String? get _comment => switch (_commentController.text.trim()) {
        '' => null,
        final text => text,
      };

  /// 头部倒计时/等待说明行（muted）
  Widget _buildCountdownRow(LmPalette colors, Translations t) {
    final timeout = widget.timeout;
    final String text;
    if (timeout == null) {
      text = t.advanced.hitl.waitForeverApproval;
    } else {
      final seconds = _appearedAt.add(timeout).difference(_now()).inSeconds;
      final minutes = (seconds / 60).ceil();
      text =
          t.advanced.hitl.countdownApproval(minutes: minutes < 1 ? 1 : minutes);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.timer_outlined, size: 14, color: colors.muted),
        const SizedBox(width: IntermediateSpacing.sXs),
        Expanded(
          child: Text(
            text,
            // 12px caption → 14px（与决策卡同口径）
            style: IntermediateTextStyles.label.copyWith(
              color: colors.muted,
              fontWeight: FontWeight.w400,
            ),
          ),
        ),
      ],
    );
  }

  /// 变更明细折叠区（默认收起；展开限高滚动，行卡=实体·属性+徽标+前后值）
  Widget _buildChangesSection(LmPalette colors, Translations t) {
    final changes = widget.prompt.changes;
    if (changes.isEmpty) return const SizedBox.shrink();
    final s = t.advanced.approval;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 展开入口从裸 primary 文本行升为浅底 chip——
        // "看不出这里可以点击"。
        Container(
          decoration: BoxDecoration(
            color: colors.surfaceVariant,
            borderRadius: BorderRadius.circular(
              context.lmUi.radius(LmCorner.xs),
            ),
            border: Border.all(color: colors.divider, width: 0.5),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(
              context.lmUi.radius(LmCorner.xs),
            ),
            onTap: () {
              _resetCountdown();
              setState(() => _changesExpanded = !_changesExpanded);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: IntermediateSpacing.sXs,
                vertical: IntermediateSpacing.s2xs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _changesExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: colors.primary,
                  ),
                  const SizedBox(width: IntermediateSpacing.s2xs),
                  Text(
                    _changesExpanded
                        ? s.changesToggleHide
                        : s.changesToggleShow(count: changes.length),
                    style: IntermediateTextStyles.label.copyWith(
                      color: colors.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_changesExpanded)
          // 限高滚动区补底部渐隐（明细可达 30+ 行，
          // "看不出下面还有"）
          LmOverflowCard(
            maxHeight: 220,
            padding: EdgeInsets.zero,
            fadeColor: colors.surfaceElevated,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (i, change) in changes.indexed)
                  _buildChangeRow(colors, t, change, i),
              ],
            ),
          ),
      ],
    );
  }

  /// 单条变更行卡
  Widget _buildChangeRow(
    LmPalette colors,
    Translations t,
    AgentApprovalChange change,
    int index,
  ) {
    final display = formatApprovalChange(change, t);
    final s = t.advanced.approval;
    final dimmed = colors.muted.withValues(alpha: 0.7);
    final titleColor = change.effective ? colors.ink : dimmed;
    final kindLabel = switch (change.kind) {
      ApprovalChangeKind.createEntity => s.kindCreate,
      ApprovalChangeKind.updateAttr => s.kindUpdate,
      ApprovalChangeKind.appendList => s.kindAppend,
      ApprovalChangeKind.removeFromList => s.kindRemove,
      ApprovalChangeKind.addAlias => s.kindAlias,
      ApprovalChangeKind.archiveEntity => s.kindArchive,
      ApprovalChangeKind.merge => s.kindMerge,
      ApprovalChangeKind.mergeNote => s.kindMerge,
      ApprovalChangeKind.entitySnapshot => s.kindSnapshot,
      ApprovalChangeKind.anchor => s.kindAnchor,
      ApprovalChangeKind.eventMemory => s.kindEvent,
    };
    final label = display.attributeLabel;
    final title = label == null || label.isEmpty
        ? display.entityName
        : '${display.entityName} · $label';
    final before = display.before;
    final after = display.after;
    final note = display.note;
    final reason = change.reason;

    return Container(
      margin: const EdgeInsets.only(bottom: IntermediateSpacing.s2xs),
      padding: const EdgeInsets.all(IntermediateSpacing.sXs),
      decoration: BoxDecoration(
        color: colors.surfaceVariant.withValues(
          alpha: change.effective ? 1.0 : 0.45,
        ),
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style:
                      IntermediateTextStyles.label.copyWith(color: titleColor),
                ),
              ),
              if (change.confidence != null)
                Padding(
                  padding:
                      const EdgeInsets.only(left: IntermediateSpacing.s2xs),
                  child: Text(
                    s.confidenceBadge(n: change.confidence!),
                    style: IntermediateTextStyles.captionSm.copyWith(
                      color: change.effective ? colors.muted : dimmed,
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.only(left: IntermediateSpacing.s2xs),
                child: Text(
                  kindLabel,
                  style: IntermediateTextStyles.captionSm.copyWith(
                    color: colors.primary.withValues(
                      alpha: change.effective ? 1.0 : 0.5,
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (before != null || after != null) ...[
            const SizedBox(height: IntermediateSpacing.s2xs),
            if (before != null)
              Text(
                s.valueLine(label: s.beforeLabel, value: before),
                style:
                    IntermediateTextStyles.caption.copyWith(color: titleColor),
              ),
            if (after != null)
              Text(
                s.valueLine(label: s.afterLabel, value: after),
                style:
                    IntermediateTextStyles.caption.copyWith(color: titleColor),
              ),
          ],
          if (reason != null && reason.isNotEmpty) ...[
            const SizedBox(height: IntermediateSpacing.s2xs),
            Text(
              s.valueLine(label: s.reasonLabel, value: reason),
              style: IntermediateTextStyles.caption.copyWith(
                color: colors.muted,
              ),
            ),
          ],
          if (note != null && note.isNotEmpty) ...[
            const SizedBox(height: IntermediateSpacing.s2xs),
            Text(
              note,
              style: IntermediateTextStyles.captionSm.copyWith(
                color: dimmed,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 共用批注折叠区（允许/拒绝共用，P1：随处置下发，留空不发送）
  Widget _buildCommentSection(LmPalette colors, Translations t) {
    final s = t.advanced.approval;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 批注入口同变更明细——裸文本行升为浅底 chip
        Container(
          decoration: BoxDecoration(
            color: colors.surfaceVariant,
            borderRadius: BorderRadius.circular(
              context.lmUi.radius(LmCorner.xs),
            ),
            border: Border.all(color: colors.divider, width: 0.5),
          ),
          child: InkWell(
            borderRadius: BorderRadius.circular(
              context.lmUi.radius(LmCorner.xs),
            ),
            onTap: () {
              _resetCountdown();
              setState(() => _commentExpanded = !_commentExpanded);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: IntermediateSpacing.sXs,
                vertical: IntermediateSpacing.s2xs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.edit_note_outlined,
                    size: 16,
                    color: colors.primary,
                  ),
                  const SizedBox(width: IntermediateSpacing.s2xs),
                  Text(
                    s.commentEntry,
                    style: IntermediateTextStyles.label.copyWith(
                      color: colors.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_commentExpanded)
          Focus(
            onFocusChange: (_) => _resetCountdown(),
            child: TextField(
              controller: _commentController,
              maxLines: 3,
              minLines: 1,
              maxLength: _maxCommentLength,
              style: IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
              decoration: InputDecoration(
                isDense: true,
                counterText: '',
                hintText: s.commentHint,
                hintStyle: IntermediateTextStyles.captionSm.copyWith(
                  color: colors.muted,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(
                    context.lmUi.radius(LmCorner.xs),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final summaryData = widget.prompt.summaryData;
    // P4：merge_entities 永不进会话放行集——不显示「本会话总是允许」
    final isMerge = widget.prompt.toolName == 'merge_entities';

    // 卡框由 DirectorDecisionViewport 的 LmOverflowCard 统一提供
    // （背景/描边/滚动溢出提示），此处只出内容。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          header: true,
          liveRegion: true,
          child: Text(
            t.advanced.approval
                .title(tool: stageVerbOf(widget.prompt.toolName, t)),
            style: IntermediateTextStyles.label.copyWith(color: colors.warning),
          ),
        ),
        const SizedBox(height: IntermediateSpacing.sXs),
        _buildCountdownRow(colors, t),
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
          summaryData != null
              ? formatApprovalSummary(t, widget.prompt.toolName, summaryData)
              : widget.prompt.summary,
          style: IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
        ),
        const SizedBox(height: IntermediateSpacing.sXs),
        _buildChangesSection(colors, t),
        if (widget.prompt.pendingPriorChanges > 0) ...[
          const SizedBox(height: IntermediateSpacing.s2xs),
          Text(
            t.advanced.approval.pendingPriorFootnote(
              count: widget.prompt.pendingPriorChanges,
            ),
            style: IntermediateTextStyles.captionSm.copyWith(
              color: colors.muted,
            ),
          ),
        ],
        const SizedBox(height: IntermediateSpacing.sXs),
        _buildCommentSection(colors, t),
        const SizedBox(height: IntermediateSpacing.sSm),
        Wrap(
          alignment: WrapAlignment.end,
          spacing: IntermediateSpacing.sSm,
          runSpacing: IntermediateSpacing.sXs,
          children: [
            // 本会话总是允许（merge 不显示，P4；弱视觉位防误触——
            // 与「允许」同效果但叠加会话级放行记忆）
            if (!isMerge)
              TextButton(
                onPressed: () => widget.onResolve(allow: true, always: true),
                child: Text(
                  t.advanced.approval.alwaysAllow,
                  style: IntermediateTextStyles.caption.copyWith(
                    color: colors.primary,
                  ),
                ),
              ),
            FilledButton(
              // P1：批注非空时随批准信封下发
              onPressed: () =>
                  widget.onResolve(allow: true, feedback: _comment),
              style: FilledButton.styleFrom(
                backgroundColor: colors.primary,
                foregroundColor: colors.bg,
              ),
              child: Text(t.advanced.approval.allow),
            ),
            // P1 共用批注：拒绝一步直达（批注框内容即拒绝留言，
            // 空则纯拒绝——与旧「拒绝并留言」两步流程等价但少一跳）
            OutlinedButton(
              onPressed: () =>
                  widget.onResolve(allow: false, feedback: _comment),
              child: Text(t.advanced.approval.deny),
            ),
          ],
        ),
      ],
    );
  }
}
