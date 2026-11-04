import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/diagnostics/domain/entities/failure_log_entry.dart';
import 'package:lmstory/features/diagnostics/presentation/widgets/failure_history_widget.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// FailureHistory 模式徽章测试（解耦重构 0.2：三态 mode 误标修复）
///
/// _ModeBadge 此前二态判断，导演（advanced）失败记录落入"对话"徽章。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  FailureLogEntry buildEntry(String mode) {
    return FailureLogEntry(
      id: 1,
      sessionId: 'sess-001',
      mode: mode,
      errorCategory: 'network',
      errorCode: 'E001',
      failedPhase: 'generate',
      errorMessage: '连接超时',
      createdAt: DateTime(2026, 8),
    );
  }

  Widget wrap(FailureLogEntry entry) {
    return TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: FailureHistory(failures: [entry]),
        ),
      ),
    );
  }

  testWidgets('chat 失败记录显示"对话"徽章', (tester) async {
    await tester.pumpWidget(wrap(buildEntry('chat')));

    expect(find.text('对话'), findsOneWidget);
    expect(find.text('故事'), findsNothing);
    expect(find.text('导演'), findsNothing);
  });

  testWidgets('intermediate 失败记录显示"故事"徽章', (tester) async {
    await tester.pumpWidget(wrap(buildEntry('intermediate')));

    expect(find.text('故事'), findsOneWidget);
    expect(find.text('对话'), findsNothing);
  });

  testWidgets('advanced 失败记录显示"导演"徽章（不再误标为"对话"）', (tester) async {
    await tester.pumpWidget(wrap(buildEntry('advanced')));

    expect(find.text('导演'), findsOneWidget);
    expect(find.text('对话'), findsNothing);
    expect(find.text('故事'), findsNothing);
  });
}
