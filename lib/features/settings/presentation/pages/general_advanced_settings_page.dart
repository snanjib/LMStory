import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/config_visibility.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/components/simple_app_bar.dart';
import 'package:lmstory/core/theme/simple/components/simple_setting_section.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/default_reasoning_effort_section.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/timeout_section.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/title_model_section.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 通用设置 — 高级子页（2026-07-19 子页化重构）。
///
/// 包含：默认思考预算 + 超时设置（连接超时 + 响应超时）+ 会话标题模型。
/// 从原 `GeneralSettingsPage` 扁平布局拆出，配合顶层 4 张分类卡片
/// （供应商 / 外观 / 语言与输入 / 高级）的子页化重构。
///
/// 2026-07-21 新增"会话标题模型"区段：独立于业务模式的工具配置，
/// 用于所有模式的会话标题自动生成。未配置先回落生成模型起标题，仍失败才前缀兜底。
///
/// 组装层按配置显示模式过滤：简单模式保留默认思考预算（成本旋钮），
/// 超时/会话标题模型仅进阶模式渲染。过滤只动展示层，被隐藏区
/// 已有用户值继续生效。
class GeneralAdvancedSettingsPage extends ConsumerWidget {
  const GeneralAdvancedSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = Translations.of(context);
    final level = ref.watch(configLevelProvider);

    final sections = <Widget>[
      if (ConfigVisibility.of(
        ConfigVisibilityKeys.generalAdvancedReasoningEffort,
        level,
      ))
        SimpleSettingSection(
          title: t.settings.general.defaultReasoningEffort,
          child: const DefaultReasoningEffortSection(),
        ),
      if (ConfigVisibility.of(
        ConfigVisibilityKeys.generalAdvancedTimeout,
        level,
      ))
        SimpleSettingSection(
          title: t.settings.general.timeout,
          child: const TimeoutSection(),
        ),
      if (ConfigVisibility.of(
        ConfigVisibilityKeys.generalAdvancedTitleModel,
        level,
      ))
        SimpleSettingSection(
          title: t.settings.general.titleModel,
          child: const TitleModelSection(),
        ),
    ];

    return Scaffold(
      backgroundColor:
          context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
      appBar: SimpleAppBar(title: t.settings.general.categories.advanced.title),
      body: LmMeasure(
        child: ListView(
          padding: const EdgeInsets.all(SimpleSpacing.sLg),
          children: [
            for (var i = 0; i < sections.length; i++) ...[
              if (i > 0) const SizedBox(height: SimpleSpacing.sLg),
              sections[i],
            ],
          ],
        ),
      ),
    );
  }
}
