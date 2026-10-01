import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事 vs 对话模式对比示意图（2026-07-27 新增）。
///
/// 用于「故事模式与对话模式的区别」wiki 页顶部主视觉。
///
/// 设计：三栏对比（对话模式 vs 故事模式 vs 导演模式），每栏 4 个维度
/// （入口卡片 / 视觉风格 / 字体 / 输入框文案）。
///
/// 视觉传达：三种模式入口与界面独立，按需选择
class StoryVsChatDiagram extends StatelessWidget {
  const StoryVsChatDiagram({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Container(
      padding: const EdgeInsets.all(SimpleSpacing.sMd),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左栏：对话模式
          Expanded(
            child: _ModeColumn(
              title: t.help.storyVsChat.columnChat,
              accentColor: colors.primary,
              dimColor: colors.primaryDim,
              icon: Icons.chat_bubble_outline,
              rows: [
                _RowData(
                  icon: Icons.touch_app_outlined,
                  label: t.help.storyVsChat.chatEntry,
                ),
                _RowData(
                  icon: Icons.palette_outlined,
                  label: t.help.storyVsChat.chatPalette,
                ),
                _RowData(
                  icon: Icons.text_fields,
                  label: t.help.storyVsChat.chatFont,
                ),
                _RowData(
                  icon: Icons.edit_outlined,
                  label: t.help.storyVsChat.chatInput,
                ),
              ],
            ),
          ),
          Container(
            width: 1,
            color: colors.divider,
            margin: const EdgeInsets.symmetric(horizontal: SimpleSpacing.sSm),
          ),
          // 右栏：故事模式
          Expanded(
            child: _ModeColumn(
              title: t.help.storyVsChat.columnStory,
              accentColor: colors.accent,
              dimColor: colors.accentDim,
              icon: Icons.auto_stories,
              rows: [
                _RowData(
                  icon: Icons.touch_app_outlined,
                  label: t.help.storyVsChat.storyEntry,
                ),
                _RowData(
                  icon: Icons.palette_outlined,
                  label: t.help.storyVsChat.storyPalette,
                ),
                _RowData(
                  icon: Icons.text_fields,
                  label: t.help.storyVsChat.storyFont,
                ),
                _RowData(
                  icon: Icons.auto_stories_outlined,
                  label: t.help.storyVsChat.storyInput,
                ),
              ],
            ),
          ),
          Container(
            width: 1,
            color: colors.divider,
            margin: const EdgeInsets.symmetric(horizontal: SimpleSpacing.sSm),
          ),
          // 第三栏：导演模式（实验）
          Expanded(
            child: _ModeColumn(
              title: t.help.storyVsChat.columnDirector,
              accentColor: colors.warning,
              dimColor: colors.warning.withValues(alpha: 0.12),
              icon: Icons.theater_comedy_outlined,
              rows: [
                _RowData(
                  icon: Icons.touch_app_outlined,
                  label: t.help.storyVsChat.directorEntry,
                ),
                _RowData(
                  icon: Icons.palette_outlined,
                  label: t.help.storyVsChat.directorPalette,
                ),
                _RowData(
                  icon: Icons.text_fields,
                  label: t.help.storyVsChat.directorFont,
                ),
                _RowData(
                  icon: Icons.edit_outlined,
                  label: t.help.storyVsChat.directorInput,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RowData {
  const _RowData({required this.icon, required this.label});
  final IconData icon;
  final String label;
}

class _ModeColumn extends StatelessWidget {
  const _ModeColumn({
    required this.title,
    required this.accentColor,
    required this.dimColor,
    required this.icon,
    required this.rows,
  });

  final String title;
  final Color accentColor;
  final Color dimColor;
  final IconData icon;
  final List<_RowData> rows;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 顶部标题：图标 + 名称
        Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: dimColor,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: accentColor, size: 16),
            ),
            const SizedBox(width: SimpleSpacing.s2xs),
            Flexible(
              child: Text(
                title,
                style: SimpleTextStyles.bodySm.copyWith(
                  color: colors.ink,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: SimpleSpacing.sSm),
        // 4 行维度
        ...rows.map(
          (row) => Padding(
            padding: const EdgeInsets.symmetric(vertical: SimpleSpacing.s2xs),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(row.icon, color: colors.muted, size: 14),
                const SizedBox(width: SimpleSpacing.s2xs),
                Expanded(
                  child: Text(
                    row.label,
                    style: SimpleTextStyles.caption.copyWith(
                      color: colors.muted,
                      fontSize: 11,
                      height: 1.4,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
