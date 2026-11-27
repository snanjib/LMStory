import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_compact_composer.dart';
import 'package:lmstory/features/settings/domain/entities/input_keys.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/context_usage_ring.dart';
import 'package:lmstory/i18n/strings.g.dart';

void main() {
  late Translations zh;

  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
    zh = await AppLocale.zhCn.build();
  });

  Widget wrap(
    Widget child, {
    ThemeData? theme,
    double textScale = 1.0,
    double width = 390,
  }) {
    return TranslationProvider(
      child: MaterialApp(
        theme: theme ??
            ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 844),
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            body: Align(alignment: Alignment.bottomCenter, child: child),
          ),
        ),
      ),
    );
  }

  group('DirectorCompactComposer', () {
    testWidgets(
        'shows quote, paren, and suggest pills permanently and triggers callbacks',
        (tester) async {
      var quoted = 0;
      var parened = 0;
      var suggested = 0;
      var contextTapped = 0;

      await tester.pumpWidget(
        wrap(
          DirectorCompactComposer(
            phase: IntermediatePhase.idle,
            onSend: (_) {},
            onCancel: () {},
            onAddQuote: () => quoted++,
            onAddParen: () => parened++,
            onSuggest: () => suggested++,
            isGeneratingSuggest: false,
            canSuggest: true,
            contextNumerator: 4000,
            contextDenominator: 32000,
            onContextTap: () => contextTapped++,
          ),
        ),
      );

      expect(find.byType(ContextUsageChip), findsOneWidget);
      expect(
        find.byKey(const ValueKey('director-composer-tools-toggle')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('director-composer-add-quote')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('director-composer-add-paren')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('director-composer-suggest')),
        findsOneWidget,
      );

      await tester
          .tap(find.byKey(const ValueKey('director-composer-add-quote')));
      await tester
          .tap(find.byKey(const ValueKey('director-composer-add-paren')));
      await tester.tap(find.byKey(const ValueKey('director-composer-suggest')));
      await tester.tap(find.byType(ContextUsageChip));
      await tester.pump();

      expect(quoted, 1);
      expect(parened, 1);
      expect(suggested, 1);
      expect(contextTapped, 1);
    });

    testWidgets(
        'send, insertAtCursor, draft clear, stop button, and queued slot work',
        (tester) async {
      final key = GlobalKey<DirectorCompactComposerState>();
      String? sent;
      var cancelled = false;

      Widget buildComposer({
        IntermediatePhase phase = IntermediatePhase.idle,
        bool isStopping = false,
        bool isManualCompacting = false,
        Widget? queuedSlot,
      }) =>
          wrap(
            DirectorCompactComposer(
              key: key,
              phase: phase,
              isStopping: isStopping,
              isManualCompacting: isManualCompacting,
              onSend: (text) => sent = text,
              onCancel: () => cancelled = true,
              onAddQuote: () => key.currentState
                  ?.insertAtCursor('""', cursorOffsetFromStart: 1),
              onAddParen: () {},
              onSuggest: () {},
              isGeneratingSuggest: false,
              canSuggest: false,
              queuedMessageSlot: queuedSlot,
            ),
          );

      await tester.pumpWidget(buildComposer());

      // Insert quote at cursor (permanently visible without tapping +)
      await tester
          .tap(find.byKey(const ValueKey('director-composer-add-quote')));
      await tester.pump();
      expect(key.currentState!.currentText, '""');

      // Manual compacting disables send without clearing text
      await tester.pumpWidget(buildComposer(isManualCompacting: true));
      await tester.tap(find.byTooltip(zh.intermediate.chat.send));
      await tester.pump();
      expect(sent, isNull);
      expect(key.currentState!.currentText, '""');

      // Idle enables send while keeping helper strip permanently visible
      await tester.pumpWidget(buildComposer());
      await tester.tap(find.byTooltip(zh.intermediate.chat.send));
      await tester.pumpAndSettle();
      expect(sent, '""');
      expect(key.currentState!.currentText, isEmpty);
      expect(
        find.byKey(const ValueKey('director-composer-add-quote')),
        findsOneWidget,
      );

      // Generating phase shows stop button + queued message slot
      await tester.pumpWidget(
        buildComposer(
          phase: IntermediatePhase.generating,
          queuedSlot: const Text('已排队：下一句指令'),
        ),
      );
      await tester.pump();
      expect(find.text('已排队：下一句指令'), findsOneWidget);
      await tester.tap(find.byTooltip(zh.intermediate.chat.stop));
      await tester.pump();
      expect(cancelled, isTrue);
    });

    testWidgets('respects sendKey and locked mode', (tester) async {
      final key = GlobalKey<DirectorCompactComposerState>();
      String? sent;

      await tester.pumpWidget(
        wrap(
          DirectorCompactComposer(
            key: key,
            phase: IntermediatePhase.idle,
            sendKey: SendKey.ctrlEnter,
            newlineKey: NewlineKey.enter,
            onSend: (text) => sent = text,
            onCancel: () {},
            onAddQuote: () {},
            onAddParen: () {},
            onSuggest: () {},
            isGeneratingSuggest: false,
            canSuggest: false,
          ),
        ),
      );

      key.currentState!.setText('继续调查');
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      expect(sent, isNull);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(sent, '继续调查');
    });
  });

  group('4 structures x 2 palettes x light/dark at 320dp & 1.3x fontScale', () {
    for (final structure in ThemeCatalog.structures) {
      for (final palette in ThemeCatalog.palettes) {
        for (final brightness in Brightness.values) {
          testWidgets(
              'composer zero overflow: ${structure.id}/${palette.id}/${brightness.name}',
              (tester) async {
            final theme = ThemeCatalog.assemble(
              LmAppearance(structureId: structure.id, paletteId: palette.id),
              brightness,
            );
            await tester.pumpWidget(
              wrap(
                DirectorCompactComposer(
                  phase: IntermediatePhase.idle,
                  onSend: (_) {},
                  onCancel: () {},
                  onAddQuote: () {},
                  onAddParen: () {},
                  onSuggest: () {},
                  isGeneratingSuggest: false,
                  canSuggest: true,
                  contextNumerator: 12000,
                  contextDenominator: 32000,
                  onContextTap: () {},
                ),
                theme: theme,
                textScale: 1.3,
                width: 320,
              ),
            );
            await tester.pump();
            expect(tester.takeException(), isNull);
            expect(
              find.byKey(const ValueKey('director-composer-add-quote')),
              findsOneWidget,
            );
          });
        }
      }
    }
  });
}
