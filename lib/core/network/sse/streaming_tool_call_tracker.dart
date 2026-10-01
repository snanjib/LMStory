import 'package:lmstory/core/network/sse/tool_call_accumulator.dart';

/// 流式 tool-call 碎片事件（per-index 状态机的输出）
///
/// 由 `StreamingToolCallTracker` 产生，`SseParser` 负责映射为自己的
/// `ToolCallStart` / `ToolCallArgs` / `ToolCallComplete` 事件。
sealed class StreamingToolCallEvent {
  const StreamingToolCallEvent({required this.index});

  /// OpenAI 协议的 `delta.tool_calls[].index`（本地兜底合成时为槽位序号）
  final int index;
}

/// 新工具调用开始（首片带 id/name，或匿名兜底创建）
class StreamingToolCallStart extends StreamingToolCallEvent {
  const StreamingToolCallStart({
    required super.index,
    required this.callId,
    required this.name,
  });

  final String callId;
  final String name;
}

/// 参数 JSON 字符串增量
class StreamingToolCallArgsDelta extends StreamingToolCallEvent {
  const StreamingToolCallArgsDelta({
    required super.index,
    required this.callId,
    required this.delta,
  });

  final String callId;
  final String delta;
}

/// 单个工具调用累积完成（参数经 JSON 修复后仍保持原始字符串形式）
class StreamingToolCallFinish extends StreamingToolCallEvent {
  const StreamingToolCallFinish({
    required super.index,
    required this.callId,
    required this.name,
    required this.arguments,
    this.jsonRepaired = false,
  });

  final String callId;
  final String name;

  /// 修复后的参数 JSON 字符串（未修复时为原始拼接结果）
  final String arguments;

  /// 是否经过 `ToolCallAccumulator.repairJson` 修复
  final bool jsonRepaired;
}

class _Track {
  _Track({
    required this.index,
    required this.callId,
    required this.name,
  });

  final int index;
  String callId;
  String name;
  final StringBuffer args = StringBuffer();
  bool finished = false;
}

/// 流式 tool-call 增量追踪器（per-index 状态机，v0.3 Agent Loop 协议地基）
///
/// 消费 OpenAI 兼容协议 `delta.tool_calls[]` 碎片，支持多工具并行/交错分片：
///
/// 规范行为（OpenAI 官方）：
/// - 首片带 `id` + `function.name`（可能带首段 arguments）
/// - 后续片仅带 `index` + `function.arguments` 碎片（缺 id/name 是规范不是 bug）
/// - `finish_reason="tool_calls"` 或 `DONE` 标记结束
///
/// 中转站容错（vLLM/SGLang/NIM 等实测变体，对齐设计报告 §4.3）：
/// - `index` 缺失 → 回退顺序假设（路由到最近未完成的 track）
/// - `id` 缺失（新调用场景）→ 本地合成稳定 id（`call_local_<n>`）
/// - 同一 id 重复出现 → 视为续片（部分中转每片都带 id）
/// - 一次性吐完整 arguments / 无 finish_reason / 无 `DONE` 标记 → 由 finishAll 兜底
/// - 参数 JSON 截断 → `ToolCallAccumulator.repairJson` 补闭合
///
/// 输出按 index 升序、流结束统一 finish，保证多工具调用顺序稳定。
class StreamingToolCallTracker {
  final List<_Track> _tracks = [];
  var _localIdSeq = 0;

  /// 是否存在未完成的 track（SseParser 用于状态机切换）
  bool get hasPending => _tracks.any((t) => !t.finished);

  /// 是否已经收到过至少一个 tool call 碎片
  bool get hasAnyTrack => _tracks.isNotEmpty;

  /// 处理单个 `delta.tool_calls[]` 数组元素
  ///
  /// 返回本次碎片产生的增量事件（0..2 个：可能 Start + Args 同片到达）。
  List<StreamingToolCallEvent> handleFragment({
    int? index,
    String? id,
    String? name,
    String? argsDelta,
  }) {
    final events = <StreamingToolCallEvent>[];
    final cleanId = (id == null || id.isEmpty) ? null : id;
    final cleanName = (name == null || name.isEmpty) ? null : name;

    var track = _resolveTrack(index: index, id: cleanId, name: cleanName);

    // 新 track：发出 Start（可能带首段参数）
    if (track == null) {
      track = _createTrack(index: index, id: cleanId, name: cleanName ?? '');
      events.add(
        StreamingToolCallStart(
          index: track.index,
          callId: track.callId,
          name: track.name,
        ),
      );
    } else if (cleanName != null && cleanName != track.name) {
      // 部分中转在续片重复携带 name；名字不一致时以首片为准
      // （同名工具重调用按规范会有新 id，走 _resolveTrack 的新建分支）
    }

    if (argsDelta != null && argsDelta.isNotEmpty) {
      track.args.write(argsDelta);
      events.add(
        StreamingToolCallArgsDelta(
          index: track.index,
          callId: track.callId,
          delta: argsDelta,
        ),
      );
    }

    return events;
  }

  /// 结束全部未完成的 track（`DONE` 标记 / finish_reason / 流自然结束时调用）
  ///
  /// 返回按 index 升序的完成事件；已完成的 track 不会重复发出。
  List<StreamingToolCallFinish> finishAll() {
    final finished = <StreamingToolCallFinish>[];
    for (final track in _tracks.where((t) => !t.finished)) {
      track.finished = true;
      final rawArgs = track.args.toString();
      final repaired = ToolCallAccumulator.repairJson(rawArgs);
      finished.add(
        StreamingToolCallFinish(
          index: track.index,
          callId: track.callId,
          name: track.name,
          arguments: repaired,
          jsonRepaired: repaired != rawArgs,
        ),
      );
    }
    finished.sort((a, b) => a.index.compareTo(b.index));
    return finished;
  }

  /// 已完成 track 的数量（诊断用）
  int get finishedCount => _tracks.where((t) => t.finished).length;

  /// 定位碎片归属的 track；返回 null 表示需要新建
  _Track? _resolveTrack({int? index, String? id, String? name}) {
    // 1. 精确 id 匹配（含"每片都带 id"的中转变体）
    if (id != null) {
      final byId = _tracks.where((t) => t.callId == id && !t.finished);
      if (byId.isNotEmpty) return byId.first;
      return null; // 新调用
    }

    // 2. index 匹配（规范续片）
    if (index != null) {
      final byIndex = _tracks.where((t) => t.index == index && !t.finished);
      if (byIndex.isNotEmpty) return byIndex.first;
      // index 无 track 且携带 name → 视为新调用（部分中转缺 id 只给 index+name）
      if (name != null) return null;
      // index 无 track 且无 name → 匿名新建（由 _createTrack 合成 id）
      return null;
    }

    // 3. index 缺失 → 顺序假设：路由到最近创建的未完成 track
    final pending = _tracks.where((t) => !t.finished).toList();
    if (pending.isNotEmpty) return pending.last;
    return null;
  }

  _Track _createTrack({required String name, int? index, String? id}) {
    final slot = index ?? _nextFreeSlot();
    final track = _Track(
      index: slot,
      callId: id ?? 'call_local_${_localIdSeq++}',
      name: name,
    );
    _tracks.add(track);
    return track;
  }

  /// index 缺失时的槽位分配：优先复用最小未占用整数
  int _nextFreeSlot() {
    var slot = 0;
    final used = _tracks.map((t) => t.index).toSet();
    while (used.contains(slot)) {
      slot++;
    }
    return slot;
  }
}
