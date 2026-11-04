import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/advanced/domain/entities/tool_permissions.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/collapsible_settings_section.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 导演会话面板 — 12 工具三态权限表（导演设置 ，设计文档 §5/§6.2）。
///
/// 与全局表（DirectorToolPermissionsSection）的差异：
/// - 展示**生效值**（会话列 > 全局 advanced.tools > 内置 allow）
/// - 变更即物化完整 map 写 `chat_sessions.tool_permissions`
///   （全 allow 时写 null = 跟随全局）
class DirectorToolPermissionsField extends StatelessWidget {
  const DirectorToolPermissionsField({
    required this.sessionPermissions,
    required this.globalPermissions,
    required this.onChanged,
    this.enabled = true,
    super.key,
  });

  /// 会话级权限 map（null = 跟随全局）。
  final Map<String, String>? sessionPermissions;

  /// 全局 advanced.tools（生效值回退源）。
  final Map<String, String> globalPermissions;

  /// 变更回调：接收物化的完整 map；null = 清除（全 allow 跟随全局）。
  final ValueChanged<Map<String, String>?> onChanged;

  /// false 时三态按钮视觉禁用（灰显、不可点）——
  /// 生成中会话面板锁定权限表的正式通道，替代调用方传空闭包吞点选。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final tt = t.settings.director.tools;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final group in _GroupDef.groups)
          Padding(
            padding: const EdgeInsets.only(bottom: IntermediateSpacing.sXs),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: IntermediateSpacing.sMd,
                  ),
                  child: Text(
                    group.label(t),
                    style: IntermediateTextStyles.caption
                        .copyWith(color: colors.muted),
                  ),
                ),
                const SizedBox(height: IntermediateSpacing.s2xs),
                for (final name in group.tools)
                  _SessionToolRow(
                    toolName: name,
                    value: ToolPermissions.effective(
                      session: sessionPermissions,
                      global: globalPermissions,
                      toolName: name,
                    ),
                    enabled: enabled,
                    onSelected: (state) =>
                        _onToolSelected(name, ToolPermissionStateX.name(state)),
                  ),
              ],
            ),
          ),
        Text(
          '${tt.allowDesc}；${tt.askDesc}；${tt.denyDesc}。',
          style: IntermediateTextStyles.caption.copyWith(
            color: colors.faint,
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  /// 物化语义：以当前生效 map 为基底改写单工具，全 allow 时写 null。
  void _onToolSelected(String toolName, String state) {
    final base = {
      for (final t in ToolPermissions.allTools)
        t: ToolPermissions.effective(
          session: sessionPermissions,
          global: globalPermissions,
          toolName: t,
        ).name,
    };
    base[toolName] = state;
    final allAllow = base.values.every((v) => v == 'allow');
    onChanged(allAllow ? null : base);
  }
}

/// 三态枚举 ↔ 字符串便捷转换。
extension ToolPermissionStateX on ToolPermissionState {
  static String name(ToolPermissionState s) => switch (s) {
        ToolPermissionState.allow => 'allow',
        ToolPermissionState.ask => 'ask',
        ToolPermissionState.deny => 'deny',
      };
}

class _GroupDef {
  const _GroupDef(this.labelKey, this.tools);

  final String labelKey;
  final List<String> tools;

  String label(Translations t) => switch (labelKey) {
        'readOnly' => t.settings.director.tools.groups.readOnly,
        'write' => t.settings.director.tools.groups.write,
        _ => t.settings.director.tools.groups.control,
      };

  static const groups = [
    _GroupDef('readOnly', [
      'search_story',
      'search_story_text',
      'read_story',
      'query_facts',
      'read_compact_summary',
      'read_skill',
    ]),
    _GroupDef('write', [
      'update_facts',
      'merge_entities',
      'update_story_anchor',
      'record_event_memory',
    ]),
    _GroupDef('control', ['spawn', 'ask_user', 'finish_round']),
  ];
}

class _SessionToolRow extends StatelessWidget {
  const _SessionToolRow({
    required this.toolName,
    required this.value,
    required this.onSelected,
    this.enabled = true,
  });

  final String toolName;
  final ToolPermissionState value;
  final ValueChanged<ToolPermissionState> onSelected;

  /// false 时 SegmentedButton onSelectionChanged 置 null（视觉禁用）。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final tt = t.settings.director.tools;

    return SettingsTile(
      padding: const EdgeInsets.symmetric(
        horizontal: IntermediateSpacing.sMd,
        vertical: IntermediateSpacing.s2xs,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              toolName,
              style: IntermediateTextStyles.bodyUi.copyWith(
                color: colors.ink,
                fontSize: 13,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(
            height: 32,
            child: SegmentedButton<ToolPermissionState>(
              // finish_round（提交本轮）锁死
              // allow——只渲染 allow 段，UI 上不存在可切至 ask/deny 的入口
              segments: toolName == ToolPermissions.lockedAllowTool
                  ? [
                      ButtonSegment(
                        value: ToolPermissionState.allow,
                        label: Text(
                          tt.states.allow,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ]
                  : [
                      ButtonSegment(
                        value: ToolPermissionState.allow,
                        label: Text(
                          tt.states.allow,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      ButtonSegment(
                        value: ToolPermissionState.ask,
                        label: Text(
                          tt.states.ask,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      ButtonSegment(
                        value: ToolPermissionState.deny,
                        label: Text(
                          tt.states.deny,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
              selected: {value},
              showSelectedIcon: false,
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                side: WidgetStatePropertyAll(
                  BorderSide(color: colors.divider),
                ),
                backgroundColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected)
                      ? colors.primary
                      : null,
                ),
                foregroundColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.selected)
                      ? colors.bg
                      : colors.ink,
                ),
                shape: WidgetStatePropertyAll(
                  RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(
                      context.lmUi.radius(LmCorner.xs),
                    ),
                  ),
                ),
              ),
              onSelectionChanged: enabled ? (s) => onSelected(s.first) : null,
            ),
          ),
        ],
      ),
    );
  }
}
