import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 「未配置嵌入模型」常驻提示 Banner（故事模式聊天页顶部）
///
/// 2026-07-21 新增。背景：用户反馈"embedding 调用失败静默降级"问题，
/// 其中一个场景是「从未配置 embedding 模型」——用户开箱即用就是 FTS5
/// 字符串匹配，但 UI 完全不告诉用户。本 Banner 解决此感知缺失。
///
/// 设计要点（impeccable 规范）：
/// - 使用 warning 透明底色 + 完整边框，**不使用 border-left 侧条**（AI slop）
/// - 图标 + 文字 + 主操作按钮，紧凑横向布局
/// - 可手动关闭（本会话内不再显示），重启 App 后如仍未配置则再次显示
/// - 文字对比度 ≥4.5:1，正文用 `ink` 而非 `muted`
///
/// 显示条件（由调用方控制）：
/// - `intermediateConfig.embeddingPresetId` 为空 OR
/// - `intermediateConfig.embeddingModelId` 为空
///
/// 交互：
/// - 点击「去配置」→ 跳转故事模式设置→嵌入模型页（由 onConfigure 回调）
/// - 点击关闭按钮 → 调用 onDismiss，本会话内不再显示
class EmbeddingMissingBanner extends StatelessWidget {
  const EmbeddingMissingBanner({
    required this.onConfigure,
    required this.onDismiss,
    super.key,
  });

  /// 点击「去配置」回调
  final VoidCallback onConfigure;

  /// 点击关闭按钮回调（本会话内不再显示）
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: LmSpacing.sMd,
        vertical: LmSpacing.sXs,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: LmSpacing.sMd,
        vertical: LmSpacing.sSm,
      ),
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(LmSpacing.sSm),
        border: Border.all(
          color: colors.warning.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.search_off,
            size: 20,
            color: colors.warning,
          ),
          const SizedBox(width: LmSpacing.sSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  t.intermediate.chat.embeddingMissingBanner.title,
                  style: LmNarrativeTextStyles.label.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  t.intermediate.chat.embeddingMissingBanner.message,
                  style: LmNarrativeTextStyles.caption.copyWith(
                    color: colors.ink.withValues(alpha: 0.85),
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: LmSpacing.sSm),
          TextButton(
            onPressed: onConfigure,
            style: TextButton.styleFrom(
              foregroundColor: colors.primary,
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(
                horizontal: LmSpacing.sSm,
              ),
              textStyle: LmNarrativeTextStyles.label,
            ),
            child: Text(
              t.intermediate.chat.embeddingMissingBanner.configure,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, size: 18, color: colors.muted),
            onPressed: onDismiss,
            tooltip: t.intermediate.chat.embeddingMissingBanner.dismiss,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }
}
