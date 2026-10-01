import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/components/simple_selection_option.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/theme_controller.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 主题模式选择区块（深色 / 浅色 / 跟随系统）。
///
/// 直连 [themeModeProvider]，切换即时生效并持久化。
class ThemeSelectorSection extends ConsumerWidget {
  const ThemeSelectorSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final themeMode = ref.watch(themeModeProvider);

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: Column(
        children: [
          SimpleSelectionOption(
            label: t.settings.general.themeOptions.dark,
            isSelected: themeMode == ThemeMode.dark,
            onTap: () => ref
                .read(themeModeProvider.notifier)
                .setThemeMode(ThemeMode.dark),
          ),
          SimpleSelectionOption(
            label: t.settings.general.themeOptions.light,
            isSelected: themeMode == ThemeMode.light,
            onTap: () => ref
                .read(themeModeProvider.notifier)
                .setThemeMode(ThemeMode.light),
          ),
          SimpleSelectionOption(
            label: t.settings.general.themeOptions.system,
            isSelected: themeMode == ThemeMode.system,
            onTap: () => ref
                .read(themeModeProvider.notifier)
                .setThemeMode(ThemeMode.system),
          ),
        ],
      ),
    );
  }
}
