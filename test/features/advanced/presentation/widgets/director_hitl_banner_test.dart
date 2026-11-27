import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/core/agent/agent_tool_pipeline.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/domain/services/agent_approval_composer.dart';
import 'package:lmstory/features/advanced/presentation/utils/agent_approval_labels.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_hitl_banner.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../../../helpers/fake_factual_repository.dart';

/// DirectorAskBanner / DirectorApprovalBanner widget 测试
///
/// 覆盖：头部 muted 倒计时（分钟数）、0=一直等待档（waitForever）、
/// 首次出现的一行解释（showIntro）与见后回告（onIntroSeen）。
void _noopResolve({
  bool allow = false,
  bool always = false,
  String? feedback,
}) {}

void main() {
  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.enUs);
    await LocaleSettings.setLocale(AppLocale.zhCn);
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

  group('Approval details follow the interface language', () {
    final createdAt = DateTime(2026);

    Future<void> showPendingApproval(
      WidgetTester tester, {
      required String tool,
      required Map<String, dynamic> arguments,
      EventSummary? previousEvent,
    }) async {
      LocaleSettings.setLocaleSync(AppLocale.zhCn);
      addTearDown(() => LocaleSettings.setLocaleSync(AppLocale.zhCn));
      final repo = FakeFactualRepository()
        ..entitiesById['target'] = FactualEntity(
          entityId: 'target',
          sessionId: 'story',
          type: FactualEntityType.character,
          primaryName: '林晚',
          aliases: const [],
          importance: 3,
          createdTurn: 1,
          createdAt: createdAt,
        )
        ..seedAttribute(
          FactualAttribute(
            attributeId: 'skills',
            entityId: 'target',
            sessionId: 'story',
            attrKey: 'skills',
            value: '[]',
            valueType: AttributeValueType.list,
            importance: 3,
            createdAt: createdAt,
          ),
        );
      final changes = await AgentApprovalComposer(
        repository: repo,
        sessionId: 'story',
        draftTurnNumber: 2,
        currentAnchor: null,
        draftAnchor: null,
        draftEventSummary: previousEvent,
      ).compose(
        ToolExecutionRequest(
          callId: 'call',
          toolName: tool,
          arguments: arguments,
          permission: AgentToolPermission.write,
        ),
      );
      await tester.pumpWidget(
        wrap(
          DirectorApprovalBanner(
            prompt: AgentApprovalPrompt(
              toolName: tool,
              summary: '待处置',
              summaryData: approvalSummaryDataOf(tool, arguments),
              changes: changes,
            ),
            onResolve: _noopResolve,
            timeout: null,
          ),
        ),
      );
      await tester.tap(find.text('查看 ${changes.length} 处变更明细'));
      await tester.pumpAndSettle();
    }

    Future<void> switchToEnglish(WidgetTester tester) async {
      LocaleSettings.setLocaleSync(AppLocale.enUs);
      await tester.pumpAndSettle();
      expect(find.text('Hide details'), findsOneWidget);
    }

    testWidgets('the archive badge switches and the entity name stays intact', (
      tester,
    ) async {
      await showPendingApproval(
        tester,
        tool: 'update_facts',
        arguments: {
          'deltas': [
            {
              'action': 'archive_entity',
              'entity_id': 'target',
              'reason': '离开港口',
              'confidence': 5,
            },
          ],
        },
      );
      expect(find.text('归档'), findsOneWidget);
      await switchToEnglish(tester);
      expect(find.text('Archive'), findsOneWidget);
      expect(find.text('林晚'), findsOneWidget);
      expect(find.textContaining('离开港口'), findsOneWidget);
      expect(find.textContaining(RegExp('^(Old|New)[：:]')), findsNothing);
    });

    testWidgets('a merge reference localizes the empty list and built-in key', (
      tester,
    ) async {
      await showPendingApproval(
        tester,
        tool: 'merge_entities',
        arguments: {
          'source_name': '守碑人',
          'target_entity_id': 'target',
          'reason': '同一个人在用化名',
        },
      );
      final zhValue = find.text('新：技能：无').evaluate().length;
      await switchToEnglish(tester);
      expect(find.text('林晚 · Skills'), findsOneWidget);
      expect(find.text('New: Skills: None'), findsOneWidget);
      expect(find.textContaining('Merge "守碑人" into "林晚"'), findsOneWidget);
      expect(find.textContaining('同一个人在用化名'), findsOneWidget);
      expect(zhValue, 1);
    });

    testWidgets('an event replacement localizes placeholders and labels', (
      tester,
    ) async {
      await showPendingApproval(
        tester,
        tool: 'record_event_memory',
        arguments: {'what': '她说「人物：无」', 'who': '林晚'},
        previousEvent: const EventSummary(
          importance: 3,
          tags: [],
          turnNumber: 2,
        ),
      );
      expect(find.textContaining('空事件'), findsOneWidget);
      await switchToEnglish(tester);
      expect(find.text('Old: (Empty event)'), findsOneWidget);
      expect(find.text('New: 她说「人物：无」'), findsOneWidget);
      expect(find.textContaining('Who: 林晚'), findsOneWidget);
      expect(find.textContaining('Will replace the previous'), findsOneWidget);
      expect(find.textContaining('When:'), findsNothing);
    });
  });

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

  group('决策卡选项按钮感与字体缩放', () {
    testWidgets('选项渲染为整行 OutlinedButton（2 选项 + 跳过），点击即答', (tester) async {
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

      final buttons = find.descendant(
        of: find.byType(DirectorAskBanner),
        matching: find.byType(OutlinedButton),
      );
      expect(buttons, findsNWidgets(3), reason: '2 个选项行按钮 + 1 个跳过按钮');

      await tester.tap(find.text('旧友'));
      await tester.pump();
      expect(answered, '旧友');
    });

    testWidgets('问题正文随 fontScale 缩放（「字体大小」设置联动）', (tester) async {
      double questionHeight() {
        return tester.getSize(find.text('守碑人是谁？')).height;
      }

      await tester.pumpWidget(
        wrap(
          DirectorAskBanner(
            prompt: prompt,
            onAnswer: (_) {},
            onSkip: () {},
          ),
        ),
      );
      final base = questionHeight();

      await tester.pumpWidget(
        wrap(
          DirectorAskBanner(
            prompt: prompt,
            onAnswer: (_) {},
            onSkip: () {},
            fontScale: 1.5,
          ),
        ),
      );
      expect(questionHeight(), greaterThan(base * 1.2));
    });
  });

  group('DirectorApprovalBanner 倒计时（B8）', () {
    testWidgets('fail-closed 必有超时：头部显示剩余分钟与拒绝后果', (tester) async {
      await tester.pumpWidget(
        wrap(
          const DirectorApprovalBanner(
            prompt: AgentApprovalPrompt(
              toolName: 'update_facts',
              summary: '一处设定修订',
            ),
            onResolve: _noopResolve,
            timeout: Duration(minutes: 5),
          ),
        ),
      );

      expect(find.text('5 分钟未回应，将按拒绝处理'), findsOneWidget);
    });

    testWidgets('首释行：showIntro 显示 fail-closed 解释', (tester) async {
      await tester.pumpWidget(
        wrap(
          const DirectorApprovalBanner(
            prompt: AgentApprovalPrompt(
              toolName: 'update_facts',
              summary: '一处设定修订',
            ),
            onResolve: _noopResolve,
            timeout: Duration(minutes: 5),
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

  group('DirectorApprovalBanner 三按钮与共用批注（B7-4 + 2026-10-15 P1/P4）', () {
    AgentApprovalPrompt approvalPrompt({
      String toolName = 'update_facts',
      List<AgentApprovalChange> changes = const [],
      int pendingPriorChanges = 0,
    }) =>
        AgentApprovalPrompt(
          toolName: toolName,
          summary: '一处设定修订',
          changes: changes,
          pendingPriorChanges: pendingPriorChanges,
        );

    testWidgets('「本会话总是允许」回调 allow=true 且 always=true', (tester) async {
      bool? gotAllow;
      bool? gotAlways;
      await tester.pumpWidget(
        wrap(
          DirectorApprovalBanner(
            prompt: approvalPrompt(),
            onResolve: ({allow = false, always = false, String? feedback}) {
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

    testWidgets('P4：merge_entities 横幅无「本会话总是允许」按钮', (tester) async {
      await tester.pumpWidget(
        wrap(
          DirectorApprovalBanner(
            prompt: approvalPrompt(toolName: 'merge_entities'),
            onResolve: _noopResolve,
            timeout: const Duration(minutes: 5),
          ),
        ),
      );

      expect(find.text('本会话总是允许'), findsNothing);
      expect(find.text('允许'), findsOneWidget);
      expect(find.text('拒绝'), findsOneWidget);
    });

    testWidgets('P1 共用批注：填字允许→feedback 透传；不填允许→无 feedback', (tester) async {
      final calls = <({bool allow, String? feedback})>[];
      await tester.pumpWidget(
        wrap(
          DirectorApprovalBanner(
            prompt: approvalPrompt(),
            onResolve: ({allow = false, always = false, feedback}) =>
                calls.add((allow: allow, feedback: feedback)),
            timeout: const Duration(minutes: 5),
          ),
        ),
      );

      // 不填：纯允许零追加
      await tester.tap(find.text('允许'));
      await tester.pump();
      expect(calls.single, (allow: true, feedback: null));

      // 展开批注区填字：允许带批注
      calls.clear();
      await tester.tap(find.text('附加批注（可选）'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '把表演和真性格区分开');
      await tester.tap(find.text('允许'));
      await tester.pump();
      expect(calls.single, (allow: true, feedback: '把表演和真性格区分开'));
    });

    testWidgets('P1 共用批注：填字拒绝→feedback 走拒绝通道（一步直达）', (tester) async {
      String? gotFeedback;
      bool? gotAllow;
      await tester.pumpWidget(
        wrap(
          DirectorApprovalBanner(
            prompt: approvalPrompt(),
            onResolve: ({allow = false, always = false, feedback}) {
              gotAllow = allow;
              gotFeedback = feedback;
            },
            timeout: const Duration(minutes: 5),
          ),
        ),
      );

      // 直接拒绝（无批注）：纯拒绝
      await tester.tap(find.text('拒绝'));
      await tester.pump();
      expect(gotAllow, false);
      expect(gotFeedback, isNull);

      // 批注+拒绝：留言随拒绝下发
      await tester.tap(find.text('附加批注（可选）'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '换个措辞再写，保留旧设定');
      await tester.tap(find.text('拒绝'));
      await tester.pump();
      expect(gotAllow, false);
      expect(gotFeedback, '换个措辞再写，保留旧设定');
    });

    testWidgets('批注 500 字上限：超限截断', (tester) async {
      String? gotFeedback;
      await tester.pumpWidget(
        wrap(
          DirectorApprovalBanner(
            prompt: approvalPrompt(),
            onResolve: ({allow = false, always = false, feedback}) =>
                gotFeedback = feedback,
            timeout: const Duration(minutes: 5),
          ),
        ),
      );

      await tester.tap(find.text('附加批注（可选）'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), '长' * 600);
      await tester.tap(find.text('允许'));
      await tester.pump();
      expect(gotFeedback!.length, 500);
    });
  });

  group('DirectorApprovalBanner 变更明细（2026-10-15 批 C）', () {
    const changes = [
      AgentApprovalChange(
        entityName: '林晚',
        attrKey: 'personality',
        kind: ApprovalChangeKind.updateAttr,
        before: '冷静自持，极少情绪外露',
        after: '热情冲动，喜怒形于色',
        reason: '本轮她为掩护同伴故意夸张表演',
        confidence: 2,
      ),
      AgentApprovalChange(
        entityName: '林晚',
        attrKey: 'personality',
        kind: ApprovalChangeKind.updateAttr,
        note: '值相同，不会产生变化',
        effective: false,
        confidence: 5,
      ),
    ];

    testWidgets('明细默认收起，点击展开渲染行卡（含理由/置信度/灰显 note）', (tester) async {
      await tester.pumpWidget(
        wrap(
          const DirectorApprovalBanner(
            prompt: AgentApprovalPrompt(
              toolName: 'update_facts',
              summary: '修订设定集 · 2 处',
              changes: changes,
            ),
            onResolve: _noopResolve,
            timeout: Duration(minutes: 5),
          ),
        ),
      );

      // 默认收起：只有展开入口
      expect(find.text('查看 2 处变更明细'), findsOneWidget);
      expect(find.text('冷静自持，极少情绪外露'), findsNothing);

      await tester.tap(find.text('查看 2 处变更明细'));
      await tester.pumpAndSettle();

      expect(find.text('收起明细'), findsOneWidget);
      expect(find.text('林晚 · personality'), findsNWidgets(2));
      expect(find.text('旧：冷静自持，极少情绪外露'), findsOneWidget);
      expect(find.text('新：热情冲动，喜怒形于色'), findsOneWidget);
      expect(find.text('理由：本轮她为掩护同伴故意夸张表演'), findsOneWidget);
      expect(find.text('置信度 2/5'), findsOneWidget);
      expect(find.text('值相同，不会产生变化'), findsOneWidget);
    });

    testWidgets('pendingPriorChanges>0 显示脚注；=0 不显示', (tester) async {
      await tester.pumpWidget(
        wrap(
          const DirectorApprovalBanner(
            prompt: AgentApprovalPrompt(
              toolName: 'update_facts',
              summary: '修订设定集',
              pendingPriorChanges: 3,
            ),
            onResolve: _noopResolve,
            timeout: Duration(minutes: 5),
          ),
        ),
      );
      expect(find.text('本轮此前已批准暂存 3 处，收笔时统一提交'), findsOneWidget);
    });
  });

  group('DirectorApprovalBanner P2 永等与交互重置（2026-10-15 批 C）', () {
    testWidgets('timeout=null（开关关）：显示永等说明、无倒计时分钟数', (tester) async {
      await tester.pumpWidget(
        wrap(
          const DirectorApprovalBanner(
            prompt: AgentApprovalPrompt(
              toolName: 'update_facts',
              summary: '一处设定修订',
            ),
            onResolve: _noopResolve,
            timeout: null,
          ),
        ),
      );

      expect(find.text('已关闭确认超时，一直等待你的处置'), findsOneWidget);
      expect(find.textContaining('分钟未回应'), findsNothing);
    });

    testWidgets('交互活动重置倒计时：接近超时→展开明细→倒计时回到满额', (tester) async {
      // 横幅经 clock.now() 取时（非 DateTime.now()）——假时钟可控：
      // 锚点=挂起时刻，计算=当前假时刻，展开明细应重置锚点回满额。
      var fakeNow = DateTime(2026, 10, 15, 12);
      DateTime now() => fakeNow;
      await tester.pumpWidget(
        wrap(
          DirectorApprovalBanner(
            key: const ValueKey('banner'),
            now: now,
            prompt: const AgentApprovalPrompt(
              toolName: 'update_facts',
              summary: '修订设定集 · 1 处',
              changes: [
                AgentApprovalChange(
                  entityName: '林晚',
                  attrKey: 'personality',
                  kind: ApprovalChangeKind.updateAttr,
                  after: '热情冲动',
                ),
              ],
            ),
            onResolve: _noopResolve,
            timeout: const Duration(minutes: 5),
          ),
        ),
      );
      expect(find.text('5 分钟未回应，将按拒绝处理'), findsOneWidget);

      // 时间流逝 4 分钟（剩 1 分钟）
      fakeNow = fakeNow.add(const Duration(minutes: 4));
      // pump 带时长：驱动每分钟 ticker fire → setState → 按注入时钟重算
      await tester.pump(const Duration(minutes: 4));
      expect(find.text('1 分钟未回应，将按拒绝处理'), findsOneWidget);

      // 展开明细 = 交互活动 → 锚点重置为当前假时刻，回到 5 分钟
      await tester.tap(find.text('查看 1 处变更明细'));
      await tester.pump();
      expect(find.text('5 分钟未回应，将按拒绝处理'), findsOneWidget);
    });
  });
}
