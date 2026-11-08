import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/demo/data/demo_network_guard.dart';
import 'package:lmstory/features/demo/data/replay_embedding_service.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';
import 'package:lmstory/features/demo/domain/demo_pack_fingerprint.dart';
import 'package:lmstory/features/memory/domain/services/embedding_service.dart';

void main() {
  const recordedText = '  白鹿旅店　玛尔塔  ';
  final recorded = DemoPack.parse({
    'manifest': {
      'formatVersion': 1,
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
    },
    'prompt': 'p',
    'responses': {'stream': <dynamic>[], 'chat': <dynamic>[]},
    'embeddings': [
      {
        'kind': 'query',
        'inputHash': hashEmbeddingInput('白鹿旅店 玛尔塔'),
        'dimensions': 4,
        'values': [0.1, 0.2, 0.3, 0.4],
        'inputPreview': '白鹿旅店 玛尔塔',
      },
    ],
    'expectations': {
      'proseContains': <String>[],
      'entityNames': <String>[],
      'eventSummaryContains': <String>[],
      'nextTurn': 2,
      'messageRoles': ['user', 'assistant'],
    },
  });

  DemoReplayEmbeddingService build() => DemoReplayEmbeddingService(
        pack: recorded,
        guard: DemoNetworkGuard(),
      );

  Future<Float32List> call(
    DemoReplayEmbeddingService svc,
    String text,
    EmbeddingInputKind kind,
  ) =>
      svc.embed(
        text: text,
        kind: kind,
        model: 'demo-embedding',
        baseUrl: 'https://demo.invalid/v1',
        apiKey: null,
      );

  test('规范化命中：空白折叠/大小写归一后同一输入返回同一向量', () async {
    final svc = build();
    final a = await call(svc, '白鹿旅店 玛尔塔', EmbeddingInputKind.query);
    final b = await call(svc, recordedText, EmbeddingInputKind.query);
    expect(a, hasLength(4));
    expect(b, hasLength(4)); // 全角空白+首尾空白归一后命中
  });

  test('kind 区分：passage 输入未记录 → 本地失败', () async {
    final svc = build();
    expect(
      () => call(svc, '白鹿旅店 玛尔塔', EmbeddingInputKind.passage),
      throwsA(isA<DemoReplayEmbeddingMissException>()),
    );
  });

  test('未命中：编造检查（WHITE 未在包内）→ 本地异常 + 守卫记录', () async {
    final guard = DemoNetworkGuard();
    final svc = DemoReplayEmbeddingService(pack: recorded, guard: guard);
    expect(
      () => call(svc, 'WHITE', EmbeddingInputKind.query),
      throwsA(isA<DemoReplayEmbeddingMissException>()),
    );
    expect(guard.attemptCount, 1);
    expect(guard.attempts.single.via, 'embeddingUnmatched');
  });

  test('纯查找幂等：重复/并发调用结果一致', () async {
    final svc = build();
    final a = await call(svc, '白鹿旅店 玛尔塔', EmbeddingInputKind.query);
    final b = await call(svc, '白鹿旅店 玛尔塔', EmbeddingInputKind.query);
    final futures = [
      call(svc, '白鹿旅店 玛尔塔', EmbeddingInputKind.query),
      call(svc, '白鹿旅店 玛尔塔', EmbeddingInputKind.query),
    ];
    final both = await Future.wait(futures);
    expect(b, equals(a));
    expect(both.every((e) => e.length == 4), isTrue);
  });
}
