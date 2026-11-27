import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/features/advanced/data/repositories/agent_event_log_repository.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/services/engineering_context_mode.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';

/// AgentEventLogRepository 测试（内存 drift）
void main() {
  late AppDatabase db;
  late AgentEventLogRepository repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = AgentEventLogRepository(database: db);
  });

  tearDown(() async => db.close());

  AgentDurableEvent event(
    String type, {
    Map<String, dynamic> data = const {},
    AgentSurfaceOpKind? op,
  }) {
    return AgentDurableEvent(type: type, data: data, surfaceOp: op);
  }

  // 批 I：事件日志滚动保留——超窗旧轮非 system 行
  // 清理；system/frozen 与 system/core 永不删除（缓存前缀/投影基准）。
  group('批 I trimToRecentTurns / eventsUsage', () {
    test('保留最近 N 轮：旧轮非 system 行删除，frozen/core 豁免', () async {
      // 30 轮 × 每轮 2 行（assistant/message + step/end）+ 2 行 system
      final events = <AgentDurableEvent>[];
      for (var turn = 1; turn <= 30; turn++) {
        events
          ..add(event('assistant/message', data: {'turn': turn}))
          ..add(event('step/end', data: {'turn': turn}));
      }
      events
        ..add(
          event(
            AgentEventTypes.systemFrozen,
            data: {'turn': 1, 'content': 'FROZEN'},
          ),
        )
        ..add(
          event(
            AgentEventTypes.systemCore,
            data: {'turn': 2, 'content': 'CORE-OLD'},
          ),
        );
      await repo.appendAll('s1', events);

      final deleted = await repo.trimToRecentTurns('s1', 10);

      expect(deleted, greaterThan(0));
      final remaining = await repo.readEvents('s1');
      // 非 system 行的轮分布（system 行的 turn 戳不参与窗口判定）
      final turns = remaining
          .where((e) => !e.type.startsWith('system/'))
          .map((e) => e.data['turn'])
          .whereType<int>()
          .toSet();
      expect(turns.where((t) => t <= 20), isEmpty, reason: '旧轮非 system 清空');
      expect(turns.where((t) => t >= 21), hasLength(10), reason: '保留 10 轮');
      // system 行豁免：frozen + 旧 core 都在
      expect(
        remaining.where((e) => e.type == AgentEventTypes.systemFrozen),
        hasLength(1),
      );
      expect(
        remaining.where((e) => e.type == AgentEventTypes.systemCore),
        hasLength(1),
      );
    });

    test('未超窗为空操作；keepTurns<=0 不限制', () async {
      await repo.appendAll('s1', [
        event('assistant/message', data: {'turn': 1}),
        event('assistant/message', data: {'turn': 2}),
      ]);
      expect(await repo.trimToRecentTurns('s1', 10), 0);
      expect(await repo.trimToRecentTurns('s1', 0), 0);
      expect(await repo.readEvents('s1'), hasLength(2));
    });

    test('eventsUsage 返回行数与 data 字节', () async {
      await repo.append(
        's1',
        event('assistant/message', data: {'turn': 1, 'text': '内容'}),
      );
      final usage = await repo.eventsUsage();
      expect(usage.count, 1);
      expect(usage.bytes, greaterThan(0));
    });

    test('eventsUsage 按字节口径（中文 UTF-8 多字节不低估）', () async {
      // data 列以 jsonEncode 文本存储；LENGTH(TEXT) 返回字符数，
      // 中文实际体积≈3×——口径必须是 LENGTH(CAST(data AS BLOB)) 字节数
      final data = {'turn': 1, 'text': '内容'};
      await repo.append('s1', event('assistant/message', data: data));
      final usage = await repo.eventsUsage();
      expect(usage.bytes, utf8.encode(jsonEncode(data)).length);
    });

    test('turn 戳缺失行不被删除、也不参与窗口判定', () async {
      final events = <AgentDurableEvent>[
        // 异常形态：无 turn 戳的行（DELETE 条件 CAST(NULL) 对三值逻辑恒假）
        event('assistant/message'),
        event('step/end'),
        for (var turn = 1; turn <= 6; turn++)
          event('assistant/message', data: {'turn': turn}),
      ];
      await repo.appendAll('s1', events);

      final deleted = await repo.trimToRecentTurns('s1', 2);

      // 窗口=最近 2 轮（5、6），turn 1-4 各删 1 行；无戳行豁免
      expect(deleted, 4);
      final remaining = await repo.readEvents('s1');
      expect(
        remaining.where((e) => e.data['turn'] == null),
        hasLength(2),
        reason: '无 turn 戳的行不能被裁剪误删',
      );
      expect(
        remaining
            .where((e) => e.data['turn'] != null)
            .map((e) => e.data['turn'])
            .toSet(),
        {5, 6},
      );
    });

    // HAR-01：surface/replace（溢出整面快照，唯一生产者=溢出自愈
    // agent_runner，每轮至多一次，replaceStart=0 含全量消息）与 system/%
    // 同等豁免——长会话 trim 后失败续跑/恢复的投影（deriveAgentSurface）
    // 不丢失压缩摘要。
    test('HAR-01：旧轮 surface/replace 行豁免 trim；保留量随溢出次数线性', () async {
      final events = <AgentDurableEvent>[
        event(
          AgentEventTypes.systemFrozen,
          data: {'turn': 1, 'content': 'FROZEN'},
        ),
        // 30 轮 × 每轮 2 行（assistant/message + step/end）
        for (var turn = 1; turn <= 30; turn++) ...[
          event('assistant/message', data: {'turn': turn}),
          event('step/end', data: {'turn': turn}),
        ],
        // 两次溢出整面替换快照（stamp 发生轮 5 与 12，均已在窗外）
        event(
          AgentEventTypes.surfaceReplace,
          data: {
            'turn': 5,
            'messages': [
              {'as': 'system', 'content': 'FROZEN'},
              {'as': 'user', 'content': '【前情压缩摘要】'},
            ],
          },
          op: AgentSurfaceOpKind.replace,
        ),
        event(
          AgentEventTypes.surfaceReplace,
          data: {
            'turn': 12,
            'messages': [
              {'as': 'system', 'content': 'FROZEN'},
              {'as': 'user', 'content': '【前情压缩摘要 2】'},
            ],
          },
          op: AgentSurfaceOpKind.replace,
        ),
      ];
      await repo.appendAll('s1', events);

      final deleted = await repo.trimToRecentTurns('s1', 10);

      // 旧轮非 system 非 replace 全删（60 行 - 窗内 20 行 = 40 行）
      expect(deleted, 40);
      final remaining = await repo.readEvents('s1');
      // 窗外非 system 行恰剩两条溢出快照——「低频 KB 级」保留负担
      // 随溢出次数线性（两次溢出 → 两条）
      final oldNonSystem = remaining
          .where(
            (e) =>
                !e.type.startsWith('system/') &&
                (e.data['turn'] as int? ?? 0) < 21,
          )
          .toList();
      expect(oldNonSystem, hasLength(2));
      expect(
        oldNonSystem.every((e) => e.type == AgentEventTypes.surfaceReplace),
        isTrue,
        reason: '旧轮仅溢出快照豁免保留',
      );
      // system 行不回归：frozen 仍在
      expect(
        remaining.where((e) => e.type == AgentEventTypes.systemFrozen),
        hasLength(1),
      );
    });

    test('同 turn 重生成二次追加后，窗口按 distinct turn 判定', () async {
      await repo.appendAll('s1', [
        event('assistant/message', data: {'turn': 1}),
        event('assistant/message', data: {'turn': 2}),
        // 重生成 turn2 后新尝试 stamp 同 turn：同轮两行
        event('assistant/message', data: {'turn': 2}),
        event('assistant/message', data: {'turn': 3}),
      ]);

      // keep=2：窗口边界取第 2 新的 distinct turn=2 → 只删 turn1，
      // turn2 的两行（旧尝试残留）同窗保留
      final deleted = await repo.trimToRecentTurns('s1', 2);

      expect(deleted, 1);
      final remaining = await repo.readEvents('s1');
      expect(remaining, hasLength(3));
      expect(remaining.map((e) => e.data['turn']).toSet(), {2, 3});
    });
  });

  test('append 分配连续 seq；readEvents 升序返回', () async {
    final s1 = await repo.append(
      's1',
      event('user/message', op: AgentSurfaceOpKind.append),
    );
    final s2 = await repo.append('s1', event('turn/begin'));
    final s3 = await repo.append(
      's1',
      event('assistant/message', op: AgentSurfaceOpKind.append),
    );

    expect([s1, s2, s3], [0, 1, 2]);

    final events = await repo.readEvents('s1');
    expect(
      events.map((e) => e.type).toList(),
      ['user/message', 'turn/begin', 'assistant/message'],
    );
    expect(events.first.surfaceOp, AgentSurfaceOpKind.append);
    expect(events[1].surfaceOp, isNull);
  });

  test('appendAll 事务内批量分配（seq 连续且原子）', () async {
    final seqs = await repo.appendAll('s1', [
      event('a'),
      event('b'),
      event('c'),
    ]);
    expect(seqs, [0, 1, 2]);
    expect(await repo.lastSeq('s1'), 2);
  });

  test('会话间 seq 独立', () async {
    await repo.append('s1', event('a'));
    final s2Seq = await repo.append('s2', event('a'));
    expect(s2Seq, 0);
    expect(await repo.lastSeq('s2'), 0);
    expect(await repo.lastSeq('s1'), 0);
  });

  test('fromSeq 增量读取', () async {
    for (var i = 0; i < 5; i++) {
      await repo.append('s1', event('e$i'));
    }
    final tail = await repo.readEvents('s1', fromSeq: 3);
    expect(tail.map((e) => e.type).toList(), ['e3', 'e4']);
  });

  // HAR-02：损坏 data（jsonDecode 失败）不再以 {} 空对象进投影
  // 产出空 assistant——跳过该行（不进返回列表）且不抛异常。
  group('HAR-02 损坏 data 行跳过', () {
    Future<void> insertCorruptRow(
      String sessionId,
      int seq,
      String type,
      String data, {
      String? surfaceOp,
    }) =>
        db.customStatement(
          'INSERT INTO agent_events (session_id, seq, type, time, data, '
          'surface_op) VALUES (?, ?, ?, ?, ?, ?)',
          [sessionId, seq, type, 0, data, surfaceOp],
        );

    test('损坏行被跳过且不抛异常；正常行不受影响', () async {
      await repo.appendAll('s1', [
        event('user/message', data: {'turn': 1, 'content': '输入'}),
      ]);
      await insertCorruptRow('s1', 1, 'assistant/message', 'not-json{');
      await repo.appendAll('s1', [
        event('assistant/message', data: {'turn': 1, 'text': '正常回复'}),
      ]);

      final events = await repo.readEvents('s1');

      expect(events, hasLength(2), reason: '损坏行跳过，不进返回列表');
      expect(events.map((e) => e.data['content'] ?? e.data['text']), [
        '输入',
        '正常回复',
      ]);
    });

    test('投影不再产出空 assistant（损坏行缺失被容忍）', () async {
      await repo.appendAll('s1', [
        event(
          'user/message',
          data: {'turn': 1, 'content': '输入'},
          op: AgentSurfaceOpKind.append,
        ),
      ]);
      await insertCorruptRow(
        's1',
        1,
        'assistant/message',
        '{"text": "半截', // 损坏的 JSON 截断形态
        surfaceOp: 'append', // 真实形态：surface 事件的 data 被截断
      );
      await repo.appendAll('s1', [
        event(
          'assistant/message',
          data: {'turn': 1, 'text': '正常回复'},
          op: AgentSurfaceOpKind.append,
        ),
      ]);

      final events = await repo.readEvents('s1');
      final projection = deriveAgentSurface(events);

      expect(projection.messages, hasLength(2), reason: '损坏行不产出空 assistant');
      expect(
        projection.messages.where(
          (m) =>
              m.role == 'assistant' &&
              (m.content == null || m.content!.isEmpty) &&
              !m.hasToolCalls,
        ),
        isEmpty,
        reason: '跳过的行不得以 {} 空对象进投影',
      );
    });
  });

  test('replace 事件字段（replaceStart/End + sourceEventSeqs）往返', () async {
    await repo.appendAll('s1', [
      AgentDurableEvent(
        type: AgentEventTypes.systemCore,
        surfaceOp: AgentSurfaceOpKind.replace,
        replaceStart: 1,
        replaceEnd: 2,
        data: {'content': 'CORE'},
        sourceEventSeqs: [0],
      ),
    ]);

    final events = await repo.readEvents('s1');
    expect(events.single.replaceStart, 1);
    expect(events.single.replaceEnd, 2);
    expect(events.single.sourceEventSeqs, [0]);
  });

  test('deleteFromSeq 删除回滚段（用户显式回滚轮次）', () async {
    for (var i = 0; i < 5; i++) {
      await repo.append('s1', event('e$i'));
    }
    await repo.deleteFromSeq('s1', 3);
    final events = await repo.readEvents('s1');
    expect(events, hasLength(3));
    expect(await repo.lastSeq('s1'), 2);
    // 删除后新事件继续递增（不留空洞冲突）
    final next = await repo.append('s1', event('after'));
    expect(next, 3);
  });

  test('lastSeq 空会话返回 -1', () async {
    expect(await repo.lastSeq('none'), -1);
  });

  test('schemaVersion 当前版（v49+）：agent_events 表可创建并查询', () async {
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), greaterThanOrEqualTo(49));
  });

  /// 重生成清理——deleteTurnEvents 删该轮首个事件起的全部事件
  group('B4 deleteTurnEvents', () {
    test('同 turn 仅保留最新尝试；其后轮事件一并截断（重生成=历史回卷）', () async {
      AgentDurableEvent turnEvent(int turn, String type) => AgentDurableEvent(
            type: type,
            data: {'turn': turn},
          );

      // 旧尝试 turn 2（三个事件）+ turn 3
      await repo.appendAll('s1', [
        turnEvent(2, 'turn/begin'),
        turnEvent(2, 'assistant/message'),
        turnEvent(2, 'turn/end'),
        turnEvent(3, 'turn/begin'),
      ]);

      await repo.deleteTurnEvents('s1', 2);

      final events = await repo.readEvents('s1');
      expect(events, isEmpty);
      expect(await repo.lastSeq('s1'), -1);
    });

    test('无该轮事件时为空操作，不影响既有日志', () async {
      await repo.append(
        's1',
        AgentDurableEvent(
          type: 'turn/begin',
          data: {'turn': 1},
        ),
      );
      await repo.deleteTurnEvents('s1', 9);
      expect(await repo.readEvents('s1'), hasLength(1));
    });

    // 目标轮事件已被滚动保留裁掉、
    // 下游更晚轮事件仍在时，重生成该轮不得 no-op 留幽灵——首个
    // turn >= N 的事件即删除起点。
    test('目标轮事件已被 trim 裁掉 → 仍删除其后全部（不留幽灵）', () async {
      await repo.appendAll('s1', [
        AgentDurableEvent(type: 'turn/begin', data: {'turn': 1}),
        // turn 2 的事件已被滚动保留裁掉（模拟 trim 后重生成 turn 2）
        AgentDurableEvent(type: 'turn/begin', data: {'turn': 3}),
        AgentDurableEvent(type: 'turn/end', data: {'turn': 3}),
        AgentDurableEvent(type: 'turn/begin', data: {'turn': 4}),
      ]);

      await repo.deleteTurnEvents('s1', 2);

      final events = await repo.readEvents('s1');
      expect(
        events,
        hasLength(1),
        reason: 'turn 1 保留；turn 3/4 事件是已删轮次的幽灵，须清除',
      );
      expect(events.single.data['turn'], 1);
    });

    test('只删目标轮起点之后的事件，此前轮保留', () async {
      await repo.appendAll('s1', [
        AgentDurableEvent(type: 'turn/begin', data: {'turn': 1}),
        AgentDurableEvent(
          type: 'assistant/message',
          data: {'turn': 1},
          surfaceOp: AgentSurfaceOpKind.append,
        ),
        AgentDurableEvent(type: 'turn/begin', data: {'turn': 2}),
      ]);
      await repo.deleteTurnEvents('s1', 2);
      final events = await repo.readEvents('s1');
      expect(events.map((e) => e.type), ['turn/begin', 'assistant/message']);
    });

    test('重生成 turn1 保留 system/frozen 前缀（缓存断点载体不删）', () async {
      await repo.appendAll('s1', [
        AgentDurableEvent(
          type: AgentEventTypes.systemFrozen,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': 'FROZEN', 'turn': 1},
        ),
        AgentDurableEvent(type: 'turn/begin', data: {'turn': 1}),
        AgentDurableEvent(
          type: 'assistant/message',
          data: {'turn': 1},
          surfaceOp: AgentSurfaceOpKind.append,
        ),
        AgentDurableEvent(type: 'turn/begin', data: {'turn': 2}),
      ]);

      final deletedFrozen = await repo.deleteTurnEvents('s1', 1);

      final events = await repo.readEvents('s1');
      // 冻结前缀带 turn=首写轮戳，若不豁免会被整段删掉且不再补写
      expect(events.map((e) => e.type), [AgentEventTypes.systemFrozen]);
      // frozen 在删除区间之外 → 未删 frozen，返回 false
      expect(deletedFrozen, isFalse);
    });

    test('frozen 在删除区间内（stamp 晚于目标轮）→ 删除并返回 true', () async {
      // frozen 在 turn5 变更时写入（stamp=5）；重生成 turn3 时它落在
      // 自 turn3 锚点起的删除区间内——调用方须据此重置补写备忘
      await repo.appendAll('s1', [
        AgentDurableEvent(type: 'turn/begin', data: {'turn': 3}),
        AgentDurableEvent(
          type: 'assistant/message',
          data: {'turn': 3},
          surfaceOp: AgentSurfaceOpKind.append,
        ),
        AgentDurableEvent(
          type: AgentEventTypes.systemFrozen,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': 'FROZEN-V2', 'turn': 5},
        ),
        AgentDurableEvent(type: 'turn/begin', data: {'turn': 5}),
      ]);

      final deletedFrozen = await repo.deleteTurnEvents('s1', 3);

      expect(await repo.readEvents('s1'), isEmpty);
      expect(deletedFrozen, isTrue);
    });

    test('旧轮事件已裁剪时，仍按开启轮号重建捕获', () async {
      await db.into(db.chatSessionsTable).insert(
            ChatSessionsTableCompanion.insert(sessionId: 's1', title: '导演'),
          );
      await repo.applyEngineeringContextEnter(
        sessionId: 's1',
        epochId: 'old-epoch',
        fromTurn: 3,
        captureEvents: buildEngineeringCaptureEvents(
          visibleSurface: [AgentMessage.assistant(text: '第二轮旧稿')],
          epochId: 'old-epoch',
        ),
      );

      await repo.deleteTurnEvents(
        's1',
        2,
        captureHistory: (epochId) async => EngineeringEnterCapture(
          fromTurn: 2,
          captureEvents: buildEngineeringCaptureEvents(
            visibleSurface: [AgentMessage.assistant(text: '第一轮正文')],
            epochId: epochId,
          ),
        ),
      );

      final events = await repo.readEvents('s1');
      expect(
        resolveEngineeringMode(enabled: true, events: events).mode,
        EngineeringRuntimeMode.normalOpen,
      );
      expect(
        events
            .where((event) => event.type == AgentEventTypes.modeCapture)
            .single
            .data['content'],
        '第一轮正文',
      );
      expect(events.first.data['fromTurn'], 2);
    });

    test('回退曾在开启态生成的轮次，保留会话的退出状态', () async {
      await db.into(db.chatSessionsTable).insert(
            ChatSessionsTableCompanion.insert(sessionId: 's1', title: '导演'),
          );
      await repo.applyEngineeringContextEnter(
        sessionId: 's1',
        epochId: 'closed-epoch',
        fromTurn: 2,
        captureEvents: const [],
      );
      await repo.append(
        's1',
        event(AgentEventTypes.turnBegin, data: {'turn': 2}),
      );
      await repo.applyEngineeringContextExit(
        sessionId: 's1',
        epochId: 'closed-epoch',
      );

      await repo.deleteTurnEvents('s1', 2);

      final events = await repo.readEvents('s1');
      expect(
        resolveEngineeringMode(enabled: false, events: events).mode,
        EngineeringRuntimeMode.normalClosed,
      );
      expect(events.where((event) => event.data['turn'] == 2), isEmpty);
      expect(events.last.data['phase'], kModeEpochPhaseExit);
    });
  });
}
