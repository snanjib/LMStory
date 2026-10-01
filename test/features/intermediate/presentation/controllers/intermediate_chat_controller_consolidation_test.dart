import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/network/http_client.dart';
import 'package:lmstory/core/network/llm_adapters/llm_adapter_factory.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/features/chat/data/datasources/llm_remote_datasource.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session_settings.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/intermediate/domain/entities/intermediate_chat_state.dart';
import 'package:lmstory/features/intermediate/presentation/controllers/intermediate_chat_controller.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/scored_memory.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/services/embedding_service.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/story_runtime/domain/entities/message_variant_record.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/services/memory_consolidator.dart';
import 'package:lmstory/features/story_runtime/domain/services/persistence_service.dart';
import '../../../../test_helpers/stub_failure_log_repository.dart';

/// IntermediateChatController 批量记忆提炼触发测试
///
/// 验证 controller 中 `_maybeConsolidateMemories` 的触发逻辑：
/// - 条件满足（usageRatio > threshold + 未索引记忆数 >= min）→ 触发合并
/// - 条件不满足（threshold 高 / 未索引记忆不足 / 重新生成场景 / consolidator 为 null）→ 不触发
///
/// 由于 `_maybeConsolidateMemories` 是 `unawaited` 调用，使用 `_RecordingConsolidator`
/// 内置 `Completer` 等待异步触发完成后再断言。
void main() {
  group('IntermediateChatController - 批量记忆提炼触发', () {
    test('1. 条件满足 → 触发 consolidator + persistConsolidatedMemories', () async {
      final httpClient = _SseHttpClient(_v2SuccessResponses());
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepositoryWithUnindexed(
        unindexedMemories: _buildUnindexedMemories(count: 3),
      );
      final persistenceService = _RecordingPersistenceService();
      final consolidator = _RecordingConsolidator(
        returnValue: [
          const ConsolidatedMemory(
            summary: '合并后的剧情节点',
            tags: ['古碑'],
            importance: 4,
          ),
        ],
      );
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        consolidator: consolidator,
        config: _triggerConfig(),
      );

      await controller.sendMessage('勇者前往后山');

      // 等待 unawaited 的 persistConsolidatedMemories 被调用
      await persistenceService.waitForPersistCall(
        timeout: const Duration(seconds: 5),
      );

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(consolidator.calls, hasLength(1));
      expect(consolidator.calls[0], hasLength(3)); // 3 条未索引记忆
      expect(persistenceService.persistConsolidatedMemoriesCalls, 1);
      expect(persistenceService.lastRecords, hasLength(1));
      expect(persistenceService.lastRecords![0].summary, '合并后的剧情节点');
      expect(persistenceService.lastRecords![0].importance, 4);
      expect(persistenceService.lastOriginalIds, hasLength(3));
    });

    test('2. usageRatio 低于阈值 → 不触发', () async {
      final httpClient = _SseHttpClient(_v2SuccessResponses());
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepositoryWithUnindexed(
        unindexedMemories: _buildUnindexedMemories(count: 3),
      );
      final persistenceService = _RecordingPersistenceService();
      final consolidator = _RecordingConsolidator();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        consolidator: consolidator,
        // triggerThreshold=1.0 → usageRatio 永远 < 1.0（2 条短消息 << 87808 budget）
        config: _noTriggerConfig(),
      );

      await controller.sendMessage('勇者前往后山');

      // 等待足够时间确认 unawaited 未触发（无 completer 可等，用短延迟）
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(consolidator.calls, isEmpty);
      expect(persistenceService.persistConsolidatedMemoriesCalls, 0);
    });

    test('3. 未索引记忆不足（< minArtifactsToConsolidate）→ 不触发', () async {
      final httpClient = _SseHttpClient(_v2SuccessResponses());
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepositoryWithUnindexed(
        unindexedMemories:
            _buildUnindexedMemories(count: 2), // < minArtifactsToConsolidate(3)
      );
      final persistenceService = _RecordingPersistenceService();
      final consolidator = _RecordingConsolidator();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        consolidator: consolidator,
        config:
            _triggerConfig(), // triggerThreshold=0.0 但 minArtifactsToConsolidate=3
      );

      await controller.sendMessage('勇者前往后山');

      // 等待足够时间确认 unawaited 未触发
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(consolidator.calls, isEmpty);
      expect(persistenceService.persistConsolidatedMemoriesCalls, 0);
    });

    test('4. consolidator 为 null → 不触发（无崩溃）', () async {
      final httpClient = _SseHttpClient(_v2SuccessResponses());
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepositoryWithUnindexed(
        unindexedMemories: _buildUnindexedMemories(count: 5),
      );
      final persistenceService = _RecordingPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        consolidator: null, // 未注入 consolidator
        config: _triggerConfig(),
      );

      await controller.sendMessage('勇者前往后山');

      // 等待足够时间确认无崩溃
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(persistenceService.persistConsolidatedMemoriesCalls, 0);
    });

    test('5. 重新生成场景 → 不触发（isRegenerate=true 跳过）', () async {
      // 重新生成需要已有历史消息（user + assistant）
      final existingMessages = <ChatMessage>[
        ChatMessage(
          messageId: 'u1',
          sessionId: 'real-session-1',
          role: 'user',
          content: '勇者前往后山',
          createdAt: DateTime(2026),
        ),
        ChatMessage(
          messageId: 'a1',
          sessionId: 'real-session-1',
          role: 'assistant',
          content: '勇者穿过密林，发现了一座古碑。',
          createdAt: DateTime(2026),
        ),
      ];
      final httpClient = _SseHttpClient(
        _v2SuccessResponses(draft: '重新生成草稿', reply: '重新生成回复'),
      );
      final chatRepo = _IntegrationChatRepository(messages: existingMessages);
      final experienceRepo = _StubExperienceRepositoryWithUnindexed(
        unindexedMemories: _buildUnindexedMemories(count: 5),
      );
      final persistenceService = _RecordingPersistenceService();
      final consolidator = _RecordingConsolidator();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        consolidator: consolidator,
        config: _triggerConfig(),
      );

      // 调 regenerateMessage（走 persistRegeneratedRound 分支，isRegenerate=true）
      await controller.regenerateMessage(existingMessages[1]);

      // 等待足够时间确认 unawaited 未触发
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(consolidator.calls, isEmpty);
      expect(persistenceService.persistConsolidatedMemoriesCalls, 0);
    });

    test('6. LLM 返回空合并结果 → 不调用 persistConsolidatedMemories', () async {
      final httpClient = _SseHttpClient(_v2SuccessResponses());
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepositoryWithUnindexed(
        unindexedMemories: _buildUnindexedMemories(count: 3),
      );
      final persistenceService = _RecordingPersistenceService();
      // LLM 返回空合并结果（_RecordingConsolidator 默认 returnValue=const []）
      final consolidator = _RecordingConsolidator();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        consolidator: consolidator,
        config: _triggerConfig(),
      );

      await controller.sendMessage('勇者前往后山');

      // 等待 consolidator 被调用
      await consolidator.waitForCall(timeout: const Duration(seconds: 5));
      // 额外等待让 _runConsolidation 有时间检查 consolidated.isEmpty 并返回
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(consolidator.calls, hasLength(1));
      // LLM 返回空 → 不调用 persistConsolidatedMemories
      expect(persistenceService.persistConsolidatedMemoriesCalls, 0);
    });
  });

  group('IntermediateChatController - 重新生成上下文回归', () {
    test('重新生成后每个请求中该用户文本至多出现一次', () async {
      const userText = '勇者前往后山';
      final bodies = <String>[];
      final httpClient = _SseHttpClient(
        [
          ..._v2SuccessResponses(draft: '第一轮草稿', reply: '第一轮回复'),
          ..._v2SuccessResponses(draft: '重新生成草稿', reply: '重新生成回复'),
        ],
        bodyLog: bodies,
      );
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: _IntegrationChatRepository(),
        experienceRepo: _StubExperienceRepositoryWithUnindexed(
          unindexedMemories: _buildUnindexedMemories(count: 1),
        ),
        persistenceService: _RecordingPersistenceService(),
        consolidator: _RecordingConsolidator(),
        config: _noTriggerConfig(),
      );

      // 第一轮正常发送，让 state.messages 与持久化历史都有 user_N + assistant_N
      await controller.sendMessage(userText);
      expect(controller.state.phase, IntermediatePhase.idle);

      // 重新生成该轮：user_N 刻意保留在库中（Fork 语义）
      final assistantMessage = controller.state.messages
          .where((m) => m.role == 'assistant')
          .reduce((a, b) => b);
      await controller.regenerateMessage(assistantMessage);

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(bodies.length, greaterThanOrEqualTo(8));
      // 修复前：history 重载末尾含 user_N + 组装器再追加 userInput →
      // 同一条用户消息进上下文两次。断言每个请求中该文本作为独立
      // user 消息至多一次。
      var sawUserOnce = false;
      for (final body in bodies) {
        final decoded = jsonDecode(body) as Map<String, dynamic>;
        final messages = decoded['messages']! as List<dynamic>;
        final userCopies = messages
            .where(
              (m) =>
                  m is Map && m['role'] == 'user' && m['content'] == userText,
            )
            .length;
        expect(userCopies, lessThanOrEqualTo(1));
        if (userCopies == 1) sawUserOnce = true;
      }
      expect(sawUserOnce, isTrue);
    });
  });
}

// ── 测试辅助：V2 四步流程 SSE 响应构造（Phase 6 Step 6.4）─────────────
//
// V2 四步流程：drafting（纯文本）→ extracting（工具调用/JSON）→
// retrieving（本地）→ revising（纯文本）→ summarizing（工具调用/JSON）→ persisting。
//
// 测试利用 handler 的 fallback 路径：stub 只提供 LlmTextDelta（无 LlmToolCall* 事件），
// runWithToolCall 返回 ToolCallResult(fallbackText=...)，handler 调用
// parseKeywords/parseEventSummary 解析 JSON 文本。无需构造工具调用 SSE 事件。

String _buildSseText(String content) {
  final chunkJson = jsonEncode({
    'choices': [
      {
        'delta': {
          'content': content,
        },
      },
    ],
  });
  return 'data: $chunkJson\n\ndata: [DONE]\n\n';
}

/// V2 drafting SSE（纯文本草稿，无标记/JSON）。
String _draftV2(String draft) => _buildSseText(draft);

/// V2 extracting SSE（JSON 文本，触发 handler fallback 路径解析关键词）。
///
/// 5 类关键词（characters/items/locations/actions/plots）。
String _extractKeywordsSse({
  List<String> characters = const ['古碑'],
  List<String> items = const [],
  List<String> locations = const [],
  List<String> actions = const ['密林探索'],
  List<String> plots = const [],
}) =>
    _buildSseText(
      jsonEncode({
        'characters': characters,
        'items': items,
        'locations': locations,
        'actions': actions,
        'plots': plots,
      }),
    );

/// V2 revising SSE（纯文本回复，无标记/JSON）。
String _reviseV2(String reply) => _buildSseText(reply);

/// V2 summarizing SSE（JSON 文本，触发 handler fallback 路径解析事件摘要）。
String _summarizeSse({
  String summary = '事件摘要',
  int importance = 3,
  List<String> tags = const ['探索'],
}) =>
    _buildSseText(
      jsonEncode({
        'summary': summary,
        'importance': importance,
        'tags': tags,
      }),
    );

/// V2 完整成功路径的 4 个 SSE 响应（extract + draft + revise + summarize）。
///
/// extracting 前置到 drafting 之前。
/// 便捷构造器：skipReviewWhenEmptyRetrieval=false 时走完整 4 步链路。
List<String> _v2SuccessResponses({
  String draft = '草稿正文',
  String reply = '修正回复',
  int importance = 4,
}) =>
    [
      _extractKeywordsSse(),
      _draftV2(draft),
      _reviseV2(reply),
      _summarizeSse(importance: importance),
    ];

// ── 测试数据构造 ──────────────────────────────────────────────────────

ChatSession _realSession() => ChatSession(
      sessionId: 'real-session-1',
      title: '测试故事',
      mode: 'intermediate',
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 0,
    );

/// 触发合并的配置：triggerThreshold=0（任意 token 都触发）
/// minArtifactsToConsolidate/maxArtifactsToConsolidate 走默认值（3/10）
///
/// V2 四步流程（Phase 6）：skipReviewWhenEmptyRetrieval=false 走完整 4 步链路
/// （draft+extract+revise+summarize），consolidation 测试需提供 4 个 SSE 响应。
IntermediateConfig _triggerConfig() => const IntermediateConfig(
      stream: StreamConfig(skipReviewWhenEmptyRetrieval: false),
      consolidation: ConsolidationConfig(triggerThreshold: 0),
      // 测试 revising 路径，强制启用（默认 false 会跳过 revising）
      reviewEnabled: true,
    );

/// 不触发合并的配置：triggerThreshold=1（几乎不可能触发）
IntermediateConfig _noTriggerConfig() => const IntermediateConfig(
      stream: StreamConfig(skipReviewWhenEmptyRetrieval: false),
      consolidation: ConsolidationConfig(triggerThreshold: 1),
      // 测试 revising 路径，强制启用（默认 false 会跳过 revising）
      reviewEnabled: true,
    );

/// 构造 N 条未索引记忆（importance=2，模拟低于存储门槛的记忆）
List<ExperientialMemory> _buildUnindexedMemories({required int count}) {
  return List.generate(count, (i) {
    return ExperientialMemory(
      memoryId: 'unindexed-mem-$i',
      sessionId: 'real-session-1',
      summary: '低重要性事件摘要序号$i',
      importance: 2,
      tags: const ['探索'],
      turnNumber: i + 1,
      createdAt: DateTime(2026),
    );
  });
}

// ── Stub 类 ──────────────────────────────────────────────────────────

/// SSE HTTP 客户端 stub：按队列返回预设 SSE 文本。
class _SseHttpClient implements HttpClient {
  _SseHttpClient(this.responses, {this.bodyLog});

  final List<String> responses;

  /// 每次请求的 body 快照（重新生成上下文回归断言用）
  final List<String>? bodyLog;
  int callCount = 0;

  @override
  Stream<String> streamPost(
    String url,
    Map<String, String> headers, {
    String? body,
    Encoding encoding = utf8,
    CancellationToken? cancelToken,
    Duration? connectTimeout,
    Duration? readTimeout,
  }) {
    bodyLog?.add(body ?? '');
    final response = responses[callCount];
    callCount++;
    return Stream.value(response);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

/// ChatRepository stub：支持预设历史消息（重新生成场景用）。
class _IntegrationChatRepository implements ChatRepository {
  _IntegrationChatRepository({this.messages = const []});

  List<ChatMessage> messages;
  int messageCount = 0;

  @override
  Future<ChatSession> createSession({
    required String title,
    String mode = 'simple',
    String? modelId,
    String? presetId,
  }) async {
    return _realSession();
  }

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async => messages;

  @override
  Future<ChatMessage> addMessage(ChatMessage message) async {
    messages = [...messages, message];
    return message;
  }

  @override
  Future<int> getMessageCount(String sessionId) async => messageCount;

  @override
  Future<void> deleteMessage(String messageId) async {}

  @override
  Future<ChatSession> updateSession(ChatSession session) async => session;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

/// ConfigurationResolver stub：返回受控的命名配置 + embedding 配置。
class _FakeConfigurationResolver extends ConfigurationResolver {
  _FakeConfigurationResolver()
      : super(
          presetRepository: _StubApiPresetRepository(),
          settingsRepository: _StubSettingsRepository(),
          logger: const Logger('test'),
        );

  @override
  Future<({ChatSessionSettings settings, String? apiKey})> resolveSettings(
    ChatSession session,
  ) async {
    return (
      settings: const ChatSessionSettings(
        modelId: 'test-model',
        presetId: 'test-preset',
        systemPrompt: '',
        temperature: 0.8,
        topP: 0.9,
        maxTokens: 4096,
        autoCompaction: true,
        compactionThreshold: 0.6,
        streamEnabled: true,
      ),
      apiKey: 'sk-test',
    );
  }

  @override
  Future<NamingConfig?> resolveTitleNamingConfig() async {
    return const NamingConfig(
      baseUrl: 'https://api.example.com',
      apiKey: 'sk-test',
      modelId: 'test-model',
    );
  }

  @override
  Future<({ChatSessionSettings settings, String? apiKey})>
      resolveIntermediateSettings(ChatSession session) async {
    return resolveSettings(session);
  }

  // 分步骤模型配置：测试不验证分步骤优先级，复用全局默认即可。
  @override
  Future<NamingConfig?> resolveIntermediatePhaseNamingConfig(
    ChatSession session,
    String phase,
  ) async {
    return resolveTitleNamingConfig();
  }

  @override
  Future<ModelDisplayInfo> resolveModelDisplayInfo(ChatSession session) async {
    return const ModelDisplayInfo(
      modelName: 'Test Model',
      providerName: 'Test Provider',
      contextWindowTokens: 96000,
    );
  }

  @override
  Future<EmbeddingApiConfig?> resolveEmbeddingConfig() async => null;
}

class _StubApiPresetRepository implements ApiPresetRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubSettingsRepository implements SettingsRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

/// ExperienceRepository stub：支持返回预设的未索引记忆列表。
class _StubExperienceRepositoryWithUnindexed implements ExperienceRepository {
  _StubExperienceRepositoryWithUnindexed({
    this.unindexedMemories = const [],
  });

  final List<ExperientialMemory> unindexedMemories;

  @override
  Future<List<ExperientialMemory>> searchExperiencesBySubstring(
    String sessionId,
    List<String> terms, {
    int limit = 5,
    bool includeArchived = false,
  }) async =>
      const [];

  @override
  Future<List<ScoredMemory>> searchExperiences({
    required String sessionId,
    required String query,
    required Float32List? queryVector,
    required int topK,
    required double fts5Weight,
    required double vectorWeight,
    required int keyEventThreshold,
    required double keyEventBoost,
    required double normalizationEpsilon,
    double recencyWeight = 0.0,
    double importanceWeight = 0.0,
    int recencyHalfLife = 20,
    double vectorScoreThreshold = 0.0,
    int? currentTurnNumber,
  }) async {
    return const [];
  }

  // controller 改用 5 路并行检索接口，stub 返回空列表（合并测试不验证检索结果）。
  @override
  Future<List<ScoredMemory>> searchExperiencesMultiChannel({
    required String sessionId,
    required List<String> fts5Queries,
    required List<({String query, Float32List? vector})> vectorQueries,
    required int topK,
    required double fts5Weight,
    required double vectorWeight,
    required int keyEventThreshold,
    required double keyEventBoost,
    required double normalizationEpsilon,
    double recencyWeight = 0.0,
    double importanceWeight = 0.0,
    int recencyHalfLife = 20,
    double vectorScoreThreshold = 0.0,
    int? currentTurnNumber,
  }) async {
    return const [];
  }

  @override
  Future<List<ExperientialMemory>> getUnindexedExperiences(
    String sessionId, {
    required int limit,
  }) async {
    if (limit >= unindexedMemories.length) {
      return unindexedMemories;
    }
    return unindexedMemories.take(limit).toList();
  }

  // _rollbackNarrativeTime（重新生成路径）读取全量经历以推导叙事时间。
  @override
  Future<List<ExperientialMemory>> getAllExperiences(
    String sessionId, {
    bool includeArchived = true,
  }) async {
    return unindexedMemories;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

/// PersistenceService stub：记录 persistConsolidatedMemories 调用。
class _RecordingPersistenceService implements StoryPersistenceService {
  int persistRoundCalls = 0;
  int persistConsolidatedMemoriesCalls = 0;
  List<ConsolidatedMemoryRecord>? lastRecords;
  List<String>? lastOriginalIds;
  Completer<void>? _persistCompleter;

  /// 等待 persistConsolidatedMemories 被调用。
  Future<void> waitForPersistCall({required Duration timeout}) {
    if (_persistCompleter != null && _persistCompleter!.isCompleted) {
      return Future.value();
    }
    _persistCompleter ??= Completer<void>();
    return _persistCompleter!.future.timeout(timeout, onTimeout: () {});
  }

  @override
  Future<PersistRoundResult> persistRound({
    required ChatMessage userMessage,
    required ChatMessage assistantMessage,
    required EventSummary eventSummary,
    required Float32List? embedding,
    required StoryRoundArtifacts? artifacts,
    bool indexForRetrieval = true,
    List<FactsDelta>? factsDeltas,
    FactualConfig? factualConfig,
    CompactionPersistenceData? compaction,
    String? variantSourceInput,
  }) async {
    persistRoundCalls++;
    return PersistRoundResult(
      memory: ExperientialMemory(
        memoryId: 'mem-1',
        sessionId: userMessage.sessionId,
        summary: eventSummary.summary,
        importance: eventSummary.importance,
        tags: eventSummary.tags,
        turnNumber: eventSummary.turnNumber,
        createdAt: DateTime(2026),
      ),
    );
  }

  @override
  Future<PersistRoundResult> persistRegeneratedRound({
    required ChatMessage assistantMessage,
    required EventSummary eventSummary,
    required Float32List? embedding,
    required StoryRoundArtifacts? artifacts,
    bool indexForRetrieval = true,
    List<FactsDelta>? factsDeltas,
    FactualConfig? factualConfig,
    CompactionPersistenceData? compaction,
    bool recordVariant = false,
    String? variantSourceInput,
  }) async {
    return PersistRoundResult(
      memory: ExperientialMemory(
        memoryId: 'mem-regen',
        sessionId: assistantMessage.sessionId,
        summary: eventSummary.summary,
        importance: eventSummary.importance,
        tags: eventSummary.tags,
        turnNumber: eventSummary.turnNumber,
        createdAt: DateTime(2026),
      ),
    );
  }

  @override
  Future<StoryAnchor?> deleteRoundAndDownstream({
    required String sessionId,
    required int fromTurnNumber,
    required List<String> messageIdsToDelete,
    bool keepVariantsAtFromTurn = false,
  }) async =>
      null;

  @override
  Future<Map<int, StoryRoundArtifacts>> loadArtifactsBySession(
    String sessionId,
  ) async {
    return const {};
  }

  /// 变体方法兜底——regenerate/editAndResend 前置
  /// 快照、收稿后轻查变体表；空实现保既有用例绿。
  @override
  Future<int> snapshotMessageVariant({
    required String sessionId,
    required int turnNumber,
    required String? content,
    String? thinkingContent,
    String? sourceInput,
    StoryRoundArtifacts? process,
  }) async =>
      0;

  @override
  Future<Map<int, List<MessageVariantRecord>>> loadMessageVariants(
    String sessionId,
  ) async =>
      const {};

  @override
  Future<void> persistConsolidatedMemories({
    required String sessionId,
    required List<ConsolidatedMemoryRecord> records,
    required List<String> originalMemoryIds,
  }) async {
    persistConsolidatedMemoriesCalls++;
    lastRecords = records;
    lastOriginalIds = originalMemoryIds;
    _persistCompleter ??= Completer<void>();
    if (!_persistCompleter!.isCompleted) {
      _persistCompleter!.complete();
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

/// MemoryConsolidator 子类 stub：记录调用，Completer 通知测试方。
class _RecordingConsolidator extends MemoryConsolidator {
  _RecordingConsolidator({this.returnValue = const []})
      : super(llmService: _NoOpLlmService());

  final List<ConsolidatedMemory> returnValue;
  final List<List<ExperientialMemory>> calls = [];
  Completer<void>? _completer;

  Future<void> waitForCall({required Duration timeout}) {
    if (_completer != null && _completer!.isCompleted) {
      return Future.value();
    }
    _completer ??= Completer<void>();
    return _completer!.future.timeout(
      timeout,
      onTimeout: () {
        // 超时不抛异常，让测试方断言 calls 为空
      },
    );
  }

  @override
  Future<List<ConsolidatedMemory>> consolidate({
    required List<ExperientialMemory> memories,
    required NamingConfig namingConfig,
    required String consolidationPrompt,
  }) async {
    calls.add(memories);
    final result = returnValue;
    _completer ??= Completer<void>();
    if (!_completer!.isCompleted) {
      _completer!.complete();
    }
    return result;
  }
}

/// 占位 LlmService：_RecordingConsolidator 父类构造需要，但 consolidate 被重写不实际调用。
class _NoOpLlmService implements LlmService {
  @override
  Future<LlmResponse> chat(LlmRequest request) async {
    return const LlmResponse(content: '');
  }

  @override
  Stream<LlmStreamEvent> streamChat(LlmRequest request) {
    throw UnimplementedError('Not used in _RecordingConsolidator');
  }
}

/// EmbeddingService stub：noSuchMethod 兜底（consolidation 测试不验证 embedding）。
class _StubEmbeddingService implements EmbeddingService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

// ── Controller 构造 ──────────────────────────────────────────────────

IntermediateChatController _buildController({
  required ChatSession session,
  required HttpClient httpClient,
  required _IntegrationChatRepository chatRepo,
  required _StubExperienceRepositoryWithUnindexed experienceRepo,
  required _RecordingPersistenceService persistenceService,
  required MemoryConsolidator? consolidator,
  required IntermediateConfig config,
}) {
  return IntermediateChatController(
    chatRepository: chatRepo,
    configurationResolver: _FakeConfigurationResolver(),
    llmService: LlmRemoteDataSource(
      httpClient: httpClient,
      adapterFactory: LlmAdapterFactory(),
    ),
    experienceRepository: experienceRepo,
    embeddingService: _StubEmbeddingService(),
    persistenceService: persistenceService,
    failureLogRepository: const StubFailureLogRepository(),
    tokenCounter: TokenCounter(),
    getConfig: () async => config,
    logger: const Logger('test'),
    session: session,
    consolidator: consolidator,
  );
}
