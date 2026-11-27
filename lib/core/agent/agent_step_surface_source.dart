import 'package:lmstory/core/agent/agent_message.dart';

/// 单步出站表面的账本投影结果。
class AgentStepSurface {
  const AgentStepSurface({
    required this.messages,
    required this.contentGeneration,
    required this.digest,
  });

  /// 完整出站序列（含 system 节点 0 的冻结前缀）
  final List<AgentMessage> messages;

  /// 投影代数（账本内 replace/失效事件计数；变化=表面曾被整体改写）
  final int contentGeneration;

  /// 投影确定性摘要（诊断/留痕用；守卫比对以 [messages] 逐条为准）
  final String digest;
}

/// 新模式专用：每步出站消息的账本投影源（出站唯一来源）。
///
/// 实现职责 = flush durable 事件缓冲 → 读账本 → 确定性投影 → 返回；
/// 幂等（同账本状态同结果）。AgentTurnSpec.stepSurfaceSource 为 null
/// 时走现状路径（outgoing 来自 preStep 瀑布产物），关闭态行为不变。
///
/// 时序约定（调用方遵守）：project() 自带 flush，在 request 钩子之前
/// 调用；request 钩子的 flush 幂等不产生重复落账。
// ignore: one_member_abstracts, 单方法抽象接口为依赖反转所需
abstract class AgentStepSurfaceSource {
  Future<AgentStepSurface> project();
}
