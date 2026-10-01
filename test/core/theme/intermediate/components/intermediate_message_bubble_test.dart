import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/intermediate/components/intermediate_message_bubble.dart';
import 'package:lmstory/core/theme/system/palettes/classic/classic_palette.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// IntermediateMessageBubble 组件测试
///
///  基础验证：
/// - 用户消息：右对齐 + primaryDim 底色
/// - 助手消息：左对齐 + surface 底色 + 衬线字体
/// - 内容文本正确渲染
///
///  动作按钮可见性：
/// - 默认隐藏（_actionsVisible=false、isLastAssistantMessage=false）
/// - tap 气泡切换显示
/// - 最后一条助手消息常驻显示
/// - 流式生成中不显示（即使 tap）
/// - 显示后 3 秒自动隐藏
/// - 再次 tap 隐藏
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Widget wrap(Widget child) {
    return TranslationProvider(
      child: MaterialApp(
        theme: ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
        home: Scaffold(body: child),
      ),
    );
  }

  group('IntermediateMessageBubble', () {
    testWidgets('1. 用户消息：右对齐，渲染内容', (tester) async {
      await tester.pumpWidget(
        wrap(
          const IntermediateMessageBubble(
            content: '你好',
            isUser: true,
          ),
        ),
      );

      // 内容文本存在
      expect(find.text('你好'), findsOneWidget);

      // Align 对齐方向：用户消息应右对齐
      final align = tester.widget<Align>(find.byType(Align));
      expect(align.alignment, Alignment.centerRight);
    });

    testWidgets('2. 助手消息：左对齐，渲染内容', (tester) async {
      await tester.pumpWidget(
        wrap(
          const IntermediateMessageBubble(
            content: '勇者穿过密林，发现了一座古碑。',
            isUser: false,
          ),
        ),
      );

      expect(find.text('勇者穿过密林，发现了一座古碑。'), findsOneWidget);

      final align = tester.widget<Align>(find.byType(Align));
      expect(align.alignment, Alignment.centerLeft);
    });

    testWidgets('3. 用户消息使用 primaryDim 底色', (tester) async {
      await tester.pumpWidget(
        wrap(
          const IntermediateMessageBubble(
            content: '用户输入',
            isUser: true,
          ),
        ),
      );

      final container = tester.widget<Container>(find.byType(Container));
      final decoration = container.decoration as BoxDecoration?;
      expect(
        decoration?.color,
        ClassicPaletteValues.dark.primaryDim,
      );
    });

    testWidgets('4. 助手消息使用 surface 底色', (tester) async {
      await tester.pumpWidget(
        wrap(
          const IntermediateMessageBubble(
            content: '助手回复',
            isUser: false,
          ),
        ),
      );

      final container = tester.widget<Container>(find.byType(Container));
      final decoration = container.decoration as BoxDecoration?;
      expect(decoration?.color, ClassicPaletteValues.dark.surface);
    });
  });

  group('IntermediateMessageBubble - P2.6 动作按钮可见性', () {
    testWidgets('5. 默认不显示动作按钮', (tester) async {
      await tester.pumpWidget(
        wrap(
          const IntermediateMessageBubble(
            content: '消息',
            isUser: false,
          ),
        ),
      );

      // 默认 _actionsVisible=false、isLastAssistantMessage=false
      // → _showActions=false → actions 不渲染
      expect(find.byIcon(Icons.delete_outline), findsNothing);
    });

    testWidgets('6. tap 气泡切换显示动作按钮', (tester) async {
      await tester.pumpWidget(
        wrap(
          const IntermediateMessageBubble(
            content: '消息',
            isUser: false,
          ),
        ),
      );

      expect(find.byIcon(Icons.delete_outline), findsNothing);

      // tap 气泡内容 → _toggleActions → _actionsVisible=true
      await tester.tap(find.text('消息'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    });

    testWidgets('7. 最后一条助手消息：动作按钮常驻显示', (tester) async {
      await tester.pumpWidget(
        wrap(
          const IntermediateMessageBubble(
            content: '最后一条助手消息',
            isUser: false,
            isLastAssistantMessage: true,
          ),
        ),
      );

      // isLastAssistantMessage=true → _showActions=true（无需 tap）
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    });

    testWidgets('8. 流式生成中：tap 也不显示动作按钮', (tester) async {
      await tester.pumpWidget(
        wrap(
          const IntermediateMessageBubble(
            content: '生成中...',
            isUser: false,
            isStreaming: true,
          ),
        ),
      );

      // 流式生成中 _showActions=false（即使 isLastAssistantMessage=true）
      expect(find.byIcon(Icons.delete_outline), findsNothing);

      // tap 气泡 → _actionsVisible=true，但 _showActions 仍 false（isStreaming）
      // 注意：isStreaming=true 触发 _StreamingCursor.repeat() 持续动画，
      // pumpAndSettle 会超时，改用 pump 推进一帧让 setState 生效
      await tester.tap(find.text('生成中...'));
      await tester.pump();

      expect(find.byIcon(Icons.delete_outline), findsNothing);
    });

    testWidgets('9. tap 显示后 3 秒自动隐藏', (tester) async {
      await tester.pumpWidget(
        wrap(
          const IntermediateMessageBubble(
            content: '消息',
            isUser: false,
          ),
        ),
      );

      // tap 显示
      await tester.tap(find.text('消息'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);

      // 推进 3 秒（fakeAsync timer 触发 setState）
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      // timer 回调将 _actionsVisible 置 false → actions 隐藏
      expect(find.byIcon(Icons.delete_outline), findsNothing);
    });

    testWidgets('10. 再次 tap 隐藏动作按钮', (tester) async {
      await tester.pumpWidget(
        wrap(
          const IntermediateMessageBubble(
            content: '消息',
            isUser: false,
          ),
        ),
      );

      // 第一次 tap：显示
      await tester.tap(find.text('消息'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);

      // 第二次 tap：隐藏（_actionsVisible 取反为 false，并取消 timer）
      await tester.tap(find.text('消息'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.delete_outline), findsNothing);
    });
  });

  group('IntermediateMessageBubble - fontScale 字号缩放', () {
    /// 提取 SelectableText 的字号（消息正文字号）
    double? messageFontSize(WidgetTester tester) {
      final selectableText = tester.widget<SelectableText>(
        find.byType(SelectableText).first,
      );
      return selectableText.textSpan?.style?.fontSize ??
          selectableText.style?.fontSize;
    }

    testWidgets('11. 用户消息默认 fontScale=1.0 保持基准字号 15px', (tester) async {
      await tester.pumpWidget(
        wrap(
          const IntermediateMessageBubble(
            content: '用户消息',
            isUser: true,
          ),
        ),
      );
      expect(messageFontSize(tester), 15.0);
    });

    testWidgets('12. 助手消息默认 fontScale=1.0 保持基准字号 16px', (tester) async {
      await tester.pumpWidget(
        wrap(
          const IntermediateMessageBubble(
            content: '助手消息',
            isUser: false,
          ),
        ),
      );
      expect(messageFontSize(tester), 16.0);
    });

    testWidgets('13. fontScale=1.5 用户消息字号缩放为 22.5px', (tester) async {
      await tester.pumpWidget(
        wrap(
          const IntermediateMessageBubble(
            content: '用户消息',
            isUser: true,
            fontScale: 1.5,
          ),
        ),
      );
      expect(messageFontSize(tester), 22.5);
    });

    testWidgets('14. fontScale=1.5 助手消息字号缩放为 24px', (tester) async {
      await tester.pumpWidget(
        wrap(
          const IntermediateMessageBubble(
            content: '助手消息',
            isUser: false,
            fontScale: 1.5,
          ),
        ),
      );
      expect(messageFontSize(tester), 24.0);
    });

    testWidgets('15. fontScale=0.8 缩小字号（用户 12px / 助手 12.8px）', (tester) async {
      // 用户消息
      await tester.pumpWidget(
        wrap(
          const IntermediateMessageBubble(
            content: '用户消息',
            isUser: true,
            fontScale: 0.8,
          ),
        ),
      );
      expect(messageFontSize(tester), 12.0);

      // 助手消息
      await tester.pumpWidget(
        wrap(
          const IntermediateMessageBubble(
            content: '助手消息',
            isUser: false,
            fontScale: 0.8,
          ),
        ),
      );
      expect(messageFontSize(tester), 12.8);
    });

    testWidgets('16. 思考区块字号随 fontScale 缩放', (tester) async {
      await tester.pumpWidget(
        wrap(
          const IntermediateMessageBubble(
            content: '助手消息',
            isUser: false,
            thinkingContent: '思考内容',
            fontScale: 1.5,
          ),
        ),
      );

      // 思考区块默认折叠，先点击展开
      // 折叠态标签是"展开思考过程"，点击它展开
      final expandFinder = find.textContaining('思考');
      expect(expandFinder, findsOneWidget);
      await tester.tap(expandFinder);
      await tester.pumpAndSettle();

      // 展开态：思考内容文本字号 = 14 * 1.5 = 21
      final thinkingText = tester.widget<Text>(find.text('思考内容'));
      expect(thinkingText.style?.fontSize, 21.0);
    });
  });
}
