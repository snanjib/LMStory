import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/intermediate/components/intermediate_message_bubble.dart';
import 'package:lmstory/core/theme/shared/components/streaming_fade_text.dart';
import 'package:lmstory/core/theme/shared/components/streaming_reveal_pacer.dart'
    show streamingRevealIdleSnap;
import 'package:lmstory/core/theme/shared/components/streaming_text_fade.dart'
    show streamingFadeFirstObservationTailCodeUnits;
import 'package:lmstory/core/theme/simple/components/simple_message_bubble.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_live_block.dart';
import 'package:lmstory/features/advanced/presentation/pages/director_chat_body.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/context_usage_ring.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 全模式流式面淡入覆盖证明（R1）
///
/// 覆盖矩阵（处置详见执行日志与交付说明）：
/// - 主正文三模式（chat/story 气泡、导演稿件卡）：经 StreamingMarkdownBody
///   纯文本快速路径自动同享淡入；
/// - 思考过程三模式（SimpleMessageBubble/IntermediateMessageBubble/
///   DirectorWorkGroup 思考块展开态）： 接入 StreamingFadeText；
/// - 压缩摘要流式（ContextUsageDetailSheet，story/导演共用）： 接入；
/// - 排除面（离散事件视觉语言，不接淡入）：导演工作组行/重试等待行
///   （shimmer/呼吸点）、DirectorRecapCard（结构化数据卡）、播报行
///   （轮末一次性文本）。
///
/// R（2026-09-10 复验修复）后的判定口径：淡入不再用 WidgetSpan 原子盒，
/// 「处于淡入中」的判定改为「存在带 per-span 颜色的子 span」（progress 达 1
/// 后回并为无样式普通 span），并新增布局中性回归基准。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  // 显式不透明色：淡入 alpha = 基准色 alpha × 进度，给确定基准才能断言中段值。
  const fadeStyle = TextStyle(
    fontSize: 14,
    height: 1.55,
    color: Color(0xFF1B1B1B),
  );

  /// 是否存在未完成淡入的区间（只有淡入段带 per-span 颜色）。
  bool hasFadingRun(Text text) {
    final root = text.textSpan;
    if (root is! TextSpan) return false;
    var fading = false;
    void walk(InlineSpan span) {
      if (fading || span is! TextSpan) return;
      if (span.style?.color != null && (span.text ?? '').isNotEmpty) {
        fading = true;
        return;
      }
      span.children?.forEach(walk);
    }

    root.children?.forEach(walk);
    return fading;
  }

  Finder fadingTexts() => find.byWidgetPredicate(
        (w) => w is Text && hasFadingRun(w),
        description: '存在未完成淡入的文本',
      );

  /// 未完成淡入的区间（按渲染顺序）。
  List<({String text, double alpha})> fadeRuns(
    WidgetTester tester, [
    Finder? scope,
  ]) {
    final finder = scope == null
        ? find.byType(Text)
        : find.descendant(of: scope, matching: find.byType(Text));
    final out = <({String text, double alpha})>[];
    for (final text in tester.widgetList<Text>(finder)) {
      final root = text.textSpan;
      if (root is! TextSpan) continue;
      void walk(InlineSpan span) {
        if (span is! TextSpan) return;
        final color = span.style?.color;
        if (color != null && (span.text ?? '').isNotEmpty) {
          out.add((text: span.text!, alpha: color.a));
        }
        span.children?.forEach(walk);
      }

      root.children?.forEach(walk);
    }
    return out;
  }

  String textUnder(WidgetTester tester, Finder scope) => tester
      .widgetList<Text>(find.descendant(of: scope, matching: find.byType(Text)))
      .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
      .join();

  /// 等平滑揭示配速补齐：先给一帧让增长被观察到，再等源停顿立即补齐
  ///（见 streamingRevealIdleSnap）。开启配速的面（本组渲染真实气泡/稿件
  /// 卡）断言全文前必须等这一步。
  Future<void> settleReveal(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(
      streamingRevealIdleSnap + const Duration(milliseconds: 50),
    );
  }

  group('StreamingFadeText（共享载体）', () {
    testWidgets('增长即淡入，内容完整', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: StreamingFadeText(data: '夜色沉了下去', style: fadeStyle),
          ),
        ),
      );
      expect(fadingTexts(), findsWidgets);
      expect(fadeRuns(tester).single.text, '夜色沉了下去');
      expect(
        textUnder(tester, find.byType(StreamingFadeText)),
        '夜色沉了下去',
      );
    });

    testWidgets('淡入按帧推进：150ms 时 alpha 处于 (0,1)，完成后无残留', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: StreamingFadeText(data: '夜色沉了下去', style: fadeStyle),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      final runs = fadeRuns(tester);
      expect(runs, hasLength(1));
      expect(runs.single.alpha, greaterThan(0));
      expect(runs.single.alpha, lessThan(1), reason: '300ms 淡入中段不得已完成');
      expect(runs.single.alpha, closeTo(0.5, 0.02));

      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle(); // 帧驱动不自停则超时失败
      expect(fadingTexts(), findsNothing, reason: '淡入完成后回并为静态 span');
      expect(
        textUnder(tester, find.byType(StreamingFadeText)),
        '夜色沉了下去',
      );
    });

    testWidgets('替换（非追加）不重放淡入', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: StreamingFadeText(data: '旧的思考内容', style: fadeStyle),
          ),
        ),
      );
      expect(fadingTexts(), findsWidgets);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: StreamingFadeText(data: '完全不同的新思考', style: fadeStyle),
          ),
        ),
      );
      expect(fadingTexts(), findsNothing, reason: '重生成替换清空不重放');
      expect(
        textUnder(tester, find.byType(StreamingFadeText)),
        '完全不同的新思考',
      );
    });

    testWidgets('长文首观察只淡入尾部窗口（中途重挂不重放整段历史）', (tester) async {
      final data = '夜色沉了下去，${'走廊尽头的灯还亮着' * 20}';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StreamingFadeText(data: data, style: fadeStyle),
          ),
        ),
      );
      final runs = fadeRuns(tester);
      expect(runs, hasLength(1));
      expect(
        runs.single.text,
        data.substring(
          data.length - streamingFadeFirstObservationTailCodeUnits,
        ),
        reason: '只把尾部窗口当作新增段',
      );
      expect(textUnder(tester, find.byType(StreamingFadeText)), data);
    });

    testWidgets('布局中性：淡入期与同宽纯文本尺寸/行数一致', (tester) async {
      const data = '夜色沉下去的时候走廊尽头的灯还亮着，她数着台阶下楼，第三级永远比其余的响。';
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  key: ValueKey('fade'),
                  width: 200,
                  child: StreamingFadeText(data: data, style: fadeStyle),
                ),
                SizedBox(
                  key: ValueKey('plain'),
                  width: 200,
                  child: Text(data, style: fadeStyle),
                ),
              ],
            ),
          ),
        ),
      );
      expect(fadingTexts(), findsWidgets, reason: '前置：确认处于淡入期');

      final fadeBox = tester.getSize(find.byKey(const ValueKey('fade')));
      final plainBox = tester.getSize(find.byKey(const ValueKey('plain')));
      expect(
        fadeBox.height,
        closeTo(plainBox.height, 0.01),
        reason: '淡入不得改变行数/高度（原子盒方案在此处会产生换行跳变）',
      );

      // 逐行宽度：同一文本在淡入期与纯文本下必须得到相同的换行切分。
      List<double> lineWidthsOf(Key key) => tester
          .renderObject<RenderParagraph>(
            find.descendant(
              of: find.byKey(key),
              matching: find.byType(RichText),
            ),
          )
          .getBoxesForSelection(
            const TextSelection(baseOffset: 0, extentOffset: data.length),
          )
          .map((box) => box.right - box.left)
          .toList();

      final fadeLines = lineWidthsOf(const ValueKey('fade'));
      final plainLines = lineWidthsOf(const ValueKey('plain'));
      expect(
        fadeLines.length,
        plainLines.length,
        reason: '淡入期的换行行数必须与纯文本一致',
      );
      for (var i = 0; i < fadeLines.length; i++) {
        expect(
          fadeLines[i],
          closeTo(plainLines[i], 0.01),
          reason: '第 $i 行宽度一致 = 换行点一致',
        );
      }
    });
  });

  group('R1 主正文三模式（经 StreamingMarkdownBody 快速路径）', () {
    testWidgets('chat：流式纯散文气泡出现淡入且内容完整', (tester) async {
      Widget host(ChatMessage msg) => TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 800,
                  height: 600,
                  child: ListView(
                    children: [
                      SimpleMessageBubble(
                        key: const ValueKey('bubble'),
                        message: msg,
                        isStreaming: true,
                        isConsecutive: false,
                        onCopy: () {},
                        onDelete: () {},
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );

      ChatMessage msg(String content) => ChatMessage(
            messageId: 'm1',
            sessionId: 's1',
            role: 'assistant',
            content: content,
            createdAt: DateTime(2026),
          );

      await tester.pumpWidget(host(msg('夜色沉了下去的时候')));
      final runs = fadeRuns(tester, find.byKey(const ValueKey('bubble')));
      expect(
        runs,
        isNotEmpty,
        reason: 'chat 主正文流式必须享受淡入（T8 接线自动同享）',
      );
      expect(
        runs.map((r) => r.text).join(),
        contains('夜色沉了下去的时候'),
      );

      await tester.pumpWidget(host(msg('夜色沉了下去的时候，走廊尽头的灯还亮着')));
      await settleReveal(tester);
      expect(
        textUnder(tester, find.byKey(const ValueKey('bubble'))),
        contains('走廊尽头的灯还亮着'),
        reason: '淡入只影响动效不影响内容',
      );
    });

    testWidgets('story：流式纯散文气泡出现淡入且内容完整', (tester) async {
      Widget host(String content) => TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 800,
                  height: 600,
                  child: ListView(
                    children: [
                      IntermediateMessageBubble(
                        key: const ValueKey('bubble'),
                        content: content,
                        isUser: false,
                        isStreaming: true,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );

      await tester.pumpWidget(host('她数着台阶下楼'));
      final runs = fadeRuns(tester, find.byKey(const ValueKey('bubble')));
      expect(runs, isNotEmpty, reason: 'story 主正文流式必须享受淡入');
      expect(runs.map((r) => r.text).join(), contains('她数着台阶下楼'));

      await tester.pumpWidget(host('她数着台阶下楼，第三级永远比其余的响'));
      await settleReveal(tester);
      expect(
        textUnder(tester, find.byKey(const ValueKey('bubble'))),
        contains('第三级永远比其余的响'),
      );
    });

    testWidgets('导演：直播稿件卡出现淡入且增长后内容完整', (tester) async {
      ChatSession testSession() => ChatSession(
            sessionId: 'dir-1',
            title: '测试导演',
            mode: 'advanced',
            createdAt: DateTime(2026),
            lastActiveAt: DateTime(2026),
            messageCount: 0,
          );

      Widget wrap(AdvancedChatState state) => TranslationProvider(
            child: MaterialApp(
              theme:
                  ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
              home: Scaffold(
                body: DirectorChatBody(
                  state: state,
                  onCopy: (_) {},
                  onRegenerate: (_) {},
                  onEdit: (_) {},
                  onDeleteRound: (_) {},
                ),
              ),
            ),
          );

      AdvancedChatState stateOf(String manuscript) => AdvancedChatState(
            phase: IntermediatePhase.reviewing,
            messages: const [],
            retryCounts: const {},
            session: testSession(),
            liveBlocks: [
              AgentLiveBlock(
                kind: AgentLiveBlockKind.text,
                stepIndex: 0,
                text: manuscript,
              ),
            ],
          );

      await tester.pumpWidget(wrap(stateOf('夜色漫过窗台的时候')));
      await tester.pump();
      final runs = fadeRuns(tester, find.byType(DirectorChatBody));
      expect(runs, isNotEmpty, reason: '导演稿件卡主正文流式必须享受淡入');
      expect(runs.map((r) => r.text).join(), contains('夜色漫过窗台的时候'));

      await tester.pumpWidget(wrap(stateOf('夜色漫过窗台的时候，故事从第三个人称开始')));
      await settleReveal(tester);
      expect(
        textUnder(tester, find.byType(DirectorChatBody)),
        contains('故事从第三个人称开始'),
      );
    });
  });

  group('R1 思考过程流式三模式（T10 接入）', () {
    testWidgets('chat：思考展开区流式淡入', (tester) async {
      Widget host(ChatMessage msg) => TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 800,
                  height: 600,
                  child: ListView(
                    children: [
                      SimpleMessageBubble(
                        key: const ValueKey('bubble'),
                        message: msg,
                        isStreaming: true,
                        isConsecutive: false,
                        isThinking: true,
                        onCopy: () {},
                        onDelete: () {},
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );

      ChatMessage msg(String thinking) => ChatMessage(
            messageId: 'm1',
            sessionId: 's1',
            role: 'assistant',
            content: '',
            thinkingContent: thinking,
            createdAt: DateTime(2026),
          );

      await tester.pumpWidget(host(msg('先想想人物动机')));
      // 思考中默认自动展开
      final runs = fadeRuns(tester, find.byKey(const ValueKey('bubble')));
      expect(runs, isNotEmpty, reason: 'chat 思考流式必须淡入浮现而非硬切');
      expect(runs.map((r) => r.text).join(), contains('先想想人物动机'));

      await tester.pumpWidget(host(msg('先想想人物动机，再决定视角')));
      await settleReveal(tester);
      expect(
        textUnder(tester, find.byKey(const ValueKey('bubble'))),
        contains('再决定视角'),
      );
    });

    testWidgets('story：思考展开区流式淡入', (tester) async {
      Widget host(String thinking) => TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  width: 800,
                  height: 600,
                  child: ListView(
                    children: [
                      IntermediateMessageBubble(
                        key: const ValueKey('bubble'),
                        content: '',
                        isUser: false,
                        isStreaming: true,
                        thinkingContent: thinking,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );

      await tester.pumpWidget(host('梳理时间线'));
      // story 思考默认收起：点展开
      await tester.tap(find.text('展开思考过程'));
      await tester.pump();
      final runs = fadeRuns(tester, find.byKey(const ValueKey('bubble')));
      expect(runs, isNotEmpty, reason: 'story 思考流式必须淡入浮现');
      expect(runs.map((r) => r.text).join(), contains('梳理时间线'));

      await tester.pumpWidget(host('梳理时间线，核对前文伏笔'));
      await settleReveal(tester);
      expect(
        textUnder(tester, find.byKey(const ValueKey('bubble'))),
        contains('核对前文伏笔'),
      );
    });

    testWidgets('导演：live 思考块展开态流式淡入', (tester) async {
      ChatSession testSession() => ChatSession(
            sessionId: 'dir-1',
            title: '测试导演',
            mode: 'advanced',
            createdAt: DateTime(2026),
            lastActiveAt: DateTime(2026),
            messageCount: 0,
          );

      Widget wrap(AdvancedChatState state) => TranslationProvider(
            child: MaterialApp(
              theme:
                  ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
              home: Scaffold(
                body: DirectorChatBody(
                  state: state,
                  onCopy: (_) {},
                  onRegenerate: (_) {},
                  onEdit: (_) {},
                  onDeleteRound: (_) {},
                ),
              ),
            ),
          );

      AdvancedChatState stateOf(String thinking) => AdvancedChatState(
            phase: IntermediatePhase.reviewing,
            messages: const [],
            retryCounts: const {},
            session: testSession(),
            liveBlocks: [
              AgentLiveBlock(
                kind: AgentLiveBlockKind.thinking,
                stepIndex: 0,
                text: thinking,
              ),
            ],
          );

      await tester.pumpWidget(wrap(stateOf('核对设定集')));
      await tester.pump();
      // live 思考默认展开
      final runs = fadeRuns(tester, find.byType(DirectorChatBody));
      expect(runs, isNotEmpty, reason: '导演 live 思考块必须淡入浮现');
      expect(runs.map((r) => r.text).join(), contains('核对设定集'));

      await tester.pumpWidget(wrap(stateOf('核对设定集里的人物关系')));
      await settleReveal(tester);
      expect(
        textUnder(tester, find.byType(DirectorChatBody)),
        contains('人物关系'),
      );
    });
  });

  group('R1 压缩摘要流式（story/导演共用面板，T10 接入）', () {
    testWidgets('手动压缩流式区淡入且内容完整', (tester) async {
      Widget host(String delta) => TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  height: 600,
                  child: SingleChildScrollView(
                    child: ContextUsageDetailSheet(
                      contextWindowTokens: 1000000,
                      compactionTriggerTokens: 500000,
                      lastPromptTokens: 152000,
                      lastCompletionTokens: 1800,
                      lastCacheReadTokens: 132000,
                      averageCacheHit: 0.912,
                      sessionRounds: 130,
                      isManualCompacting: true,
                      manualCompactionDelta: delta,
                      manualCompactionError: null,
                      isRoundActive: false,
                      onManualCompact: () {},
                    ),
                  ),
                ),
              ),
            ),
          );

      await tester.pumpWidget(host('第三章：主角发现了信件'));
      final runs = fadeRuns(tester, find.byType(ContextUsageDetailSheet));
      expect(runs, isNotEmpty, reason: '压缩摘要流式必须淡入浮现');
      expect(runs.map((r) => r.text).join(), contains('主角发现了信件'));

      await tester.pumpWidget(host('第三章：主角发现了信件，但没有立刻拆开'));
      await settleReveal(tester);
      expect(
        textUnder(tester, find.byType(ContextUsageDetailSheet)),
        contains('没有立刻拆开'),
      );
    });
  });
}
