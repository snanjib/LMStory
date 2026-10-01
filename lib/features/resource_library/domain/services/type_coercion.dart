import 'dart:convert';

/// 解析用类型容错工具（DOC-15 §5.2 类型容错）
///
/// 真实 SillyTavern 卡片/世界书存在非标准类型：布尔用字符串 `"True"`/`"False"`、
/// 数组用字符串 `"[]"` / Python repr、数字用字符串等。此处统一归一化。

/// 容错解析字符串列表
List<String> coerceStringList(dynamic value) {
  if (value == null) return const [];
  if (value is List) return value.map((e) => e.toString()).toList();
  if (value is String) {
    final s = value.trim();
    if (s.isEmpty || s == '[]') return const [];
    if (s.startsWith('[')) {
      // 先按原样解析：已是合法 JSON 数组（值内含撇号如 "O'Brien" 不受影响）
      final decoded = _tryDecodeList(s);
      // 仅当形如 Python repr（首 `[` 尾 `]` 且内部
      // 无任何双引号）才做单引号→双引号替换后重试。此前的无差别替换会把
      // ["O'Brien"] 撕成非法 JSON，回退逗号分隔后产出带括号引号的碎值。
      if (decoded == null && s.endsWith(']') && !s.contains('"')) {
        final repr = _tryDecodeList(s.replaceAll("'", '"'));
        if (repr != null) return repr.map((e) => e.toString()).toList();
      }
      if (decoded != null) {
        return decoded.map((e) => e.toString()).toList();
      }
    }
    return s
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }
  return const [];
}

/// 尝试按 JSON 数组解析，失败或非列表返回 null
List<dynamic>? _tryDecodeList(String s) {
  try {
    final decoded = jsonDecode(s);
    return decoded is List ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// 容错解析布尔
bool coerceBool(dynamic value, {bool fallback = false}) {
  if (value is bool) return value;
  if (value is int) return value != 0;
  if (value is String) {
    final s = value.trim().toLowerCase();
    if (s == 'true' || s == '1' || s == 'yes') return true;
    if (s == 'false' || s == '0' || s == 'no' || s.isEmpty) return false;
  }
  return fallback;
}

/// 容错解析字符串
String coerceString(dynamic value) {
  if (value == null) return '';
  if (value is String) return value;
  return value.toString();
}
