import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 性能红线守卫（常驻测试，不靠自觉）。
///
/// ① 正文/流式渲染区零 BackdropFilter——源级闭集：lib/ 内 BackdropFilter
///    仅允许出现在玻璃工厂（modal/bottomSheet/floatingBar 三处，同屏 ≤2
///    由白名单闭集结构保证）；
/// ②  实例白名单闭集断言（恰好 3 处，多一处即红）；
/// ③ glow（焦点环/品牌时刻配色）仅允许出现在材质常量声明与工厂焦点环，
///    禁止散落卡片列表；
/// ④ 字体资产体积预算（与 tool/ci_guards/check_font_budget.py 同口径：
///    白名单锁 path:bytes，只减不增）。
void main() {
  final repo = _repoRoot();

  List<File> dartFilesUnder(String folder) =>
      Directory('${repo.path}${Platform.pathSeparator}$folder')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();

  test('①② BackdropFilter 白名单闭集：全 lib 仅玻璃工厂 3 处（modal/bottomSheet/floatingBar）',
      () {
    final hits = <String>[];
    for (final file in dartFilesUnder('lib')) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('BackdropFilter(')) {
          final rel = file.path
              .split(Platform.pathSeparator)
              .skipWhile((p) => p != 'lib')
              .join('/');
          hits.add('$rel#${i + 1}');
        }
      }
    }
    expect(hits, hasLength(3), reason: 'T0 白名单闭集=3 处；当前命中：$hits');
    expect(
      hits.every((h) => h.contains('glass_factories.dart')),
      isTrue,
      reason: 'BackdropFilter 只允许存在于玻璃工厂文件；命中：$hits',
    );
  });

  test('③ glow 配色仅存在于材质声明与工厂焦点环，且无写死辉光字面量', () {
    const glowTokens = [
      'focusGlow(',
      'brandGlow(',
    ];
    // 跨轴泄漏禁令：任何形式的写死辉光字面量（波尔多 accent
    // @30%/35% 的旧常量值）在 lib/ 下零容忍——包括材质声明文件本身，
    // 辉光必须由 palette.accent 运行时派生。
    const bannedLiterals = ['0x4DFF4F6E', '0x59FF4F6E'];
    final offenders = <String>[];
    for (final file in dartFilesUnder('lib')) {
      final rel = file.path
          .split(Platform.pathSeparator)
          .skipWhile((p) => p != 'lib')
          .join('/');
      final allowed = rel ==
              'lib/core/theme/system/structures/glass/glass_materials.dart' ||
          rel == 'lib/core/theme/system/structures/glass/glass_factories.dart';
      final text = file.readAsStringSync();
      for (final token in glowTokens) {
        if (text.contains(token) && !allowed) {
          offenders.add('$rel mentions $token');
        }
      }
      for (final literal in bannedLiterals) {
        if (text.contains(literal)) {
          offenders.add('$rel hardcodes $literal');
        }
      }
    }
    expect(offenders, isEmpty, reason: 'glow 散落/写死即红：$offenders');
  });

  test('④ 字体资产体积白名单（path:bytes 锁，只减不增）', () {
    final whitelist = File(
      '${repo.path}${Platform.pathSeparator}tool'
      '${Platform.pathSeparator}ci_guards'
      '${Platform.pathSeparator}font_budget_whitelist.txt',
    );
    expect(whitelist.existsSync(), isTrue, reason: '字体预算白名单缺失');
    final locked = <String, int>{};
    for (final line in whitelist.readAsLinesSync()) {
      final s = line.trim();
      if (s.isEmpty || s.startsWith('#')) continue;
      final rel = s.rpartitionBefore(':');
      final size = int.parse(s.substring(s.lastIndexOf(':') + 1));
      locked[rel] = size;
    }
    final fontsDir = Directory(
      '${repo.path}${Platform.pathSeparator}assets'
      '${Platform.pathSeparator}fonts',
    );
    final actual = <String, int>{};
    for (final entity in fontsDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.ttf')) continue;
      final rel = entity.path
          .split(Platform.pathSeparator)
          .skipWhile((p) => p != 'assets')
          .join('/');
      actual[rel] = entity.lengthSync();
    }
    for (final entry in actual.entries) {
      expect(
        locked.containsKey(entry.key),
        isTrue,
        reason: '未登记字体文件 ${entry.key}',
      );
      expect(
        entry.value,
        lessThanOrEqualTo(locked[entry.key]!),
        reason: '体积增长 ${entry.key}',
      );
    }
    for (final key in locked.keys) {
      expect(actual.containsKey(key), isTrue, reason: '白名单内文件消失 $key');
    }
  });
}

extension on String {
  String rpartitionBefore(String sep) => substring(0, lastIndexOf(sep));
}

Directory _repoRoot() {
  var dir = Directory.current;
  while (
      !File('${dir.path}${Platform.pathSeparator}pubspec.yaml').existsSync()) {
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('pubspec.yaml not found upward');
    }
    dir = parent;
  }
  return dir;
}
