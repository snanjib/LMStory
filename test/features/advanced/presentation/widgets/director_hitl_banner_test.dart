import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_hitl_banner.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// DirectorAskBanner / DirectorApprovalBanner widget 测试
///
/// 覆盖：头部 muted 倒计时（分钟数）、0=一直等待档（waitForever）、
/// 首次出现的一行解释（showIntro）与见后回告（onIntroSeen）。
void main() {
  setUpAll(() {
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

  const prompt = AgentAskPrompt(
    question: '守碑人是谁？',
    options: ['旧友', '仇人'],
  );

  group('DirectorAskBanner 倒计时与首释（B8）', () {
    testWidgets('有超时：头部显示剩余分钟倒计时', (tester) async {
      await tester.pumpWidget(
        wrap(
          DirectorAskBanner(
            prompt: prompt,
            onAnswer: (_) {},
            onSkip: () {},
            timeout: const Duration(minutes: 3),
          ),
        ),
      );

      expect(find.text('3 分钟未回应，AI 将自行决定'), findsOneWidget);
      expect(find.text('一直等待你的回复'), findsNothing);
      // 默认无首释行
      expect(
        find.text('AI 遇到关键抉择会请你拍板，超时未回应它将自行决定'),
        findsNothing,
      );
    });

    testWidgets('0=一直等待档：头部显示 waitForever', (tester) async {
      await tester.pumpWidget(
        wrap(
          DirectorAskBanner(
            prompt: prompt,
            onAnswer: (_) {},
            onSkip: () {},
          ),
        ),
      );

      expect(find.text('一直等待你的回复'), findsOneWidget);
      expect(find.textContaining('分钟未回应'), findsNothing);
    });

    testWidgets('首释行：showIntro 显示解释并在见后回告', (tester) async {
      var introSeen = false;
      await tester.pumpWidget(
        wrap(
          DirectorAskBanner(
            prompt: prompt,
            onAnswer: (_) {},
            onSkip: () {},
            timeout: const Duration(minutes: 3),
            showIntro: true,
            onIntroSeen: () => introSeen = true,
          ),
        ),
      );
      await tester.pump();

      expect(
        find.text('AI 遇到关键抉择会请你拍板，超时未回应它将自行决定'),
        findsOneWidget,
      );
      expect(introSeen, isTrue);
    });

    testWidgets('答题交互不受倒计时影响', (tester) async {
      var answered = '';
      await tester.pumpWidget(
        wrap(
          DirectorAskBanner(
            prompt: prompt,
            onAnswer: (a) => answered = a,
            onSkip: () {},
          ),
        ),
      );

      await tester.tap(find.text('旧友'));
      expect(answered, '旧友');
    });
  });

  group('DirectorApprovalBanner 倒计时（B8）', () {
    testWidgets('fail-closed 必有超时：头部显示剩余分钟与拒绝后果', (tester) async {
      await tester.pumpWidget(
        wrap(
          DirectorApprovalBanner(
            prompt: const AgentApprovalPrompt(
              toolName: 'update_facts',
              summary: '一处设定修订',
            ),
            onResolve: ({bool allow = false, always = false}) {},
            timeout: const Duration(minutes: 5),
          ),
        ),
      );

      expect(find.text('5 分钟未回应，将按拒绝处理'), findsOneWidget);
    });

    testWidgets('首释行：showIntro 显示 fail-closed 解释', (tester) async {
      await tester.pumpWidget(
        wrap(
          DirectorApprovalBanner(
            prompt: const AgentApprovalPrompt(
              toolName: 'update_facts',
              summary: '一处设定修订',
            ),
            onResolve: ({bool allow = false, always = false}) {},
            timeout: const Duration(minutes: 5),
            showIntro: true,
          ),
        ),
      );
      await tester.pump();

      expect(
        find.text('关键写入会请你确认，超时未回应将按拒绝处理（fail-closed）'),
        findsOneWidget,
      );
    });
  });

  group('DirectorApprovalBanner 三按钮（B7-4 审批 once/always）', () {
    AgentApprovalPrompt approvalPrompt() => const AgentApprovalPrompt(
          toolName: 'update_facts',
          summary: '一处设定修订',
        );

    testWidgets('第三按钮「本会话总是允许」：回调 allow=true 且 always=true', (tester) async {
      bool? gotAllow;
      bool? gotAlways;
      await tester.pumpWidget(
        wrap(
          DirectorApprovalBanner(
            prompt: approvalPrompt(),
            onResolve: ({allow = false, always = false}) {
              gotAllow = allow;
              gotAlways = always;
            },
            timeout: const Duration(minutes: 5),
          ),
        ),
      );

      expect(find.text('本会话总是允许'), findsOneWidget);
      expect(find.text('允许'), findsOneWidget);
      expect(find.text('拒绝'), findsOneWidget);

      await tester.tap(find.text('本会话总是允许'));
      await tester.pump();
      expect(gotAllow, isTrue);
      expect(gotAlways, isTrue, reason: '会话级放行记忆由 always=true 触发');
    });

    testWidgets('普通「允许」不触发 always；「拒绝」回调 allow=false', (tester) async {
      final calls = <(bool, bool)>[];
      await tester.pumpWidget(
        wrap(
          DirectorApprovalBanner(
            prompt: approvalPrompt(),
            onResolve: ({allow = false, always = false}) =>
                calls.add((allow, always)),
            timeout: const Duration(minutes: 5),
          ),
        ),
      );

      await tester.tap(find.text('允许'));
      await tester.pump();
      await tester.tap(find.text('拒绝'));
      await tester.pump();
      expect(calls, [
        (true, false),
        (false, false),
      ]);
    });
  });
}
