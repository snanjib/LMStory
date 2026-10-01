import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/intermediate_chat_input.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// IntermediateChatInput 发送互斥测试
///
/// 手动压缩全程 phase 恒为 idle、控制器 sendMessage 静默 no-op——
/// 发送判据必须并入 isManualCompacting，否则按钮可点而毫无反应。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Widget wrap(Widget child) => TranslationProvider(
        child: MaterialApp(home: Scaffold(body: child)),
      );

  Future<void> pumpInput(
    WidgetTester tester, {
    required bool isManualCompacting,
    required ValueChanged<String> onSend,
  }) async {
    await tester.pumpWidget(
      wrap(
        IntermediateChatInput(
          phase: IntermediatePhase.idle,
          isManualCompacting: isManualCompacting,
          onSend: onSend,
          onCancel: () {},
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '压缩期间想说话');
    await tester.pump();
  }

  testWidgets('手动压缩中：发送按钮禁用，点击不触发 onSend', (tester) async {
    var sent = 0;
    await pumpInput(
      tester,
      isManualCompacting: true,
      onSend: (_) => sent++,
    );

    final sendButton = find.byIcon(Icons.send_rounded);
    expect(sendButton, findsOneWidget);
    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: sendButton,
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNull,
      reason: '压缩中发送按钮应禁用（ST7-3）',
    );

    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    expect(sent, 0);
  });

  testWidgets('非压缩 idle：发送按钮可用（对照组）', (tester) async {
    var sent = 0;
    await pumpInput(
      tester,
      isManualCompacting: false,
      onSend: (_) => sent++,
    );

    expect(
      tester
          .widget<IconButton>(
            find.ancestor(
              of: find.byIcon(Icons.send_rounded),
              matching: find.byType(IconButton),
            ),
          )
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    expect(sent, 1);
  });
}
