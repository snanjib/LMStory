/// 数据包指纹与输入规范化（契约 §7.5）。
///
/// 全部为纯函数：采集工具、离线校验 CLI 与运行时加载器共用同一实现，
/// 保证「包内声明的哈希」与「运行时计算的哈希」永远同源。
///
/// 规范化不包含 Unicode NFC 折叠（core 无内置支持、不为此引入依赖）：
/// 录制与回放两侧对同一字符串执行同一纯函数，自洽成立；跨端一致性
/// 由「回放输入恒来自包内确定性内容」保证。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';

/// 模板/提示词哈希：行结束归一 LF → sha256 前 16 hex
String demoContentHash(String content) {
  final normalized = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  return sha256.convert(utf8.encode(normalized)).toString().substring(0, 16);
}

/// 嵌入输入规范化：连续空白折叠单空格 → trim → 小写
String normalizeEmbeddingInput(String text) {
  return text.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();
}

/// 嵌入输入哈希（sha256 全长 64 hex）
String hashEmbeddingInput(String text) {
  return sha256.convert(utf8.encode(normalizeEmbeddingInput(text))).toString();
}

/// 键排序、无空白的规范化 JSON（指纹输入）
String canonicalJson(Object? value) {
  final encoded = const JsonEncoder().convert(_sortKeys(value));
  return encoded;
}

Object? _sortKeys(Object? value) {
  if (value is Map) {
    final map = Map<String, dynamic>.from(value);
    return <String, Object?>{
      for (final k in map.keys.toList()..sort()) k: _sortKeys(map[k]),
    };
  }
  if (value is List) {
    return [for (final e in value) _sortKeys(e)];
  }
  return value;
}

/// 工具集指纹：[(name, canonicalJson(schema))] 按 name 排序 → sha256 前 16 hex
///
/// 指纹覆盖工具名与参数 schema，不覆盖 description（文案微调不应
/// 导致整包失效）。
String demoToolFingerprint(Iterable<ToolDefinition> tools) {
  final entries = [
    for (final t in tools) '${t.name}=${canonicalJson(t.parameters)}',
  ]..sort();
  return sha256
      .convert(utf8.encode(entries.join('\n')))
      .toString()
      .substring(0, 16);
}
