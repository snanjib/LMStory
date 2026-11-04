import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/config_visibility.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 简单模式下挂在「含进阶专属配置」面尾部的引导行。
///
/// 显隐单源 [ConfigVisibility.surfaceHasAdvancedEntries]：当前为进阶
/// 模式、面未声明或声明键中无 advanced 级条目时渲染为空，接线方
/// 无需自行判定。文案指向配置显示模式开关（设置 → 通用设置页底）。
class AdvancedLevelHint extends ConsumerWidget {
  const AdvancedLevelHint({required this.surfaceId, super.key});

  /// 过滤面 id（[ConfigVisibilitySurfaces] 常量）。
  final String surfaceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final level = ref.watch(configLevelProvider);
    if (level != ConfigLevel.simple ||
        !ConfigVisibility.surfaceHasAdvancedEntries(surfaceId)) {
      return const SizedBox.shrink();
    }
    final colors = context.lm.palette;

    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: SimpleSpacing.sSm),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.tune, size: 14, color: colors.muted),
            const SizedBox(width: SimpleSpacing.sXs),
            Flexible(
              child: Text(
                Translations.of(context).settings.general.advancedLevelHint,
                style: SimpleTextStyles.caption.copyWith(
                  color: colors.muted,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
