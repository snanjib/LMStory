import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_structure.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/lm_ui_text_styles.dart';

/// Classic 结构 · 对话空态。
///
/// 刻意不放大图标、不截断文案：空态是屏幕空间最充裕的一屏，
/// 用户此刻需要的是「我在哪一屏、能做什么」，靠标题层级与完整副标题
/// 传达，大圆图标容器对这两件事没有实质贡献，只留下 AI 生成界面的
/// 模板指纹。
class SimpleEmptyState extends StatelessWidget {
  const SimpleEmptyState({
    required this.title,
    super.key,
    this.subtitle,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String? subtitle;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    // 居中布局防护（项目规则 §9/§10）：
    // 使用 LayoutBuilder + SingleChildScrollView + ConstrainedBox(minHeight) 模式
    // 替代裸 Center+Column，避免在键盘弹出（可视区域减少 30%-50%）时
    // Column children 总高度超过可用高度导致底部溢出（黄黑斑马纹）。
    // - LayoutBuilder 获取键盘挤压后的实际可用高度
    // - ConstrainedBox(minHeight) 让 Column 撑满可用高度以居中显示
    // - SingleChildScrollView 在 children 总高度 > 可用高度时允许滚动
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Center(
              child: ConstrainedBox(
                // 锚定阅读限宽列：空态标题与随后的消息正文、输入区共用
                // 同一条阅读轴线，宽屏下不会出现「空态铺满、正文收窄」的
                // 跳变。视口窄于上限时自动取满宽，不产生额外边距。
                constraints:
                    BoxConstraints(maxWidth: LmLayout.readingWidthOf(context)),
                child: SizedBox(
                  // 撑满限宽列，否则 CrossAxisAlignment.start 会把列宽
                  // 收缩到最长子件的固有宽度，左对齐失去意义。
                  width: double.infinity,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: LmSpacing.sXl,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          // 标题层级：扫视时先抓到「这是哪一屏」，再读副标题。
                          style:
                              LmNarrativeTextStyles.narrativeHeadline.copyWith(
                            color: colors.ink,
                          ),
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: LmSpacing.sSm),
                          Text(
                            subtitle!,
                            // 不限行：空态是最有空间讲清楚话的地方，
                            // 截断只会把最该被读完的一句切掉。
                            style: LmUiTextStyles.bodySm.copyWith(
                              color: colors.muted,
                            ),
                          ),
                        ],
                        if (actionLabel != null && onAction != null) ...[
                          const SizedBox(height: LmSpacing.sXl),
                          ElevatedButton(
                            onPressed: onAction,
                            child: Text(actionLabel!),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
