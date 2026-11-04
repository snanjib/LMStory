import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/palettes/bordeaux/bordeaux_palette.dart';
import 'package:lmstory/core/theme/system/palettes/classic/classic_palette.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_factories.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_surface.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';

import '../../../test_helpers/png_writer.dart';

///  守卫：**「两层路由同时可见」时，上层路由不得透出下层内容、不得留黑区**。
///
/// 背景（2026-09-22 真机缺陷，用户实测）：琉璃结构下左滑返回（Android
/// 系统返回手势）过程中，上层页面缩小成圆角浮板，**下层页面的卡片从它内部
/// 透出来**（两层内容叠印），屏幕左缘还出现**纯黑圆角空洞**。
///
/// 病根与  黑帧同族：琉璃结构下 `scaffoldBgOf` 一律返回透明，全部靠
/// `main.dart` 里**位于 Navigator 之下**的单张根场地幕布透色。
/// 「透明路由 + 单一祖先场地」这个假设只在**单层路由**下成立；
/// 预测式返回会把两层路由同时画出来（框架在过渡期把上层路由的
/// `overlayEntries.first.opaque` 置 false → 下层路由被重新构建并绘制），
/// 于是缩小的上层路由内部直接露出下层路由的内容 → 叠印；
/// 无绘制者覆盖的区域 → 黑区。
///
/// 修复方向（见 `lib/core/theme/system/lm_page_transitions.dart`）：
/// 让**每条路由自承载不透明场地**，不再依赖 Navigator 之下的祖先。
///
/// 判定口径（全部像素级、逐帧）：
/// - **叠印**：下层路由独有的「指纹色块」（`palette.accent`，占屏大半）不得
///   出现在上层路由卡片**内部**；
/// - **黑区**：整帧扫描不得出现 alpha≠255（无绘制者）或纯黑像素；
/// - **四组合 × 明暗**全部成立；classic 本来就正常（页面不透明），同样锁住。
void main() {
  const structures = <String>['classic', 'glass'];
  const paletteIds = <String>['classic', 'bordeaux'];

  for (final structureId in structures) {
    for (final paletteId in paletteIds) {
      for (final brightness in Brightness.values) {
        final tag = '${structureId}_${paletteId}__${brightness.name}';
        testWidgets('预测式返回：无叠印 / 无黑区 [$tag]', (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.android;
          try {
            final theme = ThemeCatalog.assemble(
              LmAppearance(structureId: structureId, paletteId: paletteId),
              brightness,
            );
            final palette = _paletteOf(paletteId, brightness);
            final glass = structureId == 'glass';

            await _pumpShell(tester, theme: theme, home: const _LowerPage());
            final steady = await _capture(tester);

            // 预置条件：指纹色必须与场地/上层色可分，否则用例无区分力。
            _expectDistinguishable(palette.accent, palette.bg, 'accent vs bg');
            _expectDistinguishable(
              palette.accent,
              palette.bgGlow,
              'accent vs bgGlow',
            );
            _expectDistinguishable(
              palette.accent,
              palette.primary,
              'accent vs primary',
            );

            await tester.tap(find.byKey(_kPush));
            await tester.pumpAndSettle();
            final upperContext = tester.element(find.byKey(_kUpperBody));

            // 契约①：路由的不透明承载随路由走。
            //   - 琉璃：路由子树内必须有场地（修复前只有根壳提供，修复后
            //     路由自承载；「无根壳也不裸奔」由下方独立用例锁死）；
            //   - 经典：页面本身不透明，不得出现透明底（不许改坏）。
            if (glass) {
              expect(
                GlassVenueScope.maybeOf(upperContext),
                isNotNull,
                reason: '[$tag] 被推入的路由子树内必须存在场地',
              );
            } else {
              expect(
                upperContext.scaffoldBgOf(theme.scaffoldBackgroundColor),
                isNot(Colors.transparent),
                reason: '[$tag] 经典结构路由不得退化为透明底',
              );
            }

            // 驱动系统返回手势（Android 预测式返回）。
            await _sendBackGesture(
                tester, 'startBackGesture', <String, dynamic>{
              'touchOffset': <double>[4, 400],
              'progress': 0.0,
              'swipeEdge': 0,
            });
            await _pumpFrames(tester);

            final lines = <String>[];
            final problems = <String>[];
            for (final stop in _kStops) {
              await _sendBackGesture(
                tester,
                'updateBackGestureProgress',
                <String, dynamic>{
                  'touchOffset': <double>[4 + stop * 410, 400],
                  'progress': stop,
                  'swipeEdge': 0,
                },
              );
              await _pumpFrames(tester);
              final frame = await _capture(tester);
              await _writeEvidence(
                tester,
                frame,
                '${tag}__p${(stop * 100).round()}',
              );

              // 卡片真实矩形（含过渡变换）——用它可以断言「是否真的缩小了」。
              final card = tester.getRect(find.byKey(_kUpperBody));
              final inner = card.deflate(6);
              final anchorBand = Rect.fromLTRB(
                inner.left,
                inner.top,
                inner.right,
                inner.top + 40,
              );

              final bleed = _countColor(frame, inner, palette.accent);
              final anchor = _countColor(frame, anchorBand, palette.primary);
              final holes = _countUnpainted(frame);
              final blacks = _countPureBlack(frame);
              final shrunk = card.width < steady.width - 2;

              lines.add(
                'p=${(stop * 100).round().toString().padLeft(2)}%: '
                'card=${card.width.toStringAsFixed(1)}x${card.height.toStringAsFixed(1)} '
                'shrunk=$shrunk bleed=$bleed anchor=$anchor '
                'holes=$holes blacks=$blacks',
              );

              if (!shrunk) {
                problems.add('p=${(stop * 100).round()}% 卡片未缩小（预测式返回未生效）');
              }
              if (bleed > _kPixelNoise) {
                problems.add(
                  'p=${(stop * 100).round()}% 卡片内部出现 $bleed 个下层路由指纹像素 → 叠印',
                );
              }
              if (anchor == 0) {
                problems.add('p=${(stop * 100).round()}% 卡片内容缺席（判定锚点丢失）');
              }
              if (holes > _kPixelNoise) {
                problems
                    .add('p=${(stop * 100).round()}% 出现 $holes 个无绘制者像素 → 黑区');
              }
              if (blacks > _kPixelNoise) {
                problems
                    .add('p=${(stop * 100).round()}% 出现 $blacks 个纯黑像素 → 黑区');
              }
            }

            if (problems.isNotEmpty) {
              fail(
                '[$tag] 预测式返回逐帧判定失败：\n'
                '  - ${problems.join('\n  - ')}\n'
                '实测：\n  ${lines.join('\n  ')}',
              );
            }
            debugPrint('[T09][$tag] ${lines.join(' | ')}');

            // 收尾：取消手势须回到上层页面（不破坏既有导航语义）。
            await _sendBackGesture(
              tester,
              'cancelBackGesture',
              <String, dynamic>{},
            );
            await tester.pumpAndSettle();
            expect(find.byKey(_kUpperBody), findsOneWidget);
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        });
      }
    }
  }

  // ── 契约①的强形式：没有根场地壳时，路由仍须自承载不透明底。 ──────────
  testWidgets('被推入的路由自承载场地（无根场地壳也不裸奔）', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final theme = ThemeCatalog.assemble(
        const LmAppearance(structureId: 'glass', paletteId: 'bordeaux'),
        Brightness.dark,
      );
      // rootVenue: false —— 复刻「Navigator 之下没有场地壳」的环境
      // （自建 Overlay / 独立 Navigator / 未来若移除根壳）。
      await _pumpShell(
        tester,
        theme: theme,
        home: const _LowerPage(),
        rootVenue: false,
      );
      await tester.tap(find.byKey(_kPush));
      await tester.pumpAndSettle();

      final upperContext = tester.element(find.byKey(_kUpperBody));
      expect(
        GlassVenueScope.maybeOf(upperContext),
        isNotNull,
        reason: '无根场地壳时，被推入的路由必须自带场地',
      );
      expect(
        upperContext.scaffoldBgOf(theme.scaffoldBackgroundColor),
        Colors.transparent,
        reason: '路由自带场地后，页面 Scaffold 应透出本路由的场地',
      );

      // 像素层面：整帧不得有无绘制者区域 / 纯黑区。
      final frame = await _capture(tester);
      final holes = _countUnpainted(frame);
      final blacks = _countPureBlack(frame);
      expect(holes, lessThanOrEqualTo(_kPixelNoise), reason: 'holes=$holes');
      expect(blacks, lessThanOrEqualTo(_kPixelNoise), reason: 'blacks=$blacks');
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  // ── 稳态观感零变化：逐路由自绘场地 ≡ 单张根场地（逐像素等价）。 ────────
  testWidgets('逐路由场地与单张根场地在稳态下逐像素等价', (tester) async {
    final lines = <String>[];
    for (final paletteId in paletteIds) {
      for (final brightness in Brightness.values) {
        final theme = ThemeCatalog.assemble(
          LmAppearance(structureId: 'glass', paletteId: paletteId),
          brightness,
        );
        final entry =
            theme.pageTransitionsTheme.builders[TargetPlatform.windows]!;
        // 预置：装配表里必须真的有装饰器，否则 (b) 与 (a) 同口径 → 假绿。
        expect(
          entry.runtimeType.toString(),
          contains('Venue'),
          reason: '路由场地装饰器未进入装配表 → 本用例的对照口径失效',
        );

        // (a) 当前装配（逐路由场地）
        await _pumpShell(tester, theme: theme, home: const _PlainPage());
        final withRouteVenue = await _capture(tester);

        // (b) 旧口径参考：把路由场地装饰器摘掉（场地只来自根壳）。
        final legacy = theme.copyWith(
          pageTransitionsTheme: _legacyTransitionsTheme(theme),
        );
        await _pumpShell(tester, theme: legacy, home: const _PlainPage());
        final rootVenueOnly = await _capture(tester);

        final diff = _diffCount(withRouteVenue, rootVenueOnly);
        lines.add(
          'glass+$paletteId ${brightness.name}: '
          'builder=${entry.runtimeType} diff=$diff',
        );
        expect(
          diff,
          lessThanOrEqualTo(_kPixelNoise),
          reason: '逐路由场地相对单张根场地在稳态出现 $diff 个像素差异（要求逐像素等价）',
        );
      }
    }
    debugPrint('[T09][steady-parity] ${lines.join(' | ')}');
  });
}

// ── 常量与阈值 ────────────────────────────────────────────────────────

const Key _kRoot = ValueKey('t09-root');
const Key _kPush = ValueKey('t09-push');
const Key _kUpperBody = ValueKey('t09-upper-body');

const Size _kViewport = Size(420, 800);

/// 系统返回手势的推进档位（0 = 未开始，1 = 已提交）。
const List<double> _kStops = <double>[0.3, 0.6, 0.9];

/// 采样点噪声容忍：缩放/圆角裁剪边缘的抗锯齿可能命中个别采样点。
const int _kPixelNoise = 2;

/// 容忍的通道差（8/255 ≈ 3%），覆盖预乘与 sRGB 往返误差。
const int _kChannelTolerance = 8;

const bool kEvidence = bool.fromEnvironment('LM_T09_EVIDENCE');
const String kEvidenceTag = String.fromEnvironment(
  'LM_T09_TAG',
  defaultValue: 'shots',
);
const String _kEvidenceDir = 'test_screenshots/night-2026-09-21';

LmPalette _paletteOf(String paletteId, Brightness brightness) =>
    paletteId == 'bordeaux'
        ? const BordeauxPaletteFamily().of(brightness)
        : const ClassicPaletteFamily().of(brightness);

/// 参考口径：与装配表同 builder 但**不装饰**场地——即  之前的旧行为
/// （场地只来自 Navigator 之下的根壳）。
PageTransitionsTheme _legacyTransitionsTheme(ThemeData theme) {
  final current = theme.pageTransitionsTheme.builders;
  return PageTransitionsTheme(
    builders: <TargetPlatform, PageTransitionsBuilder>{
      for (final entry in current.entries) entry.key: _unwrap(entry.value),
    },
  );
}

/// 从（可能被装饰的）builder 取出被委派的原始 builder。
///
/// 装饰器由 `lm_page_transitions.dart` 提供；这里按运行期类型名识别，
/// 避免让测试依赖装饰器的具体类符号。若装配表里根本没有装饰器，
/// 回落到原 builder（此时 (b) 与 (a) 同口径），
/// 由用例内「装饰器必须已在装配中」的断言拦住这种假绿。
PageTransitionsBuilder _unwrap(PageTransitionsBuilder builder) {
  if (!builder.runtimeType.toString().contains('Venue')) return builder;
  final delegate = (builder as dynamic).delegate;
  return delegate is PageTransitionsBuilder ? delegate : builder;
}

// ── 场地壳（复刻 main.dart 的层级：场地在 Navigator 之下）──────────────

Future<void> _pumpShell(
  WidgetTester tester, {
  required ThemeData theme,
  required Widget home,
  bool rootVenue = true,
}) async {
  tester.view.physicalSize = _kViewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    RepaintBoundary(
      key: _kRoot,
      child: MaterialApp(
        theme: theme,
        builder: rootVenue
            ? (context, child) => Builder(
                  builder: (inner) =>
                      inner.glassVenue(child ?? const SizedBox.shrink()),
                )
            : null,
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 下层路由：整屏「指纹色块」（`palette.accent`，占屏 90%），
/// 顶部留 80px 场地带放推页按钮。上层若透明，这块颜色就会从卡片内部透出来。
class _LowerPage extends StatelessWidget {
  const _LowerPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldBgOf(
        Theme.of(context).scaffoldBackgroundColor,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            height: 80,
            child: Center(
              child: TextButton(
                key: _kPush,
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(builder: (_) => const _UpperPage()),
                ),
                child: const Text('push'),
              ),
            ),
          ),
          Expanded(child: ColoredBox(color: context.lm.palette.accent)),
        ],
      ),
    );
  }
}

/// 上层路由：顶部 56px 自绘主题色条，**其余全空**（只透本路由场地）。
/// 于是「卡片内部出现指纹色」只可能来自下层路由。
class _UpperPage extends StatelessWidget {
  const _UpperPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldBgOf(
        Theme.of(context).scaffoldBackgroundColor,
      ),
      body: Column(
        key: _kUpperBody,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            height: 56,
            child: ColoredBox(color: context.lm.palette.primary),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}

/// 空页面：稳态等价性对照用（只靠场地 + 透明 Scaffold）。
class _PlainPage extends StatelessWidget {
  const _PlainPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.scaffoldBgOf(
        Theme.of(context).scaffoldBackgroundColor,
      ),
      body: const SizedBox.expand(),
    );
  }
}

// ── 手势驱动 ─────────────────────────────────────────────────────────

Future<void> _sendBackGesture(
  WidgetTester tester,
  String method,
  Map<String, dynamic> arguments,
) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments)),
    (ByteData? _) {},
  );
}

/// 定帧推进：setState（phase 变更）+ 一帧布局。
Future<void> _pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 16));
}

// ── 像素采集与判定 ───────────────────────────────────────────────────

class _Frame {
  _Frame(this.width, this.height, this.rgba);

  final int width;
  final int height;
  final Uint8List rgba;

  Color at(int x, int y) {
    final o = (y * width + x) * 4;
    return Color.fromARGB(rgba[o + 3], rgba[o], rgba[o + 1], rgba[o + 2]);
  }
}

Future<_Frame> _capture(WidgetTester tester) async {
  final boundary =
      tester.renderObject(find.byKey(_kRoot)) as RenderRepaintBoundary;
  late _Frame frame;
  await tester.binding.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    frame = _Frame(
      image.width,
      image.height,
      Uint8List.fromList(data!.buffer.asUint8List()),
    );
    image.dispose();
  });
  return frame;
}

Future<void> _writeEvidence(
  WidgetTester tester,
  _Frame frame,
  String name,
) async {
  if (!kEvidence) return;
  await tester.binding.runAsync(() async {
    writePngSync(
      '$_kEvidenceDir/t09_${kEvidenceTag}__$name.png',
      frame.width,
      frame.height,
      frame.rgba,
    );
  });
}

bool _matches(Color a, Color b) {
  int q(double v) => (v * 255).round();
  return (q(a.a) - q(b.a)).abs() <= _kChannelTolerance &&
      (q(a.r) - q(b.r)).abs() <= _kChannelTolerance &&
      (q(a.g) - q(b.g)).abs() <= _kChannelTolerance &&
      (q(a.b) - q(b.b)).abs() <= _kChannelTolerance;
}

/// 区域内与 [color] 匹配的采样点数。
int _countColor(_Frame f, Rect rect, Color color, {int step = 3}) {
  var count = 0;
  final x0 = rect.left.floor().clamp(0, f.width - 1);
  final x1 = rect.right.ceil().clamp(0, f.width);
  final y0 = rect.top.floor().clamp(0, f.height - 1);
  final y1 = rect.bottom.ceil().clamp(0, f.height);
  for (var y = y0; y < y1; y += step) {
    for (var x = x0; x < x1; x += step) {
      if (_matches(f.at(x, y), color)) count++;
    }
  }
  return count;
}

/// 全帧「无绘制者」采样点数（alpha ≠ 255）。
int _countUnpainted(_Frame f, {int step = 3}) {
  var count = 0;
  for (var y = 0; y < f.height; y += step) {
    for (var x = 0; x < f.width; x += step) {
      if (f.at(x, y).a < 1.0) count++;
    }
  }
  return count;
}

/// 全帧纯黑采样点数（r = g = b = 0 且不透明）。
int _countPureBlack(_Frame f, {int step = 3}) {
  var count = 0;
  for (var y = 0; y < f.height; y += step) {
    for (var x = 0; x < f.width; x += step) {
      final c = f.at(x, y);
      if (c.a == 1.0 && c.r == 0 && c.g == 0 && c.b == 0) count++;
    }
  }
  return count;
}

/// 两帧不同像素数（逐像素全量比对）。
int _diffCount(_Frame a, _Frame b) {
  if (a.width != b.width || a.height != b.height) {
    fail('帧尺寸不一致：${a.width}x${a.height} vs ${b.width}x${b.height}');
  }
  var count = 0;
  for (var y = 0; y < a.height; y += 1) {
    for (var x = 0; x < a.width; x += 1) {
      if (!_matches(a.at(x, y), b.at(x, y))) count++;
    }
  }
  return count;
}

void _expectDistinguishable(Color a, Color b, String what) {
  int q(double v) => (v * 255).round();
  final d = (q(a.r) - q(b.r)).abs() +
      (q(a.g) - q(b.g)).abs() +
      (q(a.b) - q(b.b)).abs();
  expect(
    d,
    greaterThan(60),
    reason: '夹具前提不成立：$what 太接近（通道差合计 $d）→ 像素判定无区分力',
  );
}
