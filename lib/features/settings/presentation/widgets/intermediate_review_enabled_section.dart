import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/settings/presentation/widgets/intermediate_json_mode_section.dart'
    show IntermediateJsonModeSection;
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式设置 — 审查全局开关（夜航主题）。
///
/// 控制 `intermediate.reviewEnabled` 配置项：
/// - false（默认）：生成即最终，跳过 reviewing 阶段，3 次 LLM 调用
/// - true：增加 reviewing 阶段做审查修正，4 次 LLM 调用
///
/// 持久化：SettingsRepository.user_overrides
/// - `intermediate.reviewEnabled`
///
/// 交互模式：即时持久化（switch 变更即保存），与 [IntermediateJsonModeSection]
/// 一致——因为开关是离散状态。
///
/// 会话级覆盖：本开关仅控制全局默认值，单会话可在会话设置面板中
/// 覆盖（`ChatSession.reviewEnabledOverride`）。
///
/// 视觉与交互复刻 [IntermediateJsonModeSection]：surface 卡片 + Material 宿主
/// 避免 ink splash 警告。
class IntermediateReviewEnabledSection extends ConsumerWidget {
  const IntermediateReviewEnabledSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configAsync = ref.watch(intermediateConfigProvider);
    final config = configAsync.valueOrNull;
    final colors = context.lm.palette;
    final t = Translations.of(context);

    final isReviewEnabled = config?.reviewEnabled ?? false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.settings.intermediate.reviewEnabled,
          style: IntermediateTextStyles.title.copyWith(color: colors.ink),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: IntermediateSpacing.s2xs),
        Text(
          t.settings.intermediate.reviewEnabledDesc,
          style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: IntermediateSpacing.sMd),
        Material(
          color: colors.surface,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
          child: Padding(
            padding: const EdgeInsets.all(IntermediateSpacing.sLg),
            child: SwitchListTile(
              title: Text(
                t.settings.intermediate.reviewEnabledToggle,
                style:
                    IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                isReviewEnabled
                    ? t.settings.intermediate.reviewEnabledOnHint
                    : t.settings.intermediate.reviewEnabledOffHint,
                style: IntermediateTextStyles.caption
                    .copyWith(color: colors.faint),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              value: isReviewEnabled,
              activeThumbColor: colors.primary,
              contentPadding: EdgeInsets.zero,
              onChanged: configAsync.isLoading
                  ? null
                  : (value) => _onChanged(ref, value),
            ),
          ),
        ),
      ],
    );
  }

  /// 切换审查开关：持久化 user_overrides key
  ///
  /// 始终显式写入 true/false（与 [IntermediateJsonModeSection._onChanged] 同理），
  /// 不依赖 removeUserOverride 回落默认值——default_config.json 中 reviewEnabled
  /// 默认为 false，若开启时用 removeUserOverride 会回落到 false，导致开关关不掉。
  Future<void> _onChanged(WidgetRef ref, bool value) async {
    final repo = ref.read(settingsRepositoryProvider);
    await repo.setUserOverride('intermediate.reviewEnabled', value);
    ref.invalidate(intermediateConfigProvider);
  }
}
