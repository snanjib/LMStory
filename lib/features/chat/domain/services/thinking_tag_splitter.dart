/// Separates relay-provided visible reasoning without retaining the full reply.
/// Only a possible delimiter suffix is held across deltas. Signed wire blocks
/// must be retained separately and never passed through this display decoder.
class ThinkingTagSplitter {
  ThinkingTagSplitter({
    required this.onText,
    required this.onThinking,
    bool thinking = false,
  }) : _thinking = thinking;

  final void Function(String) onText;
  final void Function(String) onThinking;
  bool _thinking;
  String _pending = '';

  static const _open = '<think>';
  static const _close = '</think>';

  void add(String delta) {
    var text = _pending + delta;
    _pending = '';
    while (text.isNotEmpty) {
      final lower = text.toLowerCase();
      final openAt = lower.indexOf(_open);
      final closeAt = lower.indexOf(_close);
      final at = openAt < 0
          ? closeAt
          : closeAt < 0
              ? openAt
              : openAt < closeAt
                  ? openAt
                  : closeAt;
      if (at >= 0) {
        _emit(text.substring(0, at));
        final opening = at == openAt;
        _thinking = opening;
        text = text.substring(at + (opening ? _open.length : _close.length));
        continue;
      }
      var held = 0;
      for (var size = 1; size < _close.length && size <= text.length; size++) {
        final suffix = lower.substring(lower.length - size);
        if (_open.startsWith(suffix) || _close.startsWith(suffix)) held = size;
      }
      _emit(text.substring(0, text.length - held));
      _pending = text.substring(text.length - held);
      break;
    }
  }

  void flush() {
    _emit(_pending);
    _pending = '';
  }

  void _emit(String text) {
    if (text.isEmpty) return;
    (_thinking ? onThinking : onText)(text);
  }
}
