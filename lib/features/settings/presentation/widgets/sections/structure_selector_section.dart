import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/appearance_controller.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_selection_option.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 主题结构选择区块（「界面长什么样」轴）。
///
/// 选项读 [ThemeCatalog.structures] 注册表（catalog 驱动，新增结构零 UI 改动），
/// 显示名经 slang 动态键解析；切换即时生效并持久化。
class StructureSelectorSection extends ConsumerWidget {
  const StructureSelectorSection({super.key});

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
          for (final entry in ThemeCatalog.structures)
            SimpleSelectionOption(
              label: t[entry.nameKey] as String,
              isSelected: appearance.structureId == entry.id,
              onTap: () => ref.read(appearanceProvider.notifier).setAppearance(
                    appearance.copyWith(structureId: entry.id),
                  ),
            ),
        ],
      ),
    );
  }
}
