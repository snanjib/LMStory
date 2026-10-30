import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/simple/simple_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/chat/domain/entities/chat_mode.dart';
import 'package:lmstory/features/diagnostics/domain/entities/failure_log_entry.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 失败历史列表组件（诊断页）
///
/// 展示 failure_logs 表最近 50 条记录，列表项显示时间 + 模式徽章 + 错误码 +
/// 分类徽章 + 消息摘要，点击展开 rawError 等技术详情。
///
/// 视觉决策（impeccable）：
/// - 分类用胶囊徽章（背景 12% 透明度 + 语义色文字），避免 side-stripe 禁令
/// - 展开动画用 AnimatedSize 200ms easeOutQuart；reduced-motion 时瞬切
/// - 详情面板的 rawError 用等宽字体，长文本可滚动
class FailureHistory extends StatelessWidget {
  const FailureHistory({required this.failures, super.key});

  final List<FailureLogEntry> failures;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      padding: const EdgeInsets.all(SimpleSpacing.sLg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.settings.diagnostics.failures.title,
            style: SimpleTextStyles.title3.copyWith(
              color: colors.ink,
              fontWeight: FontWeight.w600,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            t.settings.diagnostics.failures.desc,
            style: SimpleTextStyles.caption.copyWith(color: colors.muted),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: SimpleSpacing.sMd),
          if (failures.isEmpty)
            _EmptyFailures(colors: colors)
          else
            Column(
              children: [
                for (var i = 0; i < failures.length; i++) ...[
                  if (i > 0) const SizedBox(height: SimpleSpacing.sSm),
                  _FailureItem(entry: failures[i]),
                ],
              ],
            ),
        ],
      ),
    );
  }
}

class _EmptyFailures extends StatelessWidget {
  const _EmptyFailures({required this.colors});

  final LmPalette colors;

  @override
  Widget build(BuildContext context) {
    final t = Translations.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SimpleSpacing.sXl),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline, size: 36, color: colors.success),
            const SizedBox(height: SimpleSpacing.sSm),
            Text(
              t.settings.diagnostics.failures.empty,
              style: SimpleTextStyles.bodySm.copyWith(
                color: colors.ink,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 2),
            Text(
              t.settings.diagnostics.failures.emptyDesc,
              style: SimpleTextStyles.caption.copyWith(color: colors.muted),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _FailureItem extends StatefulWidget {
  const _FailureItem({required this.entry});

  final FailureLogEntry entry;

  @override
  State<_FailureItem> createState() => _FailureItemState();
}

class _FailureItemState extends State<_FailureItem> {
  bool _expanded = false;

  void _toggle() => setState(() => _expanded = !_expanded);

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    // 两条件取或（OS 减弱动态效果 + 辅助导航）。
    final reducedMotion = LmMotion.reducedMotion(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _toggle,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        child: Container(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
          ),
          padding: const EdgeInsets.all(SimpleSpacing.sMd),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 摘要行：时间 + 模式徽章 + 错误码
              Row(
                children: [
                  Flexible(
                    child: Text(
                      _formatTime(widget.entry.createdAt),
                      style: SimpleTextStyles.caption.copyWith(
                        color: colors.faint,
                        fontFamily: 'monospace',
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: SimpleSpacing.sSm),
                  _ModeBadge(mode: widget.entry.mode),
                  const Spacer(),
                  if (widget.entry.errorCode != null)
                    Flexible(
                      child: Text(
                        widget.entry.errorCode!,
                        style: SimpleTextStyles.caption.copyWith(
                          color: colors.ink,
                          fontWeight: FontWeight.w600,
                          fontFamily: 'monospace',
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  const SizedBox(width: SimpleSpacing.s2xs),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 18,
                    color: colors.faint,
                  ),
                ],
              ),
              const SizedBox(height: SimpleSpacing.sXs),
              // 分类徽章 + 消息
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _CategoryBadge(category: widget.entry.errorCategory),
                  // 批 F / P8：被自动重试救回的失败条目带「已自动恢复」徽标
                  if (widget.entry.isRecovered) ...[
                    const SizedBox(width: SimpleSpacing.sXs),
                    _RecoveredBadge(),
                  ],
                  const SizedBox(width: SimpleSpacing.sSm),
                  Expanded(
                    child: Text(
                      widget.entry.errorMessage ??
                          widget.entry.rawError ??
                          t.settings.diagnostics.failures.unknown,
                      style: SimpleTextStyles.bodySm.copyWith(
                        color: colors.ink,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              // 展开详情
              AnimatedSize(
                duration: reducedMotion ? Duration.zero : LmMotion.base,
                curve: LmMotion.easeSnap,
                alignment: Alignment.topCenter,
                child: _expanded
                    ? Padding(
                        padding: const EdgeInsets.only(top: SimpleSpacing.sMd),
                        child: _DetailPanel(entry: widget.entry),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}:${two(time.second)}';
  }
}

class _DetailPanel extends StatelessWidget {
  const _DetailPanel({required this.entry});

  final FailureLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.sm)),
      ),
      padding: const EdgeInsets.all(SimpleSpacing.sMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DetailRow(
            label: t.settings.diagnostics.failures.session,
            value: entry.sessionId,
            mono: true,
          ),
          if (entry.failedPhase != null) ...[
            const SizedBox(height: SimpleSpacing.sXs),
            _DetailRow(
              label: t.settings.diagnostics.failures.phase,
              value: entry.failedPhase!,
              mono: true,
            ),
          ],
          if (entry.httpStatus != null) ...[
            const SizedBox(height: SimpleSpacing.sXs),
            _DetailRow(
              label: t.settings.diagnostics.failures.httpStatus,
              value: '${entry.httpStatus}',
              mono: true,
            ),
          ],
          if (entry.rawError != null) ...[
            const SizedBox(height: SimpleSpacing.sMd),
            Text(
              t.settings.diagnostics.failures.rawError,
              style: SimpleTextStyles.caption.copyWith(
                color: colors.muted,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: SimpleSpacing.s2xs),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 160),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius:
                    BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
              ),
              padding: const EdgeInsets.all(SimpleSpacing.sSm),
              child: SingleChildScrollView(
                child: SelectableText(
                  entry.rawError!,
                  // 同 log_viewer_widget：移除 RobotoMono/Courier New fallback
                  // 以修复中文显示为方块字符的问题。
                  style: SimpleTextStyles.caption.copyWith(
                    fontFamily: 'monospace',
                    height: 1.5,
                    color: colors.ink,
                    fontSize: 11,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.label,
    required this.value,
    this.mono = false,
  });

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: SimpleTextStyles.caption.copyWith(color: colors.muted),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: SimpleTextStyles.caption.copyWith(
              color: colors.ink,
              fontFamily: mono ? 'monospace' : null,
            ),
          ),
        ),
      ],
    );
  }
}

/// 「已自动恢复」徽标（批 F：failure_logs.outcome=recovered 的条目）
class _RecoveredBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sXs,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: colors.success.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        t.settings.diagnostics.failures.recoveredBadge,
        style: SimpleTextStyles.caption.copyWith(
          color: colors.success,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ModeBadge extends StatelessWidget {
  const _ModeBadge({required this.mode});

  final String mode;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    // 三态：对话/故事/导演（导演此前落入"对话"，属 mode 误标 bug）
    final label = mode == ChatMode.intermediate
        ? t.settings.diagnostics.mode.intermediate
        : mode == ChatMode.advanced
            ? t.settings.diagnostics.mode.advanced
            : t.settings.diagnostics.mode.chat;

    return _Badge(
      label: label,
      textColor: colors.muted,
      bgColor: colors.surfaceVariant,
    );
  }
}

class _CategoryBadge extends StatelessWidget {
  const _CategoryBadge({required this.category});

  final String category;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final (label, color) = _categoryStyle(category, t, colors);

    return _Badge(
      label: label,
      textColor: color,
      bgColor: color.withValues(alpha: 0.12),
    );
  }

  (String, Color) _categoryStyle(
    String category,
    Translations t,
    LmPalette colors,
  ) {
    final c = t.settings.diagnostics.category;
    switch (category) {
      case 'network':
        return (c.network, colors.warning);
      case 'timeout':
        return (c.timeout, colors.warning);
      case 'auth':
        return (c.auth, colors.error);
      case 'rateLimit':
        return (c.rateLimit, colors.warning);
      case 'server':
        return (c.server, colors.error);
      case 'config':
        return (c.config, colors.accent);
      case 'format':
        return (c.format, colors.accent);
      case 'persist':
        return (c.persist, colors.error);
      default:
        return (c.unknown, colors.muted);
    }
  }
}

class _Badge extends StatelessWidget {
  const _Badge({
    required this.label,
    required this.textColor,
    required this.bgColor,
  });

  final String label;
  final Color textColor;
  final Color bgColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SimpleSpacing.sSm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.full)),
      ),
      child: Text(
        label,
        style: SimpleTextStyles.overline.copyWith(
          color: textColor,
          fontWeight: FontWeight.w600,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
