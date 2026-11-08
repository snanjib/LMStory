import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';
import 'package:lmstory/features/demo/domain/demo_replay_profile.dart';

/// 构造一个最小合法包（测试坏包时逐字段破坏）
Map<String, dynamic> minimalPack() {
  return jsonDecode(jsonEncode(_seed)) as Map<String, dynamic>;
}

final _seed = <String, dynamic>{
  'manifest': {
    'formatVersion': 2,
    'sceneId': 'first_launch_director',
    'kind': 'official',
    'locale': 'zh-CN',
    'contentVersion': 'v1',
    'templateId': 'builtin-isekai-narrator',
    'templateHash': '0123456789abcdef',
    'promptHash': '0123456789abcdef',
    'toolFingerprint': '0123456789abcdef',
    'embeddingDimensions': 4,
    'embeddingModelLabel': 'm',
    'replayProfile': DemoReplayProfile.zhipu.toJson(),
  },
  'prompt': '（推进门）',
  'responses': {
    'stream': [
      {
        'purpose': 'agent_step',
        'turn': 1,
        'events': [
          {
            'type': 'tool_call_start',
            'toolCallId': 'c1',
            'name': 'finish_round',
          },
          {
            'type': 'tool_call_args',
            'toolCallId': 'c1',
            'argsDelta': '{"prose":"正文"}',
          },
          {
            'type': 'tool_call_complete',
            'toolCallId': 'c1',
            'name': 'finish_round',
            'arguments': {'prose': '正文'},
          },
          {'type': 'done', 'usage': null, 'finishReason': 'tool_calls'},
        ],
      },
    ],
    'chat': [
      {
        'purpose': 'session_title',
        'turn': 1,
        'response': {'content': '标题'},
      },
    ],
  },
  'embeddings': [
    {
      'kind': 'query',
      'inputHash': 'a' * 64,
      'dimensions': 4,
      'values': [0.1, 0.2, 0.3, 0.4],
      'inputPreview': '预览',
    },
  ],
  'expectations': {
    'proseContains': ['正文'],
    'entityNames': ['甲'],
    'eventSummaryContains': ['乙'],
    'nextTurn': 2,
    'messageRoles': ['user', 'assistant'],
  },
};

List<dynamic> streamStepsOf(Map<String, dynamic> p) =>
    (p['responses'] as Map<String, dynamic>)['stream'] as List;

List<dynamic> eventsOfFirstStep(Map<String, dynamic> p) =>
    (streamStepsOf(p)[0] as Map<String, dynamic>)['events'] as List;

void main() {
  group('DemoPack.parse 合法包', () {
    test('全字段解析成功 (formatVersion=2, zhipu 流式画像)', () {
      final pack = DemoPack.parse(minimalPack());
      expect(pack.manifest.formatVersion, 2);
      expect(pack.manifest.replayProfile?.id, DemoReplayProfile.zhipuId);
      expect(pack.manifest.isSample, isFalse);
      expect(pack.prompt, '（推进门）');
      expect(pack.streamSteps, hasLength(1));
      expect(pack.streamSteps.first.events, hasLength(4));
      expect(pack.chatEntriesOf('session_title'), hasLength(1));
      expect(pack.embeddingFor('query', 'a' * 64)?.values, hasLength(4));
      expect(pack.streamStepCount('agent_step', 1), 1);
    });

    test('v1 传统包兼容：隐式 conservativeRelay 且 agent_step 在 chat', () {
      final p = minimalPack();
      (p['manifest'] as Map<String, dynamic>)['formatVersion'] = 1;
      (p['manifest'] as Map<String, dynamic>).remove('replayProfile');
      (p['responses'] as Map<String, dynamic>)['stream'] = <dynamic>[];
      (p['responses'] as Map<String, dynamic>)['chat'] = [
        {
          'purpose': 'agent_step',
          'turn': 1,
          'response': {
            'content': '正文',
            'finishReason': 'tool_calls',
            'toolCalls': [
              {
                'toolCallId': 'c1',
                'name': 'finish_round',
                'arguments': {'prose': '正文'},
              },
            ],
          },
        },
      ];
      final pack = DemoPack.parse(p);
      expect(pack.manifest.formatVersion, 1);
      expect(
        pack.manifest.replayProfile?.id,
        DemoReplayProfile.conservativeRelayId,
      );
      expect(pack.chatEntriesOf('agent_step'), hasLength(1));
    });
  });

  group('DemoPack.parse 坏包逐规则拒绝', () {
    test('formatVersion 不支持', () {
      final p = minimalPack();
      (p['manifest'] as Map<String, dynamic>)['formatVersion'] = 99;
      expect(
        () => DemoPack.parse(p),
        throwsA(isA<DemoPackFormatException>()),
      );
    });

    test('formatVersion=2 缺失 replayProfile 拒绝', () {
      final p = minimalPack();
      (p['manifest'] as Map<String, dynamic>).remove('replayProfile');
      expect(
        () => DemoPack.parse(p),
        throwsA(isA<DemoPackFormatException>()),
      );
    });

    test('formatVersion=2 replayProfile id 不在白名单拒绝', () {
      final p = minimalPack();
      final badProfile = DemoReplayProfile.zhipu.toJson();
      badProfile['id'] = 'unknown_vendor';
      (p['manifest'] as Map<String, dynamic>)['replayProfile'] = badProfile;
      expect(
        () => DemoPack.parse(p),
        throwsA(isA<DemoPackFormatException>()),
      );
    });

    test('formatVersion=2 replayProfile capabilitiesHash 篡改拒绝', () {
      final p = minimalPack();
      final badProfile = DemoReplayProfile.zhipu.toJson();
      badProfile['capabilitiesHash'] = 'deadbeefdeadbeef';
      (p['manifest'] as Map<String, dynamic>)['replayProfile'] = badProfile;
      expect(
        () => DemoPack.parse(p),
        throwsA(isA<DemoPackFormatException>()),
      );
    });

    test('通道不匹配：流式画像 (zhipu) 但 agent_step 在 chat', () {
      final p = minimalPack();
      (p['responses'] as Map<String, dynamic>)['stream'] = <dynamic>[];
      (p['responses'] as Map<String, dynamic>)['chat'] = [
        {
          'purpose': 'agent_step',
          'turn': 1,
          'response': {
            'content': '',
            'finishReason': 'tool_calls',
            'toolCalls': <dynamic>[],
          },
        },
      ];
      expect(
        () => DemoPack.parse(p),
        throwsA(isA<DemoPackFormatException>()),
      );
    });

    test('通道不匹配：非流式画像 (conservativeRelay) 但 agent_step 在 stream', () {
      final p = minimalPack();
      (p['manifest'] as Map<String, dynamic>)['replayProfile'] =
          DemoReplayProfile.conservativeRelay.toJson();
      // p['responses']['stream'] 包含 agent_step
      expect(
        () => DemoPack.parse(p),
        throwsA(isA<DemoPackFormatException>()),
      );
    });

    test('sceneId 不匹配', () {
      final p = minimalPack();
      (p['manifest'] as Map<String, dynamic>)['sceneId'] = 'other';
      expect(() => DemoPack.parse(p), throwsA(isA<DemoPackFormatException>()));
    });

    test('kind 非法', () {
      final p = minimalPack();
      (p['manifest'] as Map<String, dynamic>)['kind'] = 'mystery';
      expect(() => DemoPack.parse(p), throwsA(isA<DemoPackFormatException>()));
    });

    test('prompt 为空', () {
      final p = minimalPack();
      p['prompt'] = '  ';
      expect(() => DemoPack.parse(p), throwsA(isA<DemoPackFormatException>()));
    });

    test('流步缺终止事件', () {
      final p = minimalPack();
      eventsOfFirstStep(p).removeLast();
      expect(() => DemoPack.parse(p), throwsA(isA<DemoPackFormatException>()));
    });

    test('终止事件后多余事件', () {
      final p = minimalPack();
      eventsOfFirstStep(p).add({'type': 'text_delta', 'content': 'x'});
      expect(() => DemoPack.parse(p), throwsA(isA<DemoPackFormatException>()));
    });

    test('未知事件类型', () {
      final p = minimalPack();
      (eventsOfFirstStep(p)[0] as Map<String, dynamic>)['type'] = 'wat';
      expect(() => DemoPack.parse(p), throwsA(isA<DemoPackFormatException>()));
    });

    test('工具调用未 complete（args 后直接 done）', () {
      final p = minimalPack();
      eventsOfFirstStep(p).removeWhere(
        (e) => (e as Map<String, dynamic>)['type'] == 'tool_call_complete',
      );
      expect(() => DemoPack.parse(p), throwsA(isA<DemoPackFormatException>()));
    });

    test('args 引用未 start 的 toolCallId', () {
      final p = minimalPack();
      (eventsOfFirstStep(p)[1] as Map<String, dynamic>)['toolCallId'] = 'ghost';
      expect(() => DemoPack.parse(p), throwsA(isA<DemoPackFormatException>()));
    });

    test('embedding inputHash 非 64hex', () {
      final p = minimalPack();
      ((p['embeddings'] as List)[0] as Map<String, dynamic>)['inputHash'] =
          'xyz';
      expect(() => DemoPack.parse(p), throwsA(isA<DemoPackFormatException>()));
    });

    test('embedding dimensions 与 manifest 不符', () {
      final p = minimalPack();
      ((p['embeddings'] as List)[0] as Map<String, dynamic>)['dimensions'] = 8;
      expect(() => DemoPack.parse(p), throwsA(isA<DemoPackFormatException>()));
    });

    test('重复 (kind,inputHash)', () {
      final p = minimalPack();
      final dup = Map<String, dynamic>.from(
        (p['embeddings'] as List)[0] as Map,
      );
      (p['embeddings'] as List).add(dup);
      expect(() => DemoPack.parse(p), throwsA(isA<DemoPackFormatException>()));
    });

    test('nextTurn < 2', () {
      final p = minimalPack();
      (p['expectations'] as Map<String, dynamic>)['nextTurn'] = 1;
      expect(() => DemoPack.parse(p), throwsA(isA<DemoPackFormatException>()));
    });

    test('密钥样式键名被拒', () {
      final p = minimalPack();
      (p['manifest'] as Map<String, dynamic>)['apiKeyHint'] = 'x';
      expect(() => DemoPack.parse(p), throwsA(isA<DemoPackFormatException>()));
    });

    test('sk- 样式值被拒', () {
      final p = minimalPack();
      (p['manifest'] as Map<String, dynamic>)['notes'] = [
        'leak sk-abcdefghijklmnopqrst',
      ];
      expect(() => DemoPack.parse(p), throwsA(isA<DemoPackFormatException>()));
    });
  });
}
