import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_events.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/features/advanced/data/agent_durable_event_sink.dart';
import 'package:lmstory/features/advanced/data/repositories/agent_event_log_repository.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/services/agent_log_recovery.dart';

/// assistant/chunk 分片落盘（最小粒度/全量档/重试 reset/尾段 flush）
/// + 中断半截正文重建 + 恢复器接线。
void main() {
  group('assistant/chunk 分片落盘（最小粒度）', () {
    test('聚合档：不足阈值缓冲，跨阈值落一条，flush 补尾段', () async {
      final repo = _CapturingEventLogRepository();
      final sink = DurableAgentEventSink(
        repository: repo,
        sessionId: 's1',
        turnNumber: 2,
        chunkThreshold: 10,
      )
        ..emit(AgentTextDeltaEvent(stepIndex: 0, delta: '一二三四五'))
        ..emit(AgentTextDeltaEvent(stepIndex: 0, delta: '六七八九十'))
        ..emit(AgentTextDeltaEvent(stepIndex: 0, delta: '尾段'));

      // 前两段合计 10 字符 = 阈值 → 已缓冲一条 chunk；尾段 2 字符留缓冲
      await sink.flush();
      final chunks = repo.appended
          .where((e) => e.type == AgentEventTypes.assistantChunk)
          .toList();
      expect(chunks, hasLength(2), reason: '跨阈值一条 + flush 尾段一条');
      expect(chunks[0].data['text'], '一二三四五六七八九十');
      expect(chunks[0].data['stepIndex'], 0);
      expect(chunks[0].data['turn'], 2);
      expect(chunks[1].data['text'], '尾段');
      // log-only：不进投影
      expect(chunks[0].surfaceOp, isNull);
      // 投影不含 chunk（重建走专用函数，不经 deriveAgentSurface）
      expect(
        deriveAgentSurface(repo.appended).messages,
        isEmpty,
      );
    });

    test('全量档：每个 delta 一条（fullChunkEvents=true）', () async {
      final repo = _CapturingEventLogRepository();
      final sink = DurableAgentEventSink(
        repository: repo,
        sessionId: 's1',
        chunkThreshold: 10000,
        fullChunkEvents: true,
      )
        ..emit(AgentTextDeltaEvent(stepIndex: 1, delta: 'a'))
        ..emit(AgentTextDeltaEvent(stepIndex: 1, delta: 'b'));
      await sink.flush();

      final chunks = repo.appended
          .where((e) => e.type == AgentEventTypes.assistantChunk)
          .toList();
      expect(chunks.map((c) => c.data['text']).toList(), ['a', 'b']);
    });

    test('重试 reset：同 step 半截流丢弃（契约 §7.1 口径同步）', () async {
      final repo = _CapturingEventLogRepository();
      final sink = DurableAgentEventSink(
        repository: repo,
        sessionId: 's1',
        chunkThreshold: 5,
      )
        ..emit(AgentTextDeltaEvent(stepIndex: 0, delta: '半截正文 abc'))
        ..emit(AgentStepStarted(stepIndex: 0, attempt: 1))
        ..emit(AgentTextDeltaEvent(stepIndex: 0, delta: '重试后的正文'))
        ..emit(
          AgentAssistantMessageEvent(
            stepIndex: 0,
            message: AgentMessage.assistant(text: '完整收尾'),
          ),
        );
      await sink.flush();

      final events = repo.appended;
      final resetChunk = events.firstWhere(
        (e) =>
            e.type == AgentEventTypes.assistantChunk && e.data['reset'] == true,
      );
      expect(resetChunk.data['stepIndex'], 0);

      // 重建：reset 清空前段，只拼重试后内容；assistant/message 收尾后
      // 整体作废（该 step 已完整，无半截可言）
      expect(rebuildInterruptedAssistantText(events), isNull);
    });

    test('禁用档（threshold<=0 且 fullChunkEvents=false）：零分片事件', () async {
      final repo = _CapturingEventLogRepository();
      final sink = DurableAgentEventSink(
        repository: repo,
        sessionId: 's1',
        chunkThreshold: 0,
      )..emit(AgentTextDeltaEvent(stepIndex: 0, delta: '正文'));
      await sink.flush();

      expect(
        repo.appended.where((e) => e.type == AgentEventTypes.assistantChunk),
        isEmpty,
      );
    });

    test('assistant/message 到达即清该 step 的分片缓冲（不双写尾段）', () async {
      final repo = _CapturingEventLogRepository();
      final sink = DurableAgentEventSink(
        repository: repo,
        sessionId: 's1',
        chunkThreshold: 100,
      )
        ..emit(AgentTextDeltaEvent(stepIndex: 0, delta: '流式正文'))
        ..emit(
          AgentAssistantMessageEvent(
            stepIndex: 0,
            message: AgentMessage.assistant(text: '完整正文'),
          ),
        );
      await sink.flush();

      expect(
        repo.appended.where((e) => e.type == AgentEventTypes.assistantChunk),
        isEmpty,
        reason: '完整消息已入账，分片尾段不再落库',
      );
    });
  });

  group('rebuildInterruptedAssistantText（半截正文重建）', () {
    AgentDurableEvent chunk(int step, String text) => AgentDurableEvent(
          type: AgentEventTypes.assistantChunk,
          data: {'stepIndex': step, 'text': text},
        );

    test('分片拼接：最后一个无收尾 step 的全部 chunk 按序拼接', () {
      final text = rebuildInterruptedAssistantText([
        chunk(0, '第一段'),
        AgentDurableEvent(
          type: AgentEventTypes.assistantMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: const AgentAssistantMessageData(text: '完整').toJson(),
        ),
        chunk(1, '半截'),
        chunk(1, '正文续'),
      ]);
      expect(text, '半截正文续');
    });

    test('全部 step 已收尾 → null；reset 后无内容 → null', () {
      expect(
        rebuildInterruptedAssistantText([
          chunk(0, '已完整的流'),
          AgentDurableEvent(
            type: AgentEventTypes.assistantMessage,
            surfaceOp: AgentSurfaceOpKind.append,
            data: const AgentAssistantMessageData(text: 'x').toJson(),
          ),
        ]),
        isNull,
      );
      expect(
        rebuildInterruptedAssistantText([
          chunk(0, '旧尝试'),
          AgentDurableEvent(
            type: AgentEventTypes.assistantChunk,
            data: {'stepIndex': 0, 'reset': true},
          ),
        ]),
        isNull,
      );
    });
  });

  group('恢复器接线（B12：悬挂轮半截正文补 assistant/message）', () {
    test('审查收官 R2-P1-1：前轮已完成同号 step 不让重建失效（限悬挂轮扫描）', () async {
      final repo = _ScriptedEventLogRepository([
        // 轮 1：正常完成，step 0 已有 assistant/message 收尾
        AgentDurableEvent(
          type: AgentEventTypes.turnBegin,
          data: {'maxSteps': 8, 'turn': 1},
        ),
        AgentDurableEvent(
          type: AgentEventTypes.assistantChunk,
          data: {'stepIndex': 0, 'text': '第一轮流式', 'turn': 1},
        ),
        AgentDurableEvent(
          type: AgentEventTypes.assistantMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: const AgentAssistantMessageData(text: '第一轮完整').toJson()
            ..['turn'] = 1,
        ),
        AgentDurableEvent(
          type: AgentEventTypes.turnEnd,
          data: {'reason': 'completed', 'turn': 1},
        ),
        // 轮 2：step 0 流式中途崩溃（悬挂，无 turn/end）
        AgentDurableEvent(
          type: AgentEventTypes.turnBegin,
          data: {'maxSteps': 8, 'turn': 2},
        ),
        AgentDurableEvent(
          type: AgentEventTypes.assistantChunk,
          data: {'stepIndex': 0, 'text': '第二轮半截', 'turn': 2},
        ),
      ]);
      final service = AgentLogRecoveryService(repository: repo);

      // 修复前：completedSteps 含轮 1 的 step 0 → 重建返回 null（静默失效）
      final repaired = await service.recover('s1');
      expect(repaired, isTrue);
      final rebuilt = repo.appended
          .where((e) => e.type == AgentEventTypes.assistantMessage)
          .single;
      expect(rebuilt.data['text'], '第二轮半截');
      expect(rebuilt.data['turn'], 2, reason: '审查收官 R2-P2-6：补写带 turn 戳');
    });

    test('DK8-2：子代理 turn 对在场时主轮悬挂仍被修复（重建不串子代理稿）', () async {
      final repo = _ScriptedEventLogRepository([
        // 主轮 turn 2 悬挂：begin → 半截正文 → spawn 子代理（中继事件
        // data.subagent=true，带独立 turn 对）→ 子代理完成后崩溃，
        // 主轮无 turn/end。修复前：最后一个 turn/begin 是子代理的，
        // 其 turn/end 在后 → 误判 hasEnd=true，主轮悬挂漏修。
        AgentDurableEvent(
          type: AgentEventTypes.turnBegin,
          data: {'maxSteps': 8, 'turn': 2},
        ),
        AgentDurableEvent(
          type: AgentEventTypes.assistantChunk,
          data: {'stepIndex': 0, 'text': '主轮半截正文', 'turn': 2},
        ),
        AgentDurableEvent(
          type: AgentEventTypes.turnBegin,
          data: {'maxSteps': 4, 'turn': 2, 'subagent': true},
        ),
        AgentDurableEvent(
          type: AgentEventTypes.assistantChunk,
          data: {'stepIndex': 0, 'text': '子代理草稿', 'turn': 2, 'subagent': true},
        ),
        AgentDurableEvent(
          type: AgentEventTypes.turnEnd,
          data: {'reason': 'completed', 'turn': 2, 'subagent': true},
        ),
      ]);
      final service = AgentLogRecoveryService(repository: repo);

      final repaired = await service.recover('s1');

      expect(repaired, isTrue);
      final rebuilt = repo.appended
          .where((e) => e.type == AgentEventTypes.assistantMessage)
          .single;
      expect(rebuilt.data['text'], '主轮半截正文', reason: '重建不串子代理草稿');
      expect(rebuilt.data['turn'], 2);
      final turnEnd =
          repo.appended.where((e) => e.type == AgentEventTypes.turnEnd).single;
      expect(
        turnEnd.data['subagent'],
        isNull,
        reason: '补合成的是主轮的 turn/end',
      );
    });

    test('DK8-2：子代理执行中崩溃 → 锚定主轮，半截正文不静默丢失', () async {
      final repo = _ScriptedEventLogRepository([
        AgentDurableEvent(
          type: AgentEventTypes.turnBegin,
          data: {'maxSteps': 8, 'turn': 3},
        ),
        AgentDurableEvent(
          type: AgentEventTypes.assistantChunk,
          data: {'stepIndex': 0, 'text': '主代理写了一半', 'turn': 3},
        ),
        // 子代理执行中崩溃：只有子代理的 turn/begin，无任何 turn/end。
        // 修复前：锚定子代理 begin，重建窗口只剩子代理分片——主代理
        // 此前半截正文静默丢失。
        AgentDurableEvent(
          type: AgentEventTypes.turnBegin,
          data: {'maxSteps': 4, 'turn': 3, 'subagent': true},
        ),
        AgentDurableEvent(
          type: AgentEventTypes.assistantChunk,
          data: {'stepIndex': 1, 'text': '子代理半截', 'turn': 3, 'subagent': true},
        ),
      ]);
      final service = AgentLogRecoveryService(repository: repo);

      final repaired = await service.recover('s1');

      expect(repaired, isTrue);
      final rebuilt = repo.appended
          .where((e) => e.type == AgentEventTypes.assistantMessage)
          .single;
      expect(rebuilt.data['text'], '主代理写了一半');
      expect(rebuilt.data['turn'], 3, reason: 'turn 戳取主轮 begin 的 turn');
    });

    test('chunk 分片存在 → 修复事件含重建正文；无分片 → 行为同旧', () async {
      final repo = _ScriptedEventLogRepository([
        AgentDurableEvent(
          type: AgentEventTypes.turnBegin,
          data: {'maxSteps': 8, 'turn': 1},
        ),
        AgentDurableEvent(
          type: AgentEventTypes.assistantChunk,
          data: {'stepIndex': 0, 'text': '夜色沉下来，苏明远推开荒庙的', 'turn': 1},
        ),
        AgentDurableEvent(
          type: AgentEventTypes.assistantChunk,
          data: {'stepIndex': 0, 'text': '门。', 'turn': 1},
        ),
      ]);
      final service = AgentLogRecoveryService(repository: repo);

      final repaired = await service.recover('s1');

      expect(repaired, isTrue);
      final repairedText = repo.appended
          .where((e) => e.type == AgentEventTypes.assistantMessage)
          .single;
      expect(repairedText.data['text'], '夜色沉下来，苏明远推开荒庙的门。');
      expect(repairedText.data['interrupted'], isTrue);
      expect(repairedText.surfaceOp, AgentSurfaceOpKind.append);
      // 重建消息进投影（下一轮重放可见半截稿）
      final projection =
          deriveAgentSurface([...repo.scripted, ...repo.appended]);
      expect(projection.messages.single.content, contains('荒庙的门'));
      // turn/end 补合成照旧
      expect(
        repo.appended.any((e) => e.type == AgentEventTypes.turnEnd),
        isTrue,
      );
    });
  });

  group('D9 孤儿 surface 事件回收（R2-P2-7）', () {
    test('场景A：首轮 bootstrap 后崩溃（无 turn/begin）——surface 孤儿全回收，log-only 不动',
        () async {
      final repo = _ScriptedEventLogRepository([
        AgentDurableEvent(
          seq: 0,
          type: AgentEventTypes.systemFrozen,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': 'prefix', 'turn': 1},
        ),
        AgentDurableEvent(
          seq: 1,
          type: AgentEventTypes.systemCore,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': 'core', 'turn': 1},
        ),
        AgentDurableEvent(
          seq: 2,
          type: AgentEventTypes.userMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': '用户输入', 'turn': 1, 'source': 'user'},
        ),
        AgentDurableEvent(
          seq: 3,
          type: AgentEventTypes.persistEmbeddingDegraded,
          data: {'turn': 1, 'error': 'x'},
        ),
      ]);
      final service = AgentLogRecoveryService(repository: repo);

      final repaired = await service.recover('s1');

      expect(repaired, isTrue);
      expect(repo.deletedSeqs, [0, 1, 2], reason: '只有 surface 孤儿被回收');
      expect(
        repo.scripted.where((e) => e.surfaceOp != null),
        isEmpty,
        reason: '投影面清空，下轮 bootstrap 重写不重复',
      );
      expect(
        repo.scripted.map((e) => e.seq),
        [3],
        reason: 'log-only 留痕（persist/*）不回收',
      );
      expect(repo.appended, isEmpty, reason: '无悬挂轮需要修复');
    });

    test('场景B：完整轮后 bootstrap 崩溃——尾部孤儿回收，完整轮不动', () async {
      final repo = _ScriptedEventLogRepository([
        AgentDurableEvent(
          seq: 0,
          type: AgentEventTypes.turnBegin,
          data: {'turn': 1},
        ),
        AgentDurableEvent(
          seq: 1,
          type: AgentEventTypes.userMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': '第一轮输入', 'turn': 1},
        ),
        AgentDurableEvent(
          seq: 2,
          type: AgentEventTypes.turnEnd,
          data: {'reason': 'completed', 'turn': 1},
        ),
        // 轮2 bootstrap 落账后崩溃（turn/begin 未写）
        AgentDurableEvent(
          seq: 3,
          type: AgentEventTypes.userMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': '第二轮输入', 'turn': 2},
        ),
        AgentDurableEvent(
          seq: 4,
          type: AgentEventTypes.systemFrozen,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': 'new prefix', 'turn': 2},
        ),
      ]);
      final service = AgentLogRecoveryService(repository: repo);

      final repaired = await service.recover('s1');

      expect(repaired, isTrue);
      expect(repo.deletedSeqs, [3, 4], reason: '只回收最后 end 之后的尾部孤儿');
      expect(
        repo.scripted.map((e) => e.seq),
        [0, 1, 2],
        reason: '完整轮与其内事件保留',
      );
    });

    test('悬挂轮的轮前 bootstrap 不误删（D9 与 B12 修复互不干扰）', () async {
      final repo = _ScriptedEventLogRepository([
        AgentDurableEvent(
          seq: 0,
          type: AgentEventTypes.turnBegin,
          data: {'turn': 1},
        ),
        AgentDurableEvent(
          seq: 1,
          type: AgentEventTypes.turnEnd,
          data: {'reason': 'completed', 'turn': 1},
        ),
        // 轮2 bootstrap（合法：随后有 turn/begin，属悬挂轮前缀）
        AgentDurableEvent(
          seq: 2,
          type: AgentEventTypes.userMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': '第二轮输入', 'turn': 2},
        ),
        AgentDurableEvent(
          seq: 3,
          type: AgentEventTypes.turnBegin,
          data: {'turn': 2},
        ),
        AgentDurableEvent(
          seq: 4,
          type: AgentEventTypes.assistantChunk,
          data: {'stepIndex': 0, 'text': '半截', 'turn': 2},
        ),
      ]);
      final service = AgentLogRecoveryService(repository: repo);

      final repaired = await service.recover('s1');

      expect(repaired, isTrue, reason: '悬挂轮修复照常执行');
      expect(repo.deletedSeqs, isEmpty, reason: '悬挂轮的轮前 bootstrap 合法保留');
      expect(
        repo.appended.any((e) => e.type == AgentEventTypes.turnEnd),
        isTrue,
        reason: '合成 turn/end 修复悬挂轮',
      );
      final projection =
          deriveAgentSurface([...repo.scripted, ...repo.appended]);
      expect(
        projection.messages.map((m) => m.content),
        contains(contains('第二轮输入')),
        reason: '轮2 用户消息仍在投影',
      );
    });

    test('无孤儿无悬挂：返回 false 不动日志', () async {
      final repo = _ScriptedEventLogRepository([
        AgentDurableEvent(
          seq: 0,
          type: AgentEventTypes.turnBegin,
          data: {'turn': 1},
        ),
        AgentDurableEvent(
          seq: 1,
          type: AgentEventTypes.turnEnd,
          data: {'reason': 'completed', 'turn': 1},
        ),
        AgentDurableEvent(
          seq: 2,
          type: AgentEventTypes.persistEmbeddingDegraded,
          data: {'turn': 1, 'error': 'x'},
        ),
      ]);
      final service = AgentLogRecoveryService(repository: repo);

      expect(await service.recover('s1'), isFalse);
      expect(repo.deletedSeqs, isEmpty);
      expect(repo.appended, isEmpty);
    });
  });
}

class _CapturingEventLogRepository implements AgentEventLogRepository {
  final List<AgentDurableEvent> appended = [];

  @override
  Future<List<int>> appendAll(
    String sessionId,
    List<AgentDurableEvent> events,
  ) async {
    appended.addAll(events);
    return List.generate(events.length, (i) => i);
  }

  @override
  Future<List<AgentDurableEvent>> readEvents(
    String sessionId, {
    int? fromSeq,
    int? limit,
  }) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _ScriptedEventLogRepository implements AgentEventLogRepository {
  _ScriptedEventLogRepository(this.scripted);

  final List<AgentDurableEvent> scripted;
  final List<AgentDurableEvent> appended = [];
  final List<int> deletedSeqs = [];

  @override
  Future<List<int>> appendAll(
    String sessionId,
    List<AgentDurableEvent> events,
  ) async {
    appended.addAll(events);
    return List.generate(events.length, (i) => i);
  }

  @override
  Future<List<AgentDurableEvent>> readEvents(
    String sessionId, {
    int? fromSeq,
    int? limit,
  }) async =>
      scripted;

  @override
  Future<void> deleteAtSeqs(String sessionId, List<int> seqs) async {
    deletedSeqs.addAll(seqs);
    scripted.removeWhere((e) => e.seq != null && seqs.contains(e.seq));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
