import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_live_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/domain/services/agent_log_recovery.dart';
import 'package:lmstory/features/advanced/presentation/utils/director_human_presenter.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/entities/facts_change_record.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/services/fact_context_builder.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/i18n/strings.g.dart';

void main() {
  late Translations zh;
  late Translations en;

  setUpAll(() async {
    zh = await AppLocale.zhCn.build();
    en = await AppLocale.enUs.build();
  });

  final now = DateTime(2026, 11, 27, 23);

  ChatSession makeSession({String? narrativeTime}) => ChatSession(
        sessionId: 'sess-1',
        title: '青崖驿夜雨',
        mode: 'advanced',
        createdAt: now,
        lastActiveAt: now,
        messageCount: 4,
        nextTurn: 3,
        currentNarrativeTime: narrativeTime,
      );

  StoryRoundArtifacts makeArtifacts({
    int turnNumber = 1,
    List<FactsChangeRecord> factsChanges = const [],
    StoryAnchor? storyAnchor,
    EventSummary? eventSummary,
    List<AgentTimelineBlock> agentTimeline = const [],
    List<AgentWorkStep> agentSteps = const [],
    AgentWorkSummary? agentWorkSummary,
    List<RetrievedFact> retrievedFacts = const [],
  }) =>
      StoryRoundArtifacts(
        sessionId: 'sess-1',
        turnNumber: turnNumber,
        createdAt: now,
        factsChanges: factsChanges,
        storyAnchor: storyAnchor,
        eventSummary: eventSummary,
        agentTimeline: agentTimeline,
        agentSteps: agentSteps,
        agentWorkSummary: agentWorkSummary,
        retrievedFacts: retrievedFacts,
      );

  group('DirectorHumanPresenter.presentRound', () {
    test('returns empty pills and empty drawer when 0 changes and no actions',
        () {
      final nullPres = DirectorHumanPresenter.presentRound(
        actNumber: 1,
        artifacts: null,
        t: zh,
      );
      expect(nullPres.visiblePills, isEmpty);
      expect(nullPres.allPills, isEmpty);
      expect(nullPres.overflowCount, 0);
      expect(nullPres.worldChanges, isEmpty);
      expect(nullPres.actions, isEmpty);
      expect(nullPres.hasDrawerContent, isFalse);
      expect(nullPres.headerTitle, '第 1 幕');

      final controlOnly = DirectorHumanPresenter.presentRound(
        actNumber: 2,
        artifacts: makeArtifacts(
          turnNumber: 2,
          agentTimeline: const [
            AgentTimelineBlock(
              kind: AgentTimelineKind.action,
              stepIndex: 0,
              action: AgentWorkStep(
                toolName: 'finish_round',
                callId: 'c-end',
                title: '本轮完成',
              ),
            ),
          ],
        ),
        t: zh,
      );
      expect(controlOnly.visiblePills, isEmpty);
      expect(controlOnly.overflowCount, 0);
      expect(controlOnly.actions, isEmpty);
      expect(controlOnly.hasDrawerContent, isFalse);
    });

    test('orders 1-3 pills by priority without overflow', () {
      final artifacts = makeArtifacts(
        turnNumber: 12,
        factsChanges: const [
          FactsChangeRecord(
            action: FactAction.updateAttr,
            confidence: 5,
            entityId: 'ent_001',
            entityType: 'character',
            primaryName: '陈九',
            attrKey: '伤势',
            oldValue: '轻伤包扎',
            newValue: '左肩旧伤崩裂渗血',
          ),
        ],
        storyAnchor: const StoryAnchor(
          updatedTurn: 12,
          narrativeTime: '暮春雨夜',
          arc: '青崖驿迷局',
          oneLiner: '雨夜入驿发现异样',
          foreshadows: [
            AnchorForeshadow(text: '驿丞举止反常'),
          ],
        ),
        agentTimeline: const [
          AgentTimelineBlock(
            kind: AgentTimelineKind.thinking,
            stepIndex: 0,
            text: '先核对陈九的旧伤。',
            startMs: 0,
            endMs: 4000,
          ),
          AgentTimelineBlock(
            kind: AgentTimelineKind.action,
            stepIndex: 0,
            action: AgentWorkStep(
              toolName: 'query_facts',
              callId: 'c1',
              title: '1 张设定卡',
            ),
          ),
          AgentTimelineBlock(
            kind: AgentTimelineKind.action,
            stepIndex: 1,
            action: AgentWorkStep(
              toolName: 'search_story',
              callId: 'c2',
              title: '「古碑」· 2 处命中',
            ),
          ),
          AgentTimelineBlock(
            kind: AgentTimelineKind.action,
            stepIndex: 2,
            action: AgentWorkStep(
              toolName: 'finish_round',
              callId: 'c3',
              title: '本轮完成',
            ),
          ),
        ],
      );

      final pres = DirectorHumanPresenter.presentRound(
        actNumber: 12,
        artifacts: artifacts,
        t: zh,
      );

      expect(pres.headerTitle, '第 12 幕 · 暮春雨夜');
      expect(pres.visiblePills.length, 3);
      expect(pres.overflowCount, 0);
      expect(
        pres.visiblePills.map((p) => p.kind).toList(),
        [
          DirectorPillKind.factChange,
          DirectorPillKind.foreshadow,
          DirectorPillKind.retrieval,
        ],
      );
      expect(pres.visiblePills[0].label, contains('陈九'));
      expect(pres.visiblePills[1].label, contains('驿丞举止反常'));
      expect(pres.visiblePills[2].label, '已查证 2 处前情');
      expect(pres.hasThinking, isTrue);
      expect(pres.thinkingNotes, '先核对陈九的旧伤。');
      expect(pres.actionsSummaryLine, isNotNull);
      expect(pres.actionsSummaryLine, isNot(contains('query_facts')));
      expect(pres.actionsSummaryLine, isNot(contains('finish_round')));
    });

    test('clips 4-15 changes to 3 visible pills with accurate overflow count',
        () {
      final changes = [
        for (var i = 1; i <= 10; i++)
          FactsChangeRecord(
            action: i <= 2 ? FactAction.createEntity : FactAction.updateAttr,
            confidence: 5,
            entityId: 'ent_$i',
            entityType: 'character',
            primaryName: '角色$i',
            attrKey: 'description',
            oldValue: i <= 2 ? null : '旧设定$i',
            newValue: '新设定$i',
          ),
      ];
      final artifacts = makeArtifacts(
        turnNumber: 50,
        factsChanges: changes,
        storyAnchor: const StoryAnchor(
          updatedTurn: 50,
          foreshadows: [
            AnchorForeshadow(text: '暗门后的脚印'),
            AnchorForeshadow(text: '旧信封已拆封', resolved: true),
          ],
        ),
        agentTimeline: const [
          AgentTimelineBlock(
            kind: AgentTimelineKind.action,
            stepIndex: 0,
            action: AgentWorkStep(
              toolName: 'query_facts',
              callId: 'q1',
              title: '3 张设定卡',
            ),
          ),
          AgentTimelineBlock(
            kind: AgentTimelineKind.action,
            stepIndex: 1,
            action: AgentWorkStep(
              toolName: 'finish_maintenance',
              callId: 'm1',
              title: '周期维护完成',
            ),
          ),
        ],
        agentWorkSummary: const AgentWorkSummary(
          steps: 2,
          totalTokens: 1200,
          durationMs: 3000,
          majorReviewCompleted: true,
        ),
      );

      final pres = DirectorHumanPresenter.presentRound(
        actNumber: 50,
        artifacts: artifacts,
        t: zh,
      );

      // 10 fact pills + 2 foreshadow pills + 1 retrieval pill + 1 maintenance = 14
      expect(pres.allPills.length, 14);
      expect(pres.visiblePills.length, 3);
      expect(pres.overflowCount, 11);
      expect(
        pres.visiblePills.every((p) => p.kind == DirectorPillKind.factChange),
        isTrue,
      );
      expect(
        pres.allPills.last.kind,
        DirectorPillKind.maintenance,
      );
      expect(pres.worldChanges.length, 12);
      expect(pres.hasMajorReview, isTrue);
    });

    test(
        'resolves missing primaryName via lookup, retrievedFacts, and type fallback without leaking entityId',
        () {
      final retrievedEntity = FactualEntity(
        entityId: 'ent_from_retrieval',
        sessionId: 'sess-1',
        type: FactualEntityType.location,
        primaryName: '青崖驿栈',
        aliases: const [],
        importance: 4,
        createdTurn: 1,
        createdAt: now,
      );
      final artifacts = makeArtifacts(
        turnNumber: 4,
        retrievedFacts: [
          RetrievedFact(
            entity: retrievedEntity,
            attributes: const [],
            isKeyEntity: true,
            isKeywordMatched: false,
          ),
        ],
        factsChanges: const [
          FactsChangeRecord(
            action: FactAction.updateAttr,
            confidence: 5,
            entityId: 'ent_mapped_1',
            entityType: 'character',
            attrKey: 'personality',
            oldValue: '沉默寡言',
            newValue: '谨慎多疑',
          ),
          FactsChangeRecord(
            action: FactAction.updateAttr,
            confidence: 5,
            entityId: 'ent_from_retrieval',
            entityType: 'location',
            primaryName: '',
            attrKey: 'description',
            oldValue: '破败木屋',
            newValue: '雨夜亮起灯火',
          ),
          FactsChangeRecord(
            action: FactAction.updateAttr,
            confidence: 4,
            entityId: 'ent_missing_char',
            entityType: 'character',
            attrKey: 'skills',
            oldValue: '["潜行"]',
            newValue: '["潜行","听风"]',
          ),
          FactsChangeRecord(
            action: FactAction.updateAttr,
            confidence: 4,
            entityId: 'ent_missing_unknown',
            attrKey: 'status',
            oldValue: 'unknown',
            newValue: 'active',
          ),
        ],
      );

      final pres = DirectorHumanPresenter.presentRound(
        actNumber: 4,
        artifacts: artifacts,
        entityNames: const {'ent_mapped_1': '沈墨'},
        t: zh,
      );

      expect(pres.worldChanges[0].subject, '沈墨');
      expect(pres.worldChanges[1].subject, '青崖驿栈');
      expect(
        pres.worldChanges[2].subject,
        zh.advanced.worldSheet.entityTypeCharacter,
      );
      expect(pres.worldChanges[2].oldValue, '潜行');
      expect(pres.worldChanges[2].newValue, '潜行、听风');
      expect(pres.worldChanges[3].subject, zh.advanced.actUnit.unknownEntity);

      for (final item in pres.worldChanges) {
        expect(item.subject, isNot(contains('ent_')));
      }
      for (final pill in pres.allPills) {
        expect(pill.label, isNot(contains('ent_')));
      }
    });

    test('sanitizes dirty step titles containing ent_xxx, tool names, and JSON',
        () {
      final artifacts = makeArtifacts(
        turnNumber: 6,
        agentTimeline: const [
          AgentTimelineBlock(
            kind: AgentTimelineKind.action,
            stepIndex: 0,
            action: AgentWorkStep(
              toolName: 'query_facts',
              callId: 'c1',
              title: 'query_facts [ent_001] {"name":"陈九"}',
            ),
          ),
          AgentTimelineBlock(
            kind: AgentTimelineKind.action,
            stepIndex: 0,
            action: AgentWorkStep(
              toolName: 'update_facts',
              callId: 'c2',
              title: 'update_facts (ent_unknown_99) · 修订设定',
            ),
          ),
          AgentTimelineBlock(
            kind: AgentTimelineKind.action,
            stepIndex: 1,
            action: AgentWorkStep(
              toolName: 'calc_eval',
              callId: 'c3',
              title: 'calc · 精确计算',
            ),
          ),
          AgentTimelineBlock(
            kind: AgentTimelineKind.action,
            stepIndex: 1,
            action: AgentWorkStep(
              toolName: 'search_story',
              callId: 'c4',
              title: AgentLogRecoveryService.legacyPlaceholderTitleSynthetic,
            ),
          ),
        ],
      );

      final pres = DirectorHumanPresenter.presentRound(
        actNumber: 6,
        artifacts: artifacts,
        entityNames: const {'ent_001': '陈九'},
        t: zh,
      );

      final summary = pres.actionsSummaryLine ?? '';
      expect(summary, isNot(contains('ent_')));
      expect(summary, isNot(contains('query_facts')));
      expect(summary, isNot(contains('update_facts')));
      expect(summary, isNot(contains('calc ·')));
      expect(summary, isNot(contains('{"name"')));
      expect(summary, contains('陈九'));
      expect(summary, contains('精确计算'));
      expect(summary, contains(zh.advanced.process.interruptedToolPlaceholder));
    });

    test('falls back to legacy agentSteps and preserves error steps untouched',
        () {
      const errorStep = AgentWorkStep(
        toolName: 'query_facts',
        callId: 'err-1',
        argsPreview: '{"entity_id":"ent_001"}',
        title: '批量 ID 超限',
        output: 'raw error output',
        status: AgentStepStatus.error,
      );
      const warningStep = AgentWorkStep(
        toolName: 'update_facts',
        callId: 'warn-1',
        title: '变更全部无效',
        status: AgentStepStatus.warning,
      );
      final artifacts = makeArtifacts(
        turnNumber: 3,
        agentSteps: const [
          AgentWorkStep(
            toolName: 'search_story',
            callId: 'ok-1',
            title: '「古碑」· 4 处命中',
          ),
          AgentWorkStep(
            toolName: 'search_story',
            callId: 'ok-2',
            title: '「古碑」· 4 处命中',
          ),
          warningStep,
          errorStep,
          AgentWorkStep(
            toolName: 'finish_round',
            callId: 'done-1',
            title: '本轮完成',
          ),
        ],
      );

      final pres = DirectorHumanPresenter.presentRound(
        actNumber: 3,
        artifacts: artifacts,
        fallbackThinkingContent: '旧轮次的思考笔记。',
        t: zh,
      );

      expect(pres.isLegacyFallback, isTrue);
      expect(pres.actions.length, 1);
      expect(pres.actions.first.count, 2);
      expect(pres.hasErrors, isTrue);
      expect(pres.errorSteps, [warningStep, errorStep]);
      expect(pres.thinkingNotes, '旧轮次的思考笔记。');
    });

    test('ignores inherited storyAnchor when not updated in current act', () {
      const earlierAnchor = StoryAnchor(
        updatedTurn: 2,
        narrativeTime: '初夏午后',
        arc: '城郊调查',
        foreshadows: [AnchorForeshadow(text: '神秘来信')],
      );
      final artifacts = makeArtifacts(
        turnNumber: 5,
        storyAnchor: earlierAnchor,
      );

      final pres = DirectorHumanPresenter.presentRound(
        actNumber: 5,
        artifacts: artifacts,
        previousAnchor: earlierAnchor,
        t: zh,
      );

      expect(pres.headerTitle, '第 5 幕 · 初夏午后');
      expect(pres.visiblePills, isEmpty);
      expect(pres.worldChanges, isEmpty);
    });
  });

  group('DirectorHumanPresenter.presentLive', () {
    test(
        'produces sanitized Task 1 live pulse and hides finish_round action rows',
        () {
      final state = AdvancedChatState(
        phase: IntermediatePhase.generating,
        messages: const [],
        retryCounts: const {},
        session: makeSession(narrativeTime: '子夜'),
        agentActivity: AgentActivity.tool,
        agentSteps: const [
          AgentWorkStep(
            toolName: 'query_facts',
            callId: 'c1',
            title: 'query_facts [ent_007] 查证角色档案',
            status: AgentStepStatus.running,
          ),
        ],
        agentRoundProgress: const AgentRoundProgress(
          currentStep: 2,
          maxSteps: 8,
          startedAtMs: 1000,
        ),
      );

      final live = DirectorHumanPresenter.presentLive(
        state: state,
        entityNames: const {'ent_007': '林澈'},
        t: zh,
      );

      expect(live.isWorking, isTrue);
      expect(live.inMaintenancePhase, isFalse);
      expect(live.headerTitle, '第 3 幕 · 子夜');
      expect(live.pulseText, contains('林澈'));
      expect(live.pulseText, isNot(contains('query_facts')));
      expect(live.pulseText, isNot(contains('ent_007')));
      expect(live.currentStep, 2);
      expect(live.maxSteps, 8);
    });

    test('produces Task 2 maintenance pulse and splits maintenance actions',
        () {
      const maintError = AgentWorkStep(
        toolName: 'update_facts',
        callId: 'm-err',
        title: '变更全部无效',
        status: AgentStepStatus.error,
      );
      final state = AdvancedChatState(
        phase: IntermediatePhase.generating,
        messages: const [],
        retryCounts: const {},
        session: makeSession(narrativeTime: '次日黎明'),
        inMaintenancePhase: true,
        maintenanceStepStart: 1,
        liveBlocks: const [
          AgentLiveBlock(
            kind: AgentLiveBlockKind.text,
            stepIndex: 0,
            text: '第一段定稿正文内容。',
            source: AgentTextSource.finishRoundProse,
          ),
        ],
        agentSteps: const [
          AgentWorkStep(
            toolName: 'finish_round',
            callId: 't1-end',
            title: '任务一完成 · 进入周期审查',
          ),
          AgentWorkStep(
            toolName: 'list_facts',
            callId: 'm1',
            title: 'list_facts [ent_009] · 事实目录 4/12',
            status: AgentStepStatus.running,
          ),
          maintError,
          AgentWorkStep(
            toolName: 'finish_maintenance',
            callId: 'm-end',
            title: 'finish_maintenance',
            status: AgentStepStatus.running,
          ),
        ],
        agentRoundProgress: const AgentRoundProgress(
          currentStep: 2,
          maxSteps: 4,
          startedAtMs: 1000,
        ),
      );

      final live = DirectorHumanPresenter.presentLive(
        state: state,
        t: zh,
      );

      expect(live.inMaintenancePhase, isTrue);
      expect(live.hasManuscriptProse, isTrue);
      expect(live.pulseText, isNot(contains('list_facts')));
      expect(live.pulseText, isNot(contains('ent_009')));
      expect(live.pulseText, isNot(contains('finish_maintenance')));
      expect(live.pulseText, contains('正文已定稿'));
      expect(live.actions, isEmpty);
      expect(live.maintenanceActions.length, 1);
      expect(live.maintenanceActions.first.verb, zh.advanced.stage.listFacts);
      expect(live.errorSteps, [maintError]);
    });

    test('English locale output contains zero CJK characters', () {
      final artifacts = makeArtifacts(
        factsChanges: const [
          FactsChangeRecord(
            action: FactAction.createEntity,
            confidence: 5,
            entityId: 'ent_en_1',
            entityType: 'character',
            attrKey: 'personality',
            newValue: 'Calm and observant',
          ),
        ],
        storyAnchor: const StoryAnchor(
          updatedTurn: 1,
          narrativeTime: 'Rainy dusk',
          foreshadows: [AnchorForeshadow(text: 'Locked brass key')],
        ),
        agentTimeline: const [
          AgentTimelineBlock(
            kind: AgentTimelineKind.action,
            stepIndex: 0,
            action: AgentWorkStep(
              toolName: 'query_facts',
              callId: 'e1',
              title: 'query_facts [ent_en_1]',
            ),
          ),
        ],
      );

      final pres = DirectorHumanPresenter.presentRound(
        actNumber: 1,
        artifacts: artifacts,
        t: en,
      );

      final cjk = RegExp(r'[\u4e00-\u9fff]');
      expect(cjk.hasMatch(pres.headerTitle), isFalse);
      for (final pill in pres.allPills) {
        expect(cjk.hasMatch(pill.label), isFalse);
        expect(pill.label, isNot(contains('ent_en_1')));
      }
      expect(cjk.hasMatch(pres.actionsSummaryLine ?? ''), isFalse);
    });

    test(
        'consolidates same-entity changes into one pill and handles archive/alias/relationship',
        () {
      final artifacts = makeArtifacts(
        turnNumber: 8,
        factsChanges: const [
          FactsChangeRecord(
            action: FactAction.updateAttr,
            confidence: 5,
            entityId: 'ent_1',
            entityType: 'character',
            primaryName: '陈九',
            attrKey: 'relationship:ent_2',
            oldValue: '陌生',
            newValue: '戒备',
          ),
          FactsChangeRecord(
            action: FactAction.addAlias,
            confidence: 5,
            entityId: 'ent_1',
            entityType: 'character',
            primaryName: '陈九',
            newValue: '九爷',
          ),
          FactsChangeRecord(
            action: FactAction.archiveEntity,
            confidence: 5,
            entityId: 'ent_3',
            entityType: 'item',
            primaryName: '断剑',
            reason: '坠落深涧',
          ),
        ],
      );

      final pres = DirectorHumanPresenter.presentRound(
        actNumber: 8,
        artifacts: artifacts,
        entityNames: const {'ent_2': '沈墨'},
        t: zh,
      );

      expect(pres.visiblePills.length, 2);
      expect(pres.visiblePills[0].label, contains('2 项更新'));
      expect(pres.visiblePills[1].label, contains('归档'));
      expect(pres.worldChanges.length, 3);
      expect(pres.worldChanges[0].attributeLabel, contains('沈墨'));
      expect(pres.worldChanges[0].attributeLabel, isNot(contains('ent_2')));
    });

    test(
        'emits chronicle pill when eventSummary is present without higher tiers',
        () {
      final artifacts = makeArtifacts(
        turnNumber: 2,
        eventSummary: const EventSummary(
          importance: 4,
          tags: ['雨夜'],
          turnNumber: 2,
          what: '雨夜投宿青崖驿',
        ),
        agentTimeline: const [
          AgentTimelineBlock(
            kind: AgentTimelineKind.action,
            stepIndex: 0,
            action: AgentWorkStep(
              toolName: 'record_event_memory',
              callId: 'ev1',
              title: '已记 1 件事',
            ),
          ),
        ],
      );

      final pres = DirectorHumanPresenter.presentRound(
        actNumber: 2,
        artifacts: artifacts,
        t: zh,
      );

      expect(pres.visiblePills.length, 1);
      expect(pres.visiblePills.first.kind, DirectorPillKind.eventMemory);
      expect(pres.worldChanges.length, 1);
      expect(pres.worldChanges.first.newValue, '雨夜投宿青崖驿');
    });

    test('live presentation covers thinking, waitingUser, and saving states',
        () {
      final thinkingState = AdvancedChatState(
        phase: IntermediatePhase.generating,
        messages: const [],
        retryCounts: const {},
        session: makeSession(),
        agentActivity: AgentActivity.thinking,
      );
      expect(
        DirectorHumanPresenter.presentLive(state: thinkingState, t: zh)
            .pulseText,
        zh.advanced.process.thinkingActive,
      );

      final waitingState = thinkingState.copyWith(
        agentAskPrompt: const AgentAskPrompt(
          question: '是否推门？',
          options: ['推门', '观望'],
        ),
      );
      expect(
        DirectorHumanPresenter.presentLive(state: waitingState, t: zh)
            .pulseText,
        zh.advanced.process.waitingUser,
      );

      final savingState = thinkingState.copyWith(
        phase: IntermediatePhase.persisting,
      );
      expect(
        DirectorHumanPresenter.presentLive(state: savingState, t: zh).pulseText,
        zh.advanced.process.savingActive,
      );
    });
  });
}
