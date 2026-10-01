import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/network/sse/streaming_tool_call_tracker.dart';

void main() {
  group('StreamingToolCallTracker', () {
    test('规范流：首片带 id/name，后续片仅 index + arguments', () {
      final tracker = StreamingToolCallTracker();

      final startEvents = tracker.handleFragment(
        index: 0,
        id: 'call_abc',
        name: 'search_story',
      );
      expect(startEvents, hasLength(1));
      expect(startEvents.first, isA<StreamingToolCallStart>());
      expect(
        (startEvents.first as StreamingToolCallStart).callId,
        'call_abc',
      );

      final deltaEvents = tracker.handleFragment(
        index: 0,
        argsDelta: '{"query":',
      );
      expect(deltaEvents, hasLength(1));
      expect(deltaEvents.first, isA<StreamingToolCallArgsDelta>());

      tracker.handleFragment(index: 0, argsDelta: '"古碑"}');

      final finished = tracker.finishAll();
      expect(finished, hasLength(1));
      expect(finished.first.arguments, '{"query":"古碑"}');
      expect(finished.first.jsonRepaired, isFalse);
    });

    test('并行工具调用：按 index 独立累积，完成按 index 升序', () {
      final tracker = StreamingToolCallTracker()
        ..handleFragment(
          index: 0,
          id: 'call_1',
          name: 'search_story',
          argsDelta: '{"q":',
        )
        ..handleFragment(
          index: 1,
          id: 'call_2',
          name: 'query_facts',
          argsDelta: '{"name":',
        )
        // 交错分片
        ..handleFragment(index: 0, argsDelta: '"A"}')
        ..handleFragment(index: 1, argsDelta: '"B"}');

      final finished = tracker.finishAll();
      expect(finished, hasLength(2));
      expect(finished[0].index, 0);
      expect(finished[0].name, 'search_story');
      expect(finished[0].arguments, '{"q":"A"}');
      expect(finished[1].index, 1);
      expect(finished[1].name, 'query_facts');
      expect(finished[1].arguments, '{"name":"B"}');
    });

    test('中转站容错：续片缺失 index，回退顺序假设', () {
      final tracker = StreamingToolCallTracker()
        ..handleFragment(index: 0, id: 'call_x', name: 'echo')
        // 缺 index 的续片 → 路由到最近未完成 track
        ..handleFragment(argsDelta: '{"text":')
        ..handleFragment(argsDelta: '"hi"}');

      final finished = tracker.finishAll();
      expect(finished, hasLength(1));
      expect(finished.first.callId, 'call_x');
      expect(finished.first.arguments, '{"text":"hi"}');
    });

    test('中转站容错：缺失 id，携带 name 与 index → 新调用', () {
      final tracker = StreamingToolCallTracker()
        ..handleFragment(index: 0, id: 'call_a', name: 'echo')
        ..handleFragment(index: 0, argsDelta: '{"text":"1"}');
      // 新调用：无 id，但 index=1 且带 name
      final events = tracker.handleFragment(
        index: 1,
        name: 'query_facts',
        argsDelta: '{"name":"X"}',
      );
      expect(events.whereType<StreamingToolCallStart>(), hasLength(1));
      expect(
        events.whereType<StreamingToolCallStart>().first.name,
        'query_facts',
      );

      final finished = tracker.finishAll();
      expect(finished, hasLength(2));
      expect(finished[1].arguments, '{"name":"X"}');
    });

    test('中转站容错：完全缺 id 缺 name → 本地合成稳定 id', () {
      final tracker = StreamingToolCallTracker();

      final events = tracker.handleFragment(
        index: 0,
        argsDelta: '{"text":"hi"}',
      );
      expect(events.whereType<StreamingToolCallStart>(), hasLength(1));
      final start = events.whereType<StreamingToolCallStart>().first;
      expect(start.callId, startsWith('call_local_'));

      final finished = tracker.finishAll();
      expect(finished.first.callId, start.callId);
      expect(finished.first.arguments, '{"text":"hi"}');
    });

    test('中转站容错：每片都重复携带同一 id → 视为续片', () {
      final tracker = StreamingToolCallTracker()
        ..handleFragment(index: 0, id: 'call_r', name: 'echo')
        ..handleFragment(id: 'call_r', argsDelta: '{"text":')
        ..handleFragment(id: 'call_r', argsDelta: '"x"}');

      final finished = tracker.finishAll();
      expect(finished, hasLength(1));
      expect(finished.first.arguments, '{"text":"x"}');
    });

    test('一次性吐完整 arguments（无分片）', () {
      final tracker = StreamingToolCallTracker()
        ..handleFragment(
          index: 0,
          id: 'call_o',
          name: 'echo',
          argsDelta: '{"text":"one-shot"}',
        );

      final finished = tracker.finishAll();
      expect(finished.single.arguments, '{"text":"one-shot"}');
    });

    test('截断 JSON → 修复补闭合并标记 jsonRepaired', () {
      final tracker = StreamingToolCallTracker()
        ..handleFragment(index: 0, id: 'call_t', name: 'update_facts')
        // 模拟流中断：JSON 截断在字符串中间
        ..handleFragment(index: 0, argsDelta: '{"value":"古');

      final finished = tracker.finishAll();
      expect(finished.single.jsonRepaired, isTrue);
      // 修复后应可被解析回 Map
      expect(finished.single.arguments, contains('古'));
    });

    test('finishAll 幂等：已完成 track 不重复发出', () {
      final tracker = StreamingToolCallTracker()
        ..handleFragment(index: 0, id: 'call_i', name: 'echo');

      expect(tracker.finishAll(), hasLength(1));
      expect(tracker.finishAll(), isEmpty);
      expect(tracker.hasPending, isFalse);
    });

    test('index 缺失时槽位分配复用最小空闲整数', () {
      final tracker = StreamingToolCallTracker()
        ..handleFragment(index: 1, id: 'a', name: 't1');
      // 无 index 新调用 → 槽位 0（最小空闲）
      final events = tracker.handleFragment(id: 'b', name: 't2');
      expect(
        events.whereType<StreamingToolCallStart>().first.index,
        0,
      );
    });
  });
}
