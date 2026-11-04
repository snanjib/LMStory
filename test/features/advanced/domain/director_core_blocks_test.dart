import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/features/advanced/domain/services/agent_system_prompt.dart';
import 'package:lmstory/features/advanced/domain/services/director_core_blocks.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/factual_attribute.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
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
}) =>
    FactualEntity(
      entityId: id,
      sessionId: 's1',
      type: FactualEntityType.character,
      primaryName: name,
      aliases: const [],
      importance: 6,
      createdTurn: 1,
      createdAt: DateTime(2026),
      injectionDisabled: injectionDisabled,
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
