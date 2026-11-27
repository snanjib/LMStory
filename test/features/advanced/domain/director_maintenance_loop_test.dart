import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_budget.dart';
import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_events.dart';
import 'package:lmstory/core/agent/agent_llm_gateway.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/agent/agent_runner.dart';
import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/llm/tool_calling/provider_tool_capabilities.dart';
import 'package:lmstory/core/network/http_client.dart';
import 'package:lmstory/core/network/llm_adapters/llm_adapter_factory.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/advanced/data/engineering_compaction_service.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/domain/entities/director_round_tuning.dart';
import 'package:lmstory/features/advanced/domain/services/agent_event_bus.dart';
import 'package:lmstory/features/advanced/domain/services/agent_log_recovery.dart';
import 'package:lmstory/features/advanced/presentation/controllers/director_host.dart';
import 'package:lmstory/features/advanced/presentation/controllers/director_round_runner.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/datasources/llm_remote_datasource.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session_settings.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';
import 'package:lmstory/features/memory/data/repositories/factual_repository_impl.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_context.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_runtime_config.dart';
import 'package:lmstory/features/story_runtime/domain/services/compaction_service.dart';
import 'package:lmstory/i18n/strings.g.dart';

class _ScriptedGateway implements AgentLlmGateway {
  _ScriptedGateway(this.steps);

  final List<AgentStepResponse> steps;
  final List<AgentStepRequest> requests = [];
  int cursor = 0;

  @override
  Future<AgentStepResponse> completeStep({
    required AgentModelEndpoint endpoint,
    required AgentStepRequest request,
    required AgentCancellationToken cancellation,
    void Function(String delta)? onTextDelta,
    void Function(String delta)? onThinkingDelta,
    void Function(String toolCallId, String toolName, String delta)?
        onToolArgDelta,
  }) async {
    cancellation.throwIfCancelled('before_step');
    requests.add(request);
    if (cursor >= steps.length) {
      return const AgentStepResponse(text: '确认结束。', toolCalls: []);
    }
    return steps[cursor++];
  }
}

class _PhaseTransitionTool implements AgentTool {
  _PhaseTransitionTool(this.extraDelta, {this.notice});

  final int extraDelta;
  final String? notice;

  @override
  String get name => 'finish_round';

  @override
  String get description => 'transition tool';

  @override
  AgentToolPermission get permission => AgentToolPermission.control;

  @override
  Map<String, dynamic> buildParametersSchema() => const {
        'type': 'object',
        'properties': {
          'prose': {'type': 'string'},
        },
      };

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    return AgentToolResult.success(
      title: '切换维护阶段',
      output: '任务一已完成，进入维护阶段。',
      extraMaxStepsDelta: extraDelta,
      phaseSoftLandingNotice: notice,
    );
  }
}

class _NoopTool implements AgentTool {
  _NoopTool(this.name);

  @override
  final String name;

  @override
  String get description => name;

  @override
  AgentToolPermission get permission => AgentToolPermission.readOnly;

  @override
  Map<String, dynamic> buildParametersSchema() => const {'type': 'object'};

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async =>
      AgentToolResult.success(title: name, output: 'ok');
}

class _RecordingSseClient implements HttpClient {
  _RecordingSseClient(this.handlers);

  final List<Stream<String> Function(int callIndex, Map<String, dynamic> body)>
      handlers;
  final List<Map<String, dynamic>> bodies = [];
  int _callCount = 0;

  @override
  Stream<String> streamPost(
    String url,
    Map<String, String> headers, {
    String? body,
    Encoding encoding = utf8,
    CancellationToken? cancelToken,
    Duration? connectTimeout,
    Duration? readTimeout,
    Duration? responseStartTimeout,
  }) {
    final decoded = body == null
        ? <String, dynamic>{}
        : jsonDecode(body) as Map<String, dynamic>;
    bodies.add(decoded);
    final index = _callCount++;
    return handlers[index](index, decoded);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

String _sseToolCall(String id, String name, Map<String, dynamic> args) {
  final frames = [
    '{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"$id","type":"function","function":{"name":"$name","arguments":${jsonEncode(jsonEncode(args))}}}]},"finish_reason":null}]}',
    '{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}',
    '[DONE]',
  ];
  return frames.map((j) => 'data: $j\n\n').join();
}

class _LoopTestHost implements DirectorHost {
  _LoopTestHost({
    required this.llmService,
    required this.experienceRepository,
    required this.factualRepository,
    required this.artifacts,
    required ChatSession session,
  }) : storyState = AdvancedChatState.initial(session);

  @override
  AdvancedChatState storyState;

  @override
  RoundContext? currentRound;

  @override
  bool isStreamCancelled = false;

  @override
  final Logger logger = const Logger('loop-test');

  @override
  final LlmService llmService;

  @override
  ProviderToolCapabilities? get capabilitiesOverride => null;

  @override
  final ExperienceRepository experienceRepository;

  @override
  final FactualRepository factualRepository;

  @override
  AgentEventLogStore? get agentEventLogRepository => null;

  @override
  EngineeringCompactionService? get engineeringCompactionService => null;

  @override
  StoryCompactionService? get compactionService => null;

  final Map<int, StoryRoundArtifacts> artifacts;
  final List<RoundContext> persistedRounds = [];
  bool failCalled = false;

  @override
  Future<void> failRound(
    IntermediatePhase phase,
    String errorCode, {
    Object? error,
    ErrorCategory? errorCategory,
    StoryRuntimeConfig? config,
  }) async {
    failCalled = true;
  }

  @override
  Future<void> runPersistPhase(RoundContext round) async {
    persistedRounds.add(round);
  }

  @override
  Future<Float32List?> resolveQueryVector(String queryText) async => null;

  @override
  Future<List<ChatMessage>> loadSessionMessages(String sessionId) async =>
      const [];

  @override
  Future<Map<int, StoryRoundArtifacts>> loadSessionArtifacts(
    String sessionId,
  ) async =>
      artifacts;
}

RoundContext _buildRoundContext(int turnNumber, {String userInput = '继续推进'}) {
  const naming = NamingConfig(
    baseUrl: 'https://api.openai.com/v1',
    apiKey: 'k',
    modelId: 'test-model',
    presetId: 'test-preset',
  );
  final round = RoundContext(
    turnNumber: turnNumber,
    userInput: userInput,
    history: const [],
    settings: const ChatSessionSettings(
      modelId: 'test-model',
      presetId: 'test-preset',
      systemPrompt: '世界观设定。',
      temperature: 0.7,
      topP: 0.9,
      maxTokens: 2048,
      autoCompaction: true,
      compactionThreshold: 0.6,
      streamEnabled: true,
      reasoningEffort: ReasoningEffort.disabled,
    ),
    generatingNamingConfig: naming,
    extractNamingConfig: naming,
    reviewingNamingConfig: naming,
    summarizeNamingConfig: naming,
    embeddingConfig: null,
    config: const AdvancedConfig().storyRuntime,
    contextWindow: 32000,
    connectTimeout: const Duration(seconds: 10),
    readTimeout: const Duration(seconds: 10),
  );
  return round;
}

StoryRoundArtifacts _artifactWithTools(
  int turn,
  List<String> toolNames, {
  AgentWorkSummary? summary,
}) {
  return StoryRoundArtifacts(
    sessionId: 'sess-maint',
    turnNumber: turn,
    createdAt: DateTime(2026),
    agentSteps: [
      for (final name in toolNames) AgentWorkStep(toolName: name),
    ],
    agentWorkSummary: summary,
  );
}

void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  group('AgentRunner 动态步数扩展与阶段感知软着陆', () {
    const endpoint = AgentModelEndpoint(
      baseUrl: 'https://api.openai.com/v1',
      modelId: 'm',
      protocol: 'openaiCompatible',
    );

    test('非终结工具返回 extraMaxStepsDelta 时原地扩容，到达新上限后注入维护软着陆通牒', () async {
      final gateway = _ScriptedGateway([
        // step 1: 阶段切换（maxSteps 原为 2 → 扩至 4）
        const AgentStepResponse(
          text: '',
          toolCalls: [
            AgentToolCall(
              id: 'c1',
              name: 'finish_round',
              arguments: {'prose': '锁定正文'},
            ),
          ],
        ),
        // step 2: 维护查询
        const AgentStepResponse(
          text: '',
          toolCalls: [
            AgentToolCall(id: 'c2', name: 'list_facts', arguments: {}),
          ],
        ),
        // step 3: 继续查询，结束后 steps=3 < 4 仍继续
        const AgentStepResponse(
          text: '',
          toolCalls: [
            AgentToolCall(id: 'c3', name: 'list_facts', arguments: {}),
          ],
        ),
        // step 4: 再次查询，结束后 steps=4 >= 4 触发阶段感知软着陆
        const AgentStepResponse(
          text: '',
          toolCalls: [
            AgentToolCall(id: 'c4', name: 'list_facts', arguments: {}),
          ],
        ),
        // step 5: 收到维护通牒后的纯文本简短确认
        const AgentStepResponse(text: '维护确认完毕。', toolCalls: []),
      ]);

      final sink = BufferingAgentEventSink();
      final result = await AgentRunner(gateway: gateway).runTurn(
        AgentTurnSpec(
          sessionId: 's1',
          surface: [AgentMessage.user('开始')],
          tools: [
            _PhaseTransitionTool(
              2,
              notice: '维护预算已达上限，请调用 finish_maintenance 或简短确认收尾。',
            ),
            _NoopTool('list_facts'),
          ],
          endpoint: endpoint,
          budget: const AgentBudget(maxSteps: 2),
          events: sink,
          cancellation: AgentCancellationToken(),
        ),
      );

      expect(result.reason, AgentStopReason.completed);
      expect(result.steps, 5);
      // 最后一次请求（step 5）收到了维护专属通牒，且不含“叙事正文”催促
      final lastMessages = gateway.requests.last.messages;
      final injected = lastMessages.last['content'] as String;
      expect(injected, contains('finish_maintenance'));
      expect(injected, isNot(contains('叙事正文')));
    });

    test('原始 maxSteps=0（无限步）在 extraMaxStepsDelta > 0 时保持 0', () async {
      final gateway = _ScriptedGateway([
        const AgentStepResponse(
          text: '',
          toolCalls: [
            AgentToolCall(
              id: 'c1',
              name: 'finish_round',
              arguments: {'prose': '锁定正文'},
            ),
          ],
        ),
        const AgentStepResponse(text: '维护完成。', toolCalls: []),
      ]);
      final result = await AgentRunner(gateway: gateway).runTurn(
        AgentTurnSpec(
          sessionId: 's1',
          surface: [AgentMessage.user('开始')],
          tools: [
            _PhaseTransitionTool(6, notice: '维护通牒'),
          ],
          endpoint: endpoint,
          budget: const AgentBudget(maxSteps: 0),
          events: BufferingAgentEventSink(),
          cancellation: AgentCancellationToken(),
        ),
      );

      expect(result.reason, AgentStopReason.completed);
      expect(result.steps, 2);
      // 没有错误触发 maxSteps 软着陆
      expect(
        gateway.requests.last.messages.any(
          (m) => (m['content']?.toString() ?? '').contains('维护通牒'),
        ),
        isFalse,
      );
    });
  });

  group('DirectorRoundRunner 长会话 7/50 调度、双任务、取消保正文与叙事时间', () {
    late AppDatabase db;
    late FactualRepositoryImpl factualRepo;
    late ExperienceRepositoryImpl experienceRepo;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      factualRepo = FactualRepositoryImpl(database: db);
      experienceRepo = ExperienceRepositoryImpl(
        database: db,
        vectorEngine: const VectorEngine(),
      );
    });

    tearDown(() async => db.close());

    ChatSession makeSession({int nextTurn = 8}) => ChatSession(
          sessionId: 'sess-maint',
          title: '维护测试',
          mode: 'advanced',
          nextTurn: nextTurn,
          createdAt: DateTime(2026),
          lastActiveAt: DateTime(2026),
          messageCount: 0,
        );

    test('第 8 轮存在 7 轮缺口时注入轻量提醒并记录 maintenanceNudgeIssued', () async {
      final artifacts = <int, StoryRoundArtifacts>{
        for (var i = 1; i <= 7; i++)
          i: _artifactWithTools(i, const ['search_story']),
      };
      final sse = _RecordingSseClient([
        (_, __) => Stream.value(
              _sseToolCall('c1', 'record_event_memory', {
                'what': '推进一幕',
                'importance': 3,
              }),
            ),
        (_, __) => Stream.value(
              _sseToolCall('c2', 'finish_round', {'prose': '第八轮正文内容。'}),
            ),
      ]);
      final host = _LoopTestHost(
        llmService: LlmRemoteDataSource(
          httpClient: sse,
          adapterFactory: LlmAdapterFactory(),
        ),
        experienceRepository: experienceRepo,
        factualRepository: factualRepo,
        artifacts: artifacts,
        session: makeSession(),
      );
      final runner = DirectorRoundRunner(host: host);
      final round = _buildRoundContext(8);
      host.currentRound = round;

      await runner.runRound(
        round,
        tuning: DirectorRoundTuning.fromConfig(const AdvancedConfig()),
      );

      expect(host.persistedRounds, hasLength(1));
      final firstMessages = sse.bodies.first['messages'] as List<dynamic>;
      final tailText = firstMessages.map((m) => m.toString()).join('\n');
      expect(tailText, contains('【维护提醒】'));
      expect(tailText, contains('update_facts'));
      expect(host.storyState.agentWorkSummary?.maintenanceNudgeIssued, isTrue);
      expect(host.storyState.agentWorkSummary?.majorReviewCompleted, isFalse);
    });

    test('第 50 轮大周期抑制小提示，完成任务一→任务二双阶段接力并原子提交', () async {
      await factualRepo.createEntity(
        FactualEntity(
          entityId: 'ent_side',
          sessionId: 'sess-maint',
          type: FactualEntityType.character,
          primaryName: '顾沉舟',
          aliases: const [],
          importance: 2,
          createdTurn: 3,
          createdAt: DateTime(2026),
        ),
      );

      final artifacts = <int, StoryRoundArtifacts>{
        for (var i = 1; i <= 49; i++)
          i: _artifactWithTools(i, const ['search_story']),
      };
      var capturedInMaint = false;
      var capturedStepStart = -1;
      var capturedExpandedMaxSteps = -1;

      final sse = _RecordingSseClient([
        // Step 1 (writing): 记事件
        (_, __) => Stream.value(
              _sseToolCall('c1', 'record_event_memory', {
                'what': '关键人物登场',
                'importance': 4,
              }),
            ),
        // Step 2 (writing): finish_round 锁定正文并切入 maintenance
        (_, __) => Stream.value(
              _sseToolCall('c2', 'finish_round', {'prose': '第五十轮锁定正文。'}),
            ),
        // Step 3 (maintenance): list_facts
        (_, __) => Stream.value(_sseToolCall('c3', 'list_facts', {})),
        // Step 4 (maintenance): set_importance + finish_maintenance
        (_, __) => Stream.value(
              _sseToolCall('c4', 'update_facts', {
                'deltas': [
                  {
                    'action': 'set_importance',
                    'entity_id': 'ent_side',
                    'importance': 5,
                    'confidence': 5,
                    'reason': '晋升核心角色',
                  },
                ],
              }),
            ),
        // Step 5 (maintenance): finish_maintenance
        (_, __) => Stream.value(_sseToolCall('c5', 'finish_maintenance', {})),
      ]);

      final host = _LoopTestHost(
        llmService: LlmRemoteDataSource(
          httpClient: sse,
          adapterFactory: LlmAdapterFactory(),
        ),
        experienceRepository: experienceRepo,
        factualRepository: factualRepo,
        artifacts: artifacts,
        session: makeSession(nextTurn: 50),
      );
      final runner = DirectorRoundRunner(host: host);

      // 包装 sse 第 3 步以抓取进入任务二时的实时 state
      final originalStep3 = sse.handlers[2];
      sse.handlers[2] = (idx, body) {
        capturedInMaint = host.storyState.inMaintenancePhase;
        capturedStepStart = host.storyState.maintenanceStepStart;
        capturedExpandedMaxSteps =
            host.storyState.agentRoundProgress?.maxSteps ?? -1;
        return originalStep3(idx, body);
      };

      final round = _buildRoundContext(50);
      host.currentRound = round;

      await runner.runRound(
        round,
        tuning: DirectorRoundTuning.fromConfig(const AdvancedConfig()),
      );

      // 大周期抑制 7 轮小提示，保留契约预告
      final step1Tail = (sse.bodies.first['messages'] as List<dynamic>)
          .map((m) => m.toString())
          .join('\n');
      expect(step1Tail, isNot(contains('【维护提醒】')));
      expect(step1Tail, contains('finish_maintenance'));

      // 任务一交稿后进入任务二，UI 隔离状态与扩展步数准确更新
      expect(capturedInMaint, isTrue);
      expect(capturedStepStart, 2); // record_event_memory + finish_round
      expect(capturedExpandedMaxSteps, 8 + 6);

      // 落库产物：正文锁定、任务二更新包含在内、状态重置
      expect(host.persistedRounds, hasLength(1));
      final persisted = host.persistedRounds.single;
      expect(persisted.replyText, '第五十轮锁定正文。');
      expect(persisted.factsDeltas, isNotNull);
      expect(persisted.factsDeltas!.single.action, FactAction.setImportance);
      expect(persisted.factsDeltas!.single.skipFrequencyGuard, isTrue);
      expect(host.storyState.agentWorkSummary?.majorReviewCompleted, isTrue);
      expect(host.storyState.agentWorkSummary?.maintenanceNudgeIssued, isFalse);
      expect(host.storyState.inMaintenancePhase, isFalse);
      expect(host.storyState.maintenanceStepStart, 0);
    });

    test('任务二期间取消：跳过剩余维护并保住任务一锁定正文落库', () async {
      final artifacts = <int, StoryRoundArtifacts>{
        for (var i = 1; i <= 49; i++)
          i: _artifactWithTools(i, const ['search_story']),
      };
      late DirectorRoundRunner runner;
      final sse = _RecordingSseClient([
        (_, __) => Stream.value(
              _sseToolCall('c1', 'record_event_memory', {
                'what': '冲突爆发',
                'importance': 4,
              }),
            ),
        (_, __) => Stream.value(
              _sseToolCall('c2', 'finish_round', {'prose': '任务一已锁定的完整正文。'}),
            ),
        (_, __) {
          // 进入任务二后用户在请求 list_facts 时点取消
          runner.cancelRound('用户停止');
          return Stream.value(_sseToolCall('c3', 'list_facts', {}));
        },
      ]);
      final host = _LoopTestHost(
        llmService: LlmRemoteDataSource(
          httpClient: sse,
          adapterFactory: LlmAdapterFactory(),
        ),
        experienceRepository: experienceRepo,
        factualRepository: factualRepo,
        artifacts: artifacts,
        session: makeSession(nextTurn: 50),
      );
      runner = DirectorRoundRunner(host: host);
      final round = _buildRoundContext(50);
      host.currentRound = round;

      await runner.runRound(
        round,
        tuning: DirectorRoundTuning.fromConfig(const AdvancedConfig()),
      );

      expect(host.persistedRounds, hasLength(1));
      expect(host.persistedRounds.single.replyText, '任务一已锁定的完整正文。');
      expect(host.storyState.agentWorkSummary?.deliveryChannel, 'tool_args');
      expect(host.storyState.inMaintenancePhase, isFalse);
    });

    test('narrative_time 回填：update_story_anchor 的时间锚自动同步到 eventSummary（含兜底事件）',
        () async {
      // 场景 1：仅调 update_story_anchor，未调 record_event_memory → 兜底 EventSummary 获回填
      final sseFallback = _RecordingSseClient([
        (_, __) => Stream.value(
              _sseToolCall('c1', 'update_story_anchor', {
                'narrative_time': '第三日黄昏',
              }),
            ),
        (_, __) => Stream.value(
              _sseToolCall('c2', 'finish_round', {'prose': '第一轮正文。'}),
            ),
        (_, __) => Stream.value(
              _sseToolCall('c3', 'finish_round', {'prose': '第一轮正文。'}),
            ),
      ]);
      final host1 = _LoopTestHost(
        llmService: LlmRemoteDataSource(
          httpClient: sseFallback,
          adapterFactory: LlmAdapterFactory(),
        ),
        experienceRepository: experienceRepo,
        factualRepository: factualRepo,
        artifacts: const {},
        session: makeSession(nextTurn: 1),
      );
      final round1 = _buildRoundContext(1);
      host1.currentRound = round1;
      await DirectorRoundRunner(host: host1).runRound(round1);

      expect(host1.persistedRounds, hasLength(1));
      expect(host1.persistedRounds.single.eventSummary?.narrativeTime, '第三日黄昏');

      // 场景 2：同时调 update_story_anchor + record_event_memory → 事件摘要同样获回填
      final sseBoth = _RecordingSseClient([
        (_, __) => Stream.value(
              _sseToolCall('c1', 'update_story_anchor', {
                'narrative_time': '第四日破晓',
              }),
            ),
        (_, __) => Stream.value(
              _sseToolCall('c2', 'record_event_memory', {
                'what': '抵达渡口',
                'importance': 4,
              }),
            ),
        (_, __) => Stream.value(
              _sseToolCall('c3', 'finish_round', {'prose': '第二轮正文。'}),
            ),
      ]);
      final host2 = _LoopTestHost(
        llmService: LlmRemoteDataSource(
          httpClient: sseBoth,
          adapterFactory: LlmAdapterFactory(),
        ),
        experienceRepository: experienceRepo,
        factualRepository: factualRepo,
        artifacts: const {},
        session: makeSession(nextTurn: 2),
      );
      final round2 = _buildRoundContext(2);
      host2.currentRound = round2;
      await DirectorRoundRunner(host: host2).runRound(round2);

      expect(host2.persistedRounds, hasLength(1));
      expect(host2.persistedRounds.single.eventSummary?.what, '抵达渡口');
      expect(host2.persistedRounds.single.eventSummary?.narrativeTime, '第四日破晓');
    });

    test('update_facts 部分失败时拦截直接交卷，修正补发后放行提交全部变更', () async {
      await factualRepo.createEntity(
        FactualEntity(
          entityId: 'ent_a',
          sessionId: 'sess-maint',
          type: FactualEntityType.character,
          primaryName: '林晚',
          aliases: const [],
          importance: 4,
          createdTurn: 1,
          createdAt: DateTime(2026),
        ),
      );
      await factualRepo.createEntity(
        FactualEntity(
          entityId: 'ent_b',
          sessionId: 'sess-maint',
          type: FactualEntityType.character,
          primaryName: '顾沉舟',
          aliases: const [],
          importance: 2,
          createdTurn: 1,
          createdAt: DateTime(2026),
        ),
      );

      final sse = _RecordingSseClient([
        // Step 1: 1 条合法 + 1 条缺 confidence
        (_, __) => Stream.value(
              _sseToolCall('c1', 'update_facts', {
                'deltas': [
                  {
                    'action': 'set_importance',
                    'entity_id': 'ent_a',
                    'importance': 5,
                    'confidence': 5,
                  },
                  {
                    'action': 'set_importance',
                    'entity_id': 'ent_b',
                    'importance': 4,
                  },
                ],
              }),
            ),
        // Step 2: 模型忽略报错尝试直接 finish_round → 被 Runner 守卫拦截
        (_, __) => Stream.value(
              _sseToolCall('c2', 'finish_round', {'prose': '第五轮正文。'}),
            ),
        // Step 3: 模型补发修正后的失败条目
        (_, __) => Stream.value(
              _sseToolCall('c3', 'update_facts', {
                'deltas': [
                  {
                    'action': 'set_importance',
                    'entity_id': 'ent_b',
                    'importance': 4,
                    'confidence': 4,
                  },
                ],
              }),
            ),
        // Step 4: 记事件
        (_, __) => Stream.value(
              _sseToolCall('c4', 'record_event_memory', {
                'what': '并肩查案',
                'importance': 4,
              }),
            ),
        // Step 5: 再次 finish_round → 放行提交全部 2 条
        (_, __) => Stream.value(
              _sseToolCall('c5', 'finish_round', {'prose': '第五轮正文。'}),
            ),
      ]);

      final host = _LoopTestHost(
        llmService: LlmRemoteDataSource(
          httpClient: sse,
          adapterFactory: LlmAdapterFactory(),
        ),
        experienceRepository: experienceRepo,
        factualRepository: factualRepo,
        artifacts: const {},
        session: makeSession(nextTurn: 5),
      );
      final round = _buildRoundContext(5);
      host.currentRound = round;

      await DirectorRoundRunner(host: host).runRound(round);

      // Step 2 请求中携带了 update_facts 的 [TOOL_ERROR] 信号
      final step2Messages = sse.bodies[1]['messages'] as List<dynamic>;
      expect(
        step2Messages.any(
          (m) =>
              m is Map &&
              m['role'] == 'tool' &&
              (m['content']?.toString() ?? '').startsWith('[TOOL_ERROR] '),
        ),
        isTrue,
      );
      // Step 3 请求中携带了 finish_round 被前置守卫拦截的报错回执
      final step3Messages = sse.bodies[2]['messages'] as List<dynamic>;
      expect(
        step3Messages.any(
          (m) =>
              m is Map &&
              m['role'] == 'tool' &&
              (m['content']?.toString() ?? '').contains('update_facts'),
        ),
        isTrue,
      );

      expect(host.persistedRounds, hasLength(1));
      final persisted = host.persistedRounds.single;
      expect(persisted.replyText, '第五轮正文。');
      expect(persisted.factsDeltas, hasLength(2));
      expect(
        persisted.factsDeltas!.map((d) => d.entityId).toList(),
        ['ent_a', 'ent_b'],
      );
    });

    test('第 50 轮维护阶段 update_facts 失败时拦截 finish_maintenance，修正后一次完成', () async {
      await factualRepo.createEntity(
        FactualEntity(
          entityId: 'ent_side',
          sessionId: 'sess-maint',
          type: FactualEntityType.character,
          primaryName: '顾沉舟',
          aliases: const [],
          importance: 2,
          createdTurn: 3,
          createdAt: DateTime(2026),
        ),
      );
      final artifacts = <int, StoryRoundArtifacts>{
        for (var i = 1; i <= 49; i++)
          i: _artifactWithTools(i, const ['search_story']),
      };

      final sse = _RecordingSseClient([
        (_, __) => Stream.value(
              _sseToolCall('c1', 'record_event_memory', {
                'what': '大周期转折',
                'importance': 4,
              }),
            ),
        (_, __) => Stream.value(
              _sseToolCall('c2', 'finish_round', {'prose': '第五十轮正文。'}),
            ),
        // 维护阶段：缺 confidence 失败
        (_, __) => Stream.value(
              _sseToolCall('c3', 'update_facts', {
                'deltas': [
                  {
                    'action': 'set_importance',
                    'entity_id': 'ent_side',
                    'importance': 5,
                  },
                ],
              }),
            ),
        // 忽略失败直接调用 finish_maintenance → 被前置守卫拦截
        (_, __) => Stream.value(_sseToolCall('c4', 'finish_maintenance', {})),
        // 修正重调 update_facts
        (_, __) => Stream.value(
              _sseToolCall('c5', 'update_facts', {
                'deltas': [
                  {
                    'action': 'set_importance',
                    'entity_id': 'ent_side',
                    'importance': 5,
                    'confidence': 5,
                  },
                ],
              }),
            ),
        // 再次调用 finish_maintenance({}) → 不触发 doom-loop，成功提交
        (_, __) => Stream.value(_sseToolCall('c6', 'finish_maintenance', {})),
      ]);

      final host = _LoopTestHost(
        llmService: LlmRemoteDataSource(
          httpClient: sse,
          adapterFactory: LlmAdapterFactory(),
        ),
        experienceRepository: experienceRepo,
        factualRepository: factualRepo,
        artifacts: artifacts,
        session: makeSession(nextTurn: 50),
      );
      final round = _buildRoundContext(50);
      host.currentRound = round;

      await DirectorRoundRunner(host: host).runRound(
        round,
        tuning: DirectorRoundTuning.fromConfig(const AdvancedConfig()),
      );

      expect(host.persistedRounds, hasLength(1));
      final persisted = host.persistedRounds.single;
      expect(persisted.replyText, '第五十轮正文。');
      expect(persisted.factsDeltas, hasLength(1));
      expect(persisted.factsDeltas!.single.entityId, 'ent_side');
      expect(persisted.factsDeltas!.single.importance, 5);
      expect(host.storyState.agentWorkSummary?.majorReviewCompleted, isTrue);
    });
  });
}
