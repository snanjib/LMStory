import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_round_draft.dart';
import 'package:lmstory/features/advanced/domain/services/agent_session_tools.dart';
import 'package:lmstory/features/advanced/domain/services/agent_story_reader.dart';
import 'package:lmstory/features/advanced/domain/services/retrieval_evidence.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/features/memory/domain/entities/scored_memory.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';

// ── Fakes ────────────────────────────────────────────────────────────

class _FakeFactualRepository implements FactualRepository {
  _FakeFactualRepository({this.keyEntities = const []});

  /// 终审闸门 A 的关键实体返回值
  final List<FactualEntity> keyEntities;

  /// 最近一次 getKeyEntities 是否带了注入停用过滤
  bool? lastKeyEntitiesExcludeInjectionDisabled;

  /// 全量实体池（getEntityById / findByName 兜底查询用）
  final List<FactualEntity> entities = const [];

  /// 属性池（getAttributes 按 entityId 过滤返回）
  final List<FactualAttribute> attributes = const [];

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

class _FakeExperienceRepository implements ExperienceRepository {
  _FakeExperienceRepository(this.hits);

  final List<ScoredMemory> hits;

  /// 子串兜底命中池（与多通道 hits 分离，便于断言补齐行为）
  final List<ExperientialMemory> substringHits = const [];

  /// 非 null 时多通道检索直接抛出（模拟全通道失败）
  final Exception? searchError = null;

  /// searchExperiencesBySubstring 调用次数
  int substringCalls = 0;

  // 捕获最近一次检索的 topK / 向量阈值（断言松紧度快照传导）
  int? lastTopK;
  double? lastVectorScoreThreshold;

  // MEM-12a 值锁定：捕获最近一次多通道检索的全部排序参数（防漂移）
  double? lastFts5Weight;
  double? lastVectorWeight;
  int? lastKeyEventThreshold;
  double? lastKeyEventBoost;
  double? lastNormalizationEpsilon;

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
    lastFts5Weight = fts5Weight;
    lastVectorWeight = vectorWeight;
    lastKeyEventThreshold = keyEventThreshold;
    lastKeyEventBoost = keyEventBoost;
    lastNormalizationEpsilon = normalizationEpsilon;
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
  test(
      'qualified historical evidence must bypass legacy per-round retrieval gate',
      () async {
    final draft = AgentRoundDraft(turnNumber: 3)
      ..eventSummary = _eventSummary();
    var checked = false;
    var committed = false;
    final deps = AgentToolDeps(
      sessionId: 's1',
      draft: draft,
      factualRepository: _FakeFactualRepository(keyEntities: [_entity('沈青梧')]),
      experienceRepository: _FakeExperienceRepository([]),
      storyReader: _FakeStoryReader(),
      latestMacros: () async => [],
      userInteraction: _FakeUserPort(null),
      retrievalEvidenceGate: (prose) async {
        checked = true;
        return const EntityCoverageCheck(
          missingEntities: [],
          missingDueToRevision: [],
        );
      },
      commitRound: (d) async {
        committed = true;
        return 'committed';
      },
    );
    final result =
        await FinishRoundTool(deps).invoke(_invocation, {'prose': '沈青梧推门而入。'});
    expect(checked, isTrue);
    expect(result.isError, isFalse, reason: result.output);
    expect(committed, isTrue);
  });

  test('开启态新 gate 有缺口 → 结构化首拒列出缺证据实体（旧闸门文案不出现）', () async {
    final draft = AgentRoundDraft(turnNumber: 3)
      ..eventSummary = _eventSummary();
    var committed = false;
    final deps = AgentToolDeps(
      sessionId: 's1',
      draft: draft,
      factualRepository: _FakeFactualRepository(keyEntities: [_entity('沈青梧')]),
      experienceRepository: _FakeExperienceRepository([]),
      storyReader: _FakeStoryReader(),
      latestMacros: () async => [],
      userInteraction: _FakeUserPort(null),
      retrievalEvidenceGate: (prose) async => const EntityCoverageCheck(
        missingEntities: ['沈青梧'],
        missingDueToRevision: [],
      ),
      commitRound: (d) async {
        committed = true;
        return 'committed';
      },
    );
    final result =
        await FinishRoundTool(deps).invoke(_invocation, {'prose': '沈青梧推门而入。'});
    expect(result.isError, isTrue);
    expect(result.output, contains('缺少当前有效核对证据'));
    expect(result.output, contains('沈青梧'));
    expect(
      result.output,
      isNot(contains('全程未做任何检索核对')),
      reason: '开启态不得再走旧本轮 calledTools 闸门文案',
    );
    expect(committed, isFalse);
    expect(draft.retrievalGateUsed, isTrue, reason: '首拒占用一次性豁免');
  });

  test('关闭态旧本轮检索闸门保留（gate null → 未检索首拒）', () async {
    final draft = AgentRoundDraft(turnNumber: 3)
      ..eventSummary = _eventSummary();
    var committed = false;
    final deps = AgentToolDeps(
      sessionId: 's1',
      draft: draft,
      factualRepository: _FakeFactualRepository(keyEntities: [_entity('沈青梧')]),
      experienceRepository: _FakeExperienceRepository([]),
      storyReader: _FakeStoryReader(),
      latestMacros: () async => [],
      userInteraction: _FakeUserPort(null),
      commitRound: (d) async {
        committed = true;
        return 'committed';
      },
    );
    final result =
        await FinishRoundTool(deps).invoke(_invocation, {'prose': '沈青梧推门而入。'});
    expect(result.isError, isTrue);
    expect(result.output, contains('全程未做任何检索核对'));
    expect(committed, isFalse);
  });

  test('query_facts 成功证据按统一修订摘要采集（与闸门同函数）', () async {
    final draft = AgentRoundDraft(turnNumber: 2);
    final deps = AgentToolDeps(
      sessionId: 's1',
      draft: draft,
      factualRepository: _FakeFactualRepository(keyEntities: [_entity('沈青梧')]),
      experienceRepository: _FakeExperienceRepository([]),
      storyReader: _FakeStoryReader(),
      latestMacros: () async => [],
      userInteraction: _FakeUserPort(null),
      commitRound: (d) async => 'committed',
    );
    final result = await QueryFactsTool(deps).invoke(
      _invocation,
      {'name': '沈青梧'},
    );
    expect(result.isError, isFalse, reason: result.output);
    final evidence =
        result.metadata?['retrievalEvidence'] as Map<dynamic, dynamic>?;
    expect(evidence, isNotNull);
    expect(evidence!['status'], 'success');
    final entities = evidence['entities'] as List;
    expect(entities, hasLength(1));
    expect((entities.first as Map)['id'], 'e-沈青梧');
    // 修订摘要与闸门比对共用 entityRevisionDigest（无属性+无更新时间的
    // 确定性摘要），两侧独立实现会导致未修订实体误判修订变化
    expect(
      (entities.first as Map)['contentDigest'],
      entityRevisionDigest(updatedAtMs: null, attributes: const []),
    );
  });
}
