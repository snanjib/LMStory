import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_narrative_text_styles.dart';

/// 叙事阅读字体槽接线（打包子集）契约测试。
///
/// 三条叙事样式必须指向打包族 LMSerif，中文 fallback LMSerifSC；
/// 字号/行高/字重沿捕获值。缺字运行时抽查属真机验收项。
void main() {
  test('衬线族名与 fallback 链指向打包族', () {
    expect(LmNarrativeTextStyles.serifFamily, 'LMSerif');
    expect(LmNarrativeTextStyles.serifScFamily, 'LMSerifSC');
    expect(
      LmNarrativeTextStyles.narrativeBody.fontFamily,
      'LMSerif',
    );
    expect(
      LmNarrativeTextStyles.narrativeBody.fontFamilyFallback,
      ['LMSerifSC'],
    );
  });

  test('叙事三样式规格沿捕获值', () {
    const body = LmNarrativeTextStyles.narrativeBody;
    expect(body.fontSize, 16);
    expect(body.height, 1.75);
    expect(body.fontWeight, FontWeight.w400);

    const quote = LmNarrativeTextStyles.narrativeQuote;
    expect(quote.fontStyle, FontStyle.italic);
    expect(quote.height, 1.7);

    const display = LmNarrativeTextStyles.narrativeDisplay;
    expect(display.fontSize, 24);
    expect(display.fontWeight, FontWeight.w500);
    expect(display.height, 1.5);
  });

  testWidgets('叙事正文样式可渲染（字体资产在测试绑定可装载）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: Text(
              '夜色沉下去的时候，The light stays on.',
              style: LmNarrativeTextStyles.narrativeBody,
            ),
          ),
        ),
      ),
    );
    expect(
      find.text('夜色沉下去的时候，The light stays on.'),
      findsOneWidget,
    );
  });
}
