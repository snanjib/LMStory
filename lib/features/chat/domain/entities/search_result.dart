/// 跨会话搜索结果
///
/// 表示一条匹配搜索条件的消息，附带其所属会话信息。
class SearchResult {
  const SearchResult({
    required this.sessionId,
    required this.sessionName,
    required this.messageId,
    required this.content,
    required this.role,
    required this.createdAt,
  });

  /// 所属会话 ID
  final String sessionId;

  /// 所属会话名称
  final String sessionName;

  /// 消息 ID
  final String messageId;

  /// 消息内容
  final String content;

  /// 消息角色（user / assistant / system / tool）
  final String role;

  /// 消息创建时间
  final DateTime createdAt;
}
