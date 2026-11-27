import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show AssetBundle, rootBundle;
import 'package:lmstory/features/demo/data/demo_tool_fingerprint.dart';
import 'package:lmstory/features/demo/domain/demo_candidate.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';
import 'package:lmstory/features/demo/domain/demo_pack_fingerprint.dart';

/// 演示数据包加载器：读资产 → 解析校验 → 指纹对账。
///
/// 任何失败统一抛 [DemoPackUnavailableException]：调用方（体验入口
/// 门控）据此隐藏入口，绝不进入半兼容回放。
///
/// 指纹校验范围：
/// - packSha256 ↔ 候选目录登记的包字节 SHA-256（候选路径专用）；
/// - promptHash ↔ 包内 prompt（自洽）；
/// - toolFingerprint ↔ 当前源码核心工具集（防采集后工具 schema 漂移）；
/// - 候选元数据 ↔ 包真实 manifest（locale / 来源模型，防目录与包漂移）；
/// - templateHash ↔ 演示库种子后的 builtin-isekai-narrator 行 content
///   （由 `expectedTemplateHash` 在种子后复核，加载期缺省跳过）。
class DemoPackLoader {
  const DemoPackLoader({AssetBundle? bundle}) : _bundle = bundle;

  final AssetBundle? _bundle;

  static const String assetDir = 'assets/demo/first_launch';
  static const String catalogAssetPath = '$assetDir/catalog.json';

  String assetPathFor(String localeTag) => '$assetDir/$localeTag.json';

  /// 读取并解析候选目录；目录缺失/损坏抛 [DemoPackUnavailableException]。
  Future<List<DemoCandidate>> loadCatalog() async {
    final String raw;
    try {
      raw = await (_bundle ?? rootBundle).loadString(catalogAssetPath);
    } catch (e) {
      throw DemoPackUnavailableException('候选目录缺失: $catalogAssetPath ($e)');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (e) {
      throw DemoPackUnavailableException('候选目录 JSON 非法: $e');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const DemoPackUnavailableException('候选目录根节点必须为对象');
    }
    try {
      return parseDemoCandidateCatalog(decoded);
    } on DemoCandidateCatalogFormatException catch (e) {
      throw DemoPackUnavailableException('候选目录结构非法: $e');
    }
  }

  /// 按候选加载并校验包；不可用抛 [DemoPackUnavailableException]。
  ///
  /// 除包自身自洽校验外，强制对账候选元数据（locale / 来源模型 /
  /// 字节 SHA-256），目录与包任一漂移都按候选不可用处理。
  Future<DemoPack> loadCandidate(
    DemoCandidate candidate, {
    String? expectedTemplateHash,
  }) async {
    final path = candidate.assetPath;
    final String raw;
    try {
      raw = await (_bundle ?? rootBundle).loadString(path);
    } catch (e) {
      throw DemoPackUnavailableException('资产缺失: $path ($e)');
    }

    // 字节身份对账（内容身份锚；sha 为空仅出现在无目录的旧形态兜底）
    if (candidate.packSha256 != null) {
      final actualSha = sha256.convert(utf8.encode(raw)).toString();
      if (actualSha != candidate.packSha256) {
        throw DemoPackUnavailableException(
          'packSha256 不符（候选 ${candidate.id} 资产已漂移）: '
          'catalog=${candidate.packSha256} actual=$actualSha',
        );
      }
    }

    final pack = await _parseAndVerify(raw, path);

    // 候选元数据 ↔ 包真实 manifest 对账
    if (pack.manifest.locale != candidate.locale) {
      throw DemoPackUnavailableException(
        '候选 ${candidate.id} locale 不符: catalog=${candidate.locale} '
        'pack=${pack.manifest.locale}',
      );
    }
    final sourceModel = pack.manifest.source?['textModel'];
    if (sourceModel is String && sourceModel != candidate.sourceModelId) {
      throw DemoPackUnavailableException(
        '候选 ${candidate.id} 来源模型不符: catalog=${candidate.sourceModelId} '
        'pack=$sourceModel',
      );
    }

    if (expectedTemplateHash != null &&
        expectedTemplateHash != pack.manifest.templateHash) {
      throw DemoPackUnavailableException(
        'templateHash 不符: manifest=${pack.manifest.templateHash} '
        'expected=$expectedTemplateHash',
      );
    }
    return pack;
  }

  /// 当前 locale 的可用候选列表（逐候选真实加载校验，不可用者剔除）。
  ///
  /// 目录缺失/损坏时回退隐式旧单候选（`<locale>.json`，无字节锚）——
  /// 该路径仅保证既有单包体验不因目录事故回归，多模型能力以目录为准。
  /// 全部不可用返回空表（体验入口隐藏）。
  Future<List<DemoCandidate>> availableCandidates(String localeTag) =>
      _verifiedCandidates(localeTag, firstOnly: false);

  Future<List<DemoCandidate>> _verifiedCandidates(
    String localeTag, {
    required bool firstOnly,
  }) async {
    List<DemoCandidate> catalogCandidates;
    try {
      catalogCandidates = await loadCatalog();
    } on DemoPackUnavailableException {
      return _fallbackCandidates(localeTag);
    }
    final scoped = catalogCandidates
        .where((c) => c.locale == localeTag)
        .toList(growable: false);
    final available = <DemoCandidate>[];
    for (final c in scoped) {
      try {
        await loadCandidate(c);
        available.add(c);
        if (firstOnly) break;
      } on DemoPackUnavailableException {
        // 候选局部不可用：剔除，其余合法选项继续可用
      }
    }
    // 默认候选排首位（无显式默认命中时保持目录顺序）
    final defaultIndex = available.indexWhere((c) => c.isDefault);
    if (defaultIndex > 0) {
      final d = available.removeAt(defaultIndex);
      available.insert(0, d);
    }
    return available;
  }

  Future<List<DemoCandidate>> _fallbackCandidates(String localeTag) async {
    try {
      await load(localeTag);
    } on DemoPackUnavailableException {
      return const <DemoCandidate>[];
    }
    return <DemoCandidate>[
      DemoCandidate(
        id: 'legacy-single',
        sourceModelId: 'glm-5.3',
        virtualModelId: '${demoVirtualModelNamespace}glm',
        locale: localeTag,
        assetPath: assetPathFor(localeTag),
        isDefault: true,
        displayNameZh: '演示叙事模型（本地）',
        displayNameEn: 'Demo narrator (local)',
      ),
    ];
  }

  /// 加载并校验当前 locale 的默认候选包（既有单包入口的兼容路径）。
  Future<DemoPack> load(
    String localeTag, {
    String? expectedTemplateHash,
    String? expectedProfileId,
  }) async {
    final path = assetPathFor(localeTag);
    final String raw;
    try {
      raw = await (_bundle ?? rootBundle).loadString(path);
    } catch (e) {
      throw DemoPackUnavailableException('资产缺失: $path ($e)');
    }
    final pack = await _parseAndVerify(raw, path);

    // 模板哈希（种子后复核时提供）
    if (expectedTemplateHash != null &&
        expectedTemplateHash != pack.manifest.templateHash) {
      throw DemoPackUnavailableException(
        'templateHash 不符: manifest=${pack.manifest.templateHash} '
        'expected=$expectedTemplateHash',
      );
    }

    // 预期画像校验
    if (expectedProfileId != null &&
        pack.manifest.replayProfile?.id != expectedProfileId) {
      throw DemoPackUnavailableException(
        'replayProfile 不符: manifest=${pack.manifest.replayProfile?.id} '
        'expected=$expectedProfileId',
      );
    }

    return pack;
  }

  /// 解析 + 自洽哈希 + 工具集指纹对账（load/loadCandidate 共用）
  Future<DemoPack> _parseAndVerify(String raw, String path) async {
    final DemoPack pack;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const DemoPackFormatException('根节点必须为对象');
      }
      pack = DemoPack.parse(decoded);
    } on DemoPackFormatException catch (e) {
      throw DemoPackUnavailableException('包结构非法: $e');
    }

    // 自洽哈希
    final actualPromptHash = demoContentHash(pack.prompt);
    if (actualPromptHash != pack.manifest.promptHash) {
      throw DemoPackUnavailableException(
        'promptHash 不符: manifest=${pack.manifest.promptHash} '
        'actual=$actualPromptHash',
      );
    }

    // 与当前源码的工具集指纹对账
    final actualToolFingerprint = computeDemoToolFingerprint();
    if (actualToolFingerprint != pack.manifest.toolFingerprint) {
      throw DemoPackUnavailableException(
        'toolFingerprint 不符（源码工具 schema 已变化，包需重采）: '
        'manifest=${pack.manifest.toolFingerprint} '
        'actual=$actualToolFingerprint',
      );
    }
    return pack;
  }

  /// 体验入口门控：当前 locale 是否**至少有一个合法可用候选**。
  ///
  /// 与 [availableCandidates]/启动解析同源：默认包缺失或
  /// 损坏而其余候选有效 → 入口仍可用（用户在向导模型步显式选择其他
  /// 仿真项，不冒充已选择默认）；目录内全部候选不可用或 locale 无候选 →
  /// false（受控禁用入口）；目录缺失时回退旧单包路径（既有单包体验
  /// 不因目录事故回归）。
  Future<bool> isAvailable(String localeTag) async {
    try {
      return (await _verifiedCandidates(localeTag, firstOnly: true)).isNotEmpty;
    } catch (_) {
      return false;
    }
  }
}
