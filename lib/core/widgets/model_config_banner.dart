import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';

/// 「模型未配置」引导横幅壳（三模式会话页空态/草稿态共用）。
///
/// 与 EmbeddingMissingBanner 同族视觉（warning 透明底+整边框，无侧条）：
/// 三模式的判定链与跳转目标不同，文案与回调由宿主注入。关闭状态由
/// 组件自持（页面级记忆，离开会话页即重置）；配置完成后宿主侧
/// visible=false 自然卸载，无需通知本组件。
class ModelConfigBanner extends StatefulWidget {
  const ModelConfigBanner({
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.dismissTooltip,
    required this.onConfigure,
    super.key,
  });

  final String title;
  final String message;
  final String actionLabel;
  final String dismissTooltip;

  /// 点击主操作（去配置）回调。
  final VoidCallback onConfigure;

  @override
  State<ModelConfigBanner> createState() => _ModelConfigBannerState();
}

class _ModelConfigBannerState extends State<ModelConfigBanner> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    final colors = context.lm.palette;

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
        border: Border.all(color: colors.warning.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off_outlined, size: 20, color: colors.warning),
          const SizedBox(width: LmSpacing.sSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.title,
                  style: LmNarrativeTextStyles.label.copyWith(
                    color: colors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  widget.message,
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
            onPressed: widget.onConfigure,
            style: TextButton.styleFrom(
              foregroundColor: colors.primary,
              minimumSize: const Size(0, 36),
              padding: const EdgeInsets.symmetric(horizontal: LmSpacing.sSm),
              textStyle: LmNarrativeTextStyles.label,
            ),
            child: Text(
              widget.actionLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, size: 18, color: colors.muted),
            onPressed: () => setState(() => _dismissed = true),
            tooltip: widget.dismissTooltip,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }
}
