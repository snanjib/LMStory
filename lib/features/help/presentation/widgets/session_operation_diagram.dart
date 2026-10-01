import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 会话操作示意图（2026-07-27 新增）。
///
/// 用于「创建与切换会话」wiki 页顶部主视觉。
///
/// 设计：
/// - 上下两段：生成→入库流程 + 侧边栏操作矩阵
/// - 上段：横向 3 节点（点击新建 → 草稿会话 → 发送首消息时入库）
/// - 下段：6 宫格图标矩阵，展示侧边栏支持的 6 种会话操作
///
/// 视觉传达：草稿机制避免数据库污染 + 侧边栏操作完整
class SessionOperationDiagram extends StatelessWidget {
  const SessionOperationDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 上段：生成→入库流程
        Container(
          padding: const EdgeInsets.all(SimpleSpacing.sMd),
          decoration: BoxDecoration(
            color: colors.surfaceVariant,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
          ),
          child: Row(
            children: [
              Expanded(
                child: _FlowStep(
                  icon: Icons.add_circle_outline,
                  label: t.help.sessionOp.diagramNewLabel,
                  desc: t.help.sessionOp.diagramNewDesc,
                  highlight: false,
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: colors.faint, size: 20),
              Expanded(
                child: _FlowStep(
                  icon: Icons.edit_note_outlined,
                  label: t.help.sessionOp.diagramDraftLabel,
                  desc: t.help.sessionOp.diagramDraftDesc,
                  highlight: true,
                ),
              ),
              Icon(Icons.chevron_right_rounded, color: colors.faint, size: 20),
              Expanded(
                child: _FlowStep(
                  icon: Icons.check_circle_outline,
                  label: t.help.sessionOp.diagramPersistLabel,
                  desc: t.help.sessionOp.diagramPersistDesc,
                  highlight: false,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: SimpleSpacing.sMd),

        // 下段：侧边栏 6 种操作矩阵
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
                t.help.sessionOp.diagramOpsTitle,
                style: SimpleTextStyles.bodySm.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: SimpleSpacing.sSm),
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: SimpleSpacing.sSm,
                crossAxisSpacing: SimpleSpacing.sSm,
                childAspectRatio: 1.1,
                children: [
                  _OpCell(
                    icon: Icons.add_outlined,
                    label: t.help.sessionOp.opNew,
                    color: colors.primary,
                  ),
                  _OpCell(
                    icon: Icons.edit_outlined,
                    label: t.help.sessionOp.opRename,
                    color: colors.primary,
                  ),
                  _OpCell(
                    icon: Icons.star_border,
                    label: t.help.sessionOp.opStar,
                    color: colors.accent,
                  ),
                  _OpCell(
                    icon: Icons.content_copy,
                    label: t.help.sessionOp.opCopy,
                    color: colors.primary,
                  ),
                  _OpCell(
                    icon: Icons.drag_indicator,
                    label: t.help.sessionOp.opDrag,
                    color: colors.primary,
                  ),
                  _OpCell(
                    icon: Icons.delete_outline,
                    label: t.help.sessionOp.opDelete,
                    color: colors.error,
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

class _FlowStep extends StatelessWidget {
  const _FlowStep({
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

    return Column(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: highlight ? colors.primary : colors.primaryDim,
            shape: BoxShape.circle,
          ),
          child: Icon(
            icon,
            color: highlight ? colors.surface : colors.primary,
            size: 18,
          ),
        ),
        const SizedBox(height: SimpleSpacing.s2xs),
        Text(
          label,
          style: SimpleTextStyles.caption.copyWith(
            color: colors.ink,
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          desc,
          style: SimpleTextStyles.caption.copyWith(
            color: colors.muted,
            fontSize: 10,
            height: 1.3,
          ),
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _OpCell extends StatelessWidget {
  const _OpCell({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, color: color, size: 22),
        const SizedBox(height: SimpleSpacing.s2xs),
        Text(
          label,
          style: SimpleTextStyles.caption.copyWith(
            color: colors.muted,
            fontSize: 11,
          ),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
