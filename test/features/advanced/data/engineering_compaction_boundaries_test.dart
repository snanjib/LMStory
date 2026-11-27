import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/advanced/data/engineering_compaction_service.dart';
import 'package:lmstory/features/advanced/data/repositories/agent_event_log_repository.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/services/compaction_planning.dart';
import 'package:lmstory/features/advanced/domain/services/director_surface_v2.dart';
import 'package:lmstory/features/advanced/domain/services/retrieval_evidence.dart';
import 'package:lmstory/features/advanced/domain/services/surface_representations.dart';
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
    bool withEvidence = false,
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
          // 证据负载（压缩承接链用）：query_facts 成功快照
          if (withEvidence)
            ...retrievalEvidencePayload(
              status: 'success',
              queryScope: const {'name': '沈青梧'},
              entities: [
                EvidenceEntityRef(
                  id: 'e-x',
                  primaryName: '沈青梧',
                  updatedAtMs: 1000,
                  contentDigest: entityRevisionDigest(
                    updatedAtMs: 1000,
                    attributes: const [('状态', '熄灭')],
                  ),
                ),
              ],
            ),
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
    int? evidenceTurn,
  }) async {
    await events.applyEngineeringContextEnter(
      sessionId: 's1',
      epochId: 'e1',
      fromTurn: 1,
      captureEvents: [],
    );
    for (var t = 1; t <= completedRounds; t++) {
      await seedRound(
        t,
        attemptId: 'att$t',
        prose: '第$t轮',
        userInput: '第$t轮',
        withEvidence: t == evidenceTurn,
      );
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

  test('保尾切点不能拆开同一assistant的双工具结果', () {
    final batch = <AgentDurableEvent>[
      AgentDurableEvent(
        seq: 1,
        type: AgentEventTypes.userMessage,
        surfaceOp: AgentSurfaceOpKind.append,
        data: {'content': 'u' * 400, 'turn': 1},
      ),
      AgentDurableEvent(
        seq: 2,
        type: AgentEventTypes.assistantMessage,
        surfaceOp: AgentSurfaceOpKind.append,
        data: {
          'text': 'work',
          'turn': 1,
          'toolCalls': [
            {
              'id': 'a',
              'name': 'query_facts',
              'args': {'name': 'A'},
            },
            {
              'id': 'b',
              'name': 'query_facts',
              'args': {'name': 'B'},
            },
          ],
        },
      ),
      AgentDurableEvent(
        seq: 3,
        type: AgentEventTypes.toolResult,
        surfaceOp: AgentSurfaceOpKind.append,
        data: {'callId': 'a', 'output': 'a' * 400, 'turn': 1},
      ),
      AgentDurableEvent(
        seq: 4,
        type: AgentEventTypes.toolResult,
        surfaceOp: AgentSurfaceOpKind.append,
        data: {'callId': 'b', 'output': 'b' * 400, 'turn': 1},
      ),
      AgentDurableEvent(
        seq: 5,
        type: AgentEventTypes.assistantMessage,
        surfaceOp: AgentSurfaceOpKind.append,
        data: {'text': 'final' * 80, 'turn': 1},
      ),
      AgentDurableEvent(
        seq: 6,
        type: AgentEventTypes.replayBinding,
        data: {'turn': 1, 'chatMessageId': 'p1'},
      ),
    ];
    final fold = deriveAgentSurfaceSpans(batch);
    final plan = selectCompactionInterval(
      windowEvents: batch,
      spans: fold.spans,
      projectionMessages: fold.projection.messages,
      contextWindowTokens: 1000,
      tuning: const EngineeringCompactionTuning(
        retainMinTokens: 0,
        retainMaxTokens: 10000,
        retainMaxWindowRatio: 1,
      ),
    );
    expect(plan, isNotNull);
    final after = deriveAgentSurface([
      ...batch,
      AgentDurableEvent(
        seq: 7,
        type: AgentEventTypes.userMessage,
        surfaceOp: AgentSurfaceOpKind.replace,
        replaceStart: plan!.projectionStart,
        replaceEnd: plan.projectionEnd,
        data: {'content': 'checkpoint'},
      ),
    ]);
    expect(
      validateSurfaceIntegrity(after.messages),
      isNull,
      reason: '工具结果b不能在其assistant调用声明被压掉后留在保尾区',
    );
  });

  test('已完成轮的末尾正文不在摘要区间时不能作为叙事覆盖边界', () {
    final batch = <AgentDurableEvent>[
      AgentDurableEvent(
        seq: 1,
        type: AgentEventTypes.userMessage,
        surfaceOp: AgentSurfaceOpKind.append,
        data: {'content': 'u' * 400, 'turn': 1},
      ),
      AgentDurableEvent(
        seq: 2,
        type: AgentEventTypes.assistantMessage,
        surfaceOp: AgentSurfaceOpKind.append,
        data: {'text': 'middle' * 134, 'turn': 1},
      ),
      AgentDurableEvent(
        seq: 3,
        type: AgentEventTypes.assistantMessage,
        surfaceOp: AgentSurfaceOpKind.append,
        data: {'text': 'final' * 80, 'turn': 1},
      ),
      AgentDurableEvent(
        seq: 4,
        type: AgentEventTypes.replayBinding,
        data: {'turn': 1, 'chatMessageId': 'p1'},
      ),
    ];
    final fold = deriveAgentSurfaceSpans(batch);
    final plan = selectCompactionInterval(
      windowEvents: batch,
      spans: fold.spans,
      projectionMessages: fold.projection.messages,
      contextWindowTokens: 1000,
      tuning: const EngineeringCompactionTuning(
        retainMinTokens: 0,
        retainMaxTokens: 10000,
        retainMaxWindowRatio: 1,
      ),
    );
    expect(plan, isNotNull);
    expect(plan!.projectionEnd, lessThan(3));
    expect(
      plan.narrativeBoundaryTurn,
      isNull,
      reason: '第1轮虽然在库中已完成，但其最终正文未被本次摘要看到',
    );
  });

  test('缺少已完成剧情段时不得将整份含未定稿计划的工程纪要写入叙事资产', () async {
    await seedEpochAndRounds(withInFlightRound: true);
    final svc = EngineeringCompactionService(
      database: db,
      eventRepository: events,
      chatRepository: chat,
      experienceRepository: experience,
      summarizer: _RawOnlySummarizer(),
      tuning: smallTuning,
    );
    await svc.compact(
      sessionId: 's1',
      trigger: 'manual',
      contextWindowTokens: 32000,
      retrievalRatio: 0.15,
    );
    final stored = await chat.getMessages('s1');
    expect(
      stored
          .where((m) => m.isSummary)
          .any((m) => m.content?.contains('未定稿计划') ?? false),
      isFalse,
      reason: '解析失败不能回退整份含在途工作内容的工程摘要',
    );
  });
  test('旧压缩收尾不得抹去新压缩操作的取消登记', () async {
    await seedEpochAndRounds(withInFlightRound: true);
    final dual = _TwoSummaryCalls();
    final svc = EngineeringCompactionService(
      database: db,
      eventRepository: events,
      chatRepository: chat,
      experienceRepository: experience,
      summarizer: dual,
      tuning: smallTuning,
    );
    final first = svc.compact(
      sessionId: 's1',
      trigger: 'manual',
      contextWindowTokens: 32000,
      retrievalRatio: 0.15,
    );
    await dual.started[0].future;
    await svc.invalidateActive('s1', 'cancel-first');
    final second = svc.compact(
      sessionId: 's1',
      trigger: 'manual',
      contextWindowTokens: 32000,
      retrievalRatio: 0.15,
    );
    await dual.started[1].future;
    dual.gates[0].complete();
    final oldResult = await first;
    expect(oldResult.outcome, isNot('committed'));
    await svc.invalidateActive('s1', 'cancel-second');
    dual.gates[1].complete();
    final newResult = await second;
    expect(
      newResult.outcome,
      isNot('committed'),
      reason: '旧操作结束后，新操作的登记仍须存活，使cancel-second能够写作废记录',
    );
  });

  test('叙事段缺失：提交拒绝且零产物（end{error}，无三成果/无checkpoint）', () async {
    await seedEpochAndRounds();
    final svc = EngineeringCompactionService(
      database: db,
      eventRepository: events,
      chatRepository: chat,
      experienceRepository: experience,
      summarizer: _RawOnlySummarizer(),
      tuning: smallTuning,
    );
    final result = await svc.compact(
      sessionId: 's1',
      trigger: 'manual',
      contextWindowTokens: 32000,
      retrievalRatio: 0.15,
    );
    expect(result.outcome, 'narrative-section-missing');
    final ledger = await events.readEvents('s1');
    expect(
      ledger.any((e) => e.type == AgentEventTypes.compactionSummary),
      isFalse,
    );
    final end =
        ledger.lastWhere((e) => e.type == AgentEventTypes.compactionEnd);
    expect(end.data['error'], 'narrative-section-missing');
    expect(await chat.getCompactionPoints('s1'), isEmpty);
    final projection = DirectorSurfaceV2.epochWindowProjection(ledger);
    expect(
      projection.messages.any(
        (m) => m.content?.contains(kEngineeringCheckpointEnvelope) ?? false,
      ),
      isFalse,
    );
  });

  test('作废落账失败：进程内拒绝标记仍阻止提交（可靠取消）', () async {
    await seedEpochAndRounds();
    final failingCancelRepo = _FailCancelAppendRepository(database: db);
    final paused = _PausedSummarizer();
    final svc = EngineeringCompactionService(
      database: db,
      eventRepository: failingCancelRepo,
      chatRepository: chat,
      experienceRepository: experience,
      summarizer: paused,
      tuning: smallTuning,
    );
    final future = svc.compact(
      sessionId: 's1',
      trigger: 'manual',
      contextWindowTokens: 32000,
      retrievalRatio: 0.15,
    );
    await paused.started.future;
    final invalidated = await svc.invalidateActive('s1', 'user-stop');
    expect(invalidated, isFalse, reason: '作废事件写入失败须如实返回');
    paused.release();
    final result = await future;
    expect(result.outcome, 'cancelled', reason: '账面作废缺失时进程内标记仍须拒绝');
    final ledger = await failingCancelRepo.readEvents('s1');
    expect(
      ledger.any((e) => e.type == AgentEventTypes.compactionSummary),
      isFalse,
    );
    expect(await chat.getCompactionPoints('s1'), isEmpty);
  });

  test('合法双工具组整体纳入区间：压缩提交且配对完整', () async {
    await events.applyEngineeringContextEnter(
      sessionId: 's1',
      epochId: 'e1',
      fromTurn: 1,
      captureEvents: [],
    );
    // 轮1：双工具组（完整）+正文；轮2：大用户输入+正文（预算把切点推到轮2起点）
    await events.appendAll('s1', [
      _appendEv(AgentEventTypes.userMessage, {
        'content': 'u' * 400,
        'turn': 1,
        'attemptId': 'a1',
      }),
      _appendEv(AgentEventTypes.assistantMessage, {
        'text': 'w' * 20,
        'toolCalls': [
          <String, dynamic>{
            'id': 'a',
            'name': 'query_facts',
            'args': <String, dynamic>{},
          },
          <String, dynamic>{
            'id': 'b',
            'name': 'query_facts',
            'args': <String, dynamic>{},
          },
        ],
        'turn': 1,
        'attemptId': 'a1',
      }),
      _appendEv(AgentEventTypes.toolResult, {
        'callId': 'a',
        'output': 'r' * 100,
        'turn': 1,
        'attemptId': 'a1',
      }),
      _appendEv(AgentEventTypes.toolResult, {
        'callId': 'b',
        'output': 'r' * 100,
        'turn': 1,
        'attemptId': 'a1',
      }),
      _appendEv(AgentEventTypes.assistantMessage, {
        'text': 'p' * 200,
        'turn': 1,
        'attemptId': 'a1',
      }),
      replayBindingEvent(
        turn: 1,
        attemptId: 'a1',
        variantIndex: 0,
        prose: 'p' * 200,
        userInput: 'u' * 400,
        chatMessageId: 'chat-p1',
      ),
      _appendEv(AgentEventTypes.userMessage, {
        'content': 'u' * 600,
        'turn': 2,
        'attemptId': 'a2',
      }),
      _appendEv(AgentEventTypes.assistantMessage, {
        'text': 'p' * 200,
        'turn': 2,
        'attemptId': 'a2',
      }),
      replayBindingEvent(
        turn: 2,
        attemptId: 'a2',
        variantIndex: 0,
        prose: 'p' * 200,
        userInput: 'u' * 600,
        chatMessageId: 'chat-p2',
      ),
    ]);
    await chat.addMessage(
      ChatMessage(
        messageId: 'chat-p1',
        sessionId: 's1',
        role: 'assistant',
        content: 'p' * 200,
        createdAt: DateTime(2026),
      ),
    );
    final svc = EngineeringCompactionService(
      database: db,
      eventRepository: events,
      chatRepository: chat,
      experienceRepository: experience,
      summarizer: _NarrativeSummarizer(),
      tuning: smallTuning,
    );
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
    // 双工具组（声明+两结果）全部被遮蔽——组不可拆
    final shadowed = (summary.data['shadowedSeqs'] as List).cast<int>();
    expect(shadowed, containsAll([2, 3, 4, 5]), reason: '声明与两结果同组同入区间');
    // 提交后投影配对合法
    final projection = DirectorSurfaceV2.epochWindowProjection(ledger);
    expect(validateSurfaceIntegrity(projection.messages), isNull);
    expect(await chat.getCompactionPoints('s1'), hasLength(1));
  });

  test('压缩承接链成立：摘要引用证据编号→evidenceCarried 可检验→跨压缩复用', () async {
    await seedEpochAndRounds(evidenceTurn: 2);
    // 第 2 轮的检索回执带证据负载（真实存在的候选键=「2:c2」）
    final svc = EngineeringCompactionService(
      database: db,
      eventRepository: events,
      chatRepository: chat,
      experienceRepository: experience,
      summarizer: const _CitingSummarizer(citedCallIds: ['c2', 'c99']),
      tuning: smallTuning,
    );
    final result = await svc.compact(
      sessionId: 's1',
      trigger: 'manual',
      contextWindowTokens: 32000,
      retrievalRatio: 0.15,
    );
    expect(result.outcome, 'committed');

    final ledger = await events.readEvents('s1');
    final summaryEvent =
        ledger.lastWhere((e) => e.type == AgentEventTypes.compactionSummary);
    // 可检验解析：真实引用（c2）入列表；捏造编号（c99，无对应回执）不入
    expect(summaryEvent.data['evidenceCarried'], [
      {'turn': 2, 'callId': 'c2'},
    ]);

    // 跨压缩复用成立：被遮蔽证据按承接键获得 carried 资格，修订未变→覆盖
    final window = DirectorSurfaceV2.epochWindowEvents(ledger);
    final carriedKeys = <String>{
      for (final item in summaryEvent.data['evidenceCarried'] as List)
        if (item is Map) '${item['turn']}:${item['callId']}',
    };
    final coverage = checkEntityCoverage(
      keyEntities: {
        'e-x': (
          primaryName: '沈青梧',
          updatedAtMs: 1000,
          contentDigest: entityRevisionDigest(
            updatedAtMs: 1000,
            attributes: const [('状态', '熄灭')],
          ),
        ),
      },
      windowEvents: window,
      eligibility: EvidenceEligibilityInput(
        windowEvents: window,
        carriedEvidenceKeys: carriedKeys,
      ),
    );
    expect(coverage.missingEntities, isEmpty);
    expect(coverage.missingDueToRevision, isEmpty);
  });

  test('摘要未引用证据编号：evidenceCarried 空→被遮蔽证据按未核对（安全侧）', () async {
    await seedEpochAndRounds(evidenceTurn: 2);
    final svc = EngineeringCompactionService(
      database: db,
      eventRepository: events,
      chatRepository: chat,
      experienceRepository: experience,
      summarizer: const _CitingSummarizer(citedCallIds: []),
      tuning: smallTuning,
    );
    final result = await svc.compact(
      sessionId: 's1',
      trigger: 'manual',
      contextWindowTokens: 32000,
      retrievalRatio: 0.15,
    );
    expect(result.outcome, 'committed');

    final ledger = await events.readEvents('s1');
    final summaryEvent =
        ledger.lastWhere((e) => e.type == AgentEventTypes.compactionSummary);
    expect(summaryEvent.data['evidenceCarried'], isEmpty);

    final window = DirectorSurfaceV2.epochWindowEvents(ledger);
    final coverage = checkEntityCoverage(
      keyEntities: {
        'e-x': (
          primaryName: '沈青梧',
          updatedAtMs: 1000,
          contentDigest: entityRevisionDigest(
            updatedAtMs: 1000,
            attributes: const [('状态', '熄灭')],
          ),
        ),
      },
      windowEvents: window,
      eligibility: EvidenceEligibilityInput(windowEvents: window),
    );
    expect(coverage.missingEntities, contains('沈青梧'));
  });

  test('真实服务连续两次压缩：第二次遗漏承接键→资格失效；undo 恢复', () async {
    await seedEpochAndRounds(evidenceTurn: 2);
    EngineeringCompactionService buildService(EngineeringSummarizer s) =>
        EngineeringCompactionService(
          database: db,
          eventRepository: events,
          chatRepository: chat,
          experienceRepository: experience,
          summarizer: s,
          tuning: smallTuning,
        );
    Future<EngineeringCompactionResult> compactOnce(EngineeringSummarizer s) =>
        buildService(s).compact(
          sessionId: 's1',
          trigger: 'manual',
          contextWindowTokens: 32000,
          retrievalRatio: 0.15,
        );

    // 第一次压缩：摘要承接 2:c2（真实 service 事务提交）
    var result =
        await compactOnce(const _CitingSummarizer(citedCallIds: ['c2']));
    expect(result.outcome, 'committed');
    var ledger = await events.readEvents('s1');
    var carried = deriveCarriedEvidenceKeys(ledger);
    expect(carried, contains('2:c2'));

    // 增料两轮后第二次压缩：摘要不承接任何编号
    await seedRound(4, attemptId: 'att4', prose: '第4轮', userInput: '第4轮');
    await seedRound(5, attemptId: 'att5', prose: '第5轮', userInput: '第5轮');
    result = await compactOnce(const _CitingSummarizer(citedCallIds: []));
    expect(result.outcome, 'committed');
    ledger = await events.readEvents('s1');
    carried = deriveCarriedEvidenceKeys(ledger);
    expect(
      carried,
      isNot(contains('2:c2')),
      reason: '第二次 checkpoint 传递遮蔽了第一次，遗漏承接键必须失效',
    );

    // 资格消费（与 runner 同口径）：承接失效→被遮蔽证据不再算核对充分
    final window = DirectorSurfaceV2.epochWindowEvents(ledger);
    final coverage = checkEntityCoverage(
      keyEntities: {
        'e-x': (
          primaryName: '沈青梧',
          updatedAtMs: 1000,
          contentDigest: entityRevisionDigest(
            updatedAtMs: 1000,
            attributes: const [('状态', '熄灭')],
          ),
        ),
      },
      windowEvents: window,
      eligibility: EvidenceEligibilityInput(
        windowEvents: window,
        carriedEvidenceKeys: carried,
      ),
    );
    expect(coverage.missingEntities, contains('沈青梧'));

    // undo 撤销第二次压缩：第一次承接恢复生效
    final undoDone =
        await buildService(_NarrativeSummarizer()).undo(sessionId: 's1');
    expect(undoDone, isTrue);
    ledger = await events.readEvents('s1');
    carried = deriveCarriedEvidenceKeys(ledger);
    expect(carried, contains('2:c2'));
    final restoredWindow = DirectorSurfaceV2.epochWindowEvents(ledger);
    final restored = checkEntityCoverage(
      keyEntities: {
        'e-x': (
          primaryName: '沈青梧',
          updatedAtMs: 1000,
          contentDigest: entityRevisionDigest(
            updatedAtMs: 1000,
            attributes: const [('状态', '熄灭')],
          ),
        ),
      },
      windowEvents: restoredWindow,
      eligibility: EvidenceEligibilityInput(
        windowEvents: restoredWindow,
        carriedEvidenceKeys: carried,
      ),
    );
    expect(restored.missingEntities, isEmpty);
  });

  test('窗口末端 pending 调用：切点不得落在声明与结果之间', () {
    final batch = <AgentDurableEvent>[
      AgentDurableEvent(
        seq: 1,
        type: AgentEventTypes.userMessage,
        surfaceOp: AgentSurfaceOpKind.append,
        data: {'content': 'u' * 800, 'turn': 1},
      ),
      AgentDurableEvent(
        seq: 2,
        type: AgentEventTypes.assistantMessage,
        surfaceOp: AgentSurfaceOpKind.append,
        data: {
          'text': 'w' * 800,
          'toolCalls': [
            <String, dynamic>{
              'id': 'x',
              'name': 'query_facts',
              'args': <String, dynamic>{},
            },
            <String, dynamic>{
              'id': 'y',
              'name': 'query_facts',
              'args': <String, dynamic>{},
            },
          ],
          'turn': 1,
        },
      ),
    ];
    final fold = deriveAgentSurfaceSpans(batch);
    final plan = selectCompactionInterval(
      windowEvents: batch,
      spans: fold.spans,
      projectionMessages: fold.projection.messages,
      contextWindowTokens: 32000,
      tuning: const EngineeringCompactionTuning(
        retainMinTokens: 0,
        retainMaxTokens: 10000,
        retainMaxWindowRatio: 1,
      ),
    );
    expect(plan, isNotNull);
    // 区间止于 user 之后（声明留在保尾侧等结果），不得吞掉未闭合调用
    expect(plan!.projectionEnd, 1);
    expect(plan.narrativeBoundaryTurn, isNull);
  });
}

AgentDurableEvent _appendEv(String type, Map<String, dynamic> data) =>
    AgentDurableEvent(
      type: type,
      surfaceOp: AgentSurfaceOpKind.append,
      data: data,
    );

/// 作废事件写入即失败的仓库（模拟落账故障）
/// 引用证据编号的摘要桩（承接链测试）：citedCallIds 逐个拼进摘要文本
class _CitingSummarizer implements EngineeringSummarizer {
  const _CitingSummarizer({required this.citedCallIds});

  final List<String> citedCallIds;

  @override
  Future<EngineeringSummaryOutput> summarize({
    required String sessionId,
    required List<AgentMessage> intervalMessages,
    required int narrativeBoundaryTurn,
    required List<ToolDefinition> tools,
    required void Function(String delta)? onDelta,
  }) async {
    final citations = citedCallIds.map((c) => '（$c）').join();
    return EngineeringSummaryOutput(
      summary: '压缩纪要：检索结论已承接$citations。',
      narrativeSection: '已完成的剧情梗概。',
    );
  }
}

class _FailCancelAppendRepository extends AgentEventLogRepository {
  _FailCancelAppendRepository({required super.database});

  @override
  Future<List<int>> appendAll(
    String sessionId,
    List<AgentDurableEvent> events,
  ) async {
    if (events.any((e) => e.type == AgentEventTypes.compactionCancel)) {
      throw StateError('cancel append failed');
    }
    return super.appendAll(sessionId, events);
  }
}

/// 摘要暂停桩（started/release 编排）
class _PausedSummarizer implements EngineeringSummarizer {
  final Completer<void> started = Completer<void>();
  Completer<void>? _gate;

  @override
  Future<EngineeringSummaryOutput> summarize({
    required String sessionId,
    required List<AgentMessage> intervalMessages,
    required int narrativeBoundaryTurn,
    required List<ToolDefinition> tools,
    required void Function(String delta)? onDelta,
  }) async {
    if (!started.isCompleted) started.complete();
    _gate = Completer<void>();
    await _gate!.future;
    return const EngineeringSummaryOutput(
      summary: '简要工程纪要。',
      narrativeSection: '已完成的剧情。',
    );
  }

  void release() {
    _gate?.complete();
  }
}

/// 带叙事段的固定摘要桩
class _NarrativeSummarizer implements EngineeringSummarizer {
  @override
  Future<EngineeringSummaryOutput> summarize({
    required String sessionId,
    required List<AgentMessage> intervalMessages,
    required int narrativeBoundaryTurn,
    required List<ToolDefinition> tools,
    required void Function(String delta)? onDelta,
  }) async =>
      const EngineeringSummaryOutput(
        summary: '压缩纪要：材料已概括。',
        narrativeSection: '已完成的剧情梗概。',
      );
}

class _RawOnlySummarizer implements EngineeringSummarizer {
  @override
  Future<EngineeringSummaryOutput> summarize({
    required String sessionId,
    required List<AgentMessage> intervalMessages,
    required int narrativeBoundaryTurn,
    required List<ToolDefinition> tools,
    required void Function(String delta)? onDelta,
  }) async =>
      const EngineeringSummaryOutput(summary: '未定稿计划：下一步让角色甲死亡，这尚未在正文发生。');
}

class _TwoSummaryCalls implements EngineeringSummarizer {
  final started = [Completer<void>(), Completer<void>()];
  final gates = [Completer<void>(), Completer<void>()];
  int calls = 0;
  @override
  Future<EngineeringSummaryOutput> summarize({
    required String sessionId,
    required List<AgentMessage> intervalMessages,
    required int narrativeBoundaryTurn,
    required List<ToolDefinition> tools,
    required void Function(String delta)? onDelta,
  }) async {
    final index = calls++;
    started[index].complete();
    await gates[index].future;
    return const EngineeringSummaryOutput(
      summary: '简要工程纪要。',
      narrativeSection: '已完成的剧情。',
    );
  }
}
