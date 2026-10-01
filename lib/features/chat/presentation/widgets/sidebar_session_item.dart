import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/breathing_dot.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/chat/domain/entities/chat_mode.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// Sidebar session list item (two-row layout).
///
/// 两行布局：
/// - Row 1：[mode icon] 模式标签（对话/故事，色彩区分）+ 右侧操作区
///   （star / drag handle / action menu）
/// - Row 2：会话标题（caption 字号，muted 色，选中时 ink+w500）
///
/// 模式色彩：
/// - 对话（simple）：[LmPalette.primary]（indigo）
/// - 故事（intermediate）：[LmPalette.accent]（warm amber，呼应夜航暖色调）
///
/// 生成中时左侧图标替换为 [BreathingDot]，模式标签仍显示。
/// Star 指示器移至右侧（不再覆盖模式图标），让模式信息始终可见。
class SidebarSessionItem extends StatefulWidget {
  const SidebarSessionItem({
    required this.session,
    required this.index,
    required this.isSelected,
    required this.onTap,
    required this.onDelete,
    required this.onRename,
    required this.onToggleStar,
    required this.onCopy,
    this.isGenerating = false,
    super.key,
  });

  final ChatSession session;

  /// 该 item 在 ReorderableListView 中的索引（用于拖动排序）
  final int index;

  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onRename;
  final VoidCallback onToggleStar;
  final VoidCallback onCopy;

  /// 该会话是否正在生成（流式回复中）。
  ///
  /// 为 true 时，左侧图标位置显示 [BreathingDot] 呼吸点（覆盖 mode icon），
  /// 让用户在多会话切换或后台生成时仍能从侧边栏感知"哪个会话在跑"。
  /// 默认 false 保持向后兼容。
  final bool isGenerating;

  @override
  State<SidebarSessionItem> createState() => _SidebarSessionItemState();
}

class _SidebarSessionItemState extends State<SidebarSessionItem> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    // 三态模式标签：对话（primary）/ 故事（accent）/ 导演（warning，与首页第三卡同源）
    final mode = widget.session.mode;
    final isStory = mode == ChatMode.intermediate;
    final isDirector = mode == ChatMode.advanced;
    final modeColor = isDirector
        ? colors.warning
        : isStory
            ? colors.accent
            : colors.primary;
    final modeLabel = isDirector
        ? t.chat.sidebar.modeDirector
        : isStory
            ? t.chat.sidebar.modeStory
            : t.chat.sidebar.modeChat;
    final modeIcon = isDirector
        ? Icons.theater_comedy
        : isStory
            ? Icons.auto_stories
            : Icons.chat_bubble_outline;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: context.lmUi.sessionRow(
        context,
        onTap: widget.onTap,
        selected: widget.isSelected,
        hovered: _isHovered,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Row 1：模式标签 + 右侧操作区 ──
            Row(
              children: [
                // 生成中：显示呼吸点（覆盖 mode icon）
                // 让用户从侧边栏即可感知哪个会话正在流式生成
                if (widget.isGenerating)
                  const BreathingDot()
                else
                  Icon(
                    modeIcon,
                    size: 16,
                    color: modeColor,
                  ),
                const SizedBox(width: SimpleSpacing.sSm),
                Flexible(
                  child: Text(
                    modeLabel,
                    style: SimpleTextStyles.bodySm.copyWith(
                      color: modeColor,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Spacer(),
                // Star 指示器（starred 且非生成中时显示）
                // 移至右侧，不再覆盖模式图标，让模式信息始终可见
                if (widget.session.isStarred && !widget.isGenerating)
                  Padding(
                    padding: const EdgeInsets.only(
                      right: SimpleSpacing.s2xs,
                    ),
                    child: Icon(
                      Icons.star,
                      size: 14,
                      color: colors.accent,
                    ),
                  ),
                // 拖拽把手 + 操作菜单
                //  修复：移动端无 hover，原条件导致
                // 操作菜单完全不可见。改为常驻显示，非 hover/selected 时
                // 透明度 0.5（视觉低调），hover/selected 时透明度 1.0（高亮）。
                _DragHandle(index: widget.index),
                const SizedBox(width: SimpleSpacing.s2xs),
                Opacity(
                  opacity: (_isHovered || widget.isSelected) ? 1.0 : 0.5,
                  child: _ActionMenu(
                    session: widget.session,
                    onRename: widget.onRename,
                    onDelete: widget.onDelete,
                    onToggleStar: widget.onToggleStar,
                    onCopy: widget.onCopy,
                  ),
                ),
              ],
            ),
            const SizedBox(height: SimpleSpacing.s2xs),
            // ── Row 2：会话标题 ──
            Text(
              widget.session.title,
              style: SimpleTextStyles.caption.copyWith(
                color: widget.isSelected ? colors.ink : colors.muted,
                fontWeight:
                    widget.isSelected ? FontWeight.w500 : FontWeight.w400,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// Three-dot action menu for session items.
class _ActionMenu extends StatelessWidget {
  const _ActionMenu({
    required this.session,
    required this.onRename,
    required this.onDelete,
    required this.onToggleStar,
    required this.onCopy,
  });

  final ChatSession session;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onToggleStar;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: IconButton(
        // 纯图标按钮补语义名，读屏器此前读「button N」
        icon: Semantics(
          label: Translations.of(context).chat.sidebar.sessionActions,
          child: const Icon(Icons.more_horiz, size: 16),
        ),
        padding: EdgeInsets.zero,
        // P0-E 修复：触控目标 ≥44x44（移动端可访问性规范）
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        onPressed: () => _showMenu(context),
      ),
    );
  }

  void _showMenu(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final renderBox = context.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context, rootOverlay: true)
        .context
        .findRenderObject() as RenderBox?;
    if (renderBox == null || overlay == null) return;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        renderBox.localToGlobal(Offset.zero, ancestor: overlay),
        renderBox.localToGlobal(
          renderBox.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );

    showMenu<String>(
      context: context,
      position: position,
      items: [
        PopupMenuItem<String>(
          value: 'star',
          child: Row(
            children: [
              Icon(
                session.isStarred ? Icons.star : Icons.star_border,
                size: 16,
              ),
              const SizedBox(width: SimpleSpacing.sSm),
              Expanded(
                child: Text(
                  session.isStarred ? t.chat.unstarSession : t.chat.starSession,
                  style: SimpleTextStyles.bodySm,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'rename',
          child: Row(
            children: [
              const Icon(Icons.edit_outlined, size: 16),
              const SizedBox(width: SimpleSpacing.sSm),
              Expanded(
                child: Text(
                  t.chat.rename,
                  style: SimpleTextStyles.bodySm,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'copy',
          child: Row(
            children: [
              const Icon(Icons.content_copy, size: 16),
              const SizedBox(width: SimpleSpacing.sSm),
              Expanded(
                child: Text(
                  t.chat.copySession,
                  style: SimpleTextStyles.bodySm,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'delete',
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 16, color: colors.error),
              const SizedBox(width: SimpleSpacing.sSm),
              Expanded(
                child: Text(
                  t.chat.deleteSession,
                  style: SimpleTextStyles.bodySm.copyWith(color: colors.error),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == 'star') {
        onToggleStar();
      } else if (value == 'rename') {
        onRename();
      } else if (value == 'copy') {
        onCopy();
      } else if (value == 'delete') {
        onDelete();
      }
    });
  }
}

/// 拖动排序把手。
///
/// 使用 ReorderableDragStartListener 显式接管拖动手势，
/// 避免 ReorderableListView 默认 drag handle 与三点菜单重叠
/// （buildDefaultDragHandles: false 时必须显式提供）。
class _DragHandle extends StatelessWidget {
  const _DragHandle({required this.index});

  final int index;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    // 热区扩到 44×44（图标视觉 16px 不变、居中），
    // 此前 28×28 低于触控目标规范。
    // 显式 Semantics label——Tooltip 的语义合并
    // 不覆盖所有读屏场景，对照同文件 _ActionMenu 的显式范式。
    return SizedBox(
      width: 44,
      height: 44,
      child: Semantics(
        label: t.chat.sidebar.dragToReorder,
        child: Tooltip(
          message: t.chat.sidebar.dragToReorder,
          child: Center(
            child: ReorderableDragStartListener(
              index: index,
              child: Icon(
                Icons.drag_indicator,
                size: 16,
                color: colors.muted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
