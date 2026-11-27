import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A tap on selectable prose puts a collapsed caret under the finger.
/// EditableText asks for padding around it, even when the line is visible.
mixin ConversationTextReveal on RenderObject {
  @override
  void showOnScreen({
    RenderObject? descendant,
    Rect? rect,
    Duration duration = Duration.zero,
    // lm-motion-exempt: Forward RenderObject.showOnScreen's framework default.
    Curve curve = Curves.ease,
  }) {
    var reveal = rect;
    if (descendant is RenderEditable && descendant.readOnly && rect != null) {
      final selection = descendant.selection;
      final viewport = RenderAbstractViewport.maybeOf(this);
      if (selection != null &&
          selection.isValid &&
          selection.isCollapsed &&
          viewport != null) {
        final caret = descendant.getLocalRectForCaret(selection.extent);
        final visible = MatrixUtils.transformRect(
          viewport.getTransformTo(descendant),
          viewport.paintBounds,
        );
        if (rect.contains(caret.center) && visible.overlaps(caret)) {
          reveal = visible.intersect(caret);
        }
      }
    }
    super.showOnScreen(
      descendant: descendant,
      rect: reveal,
      duration: duration,
      curve: curve,
    );
  }
}
