import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/features/advanced/domain/services/agent_system_prompt.dart';
import 'package:lmstory/features/advanced/domain/services/director_core_blocks.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';

import '../../../helpers/fake_factual_repository.dart';

/// core blocks 共享装配服务测试
///
/// 装配语义自 runner 迁出（零行为变化），runner 注入面与场记板视图同源。
void main() {
  test('装配：关键实体 + 属性 + 宏摘要 + 时间 + 锚，text 与注入面同构', () async {
    final factual = FakeFactualRepository();
    final entity = _entity('e1', '灯塔');
    factual.entitiesById['e1'] = entity;
    factual.seedAttribute(
      FactualAttribute(
        attributeId: 'a1',
        entityId: 'e1',
        sessionId: 's1',
        attrKey: '状态',
        value: '熄灭',
        importance: 4,
        createdAt: DateTime(2026),
      ),
    );
    final repo = _FakeExperienceRepo([
      _macro('主线推进到第二夜'),
    ]);

    final data = await assembleDirectorCoreBlocks(
      factual: factual,
      experienceRepository: repo,
      sessionId: 's1',
      factualConfig: const FactualConfig(),
      narrativeTime: '第二夜',
      anchor: const StoryAnchor(
        updatedTurn: 2,
        arc: '抵达灯塔',
        foreshadows: [AnchorForeshadow(text: '灯塔里有人')],
      ),
    );

    expect(data, isNotNull);
    expect(data!.keyEntities, hasLength(1));
    expect(data.attributesByEntity['e1'], hasLength(1));
    expect(data.latestMacros, hasLength(1));
    expect(data.hasImported, isFalse);

    // text 与注入面（AgentSystemPromptBuilder.buildCoreBlocks）同构
    final expected = const AgentSystemPromptBuilder().buildCoreBlocks(
      keyEntities: data.keyEntities,
      attributesByEntity: data.attributesByEntity,
      latestMacros: data.latestMacros,
      narrativeTime: '第二夜',
      anchor: const StoryAnchor(
        updatedTurn: 2,
        arc: '抵达灯塔',
        foreshadows: [AnchorForeshadow(text: '灯塔里有人')],
      ),
    );
    expect(data.text, expected);
    expect(data.text, contains('【当前世界状态（关键实体）】'));
    expect(data.text, contains('【当前弧线】抵达灯塔'));
  });

  test('失败降级：仓储异常返回 null 不抛出', () async {
    final factual = FakeFactualRepository()
      ..getKeyEntitiesException = Exception('db down');

    final data = await assembleDirectorCoreBlocks(
      factual: factual,
      experienceRepository: _FakeExperienceRepo(const []),
      sessionId: 's1',
      factualConfig: const FactualConfig(),
      narrativeTime: null,
      anchor: null,
    );

    expect(data, isNull);
  });

  test('停用词条剔除（口径随迁）：excludeInjectionDisabled 生效', () async {
    final factual = FakeFactualRepository()
      ..keyEntitiesOverride = [
        _entity('e1', '启用实体'),
        _entity('e2', '停用实体', injectionDisabled: true),
      ];

    final data = await assembleDirectorCoreBlocks(
      factual: factual,
      experienceRepository: _FakeExperienceRepo(const []),
      sessionId: 's1',
      factualConfig: const FactualConfig(),
      narrativeTime: null,
      anchor: null,
    );

    expect(data!.keyEntities.map((e) => e.primaryName), ['启用实体']);
  });

  // DEC-06 自动资料数量收口：装配层取数走 keyEntityAutoCap（默认 10，
  // 与展示层 buildCoreBlocks 的实体 take(10) 对齐）+ 统一稳定排序
  //（importance DESC → updatedAt/updatedTurn 新者在前 → entityId 兜底），
  // 不叠加额外收缩。
  test('DEC-06：关键实体取数走 keyEntityAutoCap + 稳定排序', () async {
    final t = DateTime(2026);
    final factual = FakeFactualRepository()
      ..entitiesById = {
        // 12 个关键实体：默认 cap=10 → 恰取 10
        for (var i = 0; i < 12; i++)
          'e_k$i': _entity('e_k$i', '关键$i', importance: 5),
        // 同分但近期更新：活跃者优先于早创建占位者
        'e_active': _entity(
          'e_active',
          '近期活跃者',
          importance: 5,
          updatedAt: t.add(const Duration(days: 5)),
          updatedTurn: 9,
        ),
        'e_stale': _entity('e_stale', '早创建占位者', importance: 5),
        // importance 更高（_entity 默认 importance=6）：无条件排首
        'e_high': _entity('e_high', '高分静态'),
      };

    final data = await assembleDirectorCoreBlocks(
      factual: factual,
      experienceRepository: _FakeExperienceRepo(const []),
      sessionId: 's1',
      factualConfig: const FactualConfig(),
      narrativeTime: null,
      anchor: null,
    );

    expect(data!.keyEntities, hasLength(10));
    expect(data.keyEntities.first.primaryName, '高分静态');
    expect(data.keyEntities[1].primaryName, '近期活跃者');
    // 12 个同分静态关键实体按 entityId 稳定序占 8 席；
    // 早创建占位者（e_stale，entityId 靠后）被裁
    expect(
      data.keyEntities.map((e) => e.primaryName),
      isNot(contains('早创建占位者')),
    );
    expect(
      data.keyEntities.map((e) => e.primaryName),
      contains('关键0'),
    );
  });

  test('DEC-06：keyEntityAutoCap 可配置覆盖（cap=3）', () async {
    final factual = FakeFactualRepository()
      ..entitiesById = {
        for (var i = 0; i < 8; i++) 'e_$i': _entity('e_$i', '实体$i'),
      };

    final data = await assembleDirectorCoreBlocks(
      factual: factual,
      experienceRepository: _FakeExperienceRepo(const []),
      sessionId: 's1',
      factualConfig: const FactualConfig(keyEntityAutoCap: 3),
      narrativeTime: null,
      anchor: null,
    );

    expect(data!.keyEntities, hasLength(3));
    expect(data.keyEntities.map((e) => e.primaryName), ['实体0', '实体1', '实体2']);
  });

  test('近期活跃动态实体：排除核心与停用/归档，按窗口与活跃轮降序筛选并截断', () async {
    final factual = FakeFactualRepository()
      ..entitiesById = {
        for (var i = 0; i < 10; i++)
          'core_$i': _entity(
            'core_$i',
            '核心$i',
            importance: 5,
            createdTurn: 19,
          ),
        // 静态导入未演化实体：不应入选
        'wb_static': _entity(
          'wb_static',
          '静默世界书',
          importance: 3,
          source: FactualSource.worldbook,
          createdTurn: 19,
        ),
        // 静态导入但近期有演化（updatedTurn != null）：应入选
        'wb_evolved': _entity(
          'wb_evolved',
          '演化世界书',
          importance: 3,
          source: FactualSource.worldbook,
          updatedTurn: 19,
        ),
        // 停用注入与已归档：不应入选
        'disabled': _entity(
          'disabled',
          '停用配角',
          importance: 4,
          injectionDisabled: true,
          createdTurn: 19,
        ),
        'archived': _entity(
          'archived',
          '归档配角',
          importance: 4,
          isArchived: true,
          createdTurn: 19,
        ),
        // 超出 15 轮窗口（currentTurn=20, window=15 → 轮次 4 超窗）
        'stale': _entity(
          'stale',
          '陈旧配角',
          importance: 4,
          createdTurn: 4,
        ),
        // 边界内：turn 5（20 - 5 = 15 <= 15）
        'border': _entity(
          'border',
          '压线配角',
          importance: 2,
          createdTurn: 5,
        ),
        // 两个近期 auto 实体：updatedTurn 优先排序
        'auto_a': _entity(
          'auto_a',
          '配角甲',
          importance: 3,
          type: FactualEntityType.location,
          createdTurn: 10,
          updatedTurn: 18,
        ),
        'auto_b': _entity(
          'auto_b',
          '配角乙',
          importance: 4,
          createdTurn: 16,
        ),
      }
      ..seedAttribute(
        FactualAttribute(
          attributeId: 'attr_hidden',
          entityId: 'auto_a',
          sessionId: 's1',
          attrKey: '位置',
          value: '隐藏细节不应进目录',
          importance: 5,
          createdAt: DateTime(2026),
        ),
      );

    final data = await assembleDirectorCoreBlocks(
      factual: factual,
      experienceRepository: _FakeExperienceRepo(const []),
      sessionId: 's1',
      factualConfig: const FactualConfig(),
      narrativeTime: null,
      anchor: null,
      currentTurn: 20,
      recentActiveEntitiesCap: 3,
    );

    expect(
      data!.recentActiveEntities.map((e) => e.entityId).toList(),
      ['wb_evolved', 'auto_a', 'auto_b'],
    );
    expect(
      data.text,
      contains('【近期活跃动态实体（非核心，按需用 query_facts 查阅）】'),
    );
    expect(data.text, contains('· [wb_evolved] 演化世界书（character｜重要度3）'));
    expect(data.text, contains('· [auto_a] 配角甲（location｜重要度3）'));
    expect(data.text, isNot(contains('隐藏细节不应进目录')));
    expect(data.text, isNot(contains('静默世界书')));
    expect(data.text, isNot(contains('停用配角')));
    expect(data.text, isNot(contains('归档配角')));
    expect(data.text, isNot(contains('陈旧配角')));
  });
}

ExperientialMemory _macro(String summary) => ExperientialMemory(
      memoryId: 'm-${summary.hashCode}',
      sessionId: 's1',
      importance: 5,
      tags: const [],
      turnNumber: 1,
      createdAt: DateTime(2026),
      summary: summary,
      memoryLevel: MemoryLevel.macro,
    );

FactualEntity _entity(
  String id,
  String name, {
  bool injectionDisabled = false,
  bool isArchived = false,
  FactualSource source = FactualSource.auto,
  FactualEntityType type = FactualEntityType.character,
  int importance = 6,
  int createdTurn = 1,
  DateTime? updatedAt,
  int? updatedTurn,
}) =>
    FactualEntity(
      entityId: id,
      sessionId: 's1',
      type: type,
      primaryName: name,
      aliases: const [],
      importance: importance,
      isArchived: isArchived,
      source: source,
      createdTurn: createdTurn,
      createdAt: DateTime(2026),
      injectionDisabled: injectionDisabled,
      updatedAt: updatedAt,
      updatedTurn: updatedTurn,
    );

class _FakeExperienceRepo implements ExperienceRepository {
  _FakeExperienceRepo(this.recent);

  final List<ExperientialMemory> recent;

  @override
  Future<List<ExperientialMemory>> getRecentExperiences(
    String sessionId, {
    required int limit,
    bool includeArchived = false,
  }) async =>
      recent;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
