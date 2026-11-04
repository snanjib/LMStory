import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_readable_color.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_tool_card.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// A reasoning disclosure with a live tail and a separate reading viewport.
class DirectorThinkingBlock extends StatefulWidget {
  const DirectorThinkingBlock({
    required this.content,
    this.duration,
    this.active = false,
    this.incomplete = false,
    this.previewOnly = false,
    super.key,
  });

  final String content;
  final Duration? duration;
  final bool active;
  final bool incomplete;
  final bool previewOnly;

  @override
  State<DirectorThinkingBlock> createState() => _DirectorThinkingBlockState();
}

class _DirectorThinkingBlockState extends State<DirectorThinkingBlock> {
  final _scroll = ScrollController();
  bool _expanded = false;
  bool _following = true;

  @override
  void didUpdateWidget(DirectorThinkingBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_expanded && _following && oldWidget.content != widget.content) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients && _following) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final style = DefaultTextStyle.of(context)
        .style
        .merge(IntermediateTextStyles.caption)
        .copyWith(
          color: directorReadableColor(colors),
          height: 1.5,
        );
    final title = widget.active
        ? t.advanced.process.thinkingActive
        : widget.incomplete
            ? t.advanced.process.thinkingIncomplete
            : widget.duration != null && widget.duration!.inSeconds > 0
                ? t.advanced.process
                    .thinkingDuration(seconds: widget.duration!.inSeconds)
                : t.advanced.live.thinkingCount(count: widget.content.length);
    final expanded = _expanded && !widget.previewOnly;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!widget.previewOnly)
            Semantics(
              button: true,
              expanded: expanded,
              child: InkWell(
                onTap: () => setState(() {
                  _expanded = !_expanded;
                  if (_expanded && widget.active) {
                    _following = true;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted && _scroll.hasClients) {
                        _scroll.jumpTo(_scroll.position.maxScrollExtent);
                      }
                    });
                  }
                }),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 44),
                  child: Row(
                    children: [
                      Icon(
                        expanded ? Icons.expand_more : Icons.chevron_right,
                        size: 16,
                        color: colors.muted,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: widget.active
                            ? ShimmerText(title, style: style)
                            : Text(title, style: style),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.only(left: 22),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight:
                      math.min(240, MediaQuery.sizeOf(context).height * .4),
                ),
                child: NotificationListener<ScrollNotification>(
                  onNotification: (notification) {
                    if (notification is ScrollUpdateNotification &&
                            notification.dragDetails != null ||
                        notification is UserScrollNotification) {
                      _following = notification.metrics.extentAfter < 24;
                    }
                    return false;
                  },
                  child: Scrollbar(
                    controller: _scroll,
                    child: SingleChildScrollView(
                      controller: _scroll,
                      primary: false,
                      child: SelectableText(widget.content, style: style),
                    ),
                  ),
                ),
              ),
            )
          else if (widget.active)
            Padding(
              padding: const EdgeInsets.only(left: 22),
              child: ThinkingTailPreview(content: widget.content, style: style),
            ),
        ],
      ),
    );
  }
}

/// Paint the last three visual lines without slicing words or Unicode clusters.
class ThinkingTailPreview extends StatefulWidget {
  const ThinkingTailPreview({
    required this.content,
    required this.style,
    super.key,
  });
  final String content;
  final TextStyle style;

  @override
  State<ThinkingTailPreview> createState() => _ThinkingTailPreviewState();
}

class _ThinkingTailPreviewState extends State<ThinkingTailPreview> {
  TextPainter? _text;
  Object? _signature;

  @override
  void dispose() {
    _text?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, bounds) {
          final signature = (
            widget.content,
            widget.style,
            bounds.maxWidth,
            Directionality.of(context),
            MediaQuery.textScalerOf(context)
          );
          if (_signature != signature) {
            _text?.dispose();
            _text = TextPainter(
              text: TextSpan(text: widget.content, style: widget.style),
              textDirection: Directionality.of(context),
              textScaler: MediaQuery.textScalerOf(context),
            )..layout(maxWidth: bounds.maxWidth);
            _signature = signature;
          }
          final text = _text!;
          final lines = text.computeLineMetrics();
          final top = lines.length > 3
              ? lines[lines.length - 3].baseline -
                  lines[lines.length - 3].ascent
              : 0.0;
          final start = text.getPositionForOffset(Offset(0, top)).offset;
          return Semantics(
            label: widget.content.substring(start),
            child: SizedBox(
              width: bounds.maxWidth,
              height: text.height - top,
              child: CustomPaint(painter: _TailPainter(text, top)),
            ),
          );
        },
      );
}

class _TailPainter extends CustomPainter {
  _TailPainter(this.text, this.top);
  final TextPainter text;
  final double top;
  @override
  void paint(Canvas canvas, Size size) {
    canvas
      ..save()
      ..clipRect(Offset.zero & size);
    text.paint(canvas, Offset(0, -top));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TailPainter oldDelegate) => true;
}
