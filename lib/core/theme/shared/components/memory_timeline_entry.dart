import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';

/// A rail only for entries displayed in narrative order.
class MemoryTimelineEntry extends StatelessWidget {
  const MemoryTimelineEntry({
    required this.child,
    required this.isFirst,
    required this.isLast,
    super.key,
  });

  final Widget child;
  final bool isFirst;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return Stack(
      children: [
        PositionedDirectional(
          start: 5,
          width: 1,
          top: isFirst ? 23 : 0,
          bottom: isLast ? null : 0,
          height: isLast ? (isFirst ? 0 : 23) : null,
          child: ColoredBox(color: colors.dividerStrong),
        ),
        PositionedDirectional(
          start: 1,
          top: 19,
          child: Container(
            width: 9,
            height: 9,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colors.primary,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsetsDirectional.only(start: 24, bottom: 16),
          child: child,
        ),
      ],
    );
  }
}
