/// 压缩点实体
///
/// 表示一个上下文压缩检查点，记录摘要消息和边界消息
class CompactionPoint {
  const CompactionPoint({
    required this.sessionId,
    required this.summaryMessageId,
    required this.boundaryMessageId,
    required this.createdAt,
  });

  /// 会话 ID
  final String sessionId;

  /// 摘要消息 ID
  final String summaryMessageId;

  /// 边界消息 ID（压缩点之前的最后一条消息）
  final String boundaryMessageId;

  /// 创建时间
  final DateTime createdAt;
}
