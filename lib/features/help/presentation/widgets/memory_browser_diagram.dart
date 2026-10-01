import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 记忆库浏览器示意图（2026-07-27 新增）。
///
/// 用于「记忆库浏览器」wiki 页顶部主视觉。
///
/// 设计：
/// - 上段：双 Tab 结构（经历类记忆 / 事实类记忆）
/// - 下段：事实 Tab 的 7 种操作矩阵（搜索 / 新增 / 编辑 / 删除 / 多选 /
///   强制注入 / AI 合并——：徽章与标题计数同源，不再漏画）
///
/// 视觉传达：双 Tab 分类 + 完整 CRUD + 检索
/// 对齐：story_runtime/presentation/pages/memory_browser_page.dart + experience_memory_tab.dart +
///       factual_memory_tab.dart 实际代码
class MemoryBrowserDiagram extends StatelessWidget {
  const MemoryBrowserDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 上段：双 Tab 结构
        Container(
          padding: const EdgeInsets.all(SimpleSpacing.sMd),
          decoration: BoxDecoration(
            color: colors.surfaceVariant,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.help.memoryBrowser.diagramTabsTitle,
                style: SimpleTextStyles.bodySm.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              Row(
                children: [
                  Expanded(
                    child: _TabCard(
                      icon: Icons.history_outlined,
                      label: t.help.memoryBrowser.tabExperience,
                      desc: t.help.memoryBrowser.tabExperienceDesc,
                      highlight: true,
                    ),
                  ),
                  const SizedBox(width: SimpleSpacing.sSm),
                  Expanded(
                    child: _TabCard(
                      icon: Icons.account_tree_outlined,
                      label: t.help.memoryBrowser.tabFactual,
                      desc: t.help.memoryBrowser.tabFactualDesc,
                      highlight: false,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: SimpleSpacing.sMd),

        // 下段：7 种操作（与 diagramOpsTitle 计数同源；Wrap 布局防挤）
        Container(
          padding: const EdgeInsets.all(SimpleSpacing.sMd),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
            border: Border.all(color: colors.divider),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t.help.memoryBrowser.diagramOpsTitle,
                style: SimpleTextStyles.bodySm.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              Wrap(
                alignment: WrapAlignment.spaceAround,
                spacing: SimpleSpacing.sSm,
                runSpacing: SimpleSpacing.sXs,
                children: [
                  _OpBadge(
                    icon: Icons.search,
                    label: t.help.memoryBrowser.opSearch,
                    color: colors.primary,
                  ),
                  _OpBadge(
                    icon: Icons.add_circle_outline,
                    label: t.help.memoryBrowser.opAdd,
                    color: colors.success,
                  ),
                  _OpBadge(
                    icon: Icons.edit_outlined,
                    label: t.help.memoryBrowser.opEdit,
                    color: colors.muted,
                  ),
                  _OpBadge(
                    icon: Icons.delete_outline,
                    label: t.help.memoryBrowser.opDelete,
                    color: colors.error,
                  ),
                  _OpBadge(
                    icon: Icons.checklist,
                    label: t.help.memoryBrowser.opMulti,
                    color: colors.primary,
                  ),
                  _OpBadge(
                    icon: Icons.bolt_outlined,
                    label: t.help.memoryBrowser.opForceInject,
                    color: colors.warning,
                  ),
                  _OpBadge(
                    icon: Icons.auto_awesome,
                    label: t.help.memoryBrowser.opAiMerge,
                    color: colors.success,
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TabCard extends StatelessWidget {
  const _TabCard({
    required this.icon,
    required this.label,
    required this.desc,
    required this.highlight,
  });

  final IconData icon;
  final String label;
  final String desc;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sSm),
      decoration: BoxDecoration(
        color: highlight ? colors.primaryDim : colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        border: Border.all(
          color: highlight ? colors.primary : colors.divider,
        ),
      ),
      child: Column(
        children: [
          Icon(
            icon,
            color: highlight ? colors.primary : colors.muted,
            size: 22,
          ),
          const SizedBox(height: SimpleSpacing.s2xs),
          Text(
            label,
            style: SimpleTextStyles.caption.copyWith(
              color: highlight ? colors.primary : colors.ink,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            desc,
            style: SimpleTextStyles.caption.copyWith(
              color: colors.muted,
              fontSize: 10,
              height: 1.4,
            ),
            textAlign: TextAlign.center,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _OpBadge extends StatelessWidget {
  const _OpBadge({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(height: SimpleSpacing.s2xs),
        Text(
          label,
          style: SimpleTextStyles.caption.copyWith(
            color: color,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
