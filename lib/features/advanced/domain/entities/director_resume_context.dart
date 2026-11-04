import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_round_draft.dart';

/// 导演轮真续跑上下文（失败后「从中断处继续」复用已产出）
///
/// [surface] 由事件日志投影重建——失败时刻模型可见的完整消息序列，含
/// 已完成的 assistant 步骤与工具结果（以及中断步的半截正文合成消息），
/// 续跑不再重发已完成的 LLM 请求。[draft] 为上次尝试的轮草稿，写工具的
/// 轮级累积（事实变更/检索快照/一次性豁免标记）不因失败丢失。
class DirectorResumeContext {
  const DirectorResumeContext({
    required this.surface,
    required this.priorSteps,
    required this.priorTotalTokens,
    required this.priorDurationMs,
    required this.draft,
  });

  /// 续跑起点消息序列（deriveAgentSurface 投影）
  final List<AgentMessage> surface;

  /// 上次尝试已完成步数（续跑步号基数 + 步数预算余量执法）
  final int priorSteps;

  /// 上次尝试已消耗 token（预算执法口径；不进事件报量，聚合面各段相加）
  final int priorTotalTokens;

  /// 上次尝试已耗时毫秒（并入轮工作摘要总时长）
  final int priorDurationMs;

  /// 上次尝试的轮草稿（继续累积）
  final AgentRoundDraft draft;
}
