import 'package:lmstory/features/advanced/domain/entities/agent_live_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';

/// 轮时间线装配器（对话流计划 §4.1，纯函数）
///
/// 从直播分块（liveBlocks）+ 工具步骤（agentSteps）合成按真实发生顺序
/// 排列的轮时间线：
/// - 主序：stepIndex 归并排序（升序）；
/// - 同 step 内按 思考 → 动作 → 文本；同优先级保持各自
///   到达序（稳定）。
/// - 空白文本块跳过；失败/中断轮的半截数据按现状原样装配。
abstract final class AgentTimelineAssembler {
  /// 同 step 内的块序：思考 → 动作 → 文本
  static const _kindRank = <AgentLiveBlockKind, int>{
    AgentLiveBlockKind.thinking: 0,
    AgentLiveBlockKind.text: 2,
  };

  /// 起止时刻：live 块首/末增量时刻、动作开始时刻换算为相对轮起点毫秒
  /// （origin = 全部输入中最早的绝对时刻）；无任何时刻信息时为 null，
  /// UI 回退字数口径。
  ///
  /// [promotedIndex] 为正文交付契约 §5.2 pickReplyBlock 的升格块下标
  /// （收割与升格同源同位）；null = 正文经 prose 参数显式交付，全部自由
  /// 文本都进播报。越界下标视为 null（防御）。
  static List<AgentTimelineBlock> assemble({
    required List<AgentLiveBlock> liveBlocks,
    required List<AgentWorkStep> agentSteps,
    int? promotedIndex,
  }) {
    // 1. 升格块下标合法性检查（与 pickReplyBlock 同源，由调用方传入）
    final promoted = (promotedIndex != null &&
            promotedIndex >= 0 &&
            promotedIndex < liveBlocks.length)
        ? promotedIndex
        : -1;

    // 2. 轮起点 = 全部输入中最早的绝对时刻（无则全部为 null）
    final anchors = <int>[
      for (final block in liveBlocks)
        if (block.startMs case final at?) at,
      for (final step in agentSteps)
        if (step.startedAtMs case final at?) at,
    ];
    final origin =
        anchors.isEmpty ? null : anchors.reduce((a, b) => a < b ? a : b);
    int? rel(int? absolute) =>
        origin == null || absolute == null ? null : absolute - origin;

    // 3. 带排序键收集条目：(stepIndex, kindRank, 到达序)
    final entries = <(int, int, int, AgentTimelineBlock)>[];
    for (var i = 0; i < liveBlocks.length; i++) {
      final block = liveBlocks[i];
      if (i == promoted || block.isEmpty) continue;
      final entry = (
        block.stepIndex,
        _kindRank[block.kind]!,
        i,
        AgentTimelineBlock(
          kind: block.kind == AgentLiveBlockKind.thinking
              ? AgentTimelineKind.thinking
              : AgentTimelineKind.narration,
          stepIndex: block.stepIndex,
          text: block.text,
          startMs: rel(block.startMs),
          endMs: rel(block.endMs),
        ),
      );
      entries.add(entry);
    }
    for (var i = 0; i < agentSteps.length; i++) {
      final step = agentSteps[i];
      final startedAt = step.startedAtMs;
      final entry = (
        step.stepIndex,
        1,
        i,
        AgentTimelineBlock(
          kind: AgentTimelineKind.action,
          stepIndex: step.stepIndex,
          action: step,
          startMs: rel(startedAt),
          endMs: startedAt != null && step.durationMs > 0
              ? rel(startedAt + step.durationMs)
              : null,
        ),
      );
      entries.add(entry);
    }

    entries.sort((a, b) {
      final byStep = a.$1.compareTo(b.$1);
      if (byStep != 0) return byStep;
      final byRank = a.$2.compareTo(b.$2);
      if (byRank != 0) return byRank;
      return a.$3.compareTo(b.$3);
    });
    return [for (final entry in entries) entry.$4];
  }
}
