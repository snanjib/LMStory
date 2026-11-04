// Settings-owned input key vocabulary: the send/newline key preference is
// persisted by the settings feature and consumed by chat, story and director
// input areas.
/// Send key preference.
enum SendKey {
  /// Enter sends.
  enter,

  /// Shift+Enter sends.
  shiftEnter,

  /// Ctrl+Enter sends.
  ctrlEnter,

  /// Send via button only (mobile "回车换行" mode).
  button,
}

/// Newline key preference (desktop only).
enum NewlineKey {
  /// Enter for newline.
  enter,

  /// Shift+Enter for newline.
  shiftEnter,

  /// Ctrl+Enter for newline.
  ctrlEnter,

  /// Alt+Enter for newline.
  altEnter,
}
