import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/shared/components/breathing_dot.dart';
import 'package:lmstory/core/theme/system/palettes/classic/classic_palette.dart';

void main() {
  Future<void> host(
    WidgetTester tester, {
    bool reduce = false,
    double size = 8,
  }) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: MediaQueryData(accessibleNavigation: reduce),
              child: BreathingDot(size: size),
            ),
          ),
        ),
      );

  testWidgets('activity dot paints the default circle in the primary color',
      (tester) async {
    await host(tester);
    await tester.pump(const Duration(milliseconds: 100));
    final (width, height, bytes) = await pixels(tester);
    expect((width, height), (8, 8));
    final center = (4 * width + 4) * 4;
    final color = ClassicPaletteValues.light.primary;
    expect(bytes[center], closeTo((color.r * 255).round(), 1));
    expect(bytes[center + 1], closeTo((color.g * 255).round(), 1));
    expect(bytes[center + 2], closeTo((color.b * 255).round(), 1));
    expect(bytes[center + 3], greaterThan(0));
    expect(bytes[3], lessThan(bytes[center + 3] / 4));
  });

  testWidgets('activity changes its painted pixels between frames',
      (tester) async {
    await host(tester);
    await tester.pump(const Duration(milliseconds: 100));
    final first = (await pixels(tester)).$3;
    await tester.pump(const Duration(milliseconds: 300));
    expect(listEquals(first, (await pixels(tester)).$3), isFalse);
  });

  testWidgets('reduced motion keeps a visible stationary dot', (tester) async {
    await host(tester, reduce: true);
    await tester.pumpAndSettle();
    final first = (await pixels(tester)).$3;
    await tester.pump(const Duration(seconds: 2));
    expect(listEquals(first, (await pixels(tester)).$3), isTrue);
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 0.7);
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('custom size preserves the requested painted footprint',
      (tester) async {
    await host(tester, size: 12);
    await tester.pump(const Duration(milliseconds: 100));
    final result = await pixels(tester);
    expect((result.$1, result.$2), (12, 12));
    expect(tester.takeException(), isNull);
  });
}

Future<(int, int, List<int>)> pixels(WidgetTester tester) async {
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.descendant(
      of: find.byType(BreathingDot),
      matching: find.byType(RepaintBoundary),
    ),
  );
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes =
        await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    final result =
        (image.width, image.height, bytes!.buffer.asUint8List().toList());
    image.dispose();
    return result;
  }))!;
}
