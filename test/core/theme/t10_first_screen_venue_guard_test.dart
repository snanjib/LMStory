//  守卫 · 首屏必须**消费场地**（琉璃下），且 classic 组合零视觉变化。
//
// ## 裁决原文（2026-09-22 复评）
//
// 「首屏不消费场地 → 判为缺陷，改」：`OnboardingPage` 必须消费
// `context.glassVenue(...)`（或等价框架层处理，**不逐页复制**）；
// classic 组合必须零视觉变化。
//
// ## 缺陷是什么
//
// 首屏此前直接 `backgroundColor: colors.bg` 平涂——在琉璃下意味着
// **边缘亮度 range 恒为 0**，而进去之后的 home 页是 0.35 级的场地渐变。
// 用户第一次看到 LMStory 的那一屏，与它之后的世界不同构。
//
// ## 为什么这个夹具不套「根场地壳」
//
//  已把场地改成**逐路由自承载**。所以本用例刻意**不**在 MaterialApp
// 外面套 `glassVenue`——若首屏仍然依赖祖先幕布，这里就会露黑（alpha=0）
// 或者退化成平涂，直接红。这与 `t09_predictive_back_venue_guard_test.dart`
// 的「无根壳也不裸奔」是同一条约束的收敛面。
//
// ## 判据（像素级）
//
// 沿**左缘一列**（x=4）自顶到底采样：
//   · 琉璃：场地渐变 + 暗角 → 亮度 range **> 0**（实测见 debugPrint）；
//   · classic：平涂 `palette.bg` → range **== 0**，且每个采样点都等于
//     `palette.bg`（逐像素证明「零视觉变化」，不是"差不多"）。
// 另加两项结构性契约：琉璃下 Scaffold 底色必须**透明**（把场地让出来）、
// 且其子树内必须**存在** `GlassVenueScope`；classic 下必须**不透明**。
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_factories.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_surface.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/onboarding/presentation/pages/onboarding_page.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

const Key _kRoot = ValueKey('t10-firstrun-root');
const Size _kViewport = Size(420, 900);

/// 左缘采样列（x 固定）。取 4px：在 Simple 版式的水平内边距之外，
/// 整列都只能是「背景」（内容与底部操作条都在内边距之内）。
const double _kProbeX = 4;

int _q(double v) => (v * 255).round();

double _luminance((int, int, int) c) {
  double ch(int v) {
    final s = v / 255.0;
    return s <= 0.04039
        ? s / 12.92
        : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * ch(c.$1) + 0.7152 * ch(c.$2) + 0.0722 * ch(c.$3);
}

void main() {
  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  for (final paletteId in <String>['classic', 'bordeaux']) {
    for (final brightness in Brightness.values) {
      final tag = 'glass/$paletteId/${brightness.name}';
      testWidgets('首屏消费场地：琉璃自承载渐变 + 透明 Scaffold [$tag]', (tester) async {
        final frame = await _render(tester, 'glass', paletteId, brightness);
        final palette = _palette('glass', paletteId, brightness);

        final scaffoldContext = tester.element(find.byType(Scaffold).first);
        expect(
          GlassVenueScope.maybeOf(scaffoldContext),
          isNotNull,
          reason: '[$tag] 首屏子树内没有场地 → 又退回「靠祖先幕布」',
        );
        expect(
          scaffoldContext.scaffoldBgOf(palette.bg),
          Colors.transparent,
          reason: '[$tag] 首屏 Scaffold 不透明 → 场地被平涂盖住（本缺陷的形态）',
        );

        final strip = _strip(frame);
        final range = _range(strip);
        debugPrint('[T10-1][$tag] 左缘亮度 range=${range.toStringAsFixed(4)} '
            '顶=${strip.first} 底=${strip.last}');
        expect(
          range,
          greaterThan(0.0),
          reason: '[$tag] 首屏背景是平的（range=0）→ 没消费场地渐变',
        );
        // 注：不再加「左缘底部更靠近 bgGlow」的方向判据 —— 场地上还有一层
        // **暗角**（RadialGradient 黑@≤18%），它在左下角把底色压得比 bgGlow
        // 更暗，方向判据会被暗角本身骗过（实测 classic 日 bgGlow #DDE3EE 距
        // 底部采样点比顶部更远）。方向由 `glass_factories.dart` 的
        // `LinearGradient(bottomLeft → topRight)` 单一来源决定，不在此重复断言。

        // 底部操作条同样要被场地透上来（它是 Scaffold 之外的第二处平涂点）。
        final bottom = _at(frame, Offset(_kProbeX, _kViewport.height - 12));
        expect(
          bottom,
          isNot((_q(palette.bg.r), _q(palette.bg.g), _q(palette.bg.b))),
          reason: '[$tag] 底部操作条是平涂的 palette.bg → 场地没透上来',
        );
      });

      final classicTag = 'classic/$paletteId/${brightness.name}';
      testWidgets('首屏 classic 组合零视觉变化（逐像素等于 palette.bg）[$classicTag]',
          (tester) async {
        final frame = await _render(tester, 'classic', paletteId, brightness);
        final palette = _palette('classic', paletteId, brightness);

        final scaffoldContext = tester.element(find.byType(Scaffold).first);
        expect(
          scaffoldContext.scaffoldBgOf(palette.bg),
          isNot(Colors.transparent),
          reason: '[$classicTag] classic 结构不得退化为透明底',
        );

        final expected = (_q(palette.bg.r), _q(palette.bg.g), _q(palette.bg.b));
        final strip = _strip(frame);
        expect(
          _range(strip),
          0.0,
          reason: '[$classicTag] classic 首屏背景出现渐变 → 破坏了「零视觉变化」',
        );
        for (final c in strip) {
          expect(
            c,
            expected,
            reason: '[$classicTag] 左缘采样点 $c ≠ palette.bg $expected',
          );
        }
        expect(
          _at(frame, Offset(_kProbeX, _kViewport.height - 12)),
          expected,
          reason: '[$classicTag] classic 底部操作条不再是 palette.bg',
        );
      });
    }
  }
}

// ── 夹具 ─────────────────────────────────────────────────────────────

LmPalette _palette(String structureId, String paletteId, Brightness b) =>
    ThemeCatalog.assemble(
      LmAppearance(structureId: structureId, paletteId: paletteId),
      b,
    ).extension<LmTokens>()!.palette;

/// 渲染真实首屏。**刻意不套根场地壳**（见文件头注释）。
Future<Uint8List> _render(
  WidgetTester tester,
  String structureId,
  String paletteId,
  Brightness brightness,
) async {
  tester.view.physicalSize = _kViewport;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  SharedPreferences.setMockInitialValues({});
  final prefs = Preferences(prefs: await SharedPreferences.getInstance());
  final theme = ThemeCatalog.assemble(
    LmAppearance(structureId: structureId, paletteId: paletteId),
    brightness,
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[preferencesProvider.overrideWithValue(prefs)],
      child: TranslationProvider(
        child: MaterialApp(
          theme: theme,
          home: const RepaintBoundary(
            key: _kRoot,
            child: OnboardingPage(),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  for (final ms in const [100, 300, 600, 900]) {
    await tester.pump(Duration(milliseconds: ms));
  }

  final boundary =
      tester.renderObject(find.byKey(_kRoot)) as RenderRepaintBoundary;
  late Uint8List out;
  await tester.binding.runAsync(() async {
    final image = await boundary.toImage();
    final data =
        await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    out = Uint8List.fromList(data!.buffer.asUint8List());
    image.dispose();
  });
  return out;
}

/// 左缘一列（自上而下，跳过顶栏与底部操作条各留 60px 余量）。
List<(int, int, int)> _strip(Uint8List img) {
  final height = _kViewport.height.round();
  final out = <(int, int, int)>[];
  for (var y = 60; y < height - 60; y += 20) {
    out.add(_at(img, Offset(_kProbeX, y.toDouble())));
  }
  return out;
}

double _range(List<(int, int, int)> strip) {
  var lo = double.infinity;
  var hi = -double.infinity;
  for (final c in strip) {
    final l = _luminance(c);
    lo = math.min(lo, l);
    hi = math.max(hi, l);
  }
  return hi - lo;
}

(int, int, int) _at(Uint8List img, Offset p) {
  final width = _kViewport.width.round();
  final x = p.dx.round().clamp(0, width - 1);
  final y = p.dy.round().clamp(0, _kViewport.height.round() - 1);
  final i = (y * width + x) * 4;
  return (img[i], img[i + 1], img[i + 2]);
}
