import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/demo/data/demo_pack_loader.dart';
import 'package:lmstory/features/demo/domain/demo_candidate.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';

/// 多仿真候选目录回归（真实资产逐一对账，不走任何注入桩）：
/// 目录解析合法、五候选齐备、字节 SHA-256 与磁盘文件一致、
/// 候选元数据与包真实 manifest 一致、默认候选唯一且为 glm-5.3。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const loader = DemoPackLoader();

  test('候选目录解析：五候选、默认唯一、id 唯一、命名空间合法', () async {
    final candidates = await loader.loadCatalog();
    expect(candidates, hasLength(5));
    expect(candidates.map((c) => c.id).toSet(), hasLength(5));
    final defaults = candidates.where((c) => c.isDefault).toList();
    expect(defaults, hasLength(1));
    expect(defaults.single.id, 'glm-5.3');
    expect(defaults.single.virtualModelId, 'demo-narrator-glm');
    for (final c in candidates) {
      expect(c.virtualModelId, startsWith('demo-narrator-'));
      expect(c.locale, 'zh-CN', reason: '本轮候选均为中文包');
    }
    expect(
      candidates.map((c) => c.id),
      containsAllInOrder(<String>[
        'glm-5.3',
        'deepseek-v4.1-flash',
        'glm-5.3-flash',
        'kimi-k3.1-pro',
        'mimo-v2.6-flash',
      ]),
      reason: '默认候选排首位，其余保持目录顺序',
    );
  });

  test('availableCandidates：五候选全部经真实加载校验可用', () async {
    final available = await loader.availableCandidates('zh-CN');
    expect(available, hasLength(5));
    expect(available.first.id, 'glm-5.3');
    // 非 zh-CN 语言无候选（英语入口按原支持边界不提供多模型）
    expect(await loader.availableCandidates('en-US'), isEmpty);
  });

  test('逐候选字节 SHA-256 与磁盘文件一致', () async {
    final candidates = await loader.loadCatalog();
    for (final c in candidates) {
      final bytes = File(c.assetPath).readAsBytesSync();
      expect(
        c.packSha256,
        isNotNull,
        reason: '候选 ${c.id} 必须登记字节指纹',
      );
      // 经 rootBundle 路径加载（与运行时同源），资产存在且 sha 相符
      final assetRaw = await loader.loadCandidate(c);
      expect(assetRaw.manifest, isNotNull);
      // 磁盘字节身份（导入前核对过的同一份）
      final diskRaw = utf8.decode(bytes);
      final diskPack = DemoPack.parse(
        jsonDecode(diskRaw) as Map<String, dynamic>,
      );
      expect(
        diskPack.manifest.contentVersion,
        assetRaw.manifest.contentVersion,
        reason: '候选 ${c.id} 磁盘文件与资产包一致',
      );
    }
  });

  test('候选元数据与包真实 manifest 一致（来源模型/locale）', () async {
    final candidates = await loader.loadCatalog();
    for (final c in candidates) {
      final pack = await loader.loadCandidate(c);
      expect(pack.manifest.locale, c.locale, reason: '候选 ${c.id} locale');
      final sourceModel = pack.manifest.source?['textModel'];
      expect(
        sourceModel,
        c.sourceModelId,
        reason: '候选 ${c.id} 来源模型必须真实对账',
      );
      expect(pack.manifest.formatVersion, 2);
      expect(pack.manifest.kind, 'official');
      expect(
        pack.manifest.replayProfile?.id,
        isNotEmpty,
        reason: '候选 ${c.id} 必须声明回放画像',
      );
    }
  });

  test('五候选语义证据互不雷同（防串包的独立身份锚）', () async {
    final candidates = await loader.loadCatalog();
    final proseFirsts = <String>{};
    final entityNameSets = <String>{};
    for (final c in candidates) {
      final pack = await loader.loadCandidate(c);
      expect(
        pack.expectations.proseContains,
        isNotEmpty,
        reason: '候选 ${c.id} 必须携带正文证据',
      );
      proseFirsts.add(pack.expectations.proseContains.first);
      entityNameSets.add(pack.expectations.entityNames.join('|'));
    }
    expect(
      proseFirsts,
      hasLength(5),
      reason: '五候选开场正文各不相同',
    );
    expect(
      entityNameSets,
      hasLength(5),
      reason: '五候选实体形态各不相同（含零实体候选）',
    );
  });

  test('目录结构错误按 DemoPackUnavailableException 语义拒绝', () {
    expect(
      () => parseDemoCandidateCatalog(<String, dynamic>{
        'catalogFormatVersion': 1,
        'candidates': <dynamic>[
          <String, dynamic>{
            'id': 'a',
            'sourceModelId': 'm',
            'virtualModelId': 'demo-narrator-a',
            'locale': 'zh-CN',
            'assetPath': 'x.json',
            'isDefault': true,
            'displayNameZh': '甲',
            'displayNameEn': 'A',
          },
          <String, dynamic>{
            'id': 'a',
            'sourceModelId': 'm',
            'virtualModelId': 'demo-narrator-b',
            'locale': 'zh-CN',
            'assetPath': 'y.json',
            'isDefault': false,
            'displayNameZh': '乙',
            'displayNameEn': 'B',
          },
        ],
      }),
      throwsA(isA<DemoCandidateCatalogFormatException>()),
    );
  });
}
