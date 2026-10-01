import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/palettes/bordeaux/bordeaux_palette.dart';
import 'package:lmstory/core/theme/system/structures/brutal/brutal_factories.dart';
import 'package:lmstory/core/theme/system/structures/brutal/brutal_materials.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';

/// 棱角红线守卫（常驻测试，不靠自觉）。
///
/// ① 阴影公式守卫（签名实现的有效守卫）：BrutalButton 的阴影必须
///    offset(4,4)·blur0·spread0——删掉或改掉 BrutalMaterials.shadow 的
///    签名实现本守卫即红；
/// ② 按压同步守卫：按压位移 (4,4) 发生时阴影偏移同步归零（hover
///    预位移 (2,2) 时阴影仍 (4,4)）；
/// ③ 禁渐变扫描：brutal 子树源码零 gradient；
/// ④ 禁 blur 扫描：brutal 子树源码零 BackdropFilter / ImageFilter /
///    blurRadius 字面量（阴影 blur 恒 0 由公式保证，无需显式传参）；
/// ⑤ 减弱动态：位移补间不挂载（直接终态）；brutal 子树零循环动效。
void main() {
  setUp(() {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  });
  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  final repo = _repoRoot();
  final brutalDir = Directory(
    '${repo.path}${Platform.pathSeparator}lib'
    '${Platform.pathSeparator}core'
    '${Platform.pathSeparator}theme'
    '${Platform.pathSeparator}system'
    '${Platform.pathSeparator}structures'
    '${Platform.pathSeparator}brutal',
  );

  List<File> dartFilesUnder(Directory dir) => dir
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList();

  Future<void> pumpButton(
    WidgetTester tester, {
    bool reduce = false,
  }) async {
    final theme = ThemeCatalog.assemble(
      const LmAppearance(structureId: 'brutal', paletteId: 'bordeaux'),
      Brightness.dark,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: reduce,
              accessibleNavigation: false,
            ),
            child: const Scaffold(
              body: Center(
                child: BrutalButton(label: 'OK', onPressed: _noop),
              ),
            ),
          ),
        ),
      ),
    );
  }

  AnimatedContainer buttonFace(WidgetTester tester) => tester.widget(
        find
            .descendant(
              of: find.byType(BrutalButton),
              matching: find.byType(AnimatedContainer),
            )
            .first,
      );

  testWidgets('① 阴影公式：rest 阴影 offset(4,4)·blur0·spread0（签名有效守卫）',
      (tester) async {
    await pumpButton(tester);
    final palette = const BordeauxPaletteFamily().of(Brightness.dark);
    final decoration = buttonFace(tester).decoration! as BoxDecoration;
    final shadow = decoration.boxShadow!.single;
    expect(shadow.color, BrutalMaterials.frameOf(palette), reason: '阴影色=结构墨色');
    expect(shadow.offset, const Offset(4, 4));
    expect(shadow.blurRadius, 0, reason: '禁 blur：阴影是几何色块');
    expect(shadow.spreadRadius, 0);
  });

  testWidgets('② 按压同步：元素平移 (4,4) 且阴影偏移归零；hover 预位移 (2,2)', (tester) async {
    await pumpButton(tester);
    final center = tester.getCenter(find.byType(BrutalButton));

    // hover：mouse 指针从场外移入 → 预位移 (2,2)，阴影不动。
    final mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    await tester.pump();
    await mouse.moveTo(center);
    await tester.pump(LmMotion.hover);
    var face = buttonFace(tester);
    expect(face.transform?.entry(0, 3), 2, reason: 'hover 预位移 tx=2');
    expect(face.transform?.entry(1, 3), 2, reason: 'hover 预位移 ty=2');
    var shadow = (face.decoration! as BoxDecoration).boxShadow!.single;
    expect(shadow.offset, const Offset(4, 4), reason: 'hover 阴影不动');

    // pressed：位移 (4,4) 且阴影偏移归零（按进纸里）。
    await mouse.down(center);
    await tester.pump();
    await tester.pump(LmMotion.press);
    face = buttonFace(tester);
    expect(face.transform?.entry(0, 3), 4, reason: '按压位移 tx=4');
    expect(face.transform?.entry(1, 3), 4, reason: '按压位移 ty=4');
    shadow = (face.decoration! as BoxDecoration).boxShadow!.single;
    expect(shadow.offset, Offset.zero, reason: '按压时阴影偏移必须同步归零');

    await mouse.up();
    await mouse.removePointer();
  });

  test('③ 禁渐变扫描：brutal 子树零 gradient', () {
    final offenders = <String>[];
    for (final file in dartFilesUnder(brutalDir)) {
      final text = file.readAsStringSync();
      for (final token in [
        'LinearGradient',
        'RadialGradient',
        'SweepGradient',
      ]) {
        if (text.contains(token)) {
          offenders.add('${file.path} mentions $token');
        }
      }
    }
    expect(offenders, isEmpty, reason: '禁渐变红线：$offenders');
  });

  test('④ 禁 blur 扫描：brutal 子树零 BackdropFilter / ImageFilter / blurRadius', () {
    final offenders = <String>[];
    for (final file in dartFilesUnder(brutalDir)) {
      final text = file.readAsStringSync();
      // 只匹配调用形态（`blurRadius:`）；文档注释里「blurRadius == 0」
      // 的红线表述不是调用。
      for (final token in ['BackdropFilter', 'ImageFilter', 'blurRadius:']) {
        if (text.contains(token)) {
          offenders.add('${file.path} mentions $token');
        }
      }
    }
    expect(offenders, isEmpty, reason: '禁 blur 红线：$offenders');
  });

  testWidgets('⑤a 减弱动态：位移补间不挂载（直接终态）', (tester) async {
    await pumpButton(tester, reduce: true);
    expect(
      find.descendant(
        of: find.byType(BrutalButton),
        matching: find.byType(AnimatedContainer),
      ),
      findsNothing,
      reason: '减弱动态下位移补间不得挂载（S5）',
    );
  });

  testWidgets('⑤b 全动效：位移补间在位（对照断言）', (tester) async {
    await pumpButton(tester);
    expect(
      find.descendant(
        of: find.byType(BrutalButton),
        matching: find.byType(AnimatedContainer),
      ),
      findsOneWidget,
      reason: '全动效下按压位移补间应在位',
    );
  });

  test('⑤c brutal 子树零循环动效（repeat 不得出现）', () {
    for (final file in dartFilesUnder(brutalDir)) {
      expect(
        file.readAsStringSync(),
        isNot(contains('repeat(')),
        reason: '${file.path} 禁循环动效',
      );
    }
  });
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

void _noop() {}
