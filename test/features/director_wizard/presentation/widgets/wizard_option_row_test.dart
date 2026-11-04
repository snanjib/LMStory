import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/lm_button_metrics.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/director_wizard/presentation/widgets/wizard_option_row.dart';

/// 向导整行描边选项组件：选中/未选视觉态、选中即解释、回调与触控高。
void main() {
  Widget wrap(Widget child) {
    return MaterialApp(
      theme: ThemeCatalog.assemble(const LmAppearance(), Brightness.light),
      home: Scaffold(body: child),
    );
  }

  testWidgets('未选态：description 常显、无解释行、点按回调触发', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      wrap(
        WizardOptionRow(
          title: '暂时跳过',
          description: '靠关键词对号入座也够用',
          selected: false,
          onTap: () => tapped = true,
        ),
      ),
    );

    expect(find.text('暂时跳过'), findsOneWidget);
    expect(find.text('靠关键词对号入座也够用'), findsOneWidget);
    expect(
      find.byType(WizardExplanationLine),
      findsNothing,
      reason: '未选中不渲染解释行',
    );

    await tester.tap(find.text('暂时跳过'));
    expect(tapped, isTrue);
  });

  testWidgets('选中态：解释行出现（选中即解释），回调仍可点', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      wrap(
        WizardOptionRow(
          title: '配上（推荐）',
          description: '按意思找回忆',
          explanation: '选它意味着多花一点点',
          selected: true,
          onTap: () => tapped = true,
        ),
      ),
    );

    expect(find.text('配上（推荐）'), findsOneWidget);
    expect(
      find.byType(WizardExplanationLine),
      findsOneWidget,
      reason: '选中后追加解释行',
    );
    expect(find.text('选它意味着多花一点点'), findsOneWidget);

    await tester.tap(find.text('配上（推荐）'));
    expect(tapped, isTrue);
  });

  testWidgets('选中但未提供 explanation：不渲染解释行', (tester) async {
    await tester.pumpWidget(
      wrap(
        WizardOptionRow(
          title: '就按现状继续',
          selected: true,
          onTap: () {},
        ),
      ),
    );
    expect(find.byType(WizardExplanationLine), findsNothing);
  });

  testWidgets('触控高 ≥ 44（q4 守卫口径）', (tester) async {
    await tester.pumpWidget(
      wrap(
        WizardOptionRow(title: '短标题', selected: false, onTap: () {}),
      ),
    );
    final size = tester.getSize(find.byType(InkWell).first);
    expect(
      size.height,
      greaterThanOrEqualTo(LmButtonMetrics.minInteractiveHeight),
    );
  });

  testWidgets('WizardExplanationLine 单独可用：✓ + 一行文本', (tester) async {
    await tester.pumpWidget(
      wrap(const WizardExplanationLine(text: '这一场故事，由 DeepSeek 执笔。')),
    );
    expect(find.text('这一场故事，由 DeepSeek 执笔。'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
  });
}
