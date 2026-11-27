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
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
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
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/services/persistence_service.dart';
import '../../../../test_helpers/stub_failure_log_repository.dart';

/// IntermediateChatController embedding 链路集成测试（V3）
///
/// 独立文件验证 V1 启用的 Vector 语义检索在 controller 主链路中的接入：
/// - A. embedding 配置完整 → persistRound 写入 embedding 非 null
/// - B. embedding API 失败 + fallbackOnFailure=true → embedding=null，事务仍提交（降级）
/// - C. embedding 配置完整 → retrieve 阶段 queryVector 非 null
/// - D. 无 embedding 配置 → queryVector=null（FTS5 兜底回归）
///
/// 独立文件原因：现有 intermediate_chat_controller_integration_test.dart 已 995 行
/// （超 500 行红线），本文件复制必要 fake 隔离 V3 改动（用户规则第 4 条）。
///
/// 权威设计：DOC-09A-1 §3.9（embedding 同步生成 + 失败降级）、DOC-08 §3.4（纯 API 方案）。

// ── Fake / Stub ─────────────────────────────────────────────────────

/// SSE HTTP 客户端 stub：按队列返回预设的 SSE 原始文本流。
class _SseHttpClient implements HttpClient {
  _SseHttpClient(this.responses);

  final List<String> responses;
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
    Duration? responseStartTimeout,
  }) {
    final response = responses[callCount];
    callCount++;
    return Stream.value(response);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

/// 功能性 ChatRepository stub：实现 sendMessage 链路用到的方法。
class _IntegrationChatRepository implements ChatRepository {
  final List<ChatMessage> addMessageCalls = [];
  List<ChatMessage> messages = const [];

  @override
  Future<ChatSession> createSession({
    required String title,
    String? sessionId,
    String mode = 'simple',
    String? modelId,
    String? presetId,
  }) async {
    return ChatSession(
      sessionId: sessionId ?? 'real-session-1',
      title: title,
      mode: mode,
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 0,
      modelId: modelId,
      presetId: presetId,
    );
  }

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async => messages;

  @override
  Future<ChatMessage> addMessage(ChatMessage message) async {
    addMessageCalls.add(message);
    return message;
  }

  @override
  Future<int> getMessageCount(String sessionId) async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

/// EmbeddingService fake：根据构造参数返回固定向量或抛异常。
///
/// [vector] 非 null → embed 返回该向量；[error] 非 null → embed 抛该异常。
/// 记录 [embedCalls] 供测试断言 embedding 链路是否被触发。
class _FakeEmbeddingService implements EmbeddingService {
  _FakeEmbeddingService({this.vector, this.error});

  final Float32List? vector;
  final Object? error;
  int embedCalls = 0;

  @override
  Future<Float32List> embed({
    required String text,
    required EmbeddingInputKind kind,
    required String model,
    required String baseUrl,
    required String? apiKey,
    Duration? timeout,
  }) async {
    embedCalls++;
    if (error != null) {
      // ignore: only_throw_errors, 测试 stub 故意抛 Object 模拟 API 异常
      throw error!;
    }
    return vector ?? Float32List(0);
  }
}

///  回归用：第 [failFromCall] 次调用起抛错（前几次成功）。
///
/// 场景：检索期 query embedding 成功、persisting 期 summary embedding 失败
/// ——恰好越过 retrieving 阶段的 E104 捕获，命中 persist 阶段的 E104。
class _FlakyEmbeddingService implements EmbeddingService {
  _FlakyEmbeddingService({required this.vector, required this.failFromCall});

  final Float32List vector;
  final int failFromCall;
  int embedCalls = 0;

  @override
  Future<Float32List> embed({
    required String text,
    required EmbeddingInputKind kind,
    required String model,
    required String baseUrl,
    required String? apiKey,
    Duration? timeout,
  }) async {
    embedCalls++;
    if (embedCalls >= failFromCall) {
      throw Exception('Embedding API fail at call #$embedCalls');
    }
    return vector;
  }
}

/// ConfigurationResolver stub：override 6 个 resolve 方法返回受控值。
///
/// [embeddingConfig] 控制 resolveEmbeddingConfig 返回值（null = 未配置 → FTS5 兜底）。
/// 其他方法复用现有 _FakeConfigurationResolver 模式（避免走基类实现触发 stub repo
/// 的 noSuchMethod → E010）。
class _EmbeddingConfigResolver extends ConfigurationResolver {
  _EmbeddingConfigResolver({this.embeddingConfig})
      : super(
          presetRepository: _StubApiPresetRepository(),
          settingsRepository: _StubSettingsRepository(),
          logger: const Logger('test'),
        );

  final EmbeddingApiConfig? embeddingConfig;

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
      apiKey: 'test-api-key',
    );
  }

  @override
  Future<NamingConfig?> resolveTitleNamingConfig() async {
    return const NamingConfig(
      baseUrl: 'https://api.test.com/v1',
      apiKey: 'test-api-key',
      modelId: 'test-model',
    );
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
  Future<EmbeddingApiConfig?> resolveEmbeddingConfig() async => embeddingConfig;
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

/// ExperienceRepository 记录型 stub：记录 vectorQueries 参数（验证检索阶段传入）。
///
/// controller 改用 5 路并行检索接口，stub 记录 vectorQueries 列表
/// 供测试断言 embedding 是否被解析并传入（非 null = 配置完整，null = 降级/未配置）。
class _RecordingExperienceRepository implements ExperienceRepository {
  /// 记录最后一次 searchExperiencesMultiChannel 调用的 vectorQueries。
  List<({String query, Float32List? vector})> lastVectorQueries = const [];
  int searchExperiencesMultiChannelCalls = 0;

  @override
  Future<List<ExperientialMemory>> searchExperiencesBySubstring(
    String sessionId,
    List<String> terms, {
    int limit = 5,
    bool includeArchived = false,
  }) async =>
      const [];

  // 旧接口保留向后兼容（controller 不再调用，但接口仍需实现）。
  // ignore: unused_field
  int searchExperiencesCalls = 0;

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
    searchExperiencesCalls++;
    return const <ScoredMemory>[];
  }

  // 5 路并行检索接口，记录 vectorQueries 供测试断言。
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
    searchExperiencesMultiChannelCalls++;
    lastVectorQueries = vectorQueries;
    return const <ScoredMemory>[];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

/// PersistenceService 记录型 stub：记录 embedding 参数（验证持久化写入）。
class _RecordingPersistenceService implements StoryPersistenceService {
  Float32List? lastEmbedding;
  int persistRoundCalls = 0;

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
    bool hasVerifiedSourceTurn = false,
  }) async {
    persistRoundCalls++;
    lastEmbedding = embedding;
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

  /// 返回空 Map（stub 不持久化 artifacts）
  @override
  Future<Map<int, StoryRoundArtifacts>> loadArtifactsBySession(
    String sessionId,
  ) async =>
      const {};

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

// ── 辅助函数：V2 四步流程 SSE 响应构造（Phase 6 Step 6.4）─────────────
//
// V2 四步流程：drafting（纯文本）→ extracting（工具调用/JSON）→
// retrieving（本地）→ revising（纯文本）→ summarizing（工具调用/JSON）→ persisting。
//
// 测试利用 handler 的 fallback 路径：stub 只提供 LlmTextDelta（无 LlmToolCall* 事件），
// runWithToolCall 返回 ToolCallResult(fallbackText=...)，handler 调用
// parseKeywords/parseEventSummary 解析 JSON 文本。无需构造工具调用 SSE 事件。

/// 构造 SSE 原始文本：一个 content chunk + DONE 信号。
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
  String reply = '修正后的回复',
  int importance = 4,
}) =>
    [
      _extractKeywordsSse(),
      _draftV2(draft),
      _reviseV2(reply),
      _summarizeSse(importance: importance),
    ];

ChatSession _realSession() => ChatSession(
      sessionId: 'real-session-1',
      title: '测试故事',
      mode: 'intermediate',
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 0,
    );

/// 完整 embedding 配置（用于 A/C 测试）。
const _embeddingApiConfig = EmbeddingApiConfig(
  model: 'text-embedding-3-small',
  baseUrl: 'https://api.emb.com/v1',
  apiKey: 'key-emb',
  timeoutMs: 5000,
  fallbackOnFailure: true,
);

/// fallbackOnFailure=false（默认值形态， 回归用）。
const _embeddingApiConfigNoFallback = EmbeddingApiConfig(
  model: 'text-embedding-3-small',
  baseUrl: 'https://api.emb.com/v1',
  apiKey: 'key-emb',
  timeoutMs: 5000,
  fallbackOnFailure: false,
);

IntermediateChatController _buildController({
  required ChatSession session,
  required HttpClient httpClient,
  required _IntegrationChatRepository chatRepo,
  required _RecordingExperienceRepository experienceRepo,
  required StoryPersistenceService persistenceService,
  required EmbeddingService embeddingService,
  required ConfigurationResolver configurationResolver,
}) {
  return IntermediateChatController(
    chatRepository: chatRepo,
    configurationResolver: configurationResolver,
    llmService: LlmRemoteDataSource(
      httpClient: httpClient,
      adapterFactory: LlmAdapterFactory(),
    ),
    experienceRepository: experienceRepo,
    embeddingService: embeddingService,
    persistenceService: persistenceService,
    failureLogRepository: const StubFailureLogRepository(),
    tokenCounter: TokenCounter(),
    // V2 四步流程（Phase 6）：drafting/revising 走纯文本（runPlainText），
    // extracting/summarizing 走工具调用 fallback 路径（parseKeywords/parseEventSummary）。
    // skipReviewWhenEmptyRetrieval=false：走完整 4 步链路（含 revise）。
    getConfig: () async => const IntermediateConfig(
      stream: StreamConfig(skipReviewWhenEmptyRetrieval: false),
      // 测试 revising 路径，强制启用（默认 false 会跳过 revising）
      reviewEnabled: true,
    ),
    logger: const Logger('test'),
    session: session,
  );
}

// ── 测试 ─────────────────────────────────────────────────────────────

void main() {
  group('IntermediateChatController - embedding 链路集成 (V3)', () {
    test('A. embedding 配置完整 → persistRound 写入 embedding 非 null', () async {
      final httpClient = _SseHttpClient(_v2SuccessResponses());
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _RecordingExperienceRepository();
      final persistenceService = _RecordingPersistenceService();
      final embeddingService = _FakeEmbeddingService(
        vector: Float32List.fromList([0.1, 0.2, 0.3, 0.4]),
      );
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        embeddingService: embeddingService,
        configurationResolver:
            _EmbeddingConfigResolver(embeddingConfig: _embeddingApiConfig),
      );

      await controller.sendMessage('勇者前往后山');

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(persistenceService.persistRoundCalls, 1);
      // embedding 被写入持久化
      expect(persistenceService.lastEmbedding, isNotNull);
      expect(persistenceService.lastEmbedding!.length, 4);
      // embeddingService 被调用 2 次：query embedding（检索）+ summary embedding（持久化）
      expect(embeddingService.embedCalls, 2);
    });

    test(
        'B. embedding API 失败 + fallbackOnFailure=true → embedding=null，事务仍提交（降级）',
        () async {
      final httpClient = _SseHttpClient(_v2SuccessResponses());
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _RecordingExperienceRepository();
      final persistenceService = _RecordingPersistenceService();
      final embeddingService = _FakeEmbeddingService(
        error: Exception('Embedding API fail'),
      );
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        embeddingService: embeddingService,
        configurationResolver: _EmbeddingConfigResolver(
          embeddingConfig: _embeddingApiConfig,
        ),
      );

      await controller.sendMessage('勇者前往后山');

      // 降级成功：state idle（非 failed）
      expect(controller.state.phase, IntermediatePhase.idle);
      expect(persistenceService.persistRoundCalls, 1);
      // embedding 失败 → null 写入持久化（has_embedding=false）
      expect(persistenceService.lastEmbedding, isNull);
      // embeddingService 被调用 2 次但都失败（query + summary）
      expect(embeddingService.embedCalls, 2);
    });

    test('persisting 期 E104（fallback=false）→ failed 终态可见，不进自动重试空转', () async {
      final httpClient = _SseHttpClient(_v2SuccessResponses());
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _RecordingExperienceRepository();
      final persistenceService = _RecordingPersistenceService();
      // 第 1 次（retrieving query）成功，第 2 次（persisting summary）失败
      final embeddingService = _FlakyEmbeddingService(
        vector: Float32List.fromList([0.1, 0.2, 0.3, 0.4]),
        failFromCall: 2,
      );
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        embeddingService: embeddingService,
        configurationResolver: _EmbeddingConfigResolver(
          embeddingConfig: _embeddingApiConfigNoFallback,
        ),
      );

      await controller.sendMessage('勇者前往后山');

      // 修复前：_scheduleRetry 空转 → phase=failed 但 failureContext=null
      //（无 FailureBar/无提示/无失败日志，regenerate 场景死锁到重启）
      expect(controller.state.phase, IntermediatePhase.failed);
      expect(
        controller.state.failureContext,
        isNotNull,
        reason: 'E104@persisting 必须以 failed 终态呈现，FailureBar 才可见',
      );
      expect(controller.state.failureContext!.errorCode, 'E104');
      expect(
        controller.state.failureContext!.failedPhase,
        IntermediatePhase.persisting,
      );
      expect(
        persistenceService.persistRoundCalls,
        0,
        reason: '持久化事务不得在 embedding 失败后部分提交',
      );
    });

    test('C. embedding 配置完整 → retrieve 阶段 queryVector 非 null', () async {
      final httpClient = _SseHttpClient(_v2SuccessResponses());
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _RecordingExperienceRepository();
      final persistenceService = _RecordingPersistenceService();
      final embeddingService = _FakeEmbeddingService(
        vector: Float32List.fromList([0.5, 0.5, 0.5, 0.5]),
      );
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        embeddingService: embeddingService,
        configurationResolver:
            _EmbeddingConfigResolver(embeddingConfig: _embeddingApiConfig),
      );

      await controller.sendMessage('勇者前往后山');

      expect(controller.state.phase, IntermediatePhase.idle);
      // 检索阶段被调用且 vectorQueries 中向量非 null（语义检索生效）
      // 默认关键词 actions=['密林探索'] → 1 路 vector query，plots=[] → 不生成
      expect(experienceRepo.searchExperiencesMultiChannelCalls, 1);
      expect(experienceRepo.lastVectorQueries, hasLength(1));
      expect(experienceRepo.lastVectorQueries.first.vector, isNotNull);
      expect(experienceRepo.lastVectorQueries.first.vector!.length, 4);
    });

    test('D. 无 embedding 配置 → queryVector=null（FTS5 兜底回归）', () async {
      final httpClient = _SseHttpClient(_v2SuccessResponses());
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _RecordingExperienceRepository();
      final persistenceService = _RecordingPersistenceService();
      final embeddingService = _FakeEmbeddingService(); // 不应被调用
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        embeddingService: embeddingService,
        configurationResolver: _EmbeddingConfigResolver(), // 未配置
      );

      await controller.sendMessage('勇者前往后山');

      expect(controller.state.phase, IntermediatePhase.idle);
      // 无配置 → embeddingService 不被调用
      expect(embeddingService.embedCalls, 0);
      // 检索仍被调用（有关键词），但 vectorQueries 中向量为 null（FTS5 兜底）
      // _resolveQueryVector 在 embeddingConfig=null 时直接返回 null
      expect(experienceRepo.searchExperiencesMultiChannelCalls, 1);
      expect(experienceRepo.lastVectorQueries, hasLength(1));
      expect(experienceRepo.lastVectorQueries.first.vector, isNull);
      // 持久化 embedding=null
      expect(persistenceService.lastEmbedding, isNull);
    });
  });
}
