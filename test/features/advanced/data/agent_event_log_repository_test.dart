import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/data/repositories/agent_event_log_repository.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
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
  });
}
