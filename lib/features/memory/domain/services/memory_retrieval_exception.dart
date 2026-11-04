/// 检索通道不可用（本轮所有被请求的记忆检索通道都失败）
///
/// 与「没有命中」严格区分（FF17）：
/// - 返回空列表 = 确实没有匹配数据 → 工具回「未命中」信封，引导换关键词；
/// - 抛本异常 = 索引/向量通道坏了 → 调用方必须呈现「检索不可用，请重试」，
///   绝不能让模型据此断定「库里不存在」而重复建档。
class MemoryRetrievalUnavailableException implements Exception {
  const MemoryRetrievalUnavailableException({
    required this.sessionId,
    required this.attemptedChannels,
    this.cause,
  });

  /// 会话 ID（日志定位用）
  final String sessionId;

  /// 本轮尝试的通道数（FTS 查询数 + 向量查询数）
  final int attemptedChannels;

  /// 原始异常（可选；单通道异常已被逐条记日志，此处仅留最后一条）
  final Object? cause;

  @override
  String toString() =>
      'MemoryRetrievalUnavailableException(session=$sessionId, '
      'channels=$attemptedChannels, cause=$cause)';
}
