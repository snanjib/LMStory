import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/features/chat/domain/entities/search_result.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/presentation/widgets/global_search_dialog.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 全局搜索结果预览回归测试（2026-09-08 搜索体验修复）
///
/// 用户报告：搜索预览可能不显示搜索关键字。根因：预览片段逻辑以
/// 120 字符为界——短多行消息（markdown 段落）的关键字在第 3 行之后时，
/// 预览显示的是 maxLines=2 的开头两行，关键字被截断不可见且无高亮。
///
/// 修复后：预览统一围绕首个命中截取（关键字必含于片段）。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  late _FakeChatRepository repo;

  setUp(() {
    repo = _FakeChatRepository();
  });

  Future<void> pumpDialog(WidgetTester tester) async {
    final c = ProviderContainer(
      overrides: [chatRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: GlobalSearchDialog(onResultSelected: (_) {}),
            ),
          ),
        ),
      ),
    );
    // 防抖 500ms + 查询落地
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// 预览 RichText 中是否有「带背景高亮且含 query」的 span
  bool hasHighlightedKeyword(WidgetTester tester, String keyword) {
    var found = false;
    for (final element in find.byType(RichText).evaluate()) {
      final widget = element.widget as RichText;
      void walk(InlineSpan span) {
        if (span is TextSpan) {
          if ((span.text?.contains(keyword) ?? false) &&
              span.style?.backgroundColor != null) {
            found = true;
          }
          span.children?.forEach(walk);
        }
      }

      walk(widget.text);
    }
    return found;
  }

  testWidgets('短多行消息：关键字在末行也必须出现在预览中并高亮', (tester) async {
    // 96 字符（<120 旧阈值）+ 三段 markdown，关键字只在末段——
    // 旧行为预览只显示开头两行（maxLines:2），关键字完全不可见。
    repo.results = [
      SearchResult(
        sessionId: 's1',
        sessionName: '会话一',
        messageId: 'm1',
        content: '第一段内容介绍今天的行程安排。\n\n第二段讲了一些别的事情。\n\n最后提到了深夜便利店的故事。',
        role: 'assistant',
        createdAt: DateTime(2026),
      ),
    ];

    await pumpDialog(tester);
    await tester.enterText(find.byType(TextField), '便利店');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 100));

    // 结果项存在
    expect(find.text('会话一'), findsOneWidget);
    // 关键字高亮可见（此前：预览不含关键字且无高亮）
    expect(
      hasHighlightedKeyword(tester, '便利店'),
      isTrue,
      reason: '预览必须围绕命中截取，关键字可见且有背景高亮',
    );
  });

  testWidgets('长消息：关键字在中部，预览含前文省略号 + 高亮', (tester) async {
    repo.results = [
      SearchResult(
        sessionId: 's1',
        sessionName: '会话一',
        messageId: 'm2',
        content: '${'开头' * 60}时间旅行者来到了站台。${'结尾' * 60}',
        role: 'user',
        createdAt: DateTime(2026),
      ),
    ];

    await pumpDialog(tester);
    await tester.enterText(find.byType(TextField), '时间旅行');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      hasHighlightedKeyword(tester, '时间旅行'),
      isTrue,
      reason: '长消息中部命中的高亮保持（既有行为回归保护）',
    );
  });

  testWidgets('英文大小写不敏感命中同样高亮', (tester) async {
    repo.results = [
      SearchResult(
        sessionId: 's1',
        sessionName: '会话一',
        messageId: 'm3',
        content: 'The Quick Brown Fox jumps.',
        role: 'assistant',
        createdAt: DateTime(2026),
      ),
    ];

    await pumpDialog(tester);
    await tester.enterText(find.byType(TextField), 'quick');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      hasHighlightedKeyword(tester, 'Quick'),
      isTrue,
      reason: 'SQL LIKE 大小写不敏感命中，Dart 侧 toLowerCase 定位须一致',
    );
  });

  testWidgets('OH10-1：滚动后键盘导航高亮与全局序号对齐（高亮条目即真实条目）', (tester) async {
    // 两会话 × 20 条命中，总高远超 480px 视口。滚过整个会话1 后按 ↓ ×25
    // 把高亮移到全局序号 25（会话2 的第 6 条，在可见区）：
    // 修复前 itemBuilder 闭包累加 flatIndex，滚动重建后第一个可见组
    // （会话2）错拿 groupStartIndex=0，其 20 条没有 i==25——高亮无处安放；
    // 修复后组起始=20，i=5 命中「会话2 第5 条」。
    final results = <SearchResult>[];
    for (var g = 1; g <= 2; g++) {
      for (var i = 0; i < 20; i++) {
        results.add(
          SearchResult(
            sessionId: 's$g',
            sessionName: '会话$g',
            messageId: 'm$g-$i',
            content: '会话$g 第$i 条：深夜便利店的故事。',
            role: 'assistant',
            createdAt: DateTime(2026),
          ),
        );
      }
    }
    repo.results = results;

    await pumpDialog(tester);
    await tester.enterText(find.byType(TextField), '便利店');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump(const Duration(milliseconds: 100));

    // 滚过整个会话1（20 条 ≈ 1200px+）
    await tester.drag(find.byType(ListView), const Offset(0, -1400));
    await tester.pump();

    for (var i = 0; i < 25; i++) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 30));
    }
    await tester.pump(const Duration(milliseconds: 200));

    // 唯一的高亮容器（结果项 Container 仅在高亮时设 color）
    final highlighted = find.byWidgetPredicate(
      (w) => w is Container && w.color != null,
    );
    expect(highlighted, findsOneWidget, reason: '全局序号 25 在可见区应高亮');
    // 内容是 RichText（高亮 span），walk 检查高亮容器内的 span 文本
    var highlightedContent = '';
    void collectSpans(InlineSpan span) {
      if (span is TextSpan) {
        highlightedContent += span.text ?? '';
        span.children?.forEach(collectSpans);
      }
    }

    void walkElements(Element e) {
      if (e.widget is RichText) {
        collectSpans((e.widget as RichText).text);
      }
      e.visitChildElements(walkElements);
    }

    highlighted.evaluate().single.visitChildElements(walkElements);
    expect(
      highlightedContent,
      contains('会话2 第5 条'),
      reason: '高亮条目=真实全局序号 25（会话2 第5 条），不是错配条目',
    );
  });
}

class _FakeChatRepository implements ChatRepository {
  List<SearchResult> results = [];

  @override
  Future<List<SearchResult>> searchMessages(String query) async => results;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}
