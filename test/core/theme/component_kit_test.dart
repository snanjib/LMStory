import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_setting_card.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';

void main() {
  for (final structureId in ['brutal', 'wonder']) {
    for (final paletteId in ['classic', 'bordeaux']) {
      for (final brightness in Brightness.values) {
        testWidgets(
          '$structureId $paletteId $brightness renders and handles settings',
          (tester) async {
            var taps = 0;
            final theme = ThemeCatalog.assemble(
              LmAppearance(
                structureId: structureId,
                paletteId: paletteId,
              ),
              brightness,
            );
            expect(theme.extension<LmComponents>(), isNotNull);

            await tester.pumpWidget(
              MaterialApp(
                theme: theme,
                home: Builder(
                  builder: (context) => context.lmVenue(
                    Scaffold(
                      backgroundColor: context.scaffoldBgOf(
                        theme.scaffoldBackgroundColor,
                      ),
                      body: ListView(
                        children: [
                          IntermediateSettingCard(
                            icon: Icons.book,
                            title: 'Available setting',
                            subtitle: 'Story preferences',
                            onTap: () => taps++,
                          ),
                          IntermediateSettingCard(
                            icon: Icons.lock,
                            title: 'Unavailable setting',
                            subtitle: 'Wait until generation ends',
                            onTap: () => taps++,
                            enabled: false,
                          ),
                          Builder(
                            builder: (context) => context.lmUi.entryCard(
                              context,
                              onTap: () => taps++,
                              fallbackColor:
                                  Theme.of(context).colorScheme.surface,
                              child: const Text('Story entry'),
                            ),
                          ),
                          Builder(
                            builder: (context) => context.lmUi.messageBubble(
                              context,
                              child: const Text('Story text'),
                              isUser: false,
                              standardLayout: false,
                              narrative: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            );

            expect(find.text('Story text'), findsOneWidget);
            await tester.tap(find.text('Available setting'));
            await tester.pump();
            expect(taps, 1);
            await tester.tap(find.text('Unavailable setting'));
            await tester.pump();
            expect(taps, 1);
            expect(find.text('Story entry'), findsOneWidget);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
