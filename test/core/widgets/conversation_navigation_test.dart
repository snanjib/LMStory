import 'dart:ui' show SemanticsAction;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_message_navigation.dart';
import 'package:lmstory/core/widgets/conversation_navigation.dart';
import 'package:lmstory/i18n/strings.g.dart';

Finder get _rail => find.descendant(
      of: find.byType(SimpleMessageNavigation),
      matching: find.byWidgetPredicate(
        (widget) => widget is Container && widget.decoration is BoxDecoration,
      ),
    );

void main() {
  testWidgets(
      'only manual movement opens navigation and collapsed targets pass text selection through',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    var selected = false;
    final roundJumps = <bool>[];
    final text = List.filled(24, 'select this word').join(' ');
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: ConversationNavigation(
              controller: controller,
              onTop: () => controller.jumpTo(0),
              onBottom: () =>
                  controller.jumpTo(controller.position.maxScrollExtent),
              canJumpRound: ({required forward}) => true,
              jumpRound: ({required forward}) => roundJumps.add(forward),
              child: ListView.builder(
                controller: controller,
                itemCount: 40,
                itemBuilder: (_, i) => SelectableText(
                  '$i $text',
                  style: const TextStyle(fontSize: 16, height: 1.25),
                  onSelectionChanged: (selection, cause) {
                    if (cause == SelectionChangedCause.longPress &&
                        !selection.isCollapsed) {
                      selected = true;
                    }
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final up = find.byTooltip(t.chat.navigation.prevUserMessage);
    final latest = find.byTooltip(t.chat.scrollToLatest);
    controller.jumpTo(400);
    await tester.pumpAndSettle();
    expect(up.hitTestable(), findsNothing);
    expect(latest.hitTestable(), findsNothing);

    await tester.sendEventToBinding(
      const PointerScrollEvent(
        position: Offset(200, 200),
        scrollDelta: Offset(0, 65),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    expect(up.hitTestable(), findsOneWidget);
    final rail = tester.getRect(_rail);
    final decoration =
        tester.widget<Container>(_rail).decoration! as BoxDecoration;
    final button = tester.getRect(up);
    expect(rail.size, const Size(32, 176));
    expect(rail.center.dx, button.center.dx);
    expect(decoration.color!.a, closeTo(.6, .01));
    expect(button.size, const Size(48, 48));
    final semantics = tester.ensureSemantics();
    final targetNode = tester.getSemantics(up);
    final owner = targetNode.owner!;
    expect(
      targetNode
          .getSemanticsData()
          .hasAction(SemanticsAction.didGainAccessibilityFocus),
      isTrue,
    );
    owner.performAction(
      targetNode.id,
      SemanticsAction.didGainAccessibilityFocus,
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(up.hitTestable(), findsOneWidget);
    owner.performAction(
      targetNode.id,
      SemanticsAction.didLoseAccessibilityFocus,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 2900));
    expect(up.hitTestable(), findsOneWidget);
    final outerEdge = button.centerLeft + const Offset(1, 0);
    expect(rail.contains(outerEdge), isFalse);
    await tester.tapAt(outerEdge);
    expect(roundJumps, [false]);
    await tester.pump(const Duration(milliseconds: 2900));
    expect(up.hitTestable(), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 110));
    await tester.pump(const Duration(milliseconds: 210));
    expect(up.hitTestable(), findsNothing);
    expect(latest.hitTestable(), findsOneWidget);
    final compact = tester.getRect(_rail);
    expect(compact.size, const Size.square(32));
    expect(compact.center, tester.getCenter(latest));
    await tester.longPressAt(button.centerLeft + const Offset(2, 0));
    await tester.pump();
    expect(selected, isTrue);
    semantics.dispose();
  });

  testWidgets(
      'dark high-contrast navigation keeps a slender horizontal rail and four disjoint targets',
      (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(
                disableAnimations: true,
                highContrast: true,
              ),
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 360,
                  height: 140,
                  child: ConversationNavigation(
                    controller: controller,
                    onTop: () {},
                    onBottom: () {},
                    canJumpRound: ({required forward}) => true,
                    jumpRound: ({required forward}) {},
                    child: ListView(
                      controller: controller,
                      children: const [SizedBox(height: 1500)],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.drag(find.byType(ListView), const Offset(0, -40));
    await tester.pumpAndSettle();
    final rects = [
      t.chat.navigation.jumpToTop,
      t.chat.navigation.prevUserMessage,
      t.chat.navigation.nextUserMessage,
      t.chat.navigation.jumpToBottom,
    ].map((s) => tester.getRect(find.byTooltip(s))).toList();
    final rail = tester.getRect(_rail);
    final decoration =
        tester.widget<Container>(_rail).decoration! as BoxDecoration;
    final colors = tester.element(_rail).lm.palette;
    expect(rail.size, const Size(176, 32));
    expect(rail.center.dy, rects.first.center.dy);
    expect(decoration.color, colors.surfaceElevated);
    expect(decoration.border, Border.all(color: colors.dividerStrong));
    for (var i = 0; i < rects.length; i++) {
      expect(rects[i].size, const Size(48, 48));
      expect(rects[i].top, rects.first.top);
      if (i > 0) expect(rects[i].left, rects[i - 1].right);
    }
  });
}
