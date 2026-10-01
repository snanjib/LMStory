import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/story_runtime/domain/entities/message_variant_record.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 稿件变体切换器（导演/故事共享）。
///
/// 稿件卡右下 `◀ n/m ▶`（Chatbox ForkNav 式）：左右切相邻版本，点计数
/// 徽标开版本面板（查看预览/复制/设为当前/删除该版本）。新变体收稿后
/// [flash] 强调色 2s（reduced-motion 免适配——无动画，仅短暂变色）。
///
/// 自 director_chat_body._VariantSwitcher 原样提取
/// 为 story_runtime 共享组件，导演/故事两模式同款。
/// 迁移待办：i18n 暂引 t.advanced.variant.*（导演段），待术语表统一后
/// 迁至共享段；两模式文案一致故暂不拆分。
class MessageVariantSwitcher extends StatefulWidget {
  const MessageVariantSwitcher({
    required this.assistantMessage,
    required this.variants,
    required this.currentIndex,
    required this.onSwitch,
    this.flash = false,
    this.flashStartedAtMs,
    this.onDelete,
    this.onFlashConsumed,
    super.key,
  });

  final ChatMessage assistantMessage;
  final List<MessageVariantRecord> variants;
  final int currentIndex;

  /// 切到指定变体（设为当前）
  final ValueChanged<int> onSwitch;

  /// 删除非当前变体（null = 删除入口不可用）
  final ValueChanged<int>? onDelete;

  /// 新变体刚收稿（2s 强调后回调 [onFlashConsumed] 清除信号）
  final bool flash;

  /// 收稿时刻——2s 窗口从收稿起算：
  /// 行在视口外/延迟滚到时只闪剩余时长；超窗则不高亮、直接消费信号。
  /// null（旧状态）回退为物化时刻起表（兼容装载中的旧会话）。
  final int? flashStartedAtMs;
  final VoidCallback? onFlashConsumed;

  @override
  State<MessageVariantSwitcher> createState() => _MessageVariantSwitcherState();
}

class _MessageVariantSwitcherState extends State<MessageVariantSwitcher> {
  static const Duration _flashWindow = Duration(seconds: 2);

  bool _flashing = false;
  Timer? _flashTimer;

  @override
  void initState() {
    super.initState();
    _armFlash();
  }

  @override
  void didUpdateWidget(covariant MessageVariantSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.flash && !oldWidget.flash) _armFlash();
  }

  void _armFlash() {
    if (!widget.flash) return;
    final startedAt = widget.flashStartedAtMs;
    // 按收稿时刻折算剩余窗口；build 期内不可直接改 provider 状态，
    // 消费信号走 postFrame。
    if (startedAt != null) {
      final elapsed = DateTime.now().millisecondsSinceEpoch - startedAt;
      final remainingMs = _flashWindow.inMilliseconds - elapsed;
      if (remainingMs <= 0) {
        _flashing = false;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onFlashConsumed?.call();
        });
        return;
      }
      setState(() => _flashing = true);
      _flashTimer?.cancel();
      _flashTimer = Timer(Duration(milliseconds: remainingMs), () {
        if (!mounted) return;
        setState(() => _flashing = false);
        widget.onFlashConsumed?.call();
      });
      return;
    }
    setState(() => _flashing = true);
    _flashTimer?.cancel();
    _flashTimer = Timer(_flashWindow, () {
      if (!mounted) return;
      setState(() => _flashing = false);
      widget.onFlashConsumed?.call();
    });
  }

  @override
  void dispose() {
    // 高亮在途时行被卸载（滚出懒加载视口/切页/切会话）——补消费
    // 信号，防 variantFlashTurn 滞留导致每次重新物化都再闪 2s。
    // clearVariantFlash 幂等，双消费无害。
    if (_flashTimer != null) {
      _flashTimer?.cancel();
      widget.onFlashConsumed?.call();
    }
    super.dispose();
  }

  Future<void> _copyVariant(MessageVariantRecord variant) async {
    await Clipboard.setData(
      ClipboardData(text: variant.content ?? ''),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(Translations.of(context).advanced.variant.copyDone),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  void _openSheet() {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    showLmSheet<void>(
      context: context,
      backgroundColor: colors.surfaceElevated,
      builder: (sheetContext) {
        final sheetT = Translations.of(sheetContext);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.all(IntermediateSpacing.sLg),
                child: Text(
                  t.advanced.variant.sheetTitle,
                  style: IntermediateTextStyles.title.copyWith(
                    color: colors.ink,
                  ),
                ),
              ),
              for (final variant in widget.variants)
                ListTile(
                  dense: true,
                  title: Row(
                    children: [
                      Text(
                        '${variant.variantIndex + 1}',
                        style: IntermediateTextStyles.bodyUi.copyWith(
                          color: variant.variantIndex == widget.currentIndex
                              ? colors.primary
                              : colors.ink,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (variant.variantIndex == widget.currentIndex) ...[
                        const SizedBox(width: IntermediateSpacing.sXs),
                        Text(
                          t.advanced.variant.currentBadge,
                          style: IntermediateTextStyles.captionSm.copyWith(
                            color: colors.primary,
                          ),
                        ),
                      ],
                    ],
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        variant.content ?? '',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: IntermediateTextStyles.caption
                            .copyWith(color: colors.muted),
                      ),
                      if ((variant.sourceInput ?? '').isNotEmpty)
                        Text(
                          sheetT.advanced.variant.sourceLabel(
                            input: variant.sourceInput!,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: IntermediateTextStyles.captionSm
                              .copyWith(color: colors.faint),
                        ),
                    ],
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        iconSize: 18,
                        tooltip: t.advanced.variant.copy,
                        onPressed: () => _copyVariant(variant),
                        icon: Icon(Icons.copy, color: colors.muted),
                      ),
                      if (variant.variantIndex != widget.currentIndex &&
                          widget.onDelete != null)
                        IconButton(
                          iconSize: 18,
                          tooltip: t.advanced.variant.delete,
                          onPressed: () {
                            Navigator.of(sheetContext).pop();
                            widget.onDelete!(variant.variantIndex);
                          },
                          icon: Icon(Icons.delete_outline, color: colors.muted),
                        ),
                    ],
                  ),
                  onTap: variant.variantIndex == widget.currentIndex
                      ? null
                      : () {
                          Navigator.of(sheetContext).pop();
                          widget.onSwitch(variant.variantIndex);
                        },
                ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final accent = _flashing ? colors.primary : colors.muted;
    final position = widget.currentIndex + 1;
    final total = widget.variants.length;
    return Padding(
      padding: const EdgeInsets.only(top: IntermediateSpacing.sXs),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          _smallIcon(
            icon: Icons.chevron_left,
            tooltip: t.advanced.variant.prev,
            enabled: widget.currentIndex > 0,
            color: accent,
            onPressed: () => widget.onSwitch(widget.currentIndex - 1),
          ),
          Semantics(
            label: t.advanced.variant.switcherLabel(n: position, m: total),
            button: true,
            child: InkWell(
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
              onTap: _openSheet,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: IntermediateSpacing.sSm,
                  vertical: IntermediateSpacing.s2xs,
                ),
                child: Text(
                  '$position/$total',
                  style: IntermediateTextStyles.caption.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
          _smallIcon(
            icon: Icons.chevron_right,
            tooltip: t.advanced.variant.next,
            enabled: widget.currentIndex < total - 1,
            color: accent,
            onPressed: () => widget.onSwitch(widget.currentIndex + 1),
          ),
        ],
      ),
    );
  }

  Widget _smallIcon({
    required IconData icon,
    required String tooltip,
    required bool enabled,
    required Color color,
    required VoidCallback onPressed,
  }) {
    final colors = context.lm.palette;
    return IconButton(
      visualDensity: VisualDensity.compact,
      iconSize: 18,
      padding: const EdgeInsets.all(IntermediateSpacing.s2xs),
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      tooltip: tooltip,
      onPressed: enabled ? onPressed : null,
      icon: Icon(
        icon,
        color: enabled ? color : colors.faint.withValues(alpha: 0.5),
      ),
    );
  }
}
