import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 视觉时间轴：用户在屏幕上看到的流程顺序。
///
/// 用于四步流程页底部，告诉用户「屏幕上会看到什么」。
///
/// 设计(2026-07-30 调整）：
/// - 竖向时间轴，节点顺序：
///   `[压缩?] → [提取] → [检索] → [生成] → ([审查]) → [摘要] → [入库]`
/// - **压缩节点**（compacting）：可选显示，仅当触发了压缩时显示
///   （[showCompacting] = true）。默认隐藏。
/// - **审查节点**（reviewing）：可选显示，根据 [showReviewing] 动态显示/隐藏
///   （对应 `reviewEnabled` 配置）。默认显示（ wiki 教学场景展示完整流程）。
/// - 生成节点（generating）高亮放大，强调这是用户最终看到的（若 reviewing 关闭）；
///   若 reviewing 开启，主回复节点（reviewing）高亮。
/// - 每节点：图标 badge + 阶段名 + 1 行说明
///
/// 节点描述文案与实际 UI 阶段提示文案（intermediate.chat.*Hint）保持一致，
/// 通过 i18n key 引用，避免硬编码过时。
class VisualFlowTimeline extends StatelessWidget {
  const VisualFlowTimeline({
    this.showCompacting = false,
    this.showReviewing = true,
    super.key,
  });

  /// 是否显示压缩节点（compacting）。
  ///
  /// 默认 false（压缩仅条件触发）。wiki 教学页可传 true 展示完整流程。
  final bool showCompacting;

  /// 是否显示审查节点（reviewing）。
  ///
  /// 默认 true（wiki 教学场景展示完整流程）。
  /// 运行时场景应根据 `reviewEnabled` 配置传入。
  final bool showReviewing;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    // 主回复高亮节点：reviewing 开启时高亮 reviewing，否则高亮 generating（生成即最终）
    final highlightNodeKey = showReviewing ? _kReviewing : _kGenerating;

    // 按顺序构造节点列表（compacting 和 reviewing 可选）
    // 顺序：压缩? → 提取 → 检索 → 生成 → (审查) → 摘要 → 入库
    final nodes = <_TimelineNode>[
      if (showCompacting)
        _TimelineNode(
          icon: Icons.compress_outlined,
          name: t.help.flow.visualFlowCompactingName,
          desc: t.help.flow.visualFlowCompactingDesc,
          isHighlight: false,
        ),
      _TimelineNode(
        icon: Icons.search_outlined,
        name: t.help.flow.visualFlowNode1Name,
        desc: t.help.flow.visualFlowNode1Desc,
        isHighlight: false,
      ),
      _TimelineNode(
        icon: Icons.library_books_outlined,
        name: t.help.flow.visualFlowNode2Name,
        desc: t.help.flow.visualFlowNode2Desc,
        isHighlight: false,
      ),
      _TimelineNode(
        icon: Icons.edit_outlined,
        name: t.help.flow.visualFlowNode3Name,
        desc: t.help.flow.visualFlowNode3Desc,
        isHighlight: highlightNodeKey == _kGenerating,
      ),
      if (showReviewing)
        _TimelineNode(
          icon: Icons.chat_bubble_outline,
          name: t.help.flow.visualFlowNode4Name,
          desc: t.help.flow.visualFlowNode4Desc,
          isHighlight: highlightNodeKey == _kReviewing,
        ),
      _TimelineNode(
        icon: Icons.summarize_outlined,
        name: t.help.flow.visualFlowNode5Name,
        desc: t.help.flow.visualFlowNode5Desc,
        isHighlight: false,
      ),
      _TimelineNode(
        icon: Icons.library_add_check_outlined,
        name: t.help.flow.visualFlowNode6Name,
        desc: t.help.flow.visualFlowNode6Desc,
        isHighlight: false,
      ),
    ];

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sLg),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
        border: Border.all(color: colors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (int i = 0; i < nodes.length; i++) ...[
            _TimelineNodeView(data: nodes[i]),
            if (i < nodes.length - 1)
              Padding(
                padding: const EdgeInsets.only(
                  left: 20, // 对齐节点中心（24×2/2 + 8 padding）
                ),
                child: Container(
                  width: 2,
                  height: 20,
                  color: colors.divider,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

// 节点标识 key（用于决定高亮位置）
const String _kGenerating = 'generating';
const String _kReviewing = 'reviewing';

class _TimelineNode {
  const _TimelineNode({
    required this.icon,
    required this.name,
    required this.desc,
    required this.isHighlight,
  });

  final IconData icon;
  final String name;
  final String desc;
  final bool isHighlight;
}

class _TimelineNodeView extends StatelessWidget {
  const _TimelineNodeView({required this.data});

  final _TimelineNode data;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final size = data.isHighlight ? 32.0 : 24.0;
    final iconSize = data.isHighlight ? 18.0 : 14.0;

    return Row(
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: data.isHighlight ? colors.primary : colors.primaryDim,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
          ),
          child: Icon(data.icon, color: colors.surface, size: iconSize),
        ),
        const SizedBox(width: SimpleSpacing.sMd),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                data.name,
                style: SimpleTextStyles.body.copyWith(
                  color: colors.ink,
                  fontWeight:
                      data.isHighlight ? FontWeight.w700 : FontWeight.w500,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                data.desc,
                style: SimpleTextStyles.caption.copyWith(color: colors.muted),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
