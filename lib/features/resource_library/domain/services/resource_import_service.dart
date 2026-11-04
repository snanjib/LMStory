import 'dart:convert';
import 'dart:typed_data';
import 'package:lmstory/core/utils/json_depth_guard.dart';
import 'package:lmstory/features/resource_library/domain/repositories/resource_library_repository.dart';
import 'package:lmstory/features/resource_library/domain/services/character_card_parser.dart';
import 'package:lmstory/features/resource_library/domain/services/worldbook_parser.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:path/path.dart' as p;

/// 导入结果类型
enum ImportKind { characterCard, worldbook }

/// 导入结果：类型 + 导入后的资源名
class ImportResult {
  const ImportResult({required this.kind, required this.name});

  final ImportKind kind;
  final String name;
}

/// 资源导入服务（DOC-15 §5.1 导入逻辑的共享实现）
///
/// 供两个入口复用：
/// - 资源库页面的应用内 FilePicker 导入
/// - 系统外部"打开方式/分享"导入（微信等第三方应用）
///
/// 解析失败抛 [FormatException]，入库失败原样抛出。
class ResourceImportService {
  ResourceImportService({required ResourceLibraryRepository repository})
      : _repository = repository;

  /// JSON 嵌套深度上限与粗检实现收敛在 core/utils/json_depth_guard.dart
  /// （资源导入与数据备份导入共用口径）。

  /// 文件名兜底显示名只取最后一段并去掉资源
  /// 文件扩展名（.json/.png，大小写不敏感）——「型月.json」不再原样
  /// 入库为显示名。仅显示名用途；错误信息引用文件名时保持原样。
  static String _displayNameOf(String fallbackName) {
    final base = p.basename(fallbackName);
    const extensions = ['.json', '.png'];
    for (final ext in extensions) {
      if (base.length > ext.length && base.toLowerCase().endsWith(ext)) {
        return base.substring(0, base.length - ext.length);
      }
    }
    return base;
  }

  /// 剥 UTF-8 BOM。
  ///
  /// Windows 记事本「带 BOM 的 UTF-8」导出的世界书/角色卡 JSON 首字符为
  /// `\uFEFF`，`jsonDecode` 抛 FormatException、`detectJsonKind` 判 unknown，
  /// 此前三条读取路径（应用内 FilePicker×2 + 外部分享）均不剥 BOM 必然
  /// 失败。统一在本服务入口剥除（对无 BOM 内容幂等）。
  static String _stripBom(String content) =>
      content.startsWith('\uFEFF') ? content.substring(1) : content;

  final ResourceLibraryRepository _repository;

  /// 导入 PNG 角色卡（V1/V2/V3 卡壳）
  ///
  /// 返回导入后的资源名。失败抛 [FormatException]。
  Future<ImportResult> importCardBytes(
    Uint8List bytes, {
    String? fallbackName,
  }) async {
    final json = CharacterCardParser.extractCardJson(bytes);
    return importCardJson(json, fallbackName: fallbackName);
  }

  /// 导入角色卡 JSON（V2/V3 卡不带 PNG 壳的纯 JSON 格式）
  Future<ImportResult> importCardJson(
    String json, {
    String? fallbackName,
  }) async {
    // 入口统一剥 BOM（三条读取路径共享本方法）
    final source = _stripBom(json);
    // 深度粗检（安全评测）：先于一切 jsonDecode 守卫
    if (exceedsMaxDepth(source)) {
      throw FormatException(t.settings.resourceLibrary.importErrors.tooDeep);
    }
    // 反向守卫——世界书 JSON（顶层
    // entries）经 V1 扁平解析会被静默导入为空角色卡（书名变卡名、词条
    // 全丢）；提示改走世界书导入入口。自动识别入口（importAuto）不受
    // 影响（其先判世界书）。
    if (_looksLikeWorldbook(source)) {
      throw FormatException(
        t.settings.resourceLibrary.importErrors.wrongEntryWorldbook,
      );
    }
    final parsed = CharacterCardParser.parse(source);
    // 空壳卡守卫——仅带 spec 标记、
    // 内容字段全空的 V2 卡（如 {"spec":"chara_card_v2","data":{}}）此前
    // 静默入库为近乎全空的卡（在卡路径的镜像）；至少一项内容
    // 字段非空才允许导入。
    if (parsed.name.trim().isEmpty &&
        parsed.description.trim().isEmpty &&
        parsed.personality.trim().isEmpty &&
        parsed.embeddedEntries.isEmpty) {
      throw FormatException(
        t.settings.resourceLibrary.importErrors.invalidCard,
      );
    }
    // 文件名兜底走 _displayNameOf 剥扩展名——
    //  只修了世界书半边，卡路径曾把「a.json」原样入库为显示名
    final name = parsed.name.isNotEmpty
        ? parsed.name
        : (fallbackName != null && fallbackName.isNotEmpty
            ? _displayNameOf(fallbackName)
            : t.settings.resourceLibrary.cardFallbackName);
    await _repository.createCharacterCard(
      name: name,
      rawJson: source,
      sourceFormat: parsed.specVersion,
    );
    return ImportResult(kind: ImportKind.characterCard, name: name);
  }

  /// 导入世界书 JSON
  Future<ImportResult> importWorldbookContent(
    String content, {
    String? fallbackName,
  }) async {
    // 入口统一剥 BOM（三条读取路径共享本方法），rawJson 以剥除后
    // 内容入库——应用投影时 re-parse 不再撞 BOM
    final source = _stripBom(content);
    // 深度粗检（安全评测）：先于一切 jsonDecode 守卫
    if (exceedsMaxDepth(source)) {
      throw FormatException(t.settings.resourceLibrary.importErrors.tooDeep);
    }
    // F4 修复：结构守卫——此前对无 entries 的任意 JSON，
    // WorldbookParser 静默返回空列表并被入库为空世界书（守卫只在
    // importAuto 自动识别路径存在）。
    if (!_looksLikeWorldbook(source)) {
      throw FormatException(
        t.settings.resourceLibrary.importErrors.wrongEntryCard,
      );
    }
    // 显示名优先用 JSON 顶层 name（世界书导出
    // 自带书名，此前被弃用）；回退文件名时去资源扩展名（仅显示名用途）
    final parsed = WorldbookParser.parseBook(source);
    // 空词条守卫——entries 为空对象/
    // 数组或值全非 Map 时解析产出空列表，此前静默导入「空世界书」
    //（应用时「已应用 0 个实体」，用户无从知道问题出在导入）。
    if (parsed.entries.isEmpty) {
      throw FormatException(
        t.settings.resourceLibrary.importErrors.emptyWorldbook,
      );
    }
    final name = parsed.name.isNotEmpty
        ? parsed.name
        : (fallbackName != null && fallbackName.isNotEmpty
            ? _displayNameOf(fallbackName)
            : t.settings.resourceLibrary.bookFallbackName);
    await _repository.createWorldbook(name: name, rawJson: source);
    return ImportResult(kind: ImportKind.worldbook, name: name);
  }

  /// 自动识别导入（外部"打开方式/分享"入口）
  ///
  /// - PNG（按字节签名）→ 角色卡
  /// - JSON → 顶层含 `entries` 按世界书，否则尝试角色卡 JSON（V2/V3 纯 JSON 卡）
  ///
  /// [bytes] 与 [content] 二选一：优先 [bytes]。
  Future<ImportResult> importAuto({
    Uint8List? bytes,
    String? content,
    String? fallbackName,
  }) async {
    if (bytes != null) {
      return importCardBytes(bytes, fallbackName: fallbackName);
    }
    if (content == null) {
      throw FormatException(t.settings.resourceLibrary.importErrors.noContent);
    }
    // 先剥 BOM 再做结构识别——带 BOM 的 JSON 此前被判 unknown，
    // 用户确认后收到「无法识别的文件格式」
    final source = _stripBom(content);

    if (_looksLikeWorldbook(source)) {
      return importWorldbookContent(source, fallbackName: fallbackName);
    }
    if (_looksLikeCharacterCard(source)) {
      return importCardJson(source, fallbackName: fallbackName);
    }
    throw FormatException(t.settings.resourceLibrary.importErrors.unrecognized);
  }

  /// 探测 JSON 内容类型（供外部导入确认框显示类型标签）。
  ///
  /// PNG 字节固定为角色卡，不做探测。无法识别返回 null。
  static ImportKind? detectJsonKind(String content) {
    final source = _stripBom(content);
    if (_looksLikeWorldbook(source)) return ImportKind.worldbook;
    if (_looksLikeCharacterCard(source)) return ImportKind.characterCard;
    return null;
  }

  /// 判断 JSON 是否为世界书结构：顶层 `entries` 为字典（独立导出）或
  /// 数组（内嵌 character_book）。
  ///
  /// 注意不能依赖 WorldbookParser 的异常：它对无 `entries` 的 JSON 静默
  /// 返回空列表，角色卡 JSON 会被误判为合法空世界书。
  ///
  /// 深度短路（安全评测）：本方法被 detectJsonKind（外部导入确认框
  /// 的类型探测）与 importAuto 调用，是部分路径上第一个 jsonDecode 点，
  /// 深度超限时直接判否，不进解析器。
  static bool _looksLikeWorldbook(String content) {
    if (exceedsMaxDepth(content)) return false;
    final dynamic root;
    try {
      root = jsonDecode(content);
    } on FormatException {
      // 非 JSON：统一在后续解析中给出具体报错
      return false;
    }
    if (root is! Map) return false;
    final entries = root['entries'];
    return entries is Map || entries is List;
  }

  /// 判断 JSON 是否为角色卡结构（V2/V3 有 spec/data 标记；V1 至少有 name）。
  ///
  /// 防止任意 JSON 对象被 V1 扁平解析静默导入为空卡。
  ///
  /// 深度短路同 [_looksLikeWorldbook]。
  static bool _looksLikeCharacterCard(String content) {
    if (exceedsMaxDepth(content)) return false;
    final dynamic root;
    try {
      root = jsonDecode(content);
    } on FormatException {
      return false;
    }
    if (root is! Map) return false;
    if (root.containsKey('spec') ||
        root.containsKey('spec_v2') ||
        root.containsKey('spec_version') ||
        root['data'] is Map) {
      return true;
    }
    final name = root['name'];
    return name is String && name.isNotEmpty;
  }
}
