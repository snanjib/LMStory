import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
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
import 'package:lmstory/features/story_runtime/domain/services/compaction_service.dart';
import 'package:lmstory/features/story_runtime/domain/services/manual_compact_result.dart';
import 'package:lmstory/features/story_runtime/domain/services/persistence_service.dart';
import '../../../../test_helpers/stub_failure_log_repository.dart';

// ignore_for_file: avoid_redundant_argument_values
// 集成测试中构造配置对象时常显式传默认值以表达"使用默认配置"的意图。

/// IntermediateChatController 集成测试（+）
///
/// 验证 sendMessage 状态机主链路（idle→drafting→retrieving→revising→persisting→idle）
/// 的关键路径与设计决策。使用真实 SseParser + 真实 StreamMarkerParser（controller 内部），
/// 通过 _SseHttpClient 注入构造好的 SSE 原始文本，测试完整解析链路。
///
/// 覆盖范围（V2 四步流程：drafting→extracting→retrieving→revising→summarizing→persisting）：
/// 1. 成功路径（完整状态流转 + 4 次 SSE + persistRound）
/// 2. extracting E013（关键词 JSON 解析失败 → 重试用尽 → failed）
/// 3. summarizing E017（事件摘要 JSON 解析失败 → 重试用尽 → failed）
/// 4. retry 恢复（summarizing E017 用尽 → failed → 手动 retry() → 成功）
/// 5. 草稿会话物化（__draft_intermediate_ 前缀 → createSession）
/// 6. toolCallingEnabled=false → extracting/summarizing 直接 JSON 模式
/// 7-8. revising 始终执行（2026-07-16 优化项10：移除 compact 降级，
///      检索为空/关键词为空时 revising 仍执行，仅做润色）
///
/// 权威设计：DOC-09A-1（状态机）、DOC-09A-2 §6（失败处理）、
/// DOC-09B §8.6（工具调用/JSON 降级）、DOC-09B §9（错误码）。

// ── Stub 类 ──────────────────────────────────────────────────────────

/// SSE HTTP 客户端 stub：按队列返回预设的 SSE 原始文本流。
///
/// 成功路径需两次 streamPost 调用（draft + revise），
/// 用 [responses] 队列按调用顺序依次返回。
class _SseHttpClient implements HttpClient {
  _SseHttpClient(this.responses);

  final List<String> responses;
  int callCount = 0;

  /// 每次请求的 body 快照（注入断言用；对既有测试零影响）
  final List<String?> bodies = [];

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
    final response = responses[callCount];
    callCount++;
    bodies.add(body);
    return Stream.value(response);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

/// 功能性 ChatRepository stub：真实实现 sendMessage 链路用到的方法。
class _IntegrationChatRepository implements ChatRepository {
  final List<String> createSessionCalls = [];
  final List<ChatMessage> addMessageCalls = [];
  List<ChatMessage> messages = const [];
  int messageCount = 0;
  int _sessionCounter = 0;

  @override
  Future<ChatSession> createSession({
    required String title,
    String mode = 'simple',
    String? modelId,
    String? presetId,
  }) async {
    createSessionCalls.add(title);
    _sessionCounter++;
    return ChatSession(
      sessionId: 'real-session-$_sessionCounter',
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
  Future<int> getMessageCount(String sessionId) async => messageCount;

  /// ST13U-1：仅保存路径的仓储写。null=成功；非 null=抛该
  /// 错误（页面据此弹保存失败反馈）。
  Exception? updateMessageContentError;

  @override
  Future<void> updateMessageContent(String messageId, String newContent) async {
    final error = updateMessageContentError;
    if (error != null) throw error;
  }

  ///  残留测试：注入压缩服务后 _loadFilteredMessages 会读取压缩点。
  List<Map<String, dynamic>> compactionPoints = const [];

  @override
  Future<List<Map<String, dynamic>>> getCompactionPoints(String sessionId) =>
      Future.value(compactionPoints);

  ///  turn 单一事实源：_loadFilteredMessages 并行读取会话行（next_turn）。
  /// null = 未脚本化（noSuchMethod 抛错 → 控制器静默回退公式，存量会话路径）。
  ChatSession? scriptedSession;

  @override
  Future<ChatSession> getSession(String sessionId) async {
    final s = scriptedSession;
    if (s == null) {
      throw UnimplementedError('getSession not scripted');
    }
    return s;
  }

  /// _materializeDraftSession 调用 updateSession 写入全局默认值到会话。
  /// 集成测试不验证持久化，直接返回传入的 session 即可。
  @override
  Future<ChatSession> updateSession(ChatSession session) async => session;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

/// ConfigurationResolver stub：继承具体类，重写 5 个 resolve 方法返回受控值。
///
/// 避免触发 E010（未配置 API），resolveNamingConfig 返回有效 NamingConfig。
/// 中级专用方法（resolveIntermediateSettings / resolveIntermediateNamingConfig）
/// 复用 Simple 方法的返回值——集成测试不验证两级配置优先级，只需受控可用值。
class _FakeConfigurationResolver extends ConfigurationResolver {
  _FakeConfigurationResolver()
      : super(
          presetRepository: _StubApiPresetRepository(),
          settingsRepository: _StubSettingsRepository(),
          logger: const Logger('test'),
        );

  /// 测试用 baseUrl。JSON 模式测试需传入已知供应商（如 OpenAI），
  /// 否则 LlmCapabilities.detectJsonSupport 返回 none 触发降级。
  final String baseUrl = 'https://api.test.com/v1';

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
    return NamingConfig(
      baseUrl: baseUrl,
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

  // ── 中级模式专用方法──────────────────────────────
  // 集成测试不验证配置优先级，复用 Simple 方法的受控返回值即可，
  // 避免走基类实现触发 stub repo 的 noSuchMethod → E010。

  @override
  Future<({ChatSessionSettings settings, String? apiKey})>
      resolveIntermediateSettings(ChatSession session) async {
    final base = await resolveSettings(session);
    // 透传 session.reviewEnabledOverride，与真实 ConfigurationResolver
    // 行为一致。控制器据此做 `?? config.reviewEnabled` 回退判断。
    return (
      settings: ChatSessionSettings(
        modelId: base.settings.modelId,
        presetId: base.settings.presetId,
        systemPrompt: base.settings.systemPrompt,
        temperature: base.settings.temperature,
        topP: base.settings.topP,
        maxTokens: base.settings.maxTokens,
        autoCompaction: base.settings.autoCompaction,
        compactionThreshold: base.settings.compactionThreshold,
        streamEnabled: base.settings.streamEnabled,
        maxContextMessages: base.settings.maxContextMessages,
        effectiveContextLimit: base.settings.effectiveContextLimit,
        reasoningEffort: base.settings.reasoningEffort,
        presencePenalty: base.settings.presencePenalty,
        frequencyPenalty: base.settings.frequencyPenalty,
        reviewEnabledOverride: session.reviewEnabledOverride,
      ),
      apiKey: base.apiKey,
    );
  }

  // 分步骤模型配置：集成测试不验证分步骤优先级，复用全局默认即可。
  @override
  Future<NamingConfig?> resolveIntermediatePhaseNamingConfig(
    ChatSession session,
    String phase,
  ) async {
    return resolveTitleNamingConfig();
  }

  // V1：embedding 配置未配置 → 返回 null（FTS5 兜底）。
  // 避免走基类实现触发 stub repo 的 noSuchMethod。
  // V3 将改为 _FakeEmbeddingService + 受控 EmbeddingApiConfig 以验证语义检索链路。
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

/// ExperienceRepository stub：searchExperiences 返回 [returnValue]（默认空列表）。
///
///  测试可通过设置 [returnValue] 注入低质量 ScoredMemory，验证 skipRevise
/// 扩展条件（allLowQuality / fewAndLowQuality）。
///
/// DOC-10 多粒度记忆集成测试扩展：
/// - [lastMacroTurnNumber] 控制 `getLastMacroTurnNumber` 返回值（null = 从未生成）
/// - [microSummariesInRange] 控制 `getMicroSummariesInRange` 返回值
class _StubExperienceRepository implements ExperienceRepository {
  int searchExperiencesCalls = 0;
  int getLastMacroTurnNumberCalls = 0;
  int getMicroSummariesInRangeCalls = 0;

  /// 子串兜底返回池（默认空 = 不补位）
  List<ExperientialMemory> substringHits = const [];

  @override
  Future<List<ExperientialMemory>> searchExperiencesBySubstring(
    String sessionId,
    List<String> terms, {
    int limit = 5,
    bool includeArchived = false,
  }) async =>
      substringHits.take(limit).toList();

  /// 预设返回的检索结果（默认空列表 = 无历史记忆）。
  List<ScoredMemory> returnValue = const <ScoredMemory>[];

  /// getLastMacroTurnNumber 返回值（null = 从未生成过宏摘要）。
  int? lastMacroTurnNumber;

  /// getMicroSummariesInRange 返回值（默认 2 条，满足 >=2 才触发宏摘要）。
  List<ExperientialMemory> microSummariesInRange = const [];

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
    return returnValue;
  }

  // controller 改用 5 路并行检索接口，stub 复用同一计数器与返回值。
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
    searchExperiencesCalls++;
    return returnValue;
  }

  @override
  Future<int?> getLastMacroTurnNumber(String sessionId) async {
    getLastMacroTurnNumberCalls++;
    return lastMacroTurnNumber;
  }

  @override
  Future<List<ExperientialMemory>> getMicroSummariesInRange({
    required String sessionId,
    required int fromTurn,
    required int toTurn,
  }) async {
    getMicroSummariesInRangeCalls++;
    return microSummariesInRange;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

/// PersistenceService stub：记录 persistRound 调用，返回预设 ExperientialMemory。
///
/// 集成测试 stub：记录 persistRound 调用。
class _StubPersistenceService implements StoryPersistenceService {
  int persistRoundCalls = 0;

  /// + 多轮修复测试用：记录每次 persistRound 调用的 artifacts
  final List<StoryRoundArtifacts?> recordedArtifacts = [];

  ///  turn 单一事实源回归：记录每次 persistRound 的事件摘要与压缩数据，
  /// 断言 eventSummary/artifacts/compaction 三处轮号同源不分裂。
  final List<EventSummary> recordedEventSummaries = [];
  final List<CompactionPersistenceData?> recordedCompactions = [];

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
    recordedArtifacts.add(artifacts);
    recordedEventSummaries.add(eventSummary);
    recordedCompactions.add(compaction);
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

  /// 变体四方法兜底——收稿后控制器会轻查变体表，
  /// 快照在 regenerate/editAndResend 前置调用；返回空实现保既有用例绿。
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
  Future<bool> switchMessageVariant({
    required String sessionId,
    required int turnNumber,
    required int variantIndex,
    required String assistantMessageId,
  }) async =>
      false;

  @override
  Future<void> deleteMessageVariant({
    required String sessionId,
    required int turnNumber,
    required int variantIndex,
  }) async {}

  /// 重新生成场景：stub 不实际删除数据，仅返回成功
  @override
  Future<StoryAnchor?> deleteRoundAndDownstream({
    required String sessionId,
    required int fromTurnNumber,
    required List<String> messageIdsToDelete,
    bool keepVariantsAtFromTurn = false,
  }) async =>
      null;

  /// 重新生成场景：持久化重新生成的轮次（与 persistRound 类似，仅写 assistant）
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
    persistRoundCalls++;
    recordedArtifacts.add(artifacts);
    return PersistRoundResult(
      memory: ExperientialMemory(
        memoryId: 'mem-regen-$persistRoundCalls',
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
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubEmbeddingService implements EmbeddingService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

/// 变体感知持久化 stub——message_variants 内存表 +
/// artifacts 存取，供变体端到端用例（快照→recordVariant→切换→删除）。
class _VariantAwarePersistenceService extends _StubPersistenceService {
  final Map<int, List<MessageVariantRecord>> variants = {};
  final Map<int, StoryRoundArtifacts> storedArtifacts = {};

  int _appendVariant(
    int turnNumber,
    String? content,
    String? thinkingContent,
    String? sourceInput,
  ) {
    final list = variants.putIfAbsent(turnNumber, () => []);
    final next = list.length;
    list.add(
      MessageVariantRecord(
        variantIndex: next,
        content: content,
        thinkingContent: thinkingContent,
        sourceInput: sourceInput,
        createdAtMs: DateTime(2026).millisecondsSinceEpoch,
      ),
    );
    return next;
  }

  @override
  Future<int> snapshotMessageVariant({
    required String sessionId,
    required int turnNumber,
    required String? content,
    String? thinkingContent,
    String? sourceInput,
    StoryRoundArtifacts? process,
  }) async =>
      _appendVariant(turnNumber, content, thinkingContent, sourceInput);

  @override
  Future<Map<int, List<MessageVariantRecord>>> loadMessageVariants(
    String sessionId,
  ) async =>
      variants;

  @override
  Future<bool> switchMessageVariant({
    required String sessionId,
    required int turnNumber,
    required int variantIndex,
    required String assistantMessageId,
  }) async =>
      true; // 控制器侧以重载的变体表为准更新 state

  @override
  Future<void> deleteMessageVariant({
    required String sessionId,
    required int turnNumber,
    required int variantIndex,
  }) async {
    variants[turnNumber]?.removeWhere((v) => v.variantIndex == variantIndex);
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
    final result = await super.persistRound(
      userMessage: userMessage,
      assistantMessage: assistantMessage,
      eventSummary: eventSummary,
      embedding: embedding,
      artifacts: artifacts,
      indexForRetrieval: indexForRetrieval,
      factsDeltas: factsDeltas,
      factualConfig: factualConfig,
      compaction: compaction,
    );
    if (artifacts != null) storedArtifacts[artifacts.turnNumber] = artifacts;
    return result;
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
    final result = await super.persistRegeneratedRound(
      assistantMessage: assistantMessage,
      eventSummary: eventSummary,
      embedding: embedding,
      artifacts: artifacts,
      indexForRetrieval: indexForRetrieval,
      factsDeltas: factsDeltas,
      factualConfig: factualConfig,
      compaction: compaction,
      recordVariant: recordVariant,
      variantSourceInput: variantSourceInput,
    );
    if (artifacts != null) {
      storedArtifacts[artifacts.turnNumber] = artifacts;
      if (recordVariant) {
        _appendVariant(
          artifacts.turnNumber,
          assistantMessage.content,
          assistantMessage.thinkingContent,
          variantSourceInput,
        );
      }
    }
    return result;
  }

  @override
  Future<Map<int, StoryRoundArtifacts>> loadArtifactsBySession(
    String sessionId,
  ) async =>
      storedArtifacts;
}

/// 删轮回滚叙事时间会读 getAllExperiences
/// （基类 stub 抛未实现）；空列表让 latestNarrativeTimeOf 回 null。
class _RollbackSafeExperienceRepository extends _StubExperienceRepository {
  @override
  Future<List<ExperientialMemory>> getAllExperiences(
    String sessionId, {
    bool includeArchived = true,
  }) async =>
      const [];
}

/// 可闸控持久化服务——persistRound
/// 在闸门释放前挂起，模拟 persisting 阶段被后台中断/外力复位竞态穿越。
/// artifacts 侧记录进 [storedArtifacts]，loadArtifactsBySession 如实返回。
class _GatedPersistenceService extends _StubPersistenceService {
  final Completer<void> gate = Completer<void>();
  final Map<int, StoryRoundArtifacts> storedArtifacts =
      <int, StoryRoundArtifacts>{};

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
    final result = await super.persistRound(
      userMessage: userMessage,
      assistantMessage: assistantMessage,
      eventSummary: eventSummary,
      embedding: embedding,
      artifacts: artifacts,
      indexForRetrieval: indexForRetrieval,
      factsDeltas: factsDeltas,
      factualConfig: factualConfig,
      compaction: compaction,
    );
    if (artifacts != null) {
      storedArtifacts[artifacts.turnNumber] = artifacts;
    }
    await gate.future;
    return result;
  }

  @override
  Future<Map<int, StoryRoundArtifacts>> loadArtifactsBySession(
    String sessionId,
  ) async =>
      Map<int, StoryRoundArtifacts>.of(storedArtifacts);
}

/// 轮询等待条件成立（测试事件循环内驱动异步推进）。
Future<void> _until(
  bool Function() condition, [
  Duration timeout = const Duration(seconds: 5),
]) async {
  final sw = Stopwatch()..start();
  while (!condition()) {
    if (sw.elapsed > timeout) {
      fail('condition not met within timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

///  残留测试：受控压缩服务——不经 LLM，返回固定压缩结果。
///
/// shouldCompact 由 [shouldCompactReturn] 控制；compact 把 boundary 之前的
/// 轮次压成一条 system 摘要卡，仅保留 [keepTail] 条对话消息。
class _FakeCompactionService extends StoryCompactionService {
  _FakeCompactionService()
      : super(
          tokenCounter: TokenCounter(),
          llmService: _NoopLlmService(),
        );

  bool shouldCompactReturn = true;
  int keepTail = 2;
  int compactCalls = 0;

  @override
  Future<bool> shouldCompact({
    required List<ChatMessage> history,
    required int contextWindow,
    required ContextBudget budget,
    required String rolePrompt,
    required String userInput,
    String? compactionSummary,
  }) async =>
      shouldCompactReturn;

  @override
  Future<int> estimateBaseContextTokens({
    required String rolePrompt,
    required String userInput,
    String? compactionSummary,
  }) async =>
      0;

  @override
  Future<CompactionResult> compact({
    required List<ChatMessage> history,
    required String sessionId,
    required NamingConfig namingConfig,
    required int contextWindow,
    required int maxTokens,
    required ContextBudget budget,
    Duration? connectTimeout,
    Duration? readTimeout,
    String? existingCompactionSummary,
    int baseContextTokens = 0,
    void Function(String delta)? onSummaryDelta,
    CancellationToken? cancelToken,
  }) async {
    compactCalls++;
    // 保留尾部 keepTail 条对话消息，boundary = 被压缩的最后一条消息
    final tail = history.skip(history.length - keepTail).toList();
    final boundary = history[history.length - keepTail - 1];
    return CompactionResult(
      summary: '前情摘要（累积）',
      boundaryMessageId: boundary.messageId,
      compactedHistory: [
        ChatMessage(
          messageId: 'summary-card-1',
          sessionId: sessionId,
          role: 'system',
          content: '前情摘要（累积）',
          createdAt: DateTime(2026),
        ),
        ...tail,
      ],
    );
  }
}

class _NoopLlmService implements LlmService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

///  manualCompact busy 态：compact 挂在 Completer 门闸上，测并发互斥。
///
/// [release] 未 complete 前 compact 永不返回，模拟一次进行中的压缩事务。
class _GatedCompactionService extends _FakeCompactionService {
  final Completer<void> release = Completer<void>();

  @override
  Future<CompactionResult> compact({
    required List<ChatMessage> history,
    required String sessionId,
    required NamingConfig namingConfig,
    required int contextWindow,
    required int maxTokens,
    required ContextBudget budget,
    Duration? connectTimeout,
    Duration? readTimeout,
    String? existingCompactionSummary,
    int baseContextTokens = 0,
    void Function(String delta)? onSummaryDelta,
    CancellationToken? cancelToken,
  }) async {
    await release.future;
    return super.compact(
      history: history,
      sessionId: sessionId,
      namingConfig: namingConfig,
      contextWindow: contextWindow,
      maxTokens: maxTokens,
      budget: budget,
      connectTimeout: connectTimeout,
      readTimeout: readTimeout,
      existingCompactionSummary: existingCompactionSummary,
      baseContextTokens: baseContextTokens,
      onSummaryDelta: onSummaryDelta,
    );
  }
}

///  批4：压缩摘要同步突发 10 个 delta（测 manualCompactionDelta 合帧）。
class _DeltaBurstCompactionService extends _FakeCompactionService {
  @override
  Future<CompactionResult> compact({
    required List<ChatMessage> history,
    required String sessionId,
    required NamingConfig namingConfig,
    required int contextWindow,
    required int maxTokens,
    required ContextBudget budget,
    Duration? connectTimeout,
    Duration? readTimeout,
    String? existingCompactionSummary,
    int baseContextTokens = 0,
    void Function(String delta)? onSummaryDelta,
    CancellationToken? cancelToken,
  }) async {
    for (var i = 0; i < 10; i++) {
      onSummaryDelta?.call('第$i段摘要内容。');
    }
    return super.compact(
      history: history,
      sessionId: sessionId,
      namingConfig: namingConfig,
      contextWindow: contextWindow,
      maxTokens: maxTokens,
      budget: budget,
      connectTimeout: connectTimeout,
      readTimeout: readTimeout,
      existingCompactionSummary: existingCompactionSummary,
      baseContextTokens: baseContextTokens,
    );
  }
}

/// 先吐一条 delta 再挂门闸——delta 进入 32ms 合帧
/// 缓冲后压缩挂起，精确模拟「dispose 恰落在缓冲窗口内」的场景。
class _DeltaThenGateCompactionService extends _FakeCompactionService {
  final Completer<void> release = Completer<void>();

  @override
  Future<CompactionResult> compact({
    required List<ChatMessage> history,
    required String sessionId,
    required NamingConfig namingConfig,
    required int contextWindow,
    required int maxTokens,
    required ContextBudget budget,
    Duration? connectTimeout,
    Duration? readTimeout,
    String? existingCompactionSummary,
    int baseContextTokens = 0,
    void Function(String delta)? onSummaryDelta,
    CancellationToken? cancelToken,
  }) async {
    compactCalls++;
    onSummaryDelta?.call('挂起中的压缩尾段。');
    await release.future;
    return super.compact(
      history: history,
      sessionId: sessionId,
      namingConfig: namingConfig,
      contextWindow: contextWindow,
      maxTokens: maxTokens,
      budget: budget,
      connectTimeout: connectTimeout,
      readTimeout: readTimeout,
      existingCompactionSummary: existingCompactionSummary,
      baseContextTokens: baseContextTokens,
      onSummaryDelta: onSummaryDelta,
    );
  }
}

///  manualCompact failed 态：compact 恒抛异常。
class _ThrowingCompactionService extends _FakeCompactionService {
  @override
  Future<CompactionResult> compact({
    required List<ChatMessage> history,
    required String sessionId,
    required NamingConfig namingConfig,
    required int contextWindow,
    required int maxTokens,
    required ContextBudget budget,
    Duration? connectTimeout,
    Duration? readTimeout,
    String? existingCompactionSummary,
    int baseContextTokens = 0,
    void Function(String delta)? onSummaryDelta,
    CancellationToken? cancelToken,
  }) async {
    throw Exception('Mock compact failure');
  }
}

///  manualCompact：记录 persistManualCompaction 落库参数。
class _ManualCompactRecordingPersistenceService
    extends _StubPersistenceService {
  final List<CompactionPersistenceData> manualCompactions = [];

  @override
  Future<void> persistManualCompaction({
    required CompactionPersistenceData compaction,
  }) async {
    manualCompactions.add(compaction);
  }
}

/// 记录 deleteRoundAndDownstream 调用（压缩中消息操作应零到达）。
/// 继承 _ManualCompactRecordingPersistenceService：压缩收尾的
/// persistManualCompaction 也要能正常落库走 success 路径。
class _DeleteRecordingPersistenceService
    extends _ManualCompactRecordingPersistenceService {
  final List<int> deleteRoundCalls = [];

  @override
  Future<StoryAnchor?> deleteRoundAndDownstream({
    required String sessionId,
    required int fromTurnNumber,
    required List<String> messageIdsToDelete,
    bool keepVariantsAtFromTurn = false,
  }) async {
    deleteRoundCalls.add(fromTurnNumber);
    return null;
  }
}

/// PersistenceService stub：persistRound 恒抛异常（测试 E018 持久化失败）。
class _FailingPersistenceService implements StoryPersistenceService {
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
    throw Exception('Mock persist failure');
  }

  /// 返回空 Map（与 _StubPersistenceService 一致，loadHistory 正常完成）
  @override
  Future<Map<int, StoryRoundArtifacts>> loadArtifactsBySession(
    String sessionId,
  ) async =>
      const {};

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

/// 抛指定异常的 HTTP 客户端 stub。
///
/// streamPost 同步抛 [error]，模拟网络层异常。
/// 异常从 _runStream 同步传播到 _runDraftPhase/_runRevisePhase 的 catch 块，
/// 触发 E010（drafting）/ E014（revising）路径，由分类器按异常类型决定 ErrorCategory。
///
/// extracting 前置后，drafting 不再是第一个 LLM 请求。为测试 drafting
/// 阶段的 HTTP 错误，[firstResponses] 可预设前 N 次请求的成功 SSE 响应
/// （如 extract 成功），之后抛 [error]。
class _ErrorHttpClient implements HttpClient {
  _ErrorHttpClient(this.error, {this.firstResponses = const []});

  final Object error;

  /// 前 N 次请求返回这些 SSE 响应（成功），之后抛 [error]。
  final List<String> firstResponses;

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
  }) {
    if (_callCount < firstResponses.length) {
      final response = firstResponses[_callCount];
      _callCount++;
      return Stream.value(response);
    }
    // ignore: only_throw_errors, 测试 stub 故意抛 Object 模拟各类异常
    throw error;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

/// ConfigurationResolver stub：resolveIntermediatePhaseNamingConfig 返回空配置。
///
/// 触发调用点2（phase 模型未配置 → E010 + errorCategory=config，无原始异常）。
/// 继承 [_FakeConfigurationResolver] 复用其他方法。
class _EmptyNamingConfigResolver extends _FakeConfigurationResolver {
  @override
  Future<NamingConfig?> resolveIntermediatePhaseNamingConfig(
    ChatSession session,
    String phase,
  ) async {
    return const NamingConfig(baseUrl: '', apiKey: '', modelId: '');
  }
}

/// ST-2：可切换的命名配置 stub。
///
/// [configured]=false 时所有阶段解析返回 null（模拟未配模型的全局/会话），
/// 翻为 true 后返回 [_FakeConfigurationResolver] 的受控可用值——模拟
/// 用户在草稿 E010 失败后补齐配置再点失败栏按钮的场景。
class _GatedNamingConfigResolver extends _FakeConfigurationResolver {
  bool configured = false;

  @override
  Future<NamingConfig?> resolveIntermediatePhaseNamingConfig(
    ChatSession session,
    String phase,
  ) async {
    if (!configured) return null;
    return super.resolveIntermediatePhaseNamingConfig(session, phase);
  }
}

// ── 辅助函数 ─────────────────────────────────────────────────────────

/// 构造 SSE 原始文本：一个 content chunk + DONE 信号。
///
/// [content] 为 LLM 流式输出的完整内容（含分隔标记），
/// 如 `'草稿正文<<<KEYWORDS>>>["古碑"]'`。
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

// ── V2 四步流程 SSE 响应构造（Phase 6 Step 6.4）─────────────────────
//
// V2 四步流程：drafting（纯文本）→ extracting（工具调用/JSON）→
// retrieving（本地）→ revising（纯文本）→ summarizing（工具调用/JSON）→ persisting。
//
// 测试利用 handler 的 fallback 路径：stub 只提供 LlmTextDelta（无 LlmToolCall* 事件），
// runWithToolCall 返回 ToolCallResult(fallbackText=...)，handler 调用
// parseKeywords/parseEventSummary 解析 JSON 文本。无需构造工具调用 SSE 事件。

/// V2 drafting SSE（纯文本草稿，无标记/JSON）。
String _draftV2(String draft) => _buildSseText(draft);

/// V2 extracting SSE（JSON 文本，触发 handler fallback 路径解析关键词）。
///
/// 5 类关键词（characters/items/locations/actions/plots），
/// 默认 characters=['古碑']，actions=['密林探索']，触发检索。
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
///
/// importance 必须是 num 类型（int/double），否则 parseEventSummary 返回 null。
/// eventEnded（DOC-10 §4.2）：控制 EventSummary.eventEnded，用于多粒度记忆触发判断。
String _summarizeSse({
  String summary = '事件摘要',
  int importance = 3,
  List<String> tags = const ['探索'],
  bool eventEnded = false,
}) =>
    _buildSseText(
      jsonEncode({
        'summary': summary,
        'importance': importance,
        'tags': tags,
        'event_ended': eventEnded,
      }),
    );

/// V2 完整成功路径的 4 个 SSE 响应（draft + extract + revise + summarize）。
///
/// 便捷构造器：skipReviewWhenEmptyRetrieval=false 时走完整 4 步链路。
/// compact 模式（skipRevise=true）时只需前 3 个（draft+extract+summarize），
/// 由调用方按需截取。
///
/// eventEnded（DOC-10 §4.2）：透传给 _summarizeSse，控制 EventSummary.eventEnded。
List<String> _v2SuccessResponses({
  String generated = '草稿正文',
  String reply = '修正后的回复',
  int importance = 4,
  bool eventEnded = false,
}) =>
    [
      // extracting 前置到 drafting 之前
      _extractKeywordsSse(),
      _draftV2(generated),
      _reviseV2(reply),
      _summarizeSse(importance: importance, eventEnded: eventEnded),
    ];

/// 构造触发 SseParser StreamError 的无效 SSE 响应（Phase 6 Step 6.4）。
///
/// data 行内容非合法 JSON → SseParser jsonDecode 失败 → 产生 StreamError 事件
/// → StreamRunner 收到 LlmStreamError → 抛 StreamErrorException
/// → 控制器 _runDraftPhase catch StreamErrorException → E016。
/// 供应商上下文超限 SSE（200 + error chunk + OpenAI 文案——
/// 状态码判不出超限，识别走 body 模式匹配）
String _contextOverflowSse() {
  final chunkJson = jsonEncode({
    'error': {
      'message': "This model's maximum context length is 128000 tokens. "
          'However, you requested 200000 tokens',
      'code': 400,
    },
  });
  return 'data: $chunkJson\n\ndata: [DONE]\n\n';
}

String _streamErrorSse() {
  // 用字符拼接构造，避免字面量被工具链误判
  const dataLine = 'da' 'ta: {invalid' '\n\n';
  const doneLine = 'da' 'ta: [DONE]' '\n\n';
  return dataLine + doneLine;
}

/// 先吐一条正文 delta 再流中报错——半截正文进入
/// 流式缓冲后中断（partialReplySnapshot 的触发形态）。
String _partialThenErrorSse(String partial) {
  final chunkJson = jsonEncode({
    'choices': [
      {
        'delta': {'content': partial},
      },
    ],
  });
  const errorLine = 'da' 'ta: {invalid' '\n\n';
  const doneLine = 'da' 'ta: [DONE]' '\n\n';
  return 'data: $chunkJson\n\n$errorLine$doneLine';
}

// ── 测试数据 ─────────────────────────────────────────────────────────

ChatSession _realSession() => ChatSession(
      sessionId: 'real-session-1',
      title: '测试故事',
      mode: 'intermediate',
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 0,
    );

ChatSession _draftSession() => ChatSession(
      sessionId: '${IntermediateChatController.draftSessionIdPrefix}abc',
      title: '草稿故事',
      mode: 'intermediate',
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 0,
    );

IntermediateChatController _buildController({
  required ChatSession session,
  required HttpClient httpClient,
  required _IntegrationChatRepository chatRepo,
  required _StubExperienceRepository experienceRepo,
  required StoryPersistenceService persistenceService,
  // V2 四步流程（Phase 6）：drafting/revising 走纯文本（runPlainText），
  // extracting/summarizing 走工具调用 fallback 路径（parseKeywords/parseEventSummary）。
  // skipReviewWhenEmptyRetrieval=false：默认走完整 4 步链路（含 revise），
  //  compact 降级测试组显式传 true 验证跳过 revise 分支。
  IntermediateConfig config = const IntermediateConfig(
    stream: StreamConfig(skipReviewWhenEmptyRetrieval: false),
  ),
  ConfigurationResolver? configurationResolver,
  StoryCompactionService? compactionService,
  // 默认强制 reviewEnabled=true，保持既有测试（测 revising 路径）行为不变。
  // 测试 skip-revise 路径时传 false。
  bool forceReviewEnabled = true,
}) {
  return IntermediateChatController(
    chatRepository: chatRepo,
    compactionService: compactionService,
    configurationResolver:
        configurationResolver ?? _FakeConfigurationResolver(),
    llmService: LlmRemoteDataSource(
      httpClient: httpClient,
      adapterFactory: LlmAdapterFactory(),
    ),
    experienceRepository: experienceRepo,
    embeddingService: _StubEmbeddingService(),
    persistenceService: persistenceService,
    failureLogRepository: const StubFailureLogRepository(),
    tokenCounter: TokenCounter(),
    getConfig: () async =>
        forceReviewEnabled ? _forceReviewEnabled(config) : config,
    logger: const Logger('test'),
    session: session,
  );
}

/// 强制将 config 的 reviewEnabled 设为 true（测试辅助）。
///
/// 既有集成测试均针对 revising 路径编写（4 次 LLM 调用），
/// 但 `IntermediateConfig.reviewEnabled` 默认 false（改为可选化）。
/// 本方法在运行时重建 config 并强制 reviewEnabled=true，避免逐个修改
/// 30+ 处 `const IntermediateConfig(...)` 调用。
///
/// 测试 skip-revise 路径时，通过 `_buildController(forceReviewEnabled: false)` 关闭。
IntermediateConfig _forceReviewEnabled(IntermediateConfig c) {
  if (c.reviewEnabled) return c;
  return IntermediateConfig(
    embeddingPresetId: c.embeddingPresetId,
    embeddingModelId: c.embeddingModelId,
    systemPrompt: c.systemPrompt,
    generation: c.generation,
    retrieval: c.retrieval,
    context: c.context,
    retry: c.retry,
    phaseModels: c.phaseModels,
    embedding: c.embedding,
    stream: c.stream,
    fork: c.fork,
    prompts: c.prompts,
    consolidation: c.consolidation,
    memory: c.memory,
    suggestReply: c.suggestReply,
    reviewEnabled: true,
    contextBudget: c.contextBudget,
  );
}

// ── 测试 ─────────────────────────────────────────────────────────────

void main() {
  group('IntermediateChatController - sendMessage 集成', () {
    test(
        '1. 成功路径：完整链路 idle→drafting→extracting→retrieving→revising→summarizing→persisting→idle',
        () async {
      final httpClient = _SseHttpClient(
        _v2SuccessResponses(generated: '草稿正文', reply: '修正后的回复'),
      );
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository();
      final persistenceService = _StubPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
      );

      await controller.sendMessage('勇者前往后山');

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(controller.state.messages.length, 2);
      expect(controller.state.messages[0].role, 'user');
      expect(controller.state.messages[1].role, 'assistant');
      expect(controller.state.messages[1].content, '修正后的回复');
      expect(persistenceService.persistRoundCalls, 1);
      // 本轮临时产物已清理
      expect(controller.state.streamingGenerated, isNull);
      expect(controller.state.streamingReply, isNull);
      expect(controller.state.extractedKeywords, isNull);
      expect(controller.state.currentEventSummary, isNull);
      expect(controller.state.generatedText, isNull);
      expect(controller.state.userInput, isNull);
      // V2 四步流程：4 次 SSE 调用（draft + extract + revise + summarize）
      expect(httpClient.callCount, 4);
      // extract 提取关键词 → 触发检索
      expect(experienceRepo.searchExperiencesCalls, 1);
    });

    test('2. extracting E013：关键词 JSON 解析失败 → 自动重试用尽 → failed', () async {
      // extracting 前置到 drafting 之前，extract 失败不会进入 draft。
      // extracting 降级链：工具调用 fallback（parseKeywords）→ 失败降级到 JSON 模式
      // （_runJsonMode，再次请求）→ 仍失败 → 抛 ExtractFailedException → E013。
      //
      // 配置 extractingMaxRetries=1：首次 E013 + 1 次重试用尽 → failed。
      // 每次 extracting 尝试需 2 个 SSE（fallback + JSON 模式降级）。
      // 总计 SSE：首次 extract[fallback+JSON](2) + 重试 extract[fallback+JSON](2) = 4
      final httpClient = _SseHttpClient([
        _buildSseText('不是合法 JSON 的关键词'), // 首次 extract fallback：解析失败
        _buildSseText('仍不是合法 JSON'), // 首次 extract JSON 模式：失败 → E013
        _buildSseText('重试仍非合法 JSON'), // 重试 extract fallback：失败
        _buildSseText('重试 JSON 模式仍失败'), // 重试 JSON 模式：失败 → E013 用尽
      ]);
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository();
      final persistenceService = _StubPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        config: const IntermediateConfig(
          retry: RetryConfig(extractingMaxRetries: 1),
        ),
      );

      await controller.sendMessage('测试输入');

      // E013 首次失败 + 1 次重试用尽 → failed
      expect(controller.state.phase, IntermediatePhase.failed);
      expect(controller.state.failureContext, isNotNull);
      expect(controller.state.failureContext!.errorCode, 'E013');
      expect(
        controller.state.failureContext!.failedPhase,
        IntermediatePhase.extracting,
      );
      expect(
        controller.state.retryCounts[IntermediatePhase.extracting],
        1,
      );
      expect(experienceRepo.searchExperiencesCalls, 0);
      expect(persistenceService.persistRoundCalls, 0);
    });

    test('3. summarizing E017：事件摘要 JSON 解析失败 → 自动重试用尽 → failed', () async {
      // V2 四步流程：revising 纯文本不再解析事件摘要，摘要提取移至 summarizing 阶段。
      // summarizing 降级链与 extracting 一致：fallback（parseEventSummary）→ JSON 模式。
      //
      // 配置 summarizingMaxRetries=1：首次 E017 + 1 次重试用尽 → failed。
      // extracting 前置，顺序为 extract + draft + revise +
      //           首次 summarize[fallback+JSON](2) + 重试 summarize[fallback+JSON](2) = 7
      final httpClient = _SseHttpClient([
        _extractKeywordsSse(),
        _draftV2('草稿正文'),
        _reviseV2('修正回复'),
        _buildSseText('不是合法 JSON 的摘要'), // 首次 summarize fallback：失败
        _buildSseText('仍不是合法 JSON'), // 首次 summarize JSON 模式：失败 → E017
        _buildSseText('重试仍非合法 JSON'), // 重试 summarize fallback：失败
        _buildSseText('重试 JSON 模式仍失败'), // 重试 JSON 模式：失败 → E017 用尽
      ]);
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository();
      final persistenceService = _StubPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        config: const IntermediateConfig(
          retry: RetryConfig(summarizingMaxRetries: 1),
        ),
      );

      await controller.sendMessage('测试输入');

      // E017 首次失败 + 1 次重试用尽 → failed
      expect(controller.state.phase, IntermediatePhase.failed);
      expect(controller.state.failureContext, isNotNull);
      expect(controller.state.failureContext!.errorCode, 'E017');
      expect(
        controller.state.failureContext!.failedPhase,
        IntermediatePhase.summarizing,
      );
      expect(controller.state.failureContext!.retryable, isTrue);
      // 失败前不持久化
      expect(persistenceService.persistRoundCalls, 0);
      // userInput 保留（供手动重试用）
      expect(controller.state.userInput, '测试输入');
      // retryCounts 记录 summarizing 重试 1 次
      expect(controller.state.retryCounts[IntermediatePhase.summarizing], 1);
    });

    test('3b. summarizing E017 自动重试成功 → idle', () async {
      // 首次 summarize 失败（JSON 解析失败），重试后第 2 次成功
      // extracting 前置，顺序为 extract + draft + revise +
      //           首次 summarize[fallback+JSON](2) + 重试 summarize(1，fallback 成功) = 6
      final httpClient = _SseHttpClient([
        _extractKeywordsSse(),
        _draftV2('草稿正文'),
        _reviseV2('修正回复'),
        _buildSseText('不是合法 JSON 的摘要'), // 首次 summarize fallback：失败
        _buildSseText('仍不是合法 JSON'), // 首次 summarize JSON 模式：失败 → E017
        _summarizeSse(summary: '重试成功摘要', importance: 3), // 重试 summarize：成功
      ]);
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository();
      final persistenceService = _StubPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        config: const IntermediateConfig(
          retry: RetryConfig(summarizingMaxRetries: 1),
        ),
      );

      await controller.sendMessage('测试输入');

      // 自动重试后成功
      expect(controller.state.phase, IntermediatePhase.idle);
      expect(controller.state.messages.length, 2);
      expect(persistenceService.persistRoundCalls, 1);
      // 成功后 retryCounts 清零
      expect(controller.state.retryCounts, isEmpty);
    });

    test('3c. persisting E018 不可重试 → 直接 failed', () async {
      // E018 持久化失败 maxRetries=0，不自动重试直接 failed
      final httpClient = _SseHttpClient(
        _v2SuccessResponses(generated: '草稿正文', reply: '修正回复'),
      );
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository();
      // persistRound 抛异常 → E018
      final persistenceService = _FailingPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
      );

      await controller.sendMessage('测试输入');

      expect(controller.state.phase, IntermediatePhase.failed);
      expect(controller.state.failureContext!.errorCode, 'E018');
      expect(
        controller.state.failureContext!.failedPhase,
        IntermediatePhase.persisting,
      );
      // V2 四步流程：4 次 SSE 调用（无重试）
      expect(httpClient.callCount, 4);
    });

    test('4. retry 恢复：summarizing E017 用尽 → failed → 手动 retry() → 成功',
        () async {
      // 首次 sendMessage 中 summarizing E017 自动重试用尽 → failed
      // 手动 retry() 从 drafting 重新开始 → 成功
      // extracting 前置，首次 SSE：extract+draft+revise+summarize[fallback+JSON]+重试[fallback+JSON] = 7
      // 重试 SSE：extract+draft+revise+summarize = 4
      final httpClient = _SseHttpClient([
        _extractKeywordsSse(),
        _draftV2('首次草稿'),
        _reviseV2('首次修正回复'),
        _buildSseText('首次摘要非合法 JSON'), // 首次 summarize fallback：失败
        _buildSseText('首次 JSON 模式仍失败'), // 首次 summarize JSON：失败 → E017
        _buildSseText('重试摘要仍非合法 JSON'), // 重试 summarize fallback：失败
        _buildSseText('重试 JSON 模式仍失败'), // 重试 JSON：失败 → E017 用尽 → failed
        ..._v2SuccessResponses(generated: '手动重试草稿', reply: '手动重试成功'),
      ]);
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository();
      final persistenceService = _StubPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        config: const IntermediateConfig(
          stream: StreamConfig(skipReviewWhenEmptyRetrieval: false),
          retry: RetryConfig(summarizingMaxRetries: 1),
        ),
      );

      // 第一次发送 → summarizing E017 自动重试用尽 → failed
      await controller.sendMessage('测试输入');
      expect(controller.state.phase, IntermediatePhase.failed);
      expect(controller.state.failureContext!.errorCode, 'E017');
      expect(persistenceService.persistRoundCalls, 0);
      expect(httpClient.callCount, 7);

      // 手动重试 → 从 drafting 重新开始 → 成功
      await controller.retry();

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(controller.state.messages.length, 2);
      expect(persistenceService.persistRoundCalls, 1);
      expect(httpClient.callCount, 11);
    });

    test('5. 草稿会话物化：__draft_intermediate_ 前缀 → createSession 调用', () async {
      final httpClient = _SseHttpClient(
        _v2SuccessResponses(generated: '草稿正文', reply: '修正回复'),
      );
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository();
      final persistenceService = _StubPersistenceService();
      final controller = _buildController(
        session: _draftSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
      );

      // 初始为草稿会话
      expect(controller.isDraftSession, isTrue);

      await controller.sendMessage('第一条消息');

      // 物化后为真实会话
      expect(chatRepo.createSessionCalls.length, 1);
      expect(chatRepo.createSessionCalls.first, '草稿故事');
      expect(controller.isDraftSession, isFalse);
      expect(
        controller.state.session.sessionId.startsWith(
          IntermediateChatController.draftSessionIdPrefix,
        ),
        isFalse,
      );
      // 主链路正常完成
      expect(controller.state.phase, IntermediatePhase.idle);
      expect(controller.state.messages.length, 2);
      expect(persistenceService.persistRoundCalls, 1);
    });

    // ── V2 工具调用配置 + compact 降级 ────────────────────────────────

    test('6. toolCallingEnabled=false → extracting/summarizing 直接 JSON 模式',
        () async {
      // V2：toolCallingEnabled=false 时，handler 不走工具调用 fallback 路径，
      // 直接调用 _runJsonMode（1 个 SSE 请求，无降级链）。
      // 测试 stub 仍提供 JSON 文本 SSE，验证 controller 在禁用工具调用时仍能正常工作。
      final httpClient = _SseHttpClient(
        _v2SuccessResponses(generated: '草稿正文', reply: '修正后的回复'),
      );
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository();
      final persistenceService = _StubPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        config: const IntermediateConfig(
          stream: StreamConfig(
            toolCallingEnabled: false,
            skipReviewWhenEmptyRetrieval: false,
          ),
        ),
      );

      await controller.sendMessage('勇者前往后山');

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(controller.state.messages.length, 2);
      expect(controller.state.messages[1].content, '修正后的回复');
      expect(persistenceService.persistRoundCalls, 1);
      // V2 四步流程：4 次 SSE（draft + extract + revise + summarize）
      expect(httpClient.callCount, 4);
    });

    test('7. 检索为空 → revising 仍执行（润色模式，4 SSE）', () async {
      // 2026-07-16 优化项10：移除 compact 降级。
      // skipReviewWhenEmptyRetrieval 配置项保留但不再生效（向后兼容）。
      // 检索结果为空时 revising 仍执行，【相关往事】区块省略，revising 只做润色。
      // extracting 前置，总计 SSE：extract(1) + draft(1) + revise(1) + summarize(1) = 4
      final httpClient = _SseHttpClient([
        _extractKeywordsSse(),
        _draftV2('草稿正文'),
        _reviseV2('润色后的回复'),
        _summarizeSse(importance: 3),
      ]);
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository();
      final persistenceService = _StubPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        config: const IntermediateConfig(
          stream: StreamConfig(
            skipReviewWhenEmptyRetrieval: true, // 配置项保留但不再生效
          ),
        ),
      );

      await controller.sendMessage('勇者前往后山');

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(controller.state.messages.length, 2);
      // revising 始终执行：reply = revise 输出（非草稿）
      expect(controller.state.messages[1].content, '润色后的回复');
      expect(persistenceService.persistRoundCalls, 1);
      // 4 次 SSE（draft + extract + revise + summarize）
      expect(httpClient.callCount, 4);
      // extract 提取关键词 → 触发检索（结果为空，revising 仅做润色）
      expect(experienceRepo.searchExperiencesCalls, 1);
    });

    test('8. extracting 关键词为空 → 跳过检索 → revising 仍执行（润色模式）', () async {
      // 2026-07-16 优化项10：移除 compact 降级。
      // extracting 提取空关键词 → _runRetrievePhase 跳过检索
      // （keywords.isEmpty 不调用 searchExperiences）→ memories 空 →
      // revising 仍执行（【相关往事】区块省略，仅做润色）。
      // extracting 前置，总计 SSE：extract(1) + draft(1) + revise(1) + summarize(1) = 4
      final httpClient = _SseHttpClient([
        _extractKeywordsSse(
          characters: const [],
          items: const [],
          locations: const [],
          actions: const [],
          plots: const [],
        ), // 空关键词
        _draftV2('草稿正文'),
        _reviseV2('润色后的回复'),
        _summarizeSse(importance: 2),
      ]);
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository();
      final persistenceService = _StubPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        config: const IntermediateConfig(
          stream: StreamConfig(skipReviewWhenEmptyRetrieval: true),
        ),
      );

      await controller.sendMessage('测试空关键词');

      expect(controller.state.phase, IntermediatePhase.idle);
      // revising 始终执行：reply = revise 输出（非草稿）
      expect(controller.state.messages[1].content, '润色后的回复');
      expect(persistenceService.persistRoundCalls, 1);
      // 空关键词 → 不触发检索
      expect(experienceRepo.searchExperiencesCalls, 0);
      expect(httpClient.callCount, 4);
    });

    // ──  降级链路（V2 已移除分隔标记模式，以下测试改为 V2 等价场景）──

    test('10. drafting 流式中断 E016 → failed', () async {
      // V2：drafting 阶段 SSE 流中 StreamError 事件 → StreamErrorException → E016
      // 用 _streamErrorSse() 返回非法 JSON 的 SSE，SseParser 解析失败产生 StreamError
      // → StreamRunner 抛 StreamErrorException → _runDraftPhase catch → E016
      // extracting 前置，需先让 extract 成功，再让 draft 阶段失败
      // 配置 streamInterruptRetry=0：首次失败直接 failed（不重试）
      final httpClient = _SseHttpClient([
        _extractKeywordsSse(), // extract 成功
        _streamErrorSse(), // draft 阶段 SSE 错误 → E016
      ]);
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: _IntegrationChatRepository(),
        experienceRepo: _StubExperienceRepository(),
        persistenceService: _StubPersistenceService(),
        config: const IntermediateConfig(
          retry: RetryConfig(streamInterruptRetry: 0),
        ),
      );

      await controller.sendMessage('测试流式错误');

      expect(controller.state.phase, IntermediatePhase.failed);
      expect(controller.state.failureContext!.errorCode, 'E016');
      expect(
        controller.state.failureContext!.failedPhase,
        IntermediatePhase.generating,
      );
    });

    test('B11a. 上下文超限自愈：generating 超限 → 压缩一次 → 同阶段重试成功', () async {
      // 预置 5 轮历史（10 条消息）供压缩；轮前 shouldCompact=false（不与
      // 自愈路径混淆），超限发生在 generating 的流式错误事件里
      final history = <ChatMessage>[
        for (var i = 1; i <= 10; i++)
          ChatMessage(
            messageId: 'm$i',
            sessionId: 'real-session-1',
            role: i.isOdd ? 'user' : 'assistant',
            content: '第${(i + 1) ~/ 2}轮${i.isOdd ? '用户' : '回复'}',
            createdAt: DateTime(2026),
          ),
      ];
      final httpClient = _SseHttpClient([
        _extractKeywordsSse(),
        _contextOverflowSse(), // generating 首次：超限 → 自愈压缩
        _draftV2('压缩后生成的正文'), // 自愈重试：成功
        _summarizeSse(),
      ]);
      final chatRepo = _IntegrationChatRepository()..messages = history;
      final persistenceService = _StubPersistenceService();
      final compactionService = _FakeCompactionService()
        ..keepTail = 2
        ..shouldCompactReturn = false;
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: _StubExperienceRepository(),
        persistenceService: persistenceService,
        compactionService: compactionService,
        forceReviewEnabled: false,
      );

      await controller.sendMessage('第六轮输入');

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(
        compactionService.compactCalls,
        1,
        reason: '溢出自愈恰好触发一次压缩（与轮前压缩同管线）',
      );
      // 轮号与压缩基数走同一写回逻辑（口径）：5 轮历史 + 本轮 = 6
      expect(persistenceService.recordedArtifacts.single!.turnNumber, 6);
      expect(controller.state.compactedTurnBase, 4);
      expect(controller.state.failureContext, isNull);
    });

    test('B11b. 上下文超限自愈：压缩重试后仍超限 → failed + contextOverflow 专属文案', () async {
      final history = <ChatMessage>[
        for (var i = 1; i <= 10; i++)
          ChatMessage(
            messageId: 'm$i',
            sessionId: 'real-session-1',
            role: i.isOdd ? 'user' : 'assistant',
            content: '第${(i + 1) ~/ 2}轮${i.isOdd ? '用户' : '回复'}',
            createdAt: DateTime(2026),
          ),
      ];
      final httpClient = _SseHttpClient([
        _extractKeywordsSse(),
        _contextOverflowSse(), // 首次超限 → 自愈
        _contextOverflowSse(), // 自愈重试仍超限 → 失败终态
      ]);
      final chatRepo = _IntegrationChatRepository()..messages = history;
      final persistenceService = _StubPersistenceService();
      final compactionService = _FakeCompactionService()
        ..keepTail = 2
        ..shouldCompactReturn = false;
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: _StubExperienceRepository(),
        persistenceService: persistenceService,
        compactionService: compactionService,
        // streamInterruptRetry=0：E016 不进自动重试，直接 failed 终态
        config: const IntermediateConfig(
          retry: RetryConfig(streamInterruptRetry: 0),
        ),
        forceReviewEnabled: false,
      );

      await controller.sendMessage('第六轮输入');

      expect(controller.state.phase, IntermediatePhase.failed);
      expect(controller.state.failureContext!.errorCode, 'E016');
      expect(
        controller.state.failureContext!.errorCategory,
        ErrorCategory.contextOverflow,
        reason: '超限类别优先于阶段码默认分类',
      );
      expect(
        controller.state.failureContext!.errorMessage,
        contains('已自动压缩重试仍超限'),
      );
      expect(
        controller.state.failureContext!.errorMessage,
        contains('手动压缩或精简输入'),
      );
      expect(compactionService.compactCalls, 1, reason: '自愈只尝试一次');
    });

    test('B11c. 审查收官 R3-P1-1：超限不进自动重试（默认 streamInterruptRetry>0 也直进 failed）',
        () async {
      final history = <ChatMessage>[
        for (var i = 1; i <= 10; i++)
          ChatMessage(
            messageId: 'm$i',
            sessionId: 'real-session-1',
            role: i.isOdd ? 'user' : 'assistant',
            content: '第${(i + 1) ~/ 2}轮${i.isOdd ? '用户' : '回复'}',
            createdAt: DateTime(2026),
          ),
      ];
      final httpClient = _SseHttpClient([
        _extractKeywordsSse(),
        _contextOverflowSse(), // 首次超限 → 自愈压缩
        _contextOverflowSse(), // 自愈重试仍超限
        // 修复前：E016 自动重试会再发第三次请求（脚本耗尽→网关抛错）；
        // 修复后：超限直进 failed，不会有第三次请求
      ]);
      final chatRepo = _IntegrationChatRepository()..messages = history;
      final persistenceService = _StubPersistenceService();
      final compactionService = _FakeCompactionService()
        ..keepTail = 2
        ..shouldCompactReturn = false;
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: _StubExperienceRepository(),
        persistenceService: persistenceService,
        compactionService: compactionService,
        // 默认 streamInterruptRetry=1 不再显式置 0——验证超限跳过自动重试
        forceReviewEnabled: false,
      );

      await controller.sendMessage('第六轮输入');

      expect(controller.state.phase, IntermediatePhase.failed);
      expect(
        controller.state.failureContext!.errorCategory,
        ErrorCategory.contextOverflow,
      );
      expect(
        httpClient.callCount,
        3,
        reason: 'extract(1) + 生成×2（自愈前后各一）——修复前自动重试会再发第 4 次',
      );
      expect(compactionService.compactCalls, 1, reason: '自愈只压缩一次');
    });

    test('11. 检索为空 + revising 润色 + summarize 成功 → 完整链路（4 SSE）', () async {
      // 2026-07-16 优化项10：移除 compact 降级。
      // 检索为空时 revising 仍执行（润色模式），summarizing 生成事件摘要以持久化记忆。
      // 验证 replyText 来自 revising 输出，eventSummary 仍正常生成。
      final httpClient = _SseHttpClient([
        _extractKeywordsSse(),
        _draftV2('compact 草稿'),
        _reviseV2('润色后的回复'),
        _summarizeSse(summary: '润色模式摘要', importance: 2),
      ]);
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository();
      final persistenceService = _StubPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        config: const IntermediateConfig(
          stream: StreamConfig(skipReviewWhenEmptyRetrieval: true),
        ),
      );

      await controller.sendMessage('测试润色模式');

      expect(controller.state.phase, IntermediatePhase.idle);
      // revising 始终执行：reply = revise 输出（非草稿）
      expect(controller.state.messages[1].content, '润色后的回复');
      expect(persistenceService.persistRoundCalls, 1);
      // 4 次 SSE（含 revise）
      expect(httpClient.callCount, 4);
    });

    // ── + 多轮 artifacts 修复回归测试 ─────────────────────────────

    test('9. 多轮场景：artifacts turnNumber 递增，第二轮不覆盖第一轮', () async {
      // + 修复前：_runPersistPhase 漏刷新 state.session.messageCount，
      // 第二轮 turnNumber 算成 1，artifacts 错误覆盖第一轮，UI 显示消失。
      // 修复后：turnNumber 基于 state.messages.length 推导 + 持久化后刷新 messageCount。
      // V2 四步流程：2 轮 × 4 步 = 8 次 SSE
      final httpClient = _SseHttpClient([
        ..._v2SuccessResponses(generated: '草稿1正文', reply: '回复1'),
        ..._v2SuccessResponses(generated: '草稿2正文', reply: '回复2'),
      ]);
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository();
      final persistenceService = _StubPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
      );

      // Round 1
      await controller.sendMessage('第一轮输入');

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(controller.state.messages.length, 2);
      expect(
        controller.state.artifactsByTurnNumber?[1],
        isNotNull,
        reason: '第一轮 artifacts 应存在',
      );
      expect(
        controller.state.artifactsByTurnNumber?[1]!.generatedText,
        '草稿1正文',
      );
      expect(
        controller.state.session.messageCount,
        2,
        reason: '第一轮持久化后 messageCount 应刷新为 2',
      );

      // Round 2
      await controller.sendMessage('第二轮输入');

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(controller.state.messages.length, 4);
      // 关键断言：两轮 artifacts 都在 state 里，第二轮不覆盖第一轮
      expect(
        controller.state.artifactsByTurnNumber?[1],
        isNotNull,
        reason: '第一轮 artifacts 应保留',
      );
      expect(
        controller.state.artifactsByTurnNumber?[2],
        isNotNull,
        reason: '第二轮 artifacts 应存在',
      );
      expect(
        controller.state.artifactsByTurnNumber?[1]!.generatedText,
        '草稿1正文',
        reason: '第一轮 generatedText 未被覆盖',
      );
      expect(
        controller.state.artifactsByTurnNumber?[2]!.generatedText,
        '草稿2正文',
      );
      expect(controller.state.artifactsByTurnNumber?[2]!.turnNumber, 2);
      // session.messageCount 同步刷新（修复方向 A）
      expect(
        controller.state.session.messageCount,
        4,
        reason: '第二轮持久化后 messageCount 应刷新为 4',
      );
      // 持久化调用的 artifacts.turnNumber 递增（修复方向 B）
      expect(persistenceService.recordedArtifacts, hasLength(2));
      expect(persistenceService.recordedArtifacts[0]!.turnNumber, 1);
      expect(persistenceService.recordedArtifacts[1]!.turnNumber, 2);
      // V2 四步流程：8 次 SSE 调用（2 轮 × 4 步）
      expect(httpClient.callCount, 8);
    });
  });

  // ── P3：pendingUserMessage 操作（失败/取消后保留消息的可操作性）─────
  //
  // 验证 DOC-09A-2 §6.5 修订：失败/取消后 pendingUserMessage 保留在 UI，
  // 用户可编辑重发/复制/删除。覆盖 editPendingUserMessage / deletePendingUserMessage
  // 两个新方法的状态转换 + 守卫逻辑。
  group('pendingUserMessage 操作', () {
    test('1. E017 失败后 pendingUserMessage 保留 + deletePendingUserMessage 清空',
        () async {
      // 触发 E017 失败（summarizing JSON 解析失败，summarizingMaxRetries=0 直接 failed）
      // → pendingUserMessage 保留 → deletePendingUserMessage 清空
      // extracting 前置，SSE：extract+draft+revise+summarize[fallback+JSON] = 5
      final httpClient = _SseHttpClient([
        _extractKeywordsSse(),
        _draftV2('草稿正文'),
        _reviseV2('修正回复'),
        _buildSseText('不是合法 JSON 的摘要'), // summarize fallback：失败
        _buildSseText('仍不是合法 JSON'), // summarize JSON 模式：失败 → E017
      ]);
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository();
      final persistenceService = _StubPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        config: const IntermediateConfig(
          stream: StreamConfig(skipReviewWhenEmptyRetrieval: false),
          retry: RetryConfig(summarizingMaxRetries: 0),
        ),
      );

      await controller.sendMessage('测试输入');

      // 失败后 pendingUserMessage 保留
      expect(controller.state.phase, IntermediatePhase.failed);
      expect(controller.state.pendingUserMessage, isNotNull);
      expect(controller.state.pendingUserMessage!.content, '测试输入');
      expect(controller.state.userInput, '测试输入');

      // 删除 pendingUserMessage
      controller.deletePendingUserMessage();
      expect(controller.state.phase, IntermediatePhase.idle);
      expect(controller.state.pendingUserMessage, isNull);
      expect(controller.state.userInput, isNull);
      expect(controller.state.failureContext, isNull);
    });

    test('2. clearRound 清空 pendingUserMessage，并保留 userInput 供输入框回填', () async {
      // 触发 E017 失败 → clearRound（"清空本轮"按钮）→ 临时气泡消失，
      // 原输入保留，由页面层回填输入框。
      final httpClient = _SseHttpClient([
        _extractKeywordsSse(),
        _draftV2('草稿正文'),
        _reviseV2('修正回复'),
        _buildSseText('不是合法 JSON 的摘要'),
        _buildSseText('仍不是合法 JSON'),
      ]);
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository();
      final persistenceService = _StubPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        config: const IntermediateConfig(
          stream: StreamConfig(skipReviewWhenEmptyRetrieval: false),
          retry: RetryConfig(summarizingMaxRetries: 0),
        ),
      );

      await controller.sendMessage('测试输入');
      expect(controller.state.phase, IntermediatePhase.failed);

      // clearRound（对应 UI"清空本轮"按钮）
      controller.clearRound();
      expect(controller.state.phase, IntermediatePhase.idle);
      expect(controller.state.pendingUserMessage, isNull);
      expect(controller.state.userInput, '测试输入');
    });

    test('3. deletePendingUserMessage 守卫：无 pendingUserMessage → 无操作', () async {
      final controller = _buildController(
        session: _realSession(),
        httpClient: _SseHttpClient([]),
        chatRepo: _IntegrationChatRepository(),
        experienceRepo: _StubExperienceRepository(),
        persistenceService: _StubPersistenceService(),
      );

      // 初始状态无 pendingUserMessage
      expect(controller.state.pendingUserMessage, isNull);
      expect(controller.state.phase, IntermediatePhase.idle);

      // 调用 deletePendingUserMessage 应无效果
      controller.deletePendingUserMessage();
      expect(controller.state.pendingUserMessage, isNull);
      expect(controller.state.phase, IntermediatePhase.idle);
    });

    test('4. editPendingUserMessage：失败后编辑重发 → 新内容走 sendMessage', () async {
      // 触发 E017 失败 → editPendingUserMessage 用新内容重发 → 成功
      // extracting 前置，首次 SSE：extract+draft+revise+summarize[fallback+JSON] = 5
      // 重发 SSE：extract+draft+revise+summarize = 4
      final httpClient = _SseHttpClient([
        // 首次发送（失败）
        _extractKeywordsSse(),
        _draftV2('首次草稿'),
        _reviseV2('首次修正回复'),
        _buildSseText('不是合法 JSON 的摘要'),
        _buildSseText('仍不是合法 JSON'),
        // 编辑重发（成功）
        ..._v2SuccessResponses(generated: '编辑后草稿', reply: '编辑后回复'),
      ]);
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository();
      final persistenceService = _StubPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        config: const IntermediateConfig(
          stream: StreamConfig(skipReviewWhenEmptyRetrieval: false),
          retry: RetryConfig(summarizingMaxRetries: 0),
        ),
      );

      // 首次发送 → 失败
      await controller.sendMessage('原始输入');
      expect(controller.state.phase, IntermediatePhase.failed);
      expect(controller.state.pendingUserMessage!.content, '原始输入');

      // 编辑重发
      await controller.editPendingUserMessage('编辑后的新内容');

      // 重发成功（skipReviewWhenEmptyRetrieval=false → 走完整 4 步链路）
      expect(controller.state.phase, IntermediatePhase.idle);
      expect(controller.state.pendingUserMessage, isNull); // 持久化后清空
      expect(controller.state.messages.length, 2); // user + assistant
      expect(controller.state.messages[0].content, '编辑后的新内容');
      expect(controller.state.messages[1].role, 'assistant');
      expect(controller.state.messages[1].content, '编辑后回复');
      expect(persistenceService.persistRoundCalls, 1);
    });

    test('5. editPendingUserMessage 守卫：无 pendingUserMessage → 无操作', () async {
      final controller = _buildController(
        session: _realSession(),
        httpClient: _SseHttpClient([]),
        chatRepo: _IntegrationChatRepository(),
        experienceRepo: _StubExperienceRepository(),
        persistenceService: _StubPersistenceService(),
      );

      expect(controller.state.pendingUserMessage, isNull);
      await controller.editPendingUserMessage('新内容');
      // 无 pendingUserMessage，守卫直接 return，state 不变
      expect(controller.state.phase, IntermediatePhase.idle);
      expect(controller.state.messages, isEmpty);
    });
  });

  // ── ：ErrorCategory 分流 ─────────────────────────────────────
  //
  // 验证 _fail 改造后，分类器按异常类型/HTTP 状态码自动分流 ErrorCategory，
  // 以及 errorCategory 手动覆盖（config/format/persist）的优先级。
  // 权威设计：DOC-09B §9。
  group('ErrorCategory 分流', () {
    // ── 调用点6（draft phase failed, catch e）：streamPost 抛 HTTP 异常 ──
    // error=e，无 errorCategory 覆盖 → 分类器按异常类型决定 category。
    // 配置 RetryConfig(generatingMaxRetries: 0) 避免自动重试，抛1次即 failed。
    // extracting 前置，需先用 firstResponses 让 extract 成功，再让 draft 抛异常。

    test('A. drafting 401 → E010 + auth', () async {
      final httpClient = _ErrorHttpClient(
        const AppHttpException(
          'Unauthorized',
          code: 'bad_response',
          statusCode: 401,
        ),
        firstResponses: [_extractKeywordsSse()], // extract 成功
      );
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: _IntegrationChatRepository(),
        experienceRepo: _StubExperienceRepository(),
        persistenceService: _StubPersistenceService(),
        config: const IntermediateConfig(
          retry: RetryConfig(generatingMaxRetries: 0),
        ),
      );

      await controller.sendMessage('测试');

      expect(controller.state.phase, IntermediatePhase.failed);
      final ctx = controller.state.failureContext!;
      expect(ctx.errorCode, 'E010');
      expect(ctx.errorCategory, ErrorCategory.auth);
      expect(ctx.httpStatus, 401);
      expect(ctx.rawError, isNotNull);
    });

    test('B. drafting 429 → E010 + rateLimit', () async {
      final httpClient = _ErrorHttpClient(
        const AppHttpException(
          'Too Many Requests',
          code: 'bad_response',
          statusCode: 429,
        ),
        firstResponses: [_extractKeywordsSse()], // extract 成功
      );
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: _IntegrationChatRepository(),
        experienceRepo: _StubExperienceRepository(),
        persistenceService: _StubPersistenceService(),
        config: const IntermediateConfig(
          retry: RetryConfig(generatingMaxRetries: 0),
        ),
      );

      await controller.sendMessage('测试');

      expect(controller.state.phase, IntermediatePhase.failed);
      final ctx = controller.state.failureContext!;
      expect(ctx.errorCode, 'E010');
      expect(ctx.errorCategory, ErrorCategory.rateLimit);
      expect(ctx.httpStatus, 429);
    });

    test('C. drafting 500 → E010 + server', () async {
      final httpClient = _ErrorHttpClient(
        const AppHttpException(
          'Internal Server Error',
          code: 'bad_response',
          statusCode: 500,
        ),
        firstResponses: [_extractKeywordsSse()], // extract 成功
      );
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: _IntegrationChatRepository(),
        experienceRepo: _StubExperienceRepository(),
        persistenceService: _StubPersistenceService(),
        config: const IntermediateConfig(
          retry: RetryConfig(generatingMaxRetries: 0),
        ),
      );

      await controller.sendMessage('测试');

      expect(controller.state.phase, IntermediatePhase.failed);
      final ctx = controller.state.failureContext!;
      expect(ctx.errorCode, 'E010');
      expect(ctx.errorCategory, ErrorCategory.server);
      expect(ctx.httpStatus, 500);
    });

    test('D. drafting connection_error → E010 + network', () async {
      final httpClient = _ErrorHttpClient(
        const AppHttpException(
          'Connection failed',
          code: 'connection_error',
        ),
        firstResponses: [_extractKeywordsSse()], // extract 成功
      );
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: _IntegrationChatRepository(),
        experienceRepo: _StubExperienceRepository(),
        persistenceService: _StubPersistenceService(),
        config: const IntermediateConfig(
          retry: RetryConfig(generatingMaxRetries: 0),
        ),
      );

      await controller.sendMessage('测试');

      expect(controller.state.phase, IntermediatePhase.failed);
      final ctx = controller.state.failureContext!;
      expect(ctx.errorCode, 'E010');
      expect(ctx.errorCategory, ErrorCategory.network);
      expect(ctx.httpStatus, isNull);
    });

    test('E. drafting connection_timeout → E010 + timeout', () async {
      final httpClient = _ErrorHttpClient(
        const AppHttpException(
          'Connection timeout',
          code: 'connection_timeout',
        ),
        firstResponses: [_extractKeywordsSse()], // extract 成功
      );
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: _IntegrationChatRepository(),
        experienceRepo: _StubExperienceRepository(),
        persistenceService: _StubPersistenceService(),
        config: const IntermediateConfig(
          retry: RetryConfig(generatingMaxRetries: 0),
        ),
      );

      await controller.sendMessage('测试');

      expect(controller.state.phase, IntermediatePhase.failed);
      final ctx = controller.state.failureContext!;
      expect(ctx.errorCode, 'E010');
      expect(ctx.errorCategory, ErrorCategory.timeout);
      expect(ctx.httpStatus, isNull);
    });

    // ── 调用点2（namingConfig 为空）：errorCategory=config 手动覆盖，无 error ──

    test('F. E010 config（namingConfig 为空）→ errorCategory=config', () async {
      // _EmptyNamingConfigResolver 返回空 NamingConfig → 触发调用点2
      // errorCategory=config（手动覆盖），无 error → rawError/httpStatus 为 null
      final httpClient = _SseHttpClient(<String>[]);
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: _IntegrationChatRepository(),
        experienceRepo: _StubExperienceRepository(),
        persistenceService: _StubPersistenceService(),
        configurationResolver: _EmptyNamingConfigResolver(),
      );

      await controller.sendMessage('测试');

      expect(controller.state.phase, IntermediatePhase.failed);
      final ctx = controller.state.failureContext!;
      expect(ctx.errorCode, 'E010');
      expect(ctx.errorCategory, ErrorCategory.config);
      expect(ctx.httpStatus, isNull);
      expect(ctx.rawError, isNull);
    });

    // ── 调用点4（extracting JSON 解析失败）：errorCategory=format ──

    test('G. E013 format（extracting 用尽）→ errorCategory=format', () async {
      // extracting 前置，extract 失败不进入 draft
      // 配置 extractingMaxRetries=0：首次失败直接 failed（不重试）
      // SSE：extract[fallback+JSON](2) = 2
      final httpClient = _SseHttpClient([
        _buildSseText('不是合法 JSON 的关键词'), // extract fallback：失败
        _buildSseText('仍不是合法 JSON'), // extract JSON 模式：失败 → E013
      ]);
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: _IntegrationChatRepository(),
        experienceRepo: _StubExperienceRepository(),
        persistenceService: _StubPersistenceService(),
        config: const IntermediateConfig(
          retry: RetryConfig(extractingMaxRetries: 0),
        ),
      );

      await controller.sendMessage('测试');

      expect(controller.state.phase, IntermediatePhase.failed);
      final ctx = controller.state.failureContext!;
      expect(ctx.errorCode, 'E013');
      expect(ctx.errorCategory, ErrorCategory.format);
      expect(ctx.httpStatus, isNull);
      expect(ctx.rawError, isNotNull);
    });

    // ── 调用点12（persist 失败）：error=e + errorCategory=persist 覆盖 ──

    test('H. E018 persist → errorCategory=persist', () async {
      final httpClient = _SseHttpClient(
        _v2SuccessResponses(generated: '草稿正文', reply: '修正回复'),
      );
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: _IntegrationChatRepository(),
        experienceRepo: _StubExperienceRepository(),
        persistenceService: _FailingPersistenceService(),
      );

      await controller.sendMessage('测试');

      expect(controller.state.phase, IntermediatePhase.failed);
      final ctx = controller.state.failureContext!;
      expect(ctx.errorCode, 'E018');
      expect(ctx.errorCategory, ErrorCategory.persist);
      expect(ctx.httpStatus, isNull);
      expect(ctx.rawError, isNotNull);
    });
  });

  // ── 会话级工具调用覆盖（V2，DOC-09B §8.6 / §10.2）────────────────────
  //
  // V2 四步流程：jsonModeOverride 非 null 时，_applyToolCallingOverride 强制覆盖
  // stream.toolCallingEnabled（控制 extracting/summarizing 的结构化输出策略）。
  // drafting/revising 始终走纯文本（runPlainText），不受此覆盖影响。
  //
  // stub 返回 JSON 文本（无 LlmToolCall* 事件），toolCallingEnabled=true 走
  // runWithToolCall fallback 解析、toolCallingEnabled=false 走 _runJsonMode 直接解析，
  // 两条路径均能解析 stub 的 JSON 文本，故 4 步链路均完成 4 次 SSE 请求。

  group('会话级工具调用覆盖（V2 行为）', () {
    test(
      'A. jsonModeOverride=true → 覆盖 toolCallingEnabled=true，V2 四步流程正常',
      () async {
        // 全局默认 toolCallingEnabled=true，override=true 一致，走工具调用 fallback 路径。
        final httpClient = _SseHttpClient(
          _v2SuccessResponses(generated: '草稿', reply: '回复'),
        );
        final chatRepo = _IntegrationChatRepository();
        final experienceRepo = _StubExperienceRepository();
        final persistenceService = _StubPersistenceService();
        final controller = _buildController(
          session: _realSession().copyWith(jsonModeOverride: true),
          httpClient: httpClient,
          chatRepo: chatRepo,
          experienceRepo: experienceRepo,
          persistenceService: persistenceService,
        );

        await controller.sendMessage('勇者前往后山');

        expect(controller.state.phase, IntermediatePhase.idle);
        expect(controller.state.messages.length, 2);
        expect(controller.state.messages[1].content, '回复');
        expect(persistenceService.persistRoundCalls, 1);
        expect(httpClient.callCount, 4); // V2 四步流程
      },
    );

    test(
      'B. jsonModeOverride=false → 覆盖 toolCallingEnabled=false，走 JSON 模式',
      () async {
        // override=false 强制 toolCallingEnabled=false，extracting/summarizing
        // 走 _runJsonMode 直接解析 JSON 文本（不发起工具调用）。
        final httpClient = _SseHttpClient(
          _v2SuccessResponses(generated: '草稿', reply: '回复'),
        );
        final chatRepo = _IntegrationChatRepository();
        final experienceRepo = _StubExperienceRepository();
        final persistenceService = _StubPersistenceService();
        final controller = _buildController(
          session: _realSession().copyWith(jsonModeOverride: false),
          httpClient: httpClient,
          chatRepo: chatRepo,
          experienceRepo: experienceRepo,
          persistenceService: persistenceService,
        );

        await controller.sendMessage('勇者前往后山');

        expect(controller.state.phase, IntermediatePhase.idle);
        expect(controller.state.messages.length, 2);
        expect(controller.state.messages[1].content, '回复');
        expect(persistenceService.persistRoundCalls, 1);
        expect(httpClient.callCount, 4);
      },
    );

    test('C. jsonModeOverride=null → 跟随全局配置（V2 默认行为）', () async {
      final httpClient = _SseHttpClient(
        _v2SuccessResponses(generated: '默认草稿', reply: '默认回复'),
      );
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository();
      final persistenceService = _StubPersistenceService();
      final controller = _buildController(
        session: _realSession(), // jsonModeOverride 默认 null
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
      );

      await controller.sendMessage('勇者前往后山');

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(controller.state.messages[1].content, '默认回复');
      expect(httpClient.callCount, 4);
    });
  });

  // ── ：revising 始终执行测试（2026-07-16 优化项10 修订）─────────
  //
  // 移除 compact 降级后，revising 始终执行：
  // - 检索结果全部低质量 → 注入前质量过滤（双阈值取严格）过滤掉全部记忆，
  //   【相关往事】区块省略，revising 仅做润色。
  // - 检索结果数量不足/低质量 → 同上，revising 仍执行。
  // - 高质量检索结果 → 正常注入【相关往事】区块，revising 按记忆修正 + 润色。
  // - skipReviewWhenEmptyRetrieval 配置项保留但不再生效（向后兼容）。
  // 设计文档：DOC-09A-1 §3.7（修订，2026-07-16 更新）。
  group('B4-4 revising 始终执行（原 skipRevise 扩展条件）', () {
    /// 构造低质量 ScoredMemory（vectorScore < threshold 且 fts5Score == 0）
    ScoredMemory lowQualityMemory(String sessionId) {
      return ScoredMemory(
        memory: ExperientialMemory(
          memoryId: 'low-1',
          sessionId: sessionId,
          summary: '不相关的旧记忆',
          importance: 1,
          tags: const [],
          turnNumber: 0,
          createdAt: DateTime(2025),
        ),
        fts5Score: 0,
        vectorScore: 0.1, // < 默认 threshold 0.3
        temporalScore: 0,
        finalScore: 0.1,
      );
    }

    /// 构造高质量 ScoredMemory（vectorScore >= threshold）
    ScoredMemory highQualityMemory(String sessionId) {
      return ScoredMemory(
        memory: ExperientialMemory(
          memoryId: 'high-1',
          sessionId: sessionId,
          summary: '高度相关的探索经历',
          importance: 4,
          tags: const ['探索'],
          turnNumber: 0,
          createdAt: DateTime(2025),
        ),
        fts5Score: 0.8,
        vectorScore: 0.7, // >= 默认 threshold 0.3
        temporalScore: 0,
        finalScore: 0.75,
      );
    }

    test('A. allLowQuality：检索结果全部低质量 → 质量过滤后无注入 → revising 仅润色', () async {
      // 2026-07-16 优化项5/10：移除 compact 降级 + 注入前质量过滤（双阈值取严格）。
      // 检索结果全部低质量（finalScore=0.1 < 绝对阈值 0.4）→ 全部被过滤掉，
      // 【相关往事】区块省略，revising 仍执行（仅做润色）。
      // extracting 前置，SSE：extract+draft+revise+summarize = 4
      final httpClient = _SseHttpClient([
        _extractKeywordsSse(),
        _draftV2('草稿正文'),
        _reviseV2('润色后的回复'),
        _summarizeSse(importance: 2),
      ]);
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository()
        // 注入全部低质量检索结果（会被质量过滤掉）
        ..returnValue = [lowQualityMemory('sess-1')];
      final persistenceService = _StubPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        config: const IntermediateConfig(
          stream: StreamConfig(skipReviewWhenEmptyRetrieval: true),
        ),
      );

      await controller.sendMessage('勇者前往后山');

      expect(controller.state.phase, IntermediatePhase.idle);
      // revising 始终执行：reply = revise 输出（润色后的回复，非草稿）
      expect(controller.state.messages[1].content, '润色后的回复');
      expect(persistenceService.persistRoundCalls, 1);
      expect(experienceRepo.searchExperiencesCalls, 1);
      expect(httpClient.callCount, 4); // revising 仍执行
    });

    test('B. fewAndLowQuality：检索结果 1 条且低质量 → 质量过滤后无注入 → revising 仅润色',
        () async {
      // 2026-07-16 优化项5/10：同测试 A，仅 1 条低质量结果（同样被质量过滤掉）。
      final httpClient = _SseHttpClient([
        _extractKeywordsSse(),
        _draftV2('草稿正文'),
        _reviseV2('润色后的回复'),
        _summarizeSse(importance: 2),
      ]);
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository()
        // 仅 1 条低质量结果（会被质量过滤掉）
        ..returnValue = [lowQualityMemory('sess-1')];
      final persistenceService = _StubPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        config: const IntermediateConfig(
          stream: StreamConfig(skipReviewWhenEmptyRetrieval: true),
        ),
      );

      await controller.sendMessage('勇者前往后山');

      expect(controller.state.phase, IntermediatePhase.idle);
      // revising 始终执行：reply = revise 输出（润色后的回复，非草稿）
      expect(controller.state.messages[1].content, '润色后的回复');
      expect(httpClient.callCount, 4);
    });

    test('C. 高质量检索结果 → 正常注入【相关往事】→ reply=revise 输出', () async {
      // 2026-07-16 优化项10：revising 始终执行，高质量记忆通过质量过滤被注入。
      // 走完整 4 步链路。
      final httpClient = _SseHttpClient(
        _v2SuccessResponses(generated: '草稿正文', reply: '修正后的回复'),
      );
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository()
        // 注入高质量检索结果（finalScore=0.75 ≥ 绝对阈值 0.4）
        ..returnValue = [highQualityMemory('sess-1')];
      final persistenceService = _StubPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        config: const IntermediateConfig(
          stream: StreamConfig(
            skipReviewWhenEmptyRetrieval: true, // 配置项保留但不再生效
          ),
        ),
      );

      await controller.sendMessage('勇者前往后山');

      expect(controller.state.phase, IntermediatePhase.idle);
      // revising 始终执行：reply = revise 输出（"修正后的回复"）
      expect(controller.state.messages[1].content, '修正后的回复');
      expect(httpClient.callCount, 4); // 完整 4 步
    });

    test('D. skipReviewWhenEmptyRetrieval=false → 配置项不再生效 → revising 仍执行',
        () async {
      // 2026-07-16 优化项10：skipReviewWhenEmptyRetrieval 配置项保留但不再生效。
      // 无论 true/false，revising 始终执行。
      final httpClient = _SseHttpClient(
        _v2SuccessResponses(generated: '草稿正文', reply: '修正后的回复'),
      );
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository()
        // 全部低质量，会被质量过滤掉，但 revising 仍执行
        ..returnValue = [lowQualityMemory('sess-1')];
      final persistenceService = _StubPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        config: const IntermediateConfig(
          stream: StreamConfig(
            skipReviewWhenEmptyRetrieval: false, // 配置项不再生效
          ),
        ),
      );

      await controller.sendMessage('勇者前往后山');

      expect(controller.state.phase, IntermediatePhase.idle);
      // revising 始终执行：reply = revise 输出
      expect(controller.state.messages[1].content, '修正后的回复');
      expect(httpClient.callCount, 4);
    });
  });

  // ── ：纯语义候选独立低阈召回──
  //
  // FTS 未命中（<0.02）的 vector-only 候选不走 absoluteThreshold=0.5
  // （该阈在 finalScore=vec/2 刻度下等价于原始 cosine ≥0.625，跨轮非
  // 对称嵌入的典型 0.3-0.6 全灭）；改为原始 cosine ≥
  // vector_only_cosine_floor（默认 0.3）即保留。混合命中仍走双阈值。
  group('D3（ST9-2）：纯语义候选独立低阈召回', () {
    /// vector-only 候选：FTS 空，vectorScore=(cosine+1)/2 归一化
    ScoredMemory vectorOnlyMemory(
      String sessionId, {
      required double cosine,
      double fts5 = 0,
    }) {
      final vec = (cosine + 1) / 2;
      return ScoredMemory(
        memory: ExperientialMemory(
          memoryId: 'vec-only-$cosine',
          sessionId: sessionId,
          summary: '语义弱相关的跨轮旧记忆',
          importance: 3,
          tags: const [],
          turnNumber: 0,
          createdAt: DateTime(2025),
        ),
        fts5Score: fts5,
        vectorScore: vec,
        temporalScore: 0,
        // FTS=0 时 repo 公式：finalScore = fts5×0.5 + vec×0.5 = vec/2
        finalScore: fts5 * 0.5 + vec * 0.5,
      );
    }

    test('FTS 空 + cosine≈0.4 → 过独立低阈被召回（请求体含记忆文本）', () async {
      final httpClient = _SseHttpClient(
        _v2SuccessResponses(
          generated: '草稿正文',
          reply: '修正后的回复',
        ),
      );
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository()
        // cosine 0.4：旧逻辑 finalScore=0.7×0.5=0.35 < 0.5 被滤（窄带）；
        //  后过独立低阈 0.3 被召回
        ..returnValue = [vectorOnlyMemory('sess-1', cosine: 0.4)];
      final persistenceService = _StubPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
      );

      await controller.sendMessage('勇者前往后山');

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(
        httpClient.bodies.any((b) => b != null && b.contains('语义弱相关的跨轮旧记忆')),
        isTrue,
        reason: 'cosine 0.4 ≥ 独立低阈 0.3：纯语义候选应注入生成请求',
      );
    });

    test('FTS 空 + cosine 0.2 < 独立低阈 0.3 → 仍被过滤', () async {
      final httpClient = _SseHttpClient(
        _v2SuccessResponses(
          generated: '草稿正文',
          reply: '修正后的回复',
        ),
      );
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository()
        ..returnValue = [vectorOnlyMemory('sess-1', cosine: 0.2)];
      final persistenceService = _StubPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
      );

      await controller.sendMessage('勇者前往后山');

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(
        httpClient.bodies.any((b) => b != null && b.contains('语义弱相关的跨轮旧记忆')),
        isFalse,
        reason: 'cosine 0.2 < 独立低阈 0.3：低相关候选不注入',
      );
    });

    test('混合命中（FTS≥0.02）仍走双阈值：finalScore<0.5 被滤不受 D3 影响', () async {
      final httpClient = _SseHttpClient(
        _v2SuccessResponses(
          generated: '草稿正文',
          reply: '修正后的回复',
        ),
      );
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository()
        // cosine 0.4（高向量）但 FTS 也有分 → 混合候选走 absoluteThreshold；
        // finalScore = 0.02×0.5 + 0.7×0.5 = 0.36 < 0.5 → 被滤
        ..returnValue = [
          vectorOnlyMemory('sess-1', cosine: 0.4, fts5: 0.02),
        ];
      final persistenceService = _StubPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
      );

      await controller.sendMessage('勇者前往后山');

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(
        httpClient.bodies.any((b) => b != null && b.contains('语义弱相关的跨轮旧记忆')),
        isFalse,
        reason: '混合命中不受独立低阈豁免：finalScore<absoluteThreshold 仍被滤',
      );
    });
  });

  // ── revising 可选化（默认关）──────────────────────────────
  //
  // reviewEnabled=false（默认）→ 草稿即终稿，跳过 revising，3 次 LLM 调用
  // reviewEnabled=true → 执行 revising 双保险审查，4 次 LLM 调用
  // 优先级：会话级 reviewEnabledOverride > 全局 reviewEnabled
  group('revising 可选化', () {
    test('A. reviewEnabled=false（默认）→ 跳过 revising，草稿即终稿，3 次 SSE', () async {
      // 只需 3 个响应：extract + draft + summarize（无 revise）
      final httpClient = _SseHttpClient([
        _extractKeywordsSse(),
        _draftV2('草稿正文'),
        _summarizeSse(),
      ]);
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository();
      final persistenceService = _StubPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        // 关闭 reviewEnabled：使用默认 false，不强制
        forceReviewEnabled: false,
      );

      await controller.sendMessage('勇者前往后山');

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(controller.state.messages.length, 2);
      // 草稿即终稿：reply = 草稿（非 revise 输出）
      expect(controller.state.messages[1].content, '草稿正文');
      expect(persistenceService.persistRoundCalls, 1);
      // 3 次 SSE（extract + draft + summarize，无 revise）
      expect(httpClient.callCount, 3);
    });

    test('B. reviewEnabled=true → 执行 revising，4 次 SSE', () async {
      final httpClient = _SseHttpClient(
        _v2SuccessResponses(generated: '草稿正文', reply: '修正后的回复'),
      );
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository();
      final persistenceService = _StubPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        // 默认 forceReviewEnabled=true
      );

      await controller.sendMessage('勇者前往后山');

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(controller.state.messages.length, 2);
      // revising 执行：reply = revise 输出
      expect(controller.state.messages[1].content, '修正后的回复');
      // 4 次 SSE（extract + draft + revise + summarize）
      expect(httpClient.callCount, 4);
    });

    test('C. 会话级 reviewEnabledOverride=true > 全局 false → 执行 revising',
        () async {
      final httpClient = _SseHttpClient(
        _v2SuccessResponses(generated: '草稿正文', reply: '修正后的回复'),
      );
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository();
      final persistenceService = _StubPersistenceService();
      // 会话级 override=true，全局 false（forceReviewEnabled=false 保持 config 原样）
      final session = _realSession().copyWith(
        reviewEnabledOverride: true,
      );
      final controller = _buildController(
        session: session,
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        forceReviewEnabled: false,
      );

      await controller.sendMessage('勇者前往后山');

      expect(controller.state.phase, IntermediatePhase.idle);
      // 会话级 override=true 优先级高于全局 false → 执行 revising
      expect(controller.state.messages[1].content, '修正后的回复');
      expect(httpClient.callCount, 4);
    });

    test('D. 会话级 reviewEnabledOverride=false > 全局 true → 跳过 revising',
        () async {
      final httpClient = _SseHttpClient([
        _extractKeywordsSse(),
        _draftV2('草稿正文'),
        _summarizeSse(),
      ]);
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository();
      final persistenceService = _StubPersistenceService();
      // 会话级 override=false，全局 true（forceReviewEnabled=true 强制全局 true）
      final session = _realSession().copyWith(
        reviewEnabledOverride: false,
      );
      final controller = _buildController(
        session: session,
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        // forceReviewEnabled=true 使全局 reviewEnabled=true，
        // 但会话级 override=false 应优先 → 跳过 revising
        forceReviewEnabled: true,
      );

      await controller.sendMessage('勇者前往后山');

      expect(controller.state.phase, IntermediatePhase.idle);
      // 会话级 override=false 优先级高于全局 true → 跳过 revising
      expect(controller.state.messages[1].content, '草稿正文');
      expect(httpClient.callCount, 3);
    });
  });

  group('轮内压缩后 turnNumber 不虚高', () {
    test('压缩当轮 persist 轮号 = 基数 + 可见轮数 + 1，不与全量列表双重计数', () async {
      // 预置 5 轮历史（10 条对话消息）：压缩边界覆盖前 4 轮（8 条）
      final history = <ChatMessage>[
        for (var i = 1; i <= 10; i++)
          ChatMessage(
            messageId: 'm$i',
            sessionId: 'real-session-1',
            role: i.isOdd ? 'user' : 'assistant',
            content: '第${(i + 1) ~/ 2}轮${i.isOdd ? '用户' : '回复'}',
            createdAt: DateTime(2026),
          ),
      ];
      final httpClient = _SseHttpClient(_v2SuccessResponses());
      final chatRepo = _IntegrationChatRepository()..messages = history;
      final experienceRepo = _StubExperienceRepository();
      final persistenceService = _StubPersistenceService();
      final compactionService = _FakeCompactionService()..keepTail = 2;
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
        compactionService: compactionService,
      );

      await controller.sendMessage('第六轮输入');

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(compactionService.compactCalls, 1, reason: '本轮应触发一次压缩');
      // 真实轮号：5 轮历史 + 本轮 = 第 6 轮。
      // 修复前：基数(4) + 未同步的全量 10 条/2 + 1 = 10（双重计数，虚高）
      expect(
        persistenceService.recordedArtifacts.last!.turnNumber,
        6,
        reason: '压缩当轮 persist 的 artifacts 轮号必须等于真实轮次',
      );
      // 内存消息视图应同步为压缩后视图：摘要卡 + 保留尾部 + 本轮 2 条
      expect(
        controller.state.messages.length,
        5,
        reason: '摘要卡(1) + 保留尾部(2) + 本轮 user/assistant(2)',
      );
      expect(controller.state.messages.first.role, 'system');
      // 压缩基数已追加（供后续轮次与 UI artifacts 键查找使用）
      expect(controller.state.compactedTurnBase, 4);
    });
  });

  group('user-boundary 压缩轮号连续（turn 单一事实源）', () {
    // 预置 5 轮历史（10 条对话消息，sessionId 与 _realSession 一致）
    List<ChatMessage> seededHistory() => [
          for (var i = 1; i <= 10; i++)
            ChatMessage(
              messageId: 'm$i',
              sessionId: 'real-session-1',
              role: i.isOdd ? 'user' : 'assistant',
              content: '第${(i + 1) ~/ 2}轮${i.isOdd ? '用户' : '回复'}',
              createdAt: DateTime(2026),
            ),
        ];

    test('压缩边界落 user（keepTail=3 制造孤儿视图）→ 三处轮号仍同源不分裂', () async {
      final httpClient = _SseHttpClient(_v2SuccessResponses());
      // 计数器已物化：5 轮历史 → next_turn=6（存量会话首轮 persist 已写）
      final chatRepo = _IntegrationChatRepository()
        ..messages = seededHistory()
        ..scriptedSession = _realSession().copyWith(nextTurn: 6);
      final persistenceService = _StubPersistenceService();
      // keepTail=3 → boundary = history[6] = m7 = user 消息：
      // fake 压缩服务不经吸附，保留区头部出现孤儿 assistant——
      // 即使拿到这种（真实服务经  吸附后不可能产生的）分裂视图，
      // 计数器仍必须保证写入侧三处轮号一致。
      final compactionService = _FakeCompactionService()..keepTail = 3;
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: _StubExperienceRepository(),
        persistenceService: persistenceService,
        compactionService: compactionService,
        forceReviewEnabled: false,
      );

      await controller.sendMessage('第六轮输入');

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(compactionService.compactCalls, 1);
      //  核心断言：同事务三处轮号必须同源——
      // 修复前 eventSummary（轮前公式）与 artifacts/compaction（轮后公式）
      // 在 user-boundary 压缩下相差 1，当轮即分裂
      expect(persistenceService.recordedEventSummaries.single.turnNumber, 6);
      expect(persistenceService.recordedArtifacts.single!.turnNumber, 6);
      expect(persistenceService.recordedCompactions.single!.turnNumber, 6);
      // UI artifacts 键可查（state 侧同键写入）
      expect(controller.state.artifactsByTurnNumber?[6], isNotNull);
    });

    test('压缩当轮/次轮轮号连续、记忆不撞号（计数器驱动）', () async {
      final httpClient = _SseHttpClient(
        _v2SuccessResponses()..addAll(_v2SuccessResponses()),
      );
      final chatRepo = _IntegrationChatRepository()
        ..messages = seededHistory()
        ..scriptedSession = _realSession().copyWith(nextTurn: 6);
      final persistenceService = _StubPersistenceService();
      // keepTail=2 → boundary = assistant（对齐真实服务吸附后的语义）
      final compactionService = _FakeCompactionService()..keepTail = 2;
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: _StubExperienceRepository(),
        persistenceService: persistenceService,
        compactionService: compactionService,
        forceReviewEnabled: false,
      );

      // 第 6 轮（触发压缩）
      await controller.sendMessage('第六轮输入');
      expect(controller.state.phase, IntermediatePhase.idle);
      expect(persistenceService.recordedEventSummaries.last.turnNumber, 6);

      // 模拟 persist 事务已把 next_turn 递增为 7（真实服务行为）
      chatRepo.scriptedSession =
          chatRepo.scriptedSession!.copyWith(nextTurn: 7);

      // 第 7 轮（压缩后首轮）
      await controller.sendMessage('第七轮输入');
      expect(controller.state.phase, IntermediatePhase.idle);

      // 当轮/次轮轮号连续：6 → 7
      expect(
        persistenceService.recordedEventSummaries
            .map((s) => s.turnNumber)
            .toList(),
        [6, 7],
        reason: '压缩当轮与次轮轮号必须连续（修复前次轮与上轮记忆撞号）',
      );
      // 记忆不撞号：两轮经历记忆的 turnNumber 互异
      expect(
        persistenceService.recordedEventSummaries
            .map((s) => s.turnNumber)
            .toSet(),
        hasLength(2),
      );
      // artifacts 可查：两轮键都在（UI 过程小窗可命中）
      expect(controller.state.artifactsByTurnNumber?.containsKey(6), isTrue);
      expect(controller.state.artifactsByTurnNumber?.containsKey(7), isTrue);
      // UI 公式侧（对齐视图下）与计数器一致：completedTurns = base + 可见轮数
      expect(controller.state.compactedTurnBase, 4);
    });

    test('计数器未物化（存量会话）→ 公式惰性回退且与计数器路径等值', () async {
      final httpClient = _SseHttpClient(_v2SuccessResponses());
      final chatRepo = _IntegrationChatRepository()..messages = seededHistory();
      // scriptedSession = null → getSession 抛错 → 控制器静默回退公式
      final persistenceService = _StubPersistenceService();
      final compactionService = _FakeCompactionService()..keepTail = 2;
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: _StubExperienceRepository(),
        persistenceService: persistenceService,
        compactionService: compactionService,
        forceReviewEnabled: false,
      );

      await controller.sendMessage('第六轮输入');

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(
        persistenceService.recordedEventSummaries.single.turnNumber,
        6,
        reason: '公式回退（base+可见轮数+1）与计数器在对齐视图下等值',
      );
    });
  });

  group('manualCompact 手动压缩（B5 上下文用量指示 §4.3）', () {
    /// 5 轮完整对话（满足 minDialogueMessages=8 下限）
    List<ChatMessage> dialogueHistory() => [
          for (var i = 1; i <= 10; i++)
            ChatMessage(
              messageId: 'mc$i',
              sessionId: 'real-session-1',
              role: i.isOdd ? 'user' : 'assistant',
              content: '第${(i + 1) ~/ 2}轮',
              createdAt: DateTime(2026),
            ),
        ];

    /// 等构造函数触发的 loadHistory（纯微任务链）完成后再操作
    Future<void> settleLoad() => Future<void>.delayed(Duration.zero);

    test('insufficient：对话不足（< minDialogueMessages）不发起压缩', () async {
      final compactionService = _FakeCompactionService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: _SseHttpClient(const []),
        chatRepo: _IntegrationChatRepository(),
        experienceRepo: _StubExperienceRepository(),
        persistenceService: _StubPersistenceService(),
        compactionService: compactionService,
        forceReviewEnabled: false,
      );
      await settleLoad();

      final result = await controller.manualCompact();

      expect(result, ManualCompactResult.insufficient);
      expect(compactionService.compactCalls, 0);
      expect(controller.state.isManualCompacting, isFalse);
    });

    test('busy：压缩进行中重复调用被拒（压缩事务先行）', () async {
      final chatRepo = _IntegrationChatRepository()
        ..messages = dialogueHistory();
      final compactionService = _GatedCompactionService();
      final persistenceService = _ManualCompactRecordingPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: _SseHttpClient(const []),
        chatRepo: chatRepo,
        experienceRepo: _StubExperienceRepository(),
        persistenceService: persistenceService,
        compactionService: compactionService,
        forceReviewEnabled: false,
      );
      await settleLoad();

      final first = controller.manualCompact();
      // 门闸未开：压缩挂起中，第二次调用必须 busy 且不影响首轮
      final second = await controller.manualCompact();
      expect(second, ManualCompactResult.busy);
      expect(controller.state.isManualCompacting, isTrue);
      expect(persistenceService.manualCompactions, isEmpty);

      compactionService.release.complete();
      expect(await first, ManualCompactResult.success);
      expect(controller.state.isManualCompacting, isFalse);
    });

    // 的「控制器 dispose 冲刷缓冲」。
    // 压缩流中途控制器被销毁（family 非 autoDispose 下的热重载/测试
    // teardown 等价路径）时，32ms Timer 回调不得对已 dispose 的
    // StateNotifier 写 state；挂起尾段须在 dispose 时冲刷落账。
    test('XC7-4：dispose 冲刷压缩缓冲尾段，之后零写入', () async {
      final chatRepo = _IntegrationChatRepository()
        ..messages = dialogueHistory();
      final compactionService = _DeltaThenGateCompactionService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: _SseHttpClient(const []),
        chatRepo: chatRepo,
        experienceRepo: _StubExperienceRepository(),
        persistenceService: _ManualCompactRecordingPersistenceService(),
        compactionService: compactionService,
        forceReviewEnabled: false,
      );
      await settleLoad();

      // 前置：delta 已先于门闸到达并进入 32ms 合帧缓冲（state 未写入）
      unawaited(controller.manualCompact());
      // manualCompact 到 compact 之间有多级 await，轮询等到达门闸
      for (var i = 0; i < 50 && compactionService.compactCalls == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      expect(compactionService.compactCalls, 1);
      expect(controller.state.isManualCompacting, isTrue);
      expect(controller.state.manualCompactionDelta, isEmpty);

      String? lastDelta;
      controller
        ..addListener((s) => lastDelta = s.manualCompactionDelta)
        // 压缩挂起中销毁控制器
        ..dispose();

      // 冲刷语义：挂起尾段在 dispose 时落账（监听者收到一次通知）
      expect(
        lastDelta,
        isNotEmpty,
        reason: 'dispose 应冲刷压缩缓冲尾段（D6-6 拍板 a / XC7-4）',
      );

      // 零写入语义：等待超过合帧间隔，不得有任何挂起 Timer 再写 state
      //（修复前：32ms 后对已 dispose 的 StateNotifier 写 state → StateError）
      await Future<void>.delayed(const Duration(milliseconds: 60));
    });

    test('B1 批4：压缩摘要 delta 合帧——同步突发只通知一次', () async {
      final chatRepo = _IntegrationChatRepository()
        ..messages = dialogueHistory();
      final compactionService = _DeltaBurstCompactionService();
      final persistenceService = _ManualCompactRecordingPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: _SseHttpClient(const []),
        chatRepo: chatRepo,
        experienceRepo: _StubExperienceRepository(),
        persistenceService: persistenceService,
        compactionService: compactionService,
        forceReviewEnabled: false,
      );
      await settleLoad();

      // manualCompactionDelta 字段变化的通知次数（：此前每原始
      // delta 一次 state.copyWith 一次整页通知）
      var deltaNotifications = 0;
      controller.addListener((state) {
        if (state.manualCompactionDelta.isNotEmpty) {
          deltaNotifications++;
        }
      });

      final result = await controller.manualCompact();

      expect(result, ManualCompactResult.success);
      expect(
        deltaNotifications,
        1,
        reason: '10 个同步突发 delta 应合帧为一次 state 通知（完成时 flushAndDispose 保证尾段落账）',
      );
    });

    test('success：完整链路落库（摘要+边界+轮号）并复位状态', () async {
      final chatRepo = _IntegrationChatRepository()
        ..messages = dialogueHistory();
      // keepTail=2 → boundary = history[7] = mc8（assistant，对齐吸附语义）
      final compactionService = _FakeCompactionService()..keepTail = 2;
      final persistenceService = _ManualCompactRecordingPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: _SseHttpClient(const []),
        chatRepo: chatRepo,
        experienceRepo: _StubExperienceRepository(),
        persistenceService: persistenceService,
        compactionService: compactionService,
        forceReviewEnabled: false,
      );
      await settleLoad();

      final result = await controller.manualCompact();

      expect(result, ManualCompactResult.success);
      expect(controller.state.isManualCompacting, isFalse);
      expect(controller.state.manualCompactionError, isNull);
      expect(compactionService.compactCalls, 1);
      final recorded = persistenceService.manualCompactions.single;
      expect(recorded.summaryMessage.content, '前情摘要（累积）');
      expect(recorded.boundaryMessageId, 'mc8');
      expect(recorded.turnNumber, 5, reason: 'completedTurnCount(0, 10 条对话)');
      // 压缩后重载的过滤视图同步镜像到
      // session.messageCount（口径同 persist 路径）——stub 仓库未落压缩点，
      // 过滤视图仍是全量 10 条
      expect(controller.state.session.messageCount, 10);
    });

    test('failed（未配置模型）：错误文案直达故事设置指引', () async {
      final chatRepo = _IntegrationChatRepository()
        ..messages = dialogueHistory();
      final compactionService = _FakeCompactionService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: _SseHttpClient(const []),
        chatRepo: chatRepo,
        experienceRepo: _StubExperienceRepository(),
        persistenceService: _StubPersistenceService(),
        configurationResolver: _EmptyNamingConfigResolver(),
        compactionService: compactionService,
        forceReviewEnabled: false,
      );
      await settleLoad();

      final result = await controller.manualCompact();

      expect(result, ManualCompactResult.failed);
      expect(controller.state.isManualCompacting, isFalse);
      expect(controller.state.manualCompactionError, contains('未配置模型'));
      expect(compactionService.compactCalls, 0);
    });

    test('failed（压缩异常）：不落库、错误入面板可重试', () async {
      final chatRepo = _IntegrationChatRepository()
        ..messages = dialogueHistory();
      final compactionService = _ThrowingCompactionService();
      final persistenceService = _ManualCompactRecordingPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: _SseHttpClient(const []),
        chatRepo: chatRepo,
        experienceRepo: _StubExperienceRepository(),
        persistenceService: persistenceService,
        compactionService: compactionService,
        forceReviewEnabled: false,
      );
      await settleLoad();

      final result = await controller.manualCompact();

      expect(result, ManualCompactResult.failed);
      expect(controller.state.isManualCompacting, isFalse);
      expect(persistenceService.manualCompactions, isEmpty);
      expect(
        controller.state.manualCompactionError,
        contains('Mock compact failure'),
      );
    });
  });

  // ── ：手动压缩与消息操作互斥 ──────────────────────
  //
  // 手动压缩全程 phase 保持 idle、仅置 isManualCompacting=true，此前
  // regenerate/editAndResend/editMessageContent/deleteRound 四方法只守卫
  // phase——长压缩（LLM 流式可达数十秒）期间删/改轮次会产出引用已删
  // boundary 的悬空压缩点，或与压缩事务并发写库互相污染。
  group('手动压缩与消息操作互斥', () {
    test('压缩挂起中 deleteRound/regenerate/editAndResend/editContent 全被拒',
        () async {
      final chatRepo = _IntegrationChatRepository()
        ..messages = [
          for (var i = 1; i <= 10; i++)
            ChatMessage(
              messageId: 'mc$i',
              sessionId: 'real-session-1',
              role: i.isOdd ? 'user' : 'assistant',
              content: '第${(i + 1) ~/ 2}轮',
              createdAt: DateTime(2026),
            ),
        ];
      final compactionService = _GatedCompactionService();
      final persistenceService = _DeleteRecordingPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: _SseHttpClient(const []),
        chatRepo: chatRepo,
        experienceRepo: _StubExperienceRepository(),
        persistenceService: persistenceService,
        compactionService: compactionService,
        forceReviewEnabled: false,
      );
      await Future<void>.delayed(Duration.zero);

      final compactFuture = controller.manualCompact();
      // 门闸未开：压缩挂起中（isManualCompacting=true、phase 仍 idle）
      expect(controller.state.isManualCompacting, isTrue);
      expect(controller.state.phase, IntermediatePhase.idle);
      final messagesBefore = List.of(controller.state.messages);

      final lastAssistant =
          controller.state.messages.lastWhere((m) => m.role == 'assistant');
      final lastUser =
          controller.state.messages.lastWhere((m) => m.role == 'user');
      await controller.deleteRound(lastAssistant);
      await controller.regenerateMessage(lastAssistant);
      await controller.editAndResend(lastUser, '压缩中改写');
      await controller.editMessageContent(lastAssistant, '压缩中改写');

      // 四操作零副作用：不删库、消息列表原样
      expect(persistenceService.deleteRoundCalls, isEmpty);
      expect(controller.state.messages, messagesBefore);

      compactionService.release.complete();
      expect(await compactFuture, ManualCompactResult.success);
      expect(controller.state.isManualCompacting, isFalse);
    });
  });

  // ── ST-1：压缩摘要卡「已归档第 X–Y 轮」范围 ────────────
  //
  // 修复前：copyWith 三个参数表达式都读旧 compactedTurnBase——
  // 首次压缩（B=0, T=4）渲染「已归档第 -3–0 轮」；后续压缩滞回上一轮范围。
  group('压缩摘要卡归档范围', () {
    List<ChatMessage> seededHistory() => [
          for (var i = 1; i <= 10; i++)
            ChatMessage(
              messageId: 'm$i',
              sessionId: 'real-session-1',
              role: i.isOdd ? 'user' : 'assistant',
              content: '第${(i + 1) ~/ 2}轮${i.isOdd ? '用户' : '回复'}',
              createdAt: DateTime(2026),
            ),
        ];

    test('首次压缩（B=0, T=4）：已归档第 1–4 轮，正序非负', () async {
      final httpClient = _SseHttpClient(_v2SuccessResponses());
      final chatRepo = _IntegrationChatRepository()..messages = seededHistory();
      final persistenceService = _StubPersistenceService();
      final compactionService = _FakeCompactionService()..keepTail = 2;
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: _StubExperienceRepository(),
        persistenceService: persistenceService,
        compactionService: compactionService,
        forceReviewEnabled: false,
      );

      await controller.sendMessage('第六轮输入');

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(controller.state.compactedTurnBase, 4);
      // 修复前：(from: -3, to: 0)——旧基数 0 直接参与范围计算
      expect(
        controller.state.archivedTurnRange,
        (from: 1, to: 4),
        reason: '首次压缩覆盖第 1–4 轮，范围必须正序非负',
      );
    });

    test('二次压缩（B=4, T=1）：已归档第 5–5 轮，不滞回上一轮范围', () async {
      final httpClient = _SseHttpClient(
        _v2SuccessResponses()..addAll(_v2SuccessResponses()),
      );
      final chatRepo = _IntegrationChatRepository()..messages = seededHistory();
      final persistenceService = _StubPersistenceService();
      final compactionService = _FakeCompactionService()..keepTail = 2;
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: _StubExperienceRepository(),
        persistenceService: persistenceService,
        compactionService: compactionService,
        forceReviewEnabled: false,
      );

      // 第 6 轮：首次压缩（B 0→4）
      await controller.sendMessage('第六轮输入');
      expect(controller.state.phase, IntermediatePhase.idle);
      expect(controller.state.archivedTurnRange, (from: 1, to: 4));

      // 模拟第 6 轮 persist 后的 DB 全量视图 + 压缩点（boundary=m8）：
      // 全量 12 条 = 原 10 条 + 第 6 轮 user/assistant（state.messages 尾两条）
      final round6Pair = controller.state.messages.sublist(3);
      chatRepo
        ..messages = [...seededHistory(), ...round6Pair]
        ..compactionPoints = [
          {'boundaryMessageId': 'm8', 'summaryMessageId': 'summary-card-1'},
        ];

      // 第 7 轮：二次压缩（可见历史 = 摘要 + m9/m10 + 第 6 轮 → 新覆盖 1 轮）
      await controller.sendMessage('第七轮输入');

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(controller.state.compactedTurnBase, 5);
      // 修复前：(from: 4, to: 4)——读旧基数 4，显示的是上一轮压缩的范围
      expect(
        controller.state.archivedTurnRange,
        (from: 5, to: 5),
        reason: '二次压缩覆盖第 5 轮，范围必须用更新后的基数（B+T）计算',
      );
    });
  });

  // ── ST-2：草稿 E010 拦截后的失败栏善后 ──────────────────
  //
  // 修复前：draft 预检 _fail 发生在 userInput/pendingUserMessage 写入 state
  // 之前且 _round=null → 失败栏「整轮重试」「从中断处继续」双静默 no-op。
  group('草稿 E010 拦截后的失败栏善后', () {
    test('未配模型草稿首跑：E010 failed 且输入保留（重试有输入可重放）', () async {
      final chatRepo = _IntegrationChatRepository();
      final persistenceService = _StubPersistenceService();
      final controller = _buildController(
        session: _draftSession(),
        httpClient: _SseHttpClient(const []),
        chatRepo: chatRepo,
        experienceRepo: _StubExperienceRepository(),
        persistenceService: persistenceService,
        configurationResolver: _GatedNamingConfigResolver(),
      );

      await controller.sendMessage('勇者初出茅庐');

      //  拦截本身保持：不物化草稿（不制造空会话）
      expect(controller.state.phase, IntermediatePhase.failed);
      expect(controller.state.failureContext!.errorCode, 'E010');
      expect(
        controller.state.failureContext!.failedPhase,
        IntermediatePhase.extracting,
      );
      expect(chatRepo.createSessionCalls, isEmpty);
      expect(persistenceService.persistRoundCalls, 0);
      // ST-2：修复前 userInput/pendingUserMessage 均为 null（重试按钮死键）
      expect(controller.state.userInput, '勇者初出茅庐');
      expect(controller.state.pendingUserMessage, isNotNull);
      expect(controller.state.pendingUserMessage!.content, '勇者初出茅庐');
    });

    test('补齐配置后 retry()：物化草稿并完成整轮（不再静默 no-op）', () async {
      final httpClient = _SseHttpClient(_v2SuccessResponses());
      final chatRepo = _IntegrationChatRepository();
      final persistenceService = _StubPersistenceService();
      final resolver = _GatedNamingConfigResolver();
      final controller = _buildController(
        session: _draftSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: _StubExperienceRepository(),
        persistenceService: persistenceService,
        configurationResolver: resolver,
      );

      // 首跑：未配模型 → E010 failed（草稿未物化）
      await controller.sendMessage('勇者初出茅庐');
      expect(controller.state.phase, IntermediatePhase.failed);
      expect(chatRepo.createSessionCalls, isEmpty);

      // 用户补齐配置（模拟全局/会话配置修复）
      resolver.configured = true;

      await controller.retry();

      // 修复前：retry() 因 userInput 为 null 静默 return，phase 仍 failed
      expect(controller.state.phase, IntermediatePhase.idle);
      expect(chatRepo.createSessionCalls, hasLength(1), reason: '重试时物化草稿');
      expect(controller.isDraftSession, isFalse);
      expect(persistenceService.persistRoundCalls, 1);
      expect(controller.state.messages.length, 2);
      expect(controller.state.pendingUserMessage, isNull);
    });

    test('补齐配置后 continueFromFailed()：轮前失败无产出 → 等价整轮重试', () async {
      final httpClient = _SseHttpClient(_v2SuccessResponses());
      final chatRepo = _IntegrationChatRepository();
      final persistenceService = _StubPersistenceService();
      final resolver = _GatedNamingConfigResolver();
      final controller = _buildController(
        session: _draftSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: _StubExperienceRepository(),
        persistenceService: persistenceService,
        configurationResolver: resolver,
      );

      await controller.sendMessage('勇者初出茅庐');
      expect(controller.state.phase, IntermediatePhase.failed);
      resolver.configured = true;

      // 修复前：_round=null → 静默 return（「从中断处继续」死键）
      await controller.continueFromFailed();

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(persistenceService.persistRoundCalls, 1);
      expect(controller.state.messages.length, 2);
    });

    test('failed 态 userInput 被清时 retry() 从用户气泡恢复输入', () async {
      final httpClient = _SseHttpClient(_v2SuccessResponses());
      final chatRepo = _IntegrationChatRepository();
      final persistenceService = _StubPersistenceService();
      final resolver = _GatedNamingConfigResolver();
      final controller = _buildController(
        session: _draftSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: _StubExperienceRepository(),
        persistenceService: persistenceService,
        configurationResolver: resolver,
      );

      // 首跑：未配模型 → E010 failed（落 userInput + pendingUserMessage）
      await controller.sendMessage('勇者初出茅庐');
      expect(controller.state.phase, IntermediatePhase.failed);

      // 模拟页面层把 userInput 回写输入框后清空 state.userInput 的现场
      //（修复前 retry() 在此静默 return，按钮无响应）
      controller.clearUserInput();
      expect(controller.state.userInput, isNull);
      expect(controller.state.pendingUserMessage, isNotNull);

      resolver.configured = true;
      await controller.retry();

      // 从 pendingUserMessage 恢复输入并完成整轮（不再静默 no-op）
      expect(controller.state.phase, IntermediatePhase.idle);
      expect(chatRepo.createSessionCalls, hasLength(1), reason: '重试时物化草稿');
      expect(persistenceService.persistRoundCalls, 1);
      expect(controller.state.messages.length, 2);
      expect(controller.state.messages.first.content, '勇者初出茅庐');
    });

    test('仍未配模型时 retry()：维持 failed + E010，不物化不空转', () async {
      final chatRepo = _IntegrationChatRepository();
      final persistenceService = _StubPersistenceService();
      final controller = _buildController(
        session: _draftSession(),
        httpClient: _SseHttpClient(const []),
        chatRepo: chatRepo,
        experienceRepo: _StubExperienceRepository(),
        persistenceService: persistenceService,
        configurationResolver: _GatedNamingConfigResolver(),
      );

      await controller.sendMessage('勇者初出茅庐');
      expect(controller.state.phase, IntermediatePhase.failed);

      // 用户没修配置直接点重试 → 与首发同口径再次 E010（可感知，非静默）
      await controller.retry();

      expect(controller.state.phase, IntermediatePhase.failed);
      expect(controller.state.failureContext!.errorCode, 'E010');
      expect(chatRepo.createSessionCalls, isEmpty);
      expect(persistenceService.persistRoundCalls, 0);
      // 输入仍保留（用户修完配置可再试）
      expect(controller.state.userInput, '勇者初出茅庐');
    });
  });

  // ── ：retry 输入兜底第二序的重生成守卫 ────────────
  //
  //  第二序扫「列表尾部 user 消息」——普通发送场景那是
  // 上一轮的输入，双空（userInput/pendingUserMessage 皆空）时回捞重发
  // 会产生重复轮次。守卫：仅 regenerateTurnNumber != null（重生成场景
  // 列表尾确实是本轮 user 消息）才启用第二序。
  group('retry 输入兜底第二序的重生成守卫', () {
    // 构造「轮中失败 + 输入双空」现场：extracting 首调即抛（extractingMaxRetries=0
    // 保证一次失败即 failed，无自动重试定时器干扰）。
    Future<IntermediateChatController> buildFailedRoundWithHistory(
      _IntegrationChatRepository chatRepo,
      _StubPersistenceService persistenceService,
    ) async {
      chatRepo.messages = [
        for (var i = 1; i <= 6; i++)
          ChatMessage(
            messageId: 'h$i',
            sessionId: 'real-session-1',
            role: i.isOdd ? 'user' : 'assistant',
            content: '第${(i + 1) ~/ 2}轮',
            createdAt: DateTime(2026),
          ),
      ];
      final controller = _buildController(
        session: _realSession(),
        httpClient: _ErrorHttpClient(Exception('extract down')),
        chatRepo: chatRepo,
        experienceRepo: _StubExperienceRepository(),
        persistenceService: persistenceService,
        config: const IntermediateConfig(
          retry: RetryConfig(extractingMaxRetries: 0),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      await controller.sendMessage('本轮输入');
      expect(controller.state.phase, IntermediatePhase.failed);

      // EXP-02 兜底的可达现场：异常路径先清气泡再清输入（双空）。
      controller
        ..clearUserInput()
        ..state = controller.state.copyWith(pendingUserMessage: null);
      expect(controller.state.userInput, isNull);
      expect(controller.state.pendingUserMessage, isNull);
      return controller;
    }

    test('普通发送场景（regenerateTurnNumber=null）双空 → retry 复位 idle，不回捞上一轮输入',
        () async {
      final chatRepo = _IntegrationChatRepository();
      final persistenceService = _StubPersistenceService();
      final controller = await buildFailedRoundWithHistory(
        chatRepo,
        persistenceService,
      );
      expect(controller.state.regenerateTurnNumber, isNull);

      await controller.retry();

      // 修复前：第二序回捞列表尾 user 消息「第3轮」当本轮内容重发
      //（整轮重跑、再次失败回 failed）。修复后：无可恢复输入 → 复位 idle。
      expect(
        controller.state.phase,
        IntermediatePhase.idle,
        reason: '双空 + 非重生成 → 复位 idle，不把上一轮输入当本轮重发',
      );
      expect(persistenceService.persistRoundCalls, 0);
      expect(controller.state.messages.length, 6, reason: '消息列表不变');
    });

    test('重生成场景（regenerateTurnNumber!=null）双空 → retry 仍从列表尾 user 消息恢复',
        () async {
      final chatRepo = _IntegrationChatRepository();
      final persistenceService = _StubPersistenceService();
      final controller = await buildFailedRoundWithHistory(
        chatRepo,
        persistenceService,
      );
      // 模拟重生成失败现场：列表尾 user 消息即本轮目标
      controller.state = controller.state.copyWith(
        regenerateTurnNumber: 3,
      );

      await controller.retry();

      // 重生成场景列表尾确实是本轮 user 消息——第二序守卫不应误伤此路：
      // 输入从「第3轮」恢复并重跑整轮（HTTP 再次抛错 → failed 可达）。
      expect(controller.state.userInput, '第3轮', reason: '重生成场景第二序恢复保持可用');
      expect(controller.state.phase, IntermediatePhase.failed);
    });
  });

  group('persisting 后台复位竞态', () {
    test(
        'a. persisting 期间 onBackgroundInterrupt 不置标志 + recoverIfStuck 放行 → persist 完成正常收稿',
        () async {
      final httpClient = _SseHttpClient(_v2SuccessResponses());
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository();
      final persistenceService = _GatedPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
      );

      final future = controller.sendMessage('勇者前往后山');
      await _until(
        () => controller.state.phase == IntermediatePhase.persisting,
      );

      // 后台中断 + 恢复：persisting 豁免——不复位、不吞 persist
      controller.onBackgroundInterrupt();
      final recovered = controller.recoverIfStuck();
      expect(recovered, isFalse, reason: 'persisting 豁免：无恢复动作');
      expect(controller.state.phase, IntermediatePhase.persisting);

      persistenceService.gate.complete();
      await future;

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(controller.state.messages.length, 2);
      expect(
        controller.state.artifactsByTurnNumber!.keys,
        contains(1),
        reason: 'persist 正常收稿：本轮 artifacts 写入 state',
      );
    });

    test('b. persist 提交后 _round 被外力清空 → 重载历史恢复 artifacts（完成态不再静默丢失）', () async {
      final httpClient = _SseHttpClient(_v2SuccessResponses());
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _StubExperienceRepository();
      final persistenceService = _GatedPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
      );

      final future = controller.sendMessage('勇者前往后山');
      await _until(
        () => controller.state.phase == IntermediatePhase.persisting,
      );

      // 模拟旧竞态窗口的外力复位（后台复位/清空把 _round 清掉，
      // 而 persist 事务随后提交）：DB 完整、内存落后。
      controller.clearRound();
      expect(controller.state.phase, IntermediatePhase.idle);

      persistenceService.gate.complete();
      await future;

      // (c)：身份检查失败但事务已提交 → 重载历史 → artifacts 回到
      // state（轮面板「第 N 轮 · 摘要已生成」等完成态恢复渲染的数据源）。
      await _until(
        () => (controller.state.artifactsByTurnNumber ?? const {}).isNotEmpty,
      );
      expect(controller.state.artifactsByTurnNumber!.keys, contains(1));
      expect(controller.state.phase, IntermediatePhase.idle);
    });
  });

  // ── ST13U-1：仅保存的返回值契约 ──────────────────────────
  //
  // 页面凭返回值弹「已保存/保存失败」floating SnackBar；旧签名
  // Future<void> 让成功/失败在 UI 上完全无差别（B线亲证）。
  group('editMessageContent 返回值', () {
    test('保存成功返回 true 且内存消息更新', () async {
      final chatRepo = _IntegrationChatRepository()
        ..messages = [
          ChatMessage(
            messageId: 'u1',
            sessionId: 'real-session-1',
            role: 'user',
            content: '旧内容',
            createdAt: DateTime(2026),
          ),
        ];
      final controller = _buildController(
        session: _realSession(),
        httpClient: _SseHttpClient(const []),
        chatRepo: chatRepo,
        experienceRepo: _StubExperienceRepository(),
        persistenceService: _DeleteRecordingPersistenceService(),
        forceReviewEnabled: false,
      );
      await Future<void>.delayed(Duration.zero);

      final saved = await controller.editMessageContent(
        chatRepo.messages.first,
        '修正后的内容',
      );

      expect(saved, isTrue);
      expect(
        controller.state.messages.first.content,
        '修正后的内容',
      );
    });

    test('仓储抛错返回 false 且消息原样', () async {
      final chatRepo = _IntegrationChatRepository()
        ..updateMessageContentError = Exception('disk full')
        ..messages = [
          ChatMessage(
            messageId: 'u1',
            sessionId: 'real-session-1',
            role: 'user',
            content: '旧内容',
            createdAt: DateTime(2026),
          ),
        ];
      final controller = _buildController(
        session: _realSession(),
        httpClient: _SseHttpClient(const []),
        chatRepo: chatRepo,
        experienceRepo: _StubExperienceRepository(),
        persistenceService: _DeleteRecordingPersistenceService(),
        forceReviewEnabled: false,
      );
      await Future<void>.delayed(Duration.zero);

      final saved = await controller.editMessageContent(
        chatRepo.messages.first,
        '不会落库的内容',
      );

      expect(saved, isFalse);
      expect(controller.state.messages.first.content, '旧内容');
    });

    test('压缩互斥守卫（ST6-1）返回 false', () async {
      final chatRepo = _IntegrationChatRepository()
        ..messages = [
          for (var i = 1; i <= 10; i++)
            ChatMessage(
              messageId: 'mc$i',
              sessionId: 'real-session-1',
              role: i.isOdd ? 'user' : 'assistant',
              content: '第${(i + 1) ~/ 2}轮',
              createdAt: DateTime(2026),
            ),
        ];
      final gatedCompaction = _GatedCompactionService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: _SseHttpClient(const []),
        chatRepo: chatRepo,
        experienceRepo: _StubExperienceRepository(),
        persistenceService: _DeleteRecordingPersistenceService(),
        compactionService: gatedCompaction,
        forceReviewEnabled: false,
      );
      await Future<void>.delayed(Duration.zero);

      final compactFuture = controller.manualCompact();
      expect(controller.state.isManualCompacting, isTrue);

      final lastAssistant =
          controller.state.messages.lastWhere((m) => m.role == 'assistant');
      final saved = await controller.editMessageContent(lastAssistant, '压缩中改写');

      expect(saved, isFalse);
      expect(lastAssistant.content, '第5轮');

      // 收尾：放行挂起的压缩，避免悬挂 future。
      gatedCompaction.release.complete();
      await compactFuture;
    });
  });

  // ── ：非破坏性重生成变体端到端 ─────────────────────
  //
  // 与导演  同语义：重生成旧版快照为变体 0、新版记变体 1 并移指针；
  // 切回旧版后 state.messages 物化为旧版；删非当前变体后内存表收缩。
  group('故事重生成变体保留+切换', () {
    test('重生成旧版快照为变体→收稿指针移新版→切回旧版→删非当前变体', () async {
      final httpClient = _SseHttpClient([
        ..._v2SuccessResponses(generated: '第一版草稿', reply: '第一版正文'),
        ..._v2SuccessResponses(generated: '重生成草稿', reply: '第二版正文'),
      ]);
      final chatRepo = _IntegrationChatRepository();
      final experienceRepo = _RollbackSafeExperienceRepository();
      final persistenceService = _VariantAwarePersistenceService();
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: chatRepo,
        experienceRepo: experienceRepo,
        persistenceService: persistenceService,
      );

      await controller.sendMessage('勇者前往后山');
      expect(controller.state.phase, IntermediatePhase.idle);
      expect(controller.state.messages.last.content, '第一版正文');

      // ① 重生成：旧版快照为变体 0，新版记变体 1 并移指针
      await controller.regenerateMessage(controller.state.messages.last);
      expect(controller.state.phase, IntermediatePhase.idle);
      expect(controller.state.messages.last.content, '第二版正文');
      expect(controller.state.variantFlashTurn, 1, reason: '新变体收稿高亮信号');
      expect(
        controller.state.variantsByTurn?[1],
        hasLength(2),
        reason: '收稿后内存变体表立即可用（不依赖重开会话）',
      );
      expect(controller.state.variantsByTurn?[1]?[0].content, '第一版正文');
      expect(controller.state.variantsByTurn?[1]?[1].content, '第二版正文');
      expect(
        controller.state.artifactsByTurnNumber?[1]?.currentVariantIndex,
        1,
        reason: '内存变体指针随收稿回写为新版',
      );

      // ② 切回变体 0：state.messages 物化为第一版，指针回 0，信号消费
      await controller.switchMessageVariant(controller.state.messages.last, 0);
      expect(controller.state.messages.last.content, '第一版正文');
      expect(
        controller.state.variantsByTurn?[1]?[0].variantIndex,
        0,
      );
      expect(controller.state.variantFlashTurn, isNull);

      // ③ 删非当前变体（1）：内存表收缩到单版
      await controller.deleteMessageVariant(controller.state.messages.last, 1);
      expect(controller.state.variantsByTurn?[1], hasLength(1));
      expect(controller.state.variantsByTurn?[1]?[0].content, '第一版正文');

      // ④ 高亮信号清除幂等
      controller.clearVariantFlash();
      expect(controller.state.variantFlashTurn, isNull);
    });

    test('编辑重发同样快照旧版（变体落表，指针不动）', () async {
      final httpClient = _SseHttpClient([
        ..._v2SuccessResponses(generated: '旧草稿', reply: '旧版正文'),
        ..._v2SuccessResponses(generated: '新草稿', reply: '新版正文'),
      ]);
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: _IntegrationChatRepository(),
        experienceRepo: _RollbackSafeExperienceRepository(),
        persistenceService: _VariantAwarePersistenceService(),
      );

      await controller.sendMessage('开场');
      expect(controller.state.messages.last.content, '旧版正文');

      // 编辑重发首条 user：旧 assistant 快照为变体（保留可追溯），新版
      // 走 persistRound 分支不记指针——与导演同口径
      await controller.editAndResend(controller.state.messages.first, '新指令');
      expect(controller.state.phase, IntermediatePhase.idle);
      expect(controller.state.messages.last.content, '新版正文');
      expect(
        controller.state.variantsByTurn?[1],
        hasLength(1),
        reason: '旧版快照保留在变体表（新版未记变体，与导演一致）',
      );
      expect(controller.state.variantsByTurn?[1]?[0].content, '旧版正文');
      expect(
        controller.state.variantFlashTurn,
        isNull,
        reason: '编辑重发不触发新变体高亮',
      );
    });
  });

  // ── ：中断正文保留与续写 ──────────────────────────
  //
  // 生成流中断时半截正文不再随失败蒸发：_fail 快照进 partialReplySnapshot
  // （failed 态半截稿件卡数据源）；续写清流式缓冲防追加拼接 + 注入续写
  // 指令块；以此收稿=replyText=快照直奔 summarizing→persist。
  group('中断正文保留与续写', () {
    Future<IntermediateChatController> pumpFailedMidStream(
      _SseHttpClient httpClient,
    ) async {
      final controller = _buildController(
        session: _realSession(),
        httpClient: httpClient,
        chatRepo: _IntegrationChatRepository(),
        experienceRepo: _StubExperienceRepository(),
        persistenceService: _VariantAwarePersistenceService(),
        config: const IntermediateConfig(
          retry: RetryConfig(streamInterruptRetry: 0),
        ),
        forceReviewEnabled: false,
      );
      await controller.sendMessage('推进剧情');
      return controller;
    }

    test('生成流中断 → failed 且半截正文进快照（review-off 缓冲）', () async {
      final controller = await pumpFailedMidStream(
        _SseHttpClient([
          _extractKeywordsSse(),
          _partialThenErrorSse('夜色沉下来，刀锋抵住'),
        ]),
      );

      expect(controller.state.phase, IntermediatePhase.failed);
      expect(controller.state.failureContext!.errorCode, 'E016');
      expect(
        controller.state.failureContext!.failedPhase,
        IntermediatePhase.generating,
      );
      expect(
        controller.state.partialReplySnapshot,
        '夜色沉下来，刀锋抵住',
        reason: '半截正文快照进 state（failed 态稿件卡数据源）',
      );
    });

    test('续写：清流式缓冲防拼接 + 注入续写指令块 + 收稿后快照清空', () async {
      final httpClient = _SseHttpClient([
        _extractKeywordsSse(),
        _partialThenErrorSse('夜色沉下来，刀锋抵住'),
        _draftV2('门外的脚步声近了。'),
        _summarizeSse(),
      ]);
      final controller = await pumpFailedMidStream(httpClient);
      expect(controller.state.partialReplySnapshot, '夜色沉下来，刀锋抵住');

      await controller.continueFromFailed();

      expect(controller.state.phase, IntermediatePhase.idle);
      // 续写注入：重跑的生成请求携带续写指令块 + 半截正文前缀
      final generateBody = httpClient.bodies[2]!;
      expect(generateBody, contains('【续写说明】'));
      expect(generateBody, contains('夜色沉下来，刀锋抵住'));
      expect(generateBody, contains('已写正文'));
      // 清场生效：最终正文只有新内容，无旧半截前缀拼接
      expect(controller.state.messages.last.content, '门外的脚步声近了。');
      expect(
        controller.state.partialReplySnapshot,
        isNull,
        reason: '收稿成功后快照清空（正文已入 messages）',
      );
    });

    test('以此收稿：快照为正文直奔摘要+固化，正文与消息一致', () async {
      final controller = await pumpFailedMidStream(
        _SseHttpClient([
          _extractKeywordsSse(),
          _partialThenErrorSse('夜色沉下来，刀锋抵住'),
          _summarizeSse(),
        ]),
      );
      expect(controller.state.phase, IntermediatePhase.failed);

      await controller.acceptPartialReplyAsFinal();

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(
        controller.state.messages.last.content,
        '夜色沉下来，刀锋抵住',
        reason: '半截正文作为最终回复落库',
      );
      expect(controller.state.partialReplySnapshot, isNull);
    });

    test('整轮重试清空快照（防跨轮陈旧残留）', () async {
      final controller = await pumpFailedMidStream(
        _SseHttpClient([
          _extractKeywordsSse(),
          _partialThenErrorSse('夜色沉下来，刀锋抵住'),
          _extractKeywordsSse(),
          _draftV2('重写后的正文。'),
          _summarizeSse(),
        ]),
      );
      expect(controller.state.partialReplySnapshot, isNotNull);

      await controller.retry();

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(controller.state.messages.last.content, '重写后的正文。');
      expect(
        controller.state.partialReplySnapshot,
        isNull,
        reason: 'clearTemporary 随轮清理快照',
      );
    });
  });
}
