import 'dart:convert';

import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';

/// 轮时间线单个块类型（导演模式对话流，2026-08-28 计划 §4.1）
enum AgentTimelineKind {
  /// 思考块（按步分段，折叠行展示「思考 · 持续 N 秒」）
  thinking,

  /// 播报块（导演对用户说的话，无框裸文本，字体与正文一致）
  narration,

  /// 动作块（内嵌现有 AgentWorkStep，复用三态/标题/审计层）
  action,
}

/// 轮时间线单个块（按真实发生顺序排列）
///
/// 导演模式轮过程的持久化结构（v0.3 schemaVersion 45）：把"合并思考 +
/// 工具卡数组"的二分存储升级为带类型块按序排列的交错时间线。渲染层
/// （单一折叠组）与直播态共用同一条时间线。
///
/// 序列化为 JSON 数组存 `agent_timeline` TEXT 列；旧数据缺列时 UI 回退
/// `agentSteps` 渲染（兼容期双写）。
class AgentTimelineBlock {
  const AgentTimelineBlock({
    required this.kind,
    required this.stepIndex,
    this.text = '',
    this.action,
    this.startMs,
    this.endMs,
    this.order,
  });

  /// 反序列化单块（坏条目返回 null，由列表层跳过）
  static AgentTimelineBlock? tryFromJson(dynamic entry) {
    if (entry is! Map<String, dynamic>) return null;
    final kind = switch (entry['kind']) {
      'thinking' => AgentTimelineKind.thinking,
      'narration' => AgentTimelineKind.narration,
      'action' => AgentTimelineKind.action,
      _ => null,
    };
    if (kind == null) return null;
    final actionJson = entry['action'];
    return AgentTimelineBlock(
      kind: kind,
      stepIndex: (entry['stepIndex'] as num?)?.toInt() ?? 0,
      text: (entry['text'] as String?) ?? '',
      action: actionJson is Map<String, dynamic>
          ? AgentWorkStep.fromJson(actionJson)
          : null,
      startMs: (entry['startMs'] as num?)?.toInt(),
      endMs: (entry['endMs'] as num?)?.toInt(),
      order: (entry['order'] as num?)?.toInt(),
    );
  }

  /// 产生该块的模型请求序号
  final int stepIndex;

  final AgentTimelineKind kind;

  /// thinking/narration：内容；action：恒为空串
  final String text;

  /// action 块内嵌现有 AgentWorkStep JSON（复用三态/标题/审计层）
  final AgentWorkStep? action;

  /// 块起始时刻（相对轮起点，毫秒；旧数据/缺失时为 null）
  final int? startMs;

  /// 结束时刻（「思考 · 持续 N 秒」数据源；相对轮起点毫秒）
  final int? endMs;

  /// Optional arrival order; old serialized arrays retain their stored order.
  final int? order;

  bool get isAction => kind == AgentTimelineKind.action;

  /// 替换内嵌动作步骤（DD1：工具执行完成事件回补时间线里的 running 状态，
  /// 其余字段——kind/stepIndex/text/起止时刻——保持不变）。
  AgentTimelineBlock copyWithAction(AgentWorkStep next) {
    return AgentTimelineBlock(
      kind: kind,
      stepIndex: stepIndex,
      text: text,
      action: next,
      startMs: startMs,
      endMs: endMs,
      order: order,
    );
  }

  /// 落库前归一：轮已结束，动作块不可能仍处于 running。
  ///
  /// 最后一道不变量守卫——历史遗留的 running 行会让历史轮渲染出永久
  /// spinner（重启也不消失）。
  static List<AgentTimelineBlock> normalizeTerminalActions(
    List<AgentTimelineBlock> blocks,
  ) {
    var changed = false;
    final normalized = <AgentTimelineBlock>[];
    for (final block in blocks) {
      final action = block.action;
      if (block.isAction && action != null && action.isRunning) {
        normalized.add(block.copyWithAction(action.toTerminal()));
        changed = true;
      } else {
        normalized.add(block);
      }
    }
    return changed ? normalized : blocks;
  }

  /// 文本块内容是否为空（纯空白视为空，不渲染）
  bool get isEmpty => !isAction && text.trim().isEmpty;

  /// 块时长（起止完整且有效时；否则 null——UI 回退字数口径）
  Duration? get duration {
    final start = startMs;
    final end = endMs;
    if (start == null || end == null || end < start) return null;
    return Duration(milliseconds: end - start);
  }

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'stepIndex': stepIndex,
        if (text.isNotEmpty) 'text': text,
        if (action != null) 'action': action!.toJson(),
        if (startMs != null) 'startMs': startMs,
        if (endMs != null) 'endMs': endMs,
        if (order != null) 'order': order,
      };

  /// 反序列化 agent_timeline 字段（数据库 TEXT 存储 JSON 数组）
  ///
  /// 容错：整体非 JSON 数组 → 空列表（UI 回退 agentSteps 渲染）；
  /// 单条坏数据跳过不拖垮整表。
  static List<AgentTimelineBlock> listFromJsonString(String? jsonString) {
    if (jsonString == null || jsonString.isEmpty) return const [];
    try {
      final decoded = jsonDecode(jsonString);
      if (decoded is! List) return const [];
      return [
        for (final entry in decoded)
          if (tryFromJson(entry) case final block?) block,
      ];
    } catch (_) {
      return const [];
    }
  }

  /// 序列化 agent_timeline 字段
  static String listToJsonString(List<AgentTimelineBlock> blocks) {
    return jsonEncode(blocks.map((b) => b.toJson()).toList());
  }
}
