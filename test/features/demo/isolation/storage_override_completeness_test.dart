import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 覆写完备性守卫：Demo 子类必须覆写基座全部公开方法，
/// 防止基座未来新增方法时静默穿透到真实存储/网络。
///
/// 解析口径（反射在 Flutter 测试环境不可用，采用逐行文本解析）：
/// - 基座公开方法 = 两格缩进、括号前最后一个标识符为小写开头
///   （排除构造器/类型名/私有成员）；
/// - 子类覆写 = `@override` 行之后 4 行内首个含括号行的同口径标识符。
void main() {
  final repoRoot = Directory.current.path;

  String stripComments(String source) {
    final out = StringBuffer();
    var inLine = false;
    var inBlock = false;
    for (var i = 0; i < source.length; i++) {
      final c = source[i];
      final next = i + 1 < source.length ? source[i + 1] : '';
      if (inLine) {
        if (c == '\n') {
          inLine = false;
          out.write(c);
        }
        continue;
      }
      if (inBlock) {
        if (c == '*' && next == '/') {
          inBlock = false;
          i++;
        } else if (c == '\n') {
          out.write(c);
        }
        continue;
      }
      if (c == '/' && next == '/') {
        inLine = true;
        i++;
        continue;
      }
      if (c == '/' && next == '*') {
        inBlock = true;
        i++;
        continue;
      }
      out.write(c);
    }
    return out.toString();
  }

  /// 行内括号前最后一个标识符（小写开头且非关键字才算成员名）
  String? memberNameOfLine(String line) {
    final m = RegExp(r'(\w+)\s*\(').allMatches(line).toList();
    if (m.isEmpty) return null;
    final name = m.last.group(1)!;
    if (name.startsWith('_') || name[0].toUpperCase() == name[0]) return null;
    if (const {'switch', 'if', 'for', 'while'}.contains(name)) return null;
    return name;
  }

  Set<String> publicMethodsOf(String relPath) {
    final lines = stripComments(
      File('$repoRoot/$relPath').readAsStringSync(),
    ).split('\n');
    final methods = <String>{};
    for (final line in lines) {
      if (!line.startsWith('  ') || line.startsWith('   ')) continue;
      final name = memberNameOfLine(line);
      if (name != null) methods.add(name);
    }
    return methods;
  }

  Set<String> overriddenNamesIn(String relPath, String className) {
    final lines = stripComments(
      File('$repoRoot/$relPath').readAsStringSync(),
    ).split('\n');
    final start = lines.indexWhere((l) => l.startsWith('class $className'));
    expect(start, greaterThanOrEqualTo(0), reason: '$className 缺失');
    final names = <String>{};
    for (var i = start + 1; i < lines.length; i++) {
      if (lines[i].trim() != '@override') continue;
      for (var j = i + 1; j <= i + 5 && j < lines.length; j++) {
        final name = memberNameOfLine(lines[j]);
        if (name != null) {
          names.add(name);
          break;
        }
      }
    }
    return names;
  }

  void checkPair(
    String baseRel,
    String demoRel,
    String className, {
    Set<String> allowMissing = const {},
  }) {
    test('$className 覆写基座全部公开方法', () {
      final base = publicMethodsOf(baseRel);
      final overridden = overriddenNamesIn(demoRel, className);
      final missing = base.difference(overridden).difference(allowMissing);
      expect(
        missing,
        isEmpty,
        reason: '基座新增公开方法未在 $className 覆写：$missing',
      );
    });
  }

  checkPair(
    'lib/core/storage/preferences.dart',
    'lib/features/demo/data/demo_preferences.dart',
    'DemoPreferences',
  );
  checkPair(
    'lib/core/storage/secure_storage.dart',
    'lib/features/demo/data/demo_secure_storage.dart',
    'DemoSecureStorage',
  );
  checkPair(
    'lib/core/network/dio_client.dart',
    'lib/features/demo/data/demo_network_guard.dart',
    'GuardedDioClient',
    allowMissing: {'addInterceptor', 'close'},
  );
  checkPair(
    'lib/core/network/http_client.dart',
    'lib/features/demo/data/demo_network_guard.dart',
    'GuardedHttpClient',
    allowMissing: {'close'},
  );
}
