import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/data/repositories/agent_event_log_repository.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/services/engineering_context_mode.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';

/// 工程上下文模式切换的仓库原子事务（同库单事务：纪元事件+捕获+会话列）。
///
/// 覆盖 enter 事务中途失败整体回滚的异常反例与进入/退出的账本-会话列一致性。
void main() {
  late AppDatabase db;
  late AgentEventLogRepository repo;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = AgentEventLogRepository(database: db);
    await db.into(db.chatSessionsTable).insert(
          ChatSessionsTableCompanion.insert(
            sessionId: 's1',
            title: '会话',
            mode: const Value('advanced'),
          ),
        );
  });

  tearDown(() async => db.close());

  Future<bool?> flagOf(String sessionId) async {
    final row = await (db.select(db.chatSessionsTable)
          ..where((t) => t.sessionId.equals(sessionId)))
        .getSingleOrNull();
    return row?.engineeringContextEnabled;
  }

  List<AgentDurableEvent> captures(String epochId, int count) => [
        for (var i = 0; i < count; i++)
          AgentDurableEvent(
            type: AgentEventTypes.modeCapture,
            surfaceOp: AgentSurfaceOpKind.append,
            data: {
              'as': i.isEven ? 'user' : 'assistant',
              'content': '捕获$i',
              'epochId': epochId,
              'source': 'mode_capture',
            },
          ),
      ];

  group('applyEngineeringContextEnter', () {
    test('单事务成功：pending→捕获→complete 连续 seq + 会话列置 true', () async {
      await repo.applyEngineeringContextEnter(
        sessionId: 's1',
        epochId: 'e1',
        fromTurn: 5,
        captureEvents: captures('e1', 3),
      );

      final events = await repo.readEvents('s1');
      expect(events, hasLength(5));
      expect(events[0].type, AgentEventTypes.modeEpoch);
      expect(events[0].data['status'], 'pending');
      expect(events[0].data['fromTurn'], 5);
      expect(
        events.sublist(1, 4).every(
              (e) => e.type == AgentEventTypes.modeCapture,
            ),
        isTrue,
      );
      expect(events[4].data['status'], 'complete');
      expect(events[4].data['captureCount'], 3);
      // seq 连续分配
      expect(
        events.map((e) => e.seq).toList(),
        [0, 1, 2, 3, 4],
      );
      expect(await flagOf('s1'), isTrue);

      // 廉价预检通道只取纪元行
      final epochEvents = await repo.readModeEpochEvents('s1');
      expect(epochEvents, hasLength(2));
      expect(epochEvents.last.data['status'], 'complete');

      // 事务后状态解析为正常开启
      final resolution = resolveEngineeringMode(
        enabled: await flagOf('s1'),
        events: events,
      );
      expect(resolution.mode, EngineeringRuntimeMode.normalOpen);
      expect(resolution.epochId, 'e1');
    });

    test('捕获阶段异常 → 整体回滚：列保持原值、账本零残留', () async {
      // 注入不可 JSON 序列化对象：捕获批中途 jsonEncode 抛出。
      final badCaptures = <AgentDurableEvent>[
        ...captures('e1', 1),
        AgentDurableEvent(
          type: AgentEventTypes.modeCapture,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'as': 'user', 'content': Object(), 'epochId': 'e1'},
        ),
      ];
      await expectLater(
        repo.applyEngineeringContextEnter(
          sessionId: 's1',
          epochId: 'e1',
          fromTurn: 2,
          captureEvents: badCaptures,
        ),
        throwsA(anything),
      );

      expect(await flagOf('s1'), isNull);
      expect(await repo.readEvents('s1'), isEmpty);
      expect(await repo.readModeEpochEvents('s1'), isEmpty);
    });

    test('enter 前已有事件：seq 从既有末尾续起', () async {
      await repo.appendAll(
        's1',
        [
          AgentDurableEvent(
            type: AgentEventTypes.userMessage,
            surfaceOp: AgentSurfaceOpKind.append,
            data: {'content': 'u1', 'turn': 1},
          ),
        ],
      );
      await repo.applyEngineeringContextEnter(
        sessionId: 's1',
        epochId: 'e1',
        fromTurn: 2,
        captureEvents: captures('e1', 1),
      );
      final events = await repo.readEvents('s1');
      expect(events.map((e) => e.seq).toList(), [0, 1, 2, 3]);
    });
  });

  group('applyEngineeringContextExit', () {
    test('单事务：exit 事件 + 会话列置 false；解析回正常关闭', () async {
      await repo.applyEngineeringContextEnter(
        sessionId: 's1',
        epochId: 'e1',
        fromTurn: 2,
        captureEvents: captures('e1', 2),
      );
      await repo.applyEngineeringContextExit(sessionId: 's1', epochId: 'e1');

      expect(await flagOf('s1'), isFalse);
      final events = await repo.readEvents('s1');
      expect(events.last.type, AgentEventTypes.modeEpoch);
      expect(events.last.data['phase'], kModeEpochPhaseExit);
      final resolution = resolveEngineeringMode(
        enabled: await flagOf('s1'),
        events: events,
      );
      expect(resolution.mode, EngineeringRuntimeMode.normalClosed);
    });

    test('epochId 为 null（true 列缺纪元异常账本）→ 仅置列，零事件追加', () async {
      await (db.update(db.chatSessionsTable)
            ..where((t) => t.sessionId.equals('s1')))
          .write(
        const ChatSessionsTableCompanion(
          engineeringContextEnabled: Value(true),
        ),
      );
      await repo.applyEngineeringContextExit(
        sessionId: 's1',
        // 显式传 null：本用例锁定「无纪元可闭合→仅置列」分支
        // ignore: avoid_redundant_argument_values
        epochId: null,
      );

      expect(await flagOf('s1'), isFalse);
      expect(await repo.readEvents('s1'), isEmpty);
    });
  });

  group('关闭态行为不变（基线守卫）', () {
    test('普通关闭会话照旧 trim（工程列 NULL 不影响裁剪）', () async {
      final events = <AgentDurableEvent>[
        for (var turn = 1; turn <= 30; turn++)
          AgentDurableEvent(
            type: AgentEventTypes.assistantMessage,
            surfaceOp: AgentSurfaceOpKind.append,
            data: {'text': '正文$turn', 'turn': turn},
          ),
      ];
      await repo.appendAll('s1', events);
      expect(await flagOf('s1'), isNull);

      final deleted = await repo.trimToRecentTurns('s1', 10);
      expect(deleted, greaterThan(0));
      final remaining = await repo.readEvents('s1');
      expect(remaining.length, lessThan(30));
    });

    test('开启态轮事件无 trim SQL 豁免——入口跳过是唯一保护', () async {
      // 纪元内轮事件（user/message 等带 turn 戳）
      // 不在 trim 豁免名单（仅 system/% 与 surface/replace 豁免）——若
      // 调用方不整体跳过 trim，开启态活跃事件会被按轮窗物理删除。
      await repo.applyEngineeringContextEnter(
        sessionId: 's1',
        epochId: 'e1',
        fromTurn: 1,
        captureEvents: captures('e1', 1),
      );
      final roundEvents = <AgentDurableEvent>[
        for (var turn = 1; turn <= 30; turn++)
          AgentDurableEvent(
            type: AgentEventTypes.userMessage,
            surfaceOp: AgentSurfaceOpKind.append,
            data: {'content': '纪元内消息$turn', 'turn': turn},
          ),
      ];
      await repo.appendAll('s1', roundEvents);

      final deleted = await repo.trimToRecentTurns('s1', 10);
      expect(deleted, greaterThan(0));
      final after = await repo.readEvents('s1');
      // 纪元内早期轮消息确实被裁——保护只能来自调用入口跳过
      expect(
        after.where((e) => e.type == AgentEventTypes.userMessage),
        isNot(
          contains(
            predicate<AgentDurableEvent>(
              (e) => e.data['content'] == '纪元内消息1',
            ),
          ),
        ),
      );
      // mode/epoch/mode/capture 无 turn 戳，本次未被裁（豁免缺失的另一
      // 面向：带 turn 的纪元事件才是暴露面）
      expect(
        after.any((e) => e.type == AgentEventTypes.modeEpoch),
        isTrue,
      );
    });
  });
}
