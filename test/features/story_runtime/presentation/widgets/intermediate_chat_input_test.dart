import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
      reason: '压缩中发送按钮应禁用',
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

  testWidgets('重生成准备中：发送禁用且文本不被清空（输入不蒸发）', (tester) async {
    var sent = 0;
    await tester.pumpWidget(
      wrap(
        IntermediateChatInput(
          phase: IntermediatePhase.idle,
          isPreparingRegenerate: true,
          onSend: (_) => sent++,
          onCancel: () {},
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '准备期输入');
    await tester.pump();

    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    expect(sent, 0, reason: '准备中发送应被拒收');
    expect(
      find.widgetWithText(TextField, '准备期输入'),
      findsOneWidget,
      reason: '拒收时文本必须保留在输入框（此前先清空后拒绝会蒸发）',
    );
  });

  testWidgets('导演正在生成时输入保留在编辑框，发送操作未提交待发', (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(
      wrap(
        IntermediateChatInput(
          phase: IntermediatePhase.reviewing,
          isDirector: true,
          onSend: sent.add,
          onCancel: () {},
        ),
      ),
    );
    const input = '生成期间输入的第二句';
    await tester.enterText(find.byType(TextField), input);
    await tester.pump();
    expect(find.byIcon(Icons.send_rounded), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(sent, isEmpty);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      input,
    );
  });
}
