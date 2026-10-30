import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/pages/general_advanced_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/general_appearance_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/general_language_input_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/provider_list_page.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/config_display_mode_section.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 通用设置页（2026-07-19 子页化重构）。
///
/// 顶层 4 张分类卡片：
/// 1. 供应商（直接跳转 `ProviderListPage`，已是独立页）
/// 2. 外观（主题 + 字体大小）→ `GeneralAppearanceSettingsPage`
/// 3. 语言与输入（界面语言 + 发送快捷键）→ `GeneralLanguageInputSettingsPage`
/// 4. 高级（默认思考预算 + 超时设置）→ `GeneralAdvancedSettingsPage`
///
/// 重构动机：用户反馈"故事模式设置点开后很乱很长，需要像手机系统设置那样
/// 醒目标题严格分区，让用户一眼找到自己想调整的配置"。统一所有设置页
/// 为分类卡片 + 子页模式（iOS/Android 系统设置风格）。
class GeneralSettingsPage extends ConsumerWidget {
  const GeneralSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Translations.of(context);
    final presetCount = ref.watch(
      settingsNotifierProvider.select((s) => s.presets.length),
    );

    return Scaffold(
      backgroundColor:
          context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
      appBar: context.lmUi.appBar(context, title: t.settings.general.title),
      body: LmMeasure(
        child: ListView(
          padding: const EdgeInsets.all(SimpleSpacing.sLg),
          children: [
            // 1. 供应商（直接跳转 ProviderListPage）
            context.lmUi.settingCard(
              context,
              icon: Icons.dns_outlined,
              title: t.settings.provider.title,
              subtitle: t.settings.provider.entrySubtitle(
                n: presetCount,
                count: presetCount,
              ),
              onTap: () => _push(context, const ProviderListPage()),
            ),
            const SizedBox(height: SimpleSpacing.sMd),
            // 2. 外观
            context.lmUi.settingCard(
              context,
              icon: Icons.palette_outlined,
              title: t.settings.general.categories.appearance.title,
              subtitle: t.settings.general.categories.appearance.subtitle,
              onTap: () => _push(
                context,
                const GeneralAppearanceSettingsPage(),
              ),
            ),
            const SizedBox(height: SimpleSpacing.sMd),
            // 3. 语言与输入
            context.lmUi.settingCard(
              context,
              icon: Icons.language_outlined,
              title: t.settings.general.categories.languageInput.title,
              subtitle: t.settings.general.categories.languageInput.subtitle,
              onTap: () => _push(
                context,
                const GeneralLanguageInputSettingsPage(),
              ),
            ),
            const SizedBox(height: SimpleSpacing.sMd),
            // 4. 高级
            context.lmUi.settingCard(
              context,
              icon: Icons.tune_outlined,
              title: t.settings.general.categories.advanced.title,
              subtitle: t.settings.general.categories.advanced.subtitle,
              onTap: () => _push(context, const GeneralAdvancedSettingsPage()),
            ),
            const SizedBox(height: SimpleSpacing.sLg),
            // 配置显示模式（跨页元配置，双模式恒显；页底内联区块与
            // 4 张页面对象分类卡形成视觉分层）
            context.lmUi.settingSection(
              context,
              title: t.settings.general.configDisplayMode.title,
              child: const ConfigDisplayModeSection(),
            ),
          ],
        ),
      ),
    );
  }

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }
}
