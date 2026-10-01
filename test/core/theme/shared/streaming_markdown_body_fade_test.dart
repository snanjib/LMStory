import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/shared/components/streaming_markdown_body.dart';
import 'package:lmstory/core/theme/shared/components/streaming_text_fade.dart'
    show streamingFadeFirstObservationTailCodeUnits;

/// 新增段淡入 widget 单测（纯文本快速路径载体）
///
/// chatbox streaming-text-fade 的 Flutter 移植：最近 350ms 留存窗口内的
/// 新增文本段以颜色 alpha 浮现（300ms 推进到不透明），窗口外文字零动画。
/// 替换/收缩（重生成）不重放历史淡入。
///
/// R（2026-09-10 复验修复）后的断言口径：
/// - 淡入不再用 WidgetSpan 原子盒，故「有几个盒」这类断言改为「哪些区间
///   处于淡入中」（带 per-span 颜色的子 span）；
/// - 新增两条布局中性回归基准：淡入期与淡入完成后的高度/行数一致、与同
///   宽纯文本逐行指标一致——这是「换行/位置在跳」不复现的硬证据；
/// - 长首帧只淡入尾部窗口（不再按 8 码元切块、不再有盒预算截断）。
///
/// 时钟说明：widget 用 SchedulerBinding 帧时间戳驱动 tracker（本仓库
/// fake_async 锁 1.x 不 fake DateTime.now），测试用 pump(duration) 推进。
void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  // 显式不透明色：淡入 alpha 按「基准色 alpha × 进度」计算，给个确定基准
  // 才能断言中段透明度（真实调用方传各自的 paragraph 款）。
  const plainStyle = TextStyle(
    fontSize: 15,
    height: 1.6,
    color: Color(0xFF222222),
  );

  RichText tailRich(WidgetTester tester) => tester
      .widgetList<RichText>(
        find.descendant(
          of: find.byKey(const ValueKey('streaming-tail')),
          matching: find.byType(RichText),
        ),
      )
      .first;

  /// 收集快速路径尾段当前渲染的完整文本（静态 span + 淡入段拼接）。
  String collectTailText(WidgetTester tester) =>
      (tailRich(tester).text as TextSpan).toPlainText();

  /// 处于淡入中的区间（按渲染顺序）：实现里只有未完成淡入的段会带
  /// per-span 颜色，progress 达 1 后回并为无样式普通 span。
  /// 注意从根 span 的 children 起遍历（根部根 span 带段落基准色与文本，
  /// 那不是淡入）。
  List<({String text, double alpha})> tailFadeRuns(WidgetTester tester) {
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

    final root = tailRich(tester).text;
    if (root is TextSpan) {
      root.children?.forEach(walk);
    }
    return out;
  }

  TextSpan? firstFadeSpan(WidgetTester tester) {
    TextSpan? found;
    void walk(InlineSpan span) {
      if (found != null || span is! TextSpan) return;
      if (span.style?.color != null && (span.text ?? '').isNotEmpty) {
        found = span;
        return;
      }
      span.children?.forEach(walk);
    }

    final root = tailRich(tester).text;
    if (root is TextSpan) {
      root.children?.forEach(walk);
    }
    return found;
  }

  group('淡入段结构与内容完整性', () {
    testWidgets('流式追加两段：两段各自淡入且越早出现越不透明', (tester) async {
      late StateSetter setState_;
      var data = '夜色';
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) {
              setState_ = setState;
              return StreamingMarkdownBody(
                data: data,
                blockBuilder: (s) => const SizedBox(),
                blockGap: 4,
                plainTextStyle: plainStyle,
              );
            },
          ),
        ),
      );
      expect(
        tailFadeRuns(tester).map((r) => r.text),
        ['夜色'],
        reason: '首帧非空文本即进入淡入（新消息首字浮现）',
      );

      setState_(() => data = '夜色沉了');
      await tester.pump(const Duration(milliseconds: 32));
      final runs = tailFadeRuns(tester);
      expect(runs.map((r) => r.text), ['夜色', '沉了']);
      expect(
        runs.first.alpha,
        greaterThan(runs.last.alpha),
        reason: '越早出现的段越接近完全不透明',
      );
      expect(collectTailText(tester), '夜色沉了');
    });

    testWidgets('留存窗口过期后旧段转静态，新段照常淡入', (tester) async {
      late StateSetter setState_;
      var data = '夜色沉了下去';
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) {
              setState_ = setState;
              return StreamingMarkdownBody(
                data: data,
                blockBuilder: (s) => const SizedBox(),
                blockGap: 4,
                plainTextStyle: plainStyle,
              );
            },
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 400));
      setState_(() => data = '夜色沉了下去，走廊');
      await tester.pump(const Duration(milliseconds: 32));

      // 旧段 [0,6) 已过期 → 无样式静态 span；新段 [6,9) 处于淡入中
      expect(tailFadeRuns(tester).map((r) => r.text), ['，走廊']);
      expect(collectTailText(tester), '夜色沉了下去，走廊');
      final root = tailRich(tester).text as TextSpan;
      final children = (root.children!.single as TextSpan).children!;
      expect(children.first, isA<TextSpan>());
      expect(
        (children.first as TextSpan).style,
        isNull,
        reason: '过期段回并为静态 span（无 per-span 样式）',
      );
      expect((children.first as TextSpan).text, '夜色沉了下去');
    });

    testWidgets('淡入完成后帧驱动自停（无残留淡入、无空转帧）', (tester) async {
      late StateSetter setState_;
      var data = '夜色';
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) {
              setState_ = setState;
              return StreamingMarkdownBody(
                data: data,
                blockBuilder: (s) => const SizedBox(),
                blockGap: 4,
                plainTextStyle: plainStyle,
              );
            },
          ),
        ),
      );
      setState_(() => data = '夜色沉了');
      await tester.pump(const Duration(milliseconds: 32));
      expect(tailFadeRuns(tester), isNotEmpty);

      await tester.pump(const Duration(milliseconds: 400));
      // 帧驱动不自停则本行会超时失败
      await tester.pumpAndSettle();
      expect(tailFadeRuns(tester), isEmpty, reason: '淡入完成后不得残留淡入 span');
      expect(collectTailText(tester), '夜色沉了');
    });

    testWidgets(r'含 \n 的段不破坏切分，内容完整', (tester) async {
      late StateSetter setState_;
      var data = '第一行';
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) {
              setState_ = setState;
              return StreamingMarkdownBody(
                data: data,
                blockBuilder: (s) => const SizedBox(),
                blockGap: 4,
                plainTextStyle: plainStyle,
              );
            },
          ),
        ),
      );
      setState_(() => data = '第一行\n她');
      await tester.pump(const Duration(milliseconds: 32));
      expect(collectTailText(tester), '第一行\n她');
      expect(
        tailFadeRuns(tester).map((r) => r.text),
        ['第一行', '\n她'],
        reason: r'\n 计入码元但作为文本切分，不丢内容',
      );
    });

    testWidgets('长首帧只淡入尾部窗口（无原子盒、无盒预算）', (tester) async {
      final data = '夜' * 200;
      await tester.pumpWidget(
        host(
          StreamingMarkdownBody(
            data: data,
            blockBuilder: (s) => const SizedBox(),
            blockGap: 4,
            plainTextStyle: plainStyle,
          ),
        ),
      );
      final runs = tailFadeRuns(tester);
      expect(runs, hasLength(1));
      expect(
        runs.single.text,
        '夜' * streamingFadeFirstObservationTailCodeUnits,
        reason: '长文首观察只淡入尾部窗口（中途重挂不重放整段历史）',
      );
      expect(collectTailText(tester), data, reason: '淡入窗口只影响动效，内容完整');
    });

    testWidgets('淡入段样式与静态段同源（仅颜色不同）', (tester) async {
      await tester.pumpWidget(
        host(
          StreamingMarkdownBody(
            data: '夜色',
            blockBuilder: (s) => const SizedBox(),
            blockGap: 4,
            plainTextStyle: plainStyle,
          ),
        ),
      );
      final fadeSpan = firstFadeSpan(tester)!;
      expect(fadeSpan.style?.fontSize, plainStyle.fontSize);
      expect(fadeSpan.style?.height, plainStyle.height);
    });
  });

  group('动画行为', () {
    testWidgets('淡入随帧推进：150ms 时 alpha 处于 (0,1) 区间', (tester) async {
      await tester.pumpWidget(
        host(
          StreamingMarkdownBody(
            data: '夜色',
            blockBuilder: (s) => const SizedBox(),
            blockGap: 4,
            plainTextStyle: plainStyle,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 150));
      final runs = tailFadeRuns(tester);
      expect(runs, hasLength(1));
      expect(runs.single.alpha, greaterThan(0));
      expect(runs.single.alpha, lessThan(1), reason: '300ms 动画中段不得已完成');
      expect(runs.single.alpha, closeTo(0.5, 0.02));
    });

    testWidgets('跨 flush 不重启：旧段进度连续推进', (tester) async {
      late StateSetter setState_;
      var data = '夜色';
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) {
              setState_ = setState;
              return StreamingMarkdownBody(
                data: data,
                blockBuilder: (s) => const SizedBox(),
                blockGap: 4,
                plainTextStyle: plainStyle,
              );
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final before = tailFadeRuns(tester).single.alpha;

      setState_(() => data = '夜色沉了');
      await tester.pump(const Duration(milliseconds: 100));
      final runs = tailFadeRuns(tester);
      expect(runs.first.text, '夜色');
      expect(
        runs.first.alpha,
        greaterThan(before),
        reason: '旧段淡入必须从当前进度继续，不得重启',
      );
    });
  });

  group('布局中性（T9R 复验修复的回归基准）', () {
    testWidgets('淡入期与淡入完成后尺寸完全一致', (tester) async {
      const data = '夜色沉下去的时候走廊尽头的灯还亮着，她数着台阶下楼，第三级永远比其余的响。';
      Widget build() => MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 380,
                  child: StreamingMarkdownBody(
                    data: data,
                    blockBuilder: (s) => const SizedBox(),
                    blockGap: 4,
                    plainTextStyle: plainStyle,
                  ),
                ),
              ),
            ),
          );

      await tester.pumpWidget(build());
      expect(tailFadeRuns(tester), isNotEmpty, reason: '前置：确认处于淡入期');
      final sizeDuringFade = tester.getSize(find.byType(StreamingMarkdownBody));

      await tester.pump(const Duration(milliseconds: 400));
      expect(tailFadeRuns(tester), isEmpty);
      final sizeSettled = tester.getSize(find.byType(StreamingMarkdownBody));

      expect(
        sizeSettled.height,
        closeTo(sizeDuringFade.height, 0.01),
        reason: '淡入不得改变段落高度（原子盒方案在此处会产生行数与高度跳变）',
      );
    });

    testWidgets('与同宽纯文本逐行指标一致（换行点相同）', (tester) async {
      const data = '夜色沉下去的时候走廊尽头的灯还亮着，她数着台阶下楼，第三级永远比其余的响。';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  key: const ValueKey('fade'),
                  width: 240,
                  child: StreamingMarkdownBody(
                    data: data,
                    blockBuilder: (s) => const SizedBox(),
                    blockGap: 4,
                    plainTextStyle: plainStyle,
                  ),
                ),
                const SizedBox(
                  key: ValueKey('plain'),
                  width: 240,
                  child: Text(data, style: plainStyle),
                ),
              ],
            ),
          ),
        ),
      );
      expect(tailFadeRuns(tester), isNotEmpty, reason: '前置：确认处于淡入期');

      final fadeBox = tester.getSize(find.byKey(const ValueKey('fade')));
      final plainBox = tester.getSize(find.byKey(const ValueKey('plain')));
      expect(
        fadeBox.height,
        closeTo(plainBox.height, 0.01),
        reason: '淡入期的行数与纯文本一致（高度一致即无换行跳变）',
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

  group('边界与降级', () {
    testWidgets('重生成替换不重放淡入（替换帧零淡入段）', (tester) async {
      late StateSetter setState_;
      var data = '旧的内容文字';
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) {
              setState_ = setState;
              return StreamingMarkdownBody(
                data: data,
                blockBuilder: (s) => const SizedBox(),
                blockGap: 4,
                plainTextStyle: plainStyle,
              );
            },
          ),
        ),
      );
      expect(tailFadeRuns(tester), isNotEmpty);

      setState_(() => data = '完全不同的开头');
      await tester.pump(const Duration(milliseconds: 32));
      expect(tailFadeRuns(tester), isEmpty, reason: '非前缀替换=清空段，不淡入');
      expect(collectTailText(tester), '完全不同的开头');

      // 替换后恢复追加：从替换文本尾部起新段
      setState_(() => data = '完全不同的开头。');
      await tester.pump(const Duration(milliseconds: 32));
      expect(tailFadeRuns(tester).map((r) => r.text), ['。']);
      expect(collectTailText(tester), '完全不同的开头。');
    });

    testWidgets('MediaQuery.disableAnimations 时禁用淡入', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(disableAnimations: true),
              child: StreamingMarkdownBody(
                data: '夜色沉了下去',
                blockBuilder: (s) => const SizedBox(),
                blockGap: 4,
                plainTextStyle: plainStyle,
              ),
            ),
          ),
        ),
      );
      expect(tailFadeRuns(tester), isEmpty);
      expect(
        collectTailText(tester),
        '夜色沉了下去',
        reason: '无障碍降级：内容照常渲染，仅跳过动画',
      );
    });

    testWidgets('特征字符出现切回 blockBuilder 时淡入自然终止', (tester) async {
      final calls = <String>[];
      late StateSetter setState_;
      var data = '夜色沉了下去';
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) {
              setState_ = setState;
              return StreamingMarkdownBody(
                data: data,
                blockBuilder: (segment) {
                  calls.add(segment);
                  return Text('block:$segment');
                },
                blockGap: 4,
                plainTextStyle: plainStyle,
              );
            },
          ),
        ),
      );
      expect(tailFadeRuns(tester), isNotEmpty);

      setState_(() => data = '夜色沉了下去，*强调*来了');
      await tester.pump(const Duration(milliseconds: 32));
      expect(
        tailFadeRuns(tester),
        isEmpty,
        reason: '回退 Markdown 路径时快速路径整体卸载',
      );
      expect(calls.last, '夜色沉了下去，*强调*来了');
    });
  });
}
