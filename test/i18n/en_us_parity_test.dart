import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

/// zh-CN 与 en-US 资源对账守卫（解析 lib/i18n 下的两个 yaml 源文件）：
/// key 集合一致、参数占位符一致、英文无空值、英文无中文残留。
///
/// 面向正常显示路径不依赖中文 fallback 的回归保险——
/// en_US.i18n.yaml 与 zh_CN.i18n.yaml 漂移时在此失败。
void main() {
  final zh = _flatten(_loadYaml('lib/i18n/zh_CN.i18n.yaml'));
  final en = _loadEn();

  test('两侧 key 树规模同级（防解析假空跑）', () {
    expect(zh.length, greaterThan(3000));
    expect(en.length, greaterThan(3000));
  });

  test('key 集合完全一致', () {
    final onlyZh = zh.keys.toSet().difference(en.keys.toSet());
    final onlyEn = en.keys.toSet().difference(zh.keys.toSet());
    expect(
      onlyZh,
      isEmpty,
      reason: 'en 缺少这些 key: ${onlyZh.take(20).toList()}',
    );
    expect(
      onlyEn,
      isEmpty,
      reason: 'en 多出这些 key: ${onlyEn.take(20).toList()}',
    );
  });

  test('参数占位符集合逐 key 一致', () {
    final mismatches = <String>[];
    for (final entry in zh.entries) {
      final enValue = en[entry.key];
      if (enValue == null) continue;
      final zhParams = _placeholdersOf(entry.value);
      final enParams = _placeholdersOf(enValue);
      if (zhParams.length != enParams.length ||
          !zhParams.containsAll(enParams)) {
        mismatches.add('${entry.key}: $zhParams vs $enParams');
      }
    }
    expect(
      mismatches,
      isEmpty,
      reason: '占位符不一致（前 20 条）:\n${mismatches.take(20).join('\n')}',
    );
  });

  test('英文无空翻译', () {
    final empty = en.entries
        .where((e) => e.value.trim().isEmpty)
        .map((e) => e.key)
        .toList();
    expect(empty, isEmpty, reason: '空翻译 key: ${empty.take(20).toList()}');
  });

  test('英文无中文残留（语言自称白名单除外）', () {
    const allowed = {'settings.general.languageOptions.zhCn'};
    final cjk = en.entries
        .where((e) => !allowed.contains(e.key))
        .where((e) => RegExp(r'[\u4e00-\u9fff]').hasMatch(e.value))
        .map((e) => e.key)
        .toList();
    expect(cjk, isEmpty, reason: '含中文残留 key: ${cjk.take(20).toList()}');
  });
}

/// 英文文件由 pyyaml 风格脚本组装而来（列表值以块序列表达），
/// 解析时把 YamlList/YamlMap 归一为字符串后再与中文侧同一口径比较。
Map<String, String> _loadEn() {
  final raw = _flatten(_loadYaml('lib/i18n/en_US.i18n.yaml'));
  return raw;
}

dynamic _loadYaml(String path) => loadYaml(File(path).readAsStringSync());

/// 递归展平 yaml 树为 {完整路径: 字符串值}。
///
/// 列表值（help 中的 milestones 等块序列）整体串接为一个值参与对账，
/// 保证两侧列表条数漂移同样被捕获。null 叶子记空串入表：
/// 「双侧同为 null」不再逃过空翻译检查；非对称 null（一侧有一侧无）
/// 天然被 key 集合检查捕获。
Map<String, String> _flatten(dynamic node) {
  final out = <String, String>{};
  void walk(dynamic current, String path) {
    if (current is Map) {
      for (final key in current.keys) {
        walk(current[key], path.isEmpty ? '$key' : '$path.$key');
      }
    } else if (current is List) {
      out[path] = current.map((e) => e.toString()).join('\u{0}');
    } else {
      out[path] = current?.toString() ?? '';
    }
  }

  walk(node, '');
  return out;
}

/// 源 yaml 中的插值记号为 $param（含函数式 key 的参数引用）。
Set<String> _placeholdersOf(String raw) => RegExp(r'\$([a-zA-Z_][a-zA-Z0-9_]*)')
    .allMatches(raw)
    .map((m) => m.group(1)!)
    .toSet();
