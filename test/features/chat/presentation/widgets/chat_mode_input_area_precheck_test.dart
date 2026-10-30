import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/domain/entities/message_attachment.dart';
import 'package:lmstory/features/chat/presentation/widgets/chat_mode_input_area.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// ChatModeInputArea 发送前预检测试
///
/// 草稿会话无预设/模型/Key 时控制器拒绝发送——此前输入区先清空再回调，
/// 已打文本与附件原地蒸发不可恢复。预检钩子（onBeforeSend）失败时输入
/// 必须原地保留、onSend 不得触发；通过时清空并正常发送。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Widget wrap(Widget child) => ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(home: Scaffold(body: child)),
        ),
      );

  ChatModeInputArea input({
    required bool Function(String text) precheck,
    required void Function(String text) onSend,
  }) =>
      ChatModeInputArea(
        onSend: (text, attachments) => onSend(text),
        onCancel: () {},
        isSending: false,
        isStreaming: false,
        onBeforeSend: (text, attachments) async => precheck(text),
      );

  testWidgets('预检失败：输入原地保留、onSend 不触发（CH12-3）', (tester) async {
    var sent = 0;
    await tester.pumpWidget(
      wrap(input(precheck: (_) => false, onSend: (_) => sent++)),
    );
    await tester.enterText(find.byType(TextField), '很长的草稿内容，不能丢');
    await tester.pump();

    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pumpAndSettle();

    expect(sent, 0, reason: '预检失败不得发送');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '很长的草稿内容，不能丢',
      reason: '预检失败输入必须原地保留（此前先清空再拒绝）',
    );
  });

  testWidgets('预检通过：清空输入并正常发送', (tester) async {
    var sent = 0;
    var sentText = '';
    await tester.pumpWidget(
      wrap(
        input(
          precheck: (_) => true,
          onSend: (t) {
            sent++;
            sentText = t;
          },
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '正常消息');
    await tester.pump();

    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pumpAndSettle();

    expect(sent, 1);
    expect(sentText, '正常消息');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '',
      reason: '通过后照常清空',
    );
  });

  testWidgets('无预检钩子：行为与旧版一致（清空即发送）', (tester) async {
    var sent = 0;
    await tester.pumpWidget(
      wrap(
        ChatModeInputArea(
          onSend: (text, List<MessageAttachment> attachments) => sent++,
          onCancel: () {},
          isSending: false,
          isStreaming: false,
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '直接发送');
    await tester.pump();

    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pumpAndSettle();

    expect(sent, 1);
  });

  testWidgets('预检在途：第二次点击被去抖', (tester) async {
    var sent = 0;
    var precheckCalls = 0;
    await tester.pumpWidget(
      wrap(
        input(
          precheck: (_) {
            precheckCalls++;
            return true;
          },
          onSend: (_) => sent++,
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '去抖');
    await tester.pump();

    // 连点两次：第二击落在预检在途窗口内，不得重复进入
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.tap(find.byIcon(Icons.send_rounded), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(sent, 1);
    expect(precheckCalls, 1, reason: '在途窗口内去抖，预检只跑一次');
  });
}
