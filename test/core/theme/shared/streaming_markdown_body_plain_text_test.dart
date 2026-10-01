import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart' show MarkdownBody;
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/shared/components/streaming_markdown_body.dart';
import 'package:lmstory/core/theme/simple/components/simple_markdown_body.dart';
import 'package:lmstory/core/theme/simple/simple_spacing.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';

/// 活跃块纯文本快速路径单测
///
/// 叙事散文无空行 → 全文一整块 → 永远只有活跃块 → 每 32ms 全文
/// Markdown 重解析（O(n²)）。快速路径：单块活跃尾段经 looksLikePlainText
/// 判纯后用 Text 直渲（plainTextStyle 传入模式 paragraph 款式），出现
/// 特征字符或空行切块立即切回 blockBuilder。
void main() {
  /// blockBuilder 哨兵：每次调用记录实参并渲染可探测的占位
  (List<String>, Widget Function(String)) trackingBuilder() {
    final calls = <String>[];
    return (
      calls,
      (segment) {
        calls.add(segment);
        return Text('block:$segment', textDirection: TextDirection.ltr);
      },
    );
  }

  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: child)),
      );

  const plainStyle = TextStyle(fontSize: 15, height: 1.6);

  group('快速路径接入与回切', () {
    testWidgets('纯文本活跃尾块不经 blockBuilder（淡入盒内 Text 直渲）', (tester) async {
      final (calls, builder) = trackingBuilder();
      await tester.pumpWidget(
        host(
          StreamingMarkdownBody(
            data: '夜色沉下去的时候，走廊尽头的灯还亮着。',
            blockBuilder: builder,
            blockGap: 4,
            plainTextStyle: plainStyle,
          ),
        ),
      );

      expect(calls, isEmpty, reason: '纯文本单块尾段必须完全跳过 Markdown 解析');
      expect(find.byType(MarkdownBody), findsNothing);
      // R 后快速路径为单个 Text.rich（段级颜色 alpha 淡入，无占位盒）
      final texts = tester.widgetList<Text>(find.byType(Text)).toList();
      expect(texts, isNotEmpty);
      expect(
        texts.map((t) => t.data ?? t.textSpan?.toPlainText() ?? '').join(),
        '夜色沉下去的时候，走廊尽头的灯还亮着。',
        reason: '淡入区间拼接必须等于全文',
      );
      for (final text in texts) {
        // 淡入载体显式携带解析后的文本色（传入色 > 环境默认色 > 主题 ink），
        // 淡入 alpha 与最终渲染色同源；字号行高等其余款式保持传入值。
        expect(text.style!.color, isNotNull);
        expect(text.style!.fontSize, plainStyle.fontSize);
        expect(text.style!.height, plainStyle.height);
      }
    });

    testWidgets('段内换行保留在渲染文本中', (tester) async {
      await tester.pumpWidget(
        host(
          StreamingMarkdownBody(
            data: '第一行\n第二行\n第三行',
            blockBuilder: (s) => const SizedBox(),
            blockGap: 4,
            plainTextStyle: plainStyle,
          ),
        ),
      );
      expect(
        tester
            .widgetList<Text>(find.byType(Text))
            .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
            .join(),
        '第一行\n第二行\n第三行',
        reason: '无空行的段内换行不折叠、不丢弃',
      );
    });

    testWidgets('块内出现 * 立即切回 blockBuilder', (tester) async {
      final (calls, builder) = trackingBuilder();
      late StateSetter setState_;
      var data = '正文中段，情节推进';
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) {
              setState_ = setState;
              return StreamingMarkdownBody(
                data: data,
                blockBuilder: builder,
                blockGap: 4,
                plainTextStyle: plainStyle,
              );
            },
          ),
        ),
      );
      expect(calls, isEmpty);

      setState_(() => data = '正文中段，*突然强调*的情节');
      await tester.pump(const Duration(milliseconds: 32));

      expect(calls, ['正文中段，*突然强调*的情节'], reason: '特征字符一旦出现，同帧退回 Markdown 解析路径');
      expect(
        find.text('block:正文中段，*突然强调*的情节'),
        findsOneWidget,
      );
    });

    testWidgets('空行到达：较早块走 blockBuilder，正在写入的尾块保持快速路径', (tester) async {
      final (calls, builder) = trackingBuilder();
      late StateSetter setState_;
      var data = '第一段叙述。';
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) {
              setState_ = setState;
              return StreamingMarkdownBody(
                data: data,
                blockBuilder: builder,
                blockGap: 4,
                plainTextStyle: plainStyle,
              );
            },
          ),
        ),
      );
      expect(calls, isEmpty);

      setState_(() => data = '第一段叙述。\n\n第二段开始了');
      await tester.pump(const Duration(milliseconds: 32));

      // 尾窗含 2 块：较早块（已被空行终结）交 blockBuilder；
      // 「正在写入的尾块」仍走快速路径（复验修复：此前一次空行即全关）。
      expect(calls, ['第一段叙述。\n\n']);
      expect(
        calls.any((s) => s.contains('第二段开始了')),
        isFalse,
        reason: '正在写入的尾块不得交给 MarkdownBody',
      );
    });

    testWidgets('三块时首块冻结、尾窗较早块走 blockBuilder，写入块走快速路径', (tester) async {
      final (calls, builder) = trackingBuilder();
      await tester.pumpWidget(
        host(
          StreamingMarkdownBody(
            data: '一。\n\n二。\n\n三。',
            blockBuilder: builder,
            blockGap: 4,
            plainTextStyle: plainStyle,
          ),
        ),
      );
      expect(calls, contains('一。\n\n'), reason: '冻结块一律经 blockBuilder 构建');
      expect(calls, contains('二。\n\n'), reason: '尾窗内较早的块仍走 Markdown 解析');
      expect(
        calls.any((s) => s.contains('三。')),
        isFalse,
        reason: '最后一个块（正在写入）走快速路径，不进 Markdown',
      );
    });

    testWidgets('尾随空行裁剪后渲染（与整文渲染高度一致）', (tester) async {
      await tester.pumpWidget(
        host(
          StreamingMarkdownBody(
            data: '第一段。\n\n',
            blockBuilder: (s) => const SizedBox(),
            blockGap: 4,
            plainTextStyle: plainStyle,
          ),
        ),
      );
      // 尾随空行若进 Text 会多出空行高度；裁剪后与 MarkdownBody 口径一致
      expect(find.text('第一段。'), findsOneWidget);
      expect(find.textContaining('\n\n'), findsNothing);
    });

    testWidgets('plainTextStyle 为 null 时快速路径禁用（防御默认）', (tester) async {
      final (calls, builder) = trackingBuilder();
      await tester.pumpWidget(
        host(
          StreamingMarkdownBody(
            data: '完全纯的中文散文。',
            blockBuilder: builder,
            blockGap: 4,
          ),
        ),
      );
      expect(calls, ['完全纯的中文散文。'], reason: '无样式参数（旧调用方）行为必须与改造前完全一致');
    });

    testWidgets('样式参数变化时尾段以新样式即时重建（尾段不缓存）', (tester) async {
      final (calls, builder) = trackingBuilder();
      late StateSetter setState_;
      var style = plainStyle;
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) {
              setState_ = setState;
              return StreamingMarkdownBody(
                data: '纯尾段继续生长',
                blockBuilder: builder,
                blockGap: 4,
                plainTextStyle: style,
              );
            },
          ),
        ),
      );
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        expect(text.style!.fontSize, 15);
      }

      // 模拟字体缩放变化：接线方同帧更新 plainTextStyle 与 cacheKey
      setState_(() => style = plainStyle.copyWith(fontSize: 17));
      await tester.pump(const Duration(milliseconds: 32));

      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        expect(
          text.style!.fontSize,
          17,
          reason: '样式随 context 变化时快速路径必须用新样式重渲染',
        );
      }
      expect(calls, isEmpty, reason: '单块纯文本尾段始终不进 Markdown 解析');
    });
  });

  group('同数据 Text vs MarkdownBody 渲染一致性', () {
    // 风险 C 规避：切换瞬间（纯文本 → Markdown）不得出现可感知的尺寸/
    // 样式跳变。同数据、同宽度下断言快速路径 Text 与整文 MarkdownBody
    //（chat 模式真实组件 SimpleMarkdownBody，selectable SelectableText）
    // 的高度差与字号一致。
    const data = '夜色沉下去的时候，走廊尽头的灯还亮着。The corridor light stayed on, '
        'pale and stubborn.\n她数着台阶下楼，第三级永远比其余的响。Step three '
        'always creaked, a small dishonesty in the dark.';

    testWidgets('高度差在阈值内且字号一致', (tester) async {
      const fastKey = ValueKey('fast');
      const slowKey = ValueKey('slow');

      Widget buildBoth() => MaterialApp(
            home: Scaffold(
              body: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 380,
                      child: KeyedSubtree(
                        key: fastKey,
                        child: Builder(
                          builder: (context) {
                            final colors = context.lm.palette;
                            return StreamingMarkdownBody(
                              data: data,
                              blockBuilder: (segment) =>
                                  SimpleMarkdownBody(data: segment),
                              blockGap: SimpleSpacing.s2xs,
                              plainTextStyle: SimpleMarkdownBody.paragraphStyle(
                                colors: colors,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    const SizedBox(
                      width: 380,
                      child: KeyedSubtree(
                        key: slowKey,
                        child: SimpleMarkdownBody(data: data),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );

      // 两个宿主同屏并排挂载（同宽约束下各自自然排版），避免两次
      // pumpWidget 互相替换导致无法对照测量。
      await tester.pumpWidget(buildBoth());
      //  淡入段先过期重组为静态 Text（淡入期为强制 strut 等高，由
      // streaming_markdown_body_fade_test 的高度一致性用例单独把关），
      // 这里度量稳态布局——它才是「快速路径切回 MarkdownBody 瞬间」
      // 的对照基准。
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpWidget(buildBoth());

      final fastSize = tester.getSize(find.byKey(fastKey));
      final slowSize = tester.getSize(find.byKey(slowKey));

      // 实测（2026-09-10，test 环境 fallback 字体，380px 宽，中英混排
      // 两段换行）：两者高度差 0.000px（同为 15px/1.6 行高排版，fast
      // =slow=168.00）。阈值放宽到 1px 防字体替换抖动。
      expect(
        (fastSize.height - slowSize.height).abs(),
        lessThan(1.0),
        reason: '快速路径 Text 与 MarkdownBody 段落排版高度须一致，切换瞬间不可感知',
      );
      expect(fastSize.width, slowSize.width);

      // 字号一致：快速路径 Text 的 style 与 MarkdownBody 段落生效字号同源
      final fastText = tester.widget<Text>(
        find.descendant(of: find.byKey(fastKey), matching: find.byType(Text)),
      );
      final slowEditable = tester.widget<EditableText>(
        find.descendant(
          of: find.byKey(slowKey),
          matching: find.byType(EditableText),
        ),
      );
      expect(fastText.style!.fontSize, slowEditable.style.fontSize);
      expect(fastText.style!.height, slowEditable.style.height);
    });

    testWidgets('纯文本经快速路径时树中无 MarkdownBody（走 Text）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) {
                final colors = context.lm.palette;
                return StreamingMarkdownBody(
                  data: '走廊尽头的灯还亮着。',
                  blockBuilder: (segment) => SimpleMarkdownBody(data: segment),
                  blockGap: SimpleSpacing.s2xs,
                  plainTextStyle:
                      SimpleMarkdownBody.paragraphStyle(colors: colors),
                );
              },
            ),
          ),
        ),
      );
      expect(
        find.byType(MarkdownBody),
        findsNothing,
        reason: '纯文本活跃块不得构建任何 flutter_markdown MarkdownBody',
      );
      expect(
        find.byType(Text),
        findsWidgets,
        reason: 'T9 后内容承载在淡入盒内的 Text（或回收后的静态 Text）',
      );
    });
  });
}
