import 'package:flutter_test/flutter_test.dart';

/// 已配置分支经弹层选 GM（起已配置分支不再平铺模型，
/// 测试经由真实用户路径选模型）：
/// 点「选一个模型」→ 弹供应商分组选择器 → 展开供应商组 → 点模型行。
Future<void> pickWizardGmViaSheet(
  WidgetTester tester, {
  String presetName = '测试供应商',
  String modelId = 'model-1',
}) async {
  await tester.ensureVisible(find.text('选一个模型'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('选一个模型'));
  await tester.pumpAndSettle();
  // 无选中组默认收起（组头带数量徽章），先展开
  await tester.tap(find.text(presetName));
  await tester.pumpAndSettle();
  await tester.tap(find.text(modelId));
  await tester.pumpAndSettle();
  // 选择成功 toast（SnackBar 4s）会盖住底部下一步，等它退场再还控
  await tester.pump(const Duration(seconds: 4));
  await tester.pumpAndSettle();
}

/// 嵌入步未配置分支强制显式选择：
/// 点「暂时跳过」后下一步才放行（零写入路径）。
Future<void> skipWizardEmbedding(WidgetTester tester) async {
  await tester.ensureVisible(find.text('暂时跳过'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('暂时跳过'));
  await tester.pumpAndSettle();
}

/// 问卷答题（2026-10-19 方案 C：选项收进单题弹层）：
/// 点摘要卡题干开弹层 → 点选项 → 收弹层。
/// [option] 传 null = 只开弹层不选（自定义输入场景由调用方自行 enterText）。
/// 收弹层两种姿势：默认点遮罩关闭（不触发链式）；
/// [advance] = true 点主按钮（下一题→链式打开下一题弹层，
/// 末题=完成答题→关闭回短页）。
Future<void> answerWizardQuiz(
  WidgetTester tester, {
  required String question,
  String? option,
  bool advance = false,
  bool dismissSheet = true,
}) async {
  await tester.ensureVisible(find.text(question));
  await tester.pumpAndSettle();
  await tester.tap(find.text(question));
  await tester.pumpAndSettle();
  if (option != null) {
    await tester.ensureVisible(find.text(option));
    await tester.pumpAndSettle();
    await tester.tap(find.text(option));
    await tester.pumpAndSettle();
  }
  if (advance) {
    // 主按钮文案随末题/非末题变化（下一题/完成答题），按在场者定位
    final action = find.text('下一题').evaluate().isNotEmpty
        ? find.text('下一题')
        : find.text('完成答题');
    await tester.ensureVisible(action);
    await tester.pumpAndSettle();
    await tester.tap(action);
    await tester.pumpAndSettle();
  } else if (dismissSheet) {
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
  }
}
