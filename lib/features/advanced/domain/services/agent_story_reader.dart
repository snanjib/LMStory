/// 剧情回读段（read_story 的返回单元）
class AgentStoryRound {
  const AgentStoryRound({
    required this.turnNumber,
    required this.createdAt,
    this.userText,
    this.narrativeText,
    this.replyText,
    this.eventSummaryText,
  });

  final int turnNumber;
  final DateTime createdAt;

  /// 本轮用户输入
  final String? userText;

  /// 本轮生成的正文
  final String? narrativeText;

  /// 本轮最终回复
  final String? replyText;

  /// 本轮事件记忆摘要文本
  final String? eventSummaryText;

  bool get isEmpty =>
      (userText == null || userText!.isEmpty) &&
      (narrativeText == null || narrativeText!.isEmpty) &&
      (replyText == null || replyText!.isEmpty);
}

/// 原文回读端口（Data 层实现：intermediate_round_artifacts + chat_messages）
abstract class AgentStoryReader {
  /// 按轮号升序读取 [fromTurn, fromTurn + count) 的剧情段
  Future<List<AgentStoryRound>> readRounds({
    required int fromTurn,
    required int count,
  });

  /// 读取当前会话全部已保存轮次，不受工作上下文压缩边界限制。
  Future<List<AgentStoryRound>> readAllRounds();

  /// 会话总轮数（最大 turnNumber；无产物时 0）
  Future<int> totalRounds();
}

/// 用户交互端口（ask_user 工具的 UI 桥）
// ignore: one_member_abstracts, 单方法抽象接口为 UI 桥多实现所需
abstract class AgentUserInteractionPort {
  /// 向用户提问并等待回答；[options] 为可选项（可选）。
  /// 返回 null = 用户未回答（超时/跳过）。
  Future<String?> askUser({
    required String question,
    List<String>? options,
  });
}
