/// Gemini function-declaration schema 裁剪。
///
/// Gemini 原生协议的 `functionDeclarations[].parameters` 与 `responseSchema`
/// 只接受 `Schema` proto 的固定字段集；携带 `additionalProperties` 等
/// JSON Schema 关键字会让整个请求 400 INVALID_ARGUMENT。
///
/// OpenAI strict 模式又要求工具 schema 带 `additionalProperties: false`，
/// 因此不能在工具定义处删除——只能在 Gemini 出网边界做一次白名单裁剪。
library;

/// Gemini `Schema` proto 支持的字段（2026-10 官方口径）。
const Set<String> _kGeminiSchemaFields = {
  'type',
  'format',
  'title',
  'description',
  'nullable',
  'default',
  'items',
  'minItems',
  'maxItems',
  'enum',
  'properties',
  'propertyOrdering',
  'required',
  'minProperties',
  'maxProperties',
  'minimum',
  'maximum',
  'minLength',
  'maxLength',
  'pattern',
  'example',
  'anyOf',
};

/// 把 OpenAI/JSON Schema 形态的 [schema] 裁剪为 Gemini 可接受的子集。
///
/// 纯函数：返回新 Map，不修改入参（工具定义是共享 const，不能就地删键）。
Map<String, dynamic> toGeminiSchema(Map<String, dynamic> schema) {
  final result = <String, dynamic>{};
  for (final entry in schema.entries) {
    final key = entry.key;
    if (!_kGeminiSchemaFields.contains(key)) continue;
    if (key == 'properties') {
      final properties = _nestedSchemas(entry.value);
      if (properties != null) result[key] = properties;
    } else if (key == 'items') {
      final items = _asSchema(entry.value);
      if (items != null) result[key] = items;
    } else if (key == 'anyOf') {
      final anyOf = entry.value;
      if (anyOf is List) {
        final sanitized = <Map<String, dynamic>>[];
        for (final item in anyOf) {
          final itemSchema = _asSchema(item);
          if (itemSchema != null) sanitized.add(itemSchema);
        }
        result[key] = sanitized;
      }
    } else {
      result[key] = entry.value;
    }
  }
  return result;
}

/// 把任意 Map 值转成裁剪后的 Gemini schema；非 Map 返回 null。
Map<String, dynamic>? _asSchema(Object? value) {
  if (value is! Map) return null;
  final schema = <String, dynamic>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is String) schema[key] = entry.value;
  }
  return toGeminiSchema(schema);
}

/// 裁剪 `properties`：逐项递归，非 Map 的属性值丢弃。
Map<String, dynamic>? _nestedSchemas(Object? value) {
  if (value is! Map) return null;
  final result = <String, dynamic>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String) continue;
    final schema = _asSchema(entry.value);
    if (schema != null) result[key] = schema;
  }
  return result;
}
