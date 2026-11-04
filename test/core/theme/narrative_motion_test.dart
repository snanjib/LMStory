import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/lm_activity_dots.dart';
import 'package:lmstory/core/theme/shared/components/lm_arrival.dart';
import 'package:lmstory/core/theme/shared/components/lm_interactive_motion.dart';
import 'package:lmstory/core/theme/shared/components/lm_state_transition.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/message_bubble/bubble_content.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/suggest_reply_overlay.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_work_group.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/collapsible_settings_section.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../test_helpers/load_app_fonts.dart';

const _paintKey = ValueKey('motion-surface');

void main() {
  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
    await loadAppFonts(withSystemCjkFallback: true);
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  for (final structure in ['classic', 'glass', 'brutal', 'wonder']) {
    for (final palette in ['classic', 'bordeaux']) {
      for (final brightness in Brightness.values) {
        testWidgets(
            '$structure $palette $brightness activity paints and settles',
            (tester) async {
          final appearance =
              LmAppearance(structureId: structure, paletteId: palette);
          var builds = 0;
          final child = Builder(
            builder: (_) {
              builds++;
              return const LmActivityDots(label: 'waiting');
            },
          );
          await _host(
            tester,
            child,
            appearance: appearance,
            brightness: brightness,
          );
          await tester.pump();
          final start = await _pixels(tester);
          await tester.pump(const Duration(milliseconds: 250));
          final next = await _pixels(tester);
          expect(listEquals(start, next), isFalse);
          expect(builds, 1, reason: 'Paint ticks must not rebuild ancestors.');
          await _host(
            tester,
            child,
            appearance: appearance,
            brightness: brightness,
            reduce: true,
          );
          await tester.pumpAndSettle();
          final staticFrame = await _pixels(tester);
          await tester.pump(const Duration(seconds: 2));
          expect(listEquals(staticFrame, await _pixels(tester)), isTrue);
          expect(tester.binding.transientCallbackCount, 0);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets('activity pauses with visibility, lifecycle and ticker mode',
      (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    addTearDown(
      () => tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed),
    );
    final child = SizedBox(
      height: 120,
      child: SingleChildScrollView(
        controller: scroll,
        child: const Column(
          children: [LmActivityDots(), SizedBox(height: 1600)],
        ),
      ),
    );
    await _host(tester, child);
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    scroll.jumpTo(600);
    await tester.pump();
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    scroll.jumpTo(0);
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await _host(tester, child, ticker: false);
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    await _host(tester, child);
    await tester.pump();
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await _host(tester, child, accessible: true);
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
  });

  testWidgets('arrival preserves child state, layout and streaming updates',
      (tester) async {
    var builds = 0;
    final child = Builder(
      builder: (_) {
        builds++;
        return const SizedBox(width: 80, height: 40, child: Text('稿件'));
      },
    );
    await _host(tester, LmArrival(trigger: 'round', child: child));
    final footprint = tester.getSize(find.byType(LmArrival));
    await tester.pump(LmMotion.micro);
    expect(builds, 1);
    expect(tester.getSize(find.byType(LmArrival)), footprint);
    await tester.pumpAndSettle();
    await _host(tester, LmArrival(trigger: 'round', child: child));
    await tester.pump();
    expect(tester.binding.transientCallbackCount, 0);
    await _host(tester, LmArrival(trigger: 'next-round', child: child));
    expect(tester.binding.transientCallbackCount, greaterThan(0));
    await _host(
      tester,
      LmArrival(trigger: 'another-round', child: child),
      reduce: true,
    );
    await tester.pumpAndSettle();
    expect(tester.binding.transientCallbackCount, 0);
    expect(
      tester
          .widget<Opacity>(
            find.descendant(
              of: find.byType(LmArrival),
              matching: find.byType(Opacity),
            ),
          )
          .opacity,
      1,
    );
  });

  testWidgets('outgoing state cannot fire callbacks or remain in semantics',
      (tester) async {
    var taps = 0;
    await _host(
      tester,
      LmStateTransition(
        stateKey: 'ready',
        child: TextButton(onPressed: () => taps++, child: const Text('send')),
      ),
    );
    await _host(
      tester,
      const LmStateTransition(
        stateKey: 'busy',
        child: SizedBox(width: 80, height: 40),
      ),
    );
    await tester.tap(find.text('send'), warnIfMissed: false);
    expect(taps, 0);
    expect(
      find.ancestor(
        of: find.text('send'),
        matching: find.byType(ExcludeSemantics),
      ),
      findsOneWidget,
    );
    await tester.pumpAndSettle();
    expect(find.text('send'), findsNothing);
  });

  testWidgets('waiting dots persist through thinking and give way to text',
      (tester) async {
    Widget bubble(String content, {bool thinking = false}) => Builder(
          builder: (context) => BubbleMessageContent(
            message: ChatMessage(
              messageId: 'reply',
              sessionId: 'session',
              role: 'assistant',
              content: content,
              createdAt: DateTime(2026),
            ),
            isStreaming: true,
            isThinking: thinking,
            isUser: false,
            isSummary: false,
            colors: context.lm.palette,
          ),
        );
    await _host(tester, bubble(''));
    expect(find.byType(LmActivityDots), findsOneWidget);
    await _host(tester, bubble('', thinking: true));
    expect(find.byType(LmActivityDots), findsOneWidget);
    await _host(tester, bubble('第一句正文'));
    expect(find.byType(LmActivityDots), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('interactive wrapper preserves the existing tap callback',
      (tester) async {
    var taps = 0;
    await _host(
      tester,
      LmInteractiveMotion(
        child: TextButton(
          onPressed: () => taps++,
          child: const Text('continue'),
        ),
      ),
    );
    await tester.tap(find.text('continue'));
    await tester.pumpAndSettle();
    expect(taps, 1);
  });

  for (final structure in ['classic', 'glass', 'brutal', 'wonder']) {
    testWidgets('$structure real controls retain actions during motion',
        (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var expanded = false;
      var selected = -1;
      var closed = false;
      late StateSetter update;
      await _host(
        tester,
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const DirectorWorkGroup(
                    live: true,
                    timeline: [
                      AgentTimelineBlock(
                        kind: AgentTimelineKind.narration,
                        stepIndex: 1,
                        text: '正在整理这一幕的来信。',
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  CollapsibleSettingsSection(
                    title: '阅读设置',
                    isExpanded: expanded,
                    onToggle: () => update(() => expanded = !expanded),
                    child: const Text('正文保持安静，反馈跟随操作。'),
                  ),
                  const SizedBox(height: 24),
                  SuggestReplyOverlay(
                    replies: expanded ? ['打开信封，看看是谁寄来的。', '先把信收好，向码头走去。'] : [],
                    isGenerating: !expanded,
                    isExpanded: true,
                    onSelect: (index) => selected = index,
                    onClose: () => closed = true,
                    onToggle: () {},
                  ),
                ],
              ),
            );
          },
        ),
        appearance: LmAppearance(structureId: structure, paletteId: 'bordeaux'),
      );
      for (var frame = 0; frame < 24; frame++) {
        if (frame == 12) update(() => expanded = true);
        await tester.pump(const Duration(milliseconds: 50));
        await _capture(tester, '${structure}_controls', frame);
      }
      await tester.tap(find.text('打开信封，看看是谁寄来的。'));
      expect(selected, 0);
      await tester.tap(find.byTooltip('关闭'));
      expect(closed, isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}

Future<void> _host(
  WidgetTester tester,
  Widget child, {
  LmAppearance appearance = const LmAppearance(),
  Brightness brightness = Brightness.dark,
  bool reduce = false,
  bool accessible = false,
  bool ticker = true,
}) async {
  final theme = ThemeCatalog.assemble(appearance, brightness);
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        themeAnimationDuration: Duration.zero,
        theme: theme.copyWith(
          textTheme: theme.textTheme.apply(
            fontFamilyFallback: kCjkFallbackFamilies,
          ),
        ),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              disableAnimations: reduce,
              accessibleNavigation: accessible,
            ),
            child: TickerMode(
              enabled: ticker,
              child: Scaffold(
                body: RepaintBoundary(
                  key: _paintKey,
                  child: Builder(
                    builder: (inner) => inner.lmVenue(Center(child: child)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<List<int>> _pixels(WidgetTester tester) async {
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_paintKey));
  return (await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData();
    image.dispose();
    return bytes!.buffer.asUint8List().toList();
  }))!;
}

Future<void> _capture(WidgetTester tester, String name, int frame) async {
  final directory = Platform.environment['LMSTORY_MOTION_PREVIEW_DIR'];
  if (directory == null) return;
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_paintKey));
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await Directory(directory).create(recursive: true);
    await File('$directory/${name}_${frame.toString().padLeft(2, '0')}.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
  });
}
