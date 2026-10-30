import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/config_visibility.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/widgets/advanced_level_hint.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/auto_compaction_section.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/chat_default_model_section.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/display_preferences_section.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/global_generation_defaults_section.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 对话模式设置页（一级菜单：通用设置 → 对话模式设置）。
///
/// 内容顺序：默认模型 → 新对话默认生成参数 → 自动压缩 → 显示偏好。
/// 各 section 自带标题与说明，因此页面层仅以间距分隔，不再外包分组标题。
///
/// 组装层按配置显示模式过滤：简单模式保留默认模型与显示偏好，
/// 生成参数/自动压缩仅进阶模式渲染。过滤只动展示层，被隐藏区
/// 已有用户值继续生效。
class ChatSettingsPage extends ConsumerWidget {
  const ChatSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Translations.of(context);
    final level = ref.watch(configLevelProvider);

    final sections = <Widget>[
      if (ConfigVisibility.of(
        ConfigVisibilityKeys.chatDefaultModel,
        level,
      ))
        const ChatDefaultModelSection(),
      if (ConfigVisibility.of(
        ConfigVisibilityKeys.chatGenerationDefaults,
        level,
      ))
        const GlobalGenerationDefaultsSection(),
      if (ConfigVisibility.of(
        ConfigVisibilityKeys.chatAutoCompaction,
        level,
      ))
        const AutoCompactionSection(),
      if (ConfigVisibility.of(
        ConfigVisibilityKeys.chatDisplayPreferences,
        level,
      ))
        const DisplayPreferencesSection(),
    ];

    return Scaffold(
      backgroundColor:
          context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
      appBar:
          context.lmUi.appBar(context, title: t.settings.chatSettings.title),
      body: LmMeasure(
        child: ListView(
          padding: const EdgeInsets.all(SimpleSpacing.sLg),
          children: [
            for (var i = 0; i < sections.length; i++) ...[
              if (i > 0) const SizedBox(height: SimpleSpacing.sMd),
              sections[i],
            ],
            const AdvancedLevelHint(
              surfaceId: ConfigVisibilitySurfaces.chatSettings,
            ),
          ],
        ),
      ),
    );
  }
}
