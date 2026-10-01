import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/shared/components/streaming_fade_text.dart';
import 'package:lmstory/core/theme/shared/components/streaming_markdown_body.dart';
import 'package:lmstory/core/theme/shared/components/streaming_reveal_pacer.dart'
    show streamingRevealIdleSnap;

/// 平滑揭示配速的接入语义
///
/// 契约：配速由**流式调用方**显式开启（`revealPacing` / `pace`），默认关闭；
/// - 开启后：增长不会整批立刻上屏，而是逐帧放出，源停顿后立即补齐；
/// - 首观察（挂载时已有大段文本）直接到位，不逐帧放出；
/// - 同一条链上不得配速两次（正文壳已配速，其尾块载体传 pace:false）。
void main() {
  const plainStyle = TextStyle(
    fontSize: 15,
    height: 1.6,
    color: Color(0xFF222222),
  );

  String renderedText(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
      .join();

  const initial = '夜色沉了下去的时候';
  const grown = '夜色沉了下去的时候，走廊尽头的灯还亮着';

  testWidgets('开启配速：增长逐帧揭示，源停顿后补齐', (tester) async {
    late StateSetter setStateRef;
    var data = initial;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              setStateRef = setState;
              return StreamingMarkdownBody(
                data: data,
                blockBuilder: (segment) => Text('B:$segment'),
                blockGap: 4,
                plainTextStyle: plainStyle,
                revealPacing: true,
              );
            },
          ),
        ),
      ),
    );
    expect(renderedText(tester), initial, reason: '首观察直接到位（不配速）');

    setStateRef(() => data = grown);
    await tester.pump(const Duration(milliseconds: 16));
    final partial = renderedText(tester);
    expect(
      partial.length,
      lessThan(grown.length),
      reason: '开启配速后不得整批立刻上屏（这是一次蹦好几个字的根源）',
    );
    expect(partial.startsWith(initial), isTrue, reason: '揭示只按前缀推进');

    await tester.pump(
      streamingRevealIdleSnap + const Duration(milliseconds: 50),
    );
    expect(renderedText(tester), grown, reason: '源停顿后立即补齐，不留半截文字');
  });

  testWidgets('默认关闭：增长立即整批渲染（非流式用途/未接线调用方不受影响）', (tester) async {
    late StateSetter setStateRef;
    var data = initial;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              setStateRef = setState;
              return StreamingMarkdownBody(
                data: data,
                blockBuilder: (segment) => Text('B:$segment'),
                blockGap: 4,
                plainTextStyle: plainStyle,
              );
            },
          ),
        ),
      ),
    );

    setStateRef(() => data = grown);
    await tester.pump(const Duration(milliseconds: 16));
    expect(renderedText(tester), grown, reason: '默认行为与改造前一致：立即渲染');
  });

  testWidgets('淡入载体直连时的配速（pace:true）与默认关闭对照', (tester) async {
    late StateSetter setStateRef;
    var data = initial;
    Widget host({required bool pace}) => MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                setStateRef = setState;
                return StreamingFadeText(
                  data: data,
                  style: plainStyle,
                  pace: pace,
                );
              },
            ),
          ),
        );

    await tester.pumpWidget(host(pace: true));
    setStateRef(() => data = grown);
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      renderedText(tester).length,
      lessThan(grown.length),
      reason: 'pace:true 时逐帧揭示',
    );
    await tester.pump(
      streamingRevealIdleSnap + const Duration(milliseconds: 50),
    );
    expect(renderedText(tester), grown);

    data = initial;
    await tester.pumpWidget(host(pace: false));
    setStateRef(() => data = grown);
    await tester.pump(const Duration(milliseconds: 16));
    expect(renderedText(tester), grown, reason: 'pace:false 时立即渲染');
  });
}
