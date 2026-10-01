import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_work_group.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// DirectorWorkGroup 组件测试（对话流 ：单一折叠组）
///
/// 验证：
/// - 标题算术：幕后 N 步 · 思考 M 段 · Xs（N=动作块数、M=思考块数）
/// - 展开态：思考块/动作卡/播报行按时间线顺序交错
/// - 思考块时长标题（持续 N 秒），无起止数据回退字数口径
/// - 错误徽标（图标转红）与收起态错误卡常显
/// - live 态沿用「正在 X… · 第 N 步」原地更新
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Widget wrap(Widget child) {
    return TranslationProvider(
      child: MaterialApp(
        theme: ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
        home: Scaffold(body: ListView(children: [child])),
      ),
    );
  }

  const timeline = [
    AgentTimelineBlock(
      kind: AgentTimelineKind.thinking,
      stepIndex: 0,
      text: '先查前情。',
      startMs: 0,
      endMs: 6000,
    ),
    AgentTimelineBlock(
      kind: AgentTimelineKind.action,
      stepIndex: 0,
      action: AgentWorkStep(
        toolName: 'search_story',
        callId: 'call-1',
        title: '「古碑」· 12 处命中',
        durationMs: 800,
      ),
    ),
    AgentTimelineBlock(
      kind: AgentTimelineKind.narration,
      stepIndex: 0,
      text: '前情里没查到这个人，这轮让她自己出场。',
    ),
    AgentTimelineBlock(
      kind: AgentTimelineKind.action,
      stepIndex: 1,
      action: AgentWorkStep(toolName: 'finish_round', callId: 'call-2'),
    ),
  ];

  group('DirectorWorkGroup 收起态（历史轮）', () {
    testWidgets('1. 标题算术：幕后 N 步 · 思考 M 段 · Xs', (tester) async {
      await tester.pumpWidget(
        wrap(
          const DirectorWorkGroup(
            timeline: timeline,
            summary: AgentWorkSummary(
              steps: 2,
              totalTokens: 1000,
              durationMs: 12000,
            ),
          ),
        ),
      );

      expect(find.text('幕后 2 步 · 思考 1 段 · 12s'), findsOneWidget);
    });

    testWidgets('2. 无 summary 不显示时长；零思考段自适应', (tester) async {
      await tester.pumpWidget(
        wrap(
          const DirectorWorkGroup(
            timeline: [
              AgentTimelineBlock(
                kind: AgentTimelineKind.action,
                stepIndex: 0,
                action: AgentWorkStep(toolName: 'search_story'),
              ),
            ],
          ),
        ),
      );

      expect(find.text('幕后 1 步 · 思考 0 段'), findsOneWidget);
    });

    testWidgets('3. 点击展开：思考/动作/播报按时间线交错', (tester) async {
      await tester
          .pumpWidget(wrap(const DirectorWorkGroup(timeline: timeline)));
      await tester.tap(find.byIcon(Icons.tungsten_outlined));
      await tester.pumpAndSettle();

      // 交错顺序：思考标题 → 动作卡 → 播报 → 动作卡
      final thinkingTitle = find.text('思考 · 持续 6 秒');
      final actionCard = find.text('翻阅前情 · 「古碑」· 12 处命中');
      final narration = find.textContaining('这轮让她自己出场');
      expect(thinkingTitle, findsOneWidget);
      expect(actionCard, findsOneWidget);
      expect(narration, findsOneWidget);
      expect(
        tester.getTopLeft(thinkingTitle).dy,
        lessThan(tester.getTopLeft(actionCard).dy),
        reason: '思考块在动作卡前',
      );
      expect(
        tester.getTopLeft(actionCard).dy,
        lessThan(tester.getTopLeft(narration).dy),
        reason: '同 step 思考→动作→文本',
      );
    });

    testWidgets('3b. G-28：播报行弱化——前缀图标+左侧竖线+小一号', (tester) async {
      await tester
          .pumpWidget(wrap(const DirectorWorkGroup(timeline: timeline)));
      await tester.tap(find.byIcon(Icons.tungsten_outlined));
      await tester.pumpAndSettle();

      // 前缀图标存在（弱化标识）
      expect(find.byIcon(Icons.record_voice_over_outlined), findsOneWidget);
      // 播报文本仍可读
      expect(find.textContaining('这轮让她自己出场'), findsOneWidget);
    });

    testWidgets('3c. G-18：连续同工具动作 >3 聚合为一行，点开逐卡', (tester) async {
      final sixSearches = [
        for (var i = 0; i < 6; i++)
          AgentTimelineBlock(
            kind: AgentTimelineKind.action,
            stepIndex: i,
            action: AgentWorkStep(
              toolName: 'query_facts',
              callId: 'call-q$i',
              title: '查证 $i',
            ),
          ),
      ];
      await tester.pumpWidget(wrap(DirectorWorkGroup(timeline: sixSearches)));
      await tester.tap(find.byIcon(Icons.tungsten_outlined));
      await tester.pumpAndSettle();

      // 聚合行出现，逐卡不渲染
      expect(find.text('查证设定 × 6'), findsOneWidget);
      expect(find.textContaining('查证 0'), findsNothing);

      // 点开：六张卡逐卡渲染
      await tester.tap(find.text('查证设定 × 6'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 6; i++) {
        expect(find.textContaining('查证 $i'), findsOneWidget);
      }
    });

    testWidgets('3d. G-18：≤3 或含错误的同工具段不聚合', (tester) async {
      final mixed = [
        for (var i = 0; i < 2; i++)
          AgentTimelineBlock(
            kind: AgentTimelineKind.action,
            stepIndex: i,
            action: AgentWorkStep(
              toolName: 'query_facts',
              callId: 'call-s$i',
            ),
          ),
        const AgentTimelineBlock(
          kind: AgentTimelineKind.action,
          stepIndex: 2,
          action: AgentWorkStep(
            toolName: 'query_facts',
            callId: 'call-bad',
            status: AgentStepStatus.error,
          ),
        ),
        for (var i = 3; i < 6; i++)
          AgentTimelineBlock(
            kind: AgentTimelineKind.action,
            stepIndex: i,
            action: AgentWorkStep(
              toolName: 'query_facts',
              callId: 'call-s$i',
            ),
          ),
      ];
      await tester.pumpWidget(wrap(DirectorWorkGroup(timeline: mixed)));
      await tester.tap(find.byIcon(Icons.tungsten_outlined));
      await tester.pumpAndSettle();

      // 含错误步骤：整段不聚合，逐卡可见（错误卡不藏进折叠行）
      expect(find.text('查证设定 × 6'), findsNothing);
      expect(find.byIcon(Icons.layers_outlined), findsNothing);
    });

    testWidgets('4. 思考块无起止数据回退字数口径', (tester) async {
      await tester.pumpWidget(
        wrap(
          const DirectorWorkGroup(
            timeline: [
              AgentTimelineBlock(
                kind: AgentTimelineKind.thinking,
                stepIndex: 0,
                text: '五个字思考',
              ),
              AgentTimelineBlock(
                kind: AgentTimelineKind.action,
                stepIndex: 0,
                action: AgentWorkStep(toolName: 'search_story'),
              ),
            ],
          ),
        ),
      );
      await tester.tap(find.byIcon(Icons.tungsten_outlined));
      await tester.pumpAndSettle();

      expect(find.text('思考 · 5 字'), findsOneWidget);
    });

    testWidgets('5. 错误动作卡收起态常显 + 标题图标转红', (tester) async {
      final colorsError = <Color>[];
      await tester.pumpWidget(
        wrap(
          const DirectorWorkGroup(
            timeline: [
              AgentTimelineBlock(
                kind: AgentTimelineKind.action,
                stepIndex: 0,
                action: AgentWorkStep(toolName: 'search_story'),
              ),
              AgentTimelineBlock(
                kind: AgentTimelineKind.action,
                stepIndex: 1,
                action: AgentWorkStep(
                  toolName: 'update_facts',
                  callId: 'call-bad',
                  title: '提交失败',
                  output: '错误信息',
                  status: AgentStepStatus.error,
                ),
              ),
            ],
          ),
        ),
      );

      // 收起态：失败卡直接可见，成功卡不可见
      expect(find.text('修订设定集 · 提交失败'), findsOneWidget);
      expect(find.byIcon(Icons.tungsten), findsNothing);

      // 标题图标使用 error 色
      final icon = tester.widget<Icon>(find.byIcon(Icons.tungsten_outlined));
      colorsError.add(icon.color!);
      expect(colorsError.single, isNot(equals(const Color(0xFF9B9990))));
    });
  });

  group('DirectorWorkGroup live 态', () {
    testWidgets('7. 进行中显示"正在动词… · 第 N 步"', (tester) async {
      await tester.pumpWidget(
        wrap(
          const DirectorWorkGroup(
            timeline: [
              AgentTimelineBlock(
                kind: AgentTimelineKind.action,
                stepIndex: 0,
                action: AgentWorkStep(toolName: 'search_story'),
              ),
              AgentTimelineBlock(
                kind: AgentTimelineKind.action,
                stepIndex: 1,
                action: AgentWorkStep(
                  toolName: 'read_story',
                  status: AgentStepStatus.running,
                ),
              ),
            ],
            live: true,
          ),
        ),
      );

      expect(find.text('正在回读原文… · 第 2 步'), findsOneWidget);
    });

    testWidgets('8. 直播中的末思考块默认展开', (tester) async {
      await tester.pumpWidget(
        wrap(
          const DirectorWorkGroup(
            timeline: [
              AgentTimelineBlock(
                kind: AgentTimelineKind.thinking,
                stepIndex: 0,
                text: '正在想…',
              ),
            ],
            live: true,
          ),
        ),
      );

      // live 末块默认展开：内容直接可见
      expect(find.text('正在想…'), findsOneWidget);
    });
  });

  group('DirectorWorkGroup live 态预算进度（G-04+19）', () {
    testWidgets('9. 有预算快照显示「第 N/M 步 · 已用 X:XX」并随 tick 推进', (
      tester,
    ) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await tester.pumpWidget(
        wrap(
          DirectorWorkGroup(
            timeline: const [
              AgentTimelineBlock(
                kind: AgentTimelineKind.action,
                stepIndex: 0,
                action: AgentWorkStep(toolName: 'search_story'),
              ),
              AgentTimelineBlock(
                kind: AgentTimelineKind.action,
                stepIndex: 1,
                action: AgentWorkStep(
                  toolName: 'read_story',
                  status: AgentStepStatus.running,
                ),
              ),
            ],
            live: true,
            progress: AgentRoundProgress(
              currentStep: 2,
              maxSteps: 8,
              startedAtMs: now,
            ),
          ),
        ),
      );

      expect(find.text('第 2/8 步 · 已用 0:00 · 正在回读原文…'), findsOneWidget);

      // fake clock 前进 5 秒：用时随 tick 推进
      await tester.pump(const Duration(seconds: 5));
      expect(find.text('第 2/8 步 · 已用 0:05 · 正在回读原文…'), findsOneWidget);
    });

    testWidgets('10. 无上限档（maxSteps=0）不显示分母', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await tester.pumpWidget(
        wrap(
          DirectorWorkGroup(
            timeline: const [
              AgentTimelineBlock(
                kind: AgentTimelineKind.action,
                stepIndex: 1,
                action: AgentWorkStep(
                  toolName: 'read_story',
                  status: AgentStepStatus.running,
                ),
              ),
            ],
            live: true,
            progress: AgentRoundProgress(
              currentStep: 3,
              maxSteps: 0,
              startedAtMs: now,
            ),
          ),
        ),
      );

      expect(find.text('第 3 步 · 已用 0:00 · 正在回读原文…'), findsOneWidget);
    });

    testWidgets('11. 预算占用 ≥80% 标题文本转警示色', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await tester.pumpWidget(
        wrap(
          DirectorWorkGroup(
            timeline: const [
              AgentTimelineBlock(
                kind: AgentTimelineKind.action,
                stepIndex: 6,
                action: AgentWorkStep(
                  toolName: 'read_story',
                  status: AgentStepStatus.running,
                ),
              ),
            ],
            live: true,
            progress: AgentRoundProgress(
              currentStep: 7,
              maxSteps: 8,
              startedAtMs: now,
            ),
          ),
        ),
      );

      final text = tester.widget<Text>(
        find.text('第 7/8 步 · 已用 0:00 · 正在回读原文…'),
      );
      expect(text.style!.color, const Color(0xFFD4B842));
    });

    testWidgets('12. 收工（live→false）停表且回落历史汇总口径', (tester) async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await tester.pumpWidget(
        wrap(
          DirectorWorkGroup(
            timeline: const [
              AgentTimelineBlock(
                kind: AgentTimelineKind.action,
                stepIndex: 0,
                action: AgentWorkStep(
                  toolName: 'finish_round',
                ),
              ),
            ],
            live: true,
            progress: AgentRoundProgress(
              currentStep: 1,
              maxSteps: 8,
              startedAtMs: now,
            ),
          ),
        ),
      );
      expect(find.text('第 1/8 步 · 已用 0:00 · 正在落幕…'), findsOneWidget);

      // 收工：live→false，标题回落「幕后 N 步 · 思考 M 段 · Xs」
      await tester.pumpWidget(
        wrap(
          DirectorWorkGroup(
            timeline: const [
              AgentTimelineBlock(
                kind: AgentTimelineKind.action,
                stepIndex: 0,
                action: AgentWorkStep(
                  toolName: 'finish_round',
                ),
              ),
            ],
            progress: AgentRoundProgress(
              currentStep: 1,
              maxSteps: 8,
              startedAtMs: now,
            ),
            summary: const AgentWorkSummary(
              steps: 1,
              totalTokens: 100,
              durationMs: 3000,
            ),
          ),
        ),
      );
      expect(find.text('幕后 1 步 · 思考 0 段 · 3s'), findsOneWidget);
    });
  });
}
