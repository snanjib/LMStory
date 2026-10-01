import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_llm_gateway.dart';
import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_round_draft.dart';
import 'package:lmstory/features/advanced/domain/entities/retrieval_profile.dart';
import 'package:lmstory/features/advanced/domain/services/agent_session_tools.dart';
import 'package:lmstory/features/advanced/domain/services/agent_story_reader.dart';
import 'package:lmstory/features/advanced/domain/services/agent_style_lint.dart';
import 'package:lmstory/features/advanced/domain/services/agent_subagent.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/features/memory/domain/entities/scored_memory.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';
import 'package:lmstory/features/memory/domain/services/memory_retrieval_exception.dart';

// ── Fakes ────────────────────────────────────────────────────────────

class _FakeFactualRepository implements FactualRepository {
  _FakeFactualRepository({
    this.keyEntities = const [],
    this.entities = const [],
    this.attributes = const [],
  });

  /// 终审闸门 A 的关键实体返回值
  final List<FactualEntity> keyEntities;

  /// 最近一次 getKeyEntities 是否带了注入停用过滤
  bool? lastKeyEntitiesExcludeInjectionDisabled;

  /// 全量实体池（getEntityById / findByName 兜底查询用）
  final List<FactualEntity> entities;

  /// 属性池（getAttributes 按 entityId 过滤返回）
  final List<FactualAttribute> attributes;

  /// searchEntitiesByText 调用记录（可达性兜底断言用）
  final List<List<String>> textSearchCalls = [];

  /// 世界书 FTS 命中池（默认空——auto 实体没有 FTS 行，正是被测场景）
  List<FactualEntity> worldFacts = const [];

  @override
  Future<List<FactualEntity>> searchWorldFacts(
    String sessionId,
    List<String> terms, {
    int limit = 20,
    bool excludeInjectionDisabled = false,
  }) async =>
      worldFacts.take(limit).toList();

  @override
  Future<List<FactualEntity>> searchEntitiesByText(
    String sessionId,
    List<String> terms, {
    int limit = 10,
    bool includeArchived = false,
    bool excludeInjectionDisabled = false,
  }) async {
    textSearchCalls.add(List.of(terms));
    if (terms.isEmpty) return const [];
    return [...keyEntities, ...entities]
        .where((e) {
          if (!includeArchived && e.isArchived) return false;
          final haystack = <String>[
            e.primaryName,
            ...e.aliases,
            ...attributes
                .where((a) => a.entityId == e.entityId)
                .map((a) => a.value),
          ];
          return terms.any((t) => haystack.any((v) => v.contains(t)));
        })
        .take(limit)
        .toList();
  }

  @override
  Future<List<FactualEntity>> getKeyEntities(
    String sessionId,
    int minImportance, {
    bool includeForceInject = false,
    bool excludeInjectionDisabled = false,
  }) async {
    lastKeyEntitiesExcludeInjectionDisabled = excludeInjectionDisabled;
    return keyEntities;
  }

  @override
  Future<List<FactualEntity>> findByName(
    String sessionId,
    List<String> names, {
    bool excludeInjectionDisabled = false,
  }) async =>
      [...keyEntities, ...entities]
          .where(
            (e) =>
                !e.isArchived &&
                (names.contains(e.primaryName) ||
                    e.aliases.any(names.contains)),
          )
          .toList();

  @override
  Future<FactualEntity?> getEntityById(String entityId) async {
    for (final entity in [...keyEntities, ...entities]) {
      if (entity.entityId == entityId) return entity;
    }
    return null;
  }

  @override
  Future<List<FactualEntity>> getEntities(
    String sessionId, {
    bool includeArchived = false,
  }) async =>
      [...keyEntities, ...entities]
          .where((e) => includeArchived || !e.isArchived)
          .toList();

  @override
  Future<List<FactualAttribute>> getAttributes(
    String sessionId,
    List<String> entityIds,
  ) async =>
      attributes.where((a) => entityIds.contains(a.entityId)).toList();

  ///  预检用：按 (entityId, attrKey) 取全部属性行（含基线 + auto 多行）
  @override
  Future<List<FactualAttribute>> getAttributesByKey(
    String entityId,
    String attrKey,
  ) async =>
      attributes
          .where((a) => a.entityId == entityId && a.attrKey == attrKey)
          .toList();

  @override
  Never noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// getKeyEntities 抛异常的 fake（闸门 A fail-open 用例）
class _CrashingFactualRepository implements FactualRepository {
  @override
  Future<List<FactualEntity>> getKeyEntities(
    String sessionId,
    int minImportance, {
    bool includeForceInject = false,
    bool excludeInjectionDisabled = false,
  }) async =>
      throw StateError('db down');

  @override
  Never noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// 仅用于构造 SubagentRunner 的占位 gateway（测试内不被调用）
class _NoopGateway implements AgentLlmGateway {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakeExperienceRepository implements ExperienceRepository {
  _FakeExperienceRepository(
    this.hits, {
    this.substringHits = const [],
    this.searchError,
  });

  final List<ScoredMemory> hits;

  /// 子串兜底命中池（与多通道 hits 分离，便于断言补齐行为）
  final List<ExperientialMemory> substringHits;

  /// 非 null 时多通道检索直接抛出（模拟全通道失败）
  final Exception? searchError;

  /// searchExperiencesBySubstring 调用次数
  int substringCalls = 0;

  // 捕获最近一次检索的 topK / 向量阈值（断言松紧度快照传导）
  int? lastTopK;
  double? lastVectorScoreThreshold;

  @override
  Future<List<ExperientialMemory>> searchExperiencesBySubstring(
    String sessionId,
    List<String> terms, {
    int limit = 5,
    bool includeArchived = false,
  }) async {
    substringCalls++;
    return substringHits.take(limit).toList();
  }

  @override
  Future<List<ScoredMemory>> searchExperiencesMultiChannel({
    required String sessionId,
    required List<String> fts5Queries,
    required List<({String query, dynamic vector})> vectorQueries,
    required int topK,
    required double fts5Weight,
    required double vectorWeight,
    required int keyEventThreshold,
    required double keyEventBoost,
    required double normalizationEpsilon,
    double recencyWeight = 0,
    double importanceWeight = 0,
    int recencyHalfLife = 20,
    double vectorScoreThreshold = 0,
    int? currentTurnNumber,
  }) async {
    lastTopK = topK;
    lastVectorScoreThreshold = vectorScoreThreshold;
    final error = searchError;
    if (error != null) throw error;
    return hits;
  }

  @override
  Never noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakeStoryReader implements AgentStoryReader {
  @override
  Future<int> totalRounds() async => 3;

  @override
  Future<List<AgentStoryRound>> readRounds({
    required int fromTurn,
    required int count,
  }) async =>
      [
        AgentStoryRound(
          turnNumber: fromTurn,
          createdAt: DateTime.now(),
          userText: '第一轮输入',
          narrativeText: '第一轮正文',
          replyText: '第一轮回复',
          eventSummaryText: '发生了什么',
        ),
      ];

  @override
  Never noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakeUserPort implements AgentUserInteractionPort {
  _FakeUserPort(this.answer);

  final String? answer;

  @override
  Future<String?> askUser({required String question, List<String>? options}) =>
      Future.value(answer);
}

AgentToolDeps _deps({
  required AgentRoundDraft draft,
  List<ScoredMemory> searchHits = const [],
  List<ExperientialMemory> substringHits = const [],
  Exception? searchError,
  List<FactualEntity> keyEntities = const [],
  List<FactualEntity> entities = const [],
  List<FactualAttribute> attributes = const [],
  Future<String> Function(AgentRoundDraft)? commit,
  String? askAnswer,
  String Function()? roundUserInput,
  int zeroMemoryRoundStreak = 0,
  StoryAnchor? Function()? currentAnchor,
  int foreshadowCheckInterval = 8,
  Future<Float32List?> Function(String query)? embedQuery,
  RetrievalProfile? retrievalProfile,
}) {
  return AgentToolDeps(
    sessionId: 's1',
    draft: draft,
    factualRepository: _FakeFactualRepository(
      keyEntities: keyEntities,
      entities: entities,
      attributes: attributes,
    ),
    experienceRepository: _FakeExperienceRepository(
      searchHits,
      substringHits: substringHits,
      searchError: searchError,
    ),
    storyReader: _FakeStoryReader(),
    latestMacros: () async => [],
    userInteraction: _FakeUserPort(askAnswer),
    commitRound: commit ?? (d) async => d.explicitReply ?? 'committed',
    roundUserInput: roundUserInput,
    zeroMemoryRoundStreak: zeroMemoryRoundStreak,
    currentAnchor: currentAnchor,
    foreshadowCheckInterval: foreshadowCheckInterval,
    embedQuery: embedQuery,
    retrievalProfile: retrievalProfile,
  );
}

final _invocation = AgentToolInvocation(
  callId: 'c1',
  toolName: 't',
  stepIndex: 0,
  cancellation: AgentCancellationToken(),
);

EventSummary _eventSummary() => const EventSummary(
      importance: 3,
      tags: [],
      turnNumber: 1,
      what: '测试事件',
    );

FactualEntity _entity(
  String primaryName, {
  List<String> aliases = const [],
  bool isArchived = false,
  FactualSource source = FactualSource.auto,
}) =>
    FactualEntity(
      entityId: 'e-$primaryName',
      sessionId: 's1',
      type: FactualEntityType.character,
      primaryName: primaryName,
      aliases: aliases,
      importance: 5,
      createdTurn: 1,
      createdAt: DateTime(2026),
      isArchived: isArchived,
      source: source,
    );

void main() {
  group('UpdateFactsTool', () {
    test('合法 deltas 暂存到草稿', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final tool = UpdateFactsTool(_deps(draft: draft));

      final result = await tool.invoke(_invocation, {
        'deltas': [
          {
            'action': 'create_entity',
            'confidence': 4,
            'primary_name': '苏明远',
            'entity_type': 'character',
            'importance': 4,
          },
          {
            'action': 'update_attr',
            'confidence': 5,
            'entity_id': 'e1',
            'attr_key': '状态',
            'value': '受伤',
          },
        ],
      });

      expect(result.isError, isFalse);
      expect(draft.factsDeltas, hasLength(2));
      expect(draft.factsDeltas.first.primaryName, '苏明远');
      expect(draft.factsDeltas.last.action.name, 'updateAttr');
      // 写工具成功路径登记 calledTools（升级闸门判据，
      // 否则「本轮用过记忆工具」恒假、升级态过度适用）
      expect(draft.calledTools, contains('update_facts'));
    });

    group('D11（R4-P2-4）：暂存补救通道', () {
      test('clear_pending 清空本轮全部暂存（不带 deltas）', () async {
        final draft = AgentRoundDraft(turnNumber: 1);
        final tool = UpdateFactsTool(_deps(draft: draft));
        await tool.invoke(_invocation, {
          'deltas': [
            {
              'action': 'create_entity',
              'confidence': 4,
              'primary_name': '苏明远',
              'entity_type': 'character',
            },
          ],
        });
        expect(draft.factsDeltas, hasLength(1));

        final result = await tool.invoke(_invocation, {
          'clear_pending': true,
        });

        expect(result.isError, isFalse);
        expect(
          draft.factsDeltas,
          isEmpty,
          reason: '暂存被清空，finish_round 不再提交坏 delta',
        );
        expect(result.output, contains('已清空本轮暂存的 1 条变更'));
      });

      test('replace_pending 清空后以本次 deltas 重新暂存（归并保留者重设）', () async {
        final draft = AgentRoundDraft(turnNumber: 1);
        final tool = UpdateFactsTool(_deps(draft: draft));
        await tool.invoke(_invocation, {
          'deltas': [
            {
              'action': 'update_attr',
              'confidence': 4,
              'entity_id': 'e1',
              'attr_key': '状态',
              'value': '错误的旧值',
            },
          ],
        });
        expect(draft.factsDeltas, hasLength(1));

        final result = await tool.invoke(_invocation, {
          'replace_pending': true,
          'deltas': [
            {
              'action': 'update_attr',
              'confidence': 5,
              'entity_id': 'e2',
              'attr_key': '状态',
              'value': '正确的重设值',
            },
          ],
        });

        expect(result.isError, isFalse);
        expect(draft.factsDeltas, hasLength(1), reason: '旧暂存被清空，只剩本次重设');
        expect(draft.factsDeltas.first.entityId, 'e2');
        expect(draft.factsDeltas.first.value, contains('正确的重设值'));
      });

      test('replace_pending 不带 deltas → 仅执行清空并提示', () async {
        final draft = AgentRoundDraft(turnNumber: 1);
        final tool = UpdateFactsTool(_deps(draft: draft));
        await tool.invoke(_invocation, {
          'deltas': [
            {
              'action': 'create_entity',
              'confidence': 4,
              'primary_name': '甲',
              'entity_type': 'character',
            },
          ],
        });

        final result =
            await tool.invoke(_invocation, {'replace_pending': true});

        expect(result.isError, isFalse);
        expect(draft.factsDeltas, isEmpty);
        expect(result.output, contains('仅执行清空'));
      });

      test('PB-1：clear 后重发同批 delta 正常入暂存（幂等计数随清空重置）', () async {
        // replace_pending 语义诱导「重发整批修正内容」：与旧暂存等值的
        // 条目若被幂等计数判「已暂存过」跳过，而 draft 已被清空——
        // 暂存静默丢失且报成功。清空必须连计数一起清。
        final draft = AgentRoundDraft(turnNumber: 1);
        final tool = UpdateFactsTool(_deps(draft: draft));
        final sameDelta = {
          'action': 'update_attr',
          'confidence': 4,
          'entity_id': 'e1',
          'attr_key': '状态',
          'value': '修正后的值',
        };
        await tool.invoke(_invocation, {
          'deltas': [sameDelta],
        });
        expect(draft.factsDeltas, hasLength(1));

        final result = await tool.invoke(_invocation, {
          'replace_pending': true,
          'deltas': [sameDelta],
        });

        expect(result.isError, isFalse);
        expect(
          result.output,
          isNot(contains('重复')),
          reason: '重发同批不是重复命中，是清空后的重新暂存',
        );
        expect(
          draft.factsDeltas,
          hasLength(1),
          reason: '清空后重发的 delta 必须重新入暂存，否则 finish_round 提交为空',
        );
        expect(draft.factsDeltas.first.value, contains('修正后的值'));
      });

      test('RO-6：replace_pending 全拒时失败信封告知旧暂存已被清空', () async {
        final draft = AgentRoundDraft(turnNumber: 1);
        final tool = UpdateFactsTool(_deps(draft: draft));
        await tool.invoke(_invocation, {
          'deltas': [
            {
              'action': 'create_entity',
              'confidence': 4,
              'primary_name': '苏明远',
              'entity_type': 'character',
            },
          ],
        });
        expect(draft.factsDeltas, hasLength(1));

        // 全部无效的 deltas（action 非法）→ 走失败信封
        final result = await tool.invoke(_invocation, {
          'replace_pending': true,
          'deltas': [
            {'action': 'bad_action', 'confidence': 4, 'entity_id': 'e1'},
          ],
        });

        expect(result.isError, isTrue);
        expect(result.output, contains('已先清空此前的 1 条暂存'));
        expect(result.output, contains('当前暂存为空'));
      });

      test('工具描述与 merge 幂等回执含补救通道指引（替换死路指引）', () async {
        final tool =
            UpdateFactsTool(_deps(draft: AgentRoundDraft(turnNumber: 1)));
        expect(tool.description, contains('clear_pending'));
        expect(tool.description, contains('replace_pending'));
      });
    });

    test('create_entity 相似名 → 回执列出候选并建议归并（只提示不自动合并）', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final deps = _deps(draft: draft, entities: [_entity('边境庄园')]);

      final result = await UpdateFactsTool(deps).invoke(_invocation, {
        'deltas': [
          {
            'action': 'create_entity',
            'confidence': 4,
            'primary_name': '庄园',
            'entity_type': 'location',
          },
        ],
      });

      expect(result.isError, isFalse);
      expect(result.output, contains('名称相近'));
      expect(result.output, contains('边境庄园'));
      expect(result.output, contains('merge_entities'));
      expect(result.metadata?['similarHints'], 1);
      // 仍照常暂存新建（不做自动归并）
      expect(draft.factsDeltas, hasLength(1));
    });

    test('非法动作/置信度被拒绝并给出逐条可操作提示', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final tool = UpdateFactsTool(_deps(draft: draft));

      final result = await tool.invoke(_invocation, {
        'deltas': [
          {'action': 'delete_everything', 'confidence': 5},
          {'action': 'create_entity', 'confidence': 0},
        ],
      });

      expect(result.isError, isTrue);
      expect(result.output, contains('六种之一'));
      expect(result.output, contains('第 1 条'));
      expect(result.output, contains('第 2 条'));
      expect(draft.factsDeltas, isEmpty);
    });

    test('弱模型字段别名/数值归一：camelCase + name + 概率/十分制置信度', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final tool = UpdateFactsTool(_deps(draft: draft));

      final result = await tool.invoke(_invocation, {
        'deltas': [
          {
            'action': 'create_entity',
            'confidence': '0.8', // 概率制 → 4
            'primaryName': '苏明远',
            'entityType': 'character',
          },
          {
            'action': 'update', // 简写 → update_attr
            'confidence': 80, // 百分制 → 4
            'name': '荒庙', // 别名 → primary_name
            'attrKey': '状态',
            'value': '坍塌',
          },
        ],
      });

      expect(result.isError, isFalse);
      expect(draft.factsDeltas, hasLength(2));
      expect(draft.factsDeltas.first.confidence, 4);
      expect(draft.factsDeltas.first.primaryName, '苏明远');
      expect(draft.factsDeltas.first.entityType, 'character');
      expect(draft.factsDeltas.last.action, FactAction.updateAttr);
      expect(draft.factsDeltas.last.primaryName, '荒庙');
      expect(draft.factsDeltas.last.attrKey, '状态');
      expect(draft.factsDeltas.last.confidence, 4);
    });

    test('部分无效时逐条说明原因，有效条目照常暂存', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final tool = UpdateFactsTool(_deps(draft: draft));

      final result = await tool.invoke(_invocation, {
        'deltas': [
          {
            'action': 'create_entity',
            'confidence': 3,
            'primary_name': '苏明远',
          },
          {'action': 'update_attr', 'confidence': 3}, // 缺定位字段
        ],
      });

      expect(result.isError, isFalse);
      expect(draft.factsDeltas, hasLength(1));
      expect(result.output, contains('1 条无效被忽略'));
      expect(result.output, contains('第 2 条：entity_id 与 primary_name'));
    });

    test('deltas 或单条被序列化成 JSON 字符串也能解析', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final tool = UpdateFactsTool(_deps(draft: draft));

      final result = await tool.invoke(_invocation, {
        // 整个数组被弱模型序列化成字符串
        'deltas': jsonEncode([
          {
            'action': 'create_entity',
            'confidence': 4,
            'primary_name': '林玉',
          },
        ]),
      });
      expect(result.isError, isFalse);
      expect(draft.factsDeltas, hasLength(1));
      expect(draft.factsDeltas.first.primaryName, '林玉');

      final result2 = await tool.invoke(_invocation, {
        'deltas': [
          // 单条被序列化成字符串
          jsonEncode({
            'action': 'add_alias',
            'confidence': 4,
            'entity_id': 'e1',
            'value': '小林',
          }),
        ],
      });
      expect(result2.isError, isFalse);
      expect(draft.factsDeltas, hasLength(2));
      expect(draft.factsDeltas.last.action, FactAction.addAlias);
    });

    test('超过 8 条被拒绝（分批提示）', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final tool = UpdateFactsTool(_deps(draft: draft));

      final result = await tool.invoke(_invocation, {
        'deltas': List.generate(
          9,
          (i) => {
            'action': 'add_alias',
            'confidence': 3,
            'entity_id': 'e$i',
            'value': '别名$i',
          },
        ),
      });

      expect(result.isError, isTrue);
      expect(result.output, contains('分批'));
    });

    group('M3 导入实体暂存期预检（与 FactApplier 提交期守卫同口径）', () {
      FactualAttribute attr(
        String entityId,
        String key,
        String value, {
        AttributeValueType type = AttributeValueType.single,
        FactualSource source = FactualSource.auto,
      }) =>
          FactualAttribute(
            attributeId: 'a-$entityId-$key-${source.name}',
            entityId: entityId,
            sessionId: 's1',
            attrKey: key,
            value: value,
            importance: 3,
            valueType: type,
            source: source,
            createdAt: DateTime(2026),
          );

      test('导入实体 update_attr 主名 → 照常暂存，回执提示提交时转别名', () async {
        final draft = AgentRoundDraft(turnNumber: 2);
        final tool = UpdateFactsTool(
          _deps(
            draft: draft,
            entities: [_entity('雾隐剑客', source: FactualSource.worldbook)],
          ),
        );

        final result = await tool.invoke(_invocation, {
          'deltas': [
            {
              'action': 'update_attr',
              'confidence': 4,
              'entity_id': 'e-雾隐剑客',
              'attr_key': 'name',
              'value': '白袍客',
            },
          ],
        });

        expect(result.isError, isFalse);
        // 不拒：delta 照常进暂存
        expect(draft.factsDeltas, hasLength(1));
        expect(draft.factsDeltas.first.action, FactAction.updateAttr);
        // 接受回执追加主名转换提示行（非 rejected）
        expect(result.output, contains('第 1 条'));
        expect(result.output, contains('导入实体主名不可改'));
        expect(result.output, contains('将以别名记录'));
        expect(result.metadata?['rejected'], 0);
      });

      test('导入实体基线 remove_from_list（无 auto 行）→ 拒绝且不进暂存', () async {
        final draft = AgentRoundDraft(turnNumber: 2);
        final tool = UpdateFactsTool(
          _deps(
            draft: draft,
            entities: [_entity('雾隐剑客', source: FactualSource.card)],
            attributes: [
              // 该键只有 card 只读基线行（无 auto 演变行）
              attr(
                'e-雾隐剑客',
                'skills',
                '["剑术"]',
                type: AttributeValueType.list,
                source: FactualSource.card,
              ),
            ],
          ),
        );

        // 按 primary_name 定位（预检的按名兜底通道）
        final result = await tool.invoke(_invocation, {
          'deltas': [
            {
              'action': 'remove_from_list',
              'confidence': 4,
              'primary_name': '雾隐剑客',
              'attr_key': 'skills',
              'value': '剑术',
            },
          ],
        });

        // 单条被拒 → 失败信封逐条说明（既有 rejected 通道）
        expect(result.isError, isTrue);
        expect(result.output, contains('第 1 条'));
        expect(result.output, contains('雾隐剑客'));
        expect(result.output, contains('skills'));
        expect(result.output, contains('为导入基线，不可移除'));
        expect(draft.factsDeltas, isEmpty, reason: '被拒 delta 不得进暂存');
      });

      test('auto 实体 update 主名 / remove_from_list 不受预检影响', () async {
        final draft = AgentRoundDraft(turnNumber: 2);
        final tool = UpdateFactsTool(
          _deps(draft: draft, entities: [_entity('苏明远')]),
        );

        final result = await tool.invoke(_invocation, {
          'deltas': [
            {
              'action': 'update_attr',
              'confidence': 4,
              'entity_id': 'e-苏明远',
              'attr_key': 'name',
              'value': '明远',
            },
            {
              'action': 'remove_from_list',
              'confidence': 4,
              'entity_id': 'e-苏明远',
              'attr_key': 'skills',
              'value': '剑术',
            },
          ],
        });

        expect(result.isError, isFalse);
        expect(draft.factsDeltas, hasLength(2), reason: 'auto 实体走原有行为');
        expect(result.output, isNot(contains('将以别名记录')));
        expect(result.output, isNot(contains('不可移除')));
        expect(result.metadata?['rejected'], 0);
      });

      test('导入实体 remove_from_list 但该键有 auto 演变行 → 放行（演变行可删）', () async {
        final draft = AgentRoundDraft(turnNumber: 2);
        final tool = UpdateFactsTool(
          _deps(
            draft: draft,
            entities: [_entity('雾隐剑客', source: FactualSource.worldbook)],
            attributes: [
              // 基线行 + auto 演变行并存：有 auto 行即不拒
              attr(
                'e-雾隐剑客',
                'skills',
                '["剑术"]',
                type: AttributeValueType.list,
                source: FactualSource.worldbook,
              ),
              attr(
                'e-雾隐剑客',
                'skills',
                '["剑术","双刀"]',
                type: AttributeValueType.list,
              ),
            ],
          ),
        );

        final result = await tool.invoke(_invocation, {
          'deltas': [
            {
              'action': 'remove_from_list',
              'confidence': 4,
              'entity_id': 'e-雾隐剑客',
              'attr_key': 'skills',
              'value': '双刀',
            },
          ],
        });

        expect(result.isError, isFalse);
        expect(draft.factsDeltas, hasLength(1));
        expect(result.output, isNot(contains('不可移除')));
        expect(result.metadata?['rejected'], 0);
      });
    });

    group('B7-3 幂等回执（同参重复暂存）', () {
      test('同参重复：回执第 N 次、不重复 add、不耗 8 条配额', () async {
        final draft = AgentRoundDraft(turnNumber: 1);
        final tool = UpdateFactsTool(_deps(draft: draft));
        final args = {
          'deltas': [
            {
              'action': 'update_attr',
              'confidence': 4,
              'entity_id': 'e1',
              'attr_key': '状态',
              'value': '受伤',
            },
          ],
        };

        await tool.invoke(_invocation, args);
        final second = await tool.invoke(_invocation, args);
        final third = await tool.invoke(_invocation, args);

        expect(second.isError, isFalse);
        expect(second.output, contains('已暂存过（第 2 次）'));
        expect(second.output, contains('自动去重'));
        expect(third.output, contains('已暂存过（第 3 次）'));
        // 只暂存一份，重复不再 add
        expect(draft.factsDeltas, hasLength(1));
        expect(second.metadata?['duplicates'], 1);
        expect(second.metadata?['accepted'], 0);
      });

      test('重复与新条目混在同一次调用：新条目照常暂存', () async {
        final draft = AgentRoundDraft(turnNumber: 1);
        final tool = UpdateFactsTool(_deps(draft: draft));
        final first = {
          'action': 'add_alias',
          'confidence': 4,
          'entity_id': 'e1',
          'value': '小林',
        };

        await tool.invoke(_invocation, {
          'deltas': [first],
        });
        final result = await tool.invoke(_invocation, {
          'deltas': [
            first, // 重复
            {
              'action': 'add_alias',
              'confidence': 4,
              'entity_id': 'e2',
              'value': '老林',
            }, // 新条目
          ],
        });

        expect(result.isError, isFalse);
        expect(draft.factsDeltas, hasLength(2));
        expect(result.output, contains('1 条重复被跳过'));
        expect(result.metadata?['duplicates'], 1);
        expect(result.metadata?['accepted'], 1);
      });

      test('reason 等字段不同 → 非重复，照常暂存（等值口径含全部字段）', () async {
        final draft = AgentRoundDraft(turnNumber: 1);
        final tool = UpdateFactsTool(_deps(draft: draft));

        await tool.invoke(_invocation, {
          'deltas': [
            {
              'action': 'update_attr',
              'confidence': 4,
              'entity_id': 'e1',
              'attr_key': '状态',
              'value': '受伤',
              'reason': '第一幕受伤',
            },
          ],
        });
        final result = await tool.invoke(_invocation, {
          'deltas': [
            {
              'action': 'update_attr',
              'confidence': 4,
              'entity_id': 'e1',
              'attr_key': '状态',
              'value': '受伤',
              'reason': '伤情确认',
            },
          ],
        });

        expect(result.isError, isFalse);
        expect(draft.factsDeltas, hasLength(2), reason: 'reason 不同即非等值');
      });

      test('全部为重复 → 成功回执（重复不是错误）', () async {
        final draft = AgentRoundDraft(turnNumber: 1);
        final tool = UpdateFactsTool(_deps(draft: draft));
        final args = {
          'deltas': [
            {
              'action': 'archive_entity',
              'confidence': 3,
              'entity_id': 'e9',
            },
          ],
        };

        await tool.invoke(_invocation, args);
        final second = await tool.invoke(_invocation, args);

        expect(second.isError, isFalse, reason: '幂等命中不是失败');
        expect(second.title, contains('重复'));
        expect(second.output, contains('未新增变更'));
      });
    });

    test('schema 携带属性初始化指引（防裸实体回归，移植自故事模式 extract_facts）', () {
      final tool =
          UpdateFactsTool(_deps(draft: AgentRoundDraft(turnNumber: 1)));
      final schema = tool.buildParametersSchema();
      final props = schema['properties'] as Map<String, dynamic>;
      final deltas = props['deltas'] as Map<String, dynamic>;
      final items = deltas['items'] as Map<String, dynamic>;
      final itemProps = items['properties'] as Map<String, dynamic>;

      final attrKey = itemProps['attr_key'] as Map<String, dynamic>;
      expect(attrKey['description'], contains('create_entity'));
      expect(attrKey['description'], contains('location'));
      expect(attrKey['description'], contains('character'));

      final value = itemProps['value'] as Map<String, dynamic>;
      expect(value['description'], isNotNull);

      expect(tool.description, contains('attr_key'));
    });
  });

  group('MergeEntitiesTool', () {
    FactualEntity entityAt(
      String id,
      String name, {
      List<String> aliases = const [],
      FactualSource source = FactualSource.auto,
      bool archived = false,
    }) =>
        FactualEntity(
          entityId: id,
          sessionId: 's1',
          type: FactualEntityType.location,
          primaryName: name,
          aliases: aliases,
          importance: 3,
          createdTurn: 1,
          createdAt: DateTime(2026),
          source: source,
          isArchived: archived,
        );

    FactualAttribute attr(
      String entityId,
      String key,
      String value, {
      AttributeValueType type = AttributeValueType.single,
    }) =>
        FactualAttribute(
          attributeId: 'a-$entityId-$key',
          entityId: entityId,
          sessionId: 's1',
          attrKey: key,
          value: value,
          importance: 2,
          valueType: type,
          createdAt: DateTime(2026),
        );

    test('归并暂存：别名去重并入 + 缺失属性搬迁 + 同键冲突不搬 + 源归档', () async {
      final draft = AgentRoundDraft(turnNumber: 2);
      final tool = MergeEntitiesTool(
        _deps(
          draft: draft,
          entities: [
            entityAt('e-source', '庄园', aliases: ['老宅']),
            entityAt('e-target', '边境庄园'),
          ],
          attributes: [
            // 冲突键：两侧都有 description → 不搬迁，列入冲突
            attr('e-target', 'description', '边境的庄园'),
            attr('e-source', 'description', '老庄园'),
            // 目标缺失的 list 键 → 整体搬迁为逐条 append_list
            attr(
              'e-source',
              'features',
              '["护城河","瞭望塔"]',
              type: AttributeValueType.list,
            ),
          ],
        ),
      );

      final result = await tool.invoke(_invocation, {
        'source_entity_id': 'e-source',
        'target_entity_id': 'e-target',
        'reason': '同一实体',
      });

      expect(result.isError, isFalse);
      // 别名 2 条（老宅 + 源主名庄园）→ list 搬迁 2 条 → 归档收尾；
      // description 冲突不搬迁，因此全程没有 update_attr
      expect(draft.factsDeltas.map((d) => d.action).toList(), [
        FactAction.addAlias,
        FactAction.addAlias,
        FactAction.appendList,
        FactAction.appendList,
        FactAction.archiveEntity,
      ]);
      expect(draft.factsDeltas.last.entityId, 'e-source');

      final aliasDelta = draft.factsDeltas.first;
      expect(aliasDelta.value, '庄园');
      expect(draft.factsDeltas[1].value, '老宅');

      final movedLists = draft.factsDeltas
          .where((d) => d.action == FactAction.appendList)
          .toList();
      expect(movedLists.map((d) => d.value), ['护城河', '瞭望塔']);
      expect(
        draft.factsDeltas.map((d) => d.attrKey),
        isNot(contains('description')),
      );
      expect(result.output, contains('冲突'));
      expect(result.output, contains('老庄园'));
      expect(draft.calledTools, contains('merge_entities'));
    });

    test('同键 list 补差集：重复项跳过、新项追加', () async {
      final draft = AgentRoundDraft(turnNumber: 2);
      final tool = MergeEntitiesTool(
        _deps(
          draft: draft,
          entities: [
            entityAt('e-a', '甲庄'),
            entityAt('e-b', '乙庄'),
          ],
          attributes: [
            attr('e-b', 'features', '["护城河"]', type: AttributeValueType.list),
            attr(
              'e-a',
              'features',
              '["护城河","铁门"]',
              type: AttributeValueType.list,
            ),
          ],
        ),
      );

      await tool.invoke(_invocation, {
        'source_entity_id': 'e-a',
        'target_entity_id': 'e-b',
      });

      final appended =
          draft.factsDeltas.where((d) => d.action == FactAction.appendList);
      expect(appended.map((d) => d.value), ['铁门']);
    });

    test('暂存 deltas 全部标记 isCuration（豁免演化守卫，DN-X1）', () async {
      final draft = AgentRoundDraft(turnNumber: 2);
      final tool = MergeEntitiesTool(
        _deps(
          draft: draft,
          entities: [
            entityAt('e-source', '庄园', aliases: ['老宅']),
            entityAt('e-target', '边境庄园'),
          ],
          attributes: [
            attr('e-source', 'description', '老庄园'),
          ],
        ),
      );

      await tool.invoke(_invocation, {
        'source_entity_id': 'e-source',
        'target_entity_id': 'e-target',
      });

      expect(draft.factsDeltas, isNotEmpty);
      expect(
        draft.factsDeltas.every((d) => d.isCuration),
        isTrue,
        reason: '归并搬移经 finish_round 应用时须豁免频率/置信度/白名单守卫，否则部分归并静默丢数据',
      );
    });

    test('已归档 target 拒绝：搬进归档实体的知识等于蒸发', () async {
      final draft = AgentRoundDraft(turnNumber: 2);
      final tool = MergeEntitiesTool(
        _deps(
          draft: draft,
          entities: [
            entityAt('e-source', '庄园'),
            entityAt('e-target', '边境庄园', archived: true),
          ],
        ),
      );

      final result = await tool.invoke(_invocation, {
        'source_entity_id': 'e-source',
        'target_entity_id': 'e-target',
      });

      expect(result.isError, isTrue);
      expect(result.output, contains('归档'));
      expect(draft.factsDeltas, isEmpty);
    });

    test('已归档 source 拒绝：无需归并', () async {
      final draft = AgentRoundDraft(turnNumber: 2);
      final tool = MergeEntitiesTool(
        _deps(
          draft: draft,
          entities: [
            entityAt('e-source', '庄园', archived: true),
            entityAt('e-target', '边境庄园'),
          ],
        ),
      );

      final result = await tool.invoke(_invocation, {
        'source_entity_id': 'e-source',
        'target_entity_id': 'e-target',
      });

      expect(result.isError, isTrue);
      expect(result.output, contains('归档'));
      expect(draft.factsDeltas, isEmpty);
    });

    test('世界书实体拒绝归并', () async {
      final draft = AgentRoundDraft(turnNumber: 2);
      final tool = MergeEntitiesTool(
        _deps(
          draft: draft,
          entities: [
            entityAt(
              'e-wb',
              '设定庄园',
              source: FactualSource.worldbook,
            ),
            entityAt('e-auto', '自动庄园'),
          ],
        ),
      );

      final result = await tool.invoke(_invocation, {
        'source_entity_id': 'e-wb',
        'target_entity_id': 'e-auto',
      });

      expect(result.isError, isTrue);
      expect(draft.factsDeltas, isEmpty);
    });

    test('card 守卫双入口统一（WA-X4/DN-X3）：card 不可被吸收、可作保留者', () async {
      final draft = AgentRoundDraft(turnNumber: 2);

      // card 作 source → 拒绝（只读基线不可被吸收归档）
      final rejectCardSource = await MergeEntitiesTool(
        _deps(
          draft: draft,
          entities: [
            entityAt('e-card', '卡庄园', source: FactualSource.card),
            entityAt('e-auto', 'AI 复建庄园'),
          ],
        ),
      ).invoke(_invocation, {
        'source_entity_id': 'e-card',
        'target_entity_id': 'e-auto',
      });
      expect(rejectCardSource.isError, isTrue);
      expect(draft.factsDeltas, isEmpty);

      // card 作 target → 放行（实体本身可演化；工具不改其主名/重要度）
      final allowCardTarget = await MergeEntitiesTool(
        _deps(
          draft: draft,
          entities: [
            entityAt('e-auto2', 'AI 复建庄园2'),
            entityAt('e-card2', '卡庄园2', source: FactualSource.card),
          ],
          attributes: [
            attr('e-auto2', 'description', 'AI 建的重复描述'),
          ],
        ),
      ).invoke(_invocation, {
        'source_entity_id': 'e-auto2',
        'target_entity_id': 'e-card2',
        'reason': '同一实体',
      });
      expect(allowCardTarget.isError, isFalse);
      expect(draft.factsDeltas, isNotEmpty);
    });

    test('同一实体 / 找不到实体均失败且不暂存', () async {
      final draft = AgentRoundDraft(turnNumber: 2);
      final tool = MergeEntitiesTool(
        _deps(
          draft: draft,
          entities: [entityAt('e-x', '孤庄')],
        ),
      );

      final same = await tool.invoke(_invocation, {
        'source_entity_id': 'e-x',
        'target_entity_id': 'e-x',
      });
      final missing = await tool.invoke(_invocation, {
        'source_name': '不存在',
        'target_name': '也没有',
      });

      expect(same.isError, isTrue);
      expect(missing.isError, isTrue);
      expect(draft.factsDeltas, isEmpty);
    });

    test('审查收官 R4-P1-1：归并超限失败不污染计数——补救后的合法归并照常暂存', () async {
      final draft = AgentRoundDraft(turnNumber: 2);
      // 后别名并入封顶 kMaxAliasesPerEntity(10)，超限
      // 改由属性搬迁制造：45 个 list 项 + 10 个别名 > _maxStagedDeltas(50)
      final manyAliases = [for (var i = 0; i < 60; i++) '废庄$i'];
      final manyAttrs = [
        for (var i = 0; i < 45; i++)
          FactualAttribute(
            attributeId: 'attr_ovf$i',
            entityId: 'e-source',
            sessionId: 'session-1',
            attrKey: 'alias_test_slot_$i',
            value: '值$i',
            importance: 3,
            createdAt: DateTime(2026),
          ),
      ];
      final tool = MergeEntitiesTool(
        _deps(
          draft: draft,
          entities: [
            entityAt('e-source', '庄园', aliases: manyAliases),
            entityAt('e-target', '边境庄园'),
          ],
          attributes: manyAttrs,
        ),
      );
      final args = {
        'source_entity_id': 'e-source',
        'target_entity_id': 'e-target',
        'reason': '同一实体',
      };

      // 第一次：超限失败（未暂存任何 delta）
      final overflow = await tool.invoke(_invocation, args);
      expect(overflow.isError, isTrue);
      expect(overflow.title, '归并项过多');
      expect(draft.factsDeltas, isEmpty);

      // 模型按指引用 update_facts 分批手工合并（此处直接清空重试归并语义）
      // 第二次：合法重试不被误报「已暂存过」——修复前计数已被污染
      final second = await tool.invoke(_invocation, args);
      expect(second.isError, isTrue, reason: '仍超限（别名没变），但失败原因应是超限而非幂等命中');
      expect(second.title, '归并项过多', reason: '不是「归并已暂存过」假回执');
    });

    test('B7-3 幂等回执：同参重复归并不再生成第二批 deltas', () async {
      final draft = AgentRoundDraft(turnNumber: 2);
      final tool = MergeEntitiesTool(
        _deps(
          draft: draft,
          entities: [
            entityAt('e-source', '庄园', aliases: ['老宅']),
            entityAt('e-target', '边境庄园'),
          ],
        ),
      );
      final args = {
        'source_entity_id': 'e-source',
        'target_entity_id': 'e-target',
        'reason': '同一实体',
      };

      final first = await tool.invoke(_invocation, args);
      final countAfterFirst = draft.factsDeltas.length;
      expect(first.isError, isFalse);
      expect(countAfterFirst, greaterThan(0));

      final second = await tool.invoke(_invocation, args);

      expect(second.isError, isFalse);
      expect(second.title, contains('已暂存过'));
      expect(second.output, contains('第 2 次请求'));
      expect(second.output, contains('自动去重'));
      // 死路指引替换为补救通道——指引 replace_pending 重设
      expect(second.output, contains('replace_pending'));
      // 未重复暂存（delta 数与首次归并后一致）
      expect(draft.factsDeltas, hasLength(countAfterFirst));
      expect(second.metadata?['duplicateStaging'], 1);
    });

    // merge 幂等计数挂在 draft 上，
    // update_facts 的 clear_pending/replace_pending 清空暂存时必须连它
    // 一起清——merge 回执正是指引模型「用 replace_pending 重设」的，若
    // 计数残留，清空后对同一 source 的合法重归并被误报「已暂存过」，
    // 归并意图静默丢失（的姊妹面）。
    test('DK12-1：clear_pending 后重归并同一 source 正常入暂存（计数随清空重置）', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final deps = _deps(
        draft: draft,
        entities: [
          entityAt('e-source', '庄园'),
          entityAt('e-target', '边境庄园'),
        ],
      );
      final mergeTool = MergeEntitiesTool(deps);
      final updateTool = UpdateFactsTool(deps);
      final mergeArgs = {
        'source_entity_id': 'e-source',
        'target_entity_id': 'e-target',
        'reason': '同一实体',
      };

      final first = await mergeTool.invoke(_invocation, mergeArgs);
      expect(first.isError, isFalse);
      expect(first.title, isNot(contains('已暂存过')));
      final countAfterFirst = draft.factsDeltas.length;
      expect(countAfterFirst, greaterThan(0));

      // 模型按 merge 回执指引走补救通道：清空本轮暂存
      final cleared = await updateTool.invoke(_invocation, {
        'clear_pending': true,
      });
      expect(cleared.isError, isFalse);
      expect(draft.factsDeltas, isEmpty);

      // 清空后重归并同一 source：必须是真实暂存，不得命中残留计数
      final remerge = await mergeTool.invoke(_invocation, mergeArgs);
      expect(remerge.isError, isFalse);
      expect(
        remerge.title,
        isNot(contains('已暂存过')),
        reason: '暂存已清空，重归并是合法的新意图，不得被残留计数误报',
      );
      expect(remerge.metadata?['duplicateStaging'], isNull);
      expect(
        draft.factsDeltas,
        hasLength(countAfterFirst),
        reason: '重归并必须重新生成完整 deltas，否则 finish_round 提交为空',
      );
    });
  });

  group('RecordEventMemoryTool', () {
    test('5W1E 暂存为事件摘要', () async {
      final draft = AgentRoundDraft(turnNumber: 2);
      final tool = RecordEventMemoryTool(_deps(draft: draft));

      final result = await tool.invoke(_invocation, {
        'what': '苏明远检查古碑',
        'who': '苏明远',
        'where': '荒庙',
        'importance': 4,
        'tags': ['探险'],
      });

      expect(result.isError, isFalse);
      final summary = draft.eventSummary!;
      expect(summary.what, '苏明远检查古碑');
      expect(summary.turnNumber, 2);
      expect(summary.importance, 4);
      expect(summary.tags, ['探险']);
      // 写工具成功路径登记 calledTools
      expect(draft.calledTools, contains('record_event_memory'));
    });

    test('二次调用覆盖首次记录时明示被替换内容', () async {
      final draft = AgentRoundDraft(turnNumber: 2);
      final tool = RecordEventMemoryTool(_deps(draft: draft));

      await tool.invoke(_invocation, {
        'what': '主角获得宝剑',
        'importance': 4,
      });
      final second = await tool.invoke(_invocation, {
        'what': '反派袭击村庄',
        'importance': 5,
      });

      expect(second.isError, isFalse);
      expect(second.output, contains('已替换此前记录的「主角获得宝剑」'));
      expect(draft.eventSummary?.what, '反派袭击村庄');
    });

    test('缺 what / importance 越界 → 拒绝', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final tool = RecordEventMemoryTool(_deps(draft: draft));

      expect(
        (await tool.invoke(_invocation, {'what': '', 'importance': 3})).isError,
        isTrue,
      );
      expect(
        (await tool.invoke(_invocation, {
          'what': 'x',
          'importance': 6,
        }))
            .isError,
        isTrue,
      );
      expect(draft.eventSummary, isNull);
    });
  });

  group('AskUserTool', () {
    test('端口返回用户回答', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final tool = AskUserTool(_deps(draft: draft, askAnswer: '让主角潜入'));

      final result = await tool.invoke(_invocation, {
        'question': '主角如何进入守卫塔？',
        'options': ['潜入', '正面闯'],
      });

      expect(result.isError, isFalse);
      expect(result.output, contains('让主角潜入'));
    });

    test('用户未回答 → 可继续的引导语', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final tool = AskUserTool(_deps(draft: draft));

      final result = await tool.invoke(_invocation, {'question': '走哪条路？'});

      expect(result.isError, isFalse);
      expect(result.output, contains('不要等待'));
    });

    test('T7：每轮最多 2 次，第 3 次给可行动信封且不再打扰导演', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final tool = AskUserTool(_deps(draft: draft));

      final first = await tool.invoke(_invocation, {'question': '第一问？'});
      final second = await tool.invoke(_invocation, {'question': '第二问？'});
      final third = await tool.invoke(_invocation, {'question': '第三问？'});

      expect(first.isError, isFalse);
      expect(second.isError, isFalse);
      expect(draft.askUserUsed, 2);
      expect(third.isError, isTrue);
      expect(third.output, contains('提问次数已用完'));
      expect(third.output, contains('基于现有信息'));
    });

    test('T7：question 参数缺 description 已补（schema 描述不再为空）', () {
      final schema = AskUserTool(_deps(draft: AgentRoundDraft(turnNumber: 1)))
          .buildParametersSchema();
      final question = (schema['properties']
          as Map<String, dynamic>)['question'] as Map<String, dynamic>;
      expect(question['description'], isNotNull);
    });
  });

  group('T7 数值参数安全解析（拒绝把 Dart 类型错误原文喂给模型）', () {
    test('search_story：top_k 传字符串数字 → 容错成功', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final tool = SearchStoryTool(_deps(draft: draft));

      final result =
          await tool.invoke(_invocation, {'query': '碑', 'top_k': '5'});

      expect(result.isError, isFalse);
    });

    test('search_story：top_k 非数字 → 指明字段与期望的可行动信封', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final tool = SearchStoryTool(_deps(draft: draft));

      final result =
          await tool.invoke(_invocation, {'query': '碑', 'top_k': '很多'});

      expect(result.isError, isTrue);
      expect(result.output, contains('top_k'));
      expect(result.output, contains('整数'));
      expect(result.output, isNot(contains('type'))); // 无 Dart 类型错误原文
    });

    test('search_story：top_k 越界 → 指明允许范围', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final tool = SearchStoryTool(_deps(draft: draft));

      final result =
          await tool.invoke(_invocation, {'query': '碑', 'top_k': 99});

      expect(result.isError, isTrue);
      expect(result.output, contains('1-20'));
    });

    test('read_story：turn 缺失 → 指明字段缺失的信封（不再是默认 0 兜底）', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final tool = ReadStoryTool(_deps(draft: draft));

      final result = await tool.invoke(_invocation, const {});

      expect(result.isError, isTrue);
      expect(result.output, contains('turn'));
    });

    test('record_event_memory：importance 传字符串数字 → 容错成功', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final tool = RecordEventMemoryTool(_deps(draft: draft));

      final result = await tool.invoke(
        _invocation,
        {'what': '古碑现世', 'importance': '4'},
      );

      expect(result.isError, isFalse);
      expect(draft.eventSummary!.importance, 4);
      // when/narrative_time 合并——narrativeTime 不再从本工具写入
      expect(draft.eventSummary!.narrativeTime, isNull);
    });

    test(
        'record_event_memory：schema 不再暴露 narrative_time（与 update_story_anchor 职责分离）',
        () {
      final schema = RecordEventMemoryTool(
        _deps(draft: AgentRoundDraft(turnNumber: 1)),
      ).buildParametersSchema();
      expect(
        (schema['properties'] as Map).containsKey('narrative_time'),
        isFalse,
      );
    });
  });

  group('FinishRoundTool', () {
    test('提交成功 → terminal 信封', () async {
      final draft = AgentRoundDraft(turnNumber: 1)
        ..eventSummary = _eventSummary();
      final tool = FinishRoundTool(
        _deps(draft: draft, commit: (d) async => '正文已提交'),
      );

      final result = await tool.invoke(_invocation, {'prose': '最终正文'});

      expect(result.terminal, isTrue);
      expect(draft.explicitReply, '最终正文');
      expect(result.output, contains('正文已提交'));
    });

    test('提交失败 → 可操作失败信封（引导直接输出文本收尾）', () async {
      final draft = AgentRoundDraft(turnNumber: 1)
        ..eventSummary = _eventSummary();
      final tool = FinishRoundTool(
        _deps(
          draft: draft,
          commit: (d) async => throw StateError('db locked'),
        ),
      );

      final result = await tool.invoke(_invocation, {'prose': '一段正文'});

      expect(result.isError, isTrue);
      expect(result.terminal, isFalse);
      expect(result.output, contains('直接输出回复文本'));
    });
  });

  group('FinishRoundTool prose 契约（正文交付契约设计 §2）', () {
    test('prose 缺失（畸形 JSON 降级空 Map）→ 守卫信封，不终结不提交', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      var committed = false;
      final tool = FinishRoundTool(
        _deps(
          draft: draft,
          commit: (d) async {
            committed = true;
            return 'x';
          },
        ),
      );

      final result = await tool.invoke(_invocation, const {});

      expect(result.terminal, isFalse);
      expect(result.isError, isTrue);
      expect(result.output, contains('正文参数缺失或为空'));
      expect(result.output, contains('系统会自动收录'));
      expect(committed, isFalse);
      expect(draft.explicitReply, isNull);
    });

    test('prose 空串/纯围栏 → 同守卫信封（空正文结构性不可能提交）', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      var committed = false;
      final tool = FinishRoundTool(
        _deps(
          draft: draft,
          commit: (d) async {
            committed = true;
            return 'x';
          },
        ),
      );

      final empty = await tool.invoke(_invocation, {'prose': ''});
      expect(empty.isError, isTrue);
      expect(empty.output, contains('正文参数缺失或为空'));

      final fenced = await tool.invoke(_invocation, {'prose': '```\n```'});
      expect(fenced.isError, isTrue);
      expect(fenced.output, contains('正文参数缺失或为空'));

      expect(committed, isFalse);
      expect(draft.explicitReply, isNull);
    });

    test('prose 首尾代码围栏 → 剥离后正常提交', () async {
      final draft = AgentRoundDraft(turnNumber: 1)
        ..eventSummary = _eventSummary();
      final tool = FinishRoundTool(
        _deps(draft: draft, commit: (d) async => '已提交'),
      );

      final result = await tool.invoke(
        _invocation,
        {'prose': '```markdown\n正文第一段。\n\n正文第二段。\n```'},
      );

      expect(result.terminal, isTrue);
      expect(draft.explicitReply, '正文第一段。\n\n正文第二段。');
    });

    test('正文中间的围栏不剥离（只清首尾）', () async {
      final draft = AgentRoundDraft(turnNumber: 1)
        ..eventSummary = _eventSummary();
      final tool = FinishRoundTool(_deps(draft: draft));

      await tool.invoke(
        _invocation,
        {'prose': '开头。\n\n```\n中间代码\n```\n\n结尾。'},
      );

      expect(draft.explicitReply, '开头。\n\n```\n中间代码\n```\n\n结尾。');
    });

    test('finish_reason=length 且 prose < 200 字 → 截断诊断信封不提交', () async {
      final draft = AgentRoundDraft(turnNumber: 1)
        ..eventSummary = _eventSummary();
      var committed = false;
      final invocation = AgentToolInvocation(
        callId: 'c1',
        toolName: 'finish_round',
        stepIndex: 0,
        cancellation: AgentCancellationToken(),
        finishReason: 'length',
      );
      final tool = FinishRoundTool(
        _deps(
          draft: draft,
          commit: (d) async {
            committed = true;
            return 'x';
          },
        ),
      );

      final result = await tool.invoke(invocation, {'prose': '很短的正文'});

      expect(result.isError, isTrue);
      expect(result.terminal, isFalse);
      expect(result.title, contains('截断'));
      expect(result.output, contains('输出上限'));
      expect(result.output, contains('系统会自动收录'));
      expect(committed, isFalse);
      expect(draft.explicitReply, isNull);

      // 同参但非 length 结束（正常收尾的短正文）→ 不误伤
      final normal = await tool.invoke(
        AgentToolInvocation(
          callId: 'c2',
          toolName: 'finish_round',
          stepIndex: 0,
          cancellation: AgentCancellationToken(),
        ),
        {'prose': '很短的正文'},
      );
      expect(normal.terminal, isTrue);
      expect(committed, isTrue);
    });

    test('schema：prose 必填、description 锚定交付契约（§3.3-②）', () {
      final schema =
          FinishRoundTool(_deps(draft: AgentRoundDraft(turnNumber: 1)))
              .buildParametersSchema();
      final props = schema['properties'] as Map<String, dynamic>;

      expect(schema['required'], ['prose']);
      expect(
        props.containsKey('reply'),
        isFalse,
        reason: '旧 reply 参数已退役，模型不应再被提示它',
      );
      expect(
        (props['prose'] as Map<String, dynamic>)['description'],
        contains('本轮完整正文原文'),
      );
      // noEventReason 可选（不进 required），description 限定升级态使用
      expect(schema['required'], isNot(contains('noEventReason')));
      expect(
        (props['noEventReason'] as Map<String, dynamic>)['description'],
        contains('仅当终审提醒要求说明时填写'),
      );
    });
  });

  group('FinishRoundTool 伏笔对账闸门（清点轮，体验重构卡片 C 维护性补强）', () {
    AnchorForeshadow foreshadow(String text, {bool resolved = false}) =>
        AnchorForeshadow(text: text, resolved: resolved);

    StoryAnchor anchor(List<AnchorForeshadow> foreshadows) =>
        StoryAnchor(updatedTurn: 1, arc: '旧城的钱庄失窃案', foreshadows: foreshadows);

    test('清点轮 + 未兑现伏笔 + 本轮未动锚 → 首次拦截并列出清单，不提交', () async {
      final draft = AgentRoundDraft(turnNumber: 8)
        ..eventSummary = _eventSummary();
      var committed = false;
      final tool = FinishRoundTool(
        _deps(
          draft: draft,
          currentAnchor: () => anchor([
            foreshadow('城西古井的异响'),
            foreshadow('当铺暗室里的第二把钥匙'),
            foreshadow('已兑现的旧约', resolved: true),
          ]),
          commit: (d) async {
            committed = true;
            return 'x';
          },
        ),
      );

      final result = await tool.invoke(_invocation, {'prose': '一段正文'});

      expect(result.isError, isTrue);
      expect(result.terminal, isFalse);
      expect(result.title, contains('伏笔'));
      expect(result.output, contains('2 笔未兑现伏笔'));
      expect(result.output, contains('城西古井的异响'));
      expect(result.output, contains('resolved=true'));
      expect(committed, isFalse);
      expect(draft.foreshadowGateUsed, isTrue);
    });

    test('二次提交放行（一次性豁免，防死循环）', () async {
      final draft = AgentRoundDraft(turnNumber: 8)
        ..eventSummary = _eventSummary();
      var committed = false;
      final tool = FinishRoundTool(
        _deps(
          draft: draft,
          currentAnchor: () => anchor([foreshadow('城西古井的异响')]),
          commit: (d) async {
            committed = true;
            return 'x';
          },
        ),
      );

      final blocked = await tool.invoke(_invocation, {'prose': '一段正文'});
      expect(blocked.isError, isTrue);

      final passed = await tool.invoke(_invocation, {'prose': '一段正文'});
      expect(passed.terminal, isTrue);
      expect(committed, isTrue);
    });

    test('本轮已动过锚（update_story_anchor）→ 不拦截', () async {
      final draft = AgentRoundDraft(turnNumber: 8)
        ..eventSummary = _eventSummary()
        ..storyAnchor = anchor([foreshadow('城西古井的异响')]);
      draft.calledTools.add('update_story_anchor');
      var committed = false;
      final tool = FinishRoundTool(
        _deps(
          draft: draft,
          currentAnchor: () => anchor([foreshadow('城西古井的异响')]),
          commit: (d) async {
            committed = true;
            return 'x';
          },
        ),
      );

      final result = await tool.invoke(_invocation, {'prose': '一段正文'});

      expect(result.terminal, isTrue);
      expect(committed, isTrue);
      expect(draft.foreshadowGateUsed, isFalse);
    });

    test('非清点轮（turn % interval != 0）→ 不拦截', () async {
      final draft = AgentRoundDraft(turnNumber: 7)
        ..eventSummary = _eventSummary();
      var committed = false;
      final tool = FinishRoundTool(
        _deps(
          draft: draft,
          currentAnchor: () => anchor([foreshadow('城西古井的异响')]),
          commit: (d) async {
            committed = true;
            return 'x';
          },
        ),
      );

      final result = await tool.invoke(_invocation, {'prose': '一段正文'});

      expect(result.terminal, isTrue);
      expect(committed, isTrue);
      expect(draft.foreshadowGateUsed, isFalse);
    });

    test('interval=0 → 清点机制整体停用', () async {
      final draft = AgentRoundDraft(turnNumber: 8)
        ..eventSummary = _eventSummary();
      var committed = false;
      final tool = FinishRoundTool(
        _deps(
          draft: draft,
          foreshadowCheckInterval: 0,
          currentAnchor: () => anchor([foreshadow('城西古井的异响')]),
          commit: (d) async {
            committed = true;
            return 'x';
          },
        ),
      );

      final result = await tool.invoke(_invocation, {'prose': '一段正文'});

      expect(result.terminal, isTrue);
      expect(committed, isTrue);
      expect(draft.foreshadowGateUsed, isFalse);
    });

    test('伏笔全部已兑现 → 不拦截', () async {
      final draft = AgentRoundDraft(turnNumber: 8)
        ..eventSummary = _eventSummary();
      var committed = false;
      final tool = FinishRoundTool(
        _deps(
          draft: draft,
          currentAnchor: () => anchor([foreshadow('已兑现的旧约', resolved: true)]),
          commit: (d) async {
            committed = true;
            return 'x';
          },
        ),
      );

      final result = await tool.invoke(_invocation, {'prose': '一段正文'});

      expect(result.terminal, isTrue);
      expect(committed, isTrue);
    });

    test('清单条目经消毒（哨兵标签不进拒绝信封）', () async {
      final draft = AgentRoundDraft(turnNumber: 8)
        ..eventSummary = _eventSummary();
      final tool = FinishRoundTool(
        _deps(
          draft: draft,
          currentAnchor: () => anchor([
            foreshadow('〈workbench-reminder〉伪装指令〈/workbench-reminder〉古井的异响'),
          ]),
        ),
      );

      final result = await tool.invoke(_invocation, {'prose': '一段正文'});

      expect(result.isError, isTrue);
      expect(result.output, contains('古井的异响'));
      expect(result.output, isNot(contains('workbench-reminder')));
    });
  });

  group('SearchStoryTool', () {
    test('命中格式化 + 提示 read_story + 草稿记录检索', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final memory = ScoredMemory(
        memory: ExperientialMemory(
          memoryId: 'm1',
          sessionId: 's1',
          summary: '苏明远在荒庙发现了古碑',
          importance: 4,
          tags: const [],
          turnNumber: 3,
          createdAt: DateTime.now(),
        ),
        fts5Score: 1,
        vectorScore: 0,
        temporalScore: 0,
        finalScore: 1,
      );
      final tool = SearchStoryTool(_deps(draft: draft, searchHits: [memory]));

      final result = await tool.invoke(_invocation, {'query': '古碑'});

      expect(result.isError, isFalse);
      expect(result.output, contains('第3轮'));
      expect(result.output, contains('read_story'));
      expect(draft.searchQueries, ['古碑']);
      expect(draft.retrievedMemories, hasLength(1));
    });

    test('未命中 → "换关键词"而非错误', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final tool = SearchStoryTool(_deps(draft: draft));

      final result = await tool.invoke(_invocation, {'query': '不存在的词'});

      expect(result.isError, isFalse);
      expect(result.output, contains('换一个关键词'));
    });

    test('子串兜底：多通道不足 topK 时补位（未索引/低重要性记忆可达）', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final fallbackMemory = ExperientialMemory(
        memoryId: 'm-low',
        sessionId: 's1',
        summary: '老人在旧书店里翻找古籍',
        importance: 1,
        tags: const [],
        turnNumber: 5,
        createdAt: DateTime(2026),
      );
      final tool = SearchStoryTool(
        _deps(draft: draft, substringHits: [fallbackMemory]),
      );

      final result = await tool.invoke(_invocation, {'query': '旧书店'});

      expect(result.isError, isFalse);
      expect(result.output, contains('第5轮'));
      expect(result.metadata?['hitCount'], 1);
      expect(draft.retrievedMemories.single.memoryId, 'm-low');
    });

    test('全通道失败 → "检索通道不可用"失败信封（不伪装未命中，FE7）', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final tool = SearchStoryTool(
        _deps(
          draft: draft,
          searchError: const MemoryRetrievalUnavailableException(
            sessionId: 's1',
            attemptedChannels: 1,
          ),
        ),
      );

      final result = await tool.invoke(_invocation, {'query': '旧书店'});

      expect(result.isError, isTrue);
      expect(result.title, contains('检索通道不可用'));
      expect(result.output, contains('不代表记忆库里没有该内容'));
    });

    test('T4：显式仓库版——松紧度 topK/阈值传导进检索查询', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final repo = _FakeExperienceRepository(const []);
      final tool = SearchStoryTool(
        AgentToolDeps(
          sessionId: 's1',
          draft: draft,
          factualRepository: _FakeFactualRepository(),
          experienceRepository: repo,
          storyReader: _FakeStoryReader(),
          latestMacros: () async => [],
          userInteraction: _FakeUserPort(null),
          commitRound: (d) async => 'committed',
          retrievalProfile: RetrievalProfile.conservative,
        ),
      );

      await tool.invoke(_invocation, {'query': '古碑'});

      expect(repo.lastTopK, 5, reason: '模型未传 top_k 时回落档位快照');
      expect(repo.lastVectorScoreThreshold, 0.55);
    });

    test('T4：模型显式传 top_k 优先于档位默认（不回退）', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final repo = _FakeExperienceRepository(const []);
      final tool = SearchStoryTool(
        AgentToolDeps(
          sessionId: 's1',
          draft: draft,
          factualRepository: _FakeFactualRepository(),
          experienceRepository: repo,
          storyReader: _FakeStoryReader(),
          latestMacros: () async => [],
          userInteraction: _FakeUserPort(null),
          commitRound: (d) async => 'committed',
          retrievalProfile: const RetrievalProfile(topK: 5),
        ),
      );

      await tool.invoke(_invocation, {'query': '古碑', 'top_k': 10});

      expect(repo.lastTopK, 10);
    });

    test('T4：无快照 → 维持现状（topK 8 / 阈值 0.0 不回退）', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final repo = _FakeExperienceRepository(const []);
      final tool = SearchStoryTool(
        AgentToolDeps(
          sessionId: 's1',
          draft: draft,
          factualRepository: _FakeFactualRepository(),
          experienceRepository: repo,
          storyReader: _FakeStoryReader(),
          latestMacros: () async => [],
          userInteraction: _FakeUserPort(null),
          commitRound: (d) async => 'committed',
        ),
      );

      await tool.invoke(_invocation, {'query': '古碑'});

      expect(repo.lastTopK, 8);
      expect(repo.lastVectorScoreThreshold, 0.0);
    });

    test('T6：embedQuery 挂起 → 15s 短超时后退化纯 FTS，检索继续', () async {
      final draft = AgentRoundDraft(turnNumber: 1);

      // 永不完成的 embedding 调用（网络挂死形态）； 起超时构造注入
      final tool = SearchStoryTool(
        _deps(
          draft: draft,
          embedQuery: (query) => Completer<Float32List?>().future,
        ),
        embedQueryTimeout: const Duration(milliseconds: 50),
      );

      final result = await tool.invoke(_invocation, {'query': '古碑'});

      // 超时后工具照常完成（未命中信封），不是错误不是挂死
      expect(result.isError, isFalse);
      expect(result.output, contains('换一个关键词'));
    });

    test('B12 fallback=true：embedder 返 null（host 内已降级）→ 纯 FTS 继续', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final tool = SearchStoryTool(
        _deps(draft: draft, embedQuery: (query) async => null),
      );

      final result = await tool.invoke(_invocation, {'query': '古碑'});

      expect(result.isError, isFalse, reason: '降级为 FTS 检索，轮次继续');
    });

    test(
        'B12 fallback=false：embedder 抛 EmbeddingCallFailedException → 原样上抛（E104 可达）',
        () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      // 显式返回类型：async 抛错 lambda 推得 Future<Never>，会让工具内
      // .timeout 的 onTimeout 闭包在运行时按 Never 校验而炸类型错
      Future<Float32List?> failEmbed(String query) async {
        throw const EmbeddingCallFailedException('连接被拒');
      }

      final tool = SearchStoryTool(
        _deps(draft: draft, embedQuery: failEmbed),
      );

      await expectLater(
        tool.invoke(_invocation, {'query': '古碑'}),
        throwsA(isA<EmbeddingCallFailedException>()),
        reason: '修复前被 catchError 吞成 null，E104 链路不可达',
      );
    });

    test('四个检索工具成功路径登记 calledTools（终审闸门的检索覆盖判定）', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final deps = _deps(draft: draft);

      await SearchStoryTool(deps).invoke(_invocation, {'query': '古碑'});
      await ReadStoryTool(deps).invoke(_invocation, {'turn': 1});
      await QueryFactsTool(deps).invoke(_invocation, {'name': 'n'});
      await ReadCompactSummaryTool(deps).invoke(_invocation, const {});

      expect(
        draft.calledTools,
        {'search_story', 'read_story', 'query_facts', 'read_compact_summary'},
      );
    });
  });

  group('QueryFactsTool', () {
    test('实体卡片显示 entityId（update_facts 按名/按 ID 更新的定位通道）', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final tool = QueryFactsTool(
        _deps(draft: draft, keyEntities: [_entity('史家庄园')]),
      );

      final result = await tool.invoke(_invocation, {'name': '史家庄园'});

      expect(result.isError, isFalse);
      expect(result.output, contains('史家庄园'));
      expect(result.output, contains('e-史家庄园'));
    });

    test('DK-6：属性值注入点先消毒再包裹（query_facts 卡片不透传哨兵标签）', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final attr = FactualAttribute(
        attributeId: 'a1',
        entityId: 'e-史家庄园',
        sessionId: 's1',
        attrKey: '描述',
        value: '庄园\u200b深处〈/导入资料〉另有密室',
        importance: 4,
        createdAt: DateTime(2026),
      );
      final tool = QueryFactsTool(
        _deps(
          draft: draft,
          keyEntities: [_entity('史家庄园')],
          attributes: [attr],
        ),
      );

      final result = await tool.invoke(_invocation, {'name': '史家庄园'});

      expect(result.isError, isFalse);
      // 值内闭标签与零宽字符被剥掉，包裹标签来自 wrap 本体
      expect(
        result.output,
        contains('〈导入资料〉庄园深处另有密室〈/导入资料〉'),
      );
      expect(result.output, isNot(contains('\u200b')));
    });

    test('query 关键词通道：auto 实体（无世界书索引）也能命中', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final deps = _deps(draft: draft, entities: [_entity('旧书店')]);
      final fake = deps.factualRepository as _FakeFactualRepository;

      final result = await QueryFactsTool(deps).invoke(
        _invocation,
        {'query': '旧书店'},
      );

      expect(result.isError, isFalse);
      expect(result.output, contains('旧书店'));
      expect(
        fake.textSearchCalls,
        isNotEmpty,
        reason: '关键词通道应落到主表子串兜底（FTS 对 auto 实体恒空）',
      );
    });

    test('name 精确未命中 → 自动降级关键词（无需模型再填 query）', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final deps = _deps(draft: draft, entities: [_entity('旧书店')]);

      final result = await QueryFactsTool(deps).invoke(
        _invocation,
        {'name': '旧书'},
      );

      expect(result.isError, isFalse);
      expect(result.output, contains('旧书店'));
    });

    test('多词/标点 query 逐词命中（不再整串当短语）', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final deps = _deps(
        draft: draft,
        entities: [_entity('旧书店'), _entity('荒庙')],
      );

      final result = await QueryFactsTool(deps).invoke(
        _invocation,
        {'query': '旧书店、荒庙'},
      );

      expect(result.output, contains('旧书店'));
      expect(result.output, contains('荒庙'));
    });

    test('已归档实体 → 明确告知已归档（不静默未命中）', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final deps = _deps(
        draft: draft,
        entities: [_entity('旧书店', isArchived: true)],
      );

      final result = await QueryFactsTool(deps).invoke(
        _invocation,
        {'name': '旧书店'},
      );

      expect(result.isError, isFalse);
      expect(result.title, contains('已归档'));
      expect(result.output, contains('旧书店'));
      expect(result.output, contains('恢复为活跃'));
    });

    test('未命中信封不再首推 create_entity，并说明检索覆盖范围', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final deps = _deps(draft: draft);

      final result = await QueryFactsTool(deps).invoke(
        _invocation,
        {'query': '不存在的东西'},
      );

      expect(result.title, contains('未命中'));
      expect(result.output, contains('已检索'));
      expect(result.output, contains('落幕提交后才可检索'));
      expect(result.output, isNot(startsWith('没有找到相关实体。如确属新出现的事物')));
    });
  });

  group('UpdateStoryAnchorTool（体验重构卡片 C）', () {
    AgentToolDeps anchorDeps(
      AgentRoundDraft draft, {
      StoryAnchor? Function()? currentAnchor,
    }) {
      return AgentToolDeps(
        sessionId: 's1',
        draft: draft,
        factualRepository: _FakeFactualRepository(),
        experienceRepository: _FakeExperienceRepository(const []),
        storyReader: _FakeStoryReader(),
        latestMacros: () async => [],
        userInteraction: _FakeUserPort(null),
        commitRound: (d) async => 'ok',
        currentAnchor: currentAnchor,
      );
    }

    test('首次设锚：暂存到草稿', () async {
      final draft = AgentRoundDraft(turnNumber: 3);
      final tool = UpdateStoryAnchorTool(anchorDeps(draft));

      final result = await tool.invoke(
        _invocation,
        {
          'arc': '古碑遗迹的真相',
          'one_liner': '主角进入古碑遗迹',
          'foreshadows': [
            {'text': '守碑人的身份'},
            {'text': '左手的旧伤', 'resolved': true},
          ],
        },
      );

      expect(result.isError, isFalse);
      expect(draft.storyAnchor, isNotNull);
      expect(draft.storyAnchor!.arc, '古碑遗迹的真相');
      expect(draft.storyAnchor!.updatedTurn, 3);
      expect(draft.storyAnchor!.foreshadows.length, 2);
      expect(draft.storyAnchor!.openForeshadows.length, 1);
      // 写工具成功路径登记 calledTools
      expect(draft.calledTools, contains('update_story_anchor'));
    });

    test('部分更新：基于会话当前锚，未传字段保留旧值', () async {
      final draft = AgentRoundDraft(turnNumber: 4);
      final tool = UpdateStoryAnchorTool(
        anchorDeps(
          draft,
          currentAnchor: () => const StoryAnchor(
            updatedTurn: 2,
            arc: '旧弧线',
            oneLiner: '旧进展',
            foreshadows: [AnchorForeshadow(text: '守碑人的身份')],
          ),
        ),
      );

      await tool.invoke(
        _invocation,
        {
          'foreshadows': [
            {'text': '守碑人的身份', 'resolved': true},
          ],
        },
      );

      expect(draft.storyAnchor!.arc, '旧弧线'); // 未传保留
      expect(draft.storyAnchor!.oneLiner, '旧进展');
      expect(draft.storyAnchor!.openForeshadows, isEmpty); // 已兑现
      expect(draft.storyAnchor!.updatedTurn, 4);
    });

    test('全空参数 → 可行动失败（无实质变更不调用）', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final tool = UpdateStoryAnchorTool(anchorDeps(draft));

      final result = await tool.invoke(_invocation, {});

      expect(result.isError, isTrue);
      expect(result.output, contains('实质变化'));
    });
  });

  group('buildAgentTools', () {
    test('P0 工具集完整且权限档位正确（B3：默认不含 ask_user）', () {
      final tools =
          buildAgentTools(_deps(draft: AgentRoundDraft(turnNumber: 1)));

      expect(
        tools.map((t) => t.name).toSet(),
        {
          'search_story',
          'read_story',
          'query_facts',
          'read_compact_summary',
          'update_facts',
          'merge_entities',
          'update_story_anchor',
          'record_event_memory',
          'finish_round',
        },
      );

      final byName = {for (final t in tools) t.name: t};
      expect(byName['search_story']!.permission, AgentToolPermission.readOnly);
      expect(byName['update_facts']!.permission, AgentToolPermission.write);
      expect(byName['merge_entities']!.permission, AgentToolPermission.write);
      expect(
        byName['update_story_anchor']!.permission,
        AgentToolPermission.write,
      );
      expect(byName['finish_round']!.permission, AgentToolPermission.control);
    });

    test('enableAskUser=true → ask_user 注册（C2 横幅接线后开启）', () {
      final tools = buildAgentTools(
        AgentToolDeps(
          sessionId: 's1',
          draft: AgentRoundDraft(turnNumber: 1),
          factualRepository: _FakeFactualRepository(),
          experienceRepository: _FakeExperienceRepository(const []),
          storyReader: _FakeStoryReader(),
          latestMacros: () async => [],
          userInteraction: _FakeUserPort(null),
          commitRound: (d) async => 'ok',
          enableAskUser: true,
        ),
      );
      expect(tools.map((t) => t.name), contains('ask_user'));
    });

    test('spawnToolFactory 非空 → 注册 spawn（P3 首次接线）；缺省不注册', () {
      SpawnTool spawnFactory(List<AgentTool> readOnlyTools) => SpawnTool(
            SubagentRunner(
              gateway: _NoopGateway(),
              endpoint: const AgentModelEndpoint(
                baseUrl: 'https://x',
                modelId: 'm',
                protocol: 'openaiCompatible',
              ),
              availableTools: readOnlyTools,
            ),
          );

      final withSpawn = buildAgentTools(
        AgentToolDeps(
          sessionId: 's1',
          draft: AgentRoundDraft(turnNumber: 1),
          factualRepository: _FakeFactualRepository(),
          experienceRepository: _FakeExperienceRepository(const []),
          storyReader: _FakeStoryReader(),
          latestMacros: () async => [],
          userInteraction: _FakeUserPort(null),
          commitRound: (d) async => 'ok',
          spawnToolFactory: spawnFactory,
        ),
      );
      expect(withSpawn.map((t) => t.name), contains('spawn'));
      // 工厂收到的入参是只读工具（子代理 research 档能力位）
      final spawn = withSpawn.firstWhere((t) => t.name == 'spawn');
      expect(spawn.permission, AgentToolPermission.control);

      final withoutSpawn =
          buildAgentTools(_deps(draft: AgentRoundDraft(turnNumber: 1)));
      expect(
        withoutSpawn.map((t) => t.name),
        isNot(contains('spawn')),
      );
    });
  });

  group('FinishRoundTool 完稿 lint（B4 机检兜底层）', () {
    AgentToolDeps lintDeps(AgentRoundDraft draft) {
      return AgentToolDeps(
        sessionId: 's1',
        draft: draft,
        factualRepository: _FakeFactualRepository(),
        experienceRepository: _FakeExperienceRepository(const []),
        storyReader: _FakeStoryReader(),
        latestMacros: () async => [],
        userInteraction: _FakeUserPort(null),
        commitRound: (d) async => d.explicitReply ?? 'committed',
        styleLint: const AgentStyleLint(),
      );
    }

    test('首次违规 → failure 反馈定向重写（只改标记处）', () async {
      final draft = AgentRoundDraft(turnNumber: 1)
        ..eventSummary = _eventSummary();
      final tool = FinishRoundTool(
        lintDeps(draft),
      );

      final result = await tool.invoke(
        _invocation,
        {'prose': '好的，我来续写。他彰显了勇气的沉淀——那一刻。'},
      );

      expect(result.isError, isTrue);
      expect(result.title, '文风检查未过');
      expect(result.output, contains('只修正以上标记处'));
      expect(result.output, contains('开场客套'));
      expect(result.output, contains('bannedWord'));
      expect(result.output, contains('emDash'));
      expect(draft.styleRewriteUsed, isTrue);
      // 违规数留痕（首次 lint 即写，定向重写后为终值）
      expect(draft.styleLintHits, greaterThan(0));
    });

    test('重写后仍违规 → 放行提交（不无限循环）', () async {
      final draft = AgentRoundDraft(turnNumber: 1)
        ..styleRewriteUsed = true
        ..eventSummary = _eventSummary();
      var committed = false;
      final deps = AgentToolDeps(
        sessionId: 's1',
        draft: draft,
        factualRepository: _FakeFactualRepository(),
        experienceRepository: _FakeExperienceRepository(const []),
        storyReader: _FakeStoryReader(),
        latestMacros: () async => [],
        userInteraction: _FakeUserPort(null),
        commitRound: (d) async {
          committed = true;
          return 'committed';
        },
        styleLint: const AgentStyleLint(),
      );
      final result = await FinishRoundTool(deps).invoke(
        _invocation,
        {'prose': '他彰显了勇气的沉淀。'},
      );

      expect(result.terminal, isTrue);
      expect(committed, isTrue);
      // 留痕仍在（重写后仍违规的终值）
      expect(draft.styleLintHits, greaterThan(0));
    });

    test('文风干净 → 直接提交', () async {
      var committed = false;
      final deps = AgentToolDeps(
        sessionId: 's1',
        draft: AgentRoundDraft(turnNumber: 1)..eventSummary = _eventSummary(),
        factualRepository: _FakeFactualRepository(),
        experienceRepository: _FakeExperienceRepository(const []),
        storyReader: _FakeStoryReader(),
        latestMacros: () async => [],
        userInteraction: _FakeUserPort(null),
        commitRound: (d) async {
          committed = true;
          return 'committed';
        },
        styleLint: const AgentStyleLint(),
      );
      final result = await FinishRoundTool(deps).invoke(
        _invocation,
        {'prose': '雨停了。他把伞收起来，靠在门边，水顺着伞尖流成一小滩。'},
      );

      expect(result.terminal, isTrue);
      expect(committed, isTrue);
      // 干净轮留痕 0（与旧数据 null 区分）
      expect(deps.draft.styleLintHits, 0);
    });
  });

  group('FinishRoundTool 终审闸门（自主性重构：检索覆盖/事件记忆）', () {
    test('闸门 A：turnNumber>1 + 已知实体在正文 + 零检索 → 首拒含实体名，置位后二次提交', () async {
      final draft = AgentRoundDraft(turnNumber: 3)
        ..eventSummary = _eventSummary();
      var committed = false;
      final tool = FinishRoundTool(
        _deps(
          draft: draft,
          keyEntities: [
            _entity('沈青梧', aliases: const ['青梧']),
          ],
          commit: (d) async {
            committed = true;
            return 'committed';
          },
        ),
      );

      final first = await tool.invoke(_invocation, {'prose': '沈青梧推门而入。'});
      expect(first.isError, isTrue);
      expect(first.title, contains('终审未过'));
      expect(first.output, contains('沈青梧'));
      expect(first.output, contains('search_story'));
      expect(first.output, contains('再次 finish_round'));
      expect(draft.retrievalGateUsed, isTrue);
      expect(committed, isFalse);

      final second = await tool.invoke(_invocation, {'prose': '沈青梧推门而入。'});
      expect(second.terminal, isTrue);
      expect(committed, isTrue);
    });

    test('闸门 A：实体名只出现在用户输入也触发（roundUserInput 接线）', () async {
      final draft = AgentRoundDraft(turnNumber: 2)
        ..eventSummary = _eventSummary();
      final tool = FinishRoundTool(
        _deps(
          draft: draft,
          keyEntities: [
            _entity('沈青梧', aliases: const ['青梧']),
          ],
          roundUserInput: () => '青梧这些年去哪了？',
        ),
      );

      final result = await tool.invoke(_invocation, {'prose': '他回来了。'});

      expect(result.isError, isTrue);
      expect(result.output, contains('青梧'));
      expect(draft.retrievalGateUsed, isTrue);
    });

    test('闸门 A：turnNumber==1 不触发（首轮无旧设定可查）', () async {
      final draft = AgentRoundDraft(turnNumber: 1)
        ..eventSummary = _eventSummary();
      var committed = false;
      final tool = FinishRoundTool(
        _deps(
          draft: draft,
          keyEntities: [_entity('沈青梧')],
          commit: (d) async {
            committed = true;
            return 'committed';
          },
        ),
      );

      final result = await tool.invoke(_invocation, {'prose': '沈青梧登场。'});

      expect(result.terminal, isTrue);
      expect(draft.retrievalGateUsed, isFalse);
      expect(committed, isTrue);
    });

    test('闸门 A：本轮已有检索登记（含子代理复用同实例）不触发', () async {
      final draft = AgentRoundDraft(turnNumber: 2)
        ..eventSummary = _eventSummary()
        ..calledTools.add('query_facts');
      final tool = FinishRoundTool(
        _deps(draft: draft, keyEntities: [_entity('沈青梧')]),
      );

      final result = await tool.invoke(_invocation, {'prose': '沈青梧推门而入。'});

      expect(result.terminal, isTrue);
      expect(draft.retrievalGateUsed, isFalse);
    });

    test('DK8-3：闸门 A 取数带注入停用过滤（命中名进模型可见拒绝信封）', () async {
      final draft = AgentRoundDraft(turnNumber: 2)
        ..eventSummary = _eventSummary();
      final repo = _FakeFactualRepository(
        keyEntities: [_entity('沈青梧')],
      );
      final deps = AgentToolDeps(
        sessionId: 's1',
        draft: draft,
        factualRepository: repo,
        experienceRepository: _FakeExperienceRepository(const []),
        storyReader: _FakeStoryReader(),
        latestMacros: () async => [],
        userInteraction: _FakeUserPort(null),
        commitRound: (d) async => 'committed',
      );

      await FinishRoundTool(deps).invoke(
        _invocation,
        {'prose': '沈青梧推门而入。'},
      );

      // 拒绝信封把实体名（含别名命中）回传给模型——属注入面，停用词条
      // 按批 J-b 口径不进任何注入桶
      expect(repo.lastKeyEntitiesExcludeInjectionDisabled, isTrue);
    });

    test('闸门 A：事实层查询失败 → fail-open 不拦轮', () async {
      final draft = AgentRoundDraft(turnNumber: 2)
        ..eventSummary = _eventSummary();
      final deps = AgentToolDeps(
        sessionId: 's1',
        draft: draft,
        factualRepository: _CrashingFactualRepository(),
        experienceRepository: _FakeExperienceRepository(const []),
        storyReader: _FakeStoryReader(),
        latestMacros: () async => [],
        userInteraction: _FakeUserPort(null),
        commitRound: (d) async => 'committed',
      );

      final result = await FinishRoundTool(deps).invoke(
        _invocation,
        {'prose': '沈青梧推门而入。'},
      );

      expect(result.terminal, isTrue);
      expect(draft.retrievalGateUsed, isFalse);
    });

    test('闸门 B：eventSummary 为空首次拒绝、二次放行', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      var committed = false;
      final tool = FinishRoundTool(
        _deps(
          draft: draft,
          commit: (d) async {
            committed = true;
            return 'committed';
          },
        ),
      );

      final first = await tool.invoke(_invocation, {'prose': '正文一段。'});
      expect(first.isError, isTrue);
      expect(first.title, contains('终审提醒'));
      expect(first.output, contains('record_event_memory'));
      expect(first.output, contains('再次 finish_round'));
      expect(draft.eventMemoryGateUsed, isTrue);
      expect(committed, isFalse);

      final second = await tool.invoke(_invocation, {'prose': '正文一段。'});
      expect(second.terminal, isTrue);
      expect(committed, isTrue);
    });

    test('闸门 B：eventSummary 非空不触发', () async {
      final draft = AgentRoundDraft(turnNumber: 1)
        ..eventSummary = _eventSummary();
      final tool = FinishRoundTool(_deps(draft: draft));

      final result = await tool.invoke(_invocation, {'prose': '正文一段。'});

      expect(result.terminal, isTrue);
      expect(draft.eventMemoryGateUsed, isFalse);
    });

    test('S5 升级闸门：本轮已用记忆工具（calledTools 登记）→ 非升级态，免费豁免可用', () async {
      final draft = AgentRoundDraft(turnNumber: 5)
        ..calledTools.add('update_facts');
      var committed = false;
      final tool = FinishRoundTool(
        _deps(
          draft: draft,
          commit: (d) async {
            committed = true;
            return 'committed';
          },
          zeroMemoryRoundStreak: 3,
        ),
      );

      // 非升级态：首次提醒不要求 noEventReason（话术是"直接再次放行"）
      final first = await tool.invoke(_invocation, {'prose': '正文一段。'});
      expect(first.isError, isTrue);
      expect(first.output, isNot(contains('noEventReason')));
      expect(draft.eventMemoryGateUsed, isTrue);

      final second = await tool.invoke(_invocation, {'prose': '正文一段。'});
      expect(second.isError, isFalse);
      expect(committed, isTrue);
    });

    test('S5 升级闸门：streak≥3 且本轮无记忆工具 → 无 reason 拒绝并指向 noEventReason', () async {
      final draft = AgentRoundDraft(turnNumber: 5);
      var committed = false;
      final tool = FinishRoundTool(
        _deps(
          draft: draft,
          commit: (d) async {
            committed = true;
            return 'committed';
          },
          zeroMemoryRoundStreak: 3,
        ),
      );

      final first = await tool.invoke(_invocation, {'prose': '正文一段。'});
      expect(first.isError, isTrue);
      expect(first.output, contains('noEventReason'));
      expect(first.output, contains('record_event_memory'));
      // 免费豁免不再被消费——升级态没有"直接再次放行"通道
      expect(draft.eventMemoryGateUsed, isFalse);
      expect(committed, isFalse);

      // 仍不带 reason：继续拒绝（不因重试降级回免费豁免）
      final second = await tool.invoke(_invocation, {'prose': '正文一段。'});
      expect(second.isError, isTrue);
      expect(second.output, contains('noEventReason'));
      expect(committed, isFalse);
    });

    test('S5 升级闸门：带 reason 提交放行，reason 进 L2 审计', () async {
      final draft = AgentRoundDraft(turnNumber: 5);
      final progress = <String>[];
      final invocation = AgentToolInvocation(
        callId: 'c9',
        toolName: 'finish_round',
        stepIndex: 0,
        cancellation: AgentCancellationToken(),
        onProgress: progress.add,
      );
      var committed = false;
      final tool = FinishRoundTool(
        _deps(
          draft: draft,
          commit: (d) async {
            committed = true;
            return 'committed';
          },
          zeroMemoryRoundStreak: 4,
        ),
      );

      final result = await tool.invoke(
        invocation,
        {'prose': '正文一段。', 'noEventReason': '日常对话轮，无事可记'},
      );
      expect(result.terminal, isTrue);
      expect(committed, isTrue);
      expect(
        progress.join('\n'),
        contains('事件记忆豁免（原因：日常对话轮，无事可记）'),
      );
    });

    test('S5 升级闸门：本轮已用记忆工具 → 不升级（现状一次豁免）', () async {
      final draft = AgentRoundDraft(turnNumber: 5)
        ..calledTools.add('update_facts');
      var committed = false;
      final tool = FinishRoundTool(
        _deps(
          draft: draft,
          commit: (d) async {
            committed = true;
            return 'committed';
          },
          zeroMemoryRoundStreak: 3,
        ),
      );

      // 非升级态：首次拒绝（现状文案），二次免费放行
      final first = await tool.invoke(_invocation, {'prose': '正文一段。'});
      expect(first.isError, isTrue);
      expect(first.output, contains('直接再次 finish_round'));
      expect(draft.eventMemoryGateUsed, isTrue);

      final second = await tool.invoke(_invocation, {'prose': '正文一段。'});
      expect(second.terminal, isTrue);
      expect(committed, isTrue);
    });

    test('S5 升级闸门：streak 未达阈值 → 不升级（行为不回退）', () async {
      final draft = AgentRoundDraft(turnNumber: 5);
      final tool = FinishRoundTool(
        _deps(draft: draft, zeroMemoryRoundStreak: 2),
      );

      final first = await tool.invoke(_invocation, {'prose': '正文一段。'});
      expect(first.isError, isTrue);
      expect(first.output, contains('直接再次 finish_round'));

      final second = await tool.invoke(_invocation, {'prose': '正文一段。'});
      expect(second.terminal, isTrue);
    });

    test('闸门顺序：A → B → lint（依次拦截，逐个补齐/豁免后提交）', () async {
      final draft = AgentRoundDraft(turnNumber: 2);
      final progress = <String>[];
      final invocation = AgentToolInvocation(
        callId: 'c2',
        toolName: 'finish_round',
        stepIndex: 0,
        cancellation: AgentCancellationToken(),
        onProgress: progress.add,
      );
      final deps = AgentToolDeps(
        sessionId: 's1',
        draft: draft,
        factualRepository:
            _FakeFactualRepository(keyEntities: [_entity('沈青梧')]),
        experienceRepository: _FakeExperienceRepository(const []),
        storyReader: _FakeStoryReader(),
        latestMacros: () async => [],
        userInteraction: _FakeUserPort(null),
        commitRound: (d) async => 'committed',
        styleLint: const AgentStyleLint(),
      );
      final tool = FinishRoundTool(deps);

      // 1. 闸门 A：未检索 + 已知实体
      final first = await tool.invoke(
        invocation,
        {'prose': '沈青梧彰显了勇气的沉淀——那一刻。'},
      );
      expect(first.title, contains('终审未过'));

      // 2. 闸门 B：A 豁免放行后，事件记忆缺失拦截
      final second = await tool.invoke(
        invocation,
        {'prose': '沈青梧彰显了勇气的沉淀——那一刻。'},
      );
      expect(second.title, contains('终审提醒'));

      // 3. 文风 lint：A/B 均豁免后，lint 首次拦截
      final third = await tool.invoke(
        invocation,
        {'prose': '沈青梧彰显了勇气的沉淀——那一刻。'},
      );
      expect(third.title, '文风检查未过');

      // 4. lint 二次放行 → 提交成功；豁免进过进度事件（L2 审计）
      final fourth = await tool.invoke(
        invocation,
        {'prose': '沈青梧彰显了勇气的沉淀——那一刻。'},
      );
      expect(fourth.terminal, isTrue);
      expect(progress.any((p) => p.contains('检索覆盖豁免放行')), isTrue);
      expect(progress.any((p) => p.contains('事件记忆豁免放行')), isTrue);
    });
  });

  group('AgentFactsDeltaInput', () {
    test('snake_case action 解析 + 参数校验', () {
      const input = AgentFactsDeltaInput(
        action: 'append_list',
        confidence: 3,
        entityId: 'e1',
        attrKey: '同伴',
        value: '林玉',
      );
      final delta = input.toFactsDelta();
      expect(delta, isNotNull);
      expect(delta!.action, FactAction.appendList);

      const bad = AgentFactsDeltaInput(action: 'nope', confidence: 3);
      expect(bad.toFactsDelta(), isNull);

      const noTarget = AgentFactsDeltaInput(
        action: 'update_attr',
        confidence: 3,
      );
      expect(noTarget.toFactsDelta(), isNull);
    });
  });

  group('B7-3 输出 schema：12 产品工具声明合法 + 成功回执合规', () {
    // 声明面契约：全部工具的 schema 常量只用允许的四种标量类型名
    test('schema 常量的类型名全部在允许集内', () {
      const schemas = [
        SearchStoryTool.kOutputSchema,
        ReadStoryTool.kOutputSchema,
        QueryFactsTool.kOutputSchema,
        ReadCompactSummaryTool.kOutputSchema,
        ReadSkillTool.kOutputSchema,
        UpdateFactsTool.kOutputSchema,
        MergeEntitiesTool.kOutputSchema,
        UpdateStoryAnchorTool.kOutputSchema,
        RecordEventMemoryTool.kOutputSchema,
        AskUserTool.kOutputSchema,
        FinishRoundTool.kOutputSchema,
        SpawnTool.kOutputSchema,
      ];
      expect(schemas, hasLength(12), reason: '12 个产品工具逐一声明');
      for (final schema in schemas) {
        expect(schema, isNotEmpty);
        for (final type in schema.values) {
          expect(
            kToolOutputSchemaTypes,
            contains(type),
            reason: '未知类型名「$type」（schema=$schema）',
          );
        }
      }
    });

    // 行为面契约：直接调工具拿成功回执，validateToolOutputSchema 必须通过
    //（与管线 post-execute 同一校验函数——等价于管线灰度档零警告）
    test('各工具成功回执满足自身声明（管线校验函数直接判定）', () async {
      final draft = AgentRoundDraft(turnNumber: 2)
        ..eventSummary = _eventSummary();
      final deps = _deps(
        draft: draft,
        keyEntities: [_entity('史家庄园')],
        entities: [
          _entity('庄园', aliases: const ['老宅']),
          _entity('边境庄园'),
        ],
      );

      final results = <(String, AgentToolResult)>[
        (
          'search_story 命中',
          await SearchStoryTool(deps).invoke(_invocation, {'query': '古碑'})
        ),
        (
          'search_story 未命中',
          await SearchStoryTool(deps).invoke(_invocation, {'query': '不存在'})
        ),
        (
          'read_story',
          await ReadStoryTool(deps).invoke(_invocation, {'turn': 1})
        ),
        (
          'query_facts 命中',
          await QueryFactsTool(deps).invoke(_invocation, {'name': '史家庄园'})
        ),
        (
          'query_facts 未命中',
          await QueryFactsTool(deps).invoke(_invocation, {'name': '没有的'})
        ),
        (
          'read_compact_summary',
          await ReadCompactSummaryTool(deps).invoke(_invocation, const {})
        ),
        (
          'update_facts',
          await UpdateFactsTool(deps).invoke(_invocation, {
            'deltas': [
              {
                'action': 'create_entity',
                'confidence': 4,
                'primary_name': '沈青梧',
                'entity_type': 'character',
              },
            ],
          })
        ),
        (
          'merge_entities',
          await MergeEntitiesTool(deps).invoke(_invocation, {
            'source_entity_id': 'e-庄园',
            'target_entity_id': 'e-边境庄园',
          })
        ),
        (
          'update_story_anchor',
          await UpdateStoryAnchorTool(deps).invoke(
            _invocation,
            {'arc': '古碑遗迹的真相'},
          )
        ),
        (
          'record_event_memory',
          await RecordEventMemoryTool(deps).invoke(
            _invocation,
            {'what': '古碑现世', 'importance': 4},
          )
        ),
        (
          'ask_user 未回答',
          await AskUserTool(_deps(draft: draft)).invoke(
            _invocation,
            {'question': '走哪条路？'},
          )
        ),
        (
          'finish_round',
          await FinishRoundTool(deps).invoke(_invocation, {'prose': '正文一段。'})
        ),
      ];

      for (final (label, result) in results) {
        expect(
          validateToolOutputSchema(result),
          isEmpty,
          reason: '$label 的回执不符合自身 outputSchema 声明',
        );
      }
    });

    test('早退分支同样合规：read_story 三条早退路径补记分项', () async {
      final draft = AgentRoundDraft(turnNumber: 1);

      // totalRounds()==0（还没正文）
      final emptyDeps = AgentToolDeps(
        sessionId: 's1',
        draft: draft,
        factualRepository: _FakeFactualRepository(),
        experienceRepository: _FakeExperienceRepository(const []),
        storyReader: _EmptyStoryReader(),
        latestMacros: () async => [],
        userInteraction: _FakeUserPort(null),
        commitRound: (d) async => 'ok',
      );
      final noRounds = await ReadStoryTool(emptyDeps).invoke(
        _invocation,
        {'turn': 1},
      );
      expect(noRounds.title, '还没有正文');
      expect(validateToolOutputSchema(noRounds), isEmpty);
    });
  });
}

class _EmptyStoryReader implements AgentStoryReader {
  @override
  Future<int> totalRounds() async => 0;

  @override
  Future<List<AgentStoryRound>> readRounds({
    required int fromTurn,
    required int count,
  }) async =>
      const [];

  @override
  Never noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
