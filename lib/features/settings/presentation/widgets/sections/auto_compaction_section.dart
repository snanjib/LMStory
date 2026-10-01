import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/widgets/commit_slider.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 自动压缩区块：开关 + 阈值滑块。
///
/// 开启时显示压缩阈值滑块（40%-90%），关闭时仅显示开关行。
/// 持久化于 `broadcast_chat.auto_compaction` 与
/// `broadcast_chat.compaction_threshold`。
class AutoCompactionSection extends ConsumerWidget {
  const AutoCompactionSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lm.palette;
    final enabled = ref.watch(
      settingsNotifierProvider.select((s) => s.autoCompaction),
    );
    final threshold = ref.watch(
      settingsNotifierProvider.select((s) => s.compactionThreshold),
    );
    final t = Translations.of(context);

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(SimpleSpacing.sLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            MergeSemantics(
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.settings.chatSettings.autoCompaction,
                          style: SimpleTextStyles.body.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          t.settings.chatSettings.autoCompactionDesc,
                          style: SimpleTextStyles.caption,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Switch(
                    value: enabled,
                    onChanged: (value) => ref
                        .read(settingsNotifierProvider.notifier)
                        .setAutoCompaction(value),
                    activeThumbColor: colors.primary,
                    activeTrackColor: colors.primary.withValues(alpha: 0.5),
                  ),
                ],
              ),
            ),
            if (enabled) ...[
              const SizedBox(height: SimpleSpacing.sMd),
              Divider(height: 1, color: colors.divider),
              const SizedBox(height: SimpleSpacing.sMd),
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.settings.chatSettings.compactionThreshold,
                          style: SimpleTextStyles.body.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          t.settings.chatSettings.compactionThresholdDesc,
                          style: SimpleTextStyles.caption,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: SimpleSpacing.sSm),
                  Text(
                    '${(threshold * 100).round()}%',
                    style: SimpleTextStyles.caption.copyWith(
                      color: colors.primary,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
              const SizedBox(height: SimpleSpacing.sXs),
              CommitSlider(
                value: threshold,
                min: 0.4,
                max: 0.9,
                divisions: 10,
                activeColor: colors.primary,
                inactiveColor: colors.primaryDim,
                labelBuilder: (value) => '${(value * 100).round()}%',
                onCommit: (value) => ref
                    .read(settingsNotifierProvider.notifier)
                    .setCompactionThreshold(value),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
