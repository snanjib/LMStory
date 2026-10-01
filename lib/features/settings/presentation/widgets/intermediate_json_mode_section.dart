import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式设置 - 工具调用全局开关（夜航主题）。
///
/// 控制 `intermediate.stream.tool_calling_enabled` 配置项（V2 四步流程）：
/// - 开启（默认）：关键词提取和摘要生成优先使用工具调用，兼容性更好
/// - 关闭：直接输出 JSON 文本，适用于不支持工具调用的模型
///
/// 持久化：SettingsRepository.user_overrides
/// - `intermediate.stream.tool_calling_enabled`
///
/// 交互模式：即时持久化（switch 变更即保存，无 dirty state），
/// 与默认模型区块一致--因为开关是离散状态。
///
/// 会话级覆盖：本开关仅控制全局默认值，单会话可在会话设置面板中
/// 覆盖（`ChatSession.jsonModeOverride`，详见 DOC-09B §10.2）。
class IntermediateJsonModeSection extends ConsumerWidget {
  const IntermediateJsonModeSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final configAsync = ref.watch(intermediateConfigProvider);
    final config = configAsync.valueOrNull;
    final colors = context.lm.palette;
    final t = Translations.of(context);

    // 工具调用开关 = stream.toolCallingEnabled（默认 true）
    final stream = config?.stream;
    final isToolCallingEnabled = stream?.toolCallingEnabled ?? true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.settings.intermediate.jsonMode,
          style: IntermediateTextStyles.title.copyWith(color: colors.ink),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: IntermediateSpacing.s2xs),
        Text(
          t.settings.intermediate.jsonModeDesc,
          style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: IntermediateSpacing.sMd),
        //  修复：原 Container+BoxDecoration(color) 包裹 SwitchListTile 会
        // 触发 "ListTile background color or ink splashes may be invisible" 警告
        // （色层遮挡 Material ink splash 宿主）。改为 Material 让色层本身成为宿主。
        // 与 chat_sidebar.dart:289 / session_settings_sheet.dart:897 已修复样板一致。
        Material(
          color: colors.surface,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
          child: Padding(
            padding: const EdgeInsets.all(IntermediateSpacing.sLg),
            child: SwitchListTile(
              title: Text(
                t.settings.intermediate.jsonModeToggle,
                style:
                    IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                isToolCallingEnabled
                    ? t.settings.intermediate.jsonModeOnHint
                    : t.settings.intermediate.jsonModeOffHint,
                style: IntermediateTextStyles.caption
                    .copyWith(color: colors.faint),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              value: isToolCallingEnabled,
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

  /// 切换工具调用模式：持久化 user_overrides key
  ///
  /// 始终显式写入 true/false，不依赖 removeUserOverride 回落默认值--
  /// default_config.json 中 tool_calling_enabled 默认为 true，
  /// 若关闭时用 removeUserOverride 会回落到 true，导致开关永远关不掉。
  Future<void> _onChanged(WidgetRef ref, bool value) async {
    final repo = ref.read(settingsRepositoryProvider);
    await repo.setUserOverride(
      'intermediate.stream.tool_calling_enabled',
      value,
    );
    ref.invalidate(intermediateConfigProvider);
  }
}
