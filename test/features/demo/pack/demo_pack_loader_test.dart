import 'dart:async';
import 'dart:convert';

import 'dart:typed_data' show ByteData;

import 'package:flutter/services.dart' show AssetBundle, ImmutableBuffer;
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/demo/data/demo_pack_loader.dart';
import 'package:lmstory/features/demo/data/demo_tool_fingerprint.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';
import 'package:lmstory/features/demo/domain/demo_pack_fingerprint.dart';

class _FakeBundle implements AssetBundle {
  _FakeBundle(this.map);

  final Map<String, String> map;

  @override
  Future<ByteData> load(String key) => throw UnimplementedError();

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    final v = map[key];
    if (v == null) {
      throw Exception('asset not found: $key');
    }
    return v;
  }

  @override
  Future<T> loadStructuredData<T>(
    String key,
    FutureOr<T> Function(String value) parser,
  ) =>
      throw UnimplementedError();

  @override
  Future<T> loadStructuredBinaryData<T>(
    String key,
    FutureOr<T> Function(ByteData value) parser,
  ) =>
      throw UnimplementedError();

  @override
  Future<ImmutableBuffer> loadBuffer(String key) => throw UnimplementedError();

  @override
  void evict(String key) {}

  @override
  void clear() {}
}

void main() {
  const goodPrompt = '（推进门）';
  Map<String, dynamic> buildPack() => <String, dynamic>{
        'manifest': {
          'formatVersion': 1,
          'sceneId': 'first_launch_director',
          'kind': 'sample',
          'locale': 'zh-CN',
          'contentVersion': 't',
          'templateId': 'builtin-isekai-narrator',
          'templateHash': '0123456789abcdef',
          'promptHash': demoContentHash(goodPrompt),
          'toolFingerprint': computeDemoToolFingerprint(),
          'embeddingDimensions': 4,
          'embeddingModelLabel': 'm',
        },
        'prompt': goodPrompt,
        'responses': {'stream': <dynamic>[], 'chat': <dynamic>[]},
        'embeddings': <dynamic>[],
        'expectations': {
          'proseContains': <String>[],
          'entityNames': <String>[],
          'eventSummaryContains': <String>[],
          'nextTurn': 2,
          'messageRoles': ['user', 'assistant'],
        },
      };

  testWidgets('加载成功', (tester) async {
    final loader = DemoPackLoader(
      bundle: _FakeBundle({
        'assets/demo/first_launch/zh-CN.json': jsonEncode(buildPack()),
      }),
    );
    final pack = await loader.load('zh-CN');
    expect(pack.prompt, goodPrompt);
    expect(await loader.isAvailable('zh-CN'), isTrue);
  });

  testWidgets('资产缺失 → DemoPackUnavailableException / 不可用', (tester) async {
    final loader = DemoPackLoader(bundle: _FakeBundle({}));
    expect(
      () => loader.load('zh-CN'),
      throwsA(isA<DemoPackUnavailableException>()),
    );
    expect(await loader.isAvailable('zh-CN'), isFalse);
  });

  testWidgets('结构损坏 → 不可用', (tester) async {
    final bad = buildPack()..remove('expectations');
    final loader = DemoPackLoader(
      bundle: _FakeBundle({
        'assets/demo/first_launch/zh-CN.json': jsonEncode(bad),
      }),
    );
    expect(
      () => loader.load('zh-CN'),
      throwsA(isA<DemoPackUnavailableException>()),
    );
  });

  testWidgets('工具指纹不符（源码漂移）→ 不可用', (tester) async {
    final stale = buildPack();
    (stale['manifest'] as Map<String, dynamic>)['toolFingerprint'] =
        'deadbeefdeadbeef';
    final loader = DemoPackLoader(
      bundle: _FakeBundle({
        'assets/demo/first_launch/zh-CN.json': jsonEncode(stale),
      }),
    );
    expect(
      () => loader.load('zh-CN'),
      throwsA(
        isA<DemoPackUnavailableException>().having(
          (e) => e.message,
          'message',
          contains('toolFingerprint'),
        ),
      ),
    );
  });

  testWidgets('promptHash 不符 → 不可用', (tester) async {
    final bad = buildPack();
    bad['prompt'] = '（别的提示词）';
    final loader = DemoPackLoader(
      bundle: _FakeBundle({
        'assets/demo/first_launch/zh-CN.json': jsonEncode(bad),
      }),
    );
    expect(
      () => loader.load('zh-CN'),
      throwsA(isA<DemoPackUnavailableException>()),
    );
  });

  testWidgets('expectedTemplateHash 提供且不符 → 不可用', (tester) async {
    final loader = DemoPackLoader(
      bundle: _FakeBundle({
        'assets/demo/first_launch/zh-CN.json': jsonEncode(buildPack()),
      }),
    );
    expect(
      () => loader.load('zh-CN', expectedTemplateHash: 'ffffffffffffffff'),
      throwsA(isA<DemoPackUnavailableException>()),
    );
  });
}
