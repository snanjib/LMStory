import 'package:lmstory/features/demo/domain/demo_candidate.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';
import 'package:lmstory/features/demo/domain/demo_pack_fingerprint.dart';

/// 测试共用：最小合法演示包（无事件/无向量，供装配与隔离测试消费）。
DemoPack buildMinimalPack() {
  const prompt = '（推进门）';
  return DemoPack.parse(const <String, dynamic>{
    'manifest': {
      'formatVersion': 1,
      'sceneId': 'first_launch_director',
      'kind': 'sample',
      'locale': 'zh-CN',
      'contentVersion': 'test',
      'templateId': 'builtin-isekai-narrator',
      'templateHash': '0123456789abcdef',
      'promptHash': '0123456789abcdef',
      'toolFingerprint': '0123456789abcdef',
      'embeddingDimensions': 4,
      'embeddingModelLabel': 'test',
    },
    'prompt': prompt,
    'responses': {'stream': <dynamic>[], 'chat': <dynamic>[]},
    'embeddings': <dynamic>[],
    'expectations': {
      'proseContains': <String>[],
      'entityNames': <String>[],
      'eventSummaryContains': <String>[],
      'nextTurn': 2,
      'messageRoles': ['user', 'assistant'],
    },
  });
}

/// 测试共用：promptHash 与内容自洽的最小包（供加载器路径复算）。
DemoPack buildSelfConsistentPack() {
  const prompt = '（推进门）';
  return DemoPack.parse(<String, dynamic>{
    ...buildMinimalPack().toJsonForTest(),
    'prompt': prompt,
    'manifest': {
      ...buildMinimalPack().manifest.toJsonForTest(),
      'promptHash': demoContentHash(prompt),
    },
  });
}

/// 测试共用：为给定包构造默认候选（运行时多候选路径的测试桩配套；
/// 字节锚缺省——测试包不经 AssetBundle 加载）。
DemoCandidate demoCandidateForPack(
  DemoPack pack, {
  String id = 'test-candidate',
}) {
  return DemoCandidate(
    id: id,
    sourceModelId: switch (pack.manifest.source?['textModel']) {
      final String v => v,
      _ => 'test-model',
    },
    virtualModelId: '${demoVirtualModelNamespace}test',
    locale: pack.manifest.locale,
    assetPath: 'test://pack/$id',
    isDefault: true,
    displayNameZh: '仿真 · 测试模型',
    displayNameEn: 'Sim · Test model',
  );
}

extension on DemoPackManifest {
  Map<String, dynamic> toJsonForTest() => <String, dynamic>{
        'formatVersion': formatVersion,
        'sceneId': sceneId,
        'kind': kind,
        'locale': locale,
        'contentVersion': contentVersion,
        'templateId': templateId,
        'templateHash': templateHash,
        'promptHash': promptHash,
        'toolFingerprint': toolFingerprint,
        'embeddingDimensions': embeddingDimensions,
        'embeddingModelLabel': embeddingModelLabel,
      };
}

extension on DemoPack {
  Map<String, dynamic> toJsonForTest() => <String, dynamic>{
        'manifest': manifest.toJsonForTest(),
        'prompt': prompt,
        'responses': {
          'stream': <dynamic>[],
          'chat': <dynamic>[],
        },
        'embeddings': <dynamic>[],
        'expectations': {
          'proseContains': <String>[],
          'entityNames': <String>[],
          'eventSummaryContains': <String>[],
          'nextTurn': expectations.nextTurn,
          'messageRoles': expectations.messageRoles,
        },
      };
}
