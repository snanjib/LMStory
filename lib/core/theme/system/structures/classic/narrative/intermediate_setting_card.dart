import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/navigation_card_content.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';

/// 故事模式设置分类卡片（夜航主题，子页入口）。
///
/// 2026-07-19 子页化重构：故事模式设置页顶层使用 5 个分类卡片，点击进入
/// 对应子页查看具体设置项。视觉与 SimpleSettingCard 平行，但配色/字体
/// 遵循夜航主题（surface 底 + ink 文字 + primary 图标 + chevron 引导）。
///
/// 2026-07-24 扩展 [enabled] 参数：分步骤模型卡片在生成中应禁用点击，
/// 避免用户在生成过程中切换阶段模型导致状态不一致。
///
/// 视觉决策（impeccable / product register / Restrained）：
/// - surface 卡片底（surfaceVariant 与 surface 之间形成层次）
/// - 图标方块：surface 底 + primary 图标，与 Simple 模式保持视觉一致性
/// - 标题：公共衬线目的地标题 + ink 色，副标题：caption + muted 色
/// - chevron：faint 色，弱化但可识别
/// - 直角边缘？不——夜航主题保留 rLg 圆角（DOC-06B 令牌体系），与对话
///   模式的 SimpleSettingCard 视觉节奏一致，避免破坏模式间识别
class IntermediateSettingCard extends StatelessWidget {
  const IntermediateSettingCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.enabled = true,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) => context.lmUi.settingCard(
        context,
        icon: icon,
        title: title,
        subtitle: subtitle,
        onTap: onTap,
        narrative: true,
        enabled: enabled,
      );
}

/// Story setting surface used by the classic and glass kits.
class ClassicNarrativeSettingCard extends StatelessWidget {
  const ClassicNarrativeSettingCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.enabled = true,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  /// 是否启用卡片点击。false 时 InkWell 不响应点击，整体视觉降低透明度。
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final borderRadius = BorderRadius.circular(
      context.lmUi.radius(LmCorner.lg),
    );
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Container(
        decoration: BoxDecoration(
          color: context.lmSettingCardFace(colors.surface),
          borderRadius: borderRadius,
        ),
        child: Material(
          color: Colors.transparent,
          child: Semantics(
            button: true,
            enabled: enabled,
            child: InkWell(
              onTap: enabled ? onTap : null,
              borderRadius: borderRadius,
              child: Padding(
                padding: const EdgeInsets.all(LmSpacing.sLg),
                child: NavigationCardContent(
                  icon: icon,
                  title: title,
                  subtitle: subtitle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
