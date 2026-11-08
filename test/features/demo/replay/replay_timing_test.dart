import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/network/http_client_types.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/demo/data/demo_network_guard.dart';
import 'package:lmstory/features/demo/data/replay_llm_service.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';
import 'package:lmstory/features/demo/domain/demo_replay_profile.dart';
import 'package:lmstory/features/demo/domain/demo_replay_timing.dart';

import 'replay_llm_service_test.dart' show buildPack, request;

void main() {
  test('请求等待 750ms，正文 240 码点/秒按 40ms 批次调度，结构事件不叠加等待', () {
    fakeAsync((clock) {
      // 构造 25 个码点的正文
      const sampleText = '一二三四五六七八九十一二三四五六七八九十一二三四五'; // 25 runes
      final service = DemoReplayLlmService(
        pack: buildPack(
          streamEvents: [
            {'type': 'text_delta', 'content': sampleText},
            {
              'type': 'tool_call_start',
              'toolCallId': 'c1',
              'name': 'search_story',
            },
            {
              'type': 'tool_call_complete',
              'toolCallId': 'c1',
              'name': 'search_story',
              'arguments': {'query': 'x'},
            },
            {'type': 'done', 'finishReason': 'tool_calls'},
          ],
        ),
        guard: DemoNetworkGuard(),
      );
      final events = <LlmStreamEvent>[];
      service.streamChat(request(LlmPurposes.agentStep)).listen(events.add);

      clock
        ..flushMicrotasks()
        ..elapse(const Duration(milliseconds: 749));
      expect(events, isEmpty, reason: '749ms 未达到请求仿真等待');

      // 750ms 到达请求等待：但首批 tick 尚未 elapse
      clock.elapse(const Duration(milliseconds: 1));
      expect(events, isEmpty);

      // 40ms : 10 码点
      clock.elapse(const Duration(milliseconds: 40));
      expect(events.whereType<LlmTextDelta>().length, 1);
      expect(events.whereType<LlmTextDelta>().first.content.runes.length, 10);

      // 40ms : 10 码点
      clock.elapse(const Duration(milliseconds: 40));
      expect(events.whereType<LlmTextDelta>().length, 2);
      expect(events.whereType<LlmTextDelta>().elementAt(1).content.runes.length, 10);

      // 40ms : 剩余 5 码点
      clock.elapse(const Duration(milliseconds: 40));
      expect(events.whereType<LlmTextDelta>().length, 3);
      expect(events.whereType<LlmTextDelta>().elementAt(2).content.runes.length, 5);

      expect(
        events.whereType<LlmTextDelta>().map((e) => e.content).join(),
        sampleText,
      );
      expect(events.whereType<LlmToolCallComplete>(), hasLength(1));
      expect(events.last, isA<LlmStreamDone>());
      expect(service.consumedStreamSteps, 1);
    });
  });

  test('思考过程 480 码点/秒按 40ms 批次调度（每 tick 约 20 码点）', () {
    fakeAsync((clock) {
      // 构造 45 个码点的思考内容
      final thinkingContent = '思' * 45;
      final service = DemoReplayLlmService(
        pack: buildPack(
          streamEvents: [
            {'type': 'thinking_delta', 'content': thinkingContent},
            {'type': 'done', 'finishReason': 'stop'},
          ],
        ),
        guard: DemoNetworkGuard(),
      );
      final events = <LlmStreamEvent>[];
      service.streamChat(request(LlmPurposes.agentStep)).listen(events.add);

      clock
        ..flushMicrotasks()
        ..elapse(const Duration(milliseconds: 750));
      expect(events, isEmpty);

      // 40ms : 20 码点
      clock.elapse(const Duration(milliseconds: 40));
      expect(events.whereType<LlmThinkingDelta>().length, 1);
      expect(events.whereType<LlmThinkingDelta>().first.content.runes.length, 20);

      // 40ms : 20 码点
      clock.elapse(const Duration(milliseconds: 40));
      expect(events.whereType<LlmThinkingDelta>().length, 2);
      expect(events.whereType<LlmThinkingDelta>().elementAt(1).content.runes.length, 20);

      // 40ms : 5 码点
      clock.elapse(const Duration(milliseconds: 40));
      expect(events.whereType<LlmThinkingDelta>().length, 3);
      expect(events.whereType<LlmThinkingDelta>().elementAt(2).content.runes.length, 5);

      expect(
        events.whereType<LlmThinkingDelta>().map((e) => e.content).join(),
        thinkingContent,
      );
      expect(events.last, isA<LlmStreamDone>());
    });
  });

  test('不同原始分片节奏一致，补充平面字符不拆开', () {
    List<String> play(List<String> chunks) {
      final output = <String>[];
      fakeAsync((clock) {
        final service = DemoReplayLlmService(
          pack: buildPack(
            streamEvents: [
              for (final c in chunks) {'type': 'text_delta', 'content': c},
              {'type': 'done', 'finishReason': 'stop'},
            ],
          ),
          guard: DemoNetworkGuard(),
        );
        service.streamChat(request(LlmPurposes.agentStep)).listen((e) {
          if (e is LlmTextDelta) output.add(e.content);
        });
        clock
          ..flushMicrotasks()
          ..elapse(const Duration(milliseconds: 750));
        expect(output, isEmpty);
        clock.elapse(const Duration(milliseconds: 100));
        expect(service.consumedStreamSteps, 1);
      });
      return output;
    }

    expect(play(['甲😀乙']).join(), play(['甲', '😀乙']).join());
    expect(play(['甲😀乙']).join(), '甲😀乙');
  });

  test('非流式请求等待中取消不消耗，重试仍返回同一响应', () {
    fakeAsync((clock) {
      final service = DemoReplayLlmService(
        pack: buildPack(
          streamEvents: const [],
          chatEntries: [
            {
              'purpose': LlmPurposes.agentStep,
              'turn': 1,
              'response': {'content': 'response'},
            }
          ],
          replayProfile: DemoReplayProfile.conservativeRelay.toJson(),
        ),
        guard: DemoNetworkGuard(),
      );
      final token = CancellationToken();
      Object? error;
      service
          .chat(request(LlmPurposes.agentStep, cancelToken: token))
          .then<void>(
        (_) => fail('取消后不得交付响应'),
        onError: (Object e) {
          error = e;
        },
      );
      clock.elapse(const Duration(milliseconds: 749));
      expect(error, isNull);
      token.cancel();
      clock.elapse(const Duration(milliseconds: 1));
      expect(error, isA<CancelledException>());
      LlmResponse? result;
      service.chat(request(LlmPurposes.agentStep)).then((r) => result = r);
      clock.elapse(const Duration(milliseconds: 749));
      expect(result, isNull);
      clock.elapse(const Duration(milliseconds: 1));
      expect(result?.content, 'response');
    });
  });

  test('流式首响应等待中取消不输出也不消耗', () {
    fakeAsync((clock) {
      final service =
          DemoReplayLlmService(pack: buildPack(), guard: DemoNetworkGuard());
      final token = CancellationToken();
      final events = <LlmStreamEvent>[];
      Object? error;
      service
          .streamChat(request(LlmPurposes.agentStep, cancelToken: token))
          .listen(
        events.add,
        onError: (Object e) {
          error = e;
        },
      );
      clock
        ..flushMicrotasks()
        ..elapse(const Duration(milliseconds: 700));
      token.cancel();
      clock.elapse(const Duration(milliseconds: 50));
      expect(error, isA<CancelledException>());
      expect(events, isEmpty);
      expect(service.consumedStreamSteps, 0);
    });
  });

  test('后台标题不增加仿真等待', () {
    fakeAsync((clock) {
      final service =
          DemoReplayLlmService(pack: buildPack(), guard: DemoNetworkGuard());
      LlmResponse? result;
      service.chat(request(LlmPurposes.sessionTitle)).then((r) => result = r);
      clock.flushMicrotasks();
      expect(result?.content, '标题');
      expect(clock.elapsed, Duration.zero);
    });
  });

  test('真实首轮体量（7503 思考码点 + 153 正文码点，6 个请求）总回放耗时低于 1 分钟', () {
    const timing = DemoReplayTiming();
    const requestsCount = 6;
    const thinkingRunes = 7503;
    const textRunes = 153;

    // 每次请求等待 750ms
    final totalRequestDelayMs = requestsCount * timing.requestDelay.inMilliseconds;
    // thinking: 每 tick 20 码点 (480 runes/s * 0.04s)
    final thinkingTicks = (thinkingRunes / 20).ceil();
    final totalThinkingMs = thinkingTicks * timing.tickInterval.inMilliseconds;
    // text: 每 tick 10 码点 (240 runes/s * 0.04s)
    final textTicks = (textRunes / 10).ceil();
    final totalTextMs = textTicks * timing.tickInterval.inMilliseconds;

    final totalDuration = Duration(
      milliseconds: totalRequestDelayMs + totalThinkingMs + totalTextMs,
    );

    expect(totalDuration.inSeconds, lessThan(30), reason: '首轮真实回放耗时应约为 20~25 秒');
    expect(totalDuration.inMinutes, lessThan(1), reason: '首轮真实回放耗时必须严格低于 1 分钟');
  });

  test('相同正文与思考的不同录制分片（1 大块 vs 100 碎块），调度耗时与完成时间严格一致（误差 <= 40ms 1 tick）', () {
    Duration play(List<Map<String, dynamic>> rawEvents) {
      Duration? finished;
      fakeAsync((clock) {
        final service = DemoReplayLlmService(
          pack: buildPack(
            streamEvents: [
              ...rawEvents,
              {'type': 'done', 'finishReason': 'stop'},
            ],
          ),
          guard: DemoNetworkGuard(),
        );
        service.streamChat(request(LlmPurposes.agentStep)).listen(
              (_) {},
              onDone: () => finished = clock.elapsed,
            );
        clock
          ..flushMicrotasks()
          ..elapse(const Duration(seconds: 10));
      });
      return finished!;
    }

    // 1. 正文测试：1 大块 vs 100 碎块
    final textBulkTime = play([
      {'type': 'text_delta', 'content': '字' * 100},
    ]);
    final textFragTime = play([
      for (var i = 0; i < 100; i++)
        {'type': 'text_delta', 'content': '字'},
    ]);
    expect(
      (textFragTime - textBulkTime).inMicroseconds.abs(),
      lessThanOrEqualTo(const Duration(milliseconds: 40).inMicroseconds),
      reason: '正文大块与碎块播放时长必须严格对齐（误差 <= 1 tick）',
    );
    expect(textBulkTime, const Duration(milliseconds: 1150));
    expect(textFragTime, const Duration(milliseconds: 1150));

    // 2. 思考测试：1 大块 vs 100 碎块
    final thinkBulkTime = play([
      {'type': 'thinking_delta', 'content': '思' * 100},
    ]);
    final thinkFragTime = play([
      for (var i = 0; i < 100; i++)
        {'type': 'thinking_delta', 'content': '思'},
    ]);
    expect(
      (thinkFragTime - thinkBulkTime).inMicroseconds.abs(),
      lessThanOrEqualTo(const Duration(milliseconds: 40).inMicroseconds),
      reason: '思考过程大块与碎块播放时长必须严格对齐（误差 <= 1 tick）',
    );
    // 思考 100 runes: 100 / 20 = 5 ticks * 40ms = 200ms. + 750ms = 950ms.
    expect(thinkBulkTime, const Duration(milliseconds: 950));
    expect(thinkFragTime, const Duration(milliseconds: 950));
  });

  test('结构化工具事件紧随其后无逐字延迟，相对顺序严格保序', () {
    fakeAsync((clock) {
      final service = DemoReplayLlmService(
        pack: buildPack(
          streamEvents: [
            {'type': 'thinking_delta', 'content': '思' * 20}, // 1 tick: 40ms
            {
              'type': 'tool_call_start',
              'toolCallId': 'tc-1',
              'name': 'update_facts',
            },
            {
              'type': 'tool_call_args',
              'toolCallId': 'tc-1',
              'argsDelta': '{"entity": "南极"}',
            },
            {
              'type': 'tool_call_complete',
              'toolCallId': 'tc-1',
              'name': 'update_facts',
              'arguments': {'entity': '南极'},
            },
            {'type': 'text_delta', 'content': '字' * 10}, // 1 tick: 40ms
            {'type': 'done', 'finishReason': 'stop'},
          ],
        ),
        guard: DemoNetworkGuard(),
      );

      final eventsWithTime = <(Duration, LlmStreamEvent)>[];
      service.streamChat(request(LlmPurposes.agentStep)).listen((e) {
        eventsWithTime.add((clock.elapsed, e));
      });

      clock
        ..flushMicrotasks()
        ..elapse(const Duration(milliseconds: 750)); // 请求等待
      expect(eventsWithTime, isEmpty);

      // 40ms: 交付 thinking_delta(20 runes) 以及紧接着的 3 个工具事件（不额外叠加逐字等待）
      clock.elapse(const Duration(milliseconds: 40));
      expect(eventsWithTime.length, 4);
      expect(eventsWithTime[0].$2, isA<LlmThinkingDelta>());
      expect(eventsWithTime[1].$2, isA<LlmToolCallStart>());
      expect(eventsWithTime[2].$2, isA<LlmToolCallArgs>());
      expect(eventsWithTime[3].$2, isA<LlmToolCallComplete>());
      // 结构化事件时间戳与思考完成完全处于同一时刻
      expect(eventsWithTime[1].$1, eventsWithTime[0].$1);
      expect(eventsWithTime[2].$1, eventsWithTime[0].$1);
      expect(eventsWithTime[3].$1, eventsWithTime[0].$1);

      // 再过 40ms: 交付 text_delta(10 runes) 与 done
      clock.elapse(const Duration(milliseconds: 40));
      expect(eventsWithTime.length, 6);
      expect(eventsWithTime[4].$2, isA<LlmTextDelta>());
      expect(eventsWithTime[5].$2, isA<LlmStreamDone>());
    });
  });

  test('流式回放在正文输出期间中途取消：停止输出、不消耗 step，重试从头重新播放', () {
    fakeAsync((clock) {
      final service = DemoReplayLlmService(
        pack: buildPack(
          streamEvents: [
            {'type': 'text_delta', 'content': '字' * 50}, // 5 ticks = 200ms
            {'type': 'done', 'finishReason': 'stop'},
          ],
        ),
        guard: DemoNetworkGuard(),
      );

      final token = CancellationToken();
      final events = <LlmStreamEvent>[];
      Object? error;

      service
          .streamChat(request(LlmPurposes.agentStep, cancelToken: token))
          .listen(
        events.add,
        onError: (Object e) => error = e,
      );

      clock
        ..flushMicrotasks()
        ..elapse(const Duration(milliseconds: 750 + 80)); // 过了 2 个 tick（输出 20 字）
      expect(events.length, 2);
      expect(events.whereType<LlmTextDelta>().length, 2);

      // 中途取消
      token.cancel();
      clock.elapse(const Duration(milliseconds: 40));
      expect(error, isA<CancelledException>());
      expect(service.consumedStreamSteps, 0, reason: '未完成 step 必须不被消耗');

      // 再次重试：重新完整输出 50 字
      final retryEvents = <LlmStreamEvent>[];
      service
          .streamChat(request(LlmPurposes.agentStep))
          .listen(retryEvents.add);
      clock.elapse(const Duration(milliseconds: 750 + 200));
      expect(
        retryEvents.whereType<LlmTextDelta>().map((e) => e.content).join(),
        '字' * 50,
      );
      expect(retryEvents.last, isA<LlmStreamDone>());
      expect(service.consumedStreamSteps, 1);
    });
  });

  test('当前正式包实际 6 步流式事件端到端调度耗时实测（顺序调用）约 20.26 秒，严格低于 1 分钟', () {
    final packRaw = jsonDecode(
      File('assets/demo/first_launch/zh-CN.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final pack = DemoPack.parse(packRaw);

    var totalElapsed = Duration.zero;
    fakeAsync((clock) {
      final service = DemoReplayLlmService(
        pack: pack,
        guard: DemoNetworkGuard(),
      );
      for (var i = 0; i < pack.streamSteps.length; i++) {
        final start = clock.elapsed;
        var stepDone = false;
        service.streamChat(request(LlmPurposes.agentStep)).listen(
              (_) {},
              onDone: () => stepDone = true,
            );
        clock.flushMicrotasks();
        while (!stepDone) {
          clock.elapse(const Duration(milliseconds: 10));
        }
        totalElapsed += clock.elapsed - start;
      }
    });

    // 实测 6 步真实调度总耗时约 20260ms (20.26s)
    expect(totalElapsed.inMilliseconds, greaterThan(19000));
    expect(totalElapsed.inMilliseconds, lessThan(22000));
    expect(totalElapsed.inMinutes, lessThan(1), reason: '整轮实机调度耗时必须严格在 1 分钟以内');
  });
}
