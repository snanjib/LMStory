//  守卫 · Android 窗口 / 启动图底色必须与 `classic_palette.dart` 同源。
//
// ## 裁决原文（2026-09-22 复评）
//
// 「Android 窗口背景 → 改」：窗口背景对齐**默认外观**（classic 结构 + classic
// 配色）两档 —— 日间 `lightBg #F4F5F7`、夜间 `darkBg #0E1018`，两个
// `NormalTheme` 都钉对应值；新增 `drawable-night/launch_background.xml`
// 承载夜间值，`drawable`（含若存在的 `drawable-v21`）用日间值。
//
// ## 为什么要用测试锁住 XML
//
// 冷启动底色是**用户看到的第一个像素**，而它住在 `android/` 里、完全在
// Dart 类型系统之外：改 `classic_palette.dart` 不会让任何编译错误发生，
// 只会在真机上"闪一下不对的颜色"。本用例把两边读进来做等值断言，让
// 配色槽一改就红。
//
// 顺带锁死两条结构性约束：
//   · `drawable-night/` 必须存在（此前缺席 → 深色模式冷启动闪白）；
//   · 不得再出现 `?android:colorBackground` / `@android:color/white` 这类
//     「系统派生值 / 硬编码值」——它们把品牌底色交给外部决定。
//
// ## 关于 `drawable-v21`（**已入库**，硬校验）
//
// `android/app/src/main/res/drawable-v21/launch_background.xml` 曾长期被
// `.gitignore:72` 屏蔽（本机生成、不入库；Flutter 默认值是
// `?android:colorBackground`）。** 已把该行删除并让文件入库**：它不再「本机
// 有、干净克隆没有」，而是版本控制契约的一部分 —— 因此本守卫对它是**硬校验**
// （存在 + 同值），不再用「若存在才校验」的软口径。
//
// 为什么必须入库：干净克隆上若有 v21 变体却拿默认的 `?android:colorBackground`，
// 底色决定权就落回系统；而「本机修好、CI/同事机器上没有」正是冷启动闪色的温床。
// 注意「断言存在」前先 `git check-ignore -v <path>`：被屏蔽的资源在干净克隆上
// 本就不存在，守卫会误红 —— 这正是当初写软口径的原因，现在前提已消失。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/palettes/classic/classic_palette.dart';

const String _res = 'android/app/src/main/res';

/// `drawable-v21/launch_background.xml` 的路径（已入库，硬校验）。
const String _v21Path = '$_res/drawable-v21/launch_background.xml';

String _read(String path) {
  final f = File(path);
  expect(f.existsSync(), isTrue, reason: '资源文件缺失：$path');
  return _stripComments(f.readAsStringSync());
}

/// 去掉 XML 注释——注释里会**引用**被禁用的旧写法（作为改动说明），
/// 若不剥掉，「不得再用系统派生值」这类扫描会被自己的说明文字绊倒。
String _stripComments(String xml) =>
    xml.replaceAll(RegExp('<!--.*?-->', dotAll: true), '');

String _hexOf(Color c) {
  String h(double v) => (v * 255).round().toRadixString(16).padLeft(2, '0');
  return '#${h(c.r)}${h(c.g)}${h(c.b)}'.toUpperCase();
}

/// 从 `<style name="NormalTheme">` 块里取 `android:windowBackground` 的值。
String _normalThemeWindowBackground(String xml) {
  final block = RegExp(
    r'<style\s+name="NormalTheme"[^>]*>(.*?)</style>',
    dotAll: true,
  ).firstMatch(xml);
  expect(block, isNotNull, reason: 'NormalTheme 未找到');
  final item = RegExp(
    r'<item\s+name="android:windowBackground"\s*>\s*([^<\s]+)\s*</item>',
  ).firstMatch(block!.group(1)!);
  expect(item, isNotNull, reason: 'NormalTheme 里没有 android:windowBackground');
  return item!.group(1)!;
}

/// 从 `layer-list` 里取第一个 `<color android:color="…" />`。
String _launchDrawableColor(String xml) {
  final m = RegExp(
    r'<color\s+android:color="([^"]+)"\s*/>',
  ).firstMatch(xml);
  expect(m, isNotNull, reason: 'launch_background 里没有 <color> 项');
  return m!.group(1)!;
}

void main() {
  final lightBg = _hexOf(ClassicPaletteValues.lightBg);
  final darkBg = _hexOf(ClassicPaletteValues.darkBg);

  test('默认外观两档值与 classic_palette 单源一致（防配色槽改名后脱钩）', () {
    expect(lightBg, '#F4F5F7', reason: 'classic/日 bg 已改值 → 请同步 android 资源');
    expect(darkBg, '#0E1018', reason: 'classic/夜 bg 已改值 → 请同步 android 资源');
  });

  test('NormalTheme（窗口背景）日间档 = classic 日 bg', () {
    expect(
      _normalThemeWindowBackground(_read('$_res/values/styles.xml')),
      lightBg,
    );
  });

  test('NormalTheme（窗口背景）夜间档 = classic 夜 bg', () {
    expect(
      _normalThemeWindowBackground(_read('$_res/values-night/styles.xml')),
      darkBg,
    );
  });

  test('LaunchTheme 指向 @drawable/launch_background（两档一致）', () {
    for (final f in <String>[
      '$_res/values/styles.xml',
      '$_res/values-night/styles.xml',
    ]) {
      expect(
        _read(f),
        contains('@drawable/launch_background'),
        reason: '$f 的 LaunchTheme 未指向启动图',
      );
    }
  });

  test('启动图日间档：drawable 与 drawable-v21 都 = classic 日 bg', () {
    expect(
      _launchDrawableColor(_read('$_res/drawable/launch_background.xml')),
      lightBg,
    );
    // v21 变体已入库（放开 .gitignore 并纳入版本控制）——硬校验，
    // 不再「存在才校验」：它一旦脱钩，API 21+ 设备的冷启动就是错色。
    expect(
      File(_v21Path).existsSync(),
      isTrue,
      reason: '$_v21Path 已入库，缺失说明被删或被重新 ignore',
    );
    expect(
      _launchDrawableColor(_read(_v21Path)),
      lightBg,
      reason: 'drawable-v21 变体与日间值不一致',
    );
  });

  test('启动图夜间档存在且 = classic 夜 bg（堵住深色冷启动闪白）', () {
    expect(
      File('$_res/drawable-night/launch_background.xml').existsSync(),
      isTrue,
      reason: '缺少 drawable-night 变体 → 深色模式冷启动会闪一屏日间底色',
    );
    expect(
      _launchDrawableColor(_read('$_res/drawable-night/launch_background.xml')),
      darkBg,
    );
  });

  test('不得再用系统派生值 / 硬编码白（底色的决定权在本仓库）', () {
    // 五个文件全部入库（含 v21），一律硬校验存在性：漏一个就等于漏一条
    // 「底色可能被系统决定」的路径。
    final files = <String>[
      '$_res/values/styles.xml',
      '$_res/values-night/styles.xml',
      '$_res/drawable/launch_background.xml',
      _v21Path,
      '$_res/drawable-night/launch_background.xml',
    ];
    for (final f in files) {
      final xml = _read(f);
      expect(
        xml.contains('?android:colorBackground'),
        isFalse,
        reason: '$f 又用回了系统派生色（不可预测）',
      );
      expect(
        xml.contains('@android:color/white'),
        isFalse,
        reason: '$f 又用回了硬编码白',
      );
    }
  });
}
