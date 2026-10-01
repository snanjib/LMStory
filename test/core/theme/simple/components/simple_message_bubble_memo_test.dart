import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/simple/components/simple_message_bubble.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/i18n/strings.g.dart';

///  批1：气泡级 identical memo
///
/// 流式期间页面每 32ms 整页重建，可见历史气泡的 itemBuilder 全部重跑。
/// memo 语义：message 实例 identical 且全部标量/偏好输入未变时，气泡
/// 返回上一次构建的同一 child 实例 → Flutter updateChild 剪枝整棵子树
///（SimpleMarkdownBody memo 只救 markdown 子树，本 memo 把剪枝上提一级）。
///
/// 观测手段：捕获气泡内容区 GestureDetector 的 element.widget 实例做
/// identical 比较——memo 命中则该 widget 实例跨重建不变。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  final message = ChatMessage(
    messageId: 'm1',
    sessionId: 's1',
    role: 'assistant',
    content: '第一段正文。\n\n第二段正文，足够构成多块 markdown。',
    createdAt: DateTime(2026),
  );

  Future<void> pumpBubble(
    WidgetTester tester, {
    required ChatMessage msg,
    bool isStreaming = false,
    Brightness brightness = Brightness.light,
  }) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Theme(
            // 显式 Theme 决定气泡可见的亮度（MaterialApp.theme 的传播
            // 在测试环境受 platformBrightness 影响，不走它）
            data: brightness == Brightness.light
                ? ThemeData(brightness: Brightness.light)
                : ThemeData(brightness: Brightness.dark),
            child: Scaffold(
              body: SizedBox(
                width: 800,
                height: 600,
                child: ListView(
                  children: [
                    // 每次都是新 widget 实例 + 新闭包——对齐页面 itemBuilder
                    // 每 delta 重跑的真实形态
                    SimpleMessageBubble(
                      key: const ValueKey('bubble'),
                      message: msg,
                      isStreaming: isStreaming,
                      isConsecutive: false,
                      onCopy: () {},
                      onDelete: () {},
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }

  /// 气泡内容区 GestureDetector（onTap 切换操作栏那个）
  GestureDetector contentDetector(WidgetTester tester) => tester.widget(
        find
            .descendant(
              of: find.byType(SimpleMessageBubble),
              matching: find.byType(GestureDetector),
            )
            .first,
      );

  testWidgets('identical 消息 + 同标量：子树剪枝（widget 实例不变）', (tester) async {
    await pumpBubble(tester, msg: message);
    final before = contentDetector(tester);

    // 重建父级（新 SimpleMessageBubble 实例 + 新闭包），消息对象与
    // 标量完全相同——memo 应命中，GestureDetector 实例不换
    await pumpBubble(tester, msg: message);
    final after = contentDetector(tester);

    expect(
      identical(before, after),
      isTrue,
      reason: 'B1 批1：identical 消息的历史气泡子树不应重建',
    );
  });

  testWidgets('消息实例变化（流式 copyWith）：子树重建', (tester) async {
    await pumpBubble(tester, msg: message);
    final before = contentDetector(tester);

    final grown = message.copyWith(content: '${message.content}新增量');
    await pumpBubble(tester, msg: grown);
    final after = contentDetector(tester);

    expect(identical(before, after), isFalse, reason: '流式消息每 delta 都是新实例，必须重建');
  });

  testWidgets('标量变化（isStreaming 翻转）：子树重建', (tester) async {
    await pumpBubble(tester, msg: message, isStreaming: true);
    final before = contentDetector(tester);

    await pumpBubble(tester, msg: message);
    final after = contentDetector(tester);

    expect(
      identical(before, after),
      isFalse,
      reason: 'isStreaming 等标量是 memo 签名的一部分',
    );
  });

  testWidgets('亮度变化：子树重建（缓存不得残留旧配色）', (tester) async {
    await pumpBubble(tester, msg: message);
    final before = contentDetector(tester);

    await pumpBubble(tester, msg: message, brightness: Brightness.dark);
    final after = contentDetector(tester);

    expect(
      identical(before, after),
      isFalse,
      reason: '气泡 build 读 Theme.brightness，签名必须含亮度',
    );
  });
}
