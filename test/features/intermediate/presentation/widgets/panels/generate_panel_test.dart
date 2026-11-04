import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/intermediate/domain/entities/intermediate_chat_state.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/panels/generate_panel.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// GeneratePanel 自动折叠时序测试（V2 四步重构 2026-07-10）
///
/// V2 变更：GeneratePanel 移除 draftKeywords 参数（generating 产出纯文本，无关键词）。
/// 完成态文案改为"生成完成"（不含关键词数）。展开后仅显示生成内容全文。
///
/// 验证：
/// 1. generating 阶段：展开流式内容 + loading 指示
/// 2. generating → 完成态：先展开展示生成内容全文
/// 3. 延时后自动折叠为单行摘要
/// 4. 用户点击展开/折叠：取消自动折叠定时器，状态正确切换
/// 5. foldDelayMs=0：立即折叠
/// 6. 失败态：渲染错误图标 + 错误信息
void main() {
  Widget wrap(Widget child) {
    return TranslationProvider(
      child: MaterialApp(
        theme: ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
        home: Scaffold(body: child),
      ),
    );
  }

  group('GeneratePanel 自动折叠时序', () {
    testWidgets('1. generating 阶段：显示流式内容', (tester) async {
      await tester.pumpWidget(
        wrap(
          const GeneratePanel(
            phase: IntermediatePhase.generating,
            streamingGenerated: '生成内容流式中...',
            generatedText: null,
            failureContext: null,
          ),
        ),
      );

      // 流式生成内容可见
      expect(find.text('生成内容流式中...'), findsOneWidget);
    });

    testWidgets('2. generating → 完成态：先展开展示全文', (tester) async {
      // 初始为 generating
      await tester.pumpWidget(
        wrap(
          const GeneratePanel(
            phase: IntermediatePhase.generating,
            streamingGenerated: '流式内容',
            generatedText: null,
            failureContext: null,
          ),
        ),
      );

      // 切换到完成态（extracting 阶段，generatedText 已填充）
      // V2 四步：generating 完成后进入 extracting，GeneratePanel 显示完成态
      await tester.pumpWidget(
        wrap(
          const GeneratePanel(
            phase: IntermediatePhase.idle,
            streamingGenerated: null,
            generatedText: '完整的生成正文内容。',
            failureContext: null,
          ),
        ),
      );
      await tester.pump();

      // 完成态展开：生成内容全文应立即可见
      expect(find.text('完整的生成正文内容。'), findsOneWidget);
    });

    testWidgets('3. 延时后自动折叠为单行摘要', (tester) async {
      await tester.pumpWidget(
        wrap(
          const GeneratePanel(
            phase: IntermediatePhase.generating,
            streamingGenerated: '流式内容',
            generatedText: null,
            failureContext: null,
          ),
        ),
      );

      await tester.pumpWidget(
        wrap(
          const GeneratePanel(
            phase: IntermediatePhase.idle,
            streamingGenerated: null,
            generatedText: '完整的生成正文内容。',
            failureContext: null,
          ),
        ),
      );
      await tester.pump();

      // 展开状态下：生成内容全文可见
      expect(find.text('完整的生成正文内容。'), findsOneWidget);

      // 2026-07-16 修复问题3：面板可见时延迟折叠（最多延迟2次）。
      // foldDelayMs=2000，最多延迟2次 → 需推进 2000×3=6000ms 才折叠。
      // Timer retries are scheduled from each callback, so advance each
      // interval separately and cross (rather than land exactly on) each
      // deadline.
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(milliseconds: 2001));
      }
      await tester.pumpAndSettle();

      // 折叠后：生成内容全文不再可见，但摘要可见
      expect(find.text('完整的生成正文内容。'), findsNothing);
      // V2 摘要文案："生成完成"（不含关键词数）
      expect(find.textContaining('生成完成'), findsOneWidget);
    });

    testWidgets('4. 用户点击展开后取消自动折叠定时器', (tester) async {
      await tester.pumpWidget(
        wrap(
          const GeneratePanel(
            phase: IntermediatePhase.generating,
            streamingGenerated: '流式',
            generatedText: null,
            failureContext: null,
          ),
        ),
      );

      await tester.pumpWidget(
        wrap(
          const GeneratePanel(
            phase: IntermediatePhase.extracting,
            streamingGenerated: null,
            generatedText: '生成内容全文。',
            failureContext: null,
          ),
        ),
      );
      await tester.pump();

      // 展开状态：点击折叠（用户主动交互）
      await tester.tap(find.byType(InkWell));
      await tester.pump();
      expect(find.text('生成内容全文。'), findsNothing);

      // 推进 2 秒后，应保持折叠（用户已交互，定时器被取消，不再自动展开）
      await tester.pump(const Duration(milliseconds: 2500));
      await tester.pumpAndSettle();
      expect(find.text('生成内容全文。'), findsNothing);

      // 再次点击展开
      await tester.tap(find.byType(InkWell));
      await tester.pump();
      expect(find.text('生成内容全文。'), findsOneWidget);

      // 推进 5 秒后，应保持展开（用户已交互，不再自动折叠）
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(find.text('生成内容全文。'), findsOneWidget);
    });

    testWidgets('5. foldDelayMs=0：立即折叠', (tester) async {
      await tester.pumpWidget(
        wrap(
          const GeneratePanel(
            phase: IntermediatePhase.generating,
            streamingGenerated: '流式',
            generatedText: null,
            failureContext: null,
            foldDelayMs: 0,
          ),
        ),
      );

      await tester.pumpWidget(
        wrap(
          const GeneratePanel(
            phase: IntermediatePhase.extracting,
            streamingGenerated: null,
            generatedText: '生成内容全文。',
            failureContext: null,
            foldDelayMs: 0,
          ),
        ),
      );
      await tester.pump();

      // foldDelayMs=0：立即折叠，生成内容全文不应可见
      expect(find.text('生成内容全文。'), findsNothing);
      expect(find.textContaining('生成完成'), findsOneWidget);
    });

    testWidgets('6. 失败态：渲染错误图标 + 错误信息', (tester) async {
      await tester.pumpWidget(
        wrap(
          const GeneratePanel(
            phase: IntermediatePhase.failed,
            streamingGenerated: null,
            generatedText: null,
            failureContext: FailureContext(
              errorCode: 'E010',
              failedPhase: IntermediatePhase.generating,
              errorMessage: '生成失败',
              retryable: false,
            ),
          ),
        ),
      );
      await tester.pump();

      // 错误信息可见
      expect(find.text('生成失败'), findsOneWidget);
      // 错误图标可见
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });
  });
}
