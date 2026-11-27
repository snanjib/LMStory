import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_message_bubble.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_message_bubble.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/presentation/utils/conversation_round_navigation.dart';
import 'package:lmstory/i18n/strings.g.dart';

List<ChatMessage> navigationMessages(String sessionId) => [
      for (var i = 1; i <= 8; i++) ...[
        ChatMessage(
          sessionId: sessionId,
          messageId: 'u$i',
          role: 'user',
          content: 'Question $i',
          createdAt: DateTime(2026, 1, i),
        ),
        ChatMessage(
          sessionId: sessionId,
          messageId: 'a$i',
          role: 'assistant',
          content: i == 6
              ? List.filled(95, 'One paragraph in a long reply.').join('\n\n')
              : 'Answer $i',
          createdAt: DateTime(2026, 1, i, 1),
        ),
      ],
    ];

Future<void> checkRoundNavigation(WidgetTester tester) async {
  final list = find.byType(ListView).first;
  final position = tester.widget<ListView>(list).controller!.position;
  Finder row(int index) => find
      .byWidgetPredicate((w) => w is ConversationRoundRow && w.index == index);
  Future<void> layout() async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pump();
  }

  position.jumpTo(0);
  await layout();
  for (var step = 0; row(11).evaluate().isEmpty && step < 30; step++) {
    position.jumpTo(
      (position.pixels + position.viewportDimension * .6)
          .clamp(0, position.maxScrollExtent),
    );
    await layout();
  }
  final reply = tester.renderObject<RenderBox>(row(11));
  final top =
      RenderAbstractViewport.of(reply).getOffsetToReveal(reply, 0).offset;
  position.jumpTo(top + (reply.size.height - position.viewportDimension) / 2);
  await layout();
  final viewport = tester.getRect(list);
  final before = tester.getTopLeft(row(11)).dy;
  for (final fraction in [.5, .015, .985]) {
    await tester.tapAt(
      Offset(
        viewport.left + viewport.width * .35,
        viewport.top + viewport.height * fraction,
      ),
    );
    await layout();
    expect(tester.getTopLeft(row(11)).dy, closeTo(before, 1));
  }
  final up = find.byTooltip(t.chat.navigation.prevUserMessage);
  final down = find.byTooltip(t.chat.navigation.nextUserMessage);
  expect(up.hitTestable(), findsNothing);
  await tester.drag(list, const Offset(0, -50));
  await layout();
  final icon = find.descendant(of: up, matching: find.byType(Icon));
  // An edge tap lies well outside the icon itself.
  await tester.tapAt(tester.getCenter(icon) + const Offset(21, 18));
  await layout();
  void check(int turn) {
    final target = row((turn - 1) * 2);
    expect(
      find.descendant(of: target, matching: find.byKey(ValueKey('u$turn'))),
      findsOneWidget,
    );
    final bubble = find.descendant(
      of: target,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is SimpleMessageBubble &&
                widget.message.messageId == 'u$turn' ||
            widget is IntermediateMessageBubble &&
                widget.isUser &&
                widget.content == 'Question $turn',
      ),
    );
    expect(bubble, findsOneWidget);
    expect(
      tester.getTopLeft(bubble).dy,
      closeTo(tester.getTopLeft(list).dy, 1),
    );
  }

  check(5);
  await tester.tap(up);
  await tester.tap(up);
  await layout();
  check(3);
  for (var turn = 4; turn <= 8; turn++) {
    await tester.tap(down);
    await layout();
    check(turn);
  }
  expect(
    tester
        .widget<IconButton>(
          find.ancestor(
            of: find.byIcon(Icons.keyboard_arrow_down),
            matching: find.byType(IconButton),
          ),
        )
        .onPressed,
    isNull,
  );
  await tester.pump(const Duration(seconds: 3));
  await layout();
  final bottom = find.byTooltip(t.chat.scrollToLatest);
  expect(bottom.hitTestable(), findsOneWidget);
  expect(up.hitTestable(), findsNothing);
  await tester.tap(bottom);
  await layout();
  expect(position.extentAfter, closeTo(0, 1));
}
