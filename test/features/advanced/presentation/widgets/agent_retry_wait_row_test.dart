import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_work_group.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 请求重试等待状态条 widget 测试
///
/// 倒计时以事件到达时刻（AgentRetryWait.scheduledAtMs）为锚，按 fake clock
/// 推进递减；不使用 pumpAndSettle（微光动画为无限循环）。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Widget wrap(Widget child) => TranslationProvider(
        child: MaterialApp(home: Scaffold(body: child)),
      );

  testWidgets('状态条显示徽标与锚定倒计时，随 fake clock 递减', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await tester.pumpWidget(
      wrap(
        AgentRetryWaitRow(
          wait: AgentRetryWait(waitMs: 10000, attempt: 2, scheduledAtMs: now),
        ),
      ),
    );

    // 批 F：徽标并入进度文案（cause=null 未知原因 + 无 max → 旧两段式；
    // ShimmerText 单体渲染倒计时行）
    expect(find.text('10s 后第 2 次重试'), findsOneWidget);

    // 前进 2 秒：倒计时按锚点递减（10s → 8s）
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('8s 后第 2 次重试'), findsOneWidget);
  });

  testWidgets('剩余归零显示 0s，不再递减为负', (tester) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await tester.pumpWidget(
      wrap(
        AgentRetryWaitRow(
          wait: AgentRetryWait(waitMs: 1500, attempt: 1, scheduledAtMs: now),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('0s 后第 1 次重试'), findsOneWidget);
  });
}
