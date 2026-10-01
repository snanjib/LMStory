import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/components/simple_selection_option.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 配置显示模式区块（简单模式 / 进阶模式二选一）。
///
/// 跨页元配置开关，双模式下恒显（简单模式可见性前提）；
/// 切换即时生效并持久化，无需重启，驱动全部过滤面重建。
class ConfigDisplayModeSection extends ConsumerWidget {
  const ConfigDisplayModeSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final level = ref.watch(configLevelProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.settings.general.configDisplayMode.desc,
          style: SimpleTextStyles.caption.copyWith(color: colors.muted),
        ),
        const SizedBox(height: SimpleSpacing.sSm),
        Container(
          decoration: BoxDecoration(
            color: colors.surfaceVariant,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
          ),
          child: Column(
            children: [
              SimpleSelectionOption(
                label: t.settings.general.configDisplayMode.simple,
                isSelected: level == ConfigLevel.simple,
                onTap: () => ref
                    .read(configLevelProvider.notifier)
                    .setLevel(ConfigLevel.simple),
              ),
              SimpleSelectionOption(
                label: t.settings.general.configDisplayMode.advanced,
                isSelected: level == ConfigLevel.advanced,
                onTap: () => ref
                    .read(configLevelProvider.notifier)
                    .setLevel(ConfigLevel.advanced),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
