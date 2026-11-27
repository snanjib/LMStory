import 'package:lmstory/core/agent/agent_events.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/agent/agent_workbench_reminder.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/services/engineering_context_mode.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 事件日志存取抽象。
///
/// domain 不得 import data 实现（AGENTS.md 分层红线）——此前本文件直接
/// 依赖 data 层 `AgentEventLogRepository` 具体类，现倒置为：domain 声明
/// 抽象，data 层仓库实现之。恢复器/控制器/runner 均按本抽象消费
/// （presentation 不再 import data 具体类）。
abstract class AgentEventLogStore {
  /// 读取会话全部事件（seq 升序）
  Future<List<AgentDurableEvent>> readEvents(String sessionId);

  /// 批量追加事件（seq 连续分配），返回分配的 seq 列表
  Future<List<int>> appendAll(
    String sessionId,
    List<AgentDurableEvent> events,
  );

  /// 从指定轮或更晚的首个非冻结事件起截断日志。[rollbackStory] 可在同一数据库事务中先回退
  /// 正文和记忆，跨越工程上下文开启点时由 [captureHistory] 读取新历史。
  /// 返回是否删掉冻结前缀。
  Future<bool> deleteTurnEvents(
    String sessionId,
    int turn, {
    Future<void> Function()? rollbackStory,
    Future<EngineeringEnterCapture> Function(String epochId)? captureHistory,
  });

  /// 读取全部纪元边界事件（mode/epoch 行，seq 升序）——三态解析的廉价
  /// 预检通道：列非 true 且无纪元证据的会话即普通旧会话。
  Future<List<AgentDurableEvent>> readModeEpochEvents(String sessionId);

  /// 滚动保留最近 [keepTurns] 轮（批 I 事件日志保留，runner 冷路径消费）
  Future<int> trimToRecentTurns(String sessionId, int keepTurns);

  /// 按序号精确删除事件（：孤儿 surface 事件回收——
  /// 只清无轮归属的 surface 事件，log-only 留痕不动）
  Future<void> deleteAtSeqs(String sessionId, List<int> seqs);
}

/// Narrow reads for checking the ledger when a session opens.
abstract interface class AgentLogMaintenanceStore
    implements AgentEventLogStore {
  Future<T> runLogMaintenance<T>(Future<T> Function() operation);

  Future<List<AgentDurableEvent>> readEngineeringModeEvidence(String sessionId);

  Future<List<AgentDurableEvent>> readRecoveryCompactionEvents(
    String sessionId,
  );

  Future<({bool hasDanglingTurn, List<int> orphanSeqs})> probeTurnRecovery(
    String sessionId,
  );

  Future<List<AgentDurableEvent>> readLatestUsageEvent(String sessionId);
}

/// 中断半截正文补账事件（悬挂轮修复与失败真续跑共用）
///
/// 最后一个有 assistant/chunk 分片但无 assistant/message 收尾的 step，
/// 其已流出正文经分片拼接后补一条 assistant/message 落账（surface
/// append：模型续跑可见自己写过的半截稿；轮轨迹页可展示）。
/// 无可重建正文时返回 null。
AgentDurableEvent? interruptedTextRepairEvent(
  List<AgentDurableEvent> turnEvents, {
  required int? turn,
}) {
  final interruptedText = rebuildInterruptedAssistantText(turnEvents);
  if (interruptedText == null || interruptedText.isEmpty) return null;
  final data = AgentAssistantMessageData(
    text: interruptedText,
    stepIndex: AgentLogRecoveryService._lastChunkedStep(turnEvents),
  ).toJson()
    ..['interrupted'] = true;
  if (turn != null) data['turn'] = turn;
  return AgentDurableEvent(
    type: AgentEventTypes.assistantMessage,
    surfaceOp: AgentSurfaceOpKind.append,
    data: data,
  );
}

/// 真续跑时补在 assistant 尾轮之后的 user 指令。
///
/// Gemini 等协议要求请求最后一条是 user 轮（`Requests ending with a model
/// turn are not supported.`）；续跑投影常以中断半截正文（assistant）收尾，
/// 这条消息既补齐协议要求，也明确「从断点继续、不重复」。
const String kDirectorResumeContinuation = '【续跑】上一轮在生成途中中断。请从断点继续，不要重复已经输出的内容；'
    '若正文已经完整，按工作契约调用 finish_round 收尾。';

/// 投影末尾未配对的工具调用（callId/toolName）。
List<({String callId, String toolName})> _pendingToolCallsOf(
  AgentSurfaceProjection projection,
) {
  final pending = <({String callId, String toolName})>[];
  for (var i = projection.messages.length - 1; i >= 0; i--) {
    final message = projection.messages[i];
    if (message.role == 'tool') continue;
    if (message.role != 'assistant') break;
    final calls = message.toolCalls;
    if (calls == null || calls.isEmpty) continue;
    final answered = <String>{};
    for (var j = i + 1; j < projection.messages.length; j++) {
      final later = projection.messages[j];
      if (later.role == 'assistant') break;
      if (later.role == 'tool' && later.toolCallId != null) {
        answered.add(later.toolCallId!);
      }
    }
    for (final call in calls) {
      if (!answered.contains(call.id)) {
        pending.add((callId: call.id, toolName: call.name));
      }
    }
    break;
  }
  return pending;
}

/// 续跑前的 surface 尾部归一（纯函数，返回按序 append 的事件）。
///
/// 1. 末尾未配对的 tool_call → 占位 tool/result（协议配对；否则续跑首个
///    请求会因 function call/response 数量不匹配被拒）；
/// 2. 中断半截正文补账（[textRepair]）；
/// 3. 归一后仍以 assistant 收尾 → 追加 user 续跑指令（Gemini 拒绝以
///    model 轮结束的请求）。
///
/// 调用方写库后重新投影，保证「进模型的必已入日志」。
List<AgentDurableEvent> resumeRepairEvents({
  required AgentSurfaceProjection projection,
  required AgentDurableEvent? textRepair,
  required int turn,
  required String toolPlaceholderTitle,
}) {
  final pendingCalls = _pendingToolCallsOf(projection);
  final events = <AgentDurableEvent>[
    for (final call in pendingCalls)
      AgentDurableEvent(
        type: AgentEventTypes.toolResult,
        surfaceOp: AgentSurfaceOpKind.append,
        data: (AgentToolResultData(
          callId: call.callId,
          toolName: call.toolName,
          output: AgentLogRecoveryService.interruptedOutput,
          isError: true,
          title: toolPlaceholderTitle,
        ).toJson())
          ..['turn'] = turn,
      ),
    if (textRepair != null) textRepair,
  ];

  final lastNonSystem = _lastNonSystemMessage(projection);
  final needsContinuation = textRepair != null ||
      (pendingCalls.isEmpty && lastNonSystem?.role == 'assistant');
  if (needsContinuation) {
    events.add(
      AgentDurableEvent(
        type: AgentEventTypes.userMessage,
        surfaceOp: AgentSurfaceOpKind.append,
        data: (AgentUserMessageData(
          content: wrapWorkbenchReminder(kDirectorResumeContinuation),
          source: AgentInjectedMessageKinds.resumeContinuation,
        ).toJson())
          ..['turn'] = turn,
      ),
    );
  }
  return events;
}

AgentMessage? _lastNonSystemMessage(AgentSurfaceProjection projection) {
  for (final message in projection.messages.reversed) {
    if (message.role != 'system') return message;
  }
  return null;
}

/// 崩溃恢复：未闭合压缩操作收敛（cancelled 优先——已有作废记录则以
/// cancelled 收敛，否则 interrupted）。恢复器在轮修复前调用；表面不变。
Future<void> recoverUnclosedCompactions(
  AgentEventLogStore repository,
  String sessionId,
) async {
  final events = repository is AgentLogMaintenanceStore
      ? await repository.readRecoveryCompactionEvents(sessionId)
      : await repository.readEvents(sessionId);
  await _closeUnfinishedCompaction(repository, sessionId, events);
}

Future<bool> _closeUnfinishedCompaction(
  AgentEventLogStore repository,
  String sessionId,
  List<AgentDurableEvent> events,
) async {
  String? openOpId;
  final cancelledOps = <String>{};
  for (final e in events) {
    if (e.type == AgentEventTypes.compactionStart) {
      final id = e.data['opId'];
      if (id is String) openOpId = id;
    } else if (e.type == AgentEventTypes.compactionEnd ||
        e.type == AgentEventTypes.compactionUndo) {
      final id = e.data['opId'] ?? e.data['targetOpId'];
      if (id is String && id == openOpId) openOpId = null;
    } else if (e.type == AgentEventTypes.compactionCancel) {
      final id = e.data['opId'];
      if (id is String) cancelledOps.add(id);
    }
  }
  if (openOpId == null) return false;
  await repository.appendAll(sessionId, [
    AgentDurableEvent(
      type: AgentEventTypes.compactionEnd,
      data: {
        'opId': openOpId,
        'error': cancelledOps.contains(openOpId) ? 'cancelled' : 'interrupted',
      },
    ),
  ]);
  return true;
}

/// Agent 会话恢复器（dsh 崩溃恢复纪律，设计报告 §7.3）
///
/// 打开会话时检查事件日志是否存在悬挂轮（turn/begin 无对应 turn/end）：
/// 崩溃/进程被杀/后台中断的轮不截断日志，而是补合成
/// `turn/end{reason: interrupted}` 事件；surface 投影里的未配对工具调用
/// 由 `repairDanglingTurn` 一并补占位 tool/result（协议配对合法，
/// 下一轮重放不报错）。iOS 30s 落盘 interrupted 语义的 Dart 侧实现。
class AgentLogRecoveryService {
  AgentLogRecoveryService({
    required AgentEventLogStore repository,
    Logger? logger,
  })  : _repository = repository,
        _logger = logger;

  /// 崩溃恢复写入的占位输出（HAR-07 中性化：与 i18n
  /// `advanced.process.interruptedToolOutput` 同文——中断时操作是否已
  /// 执行无法确认，不诱导模型/用户盲目重试，需基于当前状态重新判断）
  static const String interruptedOutput =
      '（应用中断，此操作是否已执行无法确认；如仍需要请基于当前状态重新判断后再操作）';

  /// 历史存量协议值（仅识别兼容：旧日志的占位仍可被 UI 转译，不再写入）
  static const String legacyInterruptedOutput = '（应用中断，未执行；如仍需要请在后续轮次重试）';
  static const String legacyInterruptedShortOutput = '（应用中断，未执行…）';
  static const String legacyInterruptedEnglishOutput =
      '(Application interrupted, not executed; please retry in subsequent turns if still needed)';

  /// 崩溃恢复与主动中断写入的占位标题（历史存量协议值）
  static const String legacyPlaceholderTitleZh = '中断占位';
  static const String legacyPlaceholderTitleEn = 'Interrupted';
  static const String legacyPlaceholderTitleSynthetic = '占位补齐';

  /// 判定是否为崩溃恢复或中断占位标题（UI 渲染层据此转为当前 locale 的文案）
  static bool isPlaceholderTitle(String title) =>
      title == legacyPlaceholderTitleZh ||
      title == legacyPlaceholderTitleEn ||
      title == legacyPlaceholderTitleSynthetic;

  /// 判定是否为崩溃恢复或中断占位输出（UI 渲染层据此转为当前 locale 的文案）
  static bool isInterruptedOutput(String output) {
    final trimmed = output.trim();
    return trimmed == interruptedOutput ||
        trimmed == legacyInterruptedOutput ||
        trimmed == legacyInterruptedShortOutput ||
        trimmed == legacyInterruptedEnglishOutput ||
        trimmed == '（本轮已中断，未执行）' ||
        trimmed == '本轮已中断，未执行' ||
        trimmed == '（本轮异常终止，未执行）' ||
        trimmed == '本轮异常终止，未执行' ||
        trimmed == '（循环保护拦截：同参数重复调用）' ||
        trimmed == '循环保护拦截：同参数重复调用' ||
        trimmed == '（finish_round 反复失败，本轮停止）' ||
        trimmed == 'finish_round 反复失败，本轮停止';
  }

  final AgentEventLogStore _repository;
  final Logger? _logger;

  /// 恢复会话：先回收孤儿 surface 事件，再修复悬挂轮，返回是否执行了修复
  Future<bool> recover(String sessionId) async {
    final store = _repository;
    if (store is AgentLogMaintenanceStore) {
      return store.runLogMaintenance(() async {
        // 先收敛未闭合压缩，再在同一事务内读取更新后的尾部。
        await recoverUnclosedCompactions(store, sessionId);
        final probe = await store.probeTurnRecovery(sessionId);
        if (!probe.hasDanglingTurn) {
          return _deleteOrphanSurfaceEvents(sessionId, probe.orphanSeqs);
        }
        // 悬挂轮需要投影才能正确配对工具调用。
        return _recoverTurns(sessionId, await store.readEvents(sessionId));
      });
    }
    final events = await store.readEvents(sessionId);
    final didWrite = await _closeUnfinishedCompaction(store, sessionId, events);
    return _recoverTurns(
      sessionId,
      didWrite ? await store.readEvents(sessionId) : events,
    );
  }

  Future<bool> _recoverTurns(
    String sessionId,
    List<AgentDurableEvent> events,
  ) async {
    if (events.isEmpty) return false;

    // 找最后一个主轮 turn/begin，检查其后是否有主轮 turn/end。
    // 子代理中继事件（data.subagent=true，见
    // DurableAgentEventSink.relaySubagentEvent）带独立 turn 对——不滤的
    // 话：a) 子代理完成后主轮崩溃 → 误判 hasEnd=true 漏修；b) 子代理
    // 执行中崩溃 → 锚定错轮，主代理此前半截正文静默丢失。轨迹页
    // （agent_round_trace_controller）同款过滤先例。
    var lastTurnBeginIndex = -1;
    for (var i = events.length - 1; i >= 0; i--) {
      final event = events[i];
      if (event.type == AgentEventTypes.turnBegin &&
          event.data['subagent'] != true) {
        lastTurnBeginIndex = i;
        break;
      }
    }
    if (lastTurnBeginIndex == -1) {
      // 全日志无主轮 begin——首轮 bootstrap 落账后、
      // turn/begin 未写即崩溃的前缀孤儿。不回收的话下轮 bootstrap 重写，
      // 同一用户消息在投影里出现两遍。
      return _reclaimOrphanSurfaceEvents(sessionId, events, from: 0);
    }

    var lastMainTurnEndIndex = -1;
    for (var i = events.length - 1; i > lastTurnBeginIndex; i--) {
      final e = events[i];
      if (e.type == AgentEventTypes.turnEnd && e.data['subagent'] != true) {
        lastMainTurnEndIndex = i;
        break;
      }
    }
    if (lastMainTurnEndIndex != -1) {
      // 最后主轮已闭合：检查下一轮 bootstrap 落账后、turn/begin 未写
      // 即崩溃的尾部孤儿。
      return _reclaimOrphanSurfaceEvents(
        sessionId,
        events,
        from: lastMainTurnEndIndex + 1,
      );
    }

    // 悬挂轮：补占位 tool/result（surface 配对）+ 合成 turn/end{interrupted}
    final repairEvents = <AgentDurableEvent>[];
    final projection = deriveAgentSurface(events);
    // 审查收官 ：重建/stepIndex 仅限悬挂轮内事件——step 序号每轮
    // 归零，全会话扫描会让前轮已完成同号 step 永久驻留 completedSteps，
    // 重建静默失效甚至拼接取消轮残片。
    // 窗口内再滤子代理中继（含分片）——子代理是独立上下文，其
    // 分片不属于主轮正文，混入会让重建拼接子代理草稿
    final danglingTurnEvents = [
      for (final e in events.sublist(lastTurnBeginIndex + 1))
        if (e.data['subagent'] != true) e,
    ];
    // 审查收官 ：补写事件统一带 turn 戳（轨迹页/工作摘要按 turn
    // 过滤，无戳则修复轮永远无 reason 与时长）
    final danglingTurn =
        (events[lastTurnBeginIndex].data['turn'] as num?)?.toInt();

    // 投影末尾若为带未配对调用的 assistant，补占位（坐标从投影反查事件）
    final pendingCalls = _pendingToolCallsOf(projection);

    for (final call in pendingCalls) {
      final data = AgentToolResultData(
        callId: call.callId,
        toolName: call.toolName,
        output: interruptedOutput,
        isError: true,
        title: t.advanced.process.interruptedToolPlaceholder,
      ).toJson();
      if (danglingTurn != null) data['turn'] = danglingTurn;
      repairEvents.add(
        AgentDurableEvent(
          type: AgentEventTypes.toolResult,
          surfaceOp: AgentSurfaceOpKind.append,
          data: data,
        ),
      );
    }

    // 中断半截正文重建——最后一个有 assistant/chunk 分片但无
    // assistant/message 收尾的 step，其已流出正文经分片拼接后补一条
    // assistant/message 落账（surface append：下一轮重放可见自己写过的
    // 半截稿；轮轨迹页可展示）。写入位置在工具占位之后（协议配对优先）。
    final textRepair = interruptedTextRepairEvent(
      danglingTurnEvents,
      turn: danglingTurn,
    );
    if (textRepair != null) {
      repairEvents.add(textRepair);
    }

    repairEvents.add(
      AgentDurableEvent(
        type: AgentEventTypes.turnEnd,
        data: {
          'reason': 'interrupted',
          'steps': null,
          'note': '崩溃恢复补合成（恢复器 repairDanglingTurn）',
          if (danglingTurn != null) 'turn': danglingTurn,
        },
      ),
    );

    await _repository.appendAll(sessionId, repairEvents);
    final rebuiltText = textRepair?.data['text'];
    final rebuiltChars = rebuiltText is String ? rebuiltText.length : 0;
    _logger?.info(
      'Agent dangling turn repaired',
      detail: 'sessionId=$sessionId, placeholders=${pendingCalls.length}, '
          'rebuiltChars=$rebuiltChars',
    );
    return true;
  }

  /// 回收无轮归属的孤儿 surface 事件
  ///
  /// 孤儿=轮结构外的 surface 投影事件（surfaceOp 非空）：bootstrap 面的
  /// system/frozen、system/core、user/message 等在 turn/begin 落笔前崩溃
  /// 残留。回收后下轮 bootstrap 重写，投影不重复。log-only 非 surface
  /// 事件（persist/* 等）带 turn 戳且合法存在于轮外，不回收。
  Future<bool> _reclaimOrphanSurfaceEvents(
    String sessionId,
    List<AgentDurableEvent> events, {
    required int from,
  }) async {
    final orphanSeqs = <int>[];
    for (final e in events.skip(from)) {
      // 模式切换和回退重建的快照归属纪元，允许在轮与轮之间落账。
      if (e.surfaceOp == null || e.type == AgentEventTypes.modeCapture) {
        continue;
      }
      final seq = e.seq;
      if (seq == null) continue;
      orphanSeqs.add(seq);
    }
    return _deleteOrphanSurfaceEvents(sessionId, orphanSeqs);
  }

  Future<bool> _deleteOrphanSurfaceEvents(
    String sessionId,
    List<int> orphanSeqs,
  ) async {
    if (orphanSeqs.isEmpty) return false;
    await _repository.deleteAtSeqs(sessionId, orphanSeqs);
    _logger?.info(
      'Agent orphan surface events reclaimed',
      detail: 'sessionId=$sessionId, count=${orphanSeqs.length}, '
          'seqs=${orphanSeqs.join(',')}',
    );
    return true;
  }

  /// 最后一个带 assistant/chunk 分片的 step 序号（重建消息的 stepIndex；
  /// 无分片返回 0）
  static int _lastChunkedStep(List<AgentDurableEvent> events) {
    for (final event in events.reversed) {
      if (event.type != AgentEventTypes.assistantChunk) continue;
      if (event.data['reset'] == true) continue;
      return (event.data['stepIndex'] as num?)?.toInt() ?? 0;
    }
    return 0;
  }
}
