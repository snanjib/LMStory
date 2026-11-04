import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_message_bubble.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/i18n/strings.g.dart';

///  批5：思考区呼吸动画 ticker 生命周期
///
/// 此前 `_pulseController..repeat()` 在 initState 无条件启动——思考早已
/// 结束（isThinking=false、图标已是静态分支）后 ticker 仍每帧动画，
/// 白耗帧预算（气泡常驻列表，历史消息人手一个）。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  final message = ChatMessage(
    messageId: 'm1',
    sessionId: 's1',
    role: 'assistant',
    content: '正文。',
    thinkingContent: '一段已结束的思考。',
    thinkingDuration: 5,
    createdAt: DateTime(2026),
  );

  Future<void> pumpBubble(
    WidgetTester tester, {
    required bool isThinking,
  }) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: SingleChildScrollView(
                child: SimpleMessageBubble(
                  message: message,
                  isStreaming: false,
                  isConsecutive: false,
                  isThinking: isThinking,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // 消化入场/首次动画帧后观测
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('思考已结束：呼吸动画 ticker 停止', (tester) async {
    await pumpBubble(tester, isThinking: false);
    expect(
      tester.binding.transientCallbackCount > 0,
      isFalse,
      reason: 'B1 批5：isThinking=false 时脉冲 ticker 不得常驻',
    );
  });

  testWidgets('思考中：呼吸动画运行（不回退 B14 视觉）', (tester) async {
    await pumpBubble(tester, isThinking: true);
    expect(tester.binding.transientCallbackCount > 0, isTrue);
  });

  testWidgets('思考结束翻转：ticker 停止', (tester) async {
    await pumpBubble(tester, isThinking: true);
    expect(tester.binding.transientCallbackCount > 0, isTrue);

    // 翻转为结束
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: SingleChildScrollView(
                child: SimpleMessageBubble(
                  message: message,
                  isStreaming: false,
                  isConsecutive: false,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester.binding.transientCallbackCount > 0,
      isFalse,
      reason: 'isThinking 翻转 false 后 ticker 应停止',
    );
  });
}
