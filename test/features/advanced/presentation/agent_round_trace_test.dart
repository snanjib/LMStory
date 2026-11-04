import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/features/advanced/data/repositories/agent_event_log_repository.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/presentation/controllers/agent_round_trace_controller.dart';
import 'package:lmstory/features/advanced/presentation/pages/agent_round_trace_entry_page.dart';
import 'package:lmstory/features/advanced/presentation/pages/agent_round_trace_page.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';

///  轮轨迹三层展示 + 入口存在性
/// 裁剪后轨迹页标注历史缺失
void main() {
  late AppDatabase db;
  late AgentEventLogRepository repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = AgentEventLogRepository(database: db);
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  tearDown(() async => db.close());

  /// 一轮完整事件序列：frozen → user → turn/begin → step → assistant(带工具
  /// 调用) → tool/result(带耗时) → step/end → turn/end
  Future<void> seedRoundOne() async {
    await repo.appendAll('s1', [
      AgentDurableEvent(
        type: AgentEventTypes.systemFrozen,
        surfaceOp: AgentSurfaceOpKind.append,
        data: const {'content': 'FROZEN', 'turn': 1},
      ),
      AgentDurableEvent(
        type: AgentEventTypes.userMessage,
        surfaceOp: AgentSurfaceOpKind.append,
        data: const {'content': '第一轮输入', 'source': 'user', 'turn': 1},
      ),
      AgentDurableEvent(
        type: AgentEventTypes.turnBegin,
        data: const {'maxSteps': 8, 'turn': 1},
      ),
      AgentDurableEvent(
        type: AgentEventTypes.stepBegin,
        data: const {'stepIndex': 0, 'turn': 1},
      ),
      AgentDurableEvent(
        type: AgentEventTypes.assistantMessage,
        surfaceOp: AgentSurfaceOpKind.append,
        data: const {
          'text': '我先查一下。',
          'toolCalls': [
            {
              'id': 'c1',
              'name': 'search_story',
              'args': {'query': '古碑'},
            },
          ],
          'stepIndex': 0,
          'turn': 1,
        },
      ),
      AgentDurableEvent(
        type: AgentEventTypes.toolResult,
        surfaceOp: AgentSurfaceOpKind.append,
        data: const {
          'callId': 'c1',
          'toolName': 'search_story',
          'output': '共 2 条命中',
          'isError': false,
          'title': '「古碑」· 2 处命中',
          'durationMs': 120,
          'turn': 1,
        },
      ),
      AgentDurableEvent(
        type: AgentEventTypes.stepEnd,
        data: const {
          'stepIndex': 0,
          'stopKind': 'toolCalls',
          'promptTokens': 100,
          'completionTokens': 20,
          'totalTokens': 120,
          'turn': 1,
        },
      ),
      AgentDurableEvent(
        type: AgentEventTypes.turnEnd,
        data: const {'reason': 'completedByTool', 'steps': 1, 'turn': 1},
      ),
    ]);
  }

  group('AgentRoundTraceController（三层重建）', () {
    test('①轮摘要：reason/steps/token', () async {
      await seedRoundOne();
      final controller = AgentRoundTraceController(
        repository: repo,
        sessionId: 's1',
        turnNumber: 1,
      );

      // 控制器构造即 load；等一个事件循环让 Future 完成
      await Future<void>.delayed(Duration.zero);
      final state = controller.state;

      expect(state.isLoading, isFalse);
      expect(state.error, isNull);
      expect(state.summary, isNotNull);
      expect(state.summary!.reason, 'completedByTool');
      expect(state.summary!.steps, 1);
      expect(state.summary!.promptTokens, 100);
      expect(state.summary!.completionTokens, 20);
    });

    test('②步时间线：工具名/耗时/成败随步归并', () async {
      await seedRoundOne();
      final controller = AgentRoundTraceController(
        repository: repo,
        sessionId: 's1',
        turnNumber: 1,
      );
      await Future<void>.delayed(Duration.zero);

      expect(controller.state.steps, hasLength(1));
      final step = controller.state.steps.single;
      expect(step.stepIndex, 0);
      expect(step.tools, hasLength(1));
      expect(step.tools.single.toolName, 'search_story');
      expect(step.tools.single.durationMs, 120);
      expect(step.tools.single.isError, isFalse);
      expect(step.stopKind, 'toolCalls');
    });

    test('③单步详情（点开才计算）：请求序列 + 响应 + 工具结果', () async {
      await seedRoundOne();
      final controller = AgentRoundTraceController(
        repository: repo,
        sessionId: 's1',
        turnNumber: 1,
      );
      await Future<void>.delayed(Duration.zero);

      await controller.loadStepDetail(0);
      final detail = controller.state.stepDetails[0];
      expect(detail, isNotNull);
      // 请求重建 = frozen system + 初始 user（本步 assistant 之前的事件投影）
      expect(detail!.requestMessages, hasLength(2));
      expect(detail.requestMessages.first.role, 'system');
      expect(detail.requestMessages.last.role, 'user');
      // 响应含 assistant 文本与工具调用标记
      expect(detail.responseText, contains('我先查一下。'));
      expect(detail.responseText, contains('search_story'));
      expect(detail.toolResults, hasLength(1));
      expect(detail.toolResults.single.output, '共 2 条命中');
    });

    test('无事件的轮：summary 为 null 但不报错', () async {
      final controller = AgentRoundTraceController(
        repository: repo,
        sessionId: 's1',
        turnNumber: 9,
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.isLoading, isFalse);
      expect(controller.state.summary, isNull);
      expect(controller.state.steps, isEmpty);
    });

    test('firstAvailableTurn 取日志最早带 turn 戳的轮号', () async {
      await seedRoundOne();
      final controller = AgentRoundTraceController(
        repository: repo,
        sessionId: 's1',
        turnNumber: 1,
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.firstAvailableTurn, 1);
    });

    test('日志起点晚于轮 1（已裁剪）→ firstAvailableTurn>1', () async {
      // 模拟滚动保留裁剪后的日志：只剩第 3、4 轮
      await repo.appendAll('s1', [
        AgentDurableEvent(
          type: AgentEventTypes.turnBegin,
          data: const {'turn': 3},
        ),
        AgentDurableEvent(
          type: AgentEventTypes.assistantMessage,
          data: const {'turn': 3, 'text': 't3'},
        ),
        AgentDurableEvent(
          type: AgentEventTypes.turnEnd,
          data: const {'turn': 3, 'reason': 'finish'},
        ),
      ]);
      final controller = AgentRoundTraceController(
        repository: repo,
        sessionId: 's1',
        turnNumber: 3,
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.firstAvailableTurn, 3);
    });
  });

  group('AgentRoundTracePage（widget 三层渲染）', () {
    testWidgets('轮摘要卡 + 步时间线 + 点开详情', (tester) async {
      await seedRoundOne();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
          ],
          child: TranslationProvider(
            child: const MaterialApp(
              home: AgentRoundTracePage(sessionId: 's1', turnNumber: 1),
            ),
          ),
        ),
      );
      // 等加载完成
      await tester.pumpAndSettle();

      expect(find.text('轮摘要'), findsOneWidget);
      expect(find.textContaining('completedByTool'), findsOneWidget);
      expect(find.textContaining('Step 1'), findsOneWidget);
      expect(find.textContaining('search_story'), findsWidgets);
      // 日志自轮 1 起（未裁剪）：无裁剪标注
      expect(find.textContaining('事件日志已按保留策略裁剪'), findsNothing);

      // 点开第一步：展开详情（请求序列 + 响应）
      await tester.tap(find.textContaining('Step 1'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Request (2 messages)'), findsOneWidget);
      expect(find.textContaining('Response'), findsOneWidget);
    });

    testWidgets('日志已裁剪 → 页头标注最早保留轮与历史缺失', (tester) async {
      // 模拟裁剪后日志：仅剩第 5 轮
      await repo.appendAll('s1', [
        AgentDurableEvent(
          type: AgentEventTypes.turnBegin,
          data: const {'turn': 5},
        ),
        AgentDurableEvent(
          type: AgentEventTypes.assistantMessage,
          data: const {'turn': 5, 'text': 't5'},
        ),
        AgentDurableEvent(
          type: AgentEventTypes.turnEnd,
          data: const {'turn': 5, 'reason': 'finish'},
        ),
      ]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            appDatabaseProvider.overrideWithValue(db),
          ],
          child: TranslationProvider(
            child: const MaterialApp(
              home: AgentRoundTracePage(sessionId: 's1', turnNumber: 5),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('事件日志已按保留策略裁剪'),
        findsOneWidget,
      );
      expect(find.textContaining('第 5 轮'), findsOneWidget);
    });
  });

  group('AgentRoundTraceEntryPage（入口页）', () {
    testWidgets('仅列出演奏 advanced 会话；空态可用', (tester) async {
      final fakeRepo = _FakeChatRepository([
        ChatSession(
          sessionId: 'adv-1',
          title: '导演局',
          mode: 'advanced',
          createdAt: DateTime.now(),
          lastActiveAt: DateTime.now(),
          messageCount: 0,
        ),
      ]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [chatRepositoryProvider.overrideWithValue(fakeRepo)],
          child: TranslationProvider(
            child: const MaterialApp(home: AgentRoundTraceEntryPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('导演局'), findsOneWidget);
      expect(find.textContaining('id: adv-1'), findsOneWidget);
    });
  });

  test('诊断页入口存在性：DiagnosticsPage 已接线 AgentRoundTraceEntryPage', () {
    final source = File(
      'lib/features/diagnostics/presentation/pages/diagnostics_page.dart',
    ).readAsStringSync();
    expect(source, contains('AgentRoundTraceEntryPage'));
  });
}

class _FakeChatRepository implements ChatRepository {
  _FakeChatRepository(this.sessions);

  final List<ChatSession> sessions;

  @override
  Future<List<ChatSession>> getAllSessions() async => sessions;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
