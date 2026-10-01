import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/lm_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/wonder/wonder_components.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';

void main() {
  testWidgets('漫游竖向入口使用一致圆角和常规内边距', (tester) async {
    var taps = 0;
    final theme = ThemeCatalog.assemble(
      const LmAppearance(structureId: 'wonder'),
      Brightness.light,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => context.lmUi.entryCard(
                context,
                onTap: () => taps++,
                fallbackColor: Colors.transparent,
                child: const Text('Story entry'),
              ),
            ),
          ),
        ),
      ),
    );

    final entry = find.text('Story entry');
    final card = find.ancestor(
      of: entry,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Material &&
            widget.shape is RoundedRectangleBorder &&
            (widget.shape! as RoundedRectangleBorder).borderRadius ==
                WonderComponents.cardRadius,
      ),
    );
    expect(card, findsOneWidget);
    final shape = tester.widget<Material>(card).shape!;
    expect(shape, isA<RoundedRectangleBorder>());
    final roundedShape = shape as RoundedRectangleBorder;
    expect(roundedShape.side.width, 1);
    expect(
      roundedShape.side.color,
      theme.extension<LmTokens>()!.palette.dividerStrong,
    );

    expect(
      find.ancestor(
        of: entry,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Padding &&
              widget.padding == const EdgeInsets.all(LmSpacing.sMd),
        ),
      ),
      findsOneWidget,
    );

    await tester.tap(entry);
    await tester.pump();
    expect(taps, 1);
  });
}
