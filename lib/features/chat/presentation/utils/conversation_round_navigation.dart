import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:lmstory/core/widgets/conversation_text_reveal.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';

/// Tracks the laid-out rows, including a reply taller than the entire viewport.
/// Only attached rows retain a render object, regardless of history length.
class ConversationRoundNavigation {
  ConversationRoundNavigation(this.controller, {required this.onTailChanged});

  final ScrollController controller;
  final VoidCallback onTailChanged;
  final _rows = <int, ConversationRoundRenderBox>{};
  List<ChatMessage>? _messages;
  ChatMessage? _pending;
  List<int> _users = const [];
  String? _selected;
  int _generation = 0;
  double _tail = 0;
  double get tail => _tail;
  bool get readingSelection => _selected != null;

  void update(List<ChatMessage> messages, {ChatMessage? pending}) {
    if (identical(_messages, messages) && identical(_pending, pending)) return;
    _messages = messages;
    _pending = pending;
    _users = [
      for (var i = 0; i < messages.length; i++)
        if (messages[i].role == 'user') i,
      if (pending != null) messages.length,
    ];
    if (_selected != null && !_users.any((i) => _id(i) == _selected)) {
      reset();
    }
  }

  String? _id(int index) => index == _messages?.length
      ? _pending?.messageId
      : _messages?[index].messageId;

  double _top(ConversationRoundRenderBox box) =>
      RenderAbstractViewport.of(box).getOffsetToReveal(box, 0).offset;

  int? get firstVisible {
    if (!controller.hasClients) return null;
    final pixels = controller.position.pixels;
    int? before;
    int? after;
    for (final entry in _rows.entries) {
      final box = entry.value;
      if (!box.hasSize || box.size.height <= 0) continue;
      final y = _top(box);
      if (y <= pixels + 1) {
        if (before == null || before < entry.key) before = entry.key;
      } else if (after == null || after > entry.key) {
        after = entry.key;
      }
    }
    return before ?? after;
  }

  int? _adjacent(bool forward) {
    if (_users.isEmpty) return null;
    var rank =
        _selected == null ? -1 : _users.indexWhere((i) => _id(i) == _selected);
    if (rank < 0) {
      final index = firstVisible;
      if (index == null) return null;
      var low = 0;
      var high = _users.length;
      while (low < high) {
        final mid = (low + high) ~/ 2;
        if (_users[mid] <= index) {
          low = mid + 1;
        } else {
          high = mid;
        }
      }
      rank = low - 1;
    }
    final target = rank + (forward ? 1 : -1);
    return target < 0 || target >= _users.length ? null : _users[target];
  }

  bool canJump({required bool forward}) => _adjacent(forward) != null;

  void jump({required bool forward}) {
    final index = _adjacent(forward);
    if (index == null) return;
    final target = _id(index);
    if (target == null) return;
    _selected = target;
    _seek(target, ++_generation);
  }

  void _seek(String target, int generation) {
    if (generation != _generation || !controller.hasClients) return;
    final rank = _users.indexWhere((i) => _id(i) == target);
    if (rank < 0) return;
    final index = _users[rank];
    final position = controller.position;
    final box = _rows[index];
    if (box != null && box.hasSize) {
      final offset = _top(box);
      final double missing =
          math.max(0, offset - (position.maxScrollExtent - _tail));
      if ((missing - _tail).abs() > 1) {
        _tail = missing;
        onTailChanged();
      } else if ((position.pixels - offset).abs() <= 1) {
        return;
      }
      final available =
          offset.clamp(position.minScrollExtent, position.maxScrollExtent);
      if ((position.pixels - available).abs() > .1) position.jumpTo(available);
    } else {
      // Advance from measured row edges. A single very long reply may span
      // dozens of viewports; jumping to its edge skips that distance at once.
      final attached = _rows.entries.where((e) => e.value.hasSize).toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      if (attached.isEmpty) return;
      final before = attached.where((e) => e.key < index).lastOrNull;
      final after = attached.where((e) => e.key > index).firstOrNull;
      final double offset;
      if (before != null && after != null) {
        offset = (_top(before.value) +
                before.value.size.height +
                _top(after.value)) /
            2;
      } else if (before != null) {
        offset = _top(before.value) + before.value.size.height;
      } else {
        offset = _top(after!.value) - position.viewportDimension;
      }
      final next =
          offset.clamp(position.minScrollExtent, position.maxScrollExtent);
      if ((next - position.pixels).abs() < .1) return;
      position.jumpTo(next);
    }
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _seek(target, generation));
    WidgetsBinding.instance.scheduleFrame();
  }

  void cancelSelection() {
    _generation++;
    _selected = null;
  }

  void reset() {
    cancelSelection();
    _tail = 0;
  }

  void clearTail() {
    final hadTail = _tail > 0;
    reset();
    if (hadTail) onTailChanged();
  }
}

class ConversationRoundRow extends SingleChildRenderObjectWidget {
  const ConversationRoundRow({
    required this.navigation,
    required this.index,
    required super.child,
    super.key,
  });

  final ConversationRoundNavigation navigation;
  final int index;

  @override
  RenderProxyBox createRenderObject(BuildContext context) =>
      ConversationRoundRenderBox(navigation, index);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant ConversationRoundRenderBox renderObject,
  ) {
    renderObject.bind(navigation, index);
  }
}

class ConversationRoundRenderBox extends RenderProxyBox
    with ConversationTextReveal {
  ConversationRoundRenderBox(this.navigation, this.index);

  ConversationRoundNavigation navigation;
  int index;

  void bind(ConversationRoundNavigation next, int nextIndex) {
    if (identical(navigation, next) && index == nextIndex) return;
    if (attached) _unregister();
    navigation = next;
    index = nextIndex;
    if (attached) navigation._rows[index] = this;
  }

  void _unregister() {
    if (identical(navigation._rows[index], this)) {
      navigation._rows.remove(index);
    }
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    navigation._rows[index] = this;
  }

  @override
  void detach() {
    _unregister();
    super.detach();
  }
}
