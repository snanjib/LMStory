import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/shared/components/streaming_fade_text.dart'
    show StreamingFadeText, streamingFadeFreezeChunkCodeUnits;
import 'package:lmstory/core/theme/shared/components/streaming_text_fade.dart'
    show streamingFadeRetention;

///  冻结窗口守卫（2026-10-05 批1）
///
/// 纯性能优化的行为零变化证明。核心不变量：
/// 1. **重组等价**：全部 Text 按「相邻块间补一个 `\n`」重组后 == 原文
///    ——这同时证明：冻结只落在行界、分隔 `\n` 恰好被剥掉一个、无字符
///    丢失/重复；
/// 2. **布局等价**：冻结激活时与同数据单 `Text` 同宽渲染总高度一致
///    ——换行点/行数/行高逐像素等价（任何切分处的换行差异都会改变行数
///    从而改变高度）；
/// 3. 冻结不进入活跃淡入段；替换（含同长度替换）与样式变化整体失效；
///    单行/含 `\r`/reducedMotion 不冻结（树形 = 单 Text）。
void main() {
  const fadeStyle = TextStyle(
    fontSize: 14,
    height: 1.55,
    color: Color(0xFF1B1B1B),
  );

  /// 长多行中文散文：每行 ~44 码元、单 `\n` 分隔、无空行、无特征字符。
  String proseDoc(int targetChars) {
    final buf = StringBuffer();
    var i = 0;
    while (buf.length < targetChars) {
      buf
        ..write('夜色沉下去的时候，走廊尽头的灯还亮着，第 $i 次也是。')
        ..write('她数着台阶下楼，第三级永远比其余的响。')
        ..write('\n');
      i++;
    }
    return buf.toString();
  }

  String plainOf(Text t) => t.data ?? t.textSpan?.toPlainText() ?? '';

  /// 全部 Text 按渲染顺序「相邻块间补 `\n`」重组（未冻结时仅一个 Text，
  /// 零分隔符，公式退化为恒等）。
  String reassemble(WidgetTester tester, Finder scope) => tester
      .widgetList<Text>(
        find.descendant(of: scope, matching: find.byType(Text)),
      )
      .map(plainOf)
      .join('\n');

  Widget host(String data, {TextStyle style = fadeStyle}) => MaterialApp(
        home: Scaffold(
          // 与真实接线同构：流式正文恒处滚动视图内（气泡/稿件卡），
          // 高度不受视口约束——直接放 Scaffold 会让长文 Column 溢出。
          body: SingleChildScrollView(
            child: SizedBox(
              key: const ValueKey('host'),
              width: 300,
              child: StreamingFadeText(data: data, style: style),
            ),
          ),
        ),
      );

  testWidgets('长多行文首帧即冻结，重组 == 原文（行界切分不变式）', (tester) async {
    final doc = proseDoc(streamingFadeFreezeChunkCodeUnits * 4);
    await tester.pumpWidget(host(doc));
    await tester.pump();

    final scope = find.byKey(const ValueKey('host'));
    final textCount = tester
        .widgetList<Text>(
          find.descendant(of: scope, matching: find.byType(Text)),
        )
        .length;
    expect(
      textCount,
      greaterThan(2),
      reason: '4×粒度的长文首帧（首观察淡入尾部 40 码元之前）应已落 ≥2 个冻结块',
    );
    expect(reassemble(tester, scope), doc);
  });

  testWidgets('布局等价：冻结激活时与同数据单 Text 高度逐像素一致', (tester) async {
    final doc = proseDoc(streamingFadeFreezeChunkCodeUnits * 4);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  key: const ValueKey('fade'),
                  width: 300,
                  child: StreamingFadeText(data: doc, style: fadeStyle),
                ),
                SizedBox(
                  key: const ValueKey('plain'),
                  width: 300,
                  child: Text(doc, style: fadeStyle),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // 等淡入留存窗（350ms）过期、冻结推满全部完整行后再比对。
    await tester.pump(streamingFadeRetention * 2);
    await tester.pumpAndSettle();

    final fadeScope = find.descendant(
      of: find.byKey(const ValueKey('fade')),
      matching: find.byType(Text),
    );
    expect(
      tester.widgetList<Text>(fadeScope).length,
      greaterThan(2),
      reason: '前置：冻结必须处于激活态，本用例才有效',
    );
    final fadeBox = tester.getSize(find.byKey(const ValueKey('fade')));
    final plainBox = tester.getSize(find.byKey(const ValueKey('plain')));
    expect(
      fadeBox.height,
      closeTo(plainBox.height, 0.01),
      reason: '冻结切分不得改变总行数/高度（切分处出现多余/缺失换行即露馅）',
    );
  });

  testWidgets('结尾恰为换行：末尾空行不被冻结吃掉', (tester) async {
    final doc = proseDoc(streamingFadeFreezeChunkCodeUnits * 4);
    expect(doc.endsWith('\n'), isTrue);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  key: const ValueKey('fade'),
                  width: 300,
                  child: StreamingFadeText(data: doc, style: fadeStyle),
                ),
                SizedBox(
                  key: const ValueKey('plain'),
                  width: 300,
                  child: Text(doc, style: fadeStyle),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(streamingFadeRetention * 2);
    await tester.pumpAndSettle();

    final fadeBox = tester.getSize(find.byKey(const ValueKey('fade')));
    final plainBox = tester.getSize(find.byKey(const ValueKey('plain')));
    expect(
      fadeBox.height,
      closeTo(plainBox.height, 0.01),
      reason: r'结尾 `\n` 的空行属于渲染结果——活窗须保留它（防吃行回归）',
    );
    expect(
      reassemble(tester, find.byKey(const ValueKey('fade'))),
      doc,
    );
  });

  testWidgets('流式逐帧增长：每步重组 == 当前全文（跨冻结边界无丢失）', (tester) async {
    final doc = proseDoc(streamingFadeFreezeChunkCodeUnits * 3);
    final scope = find.byKey(const ValueKey('host'));
    var pos = 0;
    var step = 0;
    await tester.pumpWidget(host(doc.substring(0, pos = 200)));
    while (pos < doc.length) {
      final next = (pos + 97).clamp(0, doc.length);
      await tester.pumpWidget(host(doc.substring(0, next)));
      pos = next;
      step++;
      // 每步只推进一帧（淡入活跃态下冻结边界受留存窗约束——正是常态）。
      await tester.pump(const Duration(milliseconds: 32));
      expect(
        reassemble(tester, scope),
        doc.substring(0, pos),
        reason: '第 $step 步（pos=$pos）重组必须与当前全文一致',
      );
    }
    // 流结束：等淡入排空，冻结推满，重组仍完整。
    await tester.pump(streamingFadeRetention * 2);
    await tester.pumpAndSettle();
    expect(reassemble(tester, scope), doc);
  });

  testWidgets('替换（同长度，坐标陷阱）整体失效重建', (tester) async {
    final docA = proseDoc(streamingFadeFreezeChunkCodeUnits * 3);
    final docB = proseDoc(streamingFadeFreezeChunkCodeUnits * 3).replaceFirst(
      '夜色沉下去',
      '雨声盖过了',
    );
    expect(docB.length, docA.length, reason: '前置：同长度替换才是坐标陷阱');
    expect(docB == docA, isFalse);

    final scope = find.byKey(const ValueKey('host'));
    await tester.pumpWidget(host(docA));
    await tester.pump(const Duration(milliseconds: 32));
    await tester.pumpWidget(host(docB));
    await tester.pump(streamingFadeRetention * 2);
    await tester.pumpAndSettle();
    expect(reassemble(tester, scope), docB, reason: '替换后冻结缓存必须失效重建');
  });

  testWidgets('样式变化：冻结块整体换新样式', (tester) async {
    final doc = proseDoc(streamingFadeFreezeChunkCodeUnits * 3);
    const newStyle = TextStyle(
      fontSize: 14,
      height: 1.55,
      color: Color(0xFF880000),
    );
    final scope = find.byKey(const ValueKey('host'));
    await tester.pumpWidget(host(doc));
    await tester.pump(const Duration(milliseconds: 32));
    await tester.pumpWidget(host(doc, style: newStyle));
    await tester.pump();
    final texts = tester
        .widgetList<Text>(
          find.descendant(of: scope, matching: find.byType(Text)),
        )
        .toList();
    expect(texts.length, greaterThan(2), reason: '前置：冻结处于激活态');
    for (final t in texts) {
      expect(t.style?.color, const Color(0xFF880000));
    }
  });

  testWidgets('单行超长文不冻结（诚实退化：树形 = 单 Text）', (tester) async {
    final doc = '夜色沉下去的时候走廊尽头的灯还亮着' * 80; // 3840 码元、无 \n
    final scope = find.byKey(const ValueKey('host'));
    await tester.pumpWidget(host(doc));
    await tester.pump(streamingFadeRetention * 2);
    await tester.pumpAndSettle();
    expect(
      tester.widgetList<Text>(
        find.descendant(of: scope, matching: find.byType(Text)),
      ),
      hasLength(1),
      reason: '无行界不可切分（行中切会产生换行机会 = 视觉变化）',
    );
    expect(reassemble(tester, scope), doc);
  });

  testWidgets(r'含 \r（CRLF）不冻结', (tester) async {
    final buf = StringBuffer();
    while (buf.length < streamingFadeFreezeChunkCodeUnits * 3) {
      buf
        ..write('夜色沉下去的时候，走廊尽头的灯还亮着。')
        ..write('\r\n');
    }
    final doc = buf.toString();
    final scope = find.byKey(const ValueKey('host'));
    await tester.pumpWidget(host(doc));
    await tester.pump(streamingFadeRetention * 2);
    await tester.pumpAndSettle();
    expect(
      tester.widgetList<Text>(
        find.descendant(of: scope, matching: find.byType(Text)),
      ),
      hasLength(1),
      reason: 'CRLF 段尾行为无法等价切分——宁可不冻结',
    );
  });

  testWidgets('淡入段不进冻结块：淡入 run 恒在活窗（最后一个 Text）', (tester) async {
    final doc = proseDoc(streamingFadeFreezeChunkCodeUnits * 3);
    final scope = find.byKey(const ValueKey('host'));
    await tester.pumpWidget(host(doc));
    await tester.pump(); // 首观察淡入进行中（尾部 40 码元）

    final texts = tester
        .widgetList<Text>(
          find.descendant(of: scope, matching: find.byType(Text)),
        )
        .toList();
    expect(texts.length, greaterThan(2), reason: '前置：冻结处于激活态');

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

    // 冻结块（除最后一个 Text 外）恒不淡入；淡入 run（若有）只能在活窗。
    for (var i = 0; i < texts.length - 1; i++) {
      expect(
        hasFadingRun(texts[i]),
        isFalse,
        reason: '第 $i 个冻结块不得含淡入段（冻结会烙下半透明残影）',
      );
    }
    expect(hasFadingRun(texts.last), isTrue, reason: '活窗应承载首观察淡入');
  });

  testWidgets('reducedMotion：不冻结不淡入，单 Text 全量直渲', (tester) async {
    final doc = proseDoc(streamingFadeFreezeChunkCodeUnits * 3);
    final scope = find.byKey(const ValueKey('host'));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: SizedBox(
              key: const ValueKey('host'),
              width: 300,
              child: StreamingFadeText(data: doc, style: fadeStyle),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(
      tester.widgetList<Text>(
        find.descendant(of: scope, matching: find.byType(Text)),
      ),
      hasLength(1),
      reason: '减弱动态路径保持既有单 Text 树形',
    );
    expect(reassemble(tester, scope), doc);
  });
}
