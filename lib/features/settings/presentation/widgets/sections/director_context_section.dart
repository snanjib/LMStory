import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/utils/token_format.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/collapsible_settings_section.dart';
import 'package:lmstory/features/settings/presentation/widgets/director_compaction_threshold_field.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/director_setting_rows.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/session_settings_fields.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 导演设置 — 上下文与压缩分区（上下文配置收敛 §2.1，2026-09-13）。
///
/// 主面单一旋钮：「上下文压缩阈值」（百分比⇄token 双显示，存储键沿用
/// advanced.contextBudget.compactionTriggerRatio）。故事三段式预算遗产键
///（原文区下限/检索区比例）的导演暴露面移除——导演无三段结构，检索走
/// 工具不靠注入区，组装侧已定死。
///
/// 窗口上限（advanced.context.effective_context_limit，0=自动哨兵）是
/// 分母修正器（模型窗口登记不准时的手动声明 / TPM 保护），降级进高级
/// 子折叠并披露当前生效窗口（方向）。
class DirectorContextSection extends ConsumerWidget {
  const DirectorContextSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(advancedConfigProvider).valueOrNull;
    final budget = config?.contextBudget;
    final colors = context.lm.palette;
    final t = Translations.of(context);
    // 分母：GM 模型窗口与窗口上限取小；解析中/失败回退默认窗口（96000）
    final effectiveWindow =
        ref.watch(advancedGlobalContextWindowProvider).valueOrNull ??
            ConfigurationResolver.defaultContextWindow;

    return Column(
      children: [
        // ── 上下文压缩阈值（唯一旋钮，双显示）───────────────────
        SettingsTile(
          child: DirectorCompactionThresholdField(
            ratio: budget?.compactionTriggerRatio ?? 0.5,
            effectiveWindow: effectiveWindow,
            onChanged: (v) => writeDirectorOverride(
              ref,
              'advanced.contextBudget.compactionTriggerRatio',
              v,
            ),
          ),
        ),
        directorSectionGap,

        // ── 高级子折叠：窗口上限（分母修正器，低频）─────────────
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: Text(
              t.settings.director.context.windowAdvanced,
              style:
                  IntermediateTextStyles.label.copyWith(color: colors.primary),
            ),
            children: [
              SettingsTile(
                child: IntermediateEffectiveContextLimitSlider(
                  value: config?.context.effectiveContextLimit,
                  onChanged: (v) => writeDirectorOverride(
                    ref,
                    'advanced.context.effective_context_limit',
                    v == 0 ? null : v,
                  ),
                  onReset: () => writeDirectorOverride(
                    ref,
                    'advanced.context.effective_context_limit',
                    null,
                  ),
                ),
              ),
              // 生效值披露：分母随 GM 模型与上限解析实时可见
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  t.settings.director.context.effectiveWindowCaption(
                    window: formatTokenCount(effectiveWindow),
                  ),
                  style: IntermediateTextStyles.caption.copyWith(
                    color: colors.faint,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
