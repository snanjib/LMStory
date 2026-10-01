import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/components/simple_selection_option.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 语言选择区块。
///
/// zh-CN 与 en-US 可选；跟随系统项保持 disabled 占位预告。
class LanguageSelectorSection extends ConsumerWidget {
  const LanguageSelectorSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final currentLocale = ref.watch(localeProvider);

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: Column(
        children: [
          SimpleSelectionOption(
            label: t.settings.general.languageOptions.zhCn,
            isSelected: currentLocale == AppLocale.zhCn,
            onTap: () =>
                ref.read(localeProvider.notifier).switchLocale(AppLocale.zhCn),
          ),
          SimpleSelectionOption(
            label: t.settings.general.languageOptions.enUs,
            isSelected: currentLocale == AppLocale.enUs,
            onTap: () =>
                ref.read(localeProvider.notifier).switchLocale(AppLocale.enUs),
          ),
          SimpleSelectionOption(
            label: t.settings.general.languageOptions.system,
            isSelected: false,
            isEnabled: false,
            disabledLabel: t.settings.general.languageOptions.comingSoon,
            onTap: () {},
          ),
        ],
      ),
    );
  }
}
