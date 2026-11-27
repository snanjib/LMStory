import 'package:lmstory/core/llm/llm_usage.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';

/// 最新一次成功请求的分项（旧会话回填，上下文用量指示设计 §3.2）
class LatestStepUsage {
  const LatestStepUsage({
    required this.promptTokens,
    this.totalInputTokens,
    this.cacheReadTokens,
    this.usageWarnings = const [],
  });

  /// 协议原生 prompt token（Anthropic 不含缓存读写）
  final int promptTokens;

  /// 完整输入 token（新日志才有；旧日志缺键为 null）
  final int? totalInputTokens;

  /// 缓存命中读 token（回填扩展：旧日志/无缓存端点缺键为 null）
  final int? cacheReadTokens;

  /// 计量异常（字段冲突等）：异常样本不得展示无标识的精确比例
  final List<String> usageWarnings;

  /// 缓存命中率（缺输入面/缺缓存分项/计量异常的旧样本返回 null）
  double? get cacheHitRatio => usageWarnings.isEmpty
      ? LlmUsage.hitRateOf(
          cacheReadTokens: cacheReadTokens,
          inputTokens: totalInputTokens,
        )
      : null;
}

/// 旧会话回填探针（上下文用量指示设计 §3.2）
///
/// `AgentWorkSummary.lastPromptTokens` 是新字段，实施前的历史轮次没有。
/// durable 事件日志自导演模式起就记录每步 usage（step/end.promptTokens），
/// 从中取"最后一次成功请求"的分项即该会话当前上下文的真实占用。
/// cache 分项（step/end.cacheReadTokens，2026-09-04 起落库）与完整输入面
/// （step/end.totalInputTokens，2026-11-09 起落库）随同一探针回填。
/// 旧日志缺 `totalInputTokens` 时返回 null——不得用 prompt 冒充完整输入
/// 参与命中率累计（OpenAI 会重复计入缓存，Anthropic 会漏计）。只读纯函数。
LatestStepUsage? latestStepEndUsage(List<AgentDurableEvent> events) {
  for (final event in events.reversed) {
    if (event.type != AgentEventTypes.stepEnd) continue;
    // 审查收官 ：子代理 stepEnd 是独立小上下文，跳过（否则
    // 崩溃于 spawn 的轮会把子代理占用回填为主上下文）
    if (event.data['subagent'] == true) continue;
    final tokens = (event.data['promptTokens'] as num?)?.toInt();
    if (tokens != null && tokens > 0) {
      final totalInput = (event.data['totalInputTokens'] as num?)?.toInt();
      return LatestStepUsage(
        promptTokens: tokens,
        totalInputTokens:
            totalInput != null && totalInput > 0 ? totalInput : null,
        cacheReadTokens: (event.data['cacheReadTokens'] as num?)?.toInt(),
        usageWarnings: switch (event.data['usageWarnings']) {
          final List<dynamic> values => values.whereType<String>().toList(),
          _ => const [],
        },
      );
    }
  }
  return null;
}

/// 兼容旧调用点：仅取 promptTokens（前的单一口径）
int? latestStepEndPromptTokens(List<AgentDurableEvent> events) {
  return latestStepEndUsage(events)?.promptTokens;
}
