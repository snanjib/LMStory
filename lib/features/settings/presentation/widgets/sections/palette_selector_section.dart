import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/appearance_controller.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 配色族选择区块（「用什么配色」轴）。
///
/// 选项读 [ThemeCatalog.palettes] 注册表，与主题结构自由组合（两选择器分开）；
/// 切换即时生效并持久化。
class PaletteSelectorSection extends ConsumerWidget {
  const PaletteSelectorSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final appearance = ref.watch(appearanceProvider);

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: Column(
        children: [
          for (final entry in ThemeCatalog.palettes)
            context.lmUi.selectionOption(
              context,
              label: t[entry.nameKey] as String,
              isSelected: appearance.paletteId == entry.id,
              onTap: () => ref.read(appearanceProvider.notifier).setAppearance(
                    appearance.copyWith(paletteId: entry.id),
                  ),
            ),
        ],
      ),
    );
  }
}
