import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_process_row.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// DirectorProcessRow 组件测试（体验重构 ：L1 过程汇总行）
///
/// 验证：
/// - 收起态：剧场语言汇总行（幕后 N 步 · 动词串 · 时长），无等宽工具名
/// - live 态：进行中文案（正在动词… · 第 N 步）
/// - error 步骤收起时常显（不折叠进 L2）
/// - 点击展开：L2 步骤卡可见，等宽工具名只在展开层
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

  const doneSteps = [
    AgentWorkStep(
      toolName: 'search_story',
      title: '「古碑」· 12 处命中',
      output: '共 12 条命中',
      durationMs: 800,
    ),
    AgentWorkStep(
      toolName: 'update_facts',
      title: '2 处修订',
      output: '已暂存 2 条变更',
      durationMs: 120,
    ),
  ];

  group('DirectorProcessRow 收起态（历史轮）', () {
    testWidgets('1. 显示剧场语言汇总：幕后 N 步 · 动词串 · 时长', (tester) async {
      await tester.pumpWidget(
        wrap(
          const DirectorProcessRow(
            steps: doneSteps,
            summary: AgentWorkSummary(
              steps: 2,
              totalTokens: 1000,
              durationMs: 12000,
            ),
          ),
        ),
      );

      expect(find.text('幕后 2 步 · 翻阅前情、修订设定集 · 12s'), findsOneWidget);
      // 等宽工具名不出现在 L1
      expect(find.text('search_story'), findsNothing);
    });

    testWidgets('2. 无 summary 时不显示时长', (tester) async {
      await tester.pumpWidget(wrap(const DirectorProcessRow(steps: doneSteps)));

      expect(find.text('幕后 2 步 · 翻阅前情、修订设定集'), findsOneWidget);
    });

    testWidgets('3. 步骤卡默认收起（成功步骤不可见）', (tester) async {
      await tester.pumpWidget(wrap(const DirectorProcessRow(steps: doneSteps)));

      expect(find.text('翻阅前情 · 「古碑」· 12 处命中'), findsNothing);
    });

    testWidgets('4. 点击展开显示 L2 步骤卡与等宽工具名', (tester) async {
      await tester.pumpWidget(wrap(const DirectorProcessRow(steps: doneSteps)));
      await tester.tap(find.byIcon(Icons.tungsten_outlined));
      await tester.pumpAndSettle();

      expect(find.text('翻阅前情 · 「古碑」· 12 处命中'), findsOneWidget);
      expect(find.text('修订设定集 · 2 处修订'), findsOneWidget);
      // 步骤卡自身的展开层（等宽工具名）需再点击步骤卡头部
      await tester.tap(find.text('翻阅前情 · 「古碑」· 12 处命中'));
      await tester.pumpAndSettle();
      expect(find.text('工具 search_story'), findsOneWidget);
    });

    testWidgets(
      '5. error 步骤收起时常显（不折叠进 L2）',
      (tester) async {
        const stepsWithError = [
          AgentWorkStep(
            toolName: 'search_story',
            title: '「古碑」· 12 处命中',
            output: '共 12 条命中',
          ),
          AgentWorkStep(
            toolName: 'update_facts',
            title: '提交失败',
            output: '错误信息',
            status: AgentStepStatus.error,
          ),
        ];
        await tester.pumpWidget(
          wrap(const DirectorProcessRow(steps: stepsWithError)),
        );

        // 失败步骤直接可见
        expect(find.text('修订设定集 · 提交失败'), findsOneWidget);
      },
    );
  });

  group('DirectorProcessRow live 态', () {
    testWidgets('6. 进行中显示"正在动词… · 第 N 步"', (tester) async {
      const liveSteps = [
        AgentWorkStep(
          toolName: 'search_story',
          title: '「古碑」· 12 处命中',
        ),
        AgentWorkStep(
          toolName: 'read_story',
          status: AgentStepStatus.running,
        ),
      ];
      await tester.pumpWidget(
        wrap(const DirectorProcessRow(steps: liveSteps, live: true)),
      );

      expect(find.text('正在回读原文… · 第 2 步'), findsOneWidget);
    });

    testWidgets('7. 工具间隙（无 running）沿用最后一步动词', (tester) async {
      const liveSteps = [
        AgentWorkStep(
          toolName: 'search_story',
          title: '「古碑」· 12 处命中',
        ),
      ];
      await tester.pumpWidget(
        wrap(const DirectorProcessRow(steps: liveSteps, live: true)),
      );

      expect(find.text('正在翻阅前情…'), findsOneWidget);
    });
  });
}
