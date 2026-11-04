import 'dart:async';

import 'package:lmstory/features/advanced/domain/entities/agent_live_block.dart';

///  批3：导演直播增量合帧器
///
/// 此前每个 SSE 文本/思考 delta 直接 `state.copyWith(liveBlocks:
/// AgentLiveTranscript.appendText(...))`——网络 delta 频率（可达数十次/秒）
/// 下页面整页重建 + `_buildRows` 全量构造按网络节奏触发。chat/故事侧已有
/// 32ms 合帧（的 ThrottledDeltaBuffer），导演直播是唯一未合帧的流式面。
///
/// 与 ThrottledDeltaBuffer 的差异：直播增量携带 (thinking, stepIndex,
/// atMs) 元数据，且合帧**不得破坏块边界语义**——跨 step/类型拼接会把
/// 2026-08-23 修掉的「跨步串行」缺陷请回来。因此合帧输出的是「同
/// kind+step 连续段」的 [AgentLiveDeltaRun] 列表，由
/// [applyLiveDeltaRuns] 按序应用（段内合并、段间保持边界）。
///
/// 顺序保证：消费方在处理任何**非 delta 事件**前必须先 [flush]
///（见 director_round_runner `_onAgentEvent` 顶部）——直播时间线里
/// 工具步骤/早折叠/收割都按真实顺序读 liveBlocks。
class AgentLiveDeltaCoalescer {
  AgentLiveDeltaCoalescer(
    this.onFlush, {
// lm-motion-exempt: 流式增量合并间隔（吞吐调参，非过渡动效）
    this.interval = const Duration(milliseconds: 32),
  });

  /// 合帧间隔（≈30fps；测试可注入更短值）
  final Duration interval;

  /// 冲刷回调：合并后的连续段列表（已按到达顺序、段边界切分）
  final void Function(List<AgentLiveDeltaRun> runs) onFlush;

  final List<AgentLiveDelta> _pending = [];
  Timer? _timer;

  /// 喂入一个增量（空文本忽略）
  void add(AgentLiveDelta delta) {
    if (delta.text.isEmpty) return;
    _pending.add(delta);
    _timer ??= Timer(interval, flush);
  }

  /// 冲刷待发段（定时到期或消费方在非 delta 事件前手动调用）。
  /// 无待发段时不回调。
  void flush() {
    _timer?.cancel();
    _timer = null;
    if (_pending.isEmpty) return;
    final entries = List<AgentLiveDelta>.of(_pending);
    _pending.clear();

    final runs = <AgentLiveDeltaRun>[];
    var i = 0;
    while (i < entries.length) {
      final head = entries[i];
      final text = StringBuffer()..write(head.text);
      var j = i + 1;
      while (j < entries.length &&
          entries[j].thinking == head.thinking &&
          entries[j].stepIndex == head.stepIndex &&
          entries[j].source == head.source &&
          entries[j].order == head.order) {
        text.write(entries[j].text);
        j++;
      }
      runs.add(
        AgentLiveDeltaRun(
          thinking: head.thinking,
          source: head.source,
          order: head.order,
          stepIndex: head.stepIndex,
          atMs: head.atMs,
          text: text.toString(),
        ),
      );
      i = j;
    }
    onFlush(runs);
  }

  /// 丢弃未冲刷段（换轮残段不得落进新轮的 liveBlocks）
  void discardPending() {
    _timer?.cancel();
    _timer = null;
    _pending.clear();
  }
}

/// 一个待合帧的直播增量（文本或思考，携带块归属元数据）
class AgentLiveDelta {
  const AgentLiveDelta({
    required this.thinking,
    required this.stepIndex,
    required this.atMs,
    required this.text,
    this.source = AgentTextSource.assistant,
    this.order,
  });

  final bool thinking;
  final int stepIndex;
  final int atMs;
  final String text;
  final AgentTextSource source;
  final int? order;
}

/// 合帧后的连续段：同 kind+step 的相邻增量已合并，atMs 取段首
class AgentLiveDeltaRun {
  const AgentLiveDeltaRun({
    required this.thinking,
    required this.stepIndex,
    required this.atMs,
    required this.text,
    this.source = AgentTextSource.assistant,
    this.order,
  });

  final bool thinking;
  final int stepIndex;
  final int atMs;
  final String text;
  final AgentTextSource source;
  final int? order;
}

/// 把合帧后的 run 列表按序应用到 liveBlocks（纯函数）。
///
/// 等价于逐 delta 应用 `AgentLiveTranscript.appendText` /
/// `appendThinking`——段内已合并、段间经 append 的分段规则保持块边界
///（同 step 同类型追加末块、否则新开块）。消费方整个 flush 只做一次
/// state 替换（单次通知）。
List<AgentLiveBlock> applyLiveDeltaRuns(
  List<AgentLiveBlock> blocks,
  List<AgentLiveDeltaRun> runs,
) {
  var result = blocks;
  for (final run in runs) {
    result = run.thinking
        ? AgentLiveTranscript.appendThinking(
            result,
            run.stepIndex,
            run.text,
            atMs: run.atMs,
            order: run.order,
          )
        : AgentLiveTranscript.appendText(
            result,
            run.stepIndex,
            run.text,
            atMs: run.atMs,
            order: run.order,
            source: run.source,
          );
  }
  return result;
}
