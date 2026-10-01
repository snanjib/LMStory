import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/palettes/classic/classic_palette.dart';
import 'package:lmstory/core/theme/system/structures/classic/classic_structure.dart';

import '../../test_helpers/dart_source.dart';

///  守卫 · `ClassicStructure` 的明暗**不再各写一份复制体**。
///
/// ## 背景（复评 ，最后一处未闭合的复制体）
///
/// 历史形态是 `_light()` / `_dark()` 两个各 ~330 行的 `ThemeData`，20 个组件
/// 主题逐字节重复两遍（本文件曾有 699 行）。改一处配色槽要记得改两处，漏掉
/// 一处只有单档走样，且**只有 golden 抓得到**——这是纯结构债，行为上是零变化。
///
/// ## 两条不变量
///
/// 1. **骨架唯一（结构）** —— 剥掉注释后，源码里裸 `ThemeData(` 只允许出现
///    一次；`assemble` 的明暗两支都经同一个 `_theme`。这条是机械保证：
///    一旦有人把某个主题按明暗抄成两份，计数立刻变 2。
/// 2. **差异只有两项（行为）** —— 用**同一个 palette** 分别按 light / dark 装配
///    （`assemble` 是公开入口，可直接喂同一个 palette），断言骨架 `_theme` 显式
///    写下的那一组主题**除 `brightness` 与 `colorScheme` 外全部相等**。
///
/// 第 2 条刻意只比**显式写下的那 20 项**：`ThemeData` 还有一大堆由
/// `brightness` / `colorScheme` 内部派生的字段（`iconTheme` / `sliderTheme` /
/// `listTileTheme` …），它们**理应**两档不同，不该进这个断言。
///
/// 含 `WidgetStateProperty` 闭包的主题（`navigationBarTheme` / `switchTheme` /
/// 四类按钮主题）不能直接 `==`——`resolveWith(...)` 每次调用都是新闭包，`==` 是
/// 同一性比较。这里按**探针状态逐个 resolve** 后比较，闭包主题因此也在覆盖内，
/// 不留「改了一处也不会红」的缺口。
///
/// 逐像素的验收另在 `appearance_visual_parity_test.dart`（8 张 parity golden）。
void main() {
  const structure = ClassicStructure();
  // 同一个 palette 喂两档：palette 本身随明暗不同，只有固定它才能单独考察
  // 「骨架」是否随 brightness 分叉。
  final palette = const ClassicPaletteFamily().of(Brightness.light);
  final light = structure.assemble(palette, Brightness.light);
  final dark = structure.assemble(palette, Brightness.dark);

  final source = File(
    'lib/core/theme/system/structures/classic/classic_structure.dart',
  ).readAsStringSync();

  group('骨架唯一（结构契约）', () {
    test('剥注释后裸 ThemeData( 只出现一次', () {
      final code = stripDartComments(source);
      final count = RegExp(
        r'(?<![A-Za-z_])ThemeData\(',
      ).allMatches(code).length;
      expect(
        count,
        1,
        reason: '明暗又分叉成两份复制体了——共用骨架必须只有一个 ThemeData( '
            '构造点（历史教训：复制体改一处漏一处，只有 golden 抓得到）',
      );
    });

    test('assemble 的明暗两支都经 _theme，且不再有按档分叉的构造器', () {
      final code = stripDartComments(source);
      expect(
        code.contains('return _theme('),
        isTrue,
        reason: 'assemble 必须把差异交给 _theme，而不是自己分叉',
      );
      for (final banned in <String>['ThemeData _light(', 'ThemeData _dark(']) {
        expect(
          code.contains(banned),
          isFalse,
          reason: '重新出现了按明暗分叉的主题构造器 `$banned`',
        );
      }
      expect(
        code.contains('_difference('),
        isTrue,
        reason: '两档差异必须收敛在 _difference（差异表）里，便于评审时一眼看全',
      );
    });
  });

  group('差异只有 brightness / colorScheme（行为）', () {
    test('brightness 与 colorScheme 确实按档不同', () {
      expect(light.brightness, Brightness.light);
      expect(dark.brightness, Brightness.dark);
      expect(light.colorScheme.brightness, Brightness.light);
      expect(dark.colorScheme.brightness, Brightness.dark);
    });

    test('值语义组件主题：两档逐项相等', () {
      for (final (label, pick) in _valueSemanticThemes) {
        expect(
          pick(dark),
          pick(light),
          reason: '$label 随明暗变了——它不在差异表里，说明它被抄成了两份',
        );
      }
    });

    test('页面过渡配方：两档平台覆盖与委派类型一致', () {
      // `lmPageTransitionsTheme` 每次调用都新建 builder 实例（且 `scrim` 是运行期
      // 色值，无法 const 化），`PageTransitionsTheme.==` 因此过不去——按
      // 「覆盖了哪些平台 + 委派给哪类 builder」比，足以抓住「只给一档补了过渡」。
      final l = light.pageTransitionsTheme;
      final d = dark.pageTransitionsTheme;
      expect(d.builders.keys.toSet(), l.builders.keys.toSet());
      for (final platform in l.builders.keys) {
        expect(
          d.builders[platform].runtimeType,
          l.builders[platform].runtimeType,
          reason: '$platform 的过渡 builder 类型两档不一致',
        );
      }
    });

    test('闭包主题：按探针状态 resolve 后两档相等', () {
      for (final (label, resolve) in _statefulProbes) {
        for (final states in _probeStates) {
          expect(
            resolve(dark, states),
            resolve(light, states),
            reason: '$label 在 $states 下两档不一致',
          );
        }
      }
    });

    test('四类按钮主题：遮掉 side 闭包后相等，且 side 按状态解析也相等', () {
      for (final (label, pick) in _buttonThemes) {
        final l = pick(light);
        final d = pick(dark);
        expect(
          _maskSide(d),
          _maskSide(l),
          reason: '$label 除 side 外的样式两档不一致',
        );
        for (final states in _probeStates) {
          expect(
            d.side?.resolve(states),
            l.side?.resolve(states),
            reason: '$label.side 在 $states 下两档不一致',
          );
        }
      }
    });
  });
}

/// 探针状态：覆盖 idle / hover / pressed / focused / disabled。
const _probeStates = <Set<WidgetState>>[
  <WidgetState>{},
  <WidgetState>{WidgetState.hovered},
  <WidgetState>{WidgetState.pressed},
  <WidgetState>{WidgetState.focused},
  <WidgetState>{WidgetState.disabled},
];

/// `_theme` 显式写下的**值语义**主题（字段全是值/静态实例，`==` 可靠）。
///
/// 两个刻意排除项：
///
/// - `fontFamily`：`ThemeData` 仍接受同名构造参数，但**不再暴露同名 getter**
///   （已并入 `textTheme`），读不回来。
/// - `textTheme`：**派生字段**。`ThemeData` 只把我们给的 9 个槽 merge 到明暗
///   各自的 `Typography`（`blackMountainView` / `whiteMountainView`）基线上，
///   未设的槽（`displayLarge` …）以及**继承的文本色**都随明暗变——它理应两档
///   不同，不是复制体的证据。两档文本的一致性由 parity golden 覆盖。
final _valueSemanticThemes = <(String, Object? Function(ThemeData))>[
  ('scaffoldBackgroundColor', (t) => t.scaffoldBackgroundColor),
  ('splashFactory', (t) => t.splashFactory),
  ('cardTheme', (t) => t.cardTheme),
  ('appBarTheme', (t) => t.appBarTheme),
  ('dialogTheme', (t) => t.dialogTheme),
  ('bottomSheetTheme', (t) => t.bottomSheetTheme),
  ('snackBarTheme', (t) => t.snackBarTheme),
  ('dividerTheme', (t) => t.dividerTheme),
  ('inputDecorationTheme', (t) => t.inputDecorationTheme),
  ('chipTheme', (t) => t.chipTheme),
  ('floatingActionButtonTheme', (t) => t.floatingActionButtonTheme),
  ('tabBarTheme', (t) => t.tabBarTheme),
  ('progressIndicatorTheme', (t) => t.progressIndicatorTheme),
];

/// 含 `WidgetStateProperty` 闭包、必须按状态 resolve 的主题。
final _statefulProbes =
    <(String, Object? Function(ThemeData, Set<WidgetState>))>[
  (
    'navigationBarTheme.iconTheme',
    (t, s) => t.navigationBarTheme.iconTheme?.resolve(s),
  ),
  (
    'navigationBarTheme.labelTextStyle',
    (t, s) => t.navigationBarTheme.labelTextStyle?.resolve(s),
  ),
  ('switchTheme.thumbColor', (t, s) => t.switchTheme.thumbColor?.resolve(s)),
  ('switchTheme.trackColor', (t, s) => t.switchTheme.trackColor?.resolve(s)),
];

/// 四类按钮主题（样式对象里有 `side` 闭包）。
final _buttonThemes = <(String, ButtonStyle Function(ThemeData))>[
  ('filledButtonTheme', (t) => t.filledButtonTheme.style!),
  ('elevatedButtonTheme', (t) => t.elevatedButtonTheme.style!),
  ('textButtonTheme', (t) => t.textButtonTheme.style!),
  ('outlinedButtonTheme', (t) => t.outlinedButtonTheme.style!),
];

/// 把 `side` 换成常量 `WidgetStatePropertyAll(null)`，让 [ButtonStyle] 的 `==`
/// 不被「每次调用都新建的闭包」绊倒（其余字段仍是原样比较）。
ButtonStyle _maskSide(ButtonStyle style) => style.copyWith(
      side: const WidgetStatePropertyAll<BorderSide?>(null),
    );
