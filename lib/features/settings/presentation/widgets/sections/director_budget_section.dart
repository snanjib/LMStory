import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/director_setting_rows.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 导演设置 — 运行与预算分区（导演设置）。
///
/// 键：advanced.defaults.max_steps、advanced.budget.*（时长/重试）；
/// 高级子折叠（ExpansionTile）：advanced.doom_loop.threshold、
/// advanced.hitl.*（ask_user/审批双超时）、advanced.subagent.*（步数/时长）。
/// 全部即时持久化；数值点按可输入。
///
/// 2026-09-13 上下文配置收敛：移除「单轮 Token 预算比例」行——它是
/// "花了多少"的计费口径而非"装了多少"的上下文口径，键保留为引擎级
/// 高级覆盖入口（advanced.budget.token_budget_ratio，默认 0.6 继续生效，
/// 同 advanced.harness.* 哲学），不再占产品设置面。
class DirectorBudgetSection extends ConsumerWidget {
  const DirectorBudgetSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(advancedConfigProvider).valueOrNull;
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final b = t.settings.director.budget;

    final defaults = config?.defaults;
    final budget = config?.budget;
    final doomLoop = config?.doomLoop;
    final hitl = config?.hitl;
    final subagent = config?.subagent;
    // 帮助文案承诺的 harness 写点
    final harness = config?.harness;

    return Column(
      children: [
        // ── 常规预算 ────────────────────────────────────────────
        DirectorStepperRow(
          label: b.maxSteps,
          value: defaults?.maxSteps ?? 8,
          min: 0,
          max: 32,
          hint: b.maxStepsHint,
          valueLabel: (v) => v == 0 ? b.unlimited : v.toString(),
          onChanged: (v) =>
              writeDirectorOverride(ref, 'advanced.defaults.max_steps', v),
        ),
        directorSectionGap,
        DirectorStepperRow(
          label: b.maxDuration,
          value: budget?.maxDurationMinutes ?? 5,
          min: 1,
          max: 30,
          onChanged: (v) => writeDirectorOverride(
            ref,
            'advanced.budget.max_duration_minutes',
            v,
          ),
        ),
        directorSectionGap,
        DirectorStepperRow(
          label: b.maxRetries,
          value: budget?.maxRequestRetries ?? 1,
          min: 0,
          max: 5,
          onChanged: (v) => writeDirectorOverride(
            ref,
            'advanced.budget.max_request_retries',
            v,
          ),
        ),

        // ── 高级子折叠（低频调参项）─────────────────────────────
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: Text(
              b.advanced,
              style:
                  IntermediateTextStyles.label.copyWith(color: colors.primary),
            ),
            children: [
              DirectorStepperRow(
                label: b.doomLoop,
                // 装载窗口回退值跟随
                // 配置默认（后为 8）——此前硬编码 3 是  改默认
                // 前的残值，装载间隙显示/预填错基线
                value: doomLoop?.threshold ??
                    const AdvancedDoomLoopConfig().threshold,
                min: 2,
                max: 10,
                hint: b.doomLoopHint,
                onChanged: (v) => writeDirectorOverride(
                  ref,
                  'advanced.doom_loop.threshold',
                  v,
                ),
              ),
              directorSectionGap,
              DirectorStepperRow(
                label: b.askUserTimeout,
                value: hitl?.askUserTimeoutMinutes ?? 3,
                // 0 = 一直等待（对齐 maxSteps 0=无上限语义）
                min: 0,
                max: 30,
                hint: b.askUserTimeoutHint,
                valueLabel: (v) => v == 0 ? b.waitForever : v.toString(),
                onChanged: (v) => writeDirectorOverride(
                  ref,
                  'advanced.hitl.ask_user_timeout_minutes',
                  v,
                ),
              ),
              directorSectionGap,
              // P2 永等开关：同盖审批与提问两类 HITL 横幅；
              // 关闭 = 横幅永不超时一直等待（推翻 2026-08 旧口径，三道
              // 兜底不变）；开启时下方两个超时 stepper 生效
              _HitlTimeoutSwitchRow(
                enabled: hitl?.approvalTimeoutEnabled ?? true,
                minutes: hitl?.approvalTimeoutMinutes ?? 5,
              ),
              directorSectionGap,
              if (hitl?.approvalTimeoutEnabled ?? true) ...[
                DirectorStepperRow(
                  label: b.approvalTimeout,
                  value: hitl?.approvalTimeoutMinutes ?? 5,
                  min: 1,
                  max: 30,
                  hint: b.approvalTimeoutHint,
                  onChanged: (v) => writeDirectorOverride(
                    ref,
                    'advanced.hitl.approval_timeout_minutes',
                    v,
                  ),
                ),
                directorSectionGap,
              ],
              DirectorStepperRow(
                label: b.subagentMaxSteps,
                value: subagent?.maxSteps ?? 6,
                min: 1,
                max: 16,
                onChanged: (v) => writeDirectorOverride(
                  ref,
                  'advanced.subagent.max_steps',
                  v,
                ),
              ),
              directorSectionGap,
              DirectorStepperRow(
                label: b.subagentMaxDuration,
                value: subagent?.maxDurationMinutes ?? 2,
                min: 1,
                max: 10,
                onChanged: (v) => writeDirectorOverride(
                  ref,
                  'advanced.subagent.max_duration_minutes',
                  v,
                ),
              ),
              directorSectionGap,
              // 帮助文案「可在导演设置调整」的落地写点（此前无 UI 入口）
              DirectorStepperRow(
                label: b.foreshadowCheckInterval,
                value: harness?.foreshadowCheckInterval ?? 8,
                min: 0,
                max: 30,
                hint: b.foreshadowCheckIntervalHint,
                onChanged: (v) => writeDirectorOverride(
                  ref,
                  'advanced.harness.foreshadow_check_interval',
                  v,
                ),
              ),
              directorSectionGap,
              DirectorStepperRow(
                label: b.eventLogRetentionTurns,
                value: harness?.eventLogRetentionTurns ?? 20,
                min: 0,
                max: 200,
                onChanged: (v) => writeDirectorOverride(
                  ref,
                  'advanced.harness.event_log_retention_turns',
                  v,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// P2 永等开关行：文案仿 ZCode「提问自动继续」范式——
/// 开 = 「X 分钟未响应自动拒绝」（X 引当前配置值），关 = 「一直等待」。
class _HitlTimeoutSwitchRow extends ConsumerWidget {
  const _HitlTimeoutSwitchRow({
    required this.enabled,
    required this.minutes,
  });

  final bool enabled;
  final int minutes;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final b = t.settings.director.budget;

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                b.approvalTimeoutSwitch,
                style: IntermediateTextStyles.caption
                    .copyWith(color: colors.muted),
              ),
              Text(
                enabled
                    ? b.approvalTimeoutSwitchOn(minutes: minutes)
                    : b.approvalTimeoutSwitchOff,
                style: IntermediateTextStyles.captionSm.copyWith(
                  color: colors.faint,
                ),
              ),
            ],
          ),
        ),
        Switch(
          value: enabled,
          activeThumbColor: colors.primary,
          onChanged: (v) => writeDirectorOverride(
            ref,
            'advanced.hitl.approval_timeout_enabled',
            v,
          ),
        ),
      ],
    );
  }
}
