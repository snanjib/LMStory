import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/facts_change_record.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';

/// StoryRoundArtifacts 实体测试
///
/// 验证 toJson/fromJson 往返、parseDraftKeywords/stringifyDraftKeywords
/// 序列化辅助方法。这些方法用于 intermediate_round_artifacts 表的
/// draft_keywords / retrieved_memories 字段持久化。
void main() {
  group('StoryRoundArtifacts', () {
    group('toJson / fromJson 往返', () {
      test('1. 完整字段往返：所有字段精确匹配', () {
        final original = StoryRoundArtifacts(
          sessionId: 'session-1',
          turnNumber: 3,
          generatedText: '勇者穿过密林，发现古碑。',
          extractedKeywords: const ['密林', '古碑', '探索'],
          retrievedMemories: [
            ExperientialMemory(
              memoryId: 'm1',
              sessionId: 'session-1',
              summary: '过往的探索经历',
              importance: 4,
              tags: const ['探索', '密林'],
              turnNumber: 1,
              createdAt: DateTime(2026),
            ),
            ExperientialMemory(
              memoryId: 'm2',
              sessionId: 'session-1',
              summary: '古碑的传说',
              importance: 5,
              tags: const ['古碑', '传说'],
              turnNumber: 2,
              hasEmbedding: true,
              createdAt: DateTime(2026, 1, 2),
            ),
          ],
          createdAt: DateTime(2026, 7, 4, 12, 30, 45),
        );

        final json = original.toJson();
        final restored = StoryRoundArtifacts.fromJson(json);

        expect(restored.sessionId, original.sessionId);
        expect(restored.turnNumber, original.turnNumber);
        expect(restored.generatedText, original.generatedText);
        expect(restored.extractedKeywords, original.extractedKeywords);
        expect(restored.retrievedMemories.length, 2);

        // 第 1 条记忆：所有字段精确匹配
        expect(restored.retrievedMemories[0].memoryId, 'm1');
        expect(restored.retrievedMemories[0].summary, '过往的探索经历');
        expect(restored.retrievedMemories[0].importance, 4);
        expect(restored.retrievedMemories[0].tags, ['探索', '密林']);
        expect(restored.retrievedMemories[0].turnNumber, 1);
        expect(restored.retrievedMemories[0].hasEmbedding, isFalse);

        // 第 2 条记忆：hasEmbedding=true 保留
        expect(restored.retrievedMemories[1].memoryId, 'm2');
        expect(restored.retrievedMemories[1].hasEmbedding, isTrue);

        // createdAt 经 int 毫秒往返
        expect(
          restored.createdAt.millisecondsSinceEpoch,
          original.createdAt.millisecondsSinceEpoch,
        );
      });

      test('2. draftText=null 往返：nullable 字段正确处理', () {
        final original = StoryRoundArtifacts(
          sessionId: 'session-1',
          turnNumber: 1,
          createdAt: DateTime(2026),
        );

        final restored = StoryRoundArtifacts.fromJson(original.toJson());

        expect(restored.generatedText, isNull);
        expect(restored.extractedKeywords, isEmpty);
        expect(restored.retrievedMemories, isEmpty);
      });

      test('3. 空关键词 + 空记忆列表往返', () {
        final original = StoryRoundArtifacts(
          sessionId: 's',
          turnNumber: 0,
          generatedText: '草稿',
          createdAt: DateTime(2026),
        );

        final restored = StoryRoundArtifacts.fromJson(original.toJson());

        expect(restored.extractedKeywords, isEmpty);
        expect(restored.retrievedMemories, isEmpty);
      });

      test('4. factsChanges 往返：变更记录字段精确匹配', () {
        final original = StoryRoundArtifacts(
          sessionId: 'session-1',
          turnNumber: 5,
          createdAt: DateTime(2026),
          factsChanges: const [
            FactsChangeRecord(
              action: FactAction.createEntity,
              entityType: 'character',
              primaryName: '李逍遥',
              newValue: '李逍遥',
              confidence: 5,
            ),
            FactsChangeRecord(
              action: FactAction.updateAttr,
              attrKey: 'personality',
              oldValue: '开朗',
              newValue: '沉稳',
              reason: '剧情成长',
              confidence: 4,
            ),
          ],
        );

        final restored = StoryRoundArtifacts.fromJson(original.toJson());

        expect(restored.factsChanges.length, 2);
        expect(restored.factsChanges[0].action, FactAction.createEntity);
        expect(restored.factsChanges[0].primaryName, '李逍遥');
        expect(restored.factsChanges[0].newValue, '李逍遥');
        expect(restored.factsChanges[1].action, FactAction.updateAttr);
        expect(restored.factsChanges[1].attrKey, 'personality');
        expect(restored.factsChanges[1].oldValue, '开朗');
        expect(restored.factsChanges[1].newValue, '沉稳');
      });

      test('5. factsChanges 默认空列表往返', () {
        final original = StoryRoundArtifacts(
          sessionId: 's',
          turnNumber: 1,
          createdAt: DateTime(2026),
        );
        final restored = StoryRoundArtifacts.fromJson(original.toJson());
        expect(restored.factsChanges, isEmpty);
      });
    });

    group('读侧终态归一', () {
      test('存量 running 步骤/时间线块反序列化后归一为终态', () {
        // schema 45~48 期间成功轮的 artifacts 带着落库时仍 running 的
        // finish_round 块（collectRound 在工具体内装配时间线）——写侧
        // 归一只堵新数据，读侧（fromJson/DB 行装配）必须兜底归一，
        // 否则历史轮幕后组渲染永久 spinner（重启也不消失）。
        final artifacts = StoryRoundArtifacts.fromJson({
          'sessionId': 'session-1',
          'turnNumber': 7,
          'extractedKeywords': const <String>[],
          'retrievedMemories': const <dynamic>[],
          'createdAt': DateTime(2026).millisecondsSinceEpoch,
          'agentSteps': AgentWorkStep.listToJsonString(const [
            AgentWorkStep(
              toolName: 'finish_round',
              status: AgentStepStatus.running,
              stepIndex: 3,
            ),
          ]),
          'agentTimeline': AgentTimelineBlock.listToJsonString(const [
            AgentTimelineBlock(
              kind: AgentTimelineKind.action,
              stepIndex: 3,
              action: AgentWorkStep(
                toolName: 'finish_round',
                status: AgentStepStatus.running,
                stepIndex: 3,
              ),
            ),
          ]),
        });

        expect(
          artifacts.agentSteps.any((s) => s.isRunning),
          isFalse,
          reason: '存量 running 步骤读出后必须归一（历史轮永久 spinner）',
        );
        expect(
          artifacts.agentTimeline.any((b) => b.action?.isRunning ?? false),
          isFalse,
          reason: '存量 running 时间线块读出后必须归一',
        );
      });
    });

    group('parseDraftKeywords / stringifyDraftKeywords', () {
      test('4. stringifyDraftKeywords：列表 → JSON 字符串', () {
        expect(
          StoryRoundArtifacts.stringifyDraftKeywords(const []),
          '[]',
        );
        expect(
          StoryRoundArtifacts.stringifyDraftKeywords(const ['密林']),
          '["密林"]',
        );
        expect(
          StoryRoundArtifacts.stringifyDraftKeywords(
            const ['密林', '古碑', '探索'],
          ),
          '["密林","古碑","探索"]',
        );
      });

      test('5. parseDraftKeywords：JSON 字符串 → 列表', () {
        expect(
          StoryRoundArtifacts.parseDraftKeywords('[]'),
          isEmpty,
        );
        expect(
          StoryRoundArtifacts.parseDraftKeywords('["密林"]'),
          ['密林'],
        );
        expect(
          StoryRoundArtifacts.parseDraftKeywords(
            '["密林","古碑","探索"]',
          ),
          ['密林', '古碑', '探索'],
        );
      });

      test('6. parseDraftKeywords 空字符串返回空列表（防御性）', () {
        expect(
          StoryRoundArtifacts.parseDraftKeywords(''),
          isEmpty,
        );
      });

      test('7. stringify ↔ parse 往返一致', () {
        const keywords = ['密林', '古碑', '探索', '勇者', '剑'];
        final json = StoryRoundArtifacts.stringifyDraftKeywords(keywords);
        final restored = StoryRoundArtifacts.parseDraftKeywords(json);
        expect(restored, keywords);
      });
    });

    group('parseFactsChanges / stringifyFactsChanges', () {
      test('8. stringify ↔ parse 往返一致', () {
        const changes = [
          FactsChangeRecord(
            action: FactAction.appendList,
            attrKey: 'skills',
            oldValue: '["御剑术"]',
            newValue: '天雷破',
            confidence: 5,
          ),
        ];
        final json = StoryRoundArtifacts.stringifyFactsChanges(changes);
        final restored = StoryRoundArtifacts.parseFactsChanges(json);
        expect(restored.length, 1);
        expect(restored.single.action, FactAction.appendList);
        expect(restored.single.attrKey, 'skills');
        expect(restored.single.oldValue, '["御剑术"]');
        expect(restored.single.newValue, '天雷破');
      });

      test('9. parse null/空字符串/非法 JSON 返回空列表（防御性）', () {
        expect(StoryRoundArtifacts.parseFactsChanges(null), isEmpty);
        expect(StoryRoundArtifacts.parseFactsChanges(''), isEmpty);
        expect(
          StoryRoundArtifacts.parseFactsChanges('not-a-json'),
          isEmpty,
        );
      });
    });

    group('agentWorkSummary（体验重构 A1，schemaVersion 41）', () {
      test('10. agentWorkSummary 往返：字段精确匹配', () {
        final original = StoryRoundArtifacts(
          sessionId: 'session-1',
          turnNumber: 7,
          createdAt: DateTime(2026),
          agentWorkSummary: const AgentWorkSummary(
            steps: 6,
            totalTokens: 12345,
            durationMs: 12400,
          ),
        );

        final restored = StoryRoundArtifacts.fromJson(original.toJson());

        expect(restored.agentWorkSummary, isNotNull);
        expect(restored.agentWorkSummary!.steps, 6);
        expect(restored.agentWorkSummary!.totalTokens, 12345);
        expect(restored.agentWorkSummary!.durationMs, 12400);
      });

      test('11. agentWorkSummary=null 往返（故事模式 / 旧数据）', () {
        final original = StoryRoundArtifacts(
          sessionId: 'session-1',
          turnNumber: 1,
          createdAt: DateTime(2026),
        );

        final restored = StoryRoundArtifacts.fromJson(original.toJson());
        expect(restored.agentWorkSummary, isNull);
      });

      test('12. parseAgentWorkSummary 防御性：null/空/非法 JSON 返回 null', () {
        expect(
          StoryRoundArtifacts.parseAgentWorkSummary(null),
          isNull,
        );
        expect(
          StoryRoundArtifacts.parseAgentWorkSummary(''),
          isNull,
        );
        expect(
          StoryRoundArtifacts.parseAgentWorkSummary('not-a-json'),
          isNull,
        );
        expect(
          StoryRoundArtifacts.parseAgentWorkSummary('["array"]'),
          isNull,
        );
      });

      test('13. agentSteps 带 title 往返（剧场语言标题数据源）', () {
        final original = StoryRoundArtifacts(
          sessionId: 'session-1',
          turnNumber: 2,
          createdAt: DateTime(2026),
          agentSteps: const [
            AgentWorkStep(
              toolName: 'search_story',
              callId: 'call-1',
              argsPreview: '{query: 古碑}',
              title: '「古碑」· 12 处命中',
              output: '共 12 条命中',
              durationMs: 830,
            ),
          ],
        );

        final restored = StoryRoundArtifacts.fromJson(original.toJson());

        expect(restored.agentSteps.length, 1);
        expect(restored.agentSteps.first.toolName, 'search_story');
        expect(restored.agentSteps.first.title, '「古碑」· 12 处命中');
        expect(restored.agentSteps.first.status, AgentStepStatus.done);
        expect(restored.agentSteps.first.durationMs, 830);
      });

      test('14. 旧版 agent_steps JSON（无 title）可正常解析（向后兼容）', () {
        const legacyJson =
            '[{"toolName":"search_story","status":"done","durationMs":100}]';
        final steps = AgentWorkStep.listFromJsonString(legacyJson);

        expect(steps.length, 1);
        expect(steps.first.toolName, 'search_story');
        expect(steps.first.title, isEmpty);
        expect(steps.first.status, AgentStepStatus.done);
      });

      test('15. agentTimeline 往返（对话流 T3，schemaVersion 45）', () {
        final original = StoryRoundArtifacts(
          sessionId: 'session-1',
          turnNumber: 3,
          createdAt: DateTime(2026),
          agentSteps: const [AgentWorkStep(toolName: 'search_story')],
          agentTimeline: const [
            AgentTimelineBlock(
              kind: AgentTimelineKind.thinking,
              stepIndex: 0,
              text: '先查前情',
              startMs: 0,
              endMs: 6000,
            ),
            AgentTimelineBlock(
              kind: AgentTimelineKind.action,
              stepIndex: 0,
              action: AgentWorkStep(toolName: 'search_story'),
            ),
            AgentTimelineBlock(
              kind: AgentTimelineKind.narration,
              stepIndex: 1,
              text: '这轮让她自己出场。',
            ),
          ],
        );

        final restored = StoryRoundArtifacts.fromJson(original.toJson());

        expect(restored.agentTimeline.length, 3);
        expect(restored.agentTimeline.first.kind, AgentTimelineKind.thinking);
        expect(
          restored.agentTimeline.first.duration,
          const Duration(seconds: 6),
        );
        expect(restored.agentTimeline[1].action?.toolName, 'search_story');
        expect(restored.agentTimeline.last.text, '这轮让她自己出场。');
      });

      test('16. agentTimeline 缺省/坏数据回退空列表（旧数据兼容）', () {
        final base = {
          'sessionId': 'session-1',
          'turnNumber': 3,
          'extractedKeywords': <String>[],
          'retrievedMemories': <dynamic>[],
          'createdAt': DateTime(2026).millisecondsSinceEpoch,
        };
        final noTimeline = StoryRoundArtifacts.fromJson(base);
        expect(noTimeline.agentTimeline, isEmpty);

        final badTimeline = StoryRoundArtifacts.fromJson({
          ...base,
          'agentTimeline': 'corrupted',
        });
        expect(badTimeline.agentTimeline, isEmpty);
        expect(badTimeline.agentSteps, isEmpty);
      });
    });
  });
}
