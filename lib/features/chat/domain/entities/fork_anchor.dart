/// 分支锚点信息
///
/// 跟踪同一用户消息下的多个助手回复（分支）。
///
/// 快照模型（对标 ChatBox messageForksHash）：
/// - 锚点 = 触发助手回复的用户消息（parentUserMsgId）
/// - 同一锚点下的多个分支：活跃分支消息在 chat_messages 表，
///   非活跃分支消息以 JSON 快照存储在 chat_session_branches.branch_snapshots
/// - [activeIndex] 为当前显示的分支索引（0-based）
/// - [branchCount] 为分支总数
class ForkAnchor {
  const ForkAnchor({
    required this.parentUserMsgId,
    required this.activeIndex,
    required this.branchCount,
  });

  /// 锚点用户消息 ID
  final String parentUserMsgId;

  /// 当前激活的分支索引（0-based）
  final int activeIndex;

  /// 分支总数
  final int branchCount;

  /// 当前分支的显示序号（1-based）
  int get displayIndex => activeIndex + 1;

  /// 是否存在多个分支
  bool get hasForks => branchCount > 1;

  ForkAnchor copyWith({
    int? activeIndex,
    int? branchCount,
  }) {
    return ForkAnchor(
      parentUserMsgId: parentUserMsgId,
      activeIndex: activeIndex ?? this.activeIndex,
      branchCount: branchCount ?? this.branchCount,
    );
  }
}
