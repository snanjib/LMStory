import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_palette.dart';
import 'package:lmstory/core/theme/system/palettes/bordeaux/bordeaux_palette.dart';
import 'package:lmstory/core/theme/system/palettes/classic/classic_palette.dart';
import 'package:lmstory/core/theme/system/structures/brutal/brutal_structure.dart';

/// 棱角交付缺陷守卫：
/// 1) q5 对比度守卫跑明暗两档四组合（chip 标签 / 输入 hint ≥4.5:1）；
/// 2) 按钮标签 onPrimary/primary ≥4.5:1（四组合）；
/// 3) 批A 表面接线防拆线（三件套源码锚点）；
/// 4) 装配零写入用户可见中文（i18n 纪律）。
void main() {
  double ratio(Color a, Color b) {
    double luminance(Color c) {
      double channel(double v) => v <= 0.04045
          ? v / 12.92
          : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
      return 0.2126 * channel(c.r) +
          0.7152 * channel(c.g) +
          0.0722 * channel(c.b);
    }

    final la = luminance(a);
    final lb = luminance(b);
    final lighter = la > lb ? la : lb;
    final darker = la > lb ? lb : la;
    return (lighter + 0.05) / (darker + 0.05);
  }

  const families = <String, LmPaletteFamily>{
    'classic': ClassicPaletteFamily(),
    'bordeaux': BordeauxPaletteFamily(),
  };

  for (final entry in families.entries) {
    for (final brightness in Brightness.values) {
      test('${entry.key} ${brightness.name}：棱角 chip 标签对比度 ≥4.5', () {
        final palette = entry.value.of(brightness);
        final theme = const BrutalStructure().assemble(palette, brightness);
        final chip = theme.chipTheme;

        // 未选中：ink on surfaceVariant。
        expect(
          ratio(chip.labelStyle!.color!, chip.backgroundColor!),
          greaterThanOrEqualTo(4.5),
          reason: '${entry.key} ${brightness.name} 未选中 chip',
        );
        // 选中：ink on primaryDim@surfaceVariant 合成。
        final selectedBg = Color.alphaBlend(
          chip.selectedColor!,
          palette.surfaceVariant,
        );
        expect(
          ratio(chip.secondaryLabelStyle!.color!, selectedBg),
          greaterThanOrEqualTo(4.5),
          reason: '${entry.key} ${brightness.name} 选中 chip',
        );
      });

      test('${entry.key} ${brightness.name}：输入 hint 与按钮标签对比度 ≥4.5', () {
        final palette = entry.value.of(brightness);
        final theme = const BrutalStructure().assemble(palette, brightness);

        // hint：faint on surface（brutal 输入底=surface 白纸）。
        expect(
          ratio(
            theme.inputDecorationTheme.hintStyle!.color!,
            theme.inputDecorationTheme.fillColor!,
          ),
          greaterThanOrEqualTo(4.5),
          reason: '${entry.key} ${brightness.name} hint/surface',
        );

        // 按钮标签：onPrimary（foregroundColor）on primary（backgroundColor）。
        // 组件主题的 textStyle 不带 color（颜色走 foregroundColor 通道）。
        final fg = theme.filledButtonTheme.style!.foregroundColor!.resolve({})!;
        final bg = theme.filledButtonTheme.style!.backgroundColor!.resolve({})!;
        expect(
          ratio(fg, bg),
          greaterThanOrEqualTo(4.5),
          reason: '${entry.key} ${brightness.name} 按钮标签/primary',
        );
      });
    }
  }

  test('批A 接线防拆线：三件套经组件接口分发', () {
    final anchors = <String, List<String>>{
      'lib/features/chat/presentation/widgets/sidebar_session_item.dart': [
        'context.lmUi.sessionRow(',
      ],
      'lib/features/chat/presentation/pages/home_page.dart': [
        'context.lmUi.entryCard(',
      ],
      'lib/features/settings/presentation/widgets/adaptive_setting_card.dart': [
        'context.lmUi.settingCard(',
      ],
    };
    final repo = _repoRoot();
    for (final anchor in anchors.entries) {
      final file = File(
        '${repo.path}${Platform.pathSeparator}${anchor.key.replaceAll('/', Platform.pathSeparator)}',
      );
      expect(file.existsSync(), isTrue, reason: '${anchor.key} 消失？');
      final text = file.readAsStringSync();
      for (final token in anchor.value) {
        expect(
          text,
          contains(token),
          reason: '${anchor.key} 的批A 分流锚点 $token 被拆线？',
        );
      }
    }
  });

  test('装配层零用户可见中文（i18n 纪律，brutal 子树源码扫描）', () {
    final repo = _repoRoot();
    final brutalDir = Directory(
      '${repo.path}${Platform.pathSeparator}lib'
      '${Platform.pathSeparator}core'
      '${Platform.pathSeparator}theme'
      '${Platform.pathSeparator}system'
      '${Platform.pathSeparator}structures'
      '${Platform.pathSeparator}brutal',
    );
    final cjk = RegExp(r'[\u4e00-\u9fff]');
    for (final file in brutalDir.listSync(recursive: true)) {
      if (file is! File || !file.path.endsWith('.dart')) continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final code = stripLineComments(lines[i]);
        if (cjk.hasMatch(code)) {
          fail('${file.path}#${i + 1} 出现代码级中文字面量');
        }
      }
    }
  });
}

/// 去掉 `//` 行注释后返回代码部分（块注释不处理——brutal 子树未使用）。
String stripLineComments(String line) {
  final idx = line.indexOf('//');
  return idx < 0 ? line : line.substring(0, idx);
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
