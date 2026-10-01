import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_factories.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';

///  守卫：同屏 （真 blur）实例数 ≤2 的**运行时**对账。
///
/// 此前只有静态白名单守卫（glass_redline_guard_test ①②：BackdropFilter
/// 源码闭集 3 处），「同屏 ≤2」红线无运行时对账。现在三类  工厂经
/// `_T0BlurScope` 挂载计数：sheet + dialog 叠开 = 2 合法；第 3 颗真 blur
/// 挂载即 debug 断言失败；流式降级  的 floatingBar 不计数。
void main() {
  // 断言失败的用例会把树打碎、部分计数无法随 dispose 回落，
  // 逐用例复位保证隔离。
  setUp(GlassT0Tracker.resetForTest);

  Future<BuildContext> pumpGlassHost(
    WidgetTester tester, {
    Brightness brightness = Brightness.dark,
  }) async {
    late BuildContext hostContext;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeCatalog.assemble(
          const LmAppearance(structureId: 'glass'),
          brightness,
        ),
        home: Builder(
          builder: (context) {
            hostContext = context;
            return const Scaffold(body: SizedBox.shrink());
          },
        ),
      ),
    );
    return hostContext;
  }

  test('初始存活数归零', () {
    expect(GlassT0Tracker.live, 0);
  });

  testWidgets('sheet + dialog 叠开 = 2 颗真 blur，合法', (tester) async {
    final context = await pumpGlassHost(tester);
    expect(GlassT0Tracker.live, 0);

    unawaited(
      showLmSheet<void>(
        context: context,
        builder: (_) => const SizedBox(height: 120),
      ),
    );
    await tester.pumpAndSettle();
    expect(GlassT0Tracker.live, 1, reason: '琉璃 sheet = GlassBottomSheet（T0）');

    unawaited(
      showLmDialog<void>(
        context: context,
        builder: (_) => const GlassModal(child: SizedBox(height: 80)),
      ),
    );
    await tester.pumpAndSettle();
    expect(GlassT0Tracker.live, 2, reason: 'sheet + modal 叠开恰为红线内 2 颗');

    // 逐层关闭：计数同步回落。
    Navigator.of(context, rootNavigator: true).pop();
    await tester.pumpAndSettle();
    expect(GlassT0Tracker.live, 1);
    Navigator.of(context, rootNavigator: true).pop();
    await tester.pumpAndSettle();
    expect(GlassT0Tracker.live, 0);
  });

  testWidgets('第 3 颗真 blur 挂载即断言失败', (tester) async {
    final context = await pumpGlassHost(tester);
    unawaited(
      showLmSheet<void>(
        context: context,
        builder: (_) => const SizedBox(height: 120),
      ),
    );
    await tester.pumpAndSettle();
    unawaited(
      showLmDialog<void>(
        context: context,
        builder: (_) => const GlassModal(child: SizedBox(height: 80)),
      ),
    );
    await tester.pumpAndSettle();
    expect(GlassT0Tracker.live, 2);

    // 一帧内三颗  连续触发断言，收集式捕获（takeException 只吞一个）。
    final errors = <FlutterErrorDetails>[];
    final originalHandler = FlutterError.onError;
    FlutterError.onError = errors.add;
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeCatalog.assemble(
            const LmAppearance(structureId: 'glass'),
            Brightness.dark,
          ),
          home: const Scaffold(
            body: Column(
              children: [
                GlassModal(child: SizedBox(height: 40)),
                GlassBottomSheet(child: SizedBox(height: 40)),
                GlassFloatingBar(child: SizedBox(height: 40)),
              ],
            ),
          ),
        ),
      );
    } finally {
      FlutterError.onError = originalHandler;
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      });
    }

    final assertions = errors
        .map((e) => e.exception)
        .whereType<AssertionError>()
        .where((e) => '$e'.contains('T0 (real blur) live instances exceeded'))
        .toList();
    expect(
      assertions,
      isNotEmpty,
      reason: '同屏第 3 颗真 blur 挂载必须触发超限断言',
    );
  });

  testWidgets('流式降级 T1 的 floatingBar 不计数', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeCatalog.assemble(
          const LmAppearance(structureId: 'glass', paletteId: 'bordeaux'),
          Brightness.dark,
        ),
        home: const Scaffold(
          body: GlassFloatingBar(
            streaming: true,
            child: SizedBox(height: 40, width: 80),
          ),
        ),
      ),
    );
    expect(GlassT0Tracker.live, 0, reason: 'T1 分支无 BackdropFilter');
  });
}
