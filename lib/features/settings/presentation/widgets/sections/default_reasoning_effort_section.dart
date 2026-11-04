import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 默认推理强度选择区块。
///
/// 5 档：未配置 / 禁用 / 低 / 中 / 高。仅对新会话生效，会话级设置可覆盖。
/// 仅对具备 reasoning 能力的模型生效。
class DefaultReasoningEffortSection extends ConsumerWidget {
  const DefaultReasoningEffortSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final current = ref.watch(
      settingsNotifierProvider.select((s) => s.defaultReasoningEffort),
    );

    final options = <(String, ReasoningEffort?, bool)>[
      (
        t.settings.general.defaultReasoningEffortOptions.notSet,
        null,
        current == null,
      ),
      (
        t.settings.general.defaultReasoningEffortOptions.disabled,
        ReasoningEffort.disabled,
        current == ReasoningEffort.disabled,
      ),
      (
        t.settings.general.defaultReasoningEffortOptions.low,
        ReasoningEffort.low,
        current == ReasoningEffort.low,
      ),
      (
        t.settings.general.defaultReasoningEffortOptions.medium,
        ReasoningEffort.medium,
        current == ReasoningEffort.medium,
      ),
      (
        t.settings.general.defaultReasoningEffortOptions.high,
        ReasoningEffort.high,
        current == ReasoningEffort.high,
      ),
    ];

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: Column(
        children: [
          // 术语「思考预算」对新手不可懂——区块顶部补
          // 是什么/档位差异/影响范围说明（写法对齐响应超时的人话说明）
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SimpleSpacing.sLg,
              SimpleSpacing.sMd,
              SimpleSpacing.sLg,
              SimpleSpacing.sXs,
            ),
            child: Text(
              t.settings.general.defaultReasoningEffortDesc,
              style: SimpleTextStyles.caption.copyWith(color: colors.muted),
            ),
          ),
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                color: colors.divider,
                indent: SimpleSpacing.sLg,
              ),
            context.lmUi.selectionOption(
              context,
              label: options[i].$1,
              isSelected: options[i].$3,
              onTap: () => ref
                  .read(settingsNotifierProvider.notifier)
                  .setDefaultReasoningEffort(options[i].$2),
            ),
          ],
        ],
      ),
    );
  }
}
