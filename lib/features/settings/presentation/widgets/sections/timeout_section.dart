import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/widgets/commit_slider.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 超时设置区块（连接超时 + 响应超时）。
///
/// 两个 slider 项纵向排列于 surfaceVariant 圆角容器内，中间用 divider 分隔。
class TimeoutSection extends ConsumerWidget {
  const TimeoutSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    // 仅订阅超时配置切片：其它设置字段变更不触发本节重建
    final connectTimeout = ref.watch(
      settingsNotifierProvider.select((s) => s.connectTimeoutSec),
    );
    final receiveTimeout = ref.watch(
      settingsNotifierProvider.select((s) => s.receiveTimeoutSec),
    );

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: Column(
        children: [
          _TimeoutSliderItem(
            title: t.settings.general.connectTimeout,
            subtitle: t.settings.general.connectTimeoutDesc,
            value: connectTimeout,
            min: 5,
            max: 60,
            unit: t.settings.general.timeoutUnit,
            onChanged: (v) => ref
                .read(settingsNotifierProvider.notifier)
                .setConnectTimeoutSec(v.round()),
            colors: colors,
          ),
          Divider(height: 1, color: colors.divider, indent: SimpleSpacing.sLg),
          _TimeoutSliderItem(
            title: t.settings.general.receiveTimeout,
            subtitle: t.settings.general.receiveTimeoutDesc,
            value: receiveTimeout,
            min: 10,
            max: 300,
            unit: t.settings.general.timeoutUnit,
            onChanged: (v) => ref
                .read(settingsNotifierProvider.notifier)
                .setReceiveTimeoutSec(v.round()),
            colors: colors,
          ),
        ],
      ),
    );
  }
}

/// 单个超时 slider 项：标题 + 副标题 + 当前值 + slider。
class _TimeoutSliderItem extends StatelessWidget {
  const _TimeoutSliderItem({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    required this.unit,
    required this.onChanged,
    required this.colors,
  });

  final String title;
  final String subtitle;
  final int value;
  final int min;
  final int max;
  final String unit;
  final ValueChanged<double> onChanged;
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
                const SizedBox(height: SimpleSpacing.sXs),
                Text(
                  '$value $unit',
                  style: SimpleTextStyles.caption.copyWith(
                    color: colors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: CommitSlider(
              value: value.toDouble(),
              min: min.toDouble(),
              max: max.toDouble(),
              divisions: max - min,
              onCommit: onChanged,
              activeColor: colors.primary,
            ),
          ),
        ],
      ),
    );
  }
}
