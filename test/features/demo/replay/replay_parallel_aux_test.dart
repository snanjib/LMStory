import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/demo/data/demo_network_guard.dart';
import 'package:lmstory/features/demo/data/replay_llm_service.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';
import 'package:lmstory/features/demo/domain/demo_replay_profile.dart';
import 'package:lmstory/features/demo/domain/demo_replay_timing.dart';

/// 并行辅助调用契约：agent 步与 title 各自独立匹配，互不串流。
void main() {
  late DemoReplayLlmService svc;
  late DemoNetworkGuard guard;

  setUp(() {
    guard = DemoNetworkGuard();
    svc = DemoReplayLlmService(
      pack: DemoPack.parse({
        'manifest': {
          'formatVersion': 2,
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
          'replayProfile': DemoReplayProfile.zhipu.toJson(),
        },
        'prompt': 'p',
        'responses': {
          'stream': [
            {
              'purpose': 'agent_step',
              'turn': 1,
              'events': [
                {'type': 'text_delta', 'content': 'A1'},
                {'type': 'done', 'finishReason': 'stop'},
              ],
            },
          ],
          'chat': [
            {
              'purpose': 'session_title',
              'turn': 1,
              'response': {'content': '并行标题'},
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
      }),
      guard: guard,
      timing: DemoReplayTiming.immediate,
    );
  });

  test('agent 步与 title 并发各自命中，不串流', () async {
    LlmRequest req(String purpose) => LlmRequest(
          baseUrl: 'https://demo.invalid/v1',
          modelId: 'm',
          messages: const [],
          purpose: purpose,
        );

    final agentEvents = <LlmStreamEvent>[];
    final agentDone = Completer<void>();
    // 先启动 agent 流但不 drain（保持进行中）
    final sub = svc.streamChat(req(LlmPurposes.agentStep)).listen(
          agentEvents.add,
          onDone: agentDone.complete,
        );

    // 并发发起 title（chat 非流式）
    final title = await svc.chat(req(LlmPurposes.sessionTitle));
    expect(title.content, '并行标题');

    // agent 流完成
    await agentDone.future;
    await sub.cancel();
    expect((agentEvents.first as LlmTextDelta).content, 'A1');
    expect(agentEvents.last, isA<LlmStreamDone>());

    expect(guard.attemptCount, 0);
  });

  test('未知用途（未预置响应的 purpose）→ unmatched，不误取 agent 响应', () async {
    const req = LlmRequest(
      baseUrl: 'https://demo.invalid/v1',
      modelId: 'm',
      messages: [],
      purpose: LlmPurposes.worldPrompt,
    );
    final events = await svc.streamChat(req).toList();
    expect(events.single, isA<LlmStreamError>());
    expect((events.single as LlmStreamError).code, 'demo_replay_unmatched');
    expect(guard.attemptCount, 1);
    // agent_step 响应未被误消耗
    final agent = await svc
        .streamChat(
          const LlmRequest(
            baseUrl: 'https://demo.invalid/v1',
            modelId: 'm',
            messages: [],
            purpose: LlmPurposes.agentStep,
          ),
        )
        .toList();
    expect((agent.first as LlmTextDelta).content, 'A1');
  });
}
