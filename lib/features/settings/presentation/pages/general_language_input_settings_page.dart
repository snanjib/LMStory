import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/config_visibility.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/components/simple_app_bar.dart';
import 'package:lmstory/core/theme/simple/components/simple_setting_section.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/language_selector_section.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/send_key_selector_section.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 通用设置 - 语言与输入子页（2026-07-19 子页化重构）。
///
/// 包含：界面语言 + 发送快捷键。从原 `GeneralSettingsPage` 扁平布局拆出，
/// 配合顶层 4 张分类卡片（供应商 / 外观 / 语言与输入 / 高级）的子页化重构。
///
/// 发送快捷键在所有平台显示；Ctrl+Enter 选项由 `SendKeySelectorSection`
/// 内部按平台隐藏（移动端键盘无 Ctrl 键）。
///
/// 结构无变化面（配置双模式）：全部区域为 simple 声明键，双模式恒显，
/// 过滤门仅作表↔代码对账锚点。
class GeneralLanguageInputSettingsPage extends ConsumerWidget {
  const GeneralLanguageInputSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Translations.of(context);
    final level = ref.watch(configLevelProvider);

    return Scaffold(
      backgroundColor:
          context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
      appBar: SimpleAppBar(
        title: t.settings.general.categories.languageInput.title,
      ),
      body: LmMeasure(
        child: ListView(
          padding: const EdgeInsets.all(SimpleSpacing.sLg),
          children: [
            if (ConfigVisibility.of(
              ConfigVisibilityKeys.languageUiLanguage,
              level,
            ))
              SimpleSettingSection(
                title: t.settings.general.language,
                child: const LanguageSelectorSection(),
              ),
            const SizedBox(height: SimpleSpacing.sLg),
            if (ConfigVisibility.of(
              ConfigVisibilityKeys.languageSendKey,
              level,
            ))
              SimpleSettingSection(
                title: t.settings.general.sendKey,
                child: const SendKeySelectorSection(),
              ),
          ],
        ),
      ),
    );
  }
}
