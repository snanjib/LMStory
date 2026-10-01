import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/shared/components/breathing_dot.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/palettes/bordeaux/bordeaux_palette.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/message_bubble/bubble_shared.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_factories.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';

///  守卫③：减弱动态（reduced-motion）全量对账。
///
/// 锁死两条验收：
/// 1. **循环动效不得启动**：`disableAnimations` / `accessibleNavigation`
///    任一为真时，所有 `repeat()` 站点必须**不启动**（不是启动后停），
///    直接落静态终态；
/// 2. **一次性过渡退化**：按压补间 / 颜色过渡在减弱动态下退化为终态
///    （无补间或零时长）。
///
/// 另以源码审计钉住「每个 `repeat()` 站点上方必有降级守卫」，防止新增
/// 循环动效绕过。essential 例外（loading 指示器，WCAG 2.3.3）单独断言保留。
void main() {
  // ── 1. 判据并集 ───────────────────────────────────────────────────

  testWidgets(
      'LmMotion.reducedMotion 取并集：disableAnimations ∨ accessibleNavigation', (
    tester,
  ) async {
    const cases = <(bool, bool, bool)>[
      (false, false, false),
      (true, false, true),
      (false, true, true),
      (true, true, true),
    ];
    for (final (disableAnimations, accessibleNav, expected) in cases) {
      bool? seen;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                disableAnimations: disableAnimations,
                accessibleNavigation: accessibleNav,
              ),
              child: Builder(
                builder: (inner) {
                  seen = LmMotion.reducedMotion(inner);
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ),
      );
      expect(
        seen,
        expected,
        reason: 'disableAnimations=$disableAnimations '
            'accessibleNavigation=$accessibleNav',
      );
    }
  });

  // ── 2. 行为差分：循环动效不启动 ─────────────────────────────────────

  testWidgets('BreathingDot：减弱动态下静态渲染（可静置）；全动效下循环运行（不静置）', (tester) async {
    await _pumpHost(tester, reduce: true, child: const BreathingDot());
    expect(
      await _settlesWithin(tester),
      isTrue,
      reason: '减弱动态下呼吸点不得启动循环（应落静态终态）',
    );
    expect(_breathingOpacity(tester), 0.7, reason: '静态终态 opacity = 0.7');

    await _pumpHost(tester, reduce: false, child: const BreathingDot());
    expect(
      await _settlesWithin(tester),
      isFalse,
      reason: '全动效下呼吸点应持续循环（否则差分断言失去意义）',
    );
  });

  testWidgets('BubbleBouncingDotsIndicator：减弱动态下不启动循环', (tester) async {
    final palette = const BordeauxPaletteFamily().of(Brightness.dark);
    await _pumpHost(
      tester,
      reduce: true,
      child: BubbleBouncingDotsIndicator(colors: palette),
    );
    expect(
      await _settlesWithin(tester),
      isTrue,
      reason: '减弱动态下打字点不得启动循环',
    );

    await _pumpHost(
      tester,
      reduce: false,
      child: BubbleBouncingDotsIndicator(colors: palette),
    );
    expect(
      await _settlesWithin(tester),
      isFalse,
      reason: '全动效下打字点应持续循环',
    );
  });

  // ── 3. 一次性过渡退化 ─────────────────────────────────────────────

  testWidgets('GlassPillButton 按压补间：减弱动态下不装 AnimatedScale（直接终态）', (
    tester,
  ) async {
    await _pumpHost(
      tester,
      reduce: true,
      child: GlassPillButton(label: '确认', onPressed: () {}),
    );
    expect(
      find.descendant(
        of: find.byType(GlassPillButton),
        matching: find.byType(AnimatedScale),
      ),
      findsNothing,
      reason: '减弱动态下按压补间不得挂载',
    );

    await _pumpHost(
      tester,
      reduce: false,
      child: GlassPillButton(label: '确认', onPressed: () {}),
    );
    expect(
      find.descendant(
        of: find.byType(GlassPillButton),
        matching: find.byType(AnimatedScale),
      ),
      findsOneWidget,
      reason: '全动效下按压补间应在位',
    );
  });

  testWidgets('GlassSegmented 颜色过渡：减弱动态下时长压到零', (tester) async {
    Widget segmented() => GlassSegmented<_Demo>(
          values: _Demo.values,
          selected: _Demo.a,
          onSelected: (_) {},
          labelOf: (v) => v.name,
        );

    await _pumpHost(tester, reduce: true, child: segmented());
    expect(_segmentedDuration(tester), Duration.zero, reason: '减弱动态 → 零时长');

    await _pumpHost(tester, reduce: false, child: segmented());
    expect(_segmentedDuration(tester), LmMotion.base);
  });

  // ── 4. essential 例外：状态信息动效保留 ─────────────────────────────

  testWidgets('loading 指示器在减弱动态下保留（WCAG 2.3.3 essential 例外）', (tester) async {
    await _pumpHost(
      tester,
      reduce: true,
      child: GlassPillButton(label: '提交', onPressed: () {}, loading: true),
    );
    expect(
      find.descendant(
        of: find.byType(GlassPillButton),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
      reason: 'loading 承载状态信息，减弱动态下仍需指示（非装饰性动效例外）',
    );
  });

  // ── 5. 源码审计：每个 repeat() 站点上方必有降级守卫 ───────────────────

  test('源码审计：lib 全域每个 repeat() 站点上方 30 行内必须有减弱动态守卫', () {
    final libDir = Directory('lib');
    expect(libDir.existsSync(), isTrue, reason: '需在仓库根运行');

    const guardMarkers = [
      'LmMotion.shouldAnimate',
      'LmMotion.reducedMotion',
      '_shouldPulse',
      '_shouldSpin',
    ];

    final sites = <(String, int)>[];
    final unguarded = <String>[];
    for (final entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].contains('.repeat(')) continue;
        sites.add((entity.path, i + 1));
        final from = (i - 30).clamp(0, i);
        final window = lines.sublist(from, i + 1).join('\n');
        if (!guardMarkers.any(window.contains)) {
          unguarded.add('${entity.path}:${i + 1}');
        }
      }
    }

    expect(
      unguarded,
      isEmpty,
      reason: '以下 repeat() 站点上方缺少减弱动态守卫，必须改为 shouldAnimate 门禁：\n'
          '${unguarded.join('\n')}',
    );

    // 钉住站点数：新增循环动效须同步登记守卫并更新此数。
    expect(
      sites.length,
      10,
      reason: 'repeat() 站点数变化（当前应为 10），新增循环须补守卫断言：\n'
          '${sites.map((s) => '${s.$1}:${s.$2}').join('\n')}',
    );
  });
}

enum _Demo { a, b }

Future<void> _pumpHost(
  WidgetTester tester, {
  required bool reduce,
  required Widget child,
}) async {
  final theme = ThemeCatalog.assemble(
    const LmAppearance(structureId: 'glass', paletteId: 'bordeaux'),
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
          child: Scaffold(body: Center(child: child)),
        ),
      ),
    ),
  );
}

Duration? _segmentedDuration(WidgetTester tester) {
  final containers = tester.widgetList<AnimatedContainer>(
    find.descendant(
      of: find.byType(GlassSegmented<_Demo>),
      matching: find.byType(AnimatedContainer),
    ),
  );
  expect(containers, isNotEmpty, reason: '分段项应有 AnimatedContainer');
  return containers.first.duration;
}

/// 循环动效判据：在有限模拟时间内能否静置。
///
/// 返回 true = 无持续动画（已静置）；false = 有循环动效在持续排帧。
/// 比 `hasScheduledFrame` 稳（后者受首帧调度噪声影响）。
Future<bool> _settlesWithin(WidgetTester tester) async {
  try {
    await tester.pumpAndSettle(
      const Duration(milliseconds: 16),
      EnginePhase.sendSemanticsUpdate,
      const Duration(milliseconds: 600),
    );
    return true;
  } catch (_) {
    return false;
  }
}

double _breathingOpacity(WidgetTester tester) {
  final opacities = tester
      .widgetList<Opacity>(
        find.descendant(
          of: find.byType(BreathingDot),
          matching: find.byType(Opacity),
        ),
      )
      .toList();
  expect(opacities, hasLength(1));
  return opacities.single.opacity;
}
