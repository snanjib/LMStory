import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/presentation/widgets/chat_mode_input_area.dart';
import 'package:lmstory/i18n/strings.g.dart';

void main() {
  Widget input(Future<bool> Function(String text) onSend) => ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: ChatModeInputArea(
                onSend: (text, attachments) => onSend(text),
                onCancel: () {},
                isSending: false,
                isStreaming: false,
              ),
            ),
          ),
        ),
      );

  testWidgets('发送被拒时原地保留输入，之后可重新发送', (tester) async {
    final attempted = <String>[];
    var accept = false;
    await tester.pumpWidget(
      input((text) async {
        attempted.add(text);
        return accept;
      }),
    );
    final field = find.byType(TextField);
    const draft = '  保留原输入  ';
    await tester.enterText(field, draft);
    await tester.pump();

    final send = find.byIcon(Icons.send_rounded);
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(attempted, [draft.trim()]);
    expect(tester.widget<TextField>(field).controller?.text, draft);

    accept = true;
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(attempted, [draft.trim(), draft.trim()]);
    expect(tester.widget<TextField>(field).controller?.text, isEmpty);
  });

  testWidgets('等待发送回执期间连点只发一次，新编辑仍保留', (tester) async {
    final response = Completer<bool>();
    final attempted = <String>[];
    await tester.pumpWidget(
      input((text) {
        attempted.add(text);
        return response.future;
      }),
    );
    final field = find.byType(TextField);
    await tester.enterText(field, '原输入');
    await tester.pump();

    final send = find.byIcon(Icons.send_rounded);
    await tester.tap(send);
    await tester.tap(send);
    expect(attempted, ['原输入']);
    expect(tester.widget<TextField>(field).controller?.text, '原输入');

    await tester.enterText(field, '等待期间编辑的输入');
    response.complete(true);
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).controller?.text, '等待期间编辑的输入');
  });
}
