//  守卫 · classic 四类按钮全态 elevation = 0（真扁平），且 hover 反馈不消失。
//
// ## 裁决原文（2026-09-22 复评）
//
// 「classic 按钮 elevation → 钉 0，做真扁平」：`filledButtonTheme` 加 elevation
// 钉 0，**全态**（hover/pressed/disabled）；其余三类按钮同口径对齐。
// **hover 反馈必须不消失**（classic 本来就有面色 Δ15–20 的可感知反馈）。
//
// ## 为什么必须钉住「全态」
//
//  的 `FilledButton` 在 `_FilledButtonDefaultsM3.elevation` 里把 hover
// elevation 从 0 抬到 **1**（`filled_button.dart`）。而 `ButtonStyle.elevation`
// 是 `WidgetStateProperty`——只写 `elevation: 0` 是**全态**生效的（会包成
// `WidgetStatePropertyAll`），但一旦有人为了别的目的改成 `WidgetStateProperty
// .resolveWith(...)`，就可能只在 rest 生效。故本用例逐态 resolve，而不是只读
// `style.elevation` 的静态值。
//
// 后果（实测）：classic 夜间 FilledButton 悬停时圆角外侧像素从页面底色
// 变成纯黑（Δ247）——凭空长出一道 `colorScheme.shadow` 阴影。钉 0 后这道
// 阴影消失，反馈回到**面色**。
//
// ## 像素侧锁两条
//
// 1. **悬停不得在按钮外产生任何像素**（Δ<8）——「扁平」的可证伪形式：
//    没有阴影 → 按钮边界之外一个像素都不许动。
// 2. **悬停面色仍在**（按钮内 Δmax ≥15）——防止「为了扁平把反馈一起删了」。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';

const double _pixelRatio = 2;
const Size _surface = Size(800, 600);
const int _changeThreshold = 8;
const Duration _themeSettle = Duration(milliseconds: 400);

/// classic 四类按钮。
const List<String> _types = <String>[
  'filled',
  'elevated',
  'outlined',
  'text',
];

///  里**默认就带非零 elevation** 的只有这两类；其余两类的默认全态为 0，
/// 所以它们不接线也不算漏。
const Set<String> _needsWiring = {'filled', 'elevated'};

const List<WidgetState> _states = <WidgetState>[
  WidgetState.hovered,
  WidgetState.pressed,
  WidgetState.disabled,
  WidgetState.focused,
  WidgetState.selected,
];

ButtonStyle? _styleOf(ThemeData t, String type) => switch (type) {
      'filled' => t.filledButtonTheme.style,
      'elevated' => t.elevatedButtonTheme.style,
      'outlined' => t.outlinedButtonTheme.style,
      _ => t.textButtonTheme.style,
    };

String _stateName(WidgetState s) => s.name.isEmpty ? s.toString() : s.name;

void main() {
  // ── ① 主题层：全态 elevation = 0 ───────────────────────────────────
  test('四类按钮全态 elevation 钉 0（四组合 × 明暗）', () {
    for (final structure in <String>['classic', 'glass']) {
      for (final palette in <String>['classic', 'bordeaux']) {
        for (final brightness in Brightness.values) {
          final theme = ThemeCatalog.assemble(
            LmAppearance(structureId: structure, paletteId: palette),
            brightness,
          );
          final tag = '$structure/$palette/${brightness.name}';

          for (final type in _types) {
            final prop = _styleOf(theme, type)?.elevation;
            if (prop == null) {
              expect(
                _needsWiring.contains(type),
                isFalse,
                reason: '[$tag] $type 未接 elevation → 会走 M3 默认'
                    ' （filled hover 抬 1 / elevated rest 1），扁平口径失效',
              );
              continue;
            }
            // rest（空集）与全六态都必须为 0。
            expect(
              prop.resolve(<WidgetState>{}),
              0.0,
              reason: '[$tag] $type rest',
            );
            for (final s in _states) {
              expect(
                prop.resolve(<WidgetState>{s}),
                0.0,
                reason: '[$tag] $type ${_stateName(s)} 态 elevation 非 0',
              );
            }
          }
        }
      }
    }
  });

  // ── ② FAB 是**显式例外**：浮起是它成立的条件 ────────────────────────
  test('FAB 仍保留 elevation（口径外例外，不许顺手抹平）', () {
    for (final brightness in Brightness.values) {
      final theme = ThemeCatalog.assemble(
        const LmAppearance(),
        brightness,
      );
      // `FloatingActionButtonThemeData.elevation` 是裸 `double`（不是
      // WidgetStateProperty），故这里直接读值。
      final fab = theme.floatingActionButtonTheme.elevation;
      expect(fab, isNotNull, reason: 'FAB elevation 未接线');
      expect(
        fab,
        greaterThan(0),
        reason: '${brightness.name} FAB 被抹平了 — 浮起是 FAB 的成立条件',
      );
    }
  });

  // ── ③ 像素：悬停不越界 + 面色反馈仍在 ──────────────────────────────
  testWidgets('classic 按钮悬停：按钮外零像素变化、按钮内面色 Δ≥15', (tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final lines = <String>[];
    for (final palette in <String>['classic', 'bordeaux']) {
      for (final brightness in Brightness.values) {
        final theme = ThemeCatalog.assemble(
          LmAppearance(paletteId: palette),
          brightness,
        );
        final tag = 'classic/$palette/${brightness.name}';

        for (final type in _types) {
          final boundaryKey = GlobalKey();
          final buttonKey = GlobalKey();
          await _pump(tester, theme, boundaryKey, _button(type, buttonKey));
          final rest = await _shoot(tester, boundaryKey);

          final rect = tester.getRect(find.byKey(buttonKey));
          final mouse = await _hoverAt(tester, rect.center);
          final hover = await _shoot(tester, boundaryKey);
          await mouse.removePointer();

          // 按钮内：面色必须变（反馈不消失）。
          final inside = _delta(
            _at(rest, Offset(rect.left + 6, rect.center.dy)),
            _at(hover, Offset(rect.left + 6, rect.center.dy)),
          );

          // 按钮外：四角斜外 4px —— 阴影会在这里出现（旧缺陷 Δ247 的位置）。
          var outside = 0;
          for (final p in <Offset>[
            rect.topLeft - const Offset(5, 5),
            Offset(rect.right + 5, rect.top - 5),
            Offset(rect.left - 5, rect.bottom + 5),
            rect.bottomRight + const Offset(5, 5),
          ]) {
            outside = math.max(outside, _delta(_at(rest, p), _at(hover, p)));
          }

          lines.add('$tag $type inside=$inside outside=$outside');
          // 裁决点名的「classic 按钮已有面色 Δ15–20」说的是 FilledButton；
          // 其余三类只按  同款判据（Δ8）要求「反馈还在」。
          final need = type == 'filled' ? 15 : _changeThreshold;
          expect(
            inside,
            greaterThanOrEqualTo(need),
            reason: '[$tag] $type 悬停面色反馈消失（inside Δ$inside < $need）',
          );
          expect(
            outside,
            lessThan(_changeThreshold),
            reason: '[$tag] $type 悬停越界：按钮外出现 Δ$outside 的像素'
                ' （elevation 未钉 0 → 悬停长阴影）',
          );
        }
      }
    }
    debugPrint('[T10-3] ${lines.join(' | ')}');
  });
}

// ── 夹具 ─────────────────────────────────────────────────────────────

Widget _button(String type, GlobalKey key) => switch (type) {
      'filled' => FilledButton(
          key: key,
          onPressed: () {},
          child: const Text('确认操作'),
        ),
      'elevated' => ElevatedButton(
          key: key,
          onPressed: () {},
          child: const Text('确认操作'),
        ),
      'outlined' => OutlinedButton(
          key: key,
          onPressed: () {},
          child: const Text('确认操作'),
        ),
      _ => TextButton(
          key: key,
          onPressed: () {},
          child: const Text('确认操作'),
        ),
    };

Future<void> _pump(
  WidgetTester tester,
  ThemeData theme,
  GlobalKey boundaryKey,
  Widget child,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Builder(
        builder: (ctx) => Scaffold(
          backgroundColor: ctx.lm.palette.bg,
          body: RepaintBoundary(
            key: boundaryKey,
            child: ColoredBox(
              color: ctx.lm.palette.bg,
              child: SizedBox(
                width: _surface.width,
                height: _surface.height,
                child: Center(child: child),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(_themeSettle);
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump();
}

Future<TestGesture> _hoverAt(WidgetTester tester, Offset at) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  await tester.pump();
  await mouse.moveTo(at);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return mouse;
}

Future<Uint8List> _shoot(WidgetTester tester, GlobalKey key) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  late Uint8List out;
  await tester.binding.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: _pixelRatio);
    final data = await image.toByteData();
    out = Uint8List.fromList(data!.buffer.asUint8List());
    image.dispose();
  });
  return out;
}

(int, int, int) _at(Uint8List img, Offset p) {
  final width = (_surface.width * _pixelRatio).round();
  final x = (p.dx * _pixelRatio).round().clamp(0, width - 1);
  final y = (p.dy * _pixelRatio).round().clamp(0, 1 << 20);
  final i = (y * width + x) * 4;
  return (img[i], img[i + 1], img[i + 2]);
}

int _delta((int, int, int) a, (int, int, int) b) => math.max(
      math.max((a.$1 - b.$1).abs(), (a.$2 - b.$2).abs()),
      (a.$3 - b.$3).abs(),
    );
