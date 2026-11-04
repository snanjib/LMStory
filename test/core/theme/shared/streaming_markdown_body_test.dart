import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/shared/components/streaming_markdown_body.dart';

/// StreamingMarkdownBody 冻结前缀行为单测
///
/// 观测手段：blockBuilder 调用计数与实参——冻结块只应构建一次（之后
/// 返回缓存实例），每帧只重解析尾部窗口。
void main() {
  (List<String> calls, Widget Function(String) builder) trackingBuilder() {
    final calls = <String>[];
    return (
      calls,
      (segment) {
        calls.add(segment);
        return Text(
          'seg:${segment.hashCode}',
          textDirection: TextDirection.ltr,
        );
      },
    );
  }

  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  /// 逐段喂入流式文本并 pump
  Future<void> grow(
    WidgetTester tester,
    List<String> pieces,
    void Function(String) update,
  ) async {
    final acc = StringBuffer();
    for (final p in pieces) {
      acc.write(p);
      update(acc.toString());
      await tester.pump(const Duration(milliseconds: 32));
    }
  }

  testWidgets('冻结块只构建一次，每帧只重解析尾部', (tester) async {
    final (calls, builder) = trackingBuilder();
    late StateSetter setState_;
    var data = '';
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, setState) {
            setState_ = setState;
            return StreamingMarkdownBody(
              data: data,
              blockBuilder: builder,
              blockGap: 4,
            );
          },
        ),
      ),
    );

    // 5 个段落块，unstableTailBlocks=2 → 冻结前 3 块
    const pieces = [
      '第一段内容。\n\n',
      '第二段内容。\n\n',
      '第三段内容。\n\n',
      '第四段内容。\n\n',
      '第五段开头',
    ];
    await grow(tester, pieces, (d) => setState_(() => data = d));

    // 冻结语义：块离开「最后 2 块」窗口时构建恰一次。
    // 前两步全文 ≤2 块、整体属尾部窗口（必然含前段文本）——从第 3 块
    // 到达起第一块进入冻结，之后不再以任何形式重建。
    final firstExact = calls.where((c) => c == '第一段内容。\n\n').length;
    expect(
      firstExact,
      2,
      reason: '第一段独立实参恰两次：初始单块尾窗口 1 次 + 进入冻结 1 次，此后不再出现',
    );
    final tailFullRebuild =
        calls.where((c) => c == '第一段内容。\n\n第二段内容。\n\n').length;
    expect(tailFullRebuild, 1, reason: '第一+二段作为尾窗口整体重解析只发生在第 2 步');
    expect(
      calls.where((c) => c.contains('第一段') && c != '第一段内容。\n\n'),
      isNot(contains('第三段')),
      reason: '第三块到达后第一段不得再出现在任何重解析实参里',
    );

    // 尾部（最后 2 块的内容）每次增长都重解析——至少 3 次
    final tailBuilds = calls.where((c) => c.contains('第三段')).length;
    expect(tailBuilds, greaterThan(1), reason: '倒数第二块尚在窗口内时会被重解析');
  });

  testWidgets('继续增长后尾块进入冻结（构建次数收敛）', (tester) async {
    final (calls, builder) = trackingBuilder();
    late StateSetter setState_;
    var data = '';
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, setState) {
            setState_ = setState;
            return StreamingMarkdownBody(
              data: data,
              blockBuilder: builder,
              blockGap: 4,
            );
          },
        ),
      ),
    );

    const pieces = [
      '第一段。\n\n',
      '第二段。\n\n',
      '第三段。\n\n',
      '第四段。\n\n',
      '第五段。\n\n',
      '第六段。\n\n',
      '第七段。',
    ];
    await grow(tester, pieces, (d) => setState_(() => data = d));

    // 7 块、窗口 2 → 第 3 块到达起第一块冻结；第一段独立实参 =
    // 初始单块尾窗口 1 次 + 冻结 1 次
    final firstSegBuilds = calls.where((c) => c == '第一段。\n\n').length;
    expect(firstSegBuilds, 2, reason: '远离尾部的冻结块冻结后不再重建');

    final totalBuilds = calls.length;
    // 粗上界：若每帧全文重解析，7 帧累计至少 1+2+3+4+5+6+7=28 次；
    // 冻结模式下应显著少于该值
    expect(totalBuilds, lessThan(28));
  });

  testWidgets('非追加变化（替换内容）整体失效重建', (tester) async {
    final (calls, builder) = trackingBuilder();
    late StateSetter setState_;
    var data = '第一段。\n\n第二段。\n\n第三段。\n\n第四段。\n\n';
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, setState) {
            setState_ = setState;
            return StreamingMarkdownBody(
              data: data,
              blockBuilder: builder,
              blockGap: 4,
            );
          },
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 32));
    calls.clear();

    // 编辑替换：前缀不同
    setState_(() => data = '改写后的第一段。\n\n第二段。\n\n');
    await tester.pump(const Duration(milliseconds: 32));

    expect(calls, isNotEmpty);
    expect(
      calls.any((c) => c.contains('改写后')),
      isTrue,
      reason: '非前缀扩展必须整体失效重建，不得复用旧冻结块',
    );
  });

  testWidgets('cacheKey 变化（字体/主题参数）整体失效', (tester) async {
    final (calls, builder) = trackingBuilder();
    late StateSetter setState_;
    const data = '第一段。\n\n第二段。\n\n第三段。\n\n第四段。\n\n';
    var cacheKey = 1.0;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, setState) {
            setState_ = setState;
            return StreamingMarkdownBody(
              data: data,
              blockBuilder: builder,
              blockGap: 4,
              cacheKey: cacheKey,
            );
          },
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 32));
    calls.clear();

    setState_(() => cacheKey = 1.15);
    await tester.pump(const Duration(milliseconds: 32));

    expect(calls, isNotEmpty, reason: '字体缩放变化须让冻结块以新参数重建');
  });

  testWidgets('空数据渲染空占位且不构建任何块', (tester) async {
    final (calls, builder) = trackingBuilder();
    await tester.pumpWidget(
      host(
        StreamingMarkdownBody(data: '', blockBuilder: builder, blockGap: 4),
      ),
    );
    await tester.pump(const Duration(milliseconds: 32));
    expect(calls, isEmpty);
  });

  testWidgets('冻结块 widget 实例跨帧复用（identical 剪枝）', (tester) async {
    Widget probe(String segment) =>
        const Text('probe', textDirection: TextDirection.ltr);

    late StateSetter setState_;
    var data = '';
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, setState) {
            setState_ = setState;
            return StreamingMarkdownBody(
              data: data,
              blockBuilder: probe,
              blockGap: 4,
            );
          },
        ),
      ),
    );

    data = '一。\n\n二。\n\n三。\n\n四。\n\n五。';
    setState_(() {});
    await tester.pump(const Duration(milliseconds: 32));
    final before = tester.widget<Text>(
      find.text('probe').first,
    );

    data = '一。\n\n二。\n\n三。\n\n四。\n\n五。继续增长';
    setState_(() {});
    await tester.pump(const Duration(milliseconds: 32));
    final after = tester.widget<Text>(
      find.text('probe').first,
    );

    expect(
      identical(before, after),
      isTrue,
      reason: '首块（已冻结）的 widget 实例必须跨帧复用',
    );
  });
}
