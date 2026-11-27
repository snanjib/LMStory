import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/network/http_client_types.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/demo/data/demo_network_guard.dart';
import 'package:lmstory/features/demo/data/replay_llm_service.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';
import 'package:lmstory/features/demo/domain/demo_replay_profile.dart';
import 'package:lmstory/features/demo/domain/demo_replay_timing.dart';

DemoPack buildPack({
  List<Map<String, dynamic>>? streamEvents,
  List<Map<String, dynamic>>? chatEntries,
  int formatVersion = 2,
  Map<String, dynamic>? replayProfile,
}) =>
    DemoPack.parse({
      'manifest': {
        'formatVersion': formatVersion,
        'sceneId': 'first_launch_director',
        'kind': 'sample',
        'locale': 'zh-CN',
        'contentVersion': 't',
        'templateId': 'builtin-isekai-narrator',
        'templateHash': '0123456789abcdef',
        'promptHash': '0123456789abcdef',
        'toolFingerprint': '0123456789abcdef',
        'embeddingDimensions': 4,
        'embeddingModelLabel': 'm',
        'replayProfile': replayProfile ?? DemoReplayProfile.zhipu.toJson(),
      },
      'prompt': 'p',
      'responses': {
        'stream': streamEvents == null
            ? [
                {
                  'purpose': 'agent_step',
                  'turn': 1,
                  'events': [
                    {'type': 'text_delta', 'content': '第一'},
                    {'type': 'text_delta', 'content': '步'},
                    {
                      'type': 'tool_call_start',
                      'toolCallId': 'c1',
                      'name': 'search_story',
                    },
                    {
                      'type': 'tool_call_args',
                      'toolCallId': 'c1',
                      'argsDelta': '{"query":"x"}',
                    },
                    {
                      'type': 'tool_call_complete',
                      'toolCallId': 'c1',
                      'name': 'search_story',
                      'arguments': {'query': 'x'},
                    },
                    {'type': 'done', 'finishReason': 'tool_calls'},
                  ],
                },
                {
                  'purpose': 'agent_step',
                  'turn': 1,
                  'events': [
                    {'type': 'text_delta', 'content': '第二'},
                    {'type': 'done', 'finishReason': 'stop'},
                  ],
                },
              ]
            : (streamEvents.isEmpty
                ? <dynamic>[]
                : [
                    {
                      'purpose': 'agent_step',
                      'turn': 1,
                      'events': streamEvents,
                    },
                  ]),
        'chat': chatEntries ??
            [
              {
                'purpose': 'session_title',
                'turn': 1,
                'response': {'content': '标题'},
              },
            ],
      },
      'embeddings': <dynamic>[],
      'expectations': {
        'proseContains': <String>[],
        'entityNames': <String>[],
        'eventSummaryContains': <String>[],
        'nextTurn': 2,
        'messageRoles': ['user', 'assistant'],
      },
    });

LlmRequest request(String? purpose, {CancellationToken? cancelToken}) =>
    LlmRequest(
      baseUrl: 'https://demo.invalid/v1',
      modelId: 'demo-narrator-glm',
      messages: const [],
      purpose: purpose,
      cancelToken: cancelToken,
    );

Future<List<LlmStreamEvent>> drain(Stream<LlmStreamEvent> s) async {
  final out = <LlmStreamEvent>[];
  await for (final e in s) {
    out.add(e);
  }
  return out;
}

void main() {
  group('DemoReplayLlmService 匹配与步进', () {
    test('按 purpose 顺序供步；done 完成才消耗', () async {
      final guard = DemoNetworkGuard();
      final svc = DemoReplayLlmService(
        pack: buildPack(),
        guard: guard,
        timing: DemoReplayTiming.immediate,
      );

      final first = await drain(svc.streamChat(request(LlmPurposes.agentStep)));
      expect(first, hasLength(6));
      expect((first.last as LlmStreamDone).finishReason, 'tool_calls');
      expect(guard.attemptCount, 0);

      final second =
          await drain(svc.streamChat(request(LlmPurposes.agentStep)));
      expect((second.first as LlmTextDelta).content, '第二');

      // 耗尽 → unmatched 本地错误（不联网）
      final third = await drain(svc.streamChat(request(LlmPurposes.agentStep)));
      expect(third, hasLength(1));
      expect(third.single, isA<LlmStreamError>());
      expect(
        (third.single as LlmStreamError).code,
        'demo_replay_unmatched',
      );
      expect(guard.attemptCount, 1);
      expect(guard.attempts.single.via, 'replayUnmatched');
    });

    test('中途取消不消耗 → 重试从同一步头部重放', () async {
      final guard = DemoNetworkGuard();
      final svc = DemoReplayLlmService(
        pack: buildPack(),
        timing: DemoReplayTiming.immediate,
        guard: guard,
        interEventDelay: const Duration(milliseconds: 5),
      );

      final token = CancellationToken();
      // 订阅后取消（done 未送达）：取消由第 2 个事件的送达回调直接驱动，
      // 不经轮询——轮询粒度在 CI 事件循环批量化下会错过取消窗口；取消
      // 路径上的 CancelledException 用 onError 收集并在断言阶段定性，
      // 不作为未处理错误逃逸进测试 zone。
      final received = <LlmStreamEvent>[];
      final twoArrived = Completer<void>();
      final cancelSideErrors = <Object>[];
      final sub = svc
          .streamChat(
            request(LlmPurposes.agentStep, cancelToken: token),
          )
          .listen(
            (event) {
              received.add(event);
              if (received.length == 2 && !twoArrived.isCompleted) {
                twoArrived.complete();
              }
            },
            onError: cancelSideErrors.add,
          );
      await twoArrived.future;
      token.cancel();
      await sub.cancel();

      for (final error in cancelSideErrors) {
        expect(
          error,
          isA<CancelledException>(),
          reason: '取消路径只允许 CancelledException，其余错误视为回归',
        );
      }
      expect(received.whereType<LlmStreamDone>(), isEmpty);
      // 送达回调驱动取消：取消必然落在前两个事件内，整步不得被消耗
      expect(received, hasLength(2));

      // 重试：同一第一步从头完整重放
      final retry = await drain(svc.streamChat(request(LlmPurposes.agentStep)));
      expect(retry, hasLength(6));
      expect((retry.first as LlmTextDelta).content, '第一');
      // 消耗后进入第二步
      final next = await drain(svc.streamChat(request(LlmPurposes.agentStep)));
      expect((next.first as LlmTextDelta).content, '第二');
    });

    test('purpose=null 未匹配本地失败', () async {
      final guard = DemoNetworkGuard();
      final svc = DemoReplayLlmService(
        pack: buildPack(),
        guard: guard,
        timing: DemoReplayTiming.immediate,
      );
      final events = await drain(svc.streamChat(request(null)));
      expect(events.single, isA<LlmStreamError>());
      expect(guard.attemptCount, 1);
    });

    test('chat 命中构造 LlmResponse；耗尽抛本地异常', () async {
      final guard = DemoNetworkGuard();
      final svc = DemoReplayLlmService(
        pack: buildPack(),
        guard: guard,
        timing: DemoReplayTiming.immediate,
      );

      final resp = await svc.chat(request(LlmPurposes.sessionTitle));
      expect(resp.content, '标题');

      expect(
        () => svc.chat(request(LlmPurposes.sessionTitle)),
        throwsA(isA<DemoReplayUnmatchedException>()),
      );
      expect(guard.attemptCount, 1);
    });

    test('resetTurn 重置全部游标（重发同一回合安全）', () async {
      final guard = DemoNetworkGuard();
      final svc = DemoReplayLlmService(
        pack: buildPack(),
        guard: guard,
        timing: DemoReplayTiming.immediate,
      );
      await drain(svc.streamChat(request(LlmPurposes.agentStep)));
      await drain(svc.streamChat(request(LlmPurposes.agentStep)));
      svc.resetTurn();
      final again = await drain(svc.streamChat(request(LlmPurposes.agentStep)));
      expect((again.first as LlmTextDelta).content, '第一');
    });
  });
}
