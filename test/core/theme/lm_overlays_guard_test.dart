import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_factories.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_materials.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';

/// 统一浮层入口守卫（lm_overlays.showLmSheet / showLmDialog）。
///
/// 三条不变量：
/// ① 经典组合：新入口与直接调 `showModalBottomSheet` / `showDialog`
///    逐字段等值（backgroundColor / elevation / shape / barrierColor）——
///    「经典零视觉变化」由构造保证并在此锁死；
/// ② 琉璃组合：sheet 面层透明（琉璃面由 GlassBottomSheet 工厂承载，
///    面色 = t0Fill 合成 surfaceElevated），遮罩 = `palette.scrim`@50%；
/// ③ 琉璃组合：dialog 遮罩同配色 scrim@50%（显式传入值优先）。
void main() {
  final combos = <(String, String, Brightness)>[
    ('classic', 'classic', Brightness.light),
    ('classic', 'classic', Brightness.dark),
    ('classic', 'bordeaux', Brightness.light),
    ('classic', 'bordeaux', Brightness.dark),
    ('glass', 'classic', Brightness.light),
    ('glass', 'classic', Brightness.dark),
    ('glass', 'bordeaux', Brightness.light),
    ('glass', 'bordeaux', Brightness.dark),
  ];

  ThemeData themeOf(String structure, String palette, Brightness brightness) =>
      ThemeCatalog.assemble(
        LmAppearance(structureId: structure, paletteId: palette),
        brightness,
      );

  Future<ModalBottomSheetRoute<void>> openSheet(
    WidgetTester tester, {
    required ThemeData theme,
    required Future<Object?> Function(BuildContext) open,
  }) async {
    ModalBottomSheetRoute<void>? captured;
    final observer = _RouteRecorder(
      onPushed: (r) {
        if (r is ModalBottomSheetRoute<void>) captured = r;
      },
    );
    late BuildContext buttonContext;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        navigatorObservers: [observer],
        home: Scaffold(
          body: Builder(
            builder: (context) {
              buttonContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    // ignore: unawaited_futures
    open(buttonContext);
    await tester.pumpAndSettle();
    return captured!;
  }

  Future<DialogRoute<void>> openDialog(
    WidgetTester tester, {
    required ThemeData theme,
    required Future<Object?> Function(BuildContext) open,
  }) async {
    DialogRoute<void>? captured;
    final observer = _RouteRecorder(
      onPushed: (r) {
        if (r is DialogRoute<void>) captured = r;
      },
    );
    late BuildContext buttonContext;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        navigatorObservers: [observer],
        home: Scaffold(
          body: Builder(
            builder: (context) {
              buttonContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    // ignore: unawaited_futures
    open(buttonContext);
    await tester.pumpAndSettle();
    return captured!;
  }

  group('经典组合：新入口与原 show 系列逐字段等值', () {
    for (final (structure, palette, brightness) in combos) {
      if (structure != 'classic') continue;
      testWidgets(
        'showLmSheet == showModalBottomSheet（$palette ${brightness.name}）',
        (tester) async {
          final theme = themeOf(structure, palette, brightness);
          final viaEntry = await openSheet(
            tester,
            theme: theme,
            open: (ctx) => showLmSheet<void>(
              context: ctx,
              builder: (_) => const SizedBox(height: 100),
            ),
          );
          final viaRaw = await openSheet(
            tester,
            theme: theme,
            open: (ctx) => showModalBottomSheet<void>(
              context: ctx,
              builder: (_) => const SizedBox(height: 100),
            ),
          );
          expect(viaEntry.backgroundColor, viaRaw.backgroundColor);
          expect(viaEntry.barrierColor, viaRaw.barrierColor);
          expect(viaEntry.elevation, viaRaw.elevation);
          expect(viaEntry.shape?.toString(), viaRaw.shape?.toString());
        },
      );

      testWidgets(
        'showLmDialog == showDialog（$palette ${brightness.name}）',
        (tester) async {
          final theme = themeOf(structure, palette, brightness);
          final viaEntry = await openDialog(
            tester,
            theme: theme,
            open: (ctx) => showLmDialog<void>(
              context: ctx,
              builder: (_) => const SizedBox.shrink(),
            ),
          );
          final viaRaw = await openDialog(
            tester,
            theme: theme,
            open: (ctx) => showDialog<void>(
              context: ctx,
              builder: (_) => const SizedBox.shrink(),
            ),
          );
          expect(viaEntry.barrierColor, viaRaw.barrierColor);
          expect(viaEntry.barrierDismissible, viaRaw.barrierDismissible);
        },
      );
    }
  });

  group('琉璃组合：面层取自琉璃工厂、遮罩 = 配色 scrim@50%', () {
    for (final (structure, palette, brightness) in combos) {
      if (structure != 'glass') continue;
      testWidgets(
        'sheet 面透明 + GlassBottomSheet 承载 + scrim 遮罩（$palette ${brightness.name}）',
        (tester) async {
          final theme = themeOf(structure, palette, brightness);
          final route = await openSheet(
            tester,
            theme: theme,
            open: (ctx) => showLmSheet<void>(
              context: ctx,
              builder: (_) => const SizedBox(height: 100),
            ),
          );
          final paletteTokens = theme.extension<LmTokens>()!.palette;
          expect(route.backgroundColor, Colors.transparent);
          expect(
            route.barrierColor,
            paletteTokens.scrim.withValues(alpha: 0.5),
          );

          // 面层取自工厂：内容外包 GlassBottomSheet，面色 = t0Fill 合成
          // surfaceElevated（真玻璃配方）。
          final faceBox = tester.widget<DecoratedBox>(
            find
                .descendant(
                  of: find.byType(GlassBottomSheet),
                  matching: find.byType(DecoratedBox),
                )
                .first,
          );
          expect(
            (faceBox.decoration as BoxDecoration).color,
            Color.alphaBlend(
              GlassMaterials.t0Fill,
              paletteTokens.surfaceElevated,
            ),
          );
        },
      );

      testWidgets(
        'dialog 遮罩 = 配色 scrim@50%（$palette ${brightness.name}）',
        (tester) async {
          final theme = themeOf(structure, palette, brightness);
          final route = await openDialog(
            tester,
            theme: theme,
            open: (ctx) => showLmDialog<void>(
              context: ctx,
              builder: (_) => const SizedBox.shrink(),
            ),
          );
          final paletteTokens = theme.extension<LmTokens>()!.palette;
          expect(
            route.barrierColor,
            paletteTokens.scrim.withValues(alpha: 0.5),
          );
        },
      );
    }

    testWidgets('glassHandle=false 时不渲染工厂把手', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: themeOf('glass', 'bordeaux', Brightness.dark),
          home: const Scaffold(
            body: Center(
              child: GlassBottomSheet(
                showHandle: false,
                child: SizedBox(height: 40),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final handles = find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.constraints ==
                const BoxConstraints.tightFor(
                  width: 36,
                  height: 4,
                ),
      );
      expect(handles, findsNothing);
    });
  });
}

class _RouteRecorder extends NavigatorObserver {
  _RouteRecorder({required this.onPushed});

  final void Function(Route<Object?> route) onPushed;

  @override
  void didPush(Route<Object?> route, Route<Object?>? previousRoute) =>
      onPushed(route);
}
