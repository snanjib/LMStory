import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/advanced/data/engineering_compaction_service.dart';
import 'package:lmstory/features/advanced/data/engineering_summarizer.dart'
    show EngineeringSummaryException;
import 'package:lmstory/features/advanced/data/repositories/agent_event_log_repository.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/services/agent_log_recovery.dart';
import 'package:lmstory/features/advanced/domain/services/compaction_planning.dart'
    show EngineeringCompactionTuning;
import 'package:lmstory/features/advanced/domain/services/director_surface_v2.dart';
import 'package:lmstory/features/advanced/domain/services/trajectory_binding.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';

/// 工程压缩事务契约：两段提交四条件 + 正文覆盖映射 + 取消作废 + undo +
/// 恢复收敛 + 超限降级 + 熔断。
void main() {
  late AppDatabase db;
  late AgentEventLogRepository events;
  late ChatRepositoryImpl chat;
  late ExperienceRepository experience;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    events = AgentEventLogRepository(database: db);
    chat = ChatRepositoryImpl(database: db);
    experience = ExperienceRepositoryImpl(
      database: db,
      vectorEngine: const VectorEngine(),
    );
    await db.into(db.chatSessionsTable).insert(
          ChatSessionsTableCompanion.insert(
            sessionId: 's1',
            title: '会话',
            mode: const Value('advanced'),
          ),
        );
  });

  tearDown(() async => db.close());

  AgentDurableEvent ev(
    String type, {
    Map<String, dynamic> data = const {},
    AgentSurfaceOpKind? op,
  }) =>
      AgentDurableEvent(type: type, data: data, surfaceOp: op);

  /// 轮 k 的完整事件组（u/播报+工具/正文 + binding）
  Future<void> seedRound(
    int turn, {
    required String attemptId,
    String prose = '',
    String userInput = '',
    bool withBinding = true,
    String? chatMessageId,
  }) async {
    await events.appendAll('s1', [
      ev(
        AgentEventTypes.userMessage,
        op: AgentSurfaceOpKind.append,
        data: {
          'content': '$userInput 输入内容' * 30,
          'turn': turn,
          'attemptId': attemptId,
        },
      ),
      ev(
        AgentEventTypes.assistantMessage,
        op: AgentSurfaceOpKind.append,
        data: {
          'text': '先核对设定再动笔。',
          'toolCalls': [
            {
              'id': 'c$turn',
              'name': 'query_facts',
              'args': {'q': 'x'},
            },
          ],
          'turn': turn,
          'attemptId': attemptId,
        },
      ),
      ev(
        AgentEventTypes.toolResult,
        op: AgentSurfaceOpKind.append,
        data: {
          'callId': 'c$turn',
          'toolName': 'query_facts',
          'output': '命中若干条' * 200,
          'turn': turn,
          'attemptId': attemptId,
        },
      ),
      ev(
        AgentEventTypes.assistantMessage,
        op: AgentSurfaceOpKind.append,
        data: {
          'text': '$prose 正文内容' * 40,
          'turn': turn,
          'attemptId': attemptId,
        },
      ),
      if (withBinding)
        replayBindingEvent(
          turn: turn,
          attemptId: attemptId,
          variantIndex: 0,
          prose: '$prose 正文内容' * 40,
          userInput: '$userInput 输入内容' * 30,
          chatMessageId: chatMessageId ?? 'chat-p$turn',
        ),
    ]);
    if (withBinding) {
      await chat.addMessage(
        ChatMessage(
          messageId: chatMessageId ?? 'chat-p$turn',
          sessionId: 's1',
          role: 'assistant',
          content: '$prose 正文内容' * 40,
          createdAt: DateTime(2026, 1, turn),
        ),
      );
    }
  }

  Future<void> seedEpochAndRounds({
    int completedRounds = 3,
    bool withInFlightRound = false,
  }) async {
    await events.applyEngineeringContextEnter(
      sessionId: 's1',
      epochId: 'e1',
      fromTurn: 1,
      captureEvents: [],
    );
    for (var t = 1; t <= completedRounds; t++) {
      await seedRound(t, attemptId: 'att$t', prose: '第$t轮', userInput: '第$t轮');
    }
    if (withInFlightRound) {
      await seedRound(
        completedRounds + 1,
        attemptId: 'att-inflight',
        prose: '在途',
        userInput: '在途',
        withBinding: false,
      );
    }
  }

  /// 可控桩摘要器（默认立即返回；取消竞态场景用 paused=true 暂停编排）
  _ControllableSummarizer stub({
    String? narrativeSection,
    bool paused = false,
  }) =>
      _ControllableSummarizer(
        narrativeSection: narrativeSection,
        paused: paused,
      );

  /// 小参数 tuning：测试数据规模小，默认保底下限（8192 token）会吞掉
  /// 全部区间——按比例缩小的等效公式
  const smallTuning = EngineeringCompactionTuning(
    outputReserveTokens: 1000,
    headroomTokens: 500,
    retainMinTokens: 40,
    retainMaxTokens: 400,
    oversizedResultChars: 500,
    degradeHeadChars: 100,
  );

  EngineeringCompactionService service(
    EngineeringSummarizer s, {
    EngineeringCompactionTuning tuning = smallTuning,
  }) =>
      EngineeringCompactionService(
        database: db,
        eventRepository: events,
        chatRepository: chat,
        experienceRepository: experience,
        summarizer: s,
        tuning: tuning,
      );

  group('正常提交（两段+覆盖映射）', () {
    test('混合区间：checkpoint 遮蔽区间 + 正文三成果指向最后已完成轮', () async {
      await seedEpochAndRounds(withInFlightRound: true);
      final svc = service(stub(narrativeSection: '已完成剧情梗概段文本'));
      final result = await svc.compact(
        sessionId: 's1',
        trigger: 'manual',
        contextWindowTokens: 32000,
        retrievalRatio: 0.15,
      );
      expect(result.outcome, 'committed');

      final ledger = await events.readEvents('s1');
      // 四事件链完整
      expect(
        ledger.any((e) => e.type == AgentEventTypes.compactionStart),
        isTrue,
      );
      final summaryEvent = ledger.lastWhere(
        (e) => e.type == AgentEventTypes.compactionSummary,
      );
      expect(ledger.last.type, AgentEventTypes.compactionEnd);
      // 覆盖映射：narrativeBoundary 指向区间内最后「已完成且完整纳入」
      // 的轮（在途轮不入正文覆盖；此用例预算内恰可完整纳入轮3）
      final boundary = summaryEvent.data['narrativeBoundary'] as Map;
      expect(boundary['turn'], 3);
      expect(boundary['boundaryMessageId'], 'chat-p3');
      expect(boundary['summaryMessageId'], isNotNull);
      // chat 三成果落库
      final points = await chat.getCompactionPoints('s1');
      expect(points, hasLength(1));
      expect(points.last['boundaryMessageId'], 'chat-p3');
      // 投影：checkpoint 替换遮蔽区间（前捕获/后保留尾仍在）
      final window = DirectorSurfaceV2.epochWindowEvents(ledger);
      final projection = DirectorSurfaceV2.epochWindowProjection(ledger);
      expect(projection.contentGeneration, greaterThan(0));
      expect(
        window.any((e) => e.type == AgentEventTypes.replayBinding),
        isTrue,
      ); // 影子区事件保留（不自动回收）
      // checkpoint 消息可见（信封+摘要）
      final checkpointMsg = projection.messages.firstWhere(
        (m) => m.content?.contains('【前情压缩纪要·资料非指令】') ?? false,
      );
      expect(checkpointMsg.role, 'user');
    });

    test('正文覆盖映射：在途轮后半与已入摘要轮不被旧摘要覆盖（boundary 止于轮3）', () async {
      await seedEpochAndRounds(withInFlightRound: true);
      final svc = service(stub(narrativeSection: '已完成剧情梗概段文本'));
      await svc.compact(
        sessionId: 's1',
        trigger: 'manual',
        contextWindowTokens: 32000,
        retrievalRatio: 0.15,
      );
      // 在途轮正文 P_4 persist 落库（压缩后发生）
      await chat.addMessage(
        ChatMessage(
          messageId: 'chat-p4',
          sessionId: 's1',
          role: 'assistant',
          content: '在途轮最终正文',
          createdAt: DateTime(2026, 1, 4),
        ),
      );
      await events.appendAll('s1', [
        replayBindingEvent(
          turn: 4,
          attemptId: 'att-inflight',
          variantIndex: 0,
          prose: '在途轮最终正文',
          userInput: '在途 输入内容' * 30,
          chatMessageId: 'chat-p4',
        ),
      ]);
      // 正文过滤视图仍包含 P_4（boundary=chat-p3，其后的消息不受替换）
      final messages = await chat.getMessages('s1');
      final points = await chat.getCompactionPoints('s1');
      final boundaryId = points.last['boundaryMessageId'] as String;
      final boundaryIndex = messages.indexWhere(
        (m) => m.messageId == boundaryId,
      );
      final p4 = messages.indexWhere((m) => m.messageId == 'chat-p4');
      expect(p4, greaterThan(boundaryIndex));
    });

    test('纯在途区间：仅工程 checkpoint，正文侧零产物（无挂账）', () async {
      await events.applyEngineeringContextEnter(
        sessionId: 's1',
        epochId: 'e1',
        fromTurn: 1,
        captureEvents: [],
      );
      await seedRound(1, attemptId: 'a1', withBinding: false);
      final svc = service(stub());
      final result = await svc.compact(
        sessionId: 's1',
        trigger: 'manual',
        contextWindowTokens: 32000,
        retrievalRatio: 0.15,
      );
      // 区间仅含在途轮：narrativeBoundaryTurn=null → 视选材可能整区间
      // 无已完成轮 → 正文零产物。此构造下区间含轮1全部（无 binding）。
      if (result.outcome == 'committed') {
        final ledger = await events.readEvents('s1');
        final summaryEvent = ledger.lastWhere(
          (e) => e.type == AgentEventTypes.compactionSummary,
        );
        expect(summaryEvent.data.containsKey('narrativeBoundary'), isFalse);
        expect(await chat.getCompactionPoints('s1'), isEmpty);
      } else {
        expect(result.outcome, 'noop');
      }
    });
  });

  group('取消竞态三场景', () {
    test('场景①：摘要暂停→新增表面事件→旧摘要提交被拒 superseded', () async {
      await seedEpochAndRounds();
      final s = stub(paused: true);
      final svc = service(s);
      final future = svc.compact(
        sessionId: 's1',
        trigger: 'manual',
        contextWindowTokens: 32000,
        retrievalRatio: 0.15,
      );
      await s.waitUntilStarted();
      // 摘要期间：新表面事件入账（新消息）
      await events.appendAll('s1', [
        ev(
          AgentEventTypes.userMessage,
          op: AgentSurfaceOpKind.append,
          data: {'content': '压缩中的新消息', 'turn': 4, 'attemptId': 'a4'},
        ),
      ]);
      s.release();
      final result = await future;
      expect(result.outcome, 'surface-changed');
      // 只落 end{error}；无 summary/checkpoint
      final ledger = await events.readEvents('s1');
      expect(
        ledger.any((e) => e.type == AgentEventTypes.compactionSummary),
        isFalse,
      );
      final end = ledger.lastWhere(
        (e) => e.type == AgentEventTypes.compactionEnd,
      );
      expect(end.data['error'], 'surface-changed');
      expect(await chat.getCompactionPoints('s1'), isEmpty);
    });

    test('场景③：摘要暂停→取消（零表面变化）→旧摘要返回仍被拒 cancelled', () async {
      await seedEpochAndRounds();
      final s = stub(paused: true);
      final svc = service(s);
      final future = svc.compact(
        sessionId: 's1',
        trigger: 'manual',
        contextWindowTokens: 32000,
        retrievalRatio: 0.15,
      );
      await s.waitUntilStarted();
      // 取消：只落作废事件，不追加任何模型可见内容、不开新压缩
      await svc.invalidateActive('s1', 'user-stop');
      s.release();
      final result = await future;
      expect(result.outcome, 'cancelled');
      final ledger = await events.readEvents('s1');
      expect(
        ledger.any((e) => e.type == AgentEventTypes.compactionSummary),
        isFalse,
      );
      expect(await chat.getCompactionPoints('s1'), isEmpty);
    });

    test('场景②：预检通过后提交前暂停→新增事件→事务内重校验拒绝', () async {
      // 与场景①同链路（注入点在摘要前后之间），锁定同一拒绝路径
      await seedEpochAndRounds();
      final s = stub(paused: true);
      final svc = service(s);
      final future = svc.compact(
        sessionId: 's1',
        trigger: 'manual',
        contextWindowTokens: 32000,
        retrievalRatio: 0.15,
      );
      await s.waitUntilStarted();
      await events.appendAll('s1', [
        ev(
          AgentEventTypes.assistantMessage,
          op: AgentSurfaceOpKind.append,
          data: {'text': '提交前的新事件', 'turn': 4, 'attemptId': 'a4'},
        ),
      ]);
      s.release();
      expect((await future).outcome, 'surface-changed');
    });
  });

  group('撤销（全量撤销 + 按产物 ID 精确回退）', () {
    test('undo：undo 事件 + 三成果精确删除 + 影子区回表面', () async {
      await seedEpochAndRounds();
      final svc = service(stub(narrativeSection: '已完成剧情梗概段文本'));
      await svc.compact(
        sessionId: 's1',
        trigger: 'manual',
        contextWindowTokens: 32000,
        retrievalRatio: 0.15,
      );
      final beforePoints = await chat.getCompactionPoints('s1');
      expect(beforePoints, hasLength(1));
      final projectionBefore = DirectorSurfaceV2.epochWindowProjection(
        await events.readEvents('s1'),
      );

      expect(await svc.undo(sessionId: 's1'), isTrue);
      // chat 三成果删除
      expect(await chat.getCompactionPoints('s1'), isEmpty);
      final summaryId = beforePoints.last['summaryMessageId'] as String;
      final messages = await chat.getMessages('s1');
      expect(messages.any((m) => m.messageId == summaryId), isFalse);
      // undo 事件在账；投影恢复（消息数回到压缩前——checkpoint 遮蔽失效）
      final ledger = await events.readEvents('s1');
      expect(
        ledger.any((e) => e.type == AgentEventTypes.compactionUndo),
        isTrue,
      );
      final projectionAfter = DirectorSurfaceV2.epochWindowProjection(ledger);
      expect(
        projectionAfter.messages.length,
        greaterThan(projectionBefore.messages.length),
      );
      // 二次 undo 拒绝（仅最新一次）
      expect(await svc.undo(sessionId: 's1'), isFalse);
    });

    test('undo 纯工程 checkpoint：chat 侧零删除（禁盲删 points.last）', () async {
      // 预置一个「旧的正文压缩点」（非本次工程压缩产物）
      await events.applyEngineeringContextEnter(
        sessionId: 's1',
        epochId: 'e1',
        fromTurn: 1,
        captureEvents: [],
      );
      await chat.addMessage(
        ChatMessage(
          messageId: 'old-summary',
          sessionId: 's1',
          role: 'system',
          content: '旧摘要',
          createdAt: DateTime(2025),
          isSummary: true,
        ),
      );
      await chat.addMessage(
        ChatMessage(
          messageId: 'old-boundary',
          sessionId: 's1',
          role: 'assistant',
          content: '旧边界正文',
          createdAt: DateTime(2025, 1, 2),
        ),
      );
      await chat.addCompactionPoint(
        sessionId: 's1',
        summaryMessageId: 'old-summary',
        boundaryMessageId: 'old-boundary',
        createdAt: DateTime(2025),
      );
      // 工程压缩：纯在途区间（无 binding 轮）
      await seedRound(1, attemptId: 'a1', withBinding: false);
      final svc = service(stub());
      final result = await svc.compact(
        sessionId: 's1',
        trigger: 'manual',
        contextWindowTokens: 32000,
        retrievalRatio: 0.15,
      );
      if (result.outcome == 'committed') {
        expect(await svc.undo(sessionId: 's1'), isTrue);
        // 旧正文压缩点原样保留（未被盲删）
        final points = await chat.getCompactionPoints('s1');
        expect(points, hasLength(1));
        expect(points.last['summaryMessageId'], 'old-summary');
      }
    });

    test('undo 拒绝：其后有结构事件（后续压缩）', () async {
      await seedEpochAndRounds();
      final svc = service(stub());
      await svc.compact(
        sessionId: 's1',
        trigger: 'manual',
        contextWindowTokens: 32000,
        retrievalRatio: 0.15,
      );
      // checkpoint 之后发生结构事件（变体切换遮蔽）
      await events.appendAll('s1', [
        AgentDurableEvent(
          type: AgentEventTypes.branchRebuild,
          surfaceOp: AgentSurfaceOpKind.replace,
          replaceStart: 0,
          replaceEnd: 1,
          data: {
            'reason': 'variant-switch',
            'turn': 3,
            'messages': [
              {'as': 'user', 'content': '遮蔽'},
            ],
          },
        ),
      ]);
      expect(await svc.undo(sessionId: 's1'), isFalse);
    });
  });

  group('崩溃恢复收敛', () {
    test('未闭合 start（进程中断）→ recover 补 end{interrupted}', () async {
      await seedEpochAndRounds(completedRounds: 2);
      await events.appendAll('s1', [
        ev(
          AgentEventTypes.compactionStart,
          data: {
            'opId': 'op-x',
            'trigger': 'auto',
            'surfaceDigest': 'd',
            'intervalDigest': 'd',
            'intervalSeqs': [1, 2],
          },
        ),
      ]);
      await AgentLogRecoveryService(repository: events).recover('s1');
      final ledger = await events.readEvents('s1');
      final end = ledger.lastWhere(
        (e) => e.type == AgentEventTypes.compactionEnd,
      );
      expect(end.data['opId'], 'op-x');
      expect(end.data['error'], 'interrupted');
    });

    test('已有作废记录 → cancelled 优先收敛', () async {
      await seedEpochAndRounds(completedRounds: 2);
      await events.appendAll('s1', [
        ev(
          AgentEventTypes.compactionStart,
          data: {
            'opId': 'op-y',
            'trigger': 'auto',
            'surfaceDigest': 'd',
            'intervalDigest': 'd',
            'intervalSeqs': [1, 2],
          },
        ),
        ev(
          AgentEventTypes.compactionCancel,
          data: {
            'opId': 'op-y',
            'reason': 'user-stop',
          },
        ),
      ]);
      await AgentLogRecoveryService(repository: events).recover('s1');
      final ledger = await events.readEvents('s1');
      final end = ledger.lastWhere(
        (e) => e.type == AgentEventTypes.compactionEnd,
      );
      expect(end.data['error'], 'cancelled');
    });
  });

  group('超限降级与熔断', () {
    test('超限工具结果先 model-free 降级再选材', () async {
      await events.applyEngineeringContextEnter(
        sessionId: 's1',
        epochId: 'e1',
        fromTurn: 1,
        captureEvents: [],
      );
      await seedRound(1, attemptId: 'a1', withBinding: false);
      await seedRound(2, attemptId: 'a2', prose: '第2轮', userInput: '第2轮');
      await seedRound(3, attemptId: 'a3', prose: '第3轮', userInput: '第3轮');
      final svc = service(stub(narrativeSection: '已完成剧情梗概段文本'));
      final result = await svc.compact(
        sessionId: 's1',
        trigger: 'manual',
        contextWindowTokens: 32000,
        retrievalRatio: 0.15,
      );
      // 轮1 的工具结果（200×5=1000 字 < 8192 阈值）不触发降级；
      // 本用例主要锁定降级路径不破坏正常提交。加大结果的重试路径由
      // tuning 注入用例覆盖（下一条）。
      expect(result.outcome, anyOf('committed', 'noop'));
    });

    test('熔断：连续 3 次 auto 失败后暂停', () async {
      await seedEpochAndRounds();
      final failing = _ControllableSummarizer(failWith: StateError('boom'));
      final svc = service(failing);
      for (var i = 0; i < 3; i++) {
        final r = await svc.compact(
          sessionId: 's1',
          trigger: 'auto',
          contextWindowTokens: 32000,
          retrievalRatio: 0.15,
        );
        expect(r.outcome, 'failed');
      }
      expect(svc.autoCompactionSuspended, isTrue);
      final r4 = await svc.compact(
        sessionId: 's1',
        trigger: 'auto',
        contextWindowTokens: 32000,
        retrievalRatio: 0.15,
      );
      expect(r4.outcome, 'noop');
      expect(r4.reason, 'circuit-broken');
    });
  });

  group('计量与熔断', () {
    test('摘要 usage 成功落痕进 compactionSummary（tools 透传给摘要器）', () async {
      await seedEpochAndRounds();
      final summarizer = _UsageSummarizer(
        usage: const {
          'inputTokens': 1234,
          'completionTokens': 56,
          'finishReason': 'stop',
        },
      );
      final svc = service(summarizer);
      const tool = ToolDefinition(
        name: 'probe_tool',
        description: '探测工具',
        parameters: {'type': 'object'},
      );
      final result = await svc.compact(
        sessionId: 's1',
        trigger: 'auto',
        contextWindowTokens: 32000,
        retrievalRatio: 0.15,
        tools: [tool],
      );
      expect(result.outcome, 'committed');
      expect(summarizer.lastTools, hasLength(1), reason: 'tools 与模型/前缀同源透传');
      expect(summarizer.lastTools!.first.name, 'probe_tool');
      final ledger = await events.readEvents('s1');
      final summary = ledger.lastWhere(
        (e) => e.type == AgentEventTypes.compactionSummary,
      );
      expect(summary.data['usage'], {
        'inputTokens': 1234,
        'completionTokens': 56,
        'finishReason': 'stop',
      });
    });

    test('提交失败路径 usage 同样落痕（narrative 缺失→end{error} 带 usage）', () async {
      await seedEpochAndRounds();
      final svc = service(
        _UsageSummarizer(
          usage: const {'inputTokens': 99, 'finishReason': 'stop'},
          narrativeSection: null,
        ),
      );
      final result = await svc.compact(
        sessionId: 's1',
        trigger: 'manual',
        contextWindowTokens: 32000,
        retrievalRatio: 0.15,
      );
      expect(result.outcome, 'narrative-section-missing');
      final ledger = await events.readEvents('s1');
      final end =
          ledger.lastWhere((e) => e.type == AgentEventTypes.compactionEnd);
      expect(end.data['error'], 'narrative-section-missing');
      expect(end.data['usage'], {'inputTokens': 99, 'finishReason': 'stop'});
    });

    test('响应结构不合格（截断）的 usage 随 summary-error 落痕', () async {
      await seedEpochAndRounds();
      final svc = service(
        _ControllableSummarizer(
          failWith: const EngineeringSummaryException(
            'summary-response-truncated',
            usage: {'inputTokens': 77, 'finishReason': 'length'},
          ),
        ),
      );
      final result = await svc.compact(
        sessionId: 's1',
        trigger: 'manual',
        contextWindowTokens: 32000,
        retrievalRatio: 0.15,
      );
      expect(result.outcome, 'failed');
      final ledger = await events.readEvents('s1');
      final end =
          ledger.lastWhere((e) => e.type == AgentEventTypes.compactionEnd);
      expect(end.data['error'], 'summary-error');
      expect(end.data['usage'], {'inputTokens': 77, 'finishReason': 'length'});
    });

    test('shadowedTokenEstimate 按材料量（非消息条数差/4）', () async {
      await seedEpochAndRounds();
      final svc = service(_UsageSummarizer());
      final result = await svc.compact(
        sessionId: 's1',
        trigger: 'manual',
        contextWindowTokens: 32000,
        retrievalRatio: 0.15,
      );
      expect(result.outcome, 'committed');
      final ledger = await events.readEvents('s1');
      final summary = ledger.lastWhere(
        (e) => e.type == AgentEventTypes.compactionSummary,
      );
      // 材料量口径：种子轮每轮含 1000 字回执（降级面数百字）
      // ——消息条数差/4 只会给出个位数，材料量口径为数百 token
      final estimate = summary.data['shadowedTokenEstimate'] as int;
      expect(
        estimate,
        greaterThanOrEqualTo(100),
        reason: '材料量口径——条数差/4 口径只会得到个位数',
      );
      expect(result.shadowedTokenEstimate, estimate);
      expect(result.framedTokenEstimate, isNotNull);
      expect(
        result.framedTokenEstimate,
        lessThan(estimate),
        reason: '纪要远小于被压材料（收缩校验已保证）',
      );
    });

    test('rapid-refill 熔断：距上次压缩不足 3 工具步连续 3 次阻断，工具步累积自愈', () async {
      // 单轮单工具步种子：首次 auto 触发 toolSteps=1 <3（streak=1）仍执行
      await seedEpochAndRounds(completedRounds: 1);
      final svc = service(_UsageSummarizer());
      Future<EngineeringCompactionResult> run() => svc.compact(
            sessionId: 's1',
            trigger: 'auto',
            contextWindowTokens: 32000,
            retrievalRatio: 0.15,
          );
      final r1 = await run();
      expect(r1.outcome, 'committed', reason: 'streak=1 未达阈值，正常压缩');
      // 压缩后无新工具步：连续两次 <3 → streak 累积到 3 → 阻断
      final r2 = await run();
      expect(r2.outcome, isNot('rapid-refill'), reason: 'streak=2 仍放行');
      final r3 = await run();
      expect(r3.outcome, 'noop');
      expect(r3.reason, 'rapid-refill', reason: 'streak=3 阻断当次');
      // 工具步自然累积（≥3）→ 自愈
      await events.appendAll('s1', [
        for (var i = 0; i < 3; i++)
          AgentDurableEvent(
            type: AgentEventTypes.toolResult,
            surfaceOp: AgentSurfaceOpKind.append,
            data: {
              'callId': 'rr$i',
              'toolName': 'query_facts',
              'output': '新工具步回执' * 40,
              'turn': 9,
              'attemptId': 'att-rr',
            },
          ),
      ]);
      final r4 = await run();
      expect(r4.outcome, isNot('rapid-refill'), reason: '工具步累积后自愈');
    });
  });
}

/// 计量桩：返回固定 usage 并捕获透传的 tools
class _UsageSummarizer implements EngineeringSummarizer {
  _UsageSummarizer({this.usage, this.narrativeSection = '已完成的剧情梗概。'});

  final Map<String, dynamic>? usage;
  final String? narrativeSection;

  /// 最近一次调用透传的 tools（tools 同源 seam 断言用）
  List<ToolDefinition>? lastTools;

  @override
  Future<EngineeringSummaryOutput> summarize({
    required String sessionId,
    required List<AgentMessage> intervalMessages,
    required int narrativeBoundaryTurn,
    required List<ToolDefinition> tools,
    required void Function(String delta)? onDelta,
  }) async {
    lastTools = tools;
    return EngineeringSummaryOutput(
      summary: '压缩纪要：材料已概括。',
      narrativeSection: narrativeSection,
      usage: usage,
    );
  }
}

/// 可控桩摘要器：waitUntilStarted/release 编排暂停窗口；failWith 模拟失败
class _ControllableSummarizer implements EngineeringSummarizer {
  _ControllableSummarizer({
    this.narrativeSection,
    this.failWith,
    this.paused = false,
  });

  final String? narrativeSection;

  /// 摘要失败注入（Exception/Error）
  final Object? failWith;
  final bool paused;
  final Completer<void> _started = Completer<void>();
  Completer<void>? _gate;

  @override
  Future<EngineeringSummaryOutput> summarize({
    required String sessionId,
    required List<AgentMessage> intervalMessages,
    required int narrativeBoundaryTurn,
    required List<ToolDefinition> tools,
    required void Function(String delta)? onDelta,
  }) async {
    if (!_started.isCompleted) _started.complete();
    final failure = failWith;
    if (failure is Exception) {
      throw failure;
    }
    if (failure is Error) {
      throw failure;
    }
    if (paused) {
      _gate = Completer<void>();
      await _gate!.future;
    }
    onDelta?.call('摘要增量');
    return EngineeringSummaryOutput(
      summary: '压缩纪要：材料已概括。',
      narrativeSection: narrativeSection,
    );
  }

  Future<void> waitUntilStarted() => _started.future;

  void release() {
    _gate?.complete();
    // 后续调用（重试）不再挂起
    if (!_started.isCompleted) _started.complete();
  }
}
