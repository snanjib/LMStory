import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 中级模式消息动作横排按钮行（改版，Grok 风格）
///
/// 从 ⋮ PopupMenu 改为横排纯图标 IconButton Row：
/// - 4 个动作横排排列，纯图标无文字（沉浸型，不干扰叙事）
/// - 间距 sMd（16px），比简化模式大，强化沉浸氛围
/// - tap 消息卡片切换显示/隐藏（由 IntermediateMessageBubble 控制）
///
/// 动作列表（两种消息统一显示）：
/// - 复制 copy：始终可用（不依赖 canOperate），ink 色
/// - 重新生成 regenerate：两种消息均显示，需 canOperate
/// - 编辑 edit：两种消息均显示，需 canOperate（对话框内区分保存/保存并发送）
/// - 删除整轮 deleteRound：两种消息均显示，需 canOperate，error 色
///
/// canOperate=false 时的行为（窗口外消息）：
/// - 图标用 faint 色（视觉提示不可用）
/// - 点击弹 SnackBar 提示"只能操作最近 N 轮的消息"
/// - 复制始终可用，不受窗口限制
///
/// 对齐：用户消息右对齐，助手消息左对齐（与气泡对齐一致）。
///
/// impeccable product register：用标准 IconButton，不重新发明 affordance；
/// 危险操作（删除）用 error 色图标强化语义。触控目标 44x44（移动端可访问性）。
class IntermediateMessageActions extends StatelessWidget {
  const IntermediateMessageActions({
    required this.isUser,
    required this.canOperate,
    required this.windowRounds,
    required this.onCopy,
    required this.onRegenerate,
    required this.onEdit,
    required this.onDeleteRound,
    super.key,
  });

  /// 是否为用户消息（决定对齐方向）
  final bool isUser;

  /// 当前消息是否可操作（在 Fork 窗口范围内）
  final bool canOperate;

  /// 窗口轮数（用于 canOperate=false 时的提示文案）
  final int windowRounds;

  /// 复制回调（始终可用）
  final VoidCallback onCopy;

  /// 重新生成回调（两种消息均可用 + canOperate）
  ///
  /// - 助手消息：保留 user_N，删 assistant_N + 下游，重写 assistant_N
  /// - 用户消息：找到下一条 assistant，效果同上
  final VoidCallback onRegenerate;

  /// 编辑回调（两种消息均可用 + canOperate）
  ///
  /// 对话框内区分：
  /// - 用户消息：保存（仅改文本）/ 保存并发送（删下游 + 重新生成）
  /// - 助手消息：保存（仅改文本）
  final VoidCallback onEdit;

  /// 删除整轮回调（canOperate）
  final VoidCallback onDeleteRound;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;

    // 对齐：用户消息右对齐，助手消息左对齐（与气泡对齐一致）
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Wrap(
        alignment: isUser ? WrapAlignment.end : WrapAlignment.start,
        spacing: LmSpacing.sMd,
        runSpacing: LmSpacing.sXs,
        children: _buildButtons(context, colors),
      ),
    );
  }

  /// 构建动作按钮列表（两种消息统一显示）
  ///
  /// 按钮顺序：复制 -> 重新生成 -> 编辑 -> 删除整轮
  /// 按钮间距 sMd（16px），比简化模式大，强化沉浸氛围
  List<Widget> _buildButtons(
    BuildContext context,
    LmPalette colors,
  ) {
    final t = Translations.of(context);
    return [
      // 1. 复制（始终显示，ink 色，不受 canOperate 限制）
      _buildIconButton(
        icon: Icons.copy_outlined,
        color: colors.ink,
        tooltip: t.intermediate.chat.messageActions.copy,
        onPressed: onCopy,
      ),
      // 2. 重新生成（两种消息均显示）
      _buildIconButton(
        icon: Icons.refresh_rounded,
        color: canOperate ? colors.muted : colors.faint,
        tooltip: t.intermediate.chat.messageActions.regenerate,
        onPressed: () => _handleOperate(context, onRegenerate),
      ),
      // 3. 编辑（两种消息均显示，对话框内区分保存/保存并发送）
      _buildIconButton(
        icon: Icons.edit_outlined,
        color: canOperate ? colors.muted : colors.faint,
        tooltip: t.intermediate.chat.messageActions.edit,
        onPressed: () => _handleOperate(context, onEdit),
      ),
      // 4. 删除整轮（两种消息均显示，危险操作用 error 色）
      _buildIconButton(
        icon: Icons.delete_outline,
        color: canOperate ? colors.error : colors.faint,
        tooltip: t.intermediate.chat.messageActions.deleteRound,
        onPressed: () => _handleOperate(context, onDeleteRound),
      ),
    ];
  }

  /// 构建单个 IconButton
  ///
  /// - 图标 20px（与原 PopupMenu 触发图标一致）
  /// - 触控目标 44x44（移动端可访问性，与 Simple 模式一致）
  /// - splashRadius 18（水波纹收敛，视觉精致，符合夜航收敛书页感）
  /// - tooltip 长按触发（系统默认），与 tap 切换显示不冲突：
  ///   tap 切换 actions 显隐，长按弹 tooltip 帮助初次使用识别图标含义
  Widget _buildIconButton({
    required IconData icon,
    required Color color,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      icon: Icon(icon, size: 20, color: color),
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
      splashRadius: 18,
      tooltip: tooltip,
    );
  }

  /// canOperate=false 时弹 SnackBar 提示；canOperate=true 时直接执行回调
  ///
  /// 复制动作不经过此方法（始终可用），直接调用 onCopy。
  void _handleOperate(BuildContext context, VoidCallback action) {
    if (!canOperate) {
      final t = Translations.of(context);
      final message = t.intermediate.chat.messageActions.windowExceeded(
        count: windowRounds,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(behavior: SnackBarBehavior.floating, content: Text(message)),
      );
      return;
    }
    action();
  }
}
