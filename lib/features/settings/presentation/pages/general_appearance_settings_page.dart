import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/config_visibility.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/content_width_selector_section.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/font_size_selector_section.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/palette_selector_section.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/structure_selector_section.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/theme_selector_section.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 通用设置 — 外观子页（2026-07-19 子页化重构）。
///
/// 包含：主题结构 + 配色 + 主题模式 + 字体大小（三轴选择器 + 字号，
/// 2026-07-19 子页化重构，轴选择器 2026-09-20 扩轴）。从原
/// `GeneralSettingsPage` 扁平布局拆出，
/// 配合顶层 4 张分类卡片（供应商 / 外观 / 语言与输入 / 高级）的子页化重构。
///
/// 结构无变化面（配置双模式）：全部区域为 simple 声明键，双模式恒显，
/// 过滤门仅作表↔代码对账锚点；WS1 新外观键落地后按分类表 §三
/// 预登记自动可见。
class GeneralAppearanceSettingsPage extends ConsumerWidget {
  const GeneralAppearanceSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Translations.of(context);
    final level = ref.watch(configLevelProvider);

    return Scaffold(
      backgroundColor:
          context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
      appBar: context.lmUi.appBar(
        context,
        title: t.settings.general.categories.appearance.title,
      ),
      body: LmMeasure(
        child: ListView(
          padding: const EdgeInsets.all(SimpleSpacing.sLg),
          children: [
            if (ConfigVisibility.of(
              ConfigVisibilityKeys.appearanceStructure,
              level,
            )) ...[
              context.lmUi.settingSection(
                context,
                title: t.settings.general.structure,
                child: const StructureSelectorSection(),
              ),
              const SizedBox(height: SimpleSpacing.sLg),
            ],
            if (ConfigVisibility.of(
              ConfigVisibilityKeys.appearancePalette,
              level,
            )) ...[
              context.lmUi.settingSection(
                context,
                title: t.settings.general.palette,
                child: const PaletteSelectorSection(),
              ),
              const SizedBox(height: SimpleSpacing.sLg),
            ],
            if (ConfigVisibility.of(
              ConfigVisibilityKeys.appearanceThemeMode,
              level,
            ))
              context.lmUi.settingSection(
                context,
                title: t.settings.general.theme,
                child: const ThemeSelectorSection(),
              ),
            const SizedBox(height: SimpleSpacing.sLg),
            if (ConfigVisibility.of(
              ConfigVisibilityKeys.appearanceFontSize,
              level,
            ))
              context.lmUi.settingSection(
                context,
                title: t.settings.general.fontSize,
                child: const FontSizeSelectorSection(),
              ),
            const SizedBox(height: SimpleSpacing.sLg),
            if (ConfigVisibility.of(
              ConfigVisibilityKeys.appearanceContentWidth,
              level,
            ))
              context.lmUi.settingSection(
                context,
                title: t.settings.general.contentWidth,
                child: const ContentWidthSelectorSection(),
              ),
          ],
        ),
      ),
    );
  }
}
