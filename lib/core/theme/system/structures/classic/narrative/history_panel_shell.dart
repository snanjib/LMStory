import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';

/// 历史小窗共享容器（DOC-06B §6.2/§6.2A/§6.3/§6.3A 统一历史态）。
///
/// 用于将 GeneratePanel/ExtractPanel/RetrievalPanel/SummarizePanel 在"已完成快照"
/// 状态下的容器逻辑统一收口，避免 4 个组件各自重复实现：
/// - 默认折叠（历史小窗不抢注意力）
/// - 箭头用 muted 色（区别于实时态的 primary 琥珀金）
/// - 入场淡入（TweenAnimationBuilder 200ms ease-out，DOC-06B §5.3）
/// - AnimatedSize 折叠/展开过渡（200ms easeInOut）
/// - reduced-motion 备选（动效时长改 0）
///
/// 与实时态的差异（DOC-06B §6.2 表）：
/// | 差异点 | 实时态 | 历史态（本 Shell） |
/// |--------|--------|--------------------|
/// | summary 文案 | 不带轮次前缀 | 带轮次前缀（由调用方传入） |
/// | 箭头颜色 | primary | muted |
/// | 入场动画 | 无（实时显示） | 200ms ease-out 淡入 |
/// | 自动折叠 | 有（foldDelayMs） | 无（用户主动展开/折叠） |
/// | 失败态 | 有 | 无（已是成功持久化产物） |
class HistoryPanelShell extends StatefulWidget {
  const HistoryPanelShell({
    required this.summary,
    required this.expandedContent,
    this.animateEntrance = true,
    super.key,
  });

  /// 折叠态显示的单行摘要（如"第 N 轮 · 已生成"）
  final String summary;

  /// 展开后显示的内容（由调用方提供）
  final Widget expandedContent;

  /// 是否播放入场淡入动画（默认 true）。
  ///
  /// 首次加载历史消息时为 true，面板从透明淡入（DOC-06B §5.3）。
  /// 从实时态切换到历史态（生成完成 phase=idle）时为 false，
  /// 避免面板"消失再淡入"的闪烁（问题1修复）。
  final bool animateEntrance;

  @override
  State<HistoryPanelShell> createState() => _HistoryPanelShellState();
}

class _HistoryPanelShellState extends State<HistoryPanelShell> {
  bool _expanded = false;

  void _toggleExpanded() {
    setState(() => _expanded = !_expanded);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final reducedMotion = LmMotion.reducedMotion(context);

    final content = AnimatedSize(
      duration: reducedMotion ? Duration.zero : LmMotion.base,
      curve: LmMotion.easeBoth,
      child: Container(
        margin: const EdgeInsets.symmetric(
          horizontal: LmSpacing.sLg,
          vertical: LmSpacing.sXs,
        ),
        decoration: BoxDecoration(
          color: colors.surfaceElevated,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        ),
        child: InkWell(
          onTap: _toggleExpanded,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: LmSpacing.sMd,
              vertical: LmSpacing.sSm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(
                      _expanded
                          ? Icons.keyboard_arrow_down
                          : Icons.keyboard_arrow_right,
                      size: 16,
                      // 历史小窗箭头用 muted（弱化提示，不抢注意力）
                      color: colors.muted,
                    ),
                    const SizedBox(width: LmSpacing.sXs),
                    Expanded(
                      child: Text(
                        widget.summary,
                        style: LmNarrativeTextStyles.caption.copyWith(
                          color: colors.muted,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if (_expanded) ...[
                  const SizedBox(height: LmSpacing.sSm),
                  Divider(height: 1, color: colors.divider),
                  const SizedBox(height: LmSpacing.sSm),
                  widget.expandedContent,
                ],
              ],
            ),
          ),
        ),
      ),
    );

    // 从实时态切换到历史态时跳过淡入，避免"消失再淡入"闪烁（问题1修复）
    if (!widget.animateEntrance) {
      return content;
    }

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: reducedMotion ? Duration.zero : LmMotion.base,
      curve: LmMotion.easeStandard,
      builder: (context, opacity, child) =>
          Opacity(opacity: opacity, child: child),
      child: content,
    );
  }
}
