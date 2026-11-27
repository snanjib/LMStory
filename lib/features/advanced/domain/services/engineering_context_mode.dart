import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';

/// 工程上下文模式（导演实验）运行态三态判定与纪元事件构造。
///
/// 「唯一真源」分工：`chat_sessions.engineering_context_enabled` 列与
/// 账本内 `mode/epoch` 纪元事件必须一致——本文件的三态解析以**两者对账**
/// 为准，任何矛盾都进入需要修复态（保留数据、停轮、禁 trim），绝不自动
/// 置 false / 切旧装配 / 删 pending。正常关闭态 = 无纪元证据（普通旧
/// 会话）或最新 complete 纪元已有 exit；正常开启态 = 列 true 且最新
/// complete 纪元未退出且捕获完好。
///
/// 本文件全部为纯函数（解析/构造），事务性写入见
/// [EngineeringContextSwitchStore]（data 层实现以同库单事务保证
/// 纪元事件+捕获+会话列原子提交）。

/// 运行态三态（内部判定，不新增用户开关）
enum EngineeringRuntimeMode {
  /// 正常关闭：走基线旧装配与日志保留 trim
  normalClosed,

  /// 正常开启：表面从账本纪元投影，全部 trim 入口跳过
  normalOpen,

  /// 需要修复：配置/纪元矛盾、pending 残留、捕获破损或未知关键表面
  /// 事件。保留配置与事件、留痕停轮；用户明确选择修复重捕获或确认退出
  /// 后才提交相应事务。
  recoveryRequired,
}

/// 三态解析结果
class EngineeringModeResolution {
  const EngineeringModeResolution({
    required this.mode,
    this.epochId,
    this.reason,
  });

  const EngineeringModeResolution.closed()
      : this(mode: EngineeringRuntimeMode.normalClosed);

  final EngineeringRuntimeMode mode;

  /// 正常开启态的有效纪元 id（其余态为 null）
  final String? epochId;

  /// 需要修复态的原因码（诊断/留痕用；其余态为 null）
  final String? reason;

  /// 便捷判据
  bool get isBlocked => mode == EngineeringRuntimeMode.recoveryRequired;
  bool get isOpen => mode == EngineeringRuntimeMode.normalOpen;
}

/// 纪元 enter 事件的 data.phase 值
const String kModeEpochPhaseEnter = 'enter';
const String kModeEpochPhaseExit = 'exit';

/// 已知会进表面投影的事件类型集合（未知类型的 surface 事件=关键表面
/// 疑点，触发需要修复态——向前兼容的消费方应扩本集合而非静默跳过）。
const Set<String> kKnownSurfaceEventTypes = {
  AgentEventTypes.userMessage,
  AgentEventTypes.assistantMessage,
  AgentEventTypes.toolResult,
  AgentEventTypes.systemCore,
  AgentEventTypes.systemFrozen,
  AgentEventTypes.surfaceReplace,
  AgentEventTypes.modeCapture,
  AgentEventTypes.branchRebuild,
};

/// 解析三态。
///
/// [enabled] 为会话列原值（null 按关闭处理）；[events] 为账本全量事件
///（seq 升序）。判定规则：
/// - 无任何 enter 纪元：enabled==true → 修复（'enabled-without-epoch'，
///   含 Case 4「列 true 缺纪元」——有旧诊断日志不算纪元证据）；否则
///   正常关闭（普通旧会话）。
/// - 最新 enter 为 pending（无论其后是否有其他事件）→ 修复
///   （'pending-epoch'，原子进入事务中断的残留，不可猜为可删垃圾）。
/// - 最新 enter 为 complete：
///   - 其后存在 exit → 已退出：enabled==true → 修复
///     （'enabled-but-exited'）；否则正常关闭。
///   - 未退出：enabled==true → 捕获完好则正常开启（携带 epochId），
///     complete 声称 captureCount>0 而账本内无同纪元捕获事件 → 修复
///     （'capture-missing'）；enabled!=true → 修复
///     （'disabled-but-open-epoch'，Case「false 列+complete enter 无 exit」）。
/// - 未知关键表面事件（surfaceOp 非空且类型不在已知集合）→ 修复
///   （'unknown-surface-event'；仅当上述判定已走到「开启候选」才检查——
///   关闭态会话不消费账本装配，未知事件不阻塞旧路径）。
EngineeringModeResolution resolveEngineeringMode({
  required bool? enabled,
  required List<AgentDurableEvent> events,
}) {
  // 纪元事件按序扫描：记录最新 enter（pending 或 complete）与最后 exit。
  ({String epochId, bool complete, int captureCount, int index})? latestEnter;
  var lastExitIndex = -1;
  for (var i = 0; i < events.length; i++) {
    final event = events[i];
    if (event.type != AgentEventTypes.modeEpoch) continue;
    final phase = event.data['phase'];
    if (phase == kModeEpochPhaseEnter) {
      // enter 的完整态由同 epochId 的 status=complete 追加事件表达：
      // 扫描到 enter pending 记候选，遇同 epochId complete 升级；其间
      // 出现别的 pending enter（异常交错）以最新为准。
      latestEnter = (
        epochId: (event.data['epochId'] as String?) ?? '',
        complete: event.data['status'] == 'complete',
        captureCount: (event.data['captureCount'] as num?)?.toInt() ??
            (event.data['status'] == 'complete' ? 0 : -1),
        index: i,
      );
    } else if (phase == kModeEpochPhaseExit) {
      lastExitIndex = i;
    }
  }

  if (latestEnter == null) {
    if (enabled ?? false) {
      return const EngineeringModeResolution(
        mode: EngineeringRuntimeMode.recoveryRequired,
        reason: 'enabled-without-epoch',
      );
    }
    return const EngineeringModeResolution.closed();
  }

  if (!latestEnter.complete) {
    return const EngineeringModeResolution(
      mode: EngineeringRuntimeMode.recoveryRequired,
      reason: 'pending-epoch',
    );
  }

  final exited = lastExitIndex > latestEnter.index;
  if (exited) {
    if (enabled ?? false) {
      return const EngineeringModeResolution(
        mode: EngineeringRuntimeMode.recoveryRequired,
        reason: 'enabled-but-exited',
      );
    }
    return const EngineeringModeResolution.closed();
  }

  if (!(enabled ?? false)) {
    return const EngineeringModeResolution(
      mode: EngineeringRuntimeMode.recoveryRequired,
      reason: 'disabled-but-open-epoch',
    );
  }

  // 开启候选：捕获完好性（集合身份+计数+关联）+ 未知关键表面事件校验。
  final epochId = latestEnter.epochId;
  // 完整性校验用原始窗口（未过滤）——混入的他纪元捕获必须在窗内才能
  // 被发现；投影取材（activeEpochWindow）才做过滤。
  final located = _locateActiveEpoch(events);
  final window = located == null
      ? const <AgentDurableEvent>[]
      : events.sublist(located.$1);
  final sameEpochIndices = <int>[];
  var legacyCaptureCount = 0;
  var indexedCaptureCount = 0;
  for (final event in window) {
    if (event.type != AgentEventTypes.modeCapture) continue;
    final eventEpoch = event.data['epochId'];
    if (eventEpoch != epochId) {
      // 他纪元捕获混入活跃窗口：投影消费整个窗口，混入内容会进模型
      // 表面——集合不纯即停轮（保留原事件，不删不猜）。
      return const EngineeringModeResolution(
        mode: EngineeringRuntimeMode.recoveryRequired,
        reason: 'capture-foreign-epoch',
      );
    }
    final index = event.data['captureIndex'];
    if (index is num) {
      // 带集合序号的新格式：序号必须互不相同（同序号重复=重复捕获
      // 顶替丢失条目，计数巧合不能放行）。
      sameEpochIndices.add(index.toInt());
      indexedCaptureCount++;
    } else {
      legacyCaptureCount++;
    }
  }
  final capturePromised = latestEnter.captureCount;
  // 带序号格式：序号集合必须恰为 {0..N-1}（条数=声称、无重复、全在界内；
  // 鸽笼即连续）。同序号重复=重复捕获顶替丢失条目，计数巧合不能放行；
  // 新旧格式混存也属集合身份不明 → 停轮。
  if (indexedCaptureCount > 0 &&
      (legacyCaptureCount > 0 ||
          indexedCaptureCount != capturePromised ||
          sameEpochIndices.toSet().length != capturePromised ||
          sameEpochIndices.toSet().any((i) => i < 0 || i >= capturePromised))) {
    return const EngineeringModeResolution(
      mode: EngineeringRuntimeMode.recoveryRequired,
      reason: 'capture-set-broken',
    );
  }
  final captureActual = indexedCaptureCount + legacyCaptureCount;
  // 只剩一部分（导入丢失等）：complete 声称 N 条而账本不足 N → 停轮保数据
  if (capturePromised > 0 && captureActual < capturePromised) {
    return const EngineeringModeResolution(
      mode: EngineeringRuntimeMode.recoveryRequired,
      reason: 'capture-missing',
    );
  }
  // 多于声称（重复写入）或声称空而有捕获：集合不一致 → 停轮
  if (captureActual > capturePromised) {
    return const EngineeringModeResolution(
      mode: EngineeringRuntimeMode.recoveryRequired,
      reason: 'capture-count-mismatch',
    );
  }
  // 未知关键表面事件：仅检查活跃纪元窗口内（窗口外属关闭期史料，
  // 开启态投影不消费；关闭态本就不从账本装配）。
  for (final event in window) {
    if (event.surfaceOp == null) continue;
    if (!kKnownSurfaceEventTypes.contains(event.type)) {
      return const EngineeringModeResolution(
        mode: EngineeringRuntimeMode.recoveryRequired,
        reason: 'unknown-surface-event',
      );
    }
  }

  return EngineeringModeResolution(
    mode: EngineeringRuntimeMode.normalOpen,
    epochId: epochId,
  );
}

/// 活跃纪元的事件窗口（供开启态投影取材）：从最新 complete 纪元的
/// **enter pending 事件**起读（含捕获——complete 标记之后起读会漏掉
/// 之前写入的全部捕获），到账本末尾。
///
/// 非开启态（无 complete 未退出纪元）返回空列表。
List<AgentDurableEvent> activeEpochWindow(List<AgentDurableEvent> events) {
  final located = _locateActiveEpoch(events);
  if (located == null) return const [];
  final (start, activeEpochId) = located;
  final window = events.sublist(start);
  // 投影只消费合格捕获集合：他纪元捕获即使混入窗口（异常账本）也不进
  // 表面——三态解析会因此停轮，此处不再让错误内容到达模型。
  return [
    for (final event in window)
      if (!(event.type == AgentEventTypes.modeCapture &&
          event.data['epochId'] != null &&
          event.data['epochId'] != activeEpochId))
        event,
  ];
}

/// 活跃纪元在账本内的（原始窗口起点, epochId）；无未退出 complete 纪元
/// 返回 null。完整性校验需要**原始**窗口（混入的他纪元捕获必须在窗内
/// 才能被发现），投影窗口在其上再过滤。
(int, String)? _locateActiveEpoch(List<AgentDurableEvent> events) {
  String? activeEpochId;
  var lastExitIndex = -1;
  var lastEnterCompleteIndex = -1;
  for (var i = 0; i < events.length; i++) {
    final event = events[i];
    if (event.type != AgentEventTypes.modeEpoch) continue;
    final phase = event.data['phase'];
    if (phase == kModeEpochPhaseEnter) {
      if (event.data['status'] == 'complete') {
        lastEnterCompleteIndex = i;
        activeEpochId = (event.data['epochId'] as String?) ?? activeEpochId;
      }
    } else if (phase == kModeEpochPhaseExit) {
      lastExitIndex = i;
    }
  }
  if (lastEnterCompleteIndex < 0 || lastExitIndex > lastEnterCompleteIndex) {
    return null;
  }
  // 起点回溯到同 epochId 的 pending enter（含捕获事件的写入起点）；
  // 找不到（异常账本）退用 complete 位——complete 之后的捕获/轮事件
  // 仍全部在窗内。
  var start = lastEnterCompleteIndex;
  for (var i = lastEnterCompleteIndex; i >= 0; i--) {
    final event = events[i];
    if (event.type != AgentEventTypes.modeEpoch) continue;
    if (event.data['phase'] == kModeEpochPhaseEnter &&
        event.data['status'] != 'complete' &&
        event.data['epochId'] == activeEpochId) {
      start = i;
      break;
    }
  }
  return (start, activeEpochId ?? '');
}

/// 构造 enter pending 事件（原子进入事务的第一条）
AgentDurableEvent modeEpochEnterPendingEvent({
  required String epochId,
  required int fromTurn,
}) {
  return AgentDurableEvent(
    type: AgentEventTypes.modeEpoch,
    data: {
      'phase': kModeEpochPhaseEnter,
      'epochId': epochId,
      'fromTurn': fromTurn,
      'status': 'pending',
    },
  );
}

/// 构造 enter complete 事件（引用 epochId 与捕获集合规模）
AgentDurableEvent modeEpochEnterCompleteEvent({
  required String epochId,
  required int captureCount,
}) {
  return AgentDurableEvent(
    type: AgentEventTypes.modeEpoch,
    data: {
      'phase': kModeEpochPhaseEnter,
      'epochId': epochId,
      'status': 'complete',
      'captureCount': captureCount,
    },
  );
}

/// 构造 exit 事件（用户确认退出后提交；正常关闭态由此恢复旧 trim）
AgentDurableEvent modeEpochExitEvent({required String epochId}) {
  return AgentDurableEvent(
    type: AgentEventTypes.modeEpoch,
    data: {'phase': kModeEpochPhaseExit, 'epochId': epochId},
  );
}

/// 账本内最新未闭合纪元的 epochId（最新 enter——pending 或 complete——
/// 且其后无 exit）。无未闭合纪元返回 null。
///
/// 修复态的「确认退出」用它闭合悬挂纪元：pending 残留 / complete 未退
/// 出都属未闭合；true 列缺纪元（无 enter）时返回 null——退出只置列，
/// 无纪元可闭合。
String? unclosedEpochIdOf(List<AgentDurableEvent> events) {
  String? lastEnterEpochId;
  var lastEnterIndex = -1;
  var lastExitIndex = -1;
  for (var i = 0; i < events.length; i++) {
    final event = events[i];
    if (event.type != AgentEventTypes.modeEpoch) continue;
    final phase = event.data['phase'];
    if (phase == kModeEpochPhaseEnter) {
      lastEnterEpochId = (event.data['epochId'] as String?) ?? lastEnterEpochId;
      lastEnterIndex = i;
    } else if (phase == kModeEpochPhaseExit) {
      lastExitIndex = i;
    }
  }
  if (lastEnterIndex < 0 || lastExitIndex > lastEnterIndex) return null;
  return lastEnterEpochId;
}

/// 把关闭态可见表面（正文+trace 行，含压缩摘要 system 消息）逐条物化为
/// 捕获事件。内容一次写定不可改写；每条带 epochId、集合序号（captureIndex/
/// captureTotal）与 source=mode_capture——complete 事件声称的捕获数只有
/// 配合集合序号才能证明「所指集合仍完整在场」：同序号重复或序号缺漏
/// （重复捕获顶替丢失条目）都是集合破损，进入需要修复态而不是靠计数
/// 巧合放行。
List<AgentDurableEvent> buildEngineeringCaptureEvents({
  required List<AgentMessage> visibleSurface,
  required String epochId,
}) {
  return [
    for (var i = 0; i < visibleSurface.length; i++)
      AgentDurableEvent(
        type: AgentEventTypes.modeCapture,
        surfaceOp: AgentSurfaceOpKind.append,
        data: {
          'as': visibleSurface[i].role == 'assistant'
              ? 'assistant'
              : visibleSurface[i].role == 'system'
                  ? 'system'
                  : 'user',
          'content': visibleSurface[i].content ?? '',
          'epochId': epochId,
          'captureIndex': i,
          'captureTotal': visibleSurface.length,
          'source': 'mode_capture',
        },
      ),
  ];
}

/// 进入事务的捕获产物（fromTurn 与捕获集合同源——同一读快照内算得）
class EngineeringEnterCapture {
  const EngineeringEnterCapture({
    required this.fromTurn,
    required this.captureEvents,
  });

  /// 新纪元的起始轮号
  final int fromTurn;

  /// 捕获事件（[buildEngineeringCaptureEvents] 产物）
  final List<AgentDurableEvent> captureEvents;
}

/// 工程上下文模式切换的原子写入抽象（domain 声明，data 层实现）。
///
/// 实现必须在**同库单事务**内完成：
/// - 进入：pending enter → 捕获事件批量 → complete enter（引用 epochId
///   与捕获数）→ 更新 `chat_sessions.engineering_context_enabled = true`。
///   任一步异常整体回滚，不残留半截提交（异常残留的 pending 按需要
///   修复态保留，不猜为可删垃圾）。
/// - 退出：exit 事件 → 更新列 false。取消退出不写任何库变更。退出的
///   epochId（见 unclosedEpochIdOf）为 null（true 列缺纪元的异常账本）
///   时仅置列——无纪元可闭合。
abstract class EngineeringContextSwitchStore {
  /// 原子进入（captureEvents 为 [buildEngineeringCaptureEvents] 产物；
  /// 事件 seq 由实现连续分配）
  Future<void> applyEngineeringContextEnter({
    required String sessionId,
    required String epochId,
    required int fromTurn,
    required List<AgentDurableEvent> captureEvents,
  });

  /// 原子进入（同快照捕获）：[prepare] 在同一库事务内执行——读取可见
  /// 历史并物化捕获集合，期间并发写入被事务串行化排除，读快照与写入
  /// 一致。生产路径必须走此变体；固定捕获集合的测试可用上面的基础版。
  Future<void> applyEngineeringContextEnterAtomic({
    required String sessionId,
    required String epochId,
    required Future<EngineeringEnterCapture> Function() prepare,
  });

  /// 原子退出（epochId 取 unclosedEpochIdOf 的结果；null = 仅置列）
  Future<void> applyEngineeringContextExit({
    required String sessionId,
    String? epochId,
  });
}
