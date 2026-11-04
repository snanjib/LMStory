import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_settings_page.dart'
    show IntermediateSettingsPage;
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式设置 — 使用帮助子页（2026-07-19 子页化重构）。
///
/// 从原 [IntermediateSettingsPage] 的 _HelperSection 抽出。
/// 展示 5 条配置说明要点（默认模型/嵌入模型/工具调用/四步生成/会话覆盖）。
///
/// 从 [IntermediateSettingsPage] 顶层分类卡片进入。
class IntermediateHelpSettingsPage extends StatelessWidget {
  const IntermediateHelpSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    final bullets = [
      t.settings.intermediate.systemPromptHelperBullet1,
      t.settings.intermediate.systemPromptHelperBullet2,
      t.settings.intermediate.systemPromptHelperBullet3,
      t.settings.intermediate.systemPromptHelperBullet4,
      t.settings.intermediate.systemPromptHelperBullet5,
    ];

    return Scaffold(
      backgroundColor:
          context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
      appBar: AppBar(
        title: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            t.settings.intermediate.categories.help.title,
            style: IntermediateTextStyles.title.copyWith(color: colors.ink),
          ),
        ),
        backgroundColor:
            context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
        foregroundColor: colors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      body: LmMeasure(
        child: ListView(
          padding: const EdgeInsets.all(IntermediateSpacing.sLg),
          children: [
            Container(
              padding: const EdgeInsets.all(IntermediateSpacing.sLg),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius:
                    BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.settings.intermediate.systemPromptHelperTitle,
                    style: IntermediateTextStyles.label
                        .copyWith(color: colors.ink),
                  ),
                  const SizedBox(height: IntermediateSpacing.sSm),
                  ...bullets.map(
                    (b) => Padding(
                      padding: const EdgeInsets.only(
                        bottom: IntermediateSpacing.s2xs,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(
                              top: 6,
                              right: IntermediateSpacing.sSm,
                            ),
                            child: Container(
                              width: 4,
                              height: 4,
                              decoration: BoxDecoration(
                                color: colors.primary,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              b,
                              style: IntermediateTextStyles.caption
                                  .copyWith(color: colors.muted, height: 1.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
