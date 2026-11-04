import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 自动重试设置区块（2026-10-15 批 E / P5、P6）。
///
/// 次数上限（0-5）+ 累计等待预算（0=不限/30-300s）——三模式共享底座
/// （导演/故事各有阶段粒度覆盖项，simple 消费本值；判定/退避单源在
/// 共享 RetryPolicy）。样式对齐 TimeoutSection。
class AutoRetrySection extends ConsumerWidget {
  const AutoRetrySection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final maxAttempts = ref.watch(
      settingsNotifierProvider.select((s) => s.autoRetryMaxAttempts),
    );
    final waitBudgetSec = ref.watch(
      settingsNotifierProvider.select((s) => s.autoRetryWaitBudgetSec),
    );

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: Column(
        children: [
          _RetryValueRow(
            title: t.settings.general.autoRetryMaxAttempts,
            subtitle: t.settings.general.autoRetryMaxAttemptsDesc,
            valueLabel: maxAttempts == 0
                ? t.settings.general.autoRetryOff
                : '$maxAttempts',
            onDecrement: maxAttempts > 0
                ? () => ref
                    .read(settingsNotifierProvider.notifier)
                    .setAutoRetryMaxAttempts(maxAttempts - 1)
                : null,
            onIncrement: maxAttempts < 5
                ? () => ref
                    .read(settingsNotifierProvider.notifier)
                    .setAutoRetryMaxAttempts(maxAttempts + 1)
                : null,
            colors: colors,
          ),
          Divider(height: 1, color: colors.divider, indent: SimpleSpacing.sLg),
          _RetryValueRow(
            title: t.settings.general.autoRetryWaitBudget,
            subtitle: t.settings.general.autoRetryWaitBudgetDesc,
            valueLabel: waitBudgetSec == 0
                ? t.settings.general.autoRetryBudgetUnlimited
                : t.settings.general.autoRetryBudgetSeconds(
                    seconds: waitBudgetSec,
                  ),
            onDecrement: waitBudgetSec > 0
                ? () => ref
                    .read(settingsNotifierProvider.notifier)
                    .setAutoRetryWaitBudgetSec(
                      waitBudgetSec >= 45 ? waitBudgetSec - 30 : 0,
                    )
                : null,
            onIncrement: waitBudgetSec < 300
                ? () => ref
                    .read(settingsNotifierProvider.notifier)
                    .setAutoRetryWaitBudgetSec(
                      waitBudgetSec == 0 ? 30 : waitBudgetSec + 30,
                    )
                : null,
            colors: colors,
          ),
        ],
      ),
    );
  }
}

/// 单行数值项：标题 + 副标题 + 当前值 + 步进按钮（对齐 slider 区风格）。
class _RetryValueRow extends StatelessWidget {
  const _RetryValueRow({
    required this.title,
    required this.subtitle,
    required this.valueLabel,
    required this.colors,
    this.onDecrement,
    this.onIncrement,
  });

  final String title;
  final String subtitle;
  final String valueLabel;
  final VoidCallback? onDecrement;
  final VoidCallback? onIncrement;
  final LmPalette colors;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SimpleSpacing.sLg,
        SimpleSpacing.sMd,
        SimpleSpacing.sLg,
        SimpleSpacing.sMd,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: SimpleTextStyles.body.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: SimpleTextStyles.caption,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Text(
            valueLabel,
            style: SimpleTextStyles.caption.copyWith(
              color: colors.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
          IconButton(
            onPressed: onDecrement,
            icon: const Icon(Icons.remove, size: 18),
            color: colors.primary,
          ),
          IconButton(
            onPressed: onIncrement,
            icon: const Icon(Icons.add, size: 18),
            color: colors.primary,
          ),
        ],
      ),
    );
  }
}
