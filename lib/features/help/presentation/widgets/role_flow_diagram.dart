import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 编辑部角色流程图：5 角色横向排列 + 箭头连接。
///
/// 帮助用户用「编辑部比喻」理解四步生成的分工。
///
/// v0.2.2角色顺序调整：资料员 → 档案管理员 → 实习编辑 → 主编 → 归档员
/// - 资料员（提取）前置到实习编辑（生成）之前
/// - 主编（审查）标注为可选，对应 reviewEnabled 开关
///
/// 设计：
/// - 5 个角色卡片横向滚动（移动端窄屏可滑）
/// - 每张卡：48×48 圆形图标 + 角色名 + 一句话职责
/// - 卡片间用 chevron_right 图标连接（不用箭头形状，更克制）
/// - 整体在一个 surface 容器内，避免视觉散乱
class RoleFlowDiagram extends StatelessWidget {
  const RoleFlowDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final roleFlow = t.help.flow.roleFlow;

    final roles = [
      _RoleData(
        icon: Icons.search_outlined,
        name: roleFlow.role1Name,
        duty: roleFlow.role1Duty,
      ),
      _RoleData(
        icon: Icons.library_books_outlined,
        name: roleFlow.role2Name,
        duty: roleFlow.role2Duty,
      ),
      _RoleData(
        icon: Icons.edit_outlined,
        name: roleFlow.role3Name,
        duty: roleFlow.role3Duty,
      ),
      _RoleData(
        icon: Icons.auto_awesome_outlined,
        name: roleFlow.role4Name,
        duty: roleFlow.role4Duty,
      ),
      _RoleData(
        icon: Icons.save_outlined,
        name: roleFlow.role5Name,
        duty: roleFlow.role5Duty,
      ),
    ];

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sLg),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
        border: Border.all(color: colors.divider),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (int i = 0; i < roles.length; i++) ...[
              _RoleCard(data: roles[i]),
              if (i < roles.length - 1)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: SimpleSpacing.sXs,
                  ),
                  child: Icon(
                    Icons.chevron_right,
                    color: colors.faint,
                    size: 20,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _RoleData {
  const _RoleData({
    required this.icon,
    required this.name,
    required this.duty,
  });

  final IconData icon;
  final String name;
  final String duty;
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({required this.data});

  final _RoleData data;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return SizedBox(
      width: 88,
      child: Column(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: colors.primaryDim,
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
            ),
            child: Icon(data.icon, color: colors.primary, size: 24),
          ),
          const SizedBox(height: SimpleSpacing.sXs),
          Text(
            data.name,
            style: SimpleTextStyles.bodySm.copyWith(
              color: colors.ink,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            data.duty,
            style: SimpleTextStyles.caption.copyWith(color: colors.muted),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
