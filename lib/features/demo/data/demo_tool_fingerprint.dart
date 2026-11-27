import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_round_draft.dart';
import 'package:lmstory/features/advanced/domain/services/agent_session_tools.dart';
import 'package:lmstory/features/advanced/domain/services/agent_story_reader.dart';
import 'package:lmstory/features/advanced/domain/services/agent_subagent.dart';
import 'package:lmstory/features/advanced/domain/services/search_story_text_tool.dart';
import 'package:lmstory/features/demo/domain/demo_pack_fingerprint.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';

/// 演示回合核心工具集蓝图 → 数据包工具指纹。
///
/// 指纹覆盖「演示回放会实际调用的核心工具」的名称与参数 schema
/// （search_story / search_story_text / read_story / query_facts /
/// read_compact_summary / update_facts / merge_entities /
/// update_story_anchor / record_event_memory / finish_round）。
/// 会话级可选工具（read_skill/spawn/ask_user）不在录制调用面内，
/// 不入指纹。工具对象构造仅存依赖引用、不触发任何仓储调用，
/// noSuchMethod 桩因此安全。
///
/// 与真实装配的对账由 `sample_pack_validity_test.dart` 保证：
/// 该测试以真实仓储依赖构建 buildAgentTools 并比对指纹一致。
String computeDemoToolFingerprint() {
  return demoToolFingerprint(demoRoundToolBlueprints());
}

List<ToolDefinition> demoRoundToolBlueprints() {
  final deps = AgentToolDeps(
    sessionId: 'fingerprint-only',
    draft: AgentRoundDraft(turnNumber: 1),
    factualRepository: _NoopFactualRepository(),
    experienceRepository: _NoopExperienceRepository(),
    storyReader: _NoopStoryReader(),
    latestMacros: () async => [],
    userInteraction: _NoopUserInteraction(),
    commitRound: (draft) async => '',
  );
  return agentToolsToDefinitions([
    SearchStoryTool(deps),
    SearchStoryTextTool(reader: deps.storyReader, draft: deps.draft),
    ReadStoryTool(deps),
    QueryFactsTool(deps),
    ReadCompactSummaryTool(deps),
    UpdateFactsTool(deps),
    MergeEntitiesTool(deps),
    UpdateStoryAnchorTool(deps),
    RecordEventMemoryTool(deps),
    FinishRoundTool(deps),
  ]);
}

/// 生产全量工具规范蓝图（直接经由 production buildAgentTools 装配求取，无版本漂移）。
List<ToolDefinition> demoProductionToolBlueprints() {
  final deps = AgentToolDeps(
    sessionId: 'blueprint-only',
    draft: AgentRoundDraft(turnNumber: 1),
    factualRepository: _NoopFactualRepository(),
    experienceRepository: _NoopExperienceRepository(),
    storyReader: _NoopStoryReader(),
    latestMacros: () async => [],
    userInteraction: _NoopUserInteraction(),
    commitRound: (draft) async => '',
    enableAskUser: true,
    loadSkillBody: (name) async => '',
    spawnToolFactory: (readOnlyTools) => SpawnTool(_NoopSubagentRunner()),
  );
  return agentToolsToDefinitions(buildAgentTools(deps));
}

class _NoopSubagentRunner implements SubagentRunner {
  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('blueprint-only stub');
}

class _NoopFactualRepository implements FactualRepository {
  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('fingerprint-only stub');
}

class _NoopExperienceRepository implements ExperienceRepository {
  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('fingerprint-only stub');
}

class _NoopStoryReader implements AgentStoryReader {
  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('fingerprint-only stub');
}

class _NoopUserInteraction implements AgentUserInteractionPort {
  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('fingerprint-only stub');
}
