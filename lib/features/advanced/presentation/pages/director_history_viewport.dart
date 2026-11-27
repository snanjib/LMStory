part of 'director_chat_body.dart';

enum _DirectorOrigin { start, message, latest }

class _DirectorBookmark {
  const _DirectorBookmark(this.id, this.offsetInRow, {this.fromProse = false});
  final String id;
  final double offsetInRow;
  final bool fromProse;
}

/// Index zero of the forward sliver is the requested reading position. The
/// preceding sliver grows upwards from the same point, without visiting the
/// intervening children when the origin moves to a distant message.
class _DirectorHistoryViewport {
  final before = GlobalKey();
  final after = GlobalKey();
  final spacer = GlobalKey();
  int pivot = 0;

  double? get extentBeforeOrigin {
    final render = before.currentContext?.findRenderObject();
    return render is RenderSliver ? render.geometry?.scrollExtent : null;
  }

  bool get hasReadingTail {
    final render = spacer.currentContext?.findRenderObject();
    return render is RenderSliver && (render.geometry?.scrollExtent ?? 0) > 1;
  }

  ({int item, double top})? firstVisible() {
    ({int item, double top})? first;
    void inspect(GlobalKey key, {required bool backwards}) {
      final list = key.currentContext?.findRenderObject();
      if (list is! RenderSliverMultiBoxAdaptor || !list.attached) return;
      final viewport = RenderAbstractViewport.of(list);
      var child = list.firstChild;
      while (child != null) {
        if (child.hasSize && child.size.height > 0) {
          final top = child.localToGlobal(Offset.zero, ancestor: viewport).dy;
          final current = first;
          if (top + child.size.height > 0.5 &&
              (current == null || top < current.top)) {
            final index = list.indexOf(child);
            first =
                (item: backwards ? pivot - 1 - index : pivot + index, top: top);
          }
        }
        child = list.childAfter(child);
      }
    }

    inspect(before, backwards: true);
    inspect(after, backwards: false);
    return first;
  }

  double? rowTop(int item) {
    final backwards = item < pivot;
    final list =
        (backwards ? before : after).currentContext?.findRenderObject();
    if (list is! RenderSliverMultiBoxAdaptor || !list.attached) return null;
    final index = backwards ? pivot - 1 - item : item - pivot;
    var child = list.firstChild;
    while (child != null) {
      if (list.indexOf(child) == index && child.hasSize) {
        return child
            .localToGlobal(
              Offset.zero,
              ancestor: RenderAbstractViewport.of(list),
            )
            .dy;
      }
      child = list.childAfter(child);
    }
    return null;
  }

  Widget build({
    required ScrollController controller,
    required int pivotIndex,
    required bool anchorAtBottom,
    required int itemCount,
    required IndexedWidgetBuilder itemBuilder,
    required int? Function(Key) indexForKey,
    required bool allowReadingTail,
    required double innerOffset,
  }) {
    pivot = pivotIndex.clamp(0, itemCount);
    int? childIndex(Key key, {required bool backwards}) {
      final item = indexForKey(key);
      if (item == null || (item < pivot) != backwards) return null;
      return backwards ? pivot - 1 - item : item - pivot;
    }

    Widget row(BuildContext context, int item) {
      final child = itemBuilder(context, item);
      if (item == 0 || item == itemCount - 1) return child;
      return IndexedSemantics(key: child.key, index: item - 1, child: child);
    }

    return _DirectorHistoryScrollView(
      key: ObjectKey(this),
      controller: controller,
      semanticChildCount: itemCount - 2,
      center: after,
      anchor: anchorAtBottom ? 1 : 0,
      scrollCacheExtent: const ScrollCacheExtent.pixels(600),
      slivers: [
        SliverList.builder(
          key: before,
          addSemanticIndexes: false,
          itemCount: pivot,
          findChildIndexCallback: (key) => childIndex(key, backwards: true),
          itemBuilder: (context, index) => row(context, pivot - 1 - index),
        ),
        SliverList.builder(
          key: after,
          addSemanticIndexes: false,
          itemCount: itemCount - pivot,
          findChildIndexCallback: (key) => childIndex(key, backwards: false),
          itemBuilder: (context, index) => row(context, pivot + index),
        ),
        SliverLayoutBuilder(
          builder: (context, constraints) {
            // The last short round still starts at the top of the viewport.
            // This space contracts as real content grows and disappears on
            // an explicit return to the latest message.
            final missing = constraints.viewportMainAxisExtent +
                innerOffset -
                constraints.precedingScrollExtent;
            return SliverToBoxAdapter(
              key: spacer,
              child: SizedBox(
                height: allowReadingTail && missing > 0 ? missing : 0,
              ),
            );
          },
        ),
      ],
    );
  }
}

class _DirectorHistoryScrollView extends CustomScrollView {
  const _DirectorHistoryScrollView({
    required super.key,
    required super.controller,
    required super.semanticChildCount,
    required super.center,
    required super.anchor,
    required super.scrollCacheExtent,
    required super.slivers,
  });

  @override
  Widget buildViewport(
    BuildContext context,
    ViewportOffset offset,
    AxisDirection axisDirection,
    List<Widget> slivers,
  ) =>
      _DirectorViewport(
        axisDirection: axisDirection,
        offset: offset,
        center: center,
        anchor: anchor,
        scrollCacheExtent: scrollCacheExtent,
        slivers: slivers,
      );
}

class _DirectorViewport extends Viewport {
  _DirectorViewport({
    required super.axisDirection,
    required super.offset,
    required super.center,
    required super.anchor,
    required super.scrollCacheExtent,
    required super.slivers,
  });

  @override
  RenderViewport createRenderObject(BuildContext context) =>
      _RenderDirectorViewport(
        axisDirection: axisDirection,
        crossAxisDirection:
            Viewport.getDefaultCrossAxisDirection(context, axisDirection),
        offset: offset,
        anchor: anchor,
        scrollCacheExtent: scrollCacheExtent,
      );
}

class _RenderDirectorViewport extends RenderViewport
    with ConversationTextReveal {
  _RenderDirectorViewport({
    required super.axisDirection,
    required super.crossAxisDirection,
    required super.offset,
    required super.anchor,
    required super.scrollCacheExtent,
  });

  // Text selection and accessibility both use getOffsetToReveal. The sliver
  // offsets are relative to the center; when reading from the end its origin
  // is at the bottom of the viewport, a full viewport below its top.
  @override
  double scrollOffsetOf(RenderSliver child, double scrollOffsetWithinChild) =>
      super.scrollOffsetOf(child, scrollOffsetWithinChild) +
      size.height * anchor;
}
