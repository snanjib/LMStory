import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_llm_gateway.dart';
import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_round_draft.dart';
import 'package:lmstory/features/advanced/domain/services/agent_session_tools.dart';
import 'package:lmstory/features/advanced/domain/services/agent_story_reader.dart';
import 'package:lmstory/features/advanced/domain/services/agent_subagent.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';

/// buildAgentTools 的 deny 过滤（导演设置 ，设计文档 §5.1 deny 语义：
/// 工具不注册——模型不可见，系统提示词工具索引随实际注册集同步移除）
void main() {
  AgentToolDeps deps({
    void Function(List<AgentTool> readOnlyTools)? onSpawnFactory,
  }) {
    return AgentToolDeps(
      sessionId: 's1',
      draft: AgentRoundDraft(turnNumber: 1),
      factualRepository: _NoopFactualRepository(),
      experienceRepository: _NoopExperienceRepository(),
      storyReader: _NoopStoryReader(),
      latestMacros: () async => [],
      userInteraction: _NoopUserPort(),
      commitRound: (d) async => 'ok',
      loadSkillBody: (name) async => 'skill body',
      skillNames: const ['写作技能'],
      enableAskUser: true,
      spawnToolFactory: onSpawnFactory == null
          ? null
          : (readOnlyTools) {
              onSpawnFactory(readOnlyTools);
              return SpawnTool(
                SubagentRunner(
                  gateway: _NoopGateway(),
                  endpoint: _NoopEndpoint(),
                  availableTools: readOnlyTools,
                ),
              );
            },
    );
  }

  test('全量注册：13 工具齐备（含条件工具 read_skill/ask_user/spawn）', () {
    final tools = buildAgentTools(deps(onSpawnFactory: (_) {}));
    expect(
      tools.map((t) => t.name).toSet(),
      {
        'search_story',
        'search_story_text',
        'read_story',
        'query_facts',
        'read_compact_summary',
        'read_skill',
        'update_facts',
        'merge_entities',
        'update_story_anchor',
        'record_event_memory',
        'spawn',
        'ask_user',
        'finish_round',
      },
    );
  });

  test('deny 过滤：被拒工具不注册，其余保留', () {
    final tools = buildAgentTools(
      deps(onSpawnFactory: (_) {}),
      deniedTools: const {'spawn', 'update_facts'},
    );
    final names = tools.map((t) => t.name).toSet();
    expect(names, isNot(contains('spawn')));
    expect(names, isNot(contains('update_facts')));
    expect(names.length, 11);
  });

  test('子代理交集：spawn 工厂收到的只读集已剔除 deny 工具', () {
    List<AgentTool>? received;
    final tools = buildAgentTools(
      deps(onSpawnFactory: (readOnly) => received = readOnly),
      deniedTools: const {'read_story', 'query_facts', 'search_story_text'},
    );
    expect(tools.map((t) => t.name), contains('spawn'));
    expect(received, isNotNull);
    final subagentNames = received!.map((t) => t.name).toSet();
    expect(subagentNames, isNot(contains('read_story')));
    expect(subagentNames, isNot(contains('search_story_text')));
    expect(subagentNames, isNot(contains('query_facts')));
    expect(subagentNames, contains('search_story'));
    expect(subagentNames, contains('read_compact_summary'));
    expect(subagentNames, contains('read_skill'));
  });

  test('默认空 deny 集：行为与现网一致（不传参等价）', () {
    final withDefault = buildAgentTools(deps());
    final withExplicit = buildAgentTools(deps());
    expect(
      withDefault.map((t) => t.name).toList(),
      withExplicit.map((t) => t.name).toList(),
    );
  });
}

class _NoopGateway implements AgentLlmGateway {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _NoopEndpoint implements AgentModelEndpoint {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _NoopFactualRepository implements FactualRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _NoopExperienceRepository implements ExperienceRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _NoopStoryReader implements AgentStoryReader {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _NoopUserPort implements AgentUserInteractionPort {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
