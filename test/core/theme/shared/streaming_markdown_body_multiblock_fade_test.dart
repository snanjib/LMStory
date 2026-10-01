import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/shared/components/streaming_markdown_body.dart';

/// 多段落消息的流式写入块覆盖（2026-09-10 复验修复的回归基准）
///
/// 背景：快速路径原先的门槛是「全文尚为一整段」（tailBlockCount == 1）。
/// 小说正文几乎必然出现空行分段，因此**一次空行之后整个消息都不再有快速
/// 路径与淡入**——用户在复验中看到的「开头有一点淡入、后面全在蹦字」正是
/// 这条门槛造成的。
///
/// 本文件固化修复后的语义：无论消息已有多少个块，**正在写入的尾块**只要
/// 是纯文本，就必须走快速路径（Text + 段级颜色 alpha 淡入），且不得交给
/// MarkdownBody 每帧重解析。
void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  const plainStyle = TextStyle(
    fontSize: 15,
    height: 1.6,
    color: Color(0xFF222222),
  );

  /// 处于淡入中的区间（按渲染顺序）：只有未完成淡入的段带 per-span 颜色。
  List<({String text, double alpha})> fadeRuns(WidgetTester tester) {
    final out = <({String text, double alpha})>[];
    void walk(InlineSpan span) {
      if (span is! TextSpan) return;
      final color = span.style?.color;
      final text = span.text ?? '';
      if (color != null && text.isNotEmpty) {
        out.add((text: text, alpha: color.a));
      }
      span.children?.forEach(walk);
    }

    for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
      final root = rich.text;
      if (root is TextSpan) {
        root.children?.forEach(walk);
      }
    }
    return out;
  }

  testWidgets('多段落流式：正在写入的尾块仍有淡入（不再一次空行即全关）', (tester) async {
    late StateSetter setState_;
    var data = '第一段已经写完了。\n\n第二段正在写';
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, setState) {
            setState_ = setState;
            return StreamingMarkdownBody(
              data: data,
              blockBuilder: (s) => Text(s, style: plainStyle),
              blockGap: 4,
              plainTextStyle: plainStyle,
            );
          },
        ),
      ),
    );

    setState_(() => data = '第一段已经写完了。\n\n第二段正在写着，走廊尽头的灯还亮着');
    await tester.pump(const Duration(milliseconds: 32));

    final runs = fadeRuns(tester);
    expect(
      runs,
      isNotEmpty,
      reason: '尾块（正在写入的段落）必须享受淡入——此前多段落消息完全没有淡入',
    );
    expect(
      runs.last.text,
      '着，走廊尽头的灯还亮着',
      reason: '淡入必须落在本次新增的文本区间上',
    );
  });

  testWidgets('多段落流式：正在写入的尾块不经 blockBuilder（免每帧 Markdown 重解析）', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      host(
        StreamingMarkdownBody(
          data: '第一段已经写完了。\n\n第二段正在写着',
          blockBuilder: (segment) {
            calls.add(segment);
            return Text(segment, style: plainStyle);
          },
          blockGap: 4,
          plainTextStyle: plainStyle,
        ),
      ),
    );

    expect(
      calls,
      isNotEmpty,
      reason: '较早的块仍交给 Markdown 渲染（只有尾块走快速路径）',
    );
    expect(
      calls.any((s) => s.contains('第二段正在写着')),
      isFalse,
      reason: '正在写入的尾块不得交给 MarkdownBody 渲染',
    );
  });

  testWidgets('多段落流式：写入块内出现特征字符时回退 Markdown', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      host(
        StreamingMarkdownBody(
          data: '第一段。\n\n第二段含 *强调*',
          blockBuilder: (segment) {
            calls.add(segment);
            return Text(segment, style: plainStyle);
          },
          blockGap: 4,
          plainTextStyle: plainStyle,
        ),
      ),
    );

    expect(fadeRuns(tester), isEmpty, reason: '含特征字符的块不淡入');
    expect(
      calls.any((s) => s.contains('第二段含')),
      isTrue,
      reason: '含特征字符的尾块回退 MarkdownBody',
    );
  });
}
