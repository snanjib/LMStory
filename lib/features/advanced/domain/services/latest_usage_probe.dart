import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';

/// 最新一次成功请求的分项（旧会话回填，上下文用量指示设计 §3.2）
class LatestStepUsage {
  const LatestStepUsage({
    required this.promptTokens,
    this.cacheReadTokens,
  });

  final int promptTokens;

  /// 缓存命中读 token（回填扩展：旧日志/无缓存端点缺键为 null）
  final int? cacheReadTokens;
}

/// 旧会话回填探针（上下文用量指示设计 §3.2）
///
/// `AgentWorkSummary.lastPromptTokens` 是新字段，实施前的历史轮次没有。
/// durable 事件日志自导演模式起就记录每步 usage（step/end.promptTokens），
/// 从中取"最后一次成功请求"的分项即该会话当前上下文的真实占用。
/// cache 分项（step/end.cacheReadTokens，2026-09-04 起落库）随同一
/// 探针回填——崩溃恢复/旧会话打开后详情面板的缓存命中率不再缺分子。
/// 只读纯函数，不落库。
LatestStepUsage? latestStepEndUsage(List<AgentDurableEvent> events) {
  for (final event in events.reversed) {
    if (event.type != AgentEventTypes.stepEnd) continue;
    // 审查收官 ：子代理 stepEnd 是独立小上下文，跳过（否则
    // 崩溃于 spawn 的轮会把子代理占用回填为主上下文）
    if (event.data['subagent'] == true) continue;
    final tokens = (event.data['promptTokens'] as num?)?.toInt();
    if (tokens != null && tokens > 0) {
      return LatestStepUsage(
        promptTokens: tokens,
        cacheReadTokens: (event.data['cacheReadTokens'] as num?)?.toInt(),
      );
    }
  }
  return null;
}

/// 兼容旧调用点：仅取 promptTokens（前的单一口径）
int? latestStepEndPromptTokens(List<AgentDurableEvent> events) {
  return latestStepEndUsage(events)?.promptTokens;
}
