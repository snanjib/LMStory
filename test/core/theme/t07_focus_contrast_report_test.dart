// classic 键盘焦点可见性：**先量后改**的证据夹具 + 对比度守卫。
//
// 判定口径：
// 「量出 classic 焦点指示对背景的对比度。达到 3:1（WCAG 2.4.7 门槛）就登记
//   结论不动；低于 3:1 才补硬环，并且**只在键盘焦点态生效**——不许把 classic
//   的默认观感改掉。」
//
// ## 测量口径
//
// 对 classic 结构显式接线的四类按钮（Filled / Elevated / Outlined / Text）
// 逐组合做**像素级**测量：同一控件在未聚焦与键盘聚焦
// （`FocusHighlightStrategy.alwaysTraditional`）两态各抓一张 RepaintBoundary
// 位图（pixelRatio 2），比对同一像素：
//
// - **指标 A（WCAG 2.2 SC 2.4.11 焦点指示对比度）**：聚焦态与未聚焦态在
//   **同一像素**上的对比度差。**这是焦点指示的正确度量**—— 观察到的
//   「均Δ≈20」只是它的低分辨率代理。
// - **指标 B（上述口径的字面度量）**：聚焦态指示器像素对页面底色的对比度。
//
// ## 为什么用「环带」而不是「全足迹」
//
// Material 的状态层（focusColor 12% 叠色）覆盖**整个按钮面**，其对比度变化
// 只有 ~1.2:1。若对全足迹取均值，这个无关的低对比区域会把环的强度平均掉，
// 得出「仍然不达标」的错误结论。SC 2.4.11 要求的是**指示器本身**（本项目 =
// 2px / 4px 的焦点环）达标，故本夹具把环带定义为「变化 ≥ 40 的像素」
// （Material 叠色实测 ≤ ~30，环带 ≥ ~190，两者分离干净）。
//
// ## before / after
//
// | | 指标 A 峰值 | 指标 A 环带均值 | 指标 B |
// |---|---|---|---|
// | before（仅有 Material 叠色） | 1.14–1.39:1（16 组全不达标） | 无环带 | 1.14–1.20:1 |
// | after（`LmFocusRing` 内环） | 7.90–18.11:1 | 6.08–16.40:1 | 见报告注 |
//
// 产物：`test_screenshots/night-2026-09-21/t07_focus_contrast_report.md`
// （gitignore）。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_focus_ring.dart';
import 'package:lmstory/core/theme/system/lm_palette.dart';
import 'package:lmstory/core/theme/system/palettes/bordeaux/bordeaux_palette.dart';
import 'package:lmstory/core/theme/system/palettes/classic/classic_palette.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';

const double _pixelRatio = 2;
const Size _surface = Size(800, 600);

/// WCAG 2.4.11 门槛。
const double _minContrast = 3;

/// 判定「像素发生变化」的阈值（max(R,G,B) 通道差），与  差分取证同值。
const int _changeThreshold = 8;

/// 环带阈值：Material 状态层实测变化 ≤ ~30，焦点环 ≥ ~190，取 40 分离两者。
const int _ringChangeThreshold = 40;

/// 环带像素数下限（pixelRatio 2）：44px 高按钮的 2px 环 ≈ 2.0k px，
/// 取 200 作为「确实存在一条 ≥2px 厚的环」的证据下限。
const int _minRingPx = 200;

const String _reportPath =
    'test_screenshots/night-2026-09-21/t07_focus_contrast_report.md';

typedef _Rgb = (int, int, int);

/// WCAG 相对亮度。
double _relativeLuminance(_Rgb c) {
  double channel(int v) {
    final s = v / 255.0;
    return s <= 0.03928
        ? s / 12.92
        : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * channel(c.$1) +
      0.7152 * channel(c.$2) +
      0.0722 * channel(c.$3);
}

/// WCAG 对比度（1.0 – 21.0）。
double _contrastRatio(_Rgb a, _Rgb b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

String _hex(_Rgb c) => '#${c.$1.toRadixString(16).padLeft(2, '0')}'
    '${c.$2.toRadixString(16).padLeft(2, '0')}'
    '${c.$3.toRadixString(16).padLeft(2, '0')}';

_Rgb _rgbOf(Color c) =>
    ((c.r * 255).round(), (c.g * 255).round(), (c.b * 255).round());

/// 抓取 [key] 处 RepaintBoundary 的原始 RGBA 像素（默认格式即 rawRgba）。
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

class _Measure {
  const _Measure({
    required this.footprintPx,
    required this.ringPx,
    required this.ringFocused,
    required this.ringUnfocused,
    required this.background,
    required this.maxChange,
    required this.contrastChangeFootprint,
    required this.contrastChangeRing,
    required this.contrastChangeMax,
    required this.contrastVsBackground,
  });

  final int footprintPx;
  final int ringPx;
  final _Rgb ringFocused;
  final _Rgb ringUnfocused;
  final _Rgb background;
  final int maxChange;

  /// 指标 A（全足迹均值）：含 Material 叠色，仅供对照（会被稀释）。
  final double contrastChangeFootprint;

  /// 指标 A（**环带**均值）：判定用指标。
  final double contrastChangeRing;

  /// 指标 A（峰值口径）。
  final double contrastChangeMax;

  /// 指标 B：聚焦态环带均值 对 页面底色。
  final double contrastVsBackground;

  bool get pass => ringPx >= _minRingPx && contrastChangeRing >= _minContrast;
}

_Measure _analyze(Uint8List unfocused, Uint8List focused, int imageWidth) {
  final fSum = <int>[0, 0, 0];
  final uSum = <int>[0, 0, 0];
  final rSumF = <int>[0, 0, 0];
  final rSumU = <int>[0, 0, 0];
  var footprint = 0;
  var ring = 0;
  var maxChange = 0;
  var bestChange = 0.0;

  for (var i = 0; i + 3 < focused.length; i += 4) {
    final f = <int>[focused[i], focused[i + 1], focused[i + 2]];
    final u = <int>[unfocused[i], unfocused[i + 1], unfocused[i + 2]];
    var change = 0;
    for (var k = 0; k < 3; k++) {
      change = math.max(change, (f[k] - u[k]).abs());
    }
    if (change < _changeThreshold) continue;
    footprint++;
    for (var k = 0; k < 3; k++) {
      fSum[k] += f[k];
      uSum[k] += u[k];
    }
    if (change > maxChange) maxChange = change;
    bestChange = math.max(
      bestChange,
      _contrastRatio((f[0], f[1], f[2]), (u[0], u[1], u[2])),
    );
    if (change >= _ringChangeThreshold) {
      ring++;
      for (var k = 0; k < 3; k++) {
        rSumF[k] += f[k];
        rSumU[k] += u[k];
      }
    }
  }

  // 页面底色取 (2,2)（按钮居中，四角必为 Scaffold 底）。
  final indexed = ((2 * imageWidth) + 2) * 4;
  final background = (
    unfocused[indexed],
    unfocused[indexed + 1],
    unfocused[indexed + 2],
  );

  _Rgb mean(List<int> sum, int n) =>
      n == 0 ? background : (sum[0] ~/ n, sum[1] ~/ n, sum[2] ~/ n);

  final ringFocused = mean(rSumF, ring);
  final ringUnfocused = mean(rSumU, ring);

  return _Measure(
    footprintPx: footprint,
    ringPx: ring,
    ringFocused: ringFocused,
    ringUnfocused: ringUnfocused,
    background: background,
    maxChange: maxChange,
    contrastChangeFootprint: _contrastRatio(
      mean(fSum, footprint),
      mean(uSum, footprint),
    ),
    contrastChangeRing:
        ring == 0 ? 1 : _contrastRatio(ringFocused, ringUnfocused),
    contrastChangeMax: bestChange,
    contrastVsBackground:
        ring == 0 ? 1 : _contrastRatio(ringFocused, background),
  );
}

void main() {
  const combos = <(String, Brightness)>[
    ('classic', Brightness.light),
    ('classic', Brightness.dark),
    ('bordeaux', Brightness.light),
    ('bordeaux', Brightness.dark),
  ];

  const controlNames = <String>[
    'FilledButton',
    'ElevatedButton',
    'OutlinedButton',
    'TextButton',
  ];

  LmPalette paletteOf(String familyId, Brightness brightness) =>
      (familyId == 'classic'
              ? const ClassicPaletteFamily()
              : const BordeauxPaletteFamily())
          .of(brightness);

  ThemeData themeOf(String familyId, Brightness brightness) =>
      ThemeCatalog.assemble(
        LmAppearance(paletteId: familyId),
        brightness,
      );

  Widget controlOf(String name, FocusNode node) => switch (name) {
        'FilledButton' => FilledButton(
            onPressed: () {},
            focusNode: node,
            child: const Text('确认操作'),
          ),
        'ElevatedButton' => ElevatedButton(
            onPressed: () {},
            focusNode: node,
            child: const Text('确认操作'),
          ),
        'OutlinedButton' => OutlinedButton(
            onPressed: () {},
            focusNode: node,
            child: const Text('确认操作'),
          ),
        _ => TextButton(
            onPressed: () {},
            focusNode: node,
            child: const Text('确认操作'),
          ),
      };

  setUp(() {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  });
  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
  });

  // ── 守卫①：焦点环**只在键盘焦点态**存在，默认（含 golden 基线）零变化 ──
  test('classic 四类按钮的焦点环只在 focused 态出现（默认观感零变化）', () {
    for (final (familyId, brightness) in combos) {
      final theme = themeOf(familyId, brightness);
      final palette = paletteOf(familyId, brightness);
      final tag = '$familyId/${brightness.name}';
      const none = <WidgetState>{};
      const focused = <WidgetState>{WidgetState.focused};

      final filled = theme.filledButtonTheme.style!.side!;
      expect(
        filled.resolve(none),
        isNull,
        reason: '$tag FilledButton 默认态不得有描边',
      );
      expect(
        filled.resolve(focused),
        LmFocusRing.solid(palette),
        reason: '$tag FilledButton focused 态应为 onPrimary 环',
      );

      final elevated = theme.elevatedButtonTheme.style!.side!;
      expect(
        elevated.resolve(none),
        isNull,
        reason: '$tag ElevatedButton 默认态不得有描边',
      );
      expect(elevated.resolve(focused), LmFocusRing.solid(palette));

      final text = theme.textButtonTheme.style!.side!;
      expect(
        text.resolve(none),
        isNull,
        reason: '$tag TextButton 默认态不得有描边',
      );
      expect(text.resolve(focused), LmFocusRing.plain(palette));

      final outlined = theme.outlinedButtonTheme.style!.side!;
      expect(
        outlined.resolve(none),
        LmFocusRing.outlinedIdle(palette),
        reason: '$tag OutlinedButton 默认描边须保持既有观感',
      );
      expect(outlined.resolve(focused), LmFocusRing.outlined(palette));
    }
  });

  // ── 守卫② + 报告：键盘聚焦时的实际像素对比度 ──
  testWidgets('classic 四类按钮键盘焦点指示对比度达标（≥3:1）并出报告', (tester) async {
    await tester.binding.setSurfaceSize(_surface);
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final buffer = StringBuffer()
      ..writeln('# T07-4 · classic 键盘焦点指示对比度（after）')
      ..writeln()
      ..writeln(
        '方法：像素级。同一控件在**未聚焦**与**键盘聚焦**（`FocusHighlightStrategy.alwaysTraditional`）两态各抓一张 RepaintBoundary 位图（pixelRatio ${_pixelRatio.toInt()}）。',
      )
      ..writeln()
      ..writeln(
        '- **指标 A**（WCAG 2.2 SC 2.4.11）：聚焦态与未聚焦态在**同一像素**上的对比度差；判定取**环带均值**（变化 ≥ $_ringChangeThreshold 的像素，与 Material 叠色的 ≤ ~30 分离）。',
      )
      ..writeln('- **指标 B**：聚焦态环带像素对页面底色的对比度。')
      ..writeln()
      ..writeln(
        '门槛：指标 A（环带）≥ ${_minContrast.toStringAsFixed(1)}:1，且环带像素数 ≥ $_minRingPx。',
      )
      ..writeln()
      ..writeln('---')
      ..writeln();

    for (final (familyId, brightness) in combos) {
      final palette = paletteOf(familyId, brightness);
      buffer
        ..writeln('## classic 结构 · $familyId / ${brightness.name}')
        ..writeln()
        ..writeln(
          'palette：bg=${_hex(_rgbOf(palette.bg))} '
          'primary=${_hex(_rgbOf(palette.primary))} '
          'onPrimary=${_hex(_rgbOf(palette.onPrimary))}',
        )
        ..writeln()
        ..writeln(
          '| 控件 | 足迹px | 环带px | 环带聚焦均值 | 环带未聚焦均值 | '
          '指标A(全足迹) | 指标A(环带) | 指标A(峰值) | 指标B | 判 |',
        )
        ..writeln('|---|---:|---:|---|---|---:|---:|---:|---:|---|');

      for (final name in controlNames) {
        final node = FocusNode(debugLabel: 't07-$name-$familyId');
        addTearDown(node.dispose);
        final shotKey = GlobalKey();

        await tester.pumpWidget(
          RepaintBoundary(
            key: shotKey,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: themeOf(familyId, brightness),
              home: Scaffold(
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: controlOf(name, node),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final unfocused = await _shoot(tester, shotKey);

        node.requestFocus();
        await tester.pumpAndSettle();
        final focused = await _shoot(tester, shotKey);
        node.unfocus();
        await tester.pumpAndSettle();

        final m = _analyze(
          unfocused,
          focused,
          (_surface.width * _pixelRatio).toInt(),
        );

        buffer.writeln(
          '| $name | ${m.footprintPx} | ${m.ringPx} | '
          '${_hex(m.ringFocused)} | ${_hex(m.ringUnfocused)} | '
          '${m.contrastChangeFootprint.toStringAsFixed(2)}:1 | '
          '${m.contrastChangeRing.toStringAsFixed(2)}:1 | '
          '${m.contrastChangeMax.toStringAsFixed(2)}:1 | '
          '${m.contrastVsBackground.toStringAsFixed(2)}:1 | '
          '${m.pass ? 'PASS' : 'FAIL'} |',
        );

        expect(
          m.ringPx,
          greaterThanOrEqualTo(_minRingPx),
          reason: '$familyId/${brightness.name} $name：未检出 ≥2px 厚的焦点环',
        );
        expect(
          m.contrastChangeRing,
          greaterThanOrEqualTo(_minContrast),
          reason: '$familyId/${brightness.name} $name：焦点环对比度变化低于 3:1',
        );
      }
      buffer.writeln();
    }

    buffer
      ..writeln('---')
      ..writeln()
      ..writeln('## 读表说明')
      ..writeln()
      ..writeln(
        '- **指标 B 只在透明底控件上有意义**：filled / elevated 的焦点环是画在按钮**填充**之上的内环，它对页面底色的对比度自然 ≈1:1；这**不是**缺陷——这两类控件的判定看指标 A（环带对填充）。',
      )
      ..writeln(
        '- 指标 A（全足迹）同样会被 Material 状态层稀释（≈1.5:1），故不作为判定依据。',
      )
      ..writeln(
        '- outlined 的环带像素数约为其他控件的 2 倍（4px vs 2px）：其既有描边占住最外 1.5px，环必须更宽才能形成 ≥2px 的**新增**变化带（SC 2.4.11 的厚度要求）。波尔多夜间尤甚——既有描边本就近白，只有新增带产生变化。',
      )
      ..writeln(
        '- 判定一律使用**指标 A（环带）**：它正是 SC 2.4.11 的「焦点指示器在聚焦态与未聚焦态之间的对比度差」。',
      )
      ..writeln(
        '- before（仅 Material 默认叠色、未接线前实测）：指标 A 峰值 **1.14–1.39:1**（16 组全不达标）。',
      );

    final report = buffer.toString();
    // ignore: avoid_print
    print(report);
    await tester.binding.runAsync<void>(() async {
      final f = File(_reportPath);
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(report);
    });
  });
}
