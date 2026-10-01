import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/core/widgets/commit_slider.dart';
import 'package:lmstory/features/settings/presentation/widgets/context_budget_slider.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// ContextBudgetSlider 测试（DOC-14 §3.3）
///
/// 验证  行为：
/// - 传入 onCompactionTriggerRatioChanged 时压缩触发线渲染为可拖滑块
/// - 原文区下限在动态态（null）下也常驻滑块（消除"灰的像坏了"）
/// - 未传入回调时全部只读（_FixedSliderMark，无 CommitSlider）
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Widget wrap(Widget child) {
    return TranslationProvider(
      child: MaterialApp(
        theme: ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
        home: Scaffold(body: child),
      ),
    );
  }

  testWidgets('三档均传入回调时渲染 3 个可拖 CommitSlider', (tester) async {
    await tester.pumpWidget(
      wrap(
        ContextBudgetSlider(
          compactionTriggerRatio: 0.5,
          recentMinRatio: 0.2,
          retrievalRatio: 0.15,
          availableWindow: 96000,
          onCompactionTriggerRatioChanged: (_) {},
          onMinRatioChanged: (_) {},
          onRetrievalRatioChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(CommitSlider), findsNWidgets(3));
  });

  testWidgets('动态态下原文区下限仍常驻滑块', (tester) async {
    await tester.pumpWidget(
      wrap(
        ContextBudgetSlider(
          compactionTriggerRatio: 0.5,
          recentMinRatio: null, // 动态
          retrievalRatio: 0.15,
          availableWindow: 96000,
          onMinRatioChanged: (_) {},
          onRetrievalRatioChanged: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    // recentMin（动态常驻）+ retrieval = 2 个滑块；压缩触发线未传回调 → 只读。
    expect(find.byType(CommitSlider), findsNWidgets(2));
  });

  testWidgets('未传入回调时压缩触发线/原文区下限只读（仅检索区常驻滑块）', (tester) async {
    await tester.pumpWidget(
      wrap(
        const ContextBudgetSlider(
          compactionTriggerRatio: 0.5,
          recentMinRatio: null,
          retrievalRatio: 0.15,
          availableWindow: 96000,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 压缩触发线/原文区下限未传回调 → _FixedSliderMark 只读；
    // 检索区始终渲染滑块（无回调时禁用），故仅 1 个 CommitSlider。
    expect(find.byType(CommitSlider), findsOneWidget);
  });
}
