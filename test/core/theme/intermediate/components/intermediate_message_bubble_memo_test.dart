import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart' show MarkdownBody;
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_markdown_body.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_message_bubble.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// story 侧 memo 链单测（照抄 chat 侧
/// simple_message_bubble_memo_test.dart 手法）
///
/// 流式期间页面每 32ms 整页重建，可见历史气泡的 itemBuilder 全部重跑。
/// 两级 memo：
/// - 气泡级 identical memo：content/thinkingContent 实例 identical 且
///   全部标量输入未变 → 返回上次构建的同一 child 实例 → Flutter
///   updateChild 剪枝整棵子树；
/// - IntermediateMarkdownBody data-identical memo：气泡 memo 未命中
///   （如 isStreaming 翻转）但 data 实例相同时，不重跑 Markdown 解析。
///
/// 观测手段：捕获正文 MarkdownBody 的 element.widget 实例做 identical
/// 比较——memo 命中则该 widget 实例跨重建不变。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  const markdownContent = '第一段正文。\n\n第二段正文，足够构成多块 markdown。';

  Future<void> pumpBubble(
    WidgetTester tester, {
    required String content,
    String? thinkingContent,
    bool isStreaming = false,
    bool isLastAssistantMessage = false,
    bool canOperate = true,
  }) async {
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: ListView(
                children: [
                  // 每次都是新 widget 实例 + 新闭包——对齐页面 itemBuilder
                  // 的整页重建路径（memo 必须在这种情况下仍然命中）
                  IntermediateMessageBubble(
                    key: const ValueKey('bubble'),
                    content: content,
                    isUser: false,
                    thinkingContent: thinkingContent,
                    isStreaming: isStreaming,
                    isLastAssistantMessage: isLastAssistantMessage,
                    canOperate: canOperate,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  final bodyFinder = find.descendant(
    of: find.byKey(const ValueKey('bubble')),
    matching: find.byType(MarkdownBody),
  );

  group('气泡级 identical memo', () {
    testWidgets('同 content 实例 + 同环境 → 子树剪枝不重装', (tester) async {
      await pumpBubble(tester, content: markdownContent);
      final before = tester.element(bodyFinder).widget;

      // 整页重建：新气泡实例、新闭包，content 为同一 String 实例
      await pumpBubble(tester, content: markdownContent);
      final after = tester.element(bodyFinder).widget;

      expect(
        identical(before, after),
        isTrue,
        reason: 'content identical + 签名相同必须命中气泡 memo，剪枝整棵子树',
      );
    });

    testWidgets('content 换实例（值相同也算）→ 重装', (tester) async {
      await pumpBubble(tester, content: markdownContent);
      final before = tester.element(bodyFinder).widget;

      // 流式页面的真实情形：每次 flush 后 state 里是新 String 实例
      const grown = '$markdownContent\n\n第三段。';
      await pumpBubble(tester, content: grown);
      final after = tester.element(bodyFinder).widget;

      expect(identical(before, after), isFalse, reason: 'content 变化必须重建');
    });

    testWidgets('标量变化（isStreaming 翻转）→ 重装', (tester) async {
      await pumpBubble(tester, content: markdownContent);
      final before = tester.element(bodyFinder).widget;

      await pumpBubble(tester, content: markdownContent, isStreaming: true);
      // 流式态走 StreamingMarkdownBody，整文 MarkdownBody 不在树中；
      // 回落非流式后重装
      await pumpBubble(tester, content: markdownContent);
      final after = tester.element(bodyFinder).widget;

      expect(
        identical(before, after),
        isFalse,
        reason: 'isStreaming 等标量是 memo 签名的一部分',
      );
    });
  });

  group('IntermediateMarkdownBody data-identical memo', () {
    testWidgets(
      '气泡 memo 未命中（canOperate 翻转）但 data identical → MarkdownBody 不重解析',
      (tester) async {
        await pumpBubble(tester, content: markdownContent);
        final before = tester.element(bodyFinder).widget;

        // canOperate 变化使气泡 memo 失效 → _buildContent 重跑 →
        // IntermediateMarkdownBody 拿到同一 data 实例 → markdown memo
        // 必须返回缓存的同一 MarkdownBody
        await pumpBubble(tester, content: markdownContent, canOperate: false);
        final after = tester.element(bodyFinder).widget;

        expect(
          identical(before, after),
          isTrue,
          reason: 'data identical 时 MarkdownBody 实例必须复用（免重解析）',
        );
      },
    );

    testWidgets('独立使用：data 实例变化 → 重建', (tester) async {
      Future<void> pumpBody(String data) => tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 800,
                  child: IntermediateMarkdownBody(data: data, isUser: false),
                ),
              ),
            ),
          );

      await pumpBody(markdownContent);
      final before = tester.element(find.byType(MarkdownBody)).widget;
      await pumpBody(markdownContent);
      final after = tester.element(find.byType(MarkdownBody)).widget;
      expect(identical(before, after), isTrue);

      await pumpBody('$markdownContent\n\n新段。');
      final rebuilt = tester.element(find.byType(MarkdownBody)).widget;
      expect(identical(before, rebuilt), isFalse);
    });
  });

  group('流式 flush 场景（页面级）', () {
    testWidgets('流式行增长时，非流式行的 MarkdownBody 零重装配', (tester) async {
      const staticContent = '历史消息正文，含一个 *强调* 标记。';
      var streamingContent = '正在生成的正文第一句';

      Future<void> pumpPage() => tester.pumpWidget(
            TranslationProvider(
              child: MaterialApp(
                home: Scaffold(
                  body: SizedBox(
                    width: 800,
                    height: 600,
                    child: ListView(
                      children: [
                        const IntermediateMessageBubble(
                          key: ValueKey('static'),
                          content: staticContent,
                          isUser: false,
                        ),
                        IntermediateMessageBubble(
                          key: const ValueKey('streaming'),
                          content: streamingContent,
                          isUser: false,
                          isStreaming: true,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );

      await pumpPage();
      await tester.pump(const Duration(milliseconds: 300));
      final staticBefore = tester
          .element(
            find.descendant(
              of: find.byKey(const ValueKey('static')),
              matching: find.byType(MarkdownBody),
            ),
          )
          .widget;

      // 一次 32ms 合帧 flush：流式行 content 变化，整页重建
      streamingContent = '正在生成的正文第一句，第二句也来了';
      await pumpPage();
      await tester.pump(const Duration(milliseconds: 32));

      final staticAfter = tester
          .element(
            find.descendant(
              of: find.byKey(const ValueKey('static')),
              matching: find.byType(MarkdownBody),
            ),
          )
          .widget;

      expect(
        identical(staticBefore, staticAfter),
        isTrue,
        reason: '流式 flush 的整页重建中，非流式行必须命中 memo 零重装配',
      );
    });
  });
}
