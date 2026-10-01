import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/advanced/domain/entities/tool_permissions.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/collapsible_settings_section.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/director_setting_rows.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 导演设置 — 工具权限分区（导演设置 ，设计文档 §5/§7）。
///
/// 两枚预设（「自由创作」= 全 allow；「监督模式」= 写入+spawn → ask）+
/// 12 工具三态表（按只读/写入/控制分组）。写 `advanced.tools.<name>`，
/// 与预设语义一致（选 allow 即写 allow，非删除——语义显式）。
class DirectorToolPermissionsSection extends ConsumerWidget {
  const DirectorToolPermissionsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tools = ref.watch(advancedConfigProvider).valueOrNull?.tools ?? {};
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final tt = t.settings.director.tools;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 预设 ─────────────────────────────────────────────────
        SettingsTile(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: IntermediateSpacing.sSm,
                children: [
                  ActionChip(
                    label: Text(tt.presetFree),
                    onPressed: () => _applyPreset(ref, supervised: false),
                  ),
                  ActionChip(
                    label: Text(tt.presetSupervised),
                    onPressed: () => _applyPreset(ref, supervised: true),
                  ),
                ],
              ),
              const SizedBox(height: IntermediateSpacing.sXs),
              Text(
                '${tt.presetFreeDesc}；${tt.presetSupervisedDesc}。',
                style: IntermediateTextStyles.captionSm.copyWith(
                  color: colors.faint,
                ),
              ),
            ],
          ),
        ),
        directorSectionGap,

        // ── 三组工具三态表 ──────────────────────────────────────
        _ToolGroup(
          title: tt.groups.readOnly,
          toolNames: const [
            'search_story',
            'read_story',
            'query_facts',
            'read_compact_summary',
            'read_skill',
          ],
          overrides: tools,
        ),
        _ToolGroup(
          title: tt.groups.write,
          toolNames: const [
            'update_facts',
            'merge_entities',
            'update_story_anchor',
            'record_event_memory',
          ],
          overrides: tools,
          initiallyExpanded: true,
        ),
        _ToolGroup(
          title: tt.groups.control,
          toolNames: const ['spawn', 'ask_user', 'finish_round'],
          overrides: tools,
          initiallyExpanded: true,
        ),
        const SizedBox(height: IntermediateSpacing.sXs),

        // ── 底部说明 ────────────────────────────────────────────
        Text(
          '${tt.allowDesc}；${tt.askDesc}；${tt.denyDesc}。',
          style: IntermediateTextStyles.captionSm.copyWith(
            color: colors.faint,
          ),
        ),
      ],
    );
  }

  /// 应用预设：自由创作 = 逐工具移除覆写（回内置全 allow）；
  /// 监督模式 = 12 键写入监督预设值。
  Future<void> _applyPreset(WidgetRef ref, {required bool supervised}) async {
    if (!supervised) {
      for (final name in ToolPermissions.allTools) {
        await writeDirectorOverride(ref, 'advanced.tools.$name', null);
      }
      return;
    }
    for (final entry in ToolPermissions.supervised.entries) {
      await writeDirectorOverride(
        ref,
        'advanced.tools.${entry.key}',
        entry.value,
      );
    }
  }
}

/// 单组工具（ExpansionTile + 每行三态 SegmentedButton）。
class _ToolGroup extends ConsumerWidget {
  const _ToolGroup({
    required this.title,
    required this.toolNames,
    required this.overrides,
    this.initiallyExpanded = false,
  });

  final String title;
  final List<String> toolNames;
  final Map<String, String> overrides;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lm.palette;

    return Padding(
      padding: const EdgeInsets.only(bottom: IntermediateSpacing.sXs),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(
            horizontal: IntermediateSpacing.sMd,
          ),
          childrenPadding: const EdgeInsets.symmetric(
            horizontal: IntermediateSpacing.sXs,
          ),
          initiallyExpanded: initiallyExpanded,
          title: Text(
            title,
            style: IntermediateTextStyles.label.copyWith(color: colors.primary),
          ),
          children: [
            for (final name in toolNames)
              _ToolPermissionRow(
                toolName: name,
                value: overrides[name] ?? 'allow',
              ),
          ],
        ),
      ),
    );
  }
}

/// 单工具三态行（工具名 + 描述 + SegmentedButton）。
class _ToolPermissionRow extends ConsumerWidget {
  const _ToolPermissionRow({required this.toolName, required this.value});

  final String toolName;
  final String value;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final tt = t.settings.director.tools;
    // finish_round 锁死 allow——历史全局配置
    // 存的 deny/ask 值展示时同样兜底为 allow
    final locked = toolName == ToolPermissions.lockedAllowTool;
    final effectiveValue = locked ? 'allow' : value;
    final desc = _toolDesc(tt, toolName);

    return SettingsTile(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      toolName,
                      style: IntermediateTextStyles.bodyUi.copyWith(
                        color: colors.ink,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      desc,
                      style: IntermediateTextStyles.captionSm.copyWith(
                        color: colors.faint,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: IntermediateSpacing.sXs),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<String>(
              // finish_round 只渲染 allow 段——UI 上不存在可切至
              // ask/deny 的入口（正文唯一交付通道不可禁用）
              segments: [
                ButtonSegment(
                  value: 'allow',
                  label: Text(
                    tt.states.allow,
                    style: TextStyle(
                      fontSize: 12,
                      color:
                          effectiveValue == 'allow' ? colors.bg : colors.muted,
                    ),
                  ),
                ),
                if (!locked)
                  ButtonSegment(
                    value: 'ask',
                    label: Text(
                      tt.states.ask,
                      style: TextStyle(
                        fontSize: 12,
                        color:
                            effectiveValue == 'ask' ? colors.bg : colors.muted,
                      ),
                    ),
                  ),
                if (!locked)
                  ButtonSegment(
                    value: 'deny',
                    label: Text(
                      tt.states.deny,
                      style: TextStyle(
                        fontSize: 12,
                        color:
                            effectiveValue == 'deny' ? colors.bg : colors.muted,
                      ),
                    ),
                  ),
              ],
              selected: {effectiveValue},
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
              onSelectionChanged: (selection) => writeDirectorOverride(
                ref,
                'advanced.tools.$toolName',
                selection.first,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 工具名 → i18n 描述（slang 节点类不支持动态键访问，本地映射）。
String _toolDesc(
  Translations$settings$director$tools$zh_CN toolDescs,
  String toolName,
) {
  final d = toolDescs.toolDesc;
  return switch (toolName) {
    'search_story' => d.search_story,
    'read_story' => d.read_story,
    'query_facts' => d.query_facts,
    'read_compact_summary' => d.read_compact_summary,
    'read_skill' => d.read_skill,
    'update_facts' => d.update_facts,
    'merge_entities' => d.merge_entities,
    'update_story_anchor' => d.update_story_anchor,
    'record_event_memory' => d.record_event_memory,
    'spawn' => d.spawn,
    'ask_user' => d.ask_user,
    'finish_round' => d.finish_round,
    _ => toolName,
  };
}
