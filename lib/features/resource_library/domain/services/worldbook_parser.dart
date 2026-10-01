import 'dart:convert';

import 'package:lmstory/core/text/injection_guard.dart';
import 'package:lmstory/features/resource_library/domain/entities/normalized_world_entry.dart';
import 'package:lmstory/features/resource_library/domain/services/type_coercion.dart';

/// 世界书 JSON 解析器（DOC-15 §5.2）
///
/// 支持两套 SillyTavern schema：
/// - 独立导出：顶层 `{ "entries": { "<id>": <entry> } }`（字典），camelCase 字段
/// - 内嵌 character_book：`{ name, entries: [ ... ] }`（数组），snake_case 字段
///
/// 解析失败抛 [FormatException]。
class WorldbookParser {
  const WorldbookParser._();

  /// 解析世界书 JSON，返回归一化词条列表
  static List<NormalizedWorldEntry> parse(String json) =>
      parseBook(json).entries;

  /// 解析世界书 JSON，返回书名 + 归一化词条列表。
  ///
  /// 顶层 `name` 是世界书导出的自带书名，此前
  /// 被丢弃导致显示名只能是导入文件名（含 .json 后缀）。调用方
  /// （导入服务）以 [WorldbookParseResult.name] 优先于文件名回退。
  static WorldbookParseResult parseBook(String json) {
    final dynamic root;
    try {
      root = jsonDecode(json);
    } on FormatException catch (e) {
      throw FormatException('世界书 JSON 解析失败：${e.message}');
    }
    if (root is! Map) {
      throw const FormatException('世界书 JSON 顶层不是对象');
    }

    final name = _readBookName(root);
    final entries = root['entries'];
    if (entries == null) {
      return WorldbookParseResult(name: name, entries: const []);
    }

    // 独立导出：entries 为字典（键为 id 字符串）→ 取 values
    if (entries is Map) {
      return WorldbookParseResult(
        name: name,
        entries: [
          for (final e in entries.values)
            if (e is Map) normalizeEntry(Map<String, dynamic>.from(e)),
        ],
      );
    }
    // 内嵌 character_book：entries 为数组
    if (entries is List) {
      return WorldbookParseResult(
        name: name,
        entries: [
          for (final e in entries)
            if (e is Map) normalizeEntry(Map<String, dynamic>.from(e)),
        ],
      );
    }
    return WorldbookParseResult(name: name, entries: const []);
  }

  /// 读顶层书名：仅接受字符串，与角色卡 name 同口径消毒，
  /// 清洗后为空（如全为零宽字符）返回空串由调用方回退。
  static String _readBookName(Map<dynamic, dynamic> root) {
    final raw = root['name'];
    if (raw is! String) return '';
    return sanitizeUntrusted(raw.trim(), maxLength: 100);
  }

  /// 归一化单条词条（兼容 camelCase 与 snake_case 两套字段名）
  ///
  /// 字符串字段逐一消毒（去零宽/控制字符、剥离伪装的 harness 包裹
  /// 标签、超长截断）——世界书是活跃注入载体，清洗在导入口集中完成。
  static NormalizedWorldEntry normalizeEntry(Map<String, dynamic> e) {
    String s(dynamic raw) => sanitizeUntrusted(coerceString(raw));
    List<String> sList(dynamic raw) => [
          for (final k in coerceStringList(raw)) sanitizeUntrusted(k),
        ];
    return NormalizedWorldEntry(
      keys: sList(e['key'] ?? e['keys']),
      secondaryKeys: sList(e['keysecondary'] ?? e['secondary_keys']),
      comment: s(e['comment']),
      content: s(e['content']),
      constant: coerceBool(e['constant']),
      enabled: e.containsKey('enabled')
          ? coerceBool(e['enabled'], fallback: true)
          : !coerceBool(e['disable']),
      vectorized: coerceBool(e['vectorized']),
    );
  }
}

/// 世界书整体解析结果
///
/// 词条实体 [NormalizedWorldEntry] 是逐条结构、无处挂书名，书名以本
/// 包装类承载——不扩实体字段、不动 codegen，由导入服务层消费后传给
/// 仓储的显示名。
class WorldbookParseResult {
  const WorldbookParseResult({required this.name, required this.entries});

  /// 顶层 `name`（消毒后）。JSON 未提供该字段 / 非字符串 / 清洗后为空
  /// 时为空串，由调用方回退（导入路径回退去扩展名的文件名）。
  final String name;

  /// 归一化词条列表（与 [WorldbookParser.parse] 同产物）
  final List<NormalizedWorldEntry> entries;
}
