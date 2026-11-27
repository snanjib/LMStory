import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_tool_card.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:lmstory/i18n/strings_en_US.g.dart';

/// DirectorToolCard 组件测试（体验重构 ：剧场语言为表、CLI 为里）
///
/// 验证：
/// - 头部 = 舞台动词 + 人话标题（信封 title），无等宽工具名
/// - running 态：spinner + 舞台动词（占位，title 为空）
/// - 展开层：等宽工具名标签 + 参数 + 输出
/// - error 态：红色变体
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

  group('DirectorToolCard 头部语言', () {
    testWidgets('1. done 态：舞台动词 · 人话标题', (tester) async {
      await tester.pumpWidget(
        wrap(
          const DirectorToolCard(
            step: AgentWorkStep(
              toolName: 'search_story',
              title: '「古碑」· 12 处命中',
              output: '共 12 条命中',
            ),
          ),
        ),
      );

      expect(find.text('翻阅前情 · 「古碑」· 12 处命中'), findsOneWidget);
      // 等宽工具名不在头部
      expect(find.text('search_story'), findsNothing);
    });

    testWidgets('2. running 态：舞台动词占位 + spinner', (tester) async {
      await tester.pumpWidget(
        wrap(
          const DirectorToolCard(
            step: AgentWorkStep(
              toolName: 'read_story',
              status: AgentStepStatus.running,
            ),
          ),
        ),
      );

      expect(find.text('回读原文'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('3. 未知工具回落"幕后工作"', (tester) async {
      await tester.pumpWidget(
        wrap(
          const DirectorToolCard(
            step: AgentWorkStep(
              toolName: 'mystery_tool',
              status: AgentStepStatus.running,
            ),
          ),
        ),
      );

      expect(find.text('幕后工作'), findsOneWidget);
    });

    testWidgets('4. 展开层：等宽工具名标签 + 参数 + 输出', (tester) async {
      await tester.pumpWidget(
        wrap(
          const DirectorToolCard(
            step: AgentWorkStep(
              toolName: 'query_facts',
              argsPreview: '{name: 林澈}',
              title: '3 张设定卡',
              output: '共 3 个实体',
              durationMs: 1500,
            ),
          ),
        ),
      );

      // 展开前无等宽内容
      expect(find.text('工具 query_facts'), findsNothing);

      await tester.tap(find.text('查证设定 · 3 张设定卡'));
      await tester.pumpAndSettle();

      expect(find.text('工具 query_facts'), findsOneWidget);
      expect(find.text('{name: 林澈}'), findsOneWidget);
      expect(find.text('共 3 个实体'), findsOneWidget);
      expect(find.text('1.5s'), findsOneWidget);
    });

    testWidgets('5. error 态：失败标题红色变体，可展开看错误', (tester) async {
      await tester.pumpWidget(
        wrap(
          const DirectorToolCard(
            step: AgentWorkStep(
              toolName: 'update_facts',
              title: '提交失败',
              output: '本轮提交失败：数据库锁',
              status: AgentStepStatus.error,
            ),
          ),
        ),
      );

      expect(find.text('修订设定集 · 提交失败'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });

    testWidgets('6. warning 态：可恢复失败用黄色警告图标（DD2）', (tester) async {
      await tester.pumpWidget(
        wrap(
          const DirectorToolCard(
            step: AgentWorkStep(
              toolName: 'finish_round',
              title: '终审提醒：尚无事件记忆',
              output: '请先记录一件事再提交',
              status: AgentStepStatus.warning,
            ),
          ),
        ),
      );

      expect(find.text('落幕 · 终审提醒：尚无事件记忆'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      expect(find.byIcon(Icons.error_outline), findsNothing);
      // 可恢复失败同样可展开核对
      await tester.tap(find.text('落幕 · 终审提醒：尚无事件记忆'));
      await tester.pumpAndSettle();
      expect(find.text('工具 finish_round'), findsOneWidget);
    });

    testWidgets('7. warning 态 JSON 往返（旧数据缺字段回落 done）', (tester) async {
      const warning = AgentWorkStep(
        toolName: 'query_facts',
        title: '未命中',
        status: AgentStepStatus.warning,
      );

      final restored = AgentWorkStep.fromJson(warning.toJson());
      expect(restored.status, AgentStepStatus.warning);
      expect(restored.isWarning, isTrue);
      expect(restored.isSuccess, isFalse);

      expect(
        AgentWorkStep.fromJson({'toolName': 'x', 'status': 'future'}).status,
        AgentStepStatus.done,
      );
    });

    testWidgets('8. 崩溃恢复占位标题与输出映射为统一占位文案', (tester) async {
      await tester.pumpWidget(
        wrap(
          const DirectorToolCard(
            step: AgentWorkStep(
              toolName: 'read_story',
              title: 'Interrupted',
              output: '（应用中断，未执行…）',
              status: AgentStepStatus.error,
            ),
          ),
        ),
      );

      expect(find.text('回读原文 · 中断占位'), findsOneWidget);
      await tester.tap(find.text('回读原文 · 中断占位'));
      await tester.pumpAndSettle();
      expect(
        find.text('（应用中断，此操作是否已执行无法确认；如仍需要请基于当前状态重新判断后再操作）'),
        findsOneWidget,
      );
    });

    test('9. en 语言包下崩溃恢复与中断占位映射为英文占位文案', () {
      final en = TranslationsEnUs();
      expect(
        DirectorToolCard.localizedTitle('中断占位', en),
        'Interrupted',
      );
      expect(
        DirectorToolCard.localizedTitle('占位补齐', en),
        'Interrupted',
      );
      expect(
        DirectorToolCard.localizedTitle('Interrupted', en),
        'Interrupted',
      );
      expect(
        DirectorToolCard.localizedOutput(
          '（应用中断，未执行…）',
          en,
        ),
        '(Application interrupted; whether this operation executed is uncertain. Re-judge from the current state before acting if still needed)',
      );
      expect(
        DirectorToolCard.localizedOutput(
          '（本轮已中断，未执行）',
          en,
        ),
        '(Application interrupted; whether this operation executed is uncertain. Re-judge from the current state before acting if still needed)',
      );
    });

    testWidgets('10. list_facts 与 finish_maintenance 映射专属舞台动词', (tester) async {
      await tester.pumpWidget(
        wrap(
          const Column(
            children: [
              DirectorToolCard(
                step: AgentWorkStep(
                  toolName: 'list_facts',
                  title: '12 条动态实体',
                ),
              ),
              DirectorToolCard(
                step: AgentWorkStep(
                  toolName: 'finish_maintenance',
                ),
              ),
            ],
          ),
        ),
      );

      expect(find.text('浏览设定目录 · 12 条动态实体'), findsOneWidget);
      expect(find.text('完成校准'), findsOneWidget);

      final en = TranslationsEnUs();
      expect(stageVerbOf('list_facts', en), 'Browsing fact catalog');
      expect(stageVerbOf('finish_maintenance', en), 'Completing maintenance');
    });
  });
}
