import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/meta/app_meta.dart';

/// 应用版本单源桥对账：kAppVersion 必须 == pubspec.yaml 的 version。
///
/// pubspec 是应用版本的唯一真源（构建工具链消费）；kAppVersion 是运行时
/// 显示面（诊断页版本行、Wiki 版本记录 intro）的唯一桥接常量。版本 bump
/// 时若只改 pubspec 漏改常量，本测试在 CI 即红——与 wiki 计数锁同型的
/// 「文案数字 = 实物」对账（读源文件先例同 wiki_counts_lock_test）。
void main() {
  test('kAppVersion == pubspec.yaml version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match =
        RegExp(r'^version:\s*(\S+)\s*$', multiLine: true).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml 中未找到 version: 行');

    final pubspecVersion = match!.group(1)!;
    expect(
      kAppVersion,
      pubspecVersion,
      reason: 'kAppVersion（$kAppVersion）与 pubspec.yaml version（$pubspecVersion）'
          ' 不一致——版本 bump 时须同步 lib/core/meta/app_meta.dart 这一常量，'
          ' 否则诊断页版本行与 Wiki 版本记录显示旧版本号',
    );
  });
}
