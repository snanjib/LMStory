import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_page_transitions.dart';
import 'package:lmstory/core/theme/system/lm_palette.dart';
import 'package:lmstory/core/theme/system/palettes/bordeaux/bordeaux_palette.dart';
import 'package:lmstory/core/theme/system/palettes/classic/classic_palette.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_factories.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_surface.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';

///  守卫：路由过渡期不得透出「场地之外的颜色」（黑 / ColorScheme.surface）。
///
/// 背景（2026-09-21 修复）：`ZoomPageTransitionsBuilder` 过渡期用
/// `ColorScheme.surface` 作全屏 scrim，琉璃结构下把根场地渐变整层盖住，
/// 波尔多夜间 surface=#221420 观感即「先黑一帧再出波尔多」。
/// 修复 = `lmPageTransitionsTheme` 把 scrim 钉在 `palette.bg`。
///
/// 追加：过渡 scrim 钉底只解决了「单层路由」的过渡期；
/// 「两层路由同时可见」（预测式返回）需要**每条路由自承载不透明场地**，
/// 由 `LmRouteVenuePageTransitionsBuilder` 落实，新契约的逐帧守卫见
/// `t09_predictive_back_venue_guard_test.dart`（叠印 / 黑区 / 无根壳兜底 /
/// 稳态逐像素等价）。本文件的 / 兜底语义随新契约同步：
/// page route 一律有场地， 的「无场地」改由弹层环境构造。
///
/// 判定口径：过渡期任一采样点像素，必须仍在「场地色域」内——
/// 等于推入前稳态像素（场地渐变原样），或等于 `palette.bg`（scrim 钉底）。
/// 出现其它颜色（surface / 纯黑 / 透明洞）即失败。
void main() {
  final combos = <String, LmPalette Function(Brightness)>{
    'classic_classic': (b) => const ClassicPaletteFamily().of(b),
    'glass_bordeaux': (b) => const BordeauxPaletteFamily().of(b),
  };

  // ── . 装配守卫：过渡 scrim 必须钉在 palette.bg（防回归）─────────
  //
  //  起装配表里的 builder 一律先经 [LmRouteVenuePageTransitionsBuilder]
  // 装饰（每条路由自承载不透明场地），断言前先解包到内层平台 builder，
  // 再核对 scrim 取值与平台分工——语义与  之前完全一致，不放宽。
  PageTransitionsBuilder unwrapOf(PageTransitionsBuilder? builder) {
    var current = builder;
    while (current is LmRouteVenuePageTransitionsBuilder) {
      current = current.delegate;
    }
    return current!;
  }

  ZoomPageTransitionsBuilder? zoomOf(PageTransitionsBuilder? builder) {
    final inner = unwrapOf(builder);
    return inner is ZoomPageTransitionsBuilder ? inner : null;
  }

  test('all 4 combos x 2 brightness pin the transition scrim to palette.bg',
      () {
    final palettes = <String, LmPalette Function(Brightness)>{
      'classic': (b) => const ClassicPaletteFamily().of(b),
      'bordeaux': (b) => const BordeauxPaletteFamily().of(b),
    };
    for (final structure in const ['classic', 'glass']) {
      for (final entry in palettes.entries) {
        for (final brightness in Brightness.values) {
          final palette = entry.value(brightness);
          final theme = ThemeCatalog.assemble(
            LmAppearance(structureId: structure, paletteId: entry.key),
            brightness,
          );
          final builders = theme.pageTransitionsTheme.builders;
          //  契约：装配表里覆盖到的平台一律经路由场地装饰器。
          // （fuchsia 等未列入装配表的平台走 Flutter 默认表，本产品不投放。）
          for (final platform in const <TargetPlatform>[
            TargetPlatform.android,
            TargetPlatform.iOS,
            TargetPlatform.macOS,
            TargetPlatform.windows,
            TargetPlatform.linux,
          ]) {
            expect(
              builders[platform],
              isA<LmRouteVenuePageTransitionsBuilder>(),
              reason: '$structure+${entry.key} $platform 必须经路由场地装饰器',
            );
          }
          final windows = zoomOf(builders[TargetPlatform.windows]);
          final linux = zoomOf(builders[TargetPlatform.linux]);
          expect(windows, isNotNull);
          expect(linux, isNotNull);
          expect(
            windows!.backgroundColor,
            palette.bg,
            reason: '$structure+${entry.key} windows scrim must be palette.bg',
          );
          expect(
            linux!.backgroundColor,
            palette.bg,
            reason: '$structure+${entry.key} linux scrim must be palette.bg',
          );
          // Android 预测式返回退化档（FadeForwards）的 scrim 同样钉 bg。
          final android = unwrapOf(builders[TargetPlatform.android]);
          expect(android, isA<PredictiveBackPageTransitionsBuilder>());
          expect(
            (android as PredictiveBackPageTransitionsBuilder).fallbackColor,
            palette.bg,
            reason:
                '$structure+${entry.key} android fallback scrim = palette.bg',
          );
          // Apple 平台保持原生平移过渡（无 scrim，不受本缺陷影响）
          expect(
            unwrapOf(builders[TargetPlatform.iOS]),
            isA<CupertinoPageTransitionsBuilder>(),
          );
          expect(
            unwrapOf(builders[TargetPlatform.macOS]),
            isA<CupertinoPageTransitionsBuilder>(),
          );
        }
      }
    }
  });

  // ── B. scaffoldBgOf 兜底：无场地祖先时绝不返回透明 ────────────────
  testWidgets('B1: glass scaffold over venue => transparent', (tester) async {
    await _pumpShell(tester, const _ProbePage(venue: true));
    final context = tester.element(find.byKey(_kProbe));
    expect(context.isGlassSurface, isTrue);
    expect(GlassVenueScope.maybeOf(context), isNotNull);
    expect(
      context.scaffoldBgOf(const Color(0xFF010203)),
      Colors.transparent,
    );
  });

  testWidgets('B2: glass scaffold without venue => palette.bg (never black)',
      (tester) async {
    //  起每条 page route 都自承载场地，真正的「无场地」只剩两种情形：
    // ① 应用根壳（main.dart 的 _GlassVenueShell）被移除；
    // ② 非 page route 的弹层（DialogRoute / ModalBottomSheetRoute 不经
    //    PageTransitionsTheme，装饰器覆盖不到）。
    // 这里取②（并同时构造出①的环境）：无根壳的 MaterialApp 里开 dialog。
    await tester.binding.setSurfaceSize(const Size(320, 240));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeCatalog.assemble(
          const LmAppearance(structureId: 'glass', paletteId: 'bordeaux'),
          Brightness.dark,
        ),
        home: const SizedBox.shrink(),
      ),
    );
    final navContext =
        tester.state<NavigatorState>(find.byType(Navigator)).context;
    unawaited(
      showDialog<void>(
        context: navContext,
        builder: (_) => const _ProbePage(venue: false),
      ),
    );
    await tester.pumpAndSettle();

    final context = tester.element(find.byKey(_kProbe));
    expect(GlassVenueScope.maybeOf(context), isNull);
    // 真实调用口径：classicBg = Theme.scaffoldBackgroundColor = palette.bg
    final classicBg = Theme.of(context).scaffoldBackgroundColor;
    final bg = context.scaffoldBgOf(classicBg);
    expect(bg, isNot(Colors.transparent));
    expect(bg, isNot(Colors.black));
    expect(bg, classicBg);
    expect(bg, _bordeauxDark.bg);
  });

  // ── C. 逐帧像素守卫：4 组合 × 2 明暗 × {windows, android} ──────────
  for (final combo in combos.entries) {
    for (final brightness in Brightness.values) {
      for (final platform in <TargetPlatform, String>{
        TargetPlatform.windows: 'windows_zoom',
        TargetPlatform.android: 'android_predictive',
      }.entries) {
        final tag = '${combo.key}__${brightness.name}__${platform.value}';
        testWidgets('no foreign color during push [$tag]', (tester) async {
          debugDefaultTargetPlatformOverride = platform.key;
          try {
            final palette = combo.value(brightness);
            final theme = ThemeCatalog.assemble(
              LmAppearance(
                structureId: combo.key.split('_').first,
                paletteId: combo.key.split('_').last,
              ),
              brightness,
            );
            await _pumpShell(
              tester,
              _PushHost(pageBg: theme.scaffoldBackgroundColor),
              theme: theme,
            );
            final before = await _sampleCorners(tester);
            expect(before, isNotEmpty);

            await tester.tap(find.text('push'));
            await tester.pump();
            final frame01 = await _sampleCorners(tester);
            _assertAllVenueOrBg(frame01, before, palette.bg, 'frame01/$tag');
            await tester.pump(const Duration(milliseconds: 150));
            final mid = await _sampleCorners(tester);
            _assertAllVenueOrBg(mid, before, palette.bg, 'mid/$tag');
            await tester.pumpAndSettle();
            final end = await _sampleCorners(tester);
            _assertAllVenueOrBg(end, before, palette.bg, 'end/$tag');
          } finally {
            debugDefaultTargetPlatformOverride = null;
          }
        });
      }
    }
  }
}

const Key _kProbe = ValueKey('probe');

LmPalette get _bordeauxDark =>
    const BordeauxPaletteFamily().of(Brightness.dark);

/// main.dart 同款层级：builder 场地壳包住 Navigator。
Future<void> _pumpShell(
  WidgetTester tester,
  Widget home, {
  ThemeData? theme,
}) async {
  await tester.binding.setSurfaceSize(const Size(600, 500));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    RepaintBoundary(
      key: _kRoot,
      child: MaterialApp(
        theme: theme ??
            ThemeCatalog.assemble(
              const LmAppearance(structureId: 'glass', paletteId: 'bordeaux'),
              Brightness.dark,
            ),
        builder: (context, child) => Builder(
          builder: (inner) => inner.glassVenue(child ?? const SizedBox()),
        ),
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const Key _kRoot = ValueKey('root');

class _ProbePage extends StatelessWidget {
  const _ProbePage({required this.venue});
  final bool venue;

  @override
  Widget build(BuildContext context) {
    final content = Builder(
      builder: (inner) {
        final bg = inner.scaffoldBgOf(Theme.of(inner).scaffoldBackgroundColor);
        return Scaffold(key: _kProbe, backgroundColor: bg);
      },
    );
    return venue ? GlassBackdrop(child: content) : content;
  }
}

class _PushHost extends StatelessWidget {
  const _PushHost({required this.pageBg});
  final Color pageBg;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor:
          context.scaffoldBgOf(Theme.of(context).scaffoldBackgroundColor),
      body: Center(
        child: Builder(
          builder: (buttonContext) => TextButton(
            onPressed: () => Navigator.of(buttonContext).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(backgroundColor: pageBg),
              ),
            ),
            child: const Text('push'),
          ),
        ),
      ),
    );
  }
}

// ── 像素采样 ──────────────────────────────────────────────────────

Future<List<Color>> _sampleCorners(WidgetTester tester) async {
  final boundary =
      tester.renderObject(find.byKey(_kRoot)) as RenderRepaintBoundary;
  var raw = <int>[];
  var w = 0;
  var h = 0;
  await tester.binding.runAsync(() async {
    final image = await boundary.toImage();
    w = image.width;
    h = image.height;
    final data =
        await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    raw = data!.buffer.asUint8List();
    image.dispose();
  });
  Color px(int x, int y) {
    final o = (y * w + x) * 4;
    return Color.fromARGB(raw[o + 3], raw[o], raw[o + 1], raw[o + 2]);
  }

  return [px(5, 5), px(w - 6, 5), px(5, h - 6), px(w - 6, h - 6)];
}

/// 通道容差：8/255 ≈ 3%，覆盖 alpha 预乘与 sRGB 转换误差。
const double _kChannelTolerance = 8 / 255.0;

bool _close(Color a, Color b) =>
    (a.a - b.a).abs() <= _kChannelTolerance &&
    (a.r - b.r).abs() <= _kChannelTolerance &&
    (a.g - b.g).abs() <= _kChannelTolerance &&
    (a.b - b.b).abs() <= _kChannelTolerance;

void _assertAllVenueOrBg(
  List<Color> sampled,
  List<Color> before,
  Color bg,
  String where,
) {
  expect(sampled.length, before.length);
  for (var i = 0; i < sampled.length; i++) {
    final ok = _close(sampled[i], before[i]) || _close(sampled[i], bg);
    if (!ok) {
      fail(
        '$where corner#$i shows a colour outside the venue: '
        '${sampled[i].toARGB32().toRadixString(16)} '
        '(steady=${before[i].toARGB32().toRadixString(16)}, '
        'palette.bg=${bg.toARGB32().toRadixString(16)})',
      );
    }
  }
}
