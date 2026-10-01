import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/simple/components/simple_message_bubble.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 对话模式撤销压缩显性化。
///
/// 链路（删摘要+删压缩点）本就在位，本批只做显性化：最新摘要的删除
/// 按钮改 undo 图标+「撤销压缩」文案与非破坏性配色；旧摘要保留
/// 「删除」 destructive 形态；确认弹窗文案两分。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  ChatMessage summaryMessage({String id = 'sum1'}) => ChatMessage(
        messageId: id,
        sessionId: 's1',
        role: 'system',
        content: '这是摘要内容',
        isSummary: true,
        createdAt: DateTime(2026),
      );

  Future<void> pumpCard(
    WidgetTester tester, {
    required ChatMessage message,
    bool isLatestSummary = false,
  }) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                SimpleMessageBubble(
                  message: message,
                  isStreaming: false,
                  isConsecutive: false,
                  isLatestSummary: isLatestSummary,
                  onEditSummary: () {},
                  onDeleteSummary: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // 展开摘要卡（点击卡片 header 切换）
    await tester.tap(find.byType(SimpleMessageBubble));
    await tester.pumpAndSettle();
  }

  testWidgets('最新摘要：undo 图标+「撤销压缩」文案', (tester) async {
    await pumpCard(tester, message: summaryMessage(), isLatestSummary: true);
    expect(find.text('撤销压缩'), findsOneWidget);
    expect(find.text('删除摘要'), findsNothing);
  });

  testWidgets('旧摘要：保留「删除摘要」destructive 形态', (tester) async {
    await pumpCard(tester, message: summaryMessage());
    expect(find.text('删除摘要'), findsOneWidget);
    expect(find.text('撤销压缩'), findsNothing);
  });

  testWidgets('最新摘要确认弹窗走撤销文案', (tester) async {
    await pumpCard(tester, message: summaryMessage(), isLatestSummary: true);
    await tester.tap(find.text('撤销压缩'));
    await tester.pumpAndSettle();
    expect(find.text('撤销这次压缩？'), findsOneWidget);
    expect(find.text('撤销'), findsOneWidget);
  });
}
