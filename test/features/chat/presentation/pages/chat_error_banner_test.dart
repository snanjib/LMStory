import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/domain/services/simple_failure_classifier.dart';
import 'package:lmstory/features/chat/presentation/pages/chat/widgets/chat_error_banner.dart';
import 'package:lmstory/i18n/strings.g.dart';

void main() {
  testWidgets('the chat banner reads the saved summary and guidance',
      (tester) async {
    final message = const SimpleErrorPayload(
      message: 'Chat model not configured',
      code: 'S001',
      suggestion: 'Open Settings to set up a provider.',
      detail: 'internal diagnostic',
    ).encode();
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: ChatErrorBanner(message: message, onDismiss: () {}),
          ),
        ),
      ),
    );

    expect(find.textContaining('Chat model not configured'), findsOneWidget);
    expect(find.textContaining('Open Settings to set up'), findsOneWidget);
    expect(find.textContaining('lmerr:'), findsNothing);
    expect(find.textContaining('internal diagnostic'), findsNothing);
  });
}
