import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 内容宽度模式选择（通用设置-外观）：流式（随窗口放大，默认）/
/// 固定上限（超宽屏不拉长）。切换即时生效（顶层 scope 下发全树）。
class ContentWidthSelectorSection extends ConsumerWidget {
  const ContentWidthSelectorSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final mode = ref.watch(
      settingsNotifierProvider.select((s) => s.contentWidthMode),
    );

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: Column(
        children: [
          context.lmUi.selectionOption(
            context,
            label: t.settings.general.contentWidthOptions.fluid,
            isSelected: mode == LmContentWidthMode.fluid,
            onTap: () => ref
                .read(settingsNotifierProvider.notifier)
                .setContentWidthMode(LmContentWidthMode.fluid),
          ),
          context.lmUi.selectionOption(
            context,
            label: t.settings.general.contentWidthOptions.capped,
            isSelected: mode == LmContentWidthMode.capped,
            onTap: () => ref
                .read(settingsNotifierProvider.notifier)
                .setContentWidthMode(LmContentWidthMode.capped),
          ),
        ],
      ),
    );
  }
}
