/// 首次启动演示多仿真模型候选目录模型（Domain 层，不依赖 Flutter/Data）。
///
/// 候选目录（`assets/demo/first_launch/catalog.json`）是「模型名 → 包路径 /
/// 内容身份 / 展示文案」的**唯一映射点**：UI 选项、播种模型列表、恢复身份
/// 对账一律从本目录推导，禁止在页面里各写一套模型名→包路径映射。
///
/// 候选与包的对账契约：
/// - `locale` == 包 `manifest.locale`；
/// - `sourceModelId` == 包 `manifest.source.textModel`（来源真实模型）；
/// - `packSha256` == 包文件字节 SHA-256（内容身份锚，防资产漂移）；
/// - `virtualModelId` 为演示命名空间内的虚拟模型 id（`demo-narrator-*`），
///   仅存在于演示库虚拟供应商缓存清单中，绝不代表真实供应商配置。
library;

/// 目录结构错误（解析失败/字段非法/重复 id）
class DemoCandidateCatalogFormatException implements Exception {
  const DemoCandidateCatalogFormatException(this.message);

  final String message;

  @override
  String toString() => 'DemoCandidateCatalogFormatException: $message';
}

/// 单个仿真候选（一份已验收的离线回放数据包 + 展示元数据）。
class DemoCandidate {
  const DemoCandidate({
    required this.id,
    required this.sourceModelId,
    required this.virtualModelId,
    required this.locale,
    required this.assetPath,
    required this.isDefault,
    required this.displayNameZh,
    required this.displayNameEn,
    this.packSha256,
  });

  /// 解析并校验单个目录条目（[parseDemoCandidateCatalog] 内部使用，测试可直接复用）。
  factory DemoCandidate.fromJson(
    Map<String, dynamic> json, {
    required String path,
  }) {
    String requireString(String key) {
      final v = json[key];
      if (v is! String || v.isEmpty) {
        throw DemoCandidateCatalogFormatException('$path.$key: 必须为非空字符串');
      }
      return v;
    }

    final id = requireString('id');
    final locale = requireString('locale');
    if (locale.contains('/')) {
      throw DemoCandidateCatalogFormatException('$path.locale: 非法语言标签');
    }
    final virtualModelId = requireString('virtualModelId');
    if (!virtualModelId.startsWith(demoVirtualModelNamespace)) {
      throw DemoCandidateCatalogFormatException(
        '$path.virtualModelId: 必须以 "$demoVirtualModelNamespace" 命名空间开头',
      );
    }
    final sha = json['packSha256'];
    if (sha != null &&
        (sha is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha))) {
      throw DemoCandidateCatalogFormatException(
        '$path.packSha256: 必须为 64 位小写 hex（或省略）',
      );
    }
    return DemoCandidate(
      id: id,
      sourceModelId: requireString('sourceModelId'),
      virtualModelId: virtualModelId,
      locale: locale,
      assetPath: requireString('assetPath'),
      isDefault: json['isDefault'] == true,
      displayNameZh: requireString('displayNameZh'),
      displayNameEn: requireString('displayNameEn'),
      packSha256: sha as String?,
    );
  }

  /// 稳定候选 id（目录内唯一；持久身份引用它）
  final String id;

  /// 来源真实模型 id（对账包 `manifest.source.textModel`）
  final String sourceModelId;

  /// 演示命名空间虚拟模型 id（播种进演示库缓存清单；交接时清理）
  final String virtualModelId;

  /// 候选包语言（zh-CN 等）
  final String locale;

  /// 包资产路径（AssetBundle 键）
  final String assetPath;

  /// 包文件字节 SHA-256（null=不校验字节，仅旧目录缺省兜底路径使用）
  final String? packSha256;

  /// 是否默认候选（原 glm-5.3 官方包）
  final bool isDefault;

  final String displayNameZh;
  final String displayNameEn;

  /// 按 locale 前缀取展示名（en* 走英文，其余走中文）
  String displayNameFor(String localeTag) =>
      localeTag.toLowerCase().startsWith('en') ? displayNameEn : displayNameZh;
}

/// 解析候选目录（结构校验：非空、id 唯一、默认候选唯一、命名空间合法）。
List<DemoCandidate> parseDemoCandidateCatalog(Map<String, dynamic> json) {
  final version = json['catalogFormatVersion'];
  if (version != 1) {
    throw DemoCandidateCatalogFormatException(
      'catalogFormatVersion=$version 不受支持（当前支持 1）',
    );
  }
  final rawList = json['candidates'];
  if (rawList is! List || rawList.isEmpty) {
    throw const DemoCandidateCatalogFormatException(
      'candidates: 必须为非空数组',
    );
  }
  final candidates = <DemoCandidate>[];
  final ids = <String>{};
  var defaultCount = 0;
  for (var i = 0; i < rawList.length; i++) {
    final raw = rawList[i];
    if (raw is! Map<String, dynamic>) {
      throw DemoCandidateCatalogFormatException('candidates[$i]: 必须为对象');
    }
    final c = DemoCandidate.fromJson(raw, path: 'candidates[$i]');
    if (!ids.add(c.id)) {
      throw DemoCandidateCatalogFormatException(
        'candidates[$i].id=${c.id}: 重复候选 id',
      );
    }
    if (c.isDefault) defaultCount++;
    candidates.add(c);
  }
  if (defaultCount != 1) {
    throw DemoCandidateCatalogFormatException(
      '默认候选必须恰好一个（实际 $defaultCount 个）',
    );
  }
  return candidates;
}

/// 虚拟模型 id 命名空间（DemoSeeder 播种与交接清理共享词汇）
const String demoVirtualModelNamespace = 'demo-narrator-';

/// 旧单包状态的默认候选内容版本（候选目录出现前的历史身份；
/// 恢复对账据此把无 candidateId 的旧状态映射回默认候选，其余视为未知身份）
const String demoLegacyDefaultContentVersion = 'v2-glm5.3-official';
