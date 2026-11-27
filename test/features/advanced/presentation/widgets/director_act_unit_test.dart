import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_live_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/presentation/utils/director_human_presenter.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_act_unit.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_thinking_block.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_tool_card.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/memory/domain/entities/facts_change_record.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/i18n/strings.g.dart';

void main() {
  late Translations zh;

  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
    zh = await AppLocale.zhCn.build();
  });

  Widget wrap(
    Widget child, {
    ThemeData? theme,
    double textScale = 1.0,
    double width = 390,
  }) {
    return TranslationProvider(
      child: MaterialApp(
        theme: theme ??
            ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 844),
            textScaler: TextScaler.linear(textScale),
          ),
          child: Scaffold(
            body: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [child],
            ),
          ),
        ),
      ),
    );
  }

  final now = DateTime(2026, 11, 27);

  StoryRoundArtifacts sampleArtifacts() => StoryRoundArtifacts(
        sessionId: 's1',
        turnNumber: 4,
        createdAt: now,
        factsChanges: const [
          FactsChangeRecord(
            action: FactAction.updateAttr,
            confidence: 5,
            entityId: 'ent_char_1',
            entityType: 'character',
            primaryName: '沈墨',
            attrKey: '伤势',
            oldValue: '轻伤',
            newValue: '右臂渗血',
          ),
          FactsChangeRecord(
            action: FactAction.createEntity,
            confidence: 5,
            entityId: 'ent_loc_2',
            entityType: 'location',
            primaryName: '青崖驿',
          ),
        ],
        storyAnchor: const StoryAnchor(
          updatedTurn: 4,
          narrativeTime: '雨夜三更',
          arc: '青崖驿迷局',
          oneLiner: '驿站灯灭，暗门开启',
          foreshadows: [
            AnchorForeshadow(text: '铜钥匙的去向'),
            AnchorForeshadow(text: '驿丞的旧伤', resolved: true),
          ],
        ),
        agentTimeline: const [
          AgentTimelineBlock(
            kind: AgentTimelineKind.thinking,
            stepIndex: 0,
            text: '先确认沈墨的伤势记录与铜钥匙线索。',
          ),
          AgentTimelineBlock(
            kind: AgentTimelineKind.action,
            stepIndex: 0,
            action: AgentWorkStep(
              toolName: 'query_facts',
              callId: 'c1',
              title: 'query_facts [ent_char_1] 沈墨 {"attr":"伤势"}',
            ),
          ),
          AgentTimelineBlock(
            kind: AgentTimelineKind.narration,
            stepIndex: 0,
            text: '这幕让铜钥匙的线索浮出水面。',
          ),
          AgentTimelineBlock(
            kind: AgentTimelineKind.action,
            stepIndex: 1,
            action: AgentWorkStep(
              toolName: 'finish_round',
              callId: 'c2',
              title: '本轮完成',
            ),
          ),
        ],
      );

  group('DirectorActHeader', () {
    testWidgets('renders title, status text, and optional top divider', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          const Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DirectorActHeader(
                title: '第 1 幕 · 雨夜',
                statusText: '已落笔 · 2 项变动',
                showTopDivider: false,
              ),
              DirectorActHeader(
                title: '第 2 幕',
                statusText: '已中断',
                isError: true,
              ),
            ],
          ),
        ),
      );

      expect(find.text('第 1 幕 · 雨夜'), findsOneWidget);
      expect(find.text('已落笔 · 2 项变动'), findsOneWidget);
      expect(find.text('第 2 幕'), findsOneWidget);
      expect(find.text('已中断'), findsOneWidget);
    });
  });

  group('DirectorDirectiveBlock', () {
    testWidgets(
        'short directive hides expand toggle and reveals actions on tap',
        (tester) async {
      var copied = false;
      var edited = false;

      await tester.pumpWidget(
        wrap(
          DirectorDirectiveBlock(
            content: '让沈墨推开东侧木门。',
            onCopy: () => copied = true,
            onRegenerate: () {},
            onEdit: () => edited = true,
            onDeleteRound: () {},
          ),
        ),
      );

      expect(find.text('让沈墨推开东侧木门。'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('directive-expand-toggle')),
        findsNothing,
      );
      expect(
        find.byTooltip(zh.intermediate.chat.messageActions.copy),
        findsNothing,
      );

      await tester.tap(find.byKey(const ValueKey('directive-actions-toggle')));
      await tester.pump();

      await tester
          .tap(find.byTooltip(zh.intermediate.chat.messageActions.copy));
      await tester
          .tap(find.byTooltip(zh.intermediate.chat.messageActions.edit));
      expect(copied, isTrue);
      expect(edited, isTrue);
    });

    testWidgets('long directive collapses past 3 lines and toggles cleanly', (
      tester,
    ) async {
      const longInstruction = '第一行：夜雨倾盆，驿站门前的石阶积水。\n'
          '第二行：沈墨按住右肩旧伤，侧耳听屋檐下的动静。\n'
          '第三行：驿丞拎着半熄的油灯从廊道尽头走来。\n'
          '第四行：两人目光交错时，门闩忽然自己落了下去。';

      await tester.pumpWidget(
        wrap(
          DirectorDirectiveBlock(
            content: longInstruction,
            onCopy: () {},
            onRegenerate: () {},
            onEdit: () {},
            onDeleteRound: () {},
          ),
          width: 340,
        ),
      );

      final toggle = find.byKey(const ValueKey('directive-expand-toggle'));
      expect(toggle, findsOneWidget);
      expect(find.text(zh.advanced.actUnit.expandDirective), findsOneWidget);
      expect(tester.getSize(toggle).width, greaterThanOrEqualTo(240));

      await tester.tap(toggle);
      await tester.pump();
      expect(find.text(zh.advanced.actUnit.collapseDirective), findsOneWidget);
    });

    testWidgets('non-interactive block hides action toggle', (tester) async {
      await tester.pumpWidget(
        wrap(
          DirectorDirectiveBlock(
            content: '生成中锁定指示',
            interactive: false,
            onCopy: () {},
            onRegenerate: () {},
            onEdit: () {},
            onDeleteRound: () {},
          ),
        ),
      );

      expect(
        find.byKey(const ValueKey('directive-actions-toggle')),
        findsNothing,
      );
    });
  });

  group('DirectorChangePillsAndDrawer', () {
    testWidgets('occupies zero space when 0 changes and 0 actions', (
      tester,
    ) async {
      final emptyPres = DirectorHumanPresenter.presentRound(
        actNumber: 1,
        artifacts: null,
        t: zh,
      );
      await tester.pumpWidget(
        wrap(DirectorChangePillsAndDrawer(presentation: emptyPres)),
      );
      expect(find.byKey(const ValueKey('act-diff-drawer')), findsNothing);
      expect(find.byKey(const ValueKey('act-pill-overflow')), findsNothing);
    });

    testWidgets(
        'renders max 3 pills + overflow, expands drawer without leaking raw tool names or entity IDs',
        (tester) async {
      final pres = DirectorHumanPresenter.presentRound(
        actNumber: 4,
        artifacts: sampleArtifacts(),
        entityNames: const {'ent_char_1': '沈墨'},
        t: zh,
      );
      var openedMemory = false;
      StoryAnchor? editedAnchor;

      await tester.pumpWidget(
        wrap(
          DirectorChangePillsAndDrawer(
            presentation: pres,
            anchor: sampleArtifacts().storyAnchor,
            onOpenMemory: () => openedMemory = true,
            onEditAnchor: (anchor) => editedAnchor = anchor,
          ),
        ),
      );

      expect(pres.visiblePills.length, 3);
      expect(pres.overflowCount, greaterThan(0));
      expect(
        find.byKey(const ValueKey('act-changes-master-button')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('act-pills-expand-toggle')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('act-diff-drawer')), findsNothing);
      // Hidden overflow pills stay collapsed until the right chevron is tapped
      expect(
        find.byKey(ValueKey('act-pill-${pres.allPills.last.id}')),
        findsNothing,
      );

      // Tap right dropdown chevron to reveal remaining sub-title pills
      await tester.tap(find.byKey(const ValueKey('act-pills-expand-toggle')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('act-pill-${pres.allPills.last.id}')),
        findsOneWidget,
      );

      // Tap a single sub-title pill to show ONLY that specific change
      await tester
          .tap(find.byKey(ValueKey('act-pill-${pres.visiblePills[0].id}')));
      await tester.pumpAndSettle();

      final drawerFinder = find.byKey(const ValueKey('act-diff-drawer'));
      expect(drawerFinder, findsOneWidget);
      expect(
        find.descendant(
          of: drawerFinder,
          matching: find.textContaining('右臂渗血'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: drawerFinder,
          matching: find.textContaining('铜钥匙的去向'),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: drawerFinder,
          matching: find.textContaining('这幕让铜钥匙的线索浮出水面'),
        ),
        findsNothing,
      );

      // Tap master full-width button to expand the complete panel
      await tester.tap(find.byKey(const ValueKey('act-changes-master-button')));
      await tester.pumpAndSettle();

      expect(drawerFinder, findsOneWidget);
      expect(find.text(zh.advanced.actUnit.drawerTitle), findsOneWidget);
      expect(find.textContaining('沈墨'), findsWidgets);
      expect(
        find.descendant(
          of: drawerFinder,
          matching: find.textContaining('右臂渗血'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: drawerFinder,
          matching: find.textContaining('铜钥匙的去向'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: drawerFinder,
          matching: find.textContaining('这幕让铜钥匙的线索浮出水面'),
        ),
        findsOneWidget,
      );

      // Verify zero leaks of raw tool names, entity IDs, or JSON
      final allTexts = tester
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data ?? w.textSpan?.toPlainText() ?? '')
          .join('\n');
      expect(allTexts, isNot(contains('query_facts')));
      expect(allTexts, isNot(contains('finish_round')));
      expect(allTexts, isNot(contains('ent_char_1')));
      expect(allTexts, isNot(contains('{"attr"')));

      // Collapsible thinking notes inside drawer
      expect(find.text('先确认沈墨的伤势记录与铜钥匙线索。'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('act-thinking-toggle')));
      await tester.pump();
      expect(find.text('先确认沈墨的伤势记录与铜钥匙线索。'), findsOneWidget);

      // Memory browser link
      await tester.tap(find.byKey(const ValueKey('act-open-memory')));
      await tester.pump();
      expect(openedMemory, isTrue);

      // Edit anchor link
      await tester.tap(find.byKey(const ValueKey('act-edit-anchor')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('anchor-edit-save')));
      await tester.pumpAndSettle();
      expect(editedAnchor, isNotNull);
    });

    testWidgets('pureReading hides backstage pills, actions, and thinking', (
      tester,
    ) async {
      final pres = DirectorHumanPresenter.presentRound(
        actNumber: 4,
        artifacts: sampleArtifacts(),
        t: zh,
      );

      await tester.pumpWidget(
        wrap(
          DirectorChangePillsAndDrawer(
            presentation: pres,
            anchor: sampleArtifacts().storyAnchor,
            pureReading: true,
            onOpenMemory: () {},
            onEditAnchor: (_) {},
          ),
        ),
      );

      // Retrieval pill hidden in pureReading
      expect(find.byKey(const ValueKey('act-pill-retrieval')), findsNothing);
      await tester
          .tap(find.byKey(ValueKey('act-pill-${pres.visiblePills[0].id}')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('act-diff-drawer')), findsOneWidget);
      expect(find.byKey(const ValueKey('act-edit-anchor')), findsNothing);
      expect(find.byKey(const ValueKey('act-thinking-toggle')), findsNothing);
      expect(find.textContaining('这幕让铜钥匙的线索浮出水面'), findsNothing);
    });
  });

  group('DirectorLivePulse and DirectorMaintenanceSlot', () {
    final session = ChatSession(
      sessionId: 's1',
      title: '青崖驿',
      mode: 'advanced',
      createdAt: now,
      lastActiveAt: now,
      messageCount: 0,
    );

    testWidgets(
        'DirectorLivePulse collapses by default, expands human steps, and keeps DirectorToolCard for errors',
        (tester) async {
      final state = AdvancedChatState(
        phase: IntermediatePhase.reviewing,
        agentActivity: AgentActivity.tool,
        messages: const [],
        retryCounts: const {},
        session: session,
        agentRoundProgress: const AgentRoundProgress(
          currentStep: 2,
          maxSteps: 8,
          startedAtMs: 0,
        ),
        liveBlocks: const [
          AgentLiveBlock(
            kind: AgentLiveBlockKind.thinking,
            stepIndex: 0,
            text: '检查旧档案。',
          ),
          AgentLiveBlock(
            kind: AgentLiveBlockKind.text,
            stepIndex: 0,
            text: '先查一下驿丞的背景。',
          ),
        ],
        agentSteps: const [
          AgentWorkStep(
            toolName: 'search_story',
            callId: 's1',
            title: '「驿丞」· 3 处命中',
          ),
          AgentWorkStep(
            toolName: 'update_facts',
            callId: 'e1',
            title: '字段缺失',
            output: 'missing field',
            status: AgentStepStatus.error,
          ),
        ],
      );
      final livePres = DirectorHumanPresenter.presentLive(
        state: state,
        t: zh,
        actNumber: 1,
      );

      await tester.pumpWidget(
        wrap(
          DirectorLivePulse(
            presentation: livePres,
            timeline: const [
              AgentTimelineBlock(
                kind: AgentTimelineKind.thinking,
                stepIndex: 0,
                text: '检查旧档案。',
              ),
              AgentTimelineBlock(
                kind: AgentTimelineKind.action,
                stepIndex: 0,
                action: AgentWorkStep(
                  toolName: 'search_story',
                  callId: 's1',
                  title: '「驿丞」· 3 处命中',
                ),
              ),
            ],
          ),
        ),
      );

      // Error tool card remains visible verbatim
      expect(find.byType(DirectorToolCard), findsOneWidget);
      expect(find.textContaining('字段缺失'), findsOneWidget);

      // Thinking block hidden until pulse is tapped
      expect(find.byType(DirectorThinkingBlock), findsNothing);
      await tester.tap(find.byKey(const ValueKey('live-pulse-toggle')));
      await tester.pump();
      expect(find.byType(DirectorThinkingBlock), findsOneWidget);
      expect(find.textContaining('「驿丞」· 3 处命中'), findsOneWidget);
    });

    testWidgets('DirectorMaintenanceSlot renders fixed dashed slot and expands',
        (tester) async {
      final state = AdvancedChatState(
        phase: IntermediatePhase.reviewing,
        inMaintenancePhase: true,
        maintenanceStepStart: 1,
        messages: const [],
        retryCounts: const {},
        session: session,
        agentRoundProgress: const AgentRoundProgress(
          currentStep: 9,
          maxSteps: 14,
          startedAtMs: 0,
        ),
        agentSteps: const [
          AgentWorkStep(toolName: 'finish_round', callId: 'f1'),
          AgentWorkStep(
            toolName: 'list_facts',
            callId: 'm1',
            title: '8 条动态实体',
          ),
          AgentWorkStep(
            toolName: 'query_facts',
            callId: 'm2',
            status: AgentStepStatus.running,
          ),
        ],
      );
      final livePres = DirectorHumanPresenter.presentLive(
        state: state,
        t: zh,
        actNumber: 50,
      );

      await tester.pumpWidget(
        wrap(
          DirectorMaintenanceSlot(
            presentation: livePres,
            maintenanceSteps: state.agentSteps.sublist(1),
          ),
        ),
      );

      expect(find.text('9 / 14'), findsOneWidget);
      expect(find.textContaining('8 条动态实体'), findsNothing);

      await tester
          .tap(find.byKey(const ValueKey('maintenance-capsule-toggle')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.textContaining('8 条动态实体'), findsOneWidget);
    });
  });

  group('4 structures x 2 palettes x light/dark at 320dp & 1.3x fontScale', () {
    for (final structure in ThemeCatalog.structures) {
      for (final palette in ThemeCatalog.palettes) {
        for (final brightness in Brightness.values) {
          testWidgets(
              'no overflow or blur: ${structure.id}/${palette.id}/${brightness.name}',
              (tester) async {
            final theme = ThemeCatalog.assemble(
              LmAppearance(structureId: structure.id, paletteId: palette.id),
              brightness,
            );
            final pres = DirectorHumanPresenter.presentRound(
              actNumber: 4,
              artifacts: sampleArtifacts(),
              t: zh,
            );
            final livePres = DirectorHumanPresenter.presentLive(
              state: AdvancedChatState(
                phase: IntermediatePhase.reviewing,
                inMaintenancePhase: true,
                messages: const [],
                retryCounts: const {},
                session: ChatSession(
                  sessionId: 's1',
                  title: '青崖驿',
                  mode: 'advanced',
                  createdAt: now,
                  lastActiveAt: now,
                  messageCount: 0,
                ),
                agentRoundProgress: const AgentRoundProgress(
                  currentStep: 9,
                  maxSteps: 14,
                  startedAtMs: 0,
                ),
              ),
              t: zh,
              actNumber: 5,
            );

            await tester.pumpWidget(
              wrap(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const DirectorActHeader(
                      title: '第 4 幕 · 雨夜三更',
                      statusText: '已落笔 · 4 项变动',
                    ),
                    DirectorDirectiveBlock(
                      content: '第一行指示\n第二行指示\n第三行指示\n第四行指示超过三行',
                      fontScale: 1.3,
                      onCopy: () {},
                      onRegenerate: () {},
                      onEdit: () {},
                      onDeleteRound: () {},
                    ),
                    DirectorChangePillsAndDrawer(
                      presentation: pres,
                      anchor: sampleArtifacts().storyAnchor,
                      onOpenMemory: () {},
                      onEditAnchor: (_) {},
                    ),
                    DirectorLivePulse(
                      presentation: livePres,
                      timeline: const [],
                    ),
                    DirectorMaintenanceSlot(
                      presentation: livePres,
                      maintenanceSteps: const [],
                    ),
                  ],
                ),
                theme: theme,
                textScale: 1.3,
                width: 320,
              ),
            );
            await tester.pump();
            expect(tester.takeException(), isNull);
            expect(find.byType(BackdropFilter), findsNothing);

            // Expand drawer and verify zero overflow under 320dp + 1.3x scale
            await tester.tap(
              find.byKey(ValueKey('act-pill-${pres.visiblePills.first.id}')),
            );
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 300));
            expect(tester.takeException(), isNull);
            expect(find.byType(BackdropFilter), findsNothing);
          });
        }
      }
    }
  });
}
