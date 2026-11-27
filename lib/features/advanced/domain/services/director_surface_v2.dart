import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/services/engineering_context_mode.dart';

/// 开启态表面组装器（纯函数，同输入同输出）。
///
/// 布局：`[system(冻结前缀)?] + 纪元窗投影消息`。冻结前缀内容取自
/// **全账本最新 system/frozen 事件**（前缀变更=追加新事件后自动取新值；
/// 轮首补账在投影前落账，轮内每步取值恒定）。纪元窗内的 system/frozen
/// 事件被滤除（冻结前缀由本组装器单点前置，避免其原位替换逻辑误碰窗内
/// 首位的捕获 system 消息——压缩摘要）。
abstract final class DirectorSurfaceV2 {
  /// 全账本内最新的冻结前缀内容（无 system/frozen 事件返回 null——
  /// 空会话首开启的边界，轮首补账会先落一条）
  static String? latestFrozenPrefixOf(List<AgentDurableEvent> events) {
    String? frozen;
    for (final event in events) {
      if (event.type == AgentEventTypes.systemFrozen) {
        frozen = (event.data['content'] as String?) ?? frozen;
      }
    }
    return frozen;
  }

  /// 活跃纪元窗事件（system/frozen 滤除）——投影与变体切换规划共用同一
  /// 基准（坐标空间一致）
  static List<AgentDurableEvent> epochWindowEvents(
    List<AgentDurableEvent> events,
  ) {
    return activeEpochWindow(
      events.where((e) => e.type != AgentEventTypes.systemFrozen).toList(),
    );
  }

  /// 活跃纪元窗（system/frozen 滤除后）的投影
  static AgentSurfaceProjection epochWindowProjection(
    List<AgentDurableEvent> events,
  ) {
    return deriveAgentSurface(epochWindowEvents(events));
  }

  /// 组装开启态出站面：`[frozen?] + 纪元窗投影`
  static List<AgentMessage> assemble({
    required List<AgentMessage> epochWindowMessages,
    required String? frozenPrefix,
  }) {
    return [
      if (frozenPrefix != null) AgentMessage.system(frozenPrefix),
      ...epochWindowMessages,
    ];
  }
}
