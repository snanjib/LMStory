/// 会话模式字符串常量（避免 magic string）
///
/// ChatSession.mode 字段使用这些常量。
/// 中级模式（intermediate）是 v0.2 新增的模式。
///
/// 命名约定：
/// - 标识符 `chat` 对应产品名"对话模式"（v0.2 起，原 `simple` 已废弃）
/// - 标识符 `intermediate` 对应产品名"故事模式"
/// - 标识符 `advanced` 对应产品名"高级模式"（v0.3）
class ChatMode {
  ChatMode._();

  /// 对话模式（产品名）：对标 ChatBox 的 AI 对话工具
  static const String chat = 'chat';
  static const String intermediate = 'intermediate';
  static const String advanced = 'advanced';
}
