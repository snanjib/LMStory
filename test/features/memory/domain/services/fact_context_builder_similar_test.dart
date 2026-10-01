import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/services/fact_context_builder.dart';

import '../../../../helpers/fake_factual_repository.dart';

/// 疑似重复候选扫描（口径与 applier 创建侧警告一致）
void main() {
  late FakeFactualRepository repo;
  late FactContextBuilder builder;

  setUp(() {
    repo = FakeFactualRepository();
    builder = FactContextBuilder(repository: repo);
  });

  FactualEntity entity(
    String id,
    String name, {
    List<String> aliases = const [],
  }) =>
      FactualEntity(
        entityId: id,
        sessionId: 's1',
        type: FactualEntityType.character,
        primaryName: name,
        aliases: aliases,
        importance: 3,
        createdTurn: 1,
        createdAt: DateTime(2026),
      );

  test('创建名与既有主名互为包含 → 候选命中（entityId 供归并预选）', () async {
    repo.entitiesById = {
      'e-1': entity('e-1', '边境庄园'),
    };

    final candidates = await builder.findSimilarNameCandidates('s1', ['庄园']);

    expect(candidates, hasLength(1));
    expect(candidates.single.newName, '庄园');
    expect(candidates.single.similarEntityIds, ['e-1']);
    expect(candidates.single.displayNames.single, contains('边境庄园'));
  });

  test('别名也参与比对（命中既有别名）', () async {
    repo.entitiesById = {
      'e-1': entity('e-1', '守碑人', aliases: ['碑翁']),
    };

    final candidates = await builder.findSimilarNameCandidates('s1', ['老碑翁']);

    expect(candidates, hasLength(1));
    expect(candidates.single.similarEntityIds, ['e-1']);
  });

  test('无关名称/单字符包含/完全同名均不命中', () async {
    repo.entitiesById = {
      'e-1': entity('e-1', '边境庄园'),
      'e-2': entity('e-2', '剑'),
      'e-3': entity('e-3', '王国'),
    };

    final candidates = await builder.findSimilarNameCandidates(
      's1',
      ['王国', '长剑', '毫不相关'],
    );

    expect(candidates, isEmpty, reason: '同名=同一实体不算疑似；单字符包含无区分价值；无关名不命中');
  });

  test('多实体命中同一创建名 → 全部进预选集', () async {
    repo.entitiesById = {
      'e-1': entity('e-1', '边境庄园'),
      'e-2': entity('e-2', '庄园旧址'),
    };

    final candidates = await builder.findSimilarNameCandidates('s1', ['庄园']);

    expect(candidates.single.similarEntityIds, containsAll(['e-1', 'e-2']));
  });

  test('仓库异常 → 返回空列表（不阻塞主流程）', () async {
    final throwing = _ThrowingRepo();
    final b = FactContextBuilder(repository: throwing);
    expect(
      await b.findSimilarNameCandidates('s1', ['x']),
      isEmpty,
    );
  });
}

class _ThrowingRepo extends FakeFactualRepository {
  @override
  Future<List<FactualEntity>> getEntities(
    String sessionId, {
    bool includeArchived = false,
  }) =>
      throw Exception('db locked');
}
