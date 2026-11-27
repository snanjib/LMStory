import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart'
    show ApplyInterceptor, QueryExecutor, QueryInterceptor, Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';
import 'package:lmstory/core/network/http_client.dart';
import 'package:lmstory/core/network/llm_adapters/llm_adapter_factory.dart';
import 'package:lmstory/core/services/data_store_operation_guard.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/advanced/data/engineering_compaction_service.dart';
import 'package:lmstory/features/advanced/data/repositories/agent_event_log_repository.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_live_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/domain/entities/tool_permissions.dart';
import 'package:lmstory/features/advanced/domain/services/agent_log_recovery.dart';
import 'package:lmstory/features/advanced/domain/services/agent_session_stats.dart';
import 'package:lmstory/features/advanced/domain/services/compaction_planning.dart';
import 'package:lmstory/features/advanced/domain/services/director_surface_v2.dart';
import 'package:lmstory/features/advanced/domain/services/engineering_context_mode.dart';
import 'package:lmstory/features/advanced/presentation/controllers/advanced_chat_controller.dart';
import 'package:lmstory/features/advanced/presentation/pages/advanced_chat_page.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/datasources/llm_remote_datasource.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session_settings.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/diagnostics/domain/entities/failure_log_entry.dart';
import 'package:lmstory/features/diagnostics/domain/repositories/failure_log_repository.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';
import 'package:lmstory/features/memory/data/repositories/factual_repository_impl.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/factual_source.dart';
import 'package:lmstory/features/memory/domain/services/embedding_service.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';
import 'package:lmstory/features/resource_library/domain/services/resource_apply_service.dart';
import 'package:lmstory/features/settings/data/repositories/backup_repository_impl.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/domain/services/data_management_service.dart';
import 'package:lmstory/features/story_runtime/data/persistence_service_impl.dart';
import 'package:lmstory/features/story_runtime/domain/entities/context_usage_estimate.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/features/story_runtime/domain/services/compaction_service.dart';
import 'package:lmstory/features/story_runtime/domain/services/manual_compact_result.dart';
import 'package:lmstory/features/story_runtime/domain/services/memory_consolidator.dart';
import 'package:lmstory/features/story_runtime/domain/services/persistence_service.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/context_usage_ring.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../../../test_helpers/fact_write_failure_fixture.dart';
import '../../../../test_helpers/paused_backup_restore.dart';
import '../../../../test_helpers/paused_session_update.dart';
import '../../../../test_helpers/stub_failure_log_repository.dart';
import '../../../../test_helpers/stub_token_counter.dart';

/// 导演模式 kernel swap 集成测试（v0.3）
///
/// 验证：mode==advanced 时，AdvancedChatController 走 agent loop
/// （而非六步管线），agent 的检索/写事实/正文经 RoundContext → _runPersistPhase
/// 落库，复用故事模式持久化。使用真实 SSE 解析链 + 内存 drift + 真实 FactApplier。
class _FakeResolver extends ConfigurationResolver {
  _FakeResolver({
    this.baseUrl = 'https://api.openai.com/v1',
    this.apiKey = 'test-key',
  }) : super(
          presetRepository: _StubPresetRepo(),
          settingsRepository: _ThrowingSettingsRepo(),
          logger: const Logger('test'),
        );

  final String baseUrl;
  final String apiKey;

  @override
  Future<({ChatSessionSettings settings, String? apiKey})>
      resolveAdvancedSettings(ChatSession session) async {
    return (
      settings: ChatSessionSettings(
        modelId: 'test-model',
        presetId: 'test-preset',
        systemPrompt: session.systemPromptOverride ?? '世界观：剑与魔法。',
        temperature: 0.8,
        topP: 0.9,
        maxTokens: 4096,
        autoCompaction: true,
        compactionThreshold: 0.6,
        streamEnabled: true,
        reasoningEffort: ReasoningEffort.disabled,
        compactionTriggerRatioOverride: session.compactionTriggerRatioOverride,
      ),
      apiKey: null,
    );
  }

  @override
  Future<NamingConfig?> resolveAdvancedGeneratingNamingConfig(
    ChatSession session,
  ) async {
    return NamingConfig(
      baseUrl: baseUrl,
      apiKey: apiKey,
      modelId: 'test-model',
      presetId: 'test-preset',
    );
  }

  @override
  Future<int> resolveContextWindowForPhase({
    String? presetId,
    String? modelId,
    int? effectiveContextLimit,
  }) async =>
      32000;

  @override
  Future<EmbeddingApiConfig?> resolveAdvancedEmbeddingConfig() async => null;
}

/// embedding 配置可用且 fallback_on_failure=false 的解析器
/// 变体——host._resolveQueryVector 在 embed 失败时抛
/// EmbeddingCallFailedException（E104 链路入口）。
class _EmbeddingFailResolver extends _FakeResolver {
  @override
  Future<EmbeddingApiConfig?> resolveAdvancedEmbeddingConfig() async =>
      const EmbeddingApiConfig(
        model: 'embed-model',
        baseUrl: 'https://api.openai.com/v1',
        apiKey: 'test-key',
        timeoutMs: 5000,
        fallbackOnFailure: false,
      );
}

/// GM（导演主模型）未配置的解析器变体——
/// resolveAdvancedGeneratingNamingConfig 返回 null，触发 E010 守卫。
class _GmMissingResolver extends _FakeResolver {
  @override
  Future<NamingConfig?> resolveAdvancedGeneratingNamingConfig(
    ChatSession session,
  ) async =>
      null;
}

/// GM 配置可运行时切换的解析器变体——模拟用户失败后去设置补齐配置。
class _ToggleGmResolver extends _FakeResolver {
  bool gmConfigured = false;
  @override
  Future<NamingConfig?> resolveAdvancedGeneratingNamingConfig(
    ChatSession session,
  ) async =>
      gmConfigured
          ? const NamingConfig(
              baseUrl: 'https://api.openai.com/v1',
              apiKey: 'test-key',
              modelId: 'test-model',
              presetId: 'test-preset',
            )
          : null;
}

class _PausedDirectorResolver extends _ToggleGmResolver {
  final entered = Completer<void>();
  final resume = Completer<void>();
  bool pauseModel = false;
  bool pauseSettings = false;
  int visits = 0;

  Future<void> _pause() {
    visits++;
    if (!entered.isCompleted) entered.complete();
    return resume.future;
  }

  @override
  Future<NamingConfig?> resolveAdvancedGeneratingNamingConfig(
    ChatSession session,
  ) async {
    if (pauseModel) await _pause();
    return super.resolveAdvancedGeneratingNamingConfig(session);
  }

  @override
  Future<({ChatSessionSettings settings, String? apiKey})>
      resolveAdvancedSettings(ChatSession session) async {
    if (pauseSettings) await _pause();
    return super.resolveAdvancedSettings(session);
  }
}

class _LegacyDirectorResolver extends _FakeResolver {
  @override
  Future<GlobalDefaultsSnapshot> snapshotAdvancedDefaults() async =>
      const GlobalDefaultsSnapshot(temperature: 0.8);
}

class _PausedResumeEventLog extends AgentEventLogRepository {
  _PausedResumeEventLog({required super.database});

  final entered = Completer<void>();
  final resume = Completer<void>();
  bool pause = false;
  int repairWrites = 0;
  Completer<void>? trimEntered;
  Completer<void>? trimResume;

  @override
  Future<List<int>> appendAll(
    String sessionId,
    List<AgentDurableEvent> events,
  ) async {
    if (pause &&
        events.any(
          (event) =>
              event.type == AgentEventTypes.assistantMessage &&
              event.data['interrupted'] == true,
        )) {
      repairWrites++;
      if (!entered.isCompleted) entered.complete();
      await resume.future;
    }
    return super.appendAll(sessionId, events);
  }

  @override
  Future<int> trimToRecentTurns(String sessionId, int keepTurns) async {
    final entered = trimEntered;
    if (entered != null && !entered.isCompleted) {
      entered.complete();
      await trimResume?.future;
    }
    return super.trimToRecentTurns(sessionId, keepTurns);
  }
}

class _PausedEngineeringEnter extends AgentEventLogRepository {
  _PausedEngineeringEnter({required super.database});

  final entered = Completer<void>();
  final resume = Completer<void>();

  @override
  Future<void> applyEngineeringContextEnterAtomic({
    required String sessionId,
    required String epochId,
    required Future<EngineeringEnterCapture> Function() prepare,
  }) {
    return super.applyEngineeringContextEnterAtomic(
      sessionId: sessionId,
      epochId: epochId,
      prepare: () async {
        entered.complete();
        await resume.future;
        return prepare();
      },
    );
  }
}

class _PausedDirectorMutation extends StoryPersistenceServiceImpl {
  _PausedDirectorMutation(AppDatabase db, this.operation)
      : super(
          database: db,
          chatRepository: ChatRepositoryImpl(database: db),
          experienceRepository: ExperienceRepositoryImpl(
            database: db,
            vectorEngine: const VectorEngine(),
          ),
        );

  final String operation;
  final entered = Completer<void>();
  final resume = Completer<void>();
  bool pause = false;
  int calls = 0;

  Future<void> _before(String operation) async {
    if (!pause || this.operation != operation) return;
    calls++;
    if (!entered.isCompleted) entered.complete();
    await resume.future;
  }

  @override
  Future<RoundRollbackResult> rollbackRoundAndDownstream({
    required String sessionId,
    required int fromTurnNumber,
    required List<String> messageIdsToDelete,
    bool keepVariantsAtFromTurn = false,
    RoundVariantSnapshot? variantSnapshot,
    Future<bool> Function(String sessionId, int fromTurnNumber)? truncateEvents,
  }) async {
    await _before('delete');
    return super.rollbackRoundAndDownstream(
      sessionId: sessionId,
      fromTurnNumber: fromTurnNumber,
      messageIdsToDelete: messageIdsToDelete,
      keepVariantsAtFromTurn: keepVariantsAtFromTurn,
      variantSnapshot: variantSnapshot,
      truncateEvents: truncateEvents,
    );
  }

  @override
  Future<bool> switchMessageVariant({
    required String sessionId,
    required int turnNumber,
    required int variantIndex,
    required String assistantMessageId,
    FactualConfig? factualConfig,
  }) async {
    await _before('switch');
    return super.switchMessageVariant(
      sessionId: sessionId,
      turnNumber: turnNumber,
      variantIndex: variantIndex,
      assistantMessageId: assistantMessageId,
      factualConfig: factualConfig,
    );
  }

  @override
  Future<bool> undoCompaction({required String sessionId}) async {
    await _before('undo');
    return super.undoCompaction(sessionId: sessionId);
  }
}

/// 先吐一条 delta 再挂门闸——delta 进入 32ms 合帧缓冲后压缩
/// 挂起，模拟 dispose 恰落在缓冲窗口内。
class _GatedDeltaCompactionService extends StoryCompactionService {
  _GatedDeltaCompactionService()
      : super(
          tokenCounter: TokenCounter(),
          llmService: _NoopLlmService(),
        );

  final Completer<void> release = Completer<void>();
  int compactCalls = 0;

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
    Duration? responseStartTimeout,
    String? existingCompactionSummary,
    int baseContextTokens = 0,
    bool manual = false,
    void Function(String delta)? onSummaryDelta,
    CancellationToken? cancelToken,
  }) async {
    compactCalls++;
    onSummaryDelta?.call('挂起中的压缩尾段。');
    await release.future;
    return CompactionResult(
      summary: '前情摘要（累积）',
      boundaryMessageId: history[history.length - 3].messageId,
      compactedHistory: const [],
    );
  }
}

/// 立即成功的压缩服务（manualCompact 成功链路测试用）
class _ImmediateCompactionService extends StoryCompactionService {
  _ImmediateCompactionService(
    this.summaryMessage, {
    this.tokensBefore = 0,
    this.tokensAfter = 0,
    this.replacedSummaryTokens = 0,
  }) : super(
          tokenCounter: TokenCounter(),
          llmService: _NoopLlmService(),
        );

  final ChatMessage summaryMessage;
  final int tokensBefore;
  final int tokensAfter;
  final int replacedSummaryTokens;
  int compactCalls = 0;

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
    Duration? responseStartTimeout,
    String? existingCompactionSummary,
    int baseContextTokens = 0,
    bool manual = false,
    void Function(String delta)? onSummaryDelta,
    CancellationToken? cancelToken,
  }) async {
    compactCalls++;
    onSummaryDelta?.call('摘要流式增量。');
    final boundary = history[history.length - 3];
    return CompactionResult(
      summary: summaryMessage.content ?? '',
      boundaryMessageId: boundary.messageId,
      compactedHistory: [summaryMessage, ...history.skip(history.length - 2)],
      tokensBefore: tokensBefore,
      tokensAfter: tokensAfter,
      replacedSummaryTokens: replacedSummaryTokens,
    );
  }
}

class _NoopLlmService implements LlmService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

// ── 生产页面接线测试用最小依赖 ──────────────────────────────────────

class _PageSettingsRepository implements SettingsRepository {
  @override
  Future<AppConfig> getResolvedConfig() async => const AppConfig(
        version: '0.1',
        broadcastChat: BroadcastChatConfig(),
      );

  @override
  Future<Map<String, dynamic>> getUserOverrides() async => const {};

  @override
  Future<void> setUserOverride(String key, dynamic value) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _PagePresetRepository implements ApiPresetRepository {
  @override
  Future<List<ApiPreset>> getAllPresets() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _PageTemplateRepository implements TemplateRepository {
  @override
  Future<List<Template>> getTemplatesByKind(TemplateKind kind) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _DelayedComposerDraftRepository extends ChatRepositoryImpl {
  _DelayedComposerDraftRepository({
    required super.database,
    required this.delayedSessionId,
  });

  final String delayedSessionId;
  final readStarted = Completer<void>();
  final releaseRead = Completer<void>();
  final writes = <(String, String?)>[];

  @override
  Future<void> setSessionDraft(String sessionId, String? draft) async {
    await super.setSessionDraft(sessionId, draft);
    writes.add((sessionId, draft));
  }

  @override
  Future<String?> getSessionDraft(String sessionId) async {
    if (sessionId == delayedSessionId) {
      if (!readStarted.isCompleted) readStarted.complete();
      await releaseRead.future;
    }
    return super.getSessionDraft(sessionId);
  }
}

class _PausedDraftWriteRepository extends ChatRepositoryImpl {
  _PausedDraftWriteRepository({required super.database, required this.input});

  final String input;
  final writeStarted = Completer<void>();
  final releaseWrite = Completer<void>();

  @override
  Future<void> setSessionDraft(String sessionId, String? draft) async {
    if (draft == input) {
      writeStarted.complete();
      await releaseWrite.future;
    }
    await super.setSessionDraft(sessionId, draft);
  }
}

/// 真实页面接线：ProviderScope 注入真实控制器与内存库，打开页面后
/// 通过 chip 进入详情（不复制页面参数组装）。
Future<void> _pumpAdvancedPage(
  WidgetTester tester,
  AppDatabase db,
  AdvancedChatController controller, {
  String? focus,
}) async {
  final session = controller.state.session;
  await _mountAdvancedPage(
    tester,
    ChatRepositoryImpl(database: db),
    {session: controller},
    ValueNotifier(session),
    focus: focus,
  );
}

Future<void> _mountAdvancedPage(
  WidgetTester tester,
  ChatRepositoryImpl repository,
  Map<ChatSession, AdvancedChatController> controllers,
  ValueNotifier<ChatSession> current, {
  String? focus,
}) async {
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        for (final entry in controllers.entries)
          advancedChatControllerProvider(entry.key)
              .overrideWith((ref) => entry.value),
        chatRepositoryProvider.overrideWithValue(repository),
        apiPresetRepositoryProvider.overrideWithValue(_PagePresetRepository()),
        templateRepositoryProvider.overrideWithValue(_PageTemplateRepository()),
        settingsRepositoryProvider.overrideWithValue(_PageSettingsRepository()),
        advancedConfigProvider
            .overrideWith((ref) async => const AdvancedConfig()),
        for (final session in controllers.keys)
          directorGmReadyProvider(session).overrideWith((ref) async => true),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          home: ValueListenableBuilder<ChatSession>(
            valueListenable: current,
            builder: (_, session, __) => AdvancedChatPage(
              session: session,
              initialFocusMessageId: focus,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 从页面 chip 打开详情面板（生产页面接线）
Future<void> _openDetailFromChip(WidgetTester tester) async {
  expect(find.byType(ContextUsageChip), findsOneWidget);
  await tester.tap(find.byType(ContextUsageChip));
  await tester.pumpAndSettle();
  expect(find.byType(ContextUsageDetailSheet), findsOneWidget);
}

class _PausedDirectorConsolidationLlm extends _NoopLlmService {
  final started = Completer<LlmRequest>();
  final reply = Completer<LlmResponse>();

  @override
  Future<LlmResponse> chat(LlmRequest request) {
    started.complete(request);
    return reply.future;
  }
}

class _ObservedDirectorConsolidation extends StoryPersistenceServiceImpl {
  _ObservedDirectorConsolidation({
    required super.database,
    required super.chatRepository,
    required super.experienceRepository,
  });

  final finished = Completer<bool>();

  @override
  Future<bool> persistConsolidatedMemories({
    required String sessionId,
    required List<ConsolidatedMemoryRecord> records,
    required List<ExperientialMemory> originalMemories,
  }) async {
    try {
      final persisted = await super.persistConsolidatedMemories(
        sessionId: sessionId,
        records: records,
        originalMemories: originalMemories,
      );
      finished.complete(persisted);
      return persisted;
    } catch (error, stackTrace) {
      finished.completeError(error, stackTrace);
      rethrow;
    }
  }
}

/// 轮前自动压缩服务：shouldCompact 恒真，返回固定摘要与保留段。
class _AutoCompactionService extends StoryCompactionService {
  _AutoCompactionService(this.summaryMessage, {this.useRealThreshold = false})
      : super(
          tokenCounter: StubTokenCounter(),
          llmService: _NoopLlmService(),
        );

  final ChatMessage summaryMessage;
  final bool useRealThreshold;
  int compactCalls = 0;

  @override
  Future<bool> shouldCompact({
    required List<ChatMessage> history,
    required int contextWindow,
    required ContextBudget budget,
    required String rolePrompt,
    required String userInput,
    String? compactionSummary,
  }) async {
    if (!useRealThreshold) return true;
    return super.shouldCompact(
      history: history,
      contextWindow: contextWindow,
      budget: budget,
      rolePrompt: rolePrompt,
      userInput: userInput,
      compactionSummary: compactionSummary,
    );
  }

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
    Duration? responseStartTimeout,
    String? existingCompactionSummary,
    int baseContextTokens = 0,
    bool manual = false,
    void Function(String delta)? onSummaryDelta,
    CancellationToken? cancelToken,
  }) async {
    compactCalls++;
    final boundary = history[5];
    return CompactionResult(
      summary: summaryMessage.content ?? '',
      boundaryMessageId: boundary.messageId,
      compactedHistory: [summaryMessage, ...history.skip(6)],
    );
  }
}

class _StubPresetRepo implements ApiPresetRepository {
  @override
  Future<ApiPreset> getPreset(String presetId) async => ApiPreset(
        presetId: presetId,
        name: 'Test',
        baseUrl: 'https://api.openai.com/v1',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _ThrowingSettingsRepo implements SettingsRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _StubEmbeddingService implements EmbeddingService {
  @override
  Future<Float32List> embed({
    required String text,
    required EmbeddingInputKind kind,
    required String model,
    required String baseUrl,
    required String? apiKey,
    Duration? timeout,
  }) async {
    throw UnimplementedError();
  }
}

/// 记录 insertLog 入参的 FailureLogRepository（mode 误标修复断言用）
class _RecordingFailureLogRepository implements FailureLogRepository {
  final modes = <String>[];

  @override
  @override
  Future<void> markRecovered(int logId) async {}

  @override
  Future<FailureLogEntry> insertLog({
    required String sessionId,
    required String mode,
    required String errorCategory,
    String? errorCode,
    String? failedPhase,
    int? httpStatus,
    String? errorMessage,
    String? rawError,
    String? outcome,
  }) async {
    modes.add(mode);
    return FailureLogEntry(
      id: 1,
      sessionId: sessionId,
      mode: mode,
      errorCategory: errorCategory,
      errorCode: errorCode,
      failedPhase: failedPhase,
      httpStatus: httpStatus,
      errorMessage: errorMessage,
      rawError: rawError,
      createdAt: DateTime(2026),
    );
  }

  @override
  Future<List<FailureLogEntry>> getRecentLogs({
    int limit = 50,
    String? mode,
    String? sessionId,
  }) async {
    return const <FailureLogEntry>[];
  }

  @override
  Future<int> countAll() async => 0;

  @override
  Future<void> clearAll() async {}

  @override
  Future<int> deleteBySession(String sessionId) async => 0;
}

// ── SSE HTTP client stub ────────────────────────────────────────────

class _SseHttpClient implements HttpClient {
  _SseHttpClient(
    this.responses, {
    this.bodyLog,
    this.partialStreamErrorAt,
    this.hangAt,
  });

  final List<String> responses;

  /// 每次请求的 body 快照（首回合提示注入断言用）
  final List<String>? bodyLog;

  /// 该次调用吐一条文本增量后流中断（模拟连接中途断开；
  /// 契约 §7.1 的 step 重试直播块污染场景）。中断次不消费 responses 列表
  /// （重试从列表头读起）
  final int? partialStreamErrorAt;

  /// 第 [hangAt] 次调用吐一条文本增量后挂住，[hangReleased] 置位后以
  /// 流错误收尾——模拟「正文直播到一半用户点停止」。挂住次一次性
  /// （不消费 responses 列表、不推进计数）。
  final int? hangAt;
  static const _hangChunk = '夜色沉下来，苏明远推开荒庙的门。';
  bool hangReleased = false;
  String? hangResponse;
  var _hangFired = false;

  /// 挂闸已吐首帧的确定性信号（测试 await 它替代轮询直播块）。
  final hangFired = Completer<void>();
  int callCount = 0;
  var _partialFired = false;

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
    bodyLog?.add(body ?? '');
    if (hangAt != null &&
        callCount == hangAt &&
        !_hangFired &&
        !_partialFired) {
      _hangFired = true;
      late final StreamController<String> controller;
      Timer? poller;
      controller = StreamController<String>(
        onListen: () {
          final chunkJson = jsonEncode({
            'choices': [
              {
                'delta': {'content': _hangChunk},
              },
            ],
          });
          controller.add('data: $chunkJson\n\n');
          if (!hangFired.isCompleted) hangFired.complete();
          final deadline = DateTime.now().add(const Duration(seconds: 12));
          poller = Timer.periodic(const Duration(milliseconds: 10), (_) {
            if (hangReleased ||
                (cancelToken?.isCancelled ?? false) ||
                DateTime.now().isAfter(deadline)) {
              poller?.cancel();
              final response = hangResponse;
              if (hangReleased && response != null) {
                callCount++;
                controller.add(response);
              } else {
                controller.addError(Exception('cancelled mid-stream'));
              }
              unawaited(controller.close());
            }
          });
        },
        onCancel: () => poller?.cancel(),
      );
      return controller.stream;
    }
    if (partialStreamErrorAt != null &&
        callCount == partialStreamErrorAt &&
        !_partialFired) {
      callCount++;
      _partialFired = true;
      return (() async* {
        // 与 main 内 _sse([_textDelta(...)]) 等价的内联 SSE（类外不可见局部函数）
        const chunk = '半截正文，流到这里断';
        yield 'data: {"choices":[{"delta":{"content":"$chunk"},"finish_reason":null}]}\n\n';
        throw Exception('connection reset mid-stream');
      })();
    }
    final response = responses[_partialFired ? callCount - 1 : callCount];
    callCount++;
    return Stream.value(response);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _DirectorHistoryReads extends QueryInterceptor {
  bool enabled = false;
  final reads = <({String table, int rows, int micros})>[];

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final stopwatch = Stopwatch()..start();
    final rows = await executor.runSelect(statement, args);
    if (!enabled) return rows;
    final query = statement.toLowerCase();
    final table = switch (query) {
      _
          when query.contains('from "chat_messages"') ||
              query.contains('from chat_messages') =>
        'messages',
      _ when query.contains('from intermediate_round_artifacts') =>
        query.contains('generated_text') ? 'artifacts' : 'summaries',
      _ when query.contains('from message_variants') => 'variants',
      _ when query.contains('from agent_events') =>
        query.contains('id, seq, type, time, data') ? 'events' : 'event probes',
      _ => null,
    };
    if (table != null) {
      reads.add(
        (
          table: table,
          rows: rows.length,
          micros: stopwatch.elapsedMicroseconds
        ),
      );
    }
    return rows;
  }

  int count(String table) => reads
      .where((read) => read.table == table)
      .fold(0, (total, read) => total + read.rows);

  String get totals {
    return {for (final read in reads) read.table}.map((table) {
      final samples = reads.where((read) => read.table == table);
      final micros = samples.fold(0, (total, read) => total + read.micros);
      return '$table=${count(table)} rows, ${samples.length} selects, ${micros}us';
    }).join(' | ');
  }
}

String _syntheticManuscript(int turn, int variant) =>
    'Story turn $turn, draft $variant. ${'Paragraph text. ' * 250}';

Future<ChatSession> _seedDirectorHistory(
  AppDatabase db,
  int turns, {
  String sessionId = 'director-history',
}) async {
  final start = DateTime.utc(2026);
  final output = 'Synthetic tool result. ' * 160;
  final step = AgentWorkStep(toolName: 'search_story', output: output);
  final steps = AgentWorkStep.listToJsonString([step]);
  final timeline = AgentTimelineBlock.listToJsonString([
    const AgentTimelineBlock(
      kind: AgentTimelineKind.thinking,
      stepIndex: 0,
      text: 'Synthetic thought',
    ),
    AgentTimelineBlock(
      kind: AgentTimelineKind.action,
      stepIndex: 0,
      action: step,
    ),
  ]);
  await db.batch((batch) {
    batch.customStatement(
      'INSERT INTO chat_sessions '
      '(session_id, title, mode, created_at, last_active_at, message_count, next_turn) '
      "VALUES (?, 'Synthetic director', 'advanced', ?, ?, ?, ?)",
      [
        sessionId,
        start.toIso8601String(),
        start.toIso8601String(),
        2 * turns,
        turns + 1,
      ],
    );
    for (var turn = 1; turn <= turns; turn++) {
      final prose = _syntheticManuscript(turn, 5);
      for (final (role, content, tick) in [
        ('user', 'Input $turn', 2 * turn),
        ('assistant', prose, 2 * turn + 1),
      ]) {
        batch.customStatement(
          'INSERT INTO chat_messages '
          '(message_id, session_id, role, content, created_at) '
          'VALUES (?, ?, ?, ?, ?)',
          [
            '$sessionId-$role-$turn',
            sessionId,
            role,
            content,
            start.add(Duration(seconds: tick)).toIso8601String(),
          ],
        );
      }
      final summary = jsonEncode(
        AgentWorkSummary(
          steps: 1,
          totalTokens: 160,
          durationMs: 100,
          lastPromptTokens: turn == turns ? null : 100,
          lastInputTokens: turn == turns ? null : 120,
          lastCacheReadTokens: 30,
        ).toJson(),
      );
      batch.customStatement(
        'INSERT INTO intermediate_round_artifacts '
        '(session_id, turn_number, generated_text, reply_text, '
        'agent_steps, agent_timeline, agent_summary, current_variant_index, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        [sessionId, turn, prose, prose, steps, timeline, summary, 5, turn],
      );
      for (final variant in [0, 2, 5]) {
        batch.customStatement(
          'INSERT INTO message_variants '
          '(session_id, turn_number, variant_index, content, source_input, created_at) '
          'VALUES (?, ?, ?, ?, ?, ?)',
          [
            sessionId,
            turn,
            variant,
            _syntheticManuscript(turn, variant),
            'Input $turn',
            turn,
          ],
        );
      }
    }
  });
  final log = AgentEventLogRepository(database: db);
  await log.appendAll(sessionId, [
    for (var turn = 1; turn <= turns; turn++) ...[
      AgentDurableEvent(type: AgentEventTypes.turnBegin, data: {'turn': turn}),
      for (var step = 0; step < 5; step++)
        AgentDurableEvent(
          type: AgentEventTypes.assistantChunk,
          data: {'turn': turn, 'stepIndex': step, 'text': output},
        ),
      AgentDurableEvent(
        type: AgentEventTypes.assistantMessage,
        surfaceOp: AgentSurfaceOpKind.append,
        data: {'turn': turn, 'text': _syntheticManuscript(turn, 5)},
      ),
      AgentDurableEvent(
        type: AgentEventTypes.stepEnd,
        data: {
          'turn': turn,
          'promptTokens': 100 + turn,
          'totalInputTokens': 120 + turn,
          'cacheReadTokens': 30,
        },
      ),
      AgentDurableEvent(type: AgentEventTypes.turnEnd, data: {'turn': turn}),
    ],
  ]);
  return ChatRepositoryImpl(database: db).getSession(sessionId);
}

class _RecordingLogSink extends LogSink {
  final records = <LogRecord>[];

  @override
  void write(LogRecord record) => records.add(record);

  @override
  Future<void> flush() async {}

  @override
  Future<void> dispose() async {}
}

class _FailingPostCommitVariantRefresh extends StoryPersistenceServiceImpl {
  _FailingPostCommitVariantRefresh(AppDatabase database, this._chat)
      : super(
          database: database,
          chatRepository: _chat,
          experienceRepository: ExperienceRepositoryImpl(
            database: database,
            vectorEngine: const VectorEngine(),
          ),
          factApplier: FactApplier(
            repository: FactualRepositoryImpl(database: database),
          ),
        );

  final ChatRepositoryImpl _chat;
  int refreshFailures = 0;

  @override
  Future<StoryHistoryTurnDetails> loadHistoryTurnDetails(
    String sessionId,
    Set<int> turns,
  ) async {
    if (refreshFailures == 0) {
      final messages = await _chat.getMessages(sessionId);
      if (messages.any((message) => message.role == 'assistant')) {
        refreshFailures++;
        throw StateError('Synthetic post-commit variant read failure');
      }
    }
    return super.loadHistoryTurnDetails(sessionId, turns);
  }
}

class _FailingCommittedEstimateCounter extends TokenCounter {
  _FailingCommittedEstimateCounter(this._chat, this._sessionId, this._reply);

  static const errorMessage = 'Synthetic error in a post-commit estimate';

  final ChatRepositoryImpl _chat;
  final String _sessionId;
  final String _reply;
  int failures = 0;

  @override
  Future<int> countTokens(String text) async {
    if (text == _reply) {
      final persisted = await _chat.getMessages(_sessionId);
      if (persisted.any(
        (message) => message.role == 'assistant' && message.content == _reply,
      )) {
        failures++;
        throw StateError(errorMessage);
      }
    }
    return text.length;
  }

  @override
  Future<List<int>> countTokensForEach(List<String> texts) async =>
      texts.map((text) => text.length).toList();
}

void main() {
  late AppDatabase db;
  late _SseHttpClient hangClient;
  late _DirectorHistoryReads historyReads;
  Directory? databaseDirectory;

  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  setUp(() {
    databaseDirectory = null;
    historyReads = _DirectorHistoryReads();
    db = AppDatabase.forTesting(
      NativeDatabase.memory().interceptWith(historyReads),
    );
  });

  tearDown(() async {
    await db.close();
    await databaseDirectory?.delete(recursive: true);
  });

  // ── SSE 脚本（OpenAI 兼容，官方端点 → 流式工具可靠）────────────────

  String sse(List<String> jsons) => jsons.map((j) => 'data: $j\n\n').join();

  String withMeasuredUsage(String body, int promptTokens) => body.replaceFirst(
        'data: [DONE]',
        'data: ${jsonEncode({
              'choices': <dynamic>[],
              'usage': {
                'prompt_tokens': promptTokens,
                'completion_tokens': 10,
                'total_tokens': promptTokens + 10,
              },
            })}\n\n'
            'data: [DONE]',
      );

  String textDelta(String content) =>
      '{"choices":[{"delta":{"content":${jsonEncode(content)}},"finish_reason":null}]}';

  String toolCallStart(int index, String id, String name, String args) =>
      '{"choices":[{"delta":{"tool_calls":[{"index":$index,"id":"$id","type":"function","function":{"name":"$name","arguments":${jsonEncode(args)}}}]},"finish_reason":null}]}';

  String finish(String reason) =>
      '{"choices":[{"delta":{},"finish_reason":"$reason"}]}';

  /// finish_round 一步：正文经 prose 参数交付（正文交付契约——content
  /// 只留过场播报，正文唯一载体是 prose 参数）
  String finishRoundStep(String callId, String prose) => sse([
        toolCallStart(
          0,
          callId,
          'finish_round',
          '{"prose":${jsonEncode(prose)}}',
        ),
        finish('tool_calls'),
        '[DONE]',
      ]);

  /// 终审闸门 B 的一次性豁免步：无事件记忆的首次 finish_round 被拒后，
  /// 脚本模型直接再次 finish_round（豁免放行）
  String finishRoundExemption(String callId, String prose) =>
      finishRoundStep(callId, prose);

  // ── 配置 stub ───────────────────────────────────────────────────────

  /// 轮询等待条件成立（超时返回 false 交由断言报错）。
  Future<bool> until(
    bool Function() cond, {
    // 并发全量下事件循环粒度放大，5s 窗会假超时——15s 保负载边界
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final sw = Stopwatch()..start();
    while (!cond()) {
      if (sw.elapsed > timeout) return false;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return true;
  }

  AdvancedChatController buildController(
    List<String> sseResponses, {
    int? maxSteps,
    int? maxDurationMinutes,
    bool withEventLog = false,
    bool withEngineeringSwitch = false,
    bool watchMode = false,
    List<String>? bodyLog,
    FailureLogRepository? failureLogRepository,
    bool failConfig = false,
    int? partialStreamErrorAt,
    AdvancedConfig? config,
    ConfigurationResolver? resolver,
    StoryCompactionService? compactionService,
    String sessionId = 'dir-test-1',
    ChatSession? restoredSession,
    int? hangAt,
    String? characterInitPrompt,
    String? characterInitCardId,
    ResourceApplyService? resourceApplyService,
    EngineeringSummarizer? engineeringSummarizer,
    EngineeringCompactionTuning? engineeringTuning,
    EngineeringCompactionService? engineeringServiceOverride,
    StoryPersistenceService? persistenceService,
    AgentEventLogRepository? eventLogRepository,
    DataStoreOperationGuard? operationGuard,
    ChatRepositoryImpl? chatRepository,
    Future<AdvancedConfig> Function()? getConfig,
    MemoryConsolidator? consolidator,
    http.Client? chatClient,
    TokenCounter? tokenCounter,
  }) {
    final chatRepo = chatRepository ?? ChatRepositoryImpl(database: db);
    final eventLog = eventLogRepository ??
        (withEventLog ? AgentEventLogRepository(database: db) : null);
    hangClient = _SseHttpClient(
      sseResponses,
      bodyLog: bodyLog,
      partialStreamErrorAt: partialStreamErrorAt,
      hangAt: hangAt,
    );
    final experienceRepo = ExperienceRepositoryImpl(
      database: db,
      vectorEngine: const VectorEngine(),
    );
    final factualRepo = FactualRepositoryImpl(database: db);

    return AdvancedChatController(
      operationGuard: operationGuard,
      chatRepository: chatRepo,
      configurationResolver: resolver ?? _FakeResolver(),
      llmService: LlmRemoteDataSource(
        httpClient: hangClient,
        adapterFactory: LlmAdapterFactory(),
        chatClient: chatClient,
      ),
      experienceRepository: experienceRepo,
      embeddingService: _StubEmbeddingService(),
      persistenceService: persistenceService ??
          StoryPersistenceServiceImpl(
            database: db,
            chatRepository: chatRepo,
            experienceRepository: experienceRepo,
            factApplier: FactApplier(repository: factualRepo),
          ),
      failureLogRepository:
          failureLogRepository ?? const StubFailureLogRepository(),
      tokenCounter: tokenCounter ?? TokenCounter(),
      getConfig: getConfig ??
          (failConfig
              ? () => throw const FormatException('config bad')
              : () async => config ?? const AdvancedConfig()),
      logger: const Logger('test'),
      session: restoredSession ??
          ChatSession(
            sessionId: sessionId,
            title: '测试导演',
            mode: 'advanced',
            createdAt: DateTime.now(),
            lastActiveAt: DateTime.now(),
            messageCount: 0,
            maxSteps: maxSteps,
            maxDurationMinutes: maxDurationMinutes,
            // v44 语义：监督模式经 tool_permissions 监督预设生效
            //（watchMode 列迁移后仅留档，运行时不再读取）
            watchMode: watchMode,
            toolPermissions: watchMode
                ? ToolPermissions.toJson(ToolPermissions.supervised)
                : null,
            // 向导「初始化你的角色」产物（草稿带至物化）
            characterInitPrompt: characterInitPrompt,
            characterInitCardId: characterInitCardId,
          ),
      factualRepository: factualRepo,
      agentEventLogRepository: eventLog,
      engineeringContextSwitch: withEngineeringSwitch ? eventLog : null,
      engineeringCompaction: withEngineeringSwitch && eventLog != null
          ? engineeringServiceOverride ??
              EngineeringCompactionService(
                database: db,
                eventRepository: eventLog,
                chatRepository: chatRepo,
                experienceRepository: experienceRepo,
                summarizer: engineeringSummarizer ?? _ThrowingSummarizer(),
                tuning:
                    engineeringTuning ?? const EngineeringCompactionTuning(),
              )
          : null,
      compactionService: compactionService,
      resourceApplyService: resourceApplyService,
      consolidator: consolidator,
    );
  }

  for (final turns in [30, 300]) {
    test('director cold history bounds full payload reads at $turns turns',
        () async {
      final session = await _seedDirectorHistory(db, turns);
      final timer = Stopwatch()..start();
      historyReads.enabled = true;
      final controller = buildController(
        const [],
        withEventLog: true,
        restoredSession: session,
      );
      addTearDown(controller.dispose);
      final ready = Completer<void>();
      int? firstTextMicros;
      final removeListener = controller.addListener((state) {
        if (state.messages.isNotEmpty) {
          firstTextMicros ??= timer.elapsedMicroseconds;
        }
        if (!state.loadingHistory && !ready.isCompleted) ready.complete();
      });
      await ready.future;
      removeListener();
      timer.stop();
      historyReads.enabled = false;
      debugPrint(
        'Director history $turns turns: messages ready ${firstTextMicros}us, '
        'load settled ${timer.elapsedMicroseconds}us | ${historyReads.totals}',
      );
      expect(controller.state.messages, hasLength(2 * turns));
      expect(
        controller.state.messages.last.content,
        _syntheticManuscript(turns, 5),
      );
      expect(
        controller.state.artifactsByTurnNumber?[turns]?.agentTimeline,
        hasLength(2),
      );
      expect(
        controller.state.variantsByTurn?[turns]?.last.content,
        _syntheticManuscript(turns, 5),
      );
      expect(controller.state.backfilledPromptTokens, 100 + turns);
      expect(historyReads.count('messages'), 2 * turns);
      expect(historyReads.count('artifacts'), lessThanOrEqualTo(8));
      expect(historyReads.count('variants'), lessThanOrEqualTo(24));
      expect(historyReads.count('events'), lessThanOrEqualTo(2));
    });
  }

  testWidgets('生产导演页面远处搜索按需补齐该轮幕后与所有稿件版本', (tester) async {
    final session = await _seedDirectorHistory(db, 30);
    final controller = buildController(const [], restoredSession: session);
    await controller.loadHistory();
    expect(controller.state.artifactsByTurnNumber?.containsKey(2), isFalse);

    historyReads.enabled = true;
    await _pumpAdvancedPage(
      tester,
      db,
      controller,
      focus: '${session.sessionId}-assistant-2',
    );
    await tester.pump();
    historyReads.enabled = false;

    expect(find.text('Input 2'), findsOneWidget);
    expect(
      controller.state.artifactsByTurnNumber?[2]?.agentTimeline,
      hasLength(2),
    );
    expect(
      controller.state.variantsByTurn?[2]?.map((draft) => draft.variantIndex),
      [0, 2, 5],
    );
    expect(historyReads.count('artifacts'), inInclusiveRange(1, 8));
    expect(historyReads.count('variants'), inInclusiveRange(3, 24));
    expect(controller.state.artifactsByTurnNumber?.containsKey(15), isFalse);
  });

  test(
      'director history batches visible older turns and keeps full usage totals',
      () async {
    final session = await _seedDirectorHistory(db, 30);
    final controller = buildController(const [], restoredSession: session);
    addTearDown(controller.dispose);
    await controller.loadHistory();
    expect(controller.state.artifactsByTurnNumber?.containsKey(1), isFalse);
    expect(
      controller.state.historyUsageStatistics,
      (averageCacheHit: 0.25, cacheCoveredRounds: 29, sessionRounds: 30),
    );

    historyReads.enabled = true;
    await Future.wait([
      controller.loadHistoryTurnDetails([1, 2]),
      controller.loadHistoryTurnDetails([2, 3]),
    ]);
    await controller.loadHistoryTurnDetails([1, 2, 3]);
    historyReads.enabled = false;

    expect(historyReads.count('artifacts'), 3);
    expect(historyReads.count('variants'), 9);
    expect(
      historyReads.reads.where((read) => read.table == 'artifacts'),
      hasLength(2),
    );
    expect(
      controller.state.artifactsByTurnNumber?[3]?.agentTimeline,
      hasLength(2),
    );
    expect(
      controller.state.variantsByTurn?[1]?.map((draft) => draft.variantIndex),
      [0, 2, 5],
    );
    expect(controller.state.historyUsageStatistics.sessionRounds, 30);
  });

  test('director history edit, delete and switch read back unloaded drafts',
      () async {
    final session = await _seedDirectorHistory(db, 30);
    final sessionId = session.sessionId;
    final controller = buildController(const [], restoredSession: session);
    addTearDown(controller.dispose);
    await controller.loadHistory();
    final first = controller.state.messages[1];
    final second = controller.state.messages[3];
    final third = controller.state.messages[5];
    expect(controller.state.variantsByTurn?[1], isNull);
    expect(controller.state.variantsByTurn?[2], isNull);

    await controller.deleteMessageVariant(second, 5);
    expect(controller.state.variantsByTurn?[2], isNull);
    expect(
      await controller.editMessageContent(first, 'Edited first manuscript.'),
      isTrue,
    );
    expect(
      controller.state.variantsByTurn?[1]?.last.content,
      'Edited first manuscript.',
    );
    await controller.switchMessageVariant(second, 2);
    expect(controller.state.variantSwitchBlockedReason, 'downstream');

    await controller.deleteRound(third);
    expect(controller.state.variantsByTurn?[2], isNull);
    expect(controller.state.historyUsageStatistics.sessionRounds, 2);
    await controller.switchMessageVariant(second, 2);
    expect(controller.state.artifactsByTurnNumber?[2]?.currentVariantIndex, 2);
    expect(
      controller.state.variantsByTurn?[2]?.map((draft) => draft.variantIndex),
      [0, 2, 5],
    );
    expect(controller.state.messages.last.content, _syntheticManuscript(2, 2));

    final chatRepo = ChatRepositoryImpl(database: db);
    final saved = await chatRepo.getMessages(sessionId);
    expect(saved, hasLength(4));
    expect(saved[1].content, 'Edited first manuscript.');
    expect(saved.last.content, _syntheticManuscript(2, 2));
    final variantRows = await db.customSelect(
      'SELECT turn_number, variant_index, content FROM message_variants '
      'WHERE session_id = ? ORDER BY turn_number, variant_index',
      variables: [Variable.withString(sessionId)],
    ).get();
    expect(variantRows, hasLength(6));
    expect(variantRows[2].read<String>('content'), 'Edited first manuscript.');
    expect(variantRows.last.read<int>('variant_index'), 5);
  });

  test(
      'director history regeneration snapshots process of an unopened old turn',
      () async {
    final session = await _seedDirectorHistory(db, 30);
    final bodies = <String>[];
    final controller = buildController(
      [
        sse([textDelta('Regenerated manuscript.'), finish('stop'), '[DONE]']),
      ],
      restoredSession: session,
      bodyLog: bodies,
    );
    addTearDown(controller.dispose);
    await controller.loadHistory();
    final target = controller.state.messages[3];
    expect(controller.state.artifactsByTurnNumber?[2], isNull);

    await controller.regenerateMessage(target);

    expect(controller.state.failureContext, isNull);
    final chatRepo = ChatRepositoryImpl(database: db);
    final saved = await chatRepo.getMessages(session.sessionId);
    expect(saved, hasLength(4));
    expect(saved.last.content, 'Regenerated manuscript.');
    expect(bodies.single, contains('round-work n=1'));
    final previous = await db.customSelect(
      'SELECT content, source_input, agent_timeline FROM message_variants '
      'WHERE session_id = ? AND turn_number = 2 AND variant_index = 6',
      variables: [Variable.withString(session.sessionId)],
    ).getSingle();
    expect(previous.read<String>('content'), _syntheticManuscript(2, 5));
    expect(previous.read<String>('source_input'), 'Input 2');
    expect(
      previous.read<String>('agent_timeline'),
      contains('Synthetic thought'),
    );
    expect(controller.state.artifactsByTurnNumber?[2]?.currentVariantIndex, 7);
  });

  test(
      'director history send waits for current epoch and retains distant material',
      () async {
    final staleSession = await _seedDirectorHistory(db, 10);
    final first = buildController(
      const [],
      withEventLog: true,
      withEngineeringSwitch: true,
      restoredSession: staleSession,
    );
    addTearDown(first.dispose);
    await first.loadHistory();
    expect(first.state.artifactsByTurnNumber?[1], isNull);
    expect(await first.setEngineeringContextEnabled(enabled: true), isTrue);

    final bodies = <String>[];
    final reopened = buildController(
      [
        sse([textDelta('New manuscript.'), finish('stop'), '[DONE]']),
      ],
      withEventLog: true,
      withEngineeringSwitch: true,
      restoredSession: staleSession,
      bodyLog: bodies,
    );
    addTearDown(reopened.dispose);
    expect(reopened.state.loadingHistory, isTrue);
    expect(await reopened.sendMessage('Hello from the next turn.'), isTrue);
    expect(reopened.state.engineeringMode, EngineeringRuntimeMode.normalOpen);
    expect(reopened.state.failureContext, isNull);
    expect(bodies.single, contains('Story turn 1, draft 5.'));
    expect(bodies.single, contains('round-work n=1'));
    expect(bodies.single, contains('Hello from the next turn.'));
    final saved = await ChatRepositoryImpl(database: db)
        .getMessages(staleSession.sessionId);
    expect(saved.last.content, 'New manuscript.');
  });

  test('director engineering switch excludes sends and backup overwrite',
      () async {
    final session = await _seedDirectorHistory(db, 2);
    final repo = ChatRepositoryImpl(database: db);
    final guard = DataStoreOperationGuard();
    final eventLog = _PausedEngineeringEnter(database: db);
    final controller = buildController(
      const [],
      withEngineeringSwitch: true,
      eventLogRepository: eventLog,
      operationGuard: guard,
      restoredSession: session,
    );
    addTearDown(controller.dispose);
    await controller.loadHistory();
    final service = DataManagementService(
      chatRepository: repo,
      presetRepository: _StubPresetRepo(),
      settingsRepository: _ThrowingSettingsRepo(),
      backupRepository: BackupRepositoryImpl(database: db),
      operationGuard: guard,
    );
    const payload = '{"version":3,"sessions":[{"session":'
        '{"session_id":"other-story","title":"Replacement","mode":"advanced"}}]}';

    final switching = controller.setEngineeringContextEnabled(enabled: true);
    var snapshots = 0;
    try {
      await eventLog.entered.future.timeout(const Duration(seconds: 5));
      expect(await controller.sendMessage('Conflicting input'), isFalse);
      await expectLater(
        service.importBackup(
          payload,
          ImportMode.overwrite,
          preImportSnapshot: () async => snapshots++,
        ),
        throwsA(isA<BackupOverwriteBusyException>()),
      );
    } finally {
      eventLog.resume.complete();
    }
    expect(await switching, isTrue);
    expect(snapshots, 0);
    final persisted = await repo.getSession(session.sessionId);
    final events = await eventLog.readEvents(session.sessionId);
    expect(persisted.engineeringContextEnabled, isTrue);
    expect(
      resolveEngineeringMode(enabled: true, events: events).mode,
      EngineeringRuntimeMode.normalOpen,
    );
    expect(
      (await repo.getMessages(session.sessionId)).map((m) => m.content),
      [
        'Input 1',
        _syntheticManuscript(1, 5),
        'Input 2',
        _syntheticManuscript(2, 5),
      ],
    );
  });

  test('director ledger recovery sees compaction repair before dangling turn',
      () async {
    final session = await _seedDirectorHistory(db, 30);
    final repo = AgentEventLogRepository(database: db);
    final sessionId = session.sessionId;
    await repo.appendAll(sessionId, [
      AgentDurableEvent(
        type: AgentEventTypes.compactionStart,
        data: {'opId': 'pending-compaction'},
      ),
      AgentDurableEvent(
        type: AgentEventTypes.compactionCancel,
        data: {'opId': 'pending-compaction'},
      ),
      AgentDurableEvent(
        type: AgentEventTypes.turnBegin,
        // Legacy logs may encode a numeric value; only JSON true is a subagent.
        data: {'turn': 31, 'subagent': 1},
      ),
      AgentDurableEvent(
        type: AgentEventTypes.assistantMessage,
        surfaceOp: AgentSurfaceOpKind.append,
        data: {
          'turn': 31,
          'stepIndex': 0,
          'toolCalls': [
            {
              'id': 'unfinished-search',
              'name': 'search_story',
              'args': <String, Object?>{},
            },
          ],
        },
      ),
      AgentDurableEvent(
        type: AgentEventTypes.assistantChunk,
        data: {'turn': 31, 'stepIndex': 1, 'text': 'Unfinished manuscript.'},
      ),
      AgentDurableEvent(
        type: AgentEventTypes.turnEnd,
        data: {'turn': 31, 'subagent': true},
      ),
      AgentDurableEvent(
        type: AgentEventTypes.stepEnd,
        data: {'turn': 31, 'subagent': true, 'promptTokens': 9999},
      ),
    ]);

    final controller = buildController(
      const [],
      withEventLog: true,
      restoredSession: session,
    );
    addTearDown(controller.dispose);
    final concurrent =
        AgentLogRecoveryService(repository: repo).recover(sessionId);
    await Future.wait([controller.loadHistory(), concurrent]);
    expect(controller.state.backfilledPromptTokens, 130);

    final events = await repo.readEvents(sessionId);
    expect(events.any((event) => event.data['turn'] == 11), isFalse);
    expect(events.any((event) => event.data['turn'] == 12), isTrue);
    final repaired = events.sublist(events.length - 4);
    expect(repaired.map((event) => event.type), [
      AgentEventTypes.compactionEnd,
      AgentEventTypes.toolResult,
      AgentEventTypes.assistantMessage,
      AgentEventTypes.turnEnd,
    ]);
    expect(repaired[0].data['error'], 'cancelled');
    expect(repaired[1].data['callId'], 'unfinished-search');
    expect(repaired[2].data['text'], 'Unfinished manuscript.');
    expect(repaired[3].data['reason'], 'interrupted');
    expect(
      await AgentLogRecoveryService(repository: repo).recover(sessionId),
      isFalse,
    );
  });
  group('导演模式异步记忆提炼', () {
    test('删轮完成后丢弃迟到的模型提炼结果', () async {
      const deadline = Duration(seconds: 5);
      final chatRepo = ChatRepositoryImpl(database: db);
      final session = await chatRepo.createSession(
        title: '导演提炼测试',
        mode: 'advanced',
      );
      final id = session.sessionId;
      final experienceRepo = ExperienceRepositoryImpl(
        database: db,
        vectorEngine: const VectorEngine(),
      );
      for (final summary in ['导演源经历一', '导演源经历二']) {
        await experienceRepo.appendExperience(
          sessionId: id,
          summary: summary,
          importance: 2,
          tags: const [],
          turnNumber: 1,
          indexForRetrieval: false,
        );
      }
      final model = _PausedDirectorConsolidationLlm();
      final guard = DataStoreOperationGuard();
      final persistence = _ObservedDirectorConsolidation(
        database: db,
        chatRepository: chatRepo,
        experienceRepository: experienceRepo,
      );
      final controller = buildController(
        [
          sse([
            toolCallStart(
              0,
              'memo',
              'record_event_memory',
              '{"what":"本轮经历","importance":2}',
            ),
            finish('tool_calls'),
            '[DONE]',
          ]),
          finishRoundStep('first', '导演本轮正文'),
        ],
        sessionId: id,
        config: const AdvancedConfig(
          consolidation: ConsolidationConfig(triggerThreshold: 0),
        ),
        operationGuard: guard,
        persistenceService: persistence,
        consolidator: MemoryConsolidator(llmService: model),
      );
      addTearDown(controller.dispose);

      Future<void> expectNoMemories() async {
        expect(await experienceRepo.getAllExperiences(id), isEmpty);
        final indexed = await db.customSelect(
          'SELECT memory_id FROM memories_fts WHERE session_id = ?',
          variables: [Variable.withString(id)],
        ).get();
        expect(indexed, isEmpty);
      }

      expect(await controller.sendMessage('导演本轮输入'), isTrue);
      final request = await model.started.future.timeout(deadline);
      try {
        expect(request.purpose, LlmPurposes.memoryMerge);
        expect(request.messages.last['content'], contains('导演源经历一'));
        expect(request.messages.last['content'], contains('导演源经历二'));
        expect(guard.tryBeginOverwrite(), isNull);

        await controller
            .deleteRound(controller.state.messages.last)
            .timeout(deadline);
        expect(await chatRepo.getMessages(id), isEmpty);
        await expectNoMemories();
      } finally {
        final finished = persistence.finished.future.timeout(deadline);
        model.reply.complete(
          const LlmResponse(
            content: '{"consolidated":[{"summary":"迟到的导演提炼", "importance":4}]}',
          ),
        );
        await finished;
      }

      expect(await persistence.finished.future, isFalse);
      await expectNoMemories();
    });
  });

  group('导演会话打开与物化后的互斥', () {
    test('存量会话回填先于导演收稿，库和内存保留轮次元数据', () async {
      final repo = PausedSessionUpdate(database: db);
      final session = await repo.createSession(title: '旧导演', mode: 'advanced');
      final controller = buildController(
        [
          sse([
            toolCallStart(
              0,
              'memo',
              'record_event_memory',
              '{"what":"故事开场","importance":3}',
            ),
            finish('tool_calls'),
            '[DONE]',
          ]),
          finishRoundStep('first', '新正文'),
        ],
        sessionId: session.sessionId,
        chatRepository: repo,
        resolver: _LegacyDirectorResolver(),
      );
      addTearDown(controller.dispose);
      final stale =
          await repo.entered.future.timeout(const Duration(seconds: 5));
      expect(stale.messageCount, 0);
      final round = controller.sendMessage('新输入');
      final startedEarly = controller.state.phase != IntermediatePhase.idle;
      try {
        if (startedEarly) {
          expect(await round, isTrue);
          expect((await repo.getSession(session.sessionId)).messageCount, 2);
        }
      } finally {
        repo.resume.complete();
      }
      await repo.written.future;
      expect(await round, isTrue);
      await Future<void>.delayed(Duration.zero);

      final stored = await repo.getSession(session.sessionId);
      expect(
        (stored.messageCount, stored.nextTurn, stored.currentNarrativeTime),
        (2, 2, null),
      );
      final visible = controller.state.session;
      expect(
        (visible.messageCount, visible.nextTurn, visible.currentNarrativeTime),
        (2, 2, null),
      );
      expect(startedEarly, isFalse);
    });

    test('打开时的日志恢复不能给活轮补写 interrupted', () async {
      final repo = ChatRepositoryImpl(database: db);
      final session = await repo.createSession(title: '旧导演', mode: 'advanced');
      final log = AgentEventLogRepository(database: db);
      final entered = Completer<void>();
      final resume = Completer<void>();
      final response = finishRoundStep('first', '正文');
      final controller = buildController(
        [response, finishRoundExemption('second', '正文')],
        sessionId: session.sessionId,
        eventLogRepository: log,
        hangAt: 0,
        getConfig: () async {
          if (!entered.isCompleted) {
            entered.complete();
            await resume.future;
          }
          return const AdvancedConfig();
        },
      );
      addTearDown(controller.dispose);
      await entered.future.timeout(const Duration(seconds: 5));
      final round = controller.sendMessage('当前轮');
      final startedEarly = controller.state.phase != IntermediatePhase.idle;
      try {
        if (startedEarly) {
          await hangClient.hangFired.future.timeout(const Duration(seconds: 5));
          final live = await log.readEvents(session.sessionId);
          expect(
            live.any((event) => event.type == AgentEventTypes.turnBegin),
            isTrue,
          );
        }
      } finally {
        resume.complete();
      }
      expect(await until(() => !controller.state.loadingHistory), isTrue);
      await hangClient.hangFired.future.timeout(const Duration(seconds: 5));
      final whileActive = await log.readEvents(session.sessionId);
      hangClient
        ..hangResponse = response
        ..hangReleased = true;
      expect(await round, isTrue);
      expect(
        whileActive.where(
          (event) =>
              event.type == AgentEventTypes.turnEnd &&
              event.data['reason'] == 'interrupted',
        ),
        isEmpty,
      );
      expect(await repo.getMessages(session.sessionId), hasLength(2));
    });

    test('草稿 key 与真实 key 保护同一导演轮，收稿后可从真实 key 发送', () async {
      final guard = DataStoreOperationGuard();
      final repo = ChatRepositoryImpl(database: db);
      final firstResponse = finishRoundStep('first', '首轮正文');
      final draft = buildController(
        [firstResponse, finishRoundExemption('exempt', '首轮正文')],
        sessionId: '${AdvancedChatController.draftSessionIdPrefix}alias',
        operationGuard: guard,
        hangAt: 0,
      );
      addTearDown(draft.dispose);
      final firstHttp = hangClient;
      final first = draft.sendMessage('草稿首轮');
      await firstHttp.hangFired.future.timeout(const Duration(seconds: 5));
      final realId = draft.state.session.sessionId;
      final reopened = buildController(
        [
          finishRoundStep('next', '后续正文'),
          finishRoundExemption('nextb', '后续正文'),
        ],
        sessionId: realId,
        operationGuard: guard,
      );
      addTearDown(reopened.dispose);
      try {
        expect(await reopened.sendMessage('保留的输入'), isFalse);
        expect(hangClient.callCount, 0);
        expect(await repo.getMessages(realId), isEmpty);
      } finally {
        firstHttp
          ..hangResponse = firstResponse
          ..hangReleased = true;
        await first;
      }
      expect(await reopened.sendMessage('保留的输入'), isTrue);
      expect(
        (await repo.getMessages(realId)).map((message) => message.content),
        ['草稿首轮', '首轮正文', '保留的输入', '后续正文'],
      );
    });

    test('草稿物化后配置异常，真实会话可继续发送', () async {
      final guard = DataStoreOperationGuard();
      final repo = ChatRepositoryImpl(database: db);
      final entered = Completer<void>();
      final resume = Completer<void>();
      final draft = buildController(
        const [],
        sessionId: '${AdvancedChatController.draftSessionIdPrefix}error',
        operationGuard: guard,
        getConfig: () async {
          entered.complete();
          await resume.future;
          throw const FormatException('synthetic configuration failure');
        },
      );
      addTearDown(draft.dispose);

      final first = draft.sendMessage('配置异常的输入');
      await entered.future.timeout(const Duration(seconds: 5));
      final realId = draft.state.session.sessionId;
      final reopened = buildController(
        [
          finishRoundStep('next', '恢复后的正文'),
          finishRoundExemption('nextb', '恢复后的正文'),
        ],
        sessionId: realId,
        operationGuard: guard,
      );
      addTearDown(reopened.dispose);
      try {
        expect(await reopened.sendMessage('恢复后的输入'), isFalse);
        expect(await repo.getMessages(realId), isEmpty);
      } finally {
        resume.complete();
        await first;
      }
      expect(draft.state.phase, IntermediatePhase.failed);
      expect(await reopened.sendMessage('恢复后的输入'), isTrue);
      expect(
        (await repo.getMessages(realId)).map((message) => message.content),
        ['恢复后的输入', '恢复后的正文'],
      );
      expect(
        (await repo.getAllSessions()).map((session) => session.sessionId),
        [realId],
      );
    });
  });

  group('导演会话操作互斥', () {
    for (final retryFirst in [false, true]) {
      test(retryFirst ? '草稿重试挡住重试和直发' : '草稿双发只物化一次', () async {
        final gm = _PausedDirectorResolver()..gmConfigured = !retryFirst;
        final controller = buildController(
          [
            finishRoundStep('call_first', '首轮正文'),
            finishRoundExemption('call_first_again', '首轮正文'),
          ],
          resolver: gm,
          sessionId: '${AdvancedChatController.draftSessionIdPrefix}serial',
        );
        addTearDown(controller.dispose);
        if (retryFirst) {
          expect(await controller.sendMessage('原输入'), isTrue);
          expect(controller.state.pendingUserMessage?.content, '原输入');
          gm.gmConfigured = true;
        }
        gm.pauseModel = true;
        final first = retryFirst
            ? controller.retry()
            : controller.sendMessage('原输入').then<void>((accepted) {
                expect(accepted, isTrue);
              });
        await gm.entered.future.timeout(const Duration(seconds: 5));
        final repeated =
            retryFirst ? controller.continueFromFailed() : Future<void>.value();
        final second = controller.sendMessage('冲突输入');
        await Future<void>.delayed(Duration.zero);
        final visits = gm.visits;
        gm.resume.complete();
        final accepted = await second;
        await Future.wait([first, repeated]);

        expect(visits, 1);
        expect(accepted, isFalse);
        expect(controller.state.queuedMessage, isNull);
        expect(controller.isDraftSession, isFalse);
        expect(
          await db.customSelect('SELECT session_id FROM chat_sessions').get(),
          hasLength(1),
        );
        final repo = ChatRepositoryImpl(database: db);
        final messages =
            await repo.getMessages(controller.state.session.sessionId);
        expect(messages.map((message) => message.content), ['原输入', '首轮正文']);
        expect(hangClient.callCount, 2);
      });
    }

    test('中断续跑只补写一次事件并提交原轮', () async {
      final eventLog = _PausedResumeEventLog(database: db);
      final controller = buildController(
        [
          finishRoundStep('call_resume', '续跑正文'),
          finishRoundExemption('call_resume_again', '续跑正文'),
        ],
        hangAt: 0,
        eventLogRepository: eventLog,
      );
      addTearDown(controller.dispose);
      final stopped = controller.sendMessage('起始输入');
      await hangClient.hangFired.future;
      expect(await until(() => controller.state.liveBlocks.isNotEmpty), isTrue);
      await controller.cancel();
      await stopped;
      expect(await until(() => !controller.state.isStopping), isTrue);
      expect(controller.state.phase, IntermediatePhase.failed);
      eventLog.pause = true;
      final first = controller.continueFromFailed();
      await eventLog.entered.future;
      final second = controller.continueFromFailed();
      // 让第二个入口读到正在补写前的同一份事件。
      await eventLog.readEvents('dir-test-1');
      await Future<void>.delayed(Duration.zero);
      eventLog.resume.complete();
      await Future.wait([first, second]);

      final events = await eventLog.readEvents('dir-test-1');
      expect(eventLog.repairWrites, 1);
      expect(
        events.where(
          (event) =>
              event.type == AgentEventTypes.assistantMessage &&
              event.data['interrupted'] == true,
        ),
        hasLength(1),
      );
      expect(
        events.where(
          (event) =>
              event.type == AgentEventTypes.turnBegin &&
              event.data['resumed'] == true,
        ),
        hasLength(1),
      );
      expect(hangClient.callCount, 2);
      final messages =
          await ChatRepositoryImpl(database: db).getMessages('dir-test-1');
      expect(messages.map((message) => message.content), ['起始输入', '续跑正文']);
    });

    for (final operation in ['delete', 'switch', 'undo']) {
      test('$operation 与发送双向互斥且读回正确', () async {
        final persistence = _PausedDirectorMutation(db, operation);
        final resolver = _PausedDirectorResolver()..gmConfigured = true;
        final script = <String>[
          finishRoundStep('call_first', '首轮正文'),
          finishRoundExemption('call_first_again', '首轮正文'),
          if (operation == 'switch') ...[
            finishRoundStep('call_regen', '重生成正文'),
            finishRoundExemption('call_regen_again', '重生成正文'),
          ],
          finishRoundStep('call_next', '后续正文'),
          finishRoundExemption('call_next_again', '后续正文'),
        ];
        final controller = buildController(
          script,
          persistenceService: persistence,
          resolver: resolver,
        );
        addTearDown(controller.dispose);
        await controller.sendMessage('已收稿输入');
        final target = controller.state.messages.last;
        if (operation == 'switch') await controller.regenerateMessage(target);
        if (operation == 'undo') {
          await persistence.persistManualCompaction(
            compaction: CompactionPersistenceData(
              summaryMessage: ChatMessage(
                messageId: 'summary',
                sessionId: 'dir-test-1',
                role: 'system',
                content: '压缩摘要',
                isSummary: true,
                createdAt: DateTime(2026),
              ),
              boundaryMessageId: target.messageId,
              turnNumber: 1,
              segmentMacroSummary: '宏摘要',
            ),
          );
          await controller.loadHistory();
        }
        Future<void> mutate() async {
          switch (operation) {
            case 'delete':
              await controller.deleteRound(target);
            case 'switch':
              await controller.switchMessageVariant(
                controller.state.messages.last,
                0,
              );
            case 'undo':
              await controller.undoCompaction();
          }
        }

        persistence.pause = true;
        final mutation = mutate();
        await persistence.entered.future;
        final conflicting = await controller.sendMessage('冲突输入');
        persistence.resume.complete();
        await mutation;
        expect(conflicting, isFalse);
        expect(persistence.calls, 1);
        final repo = ChatRepositoryImpl(database: db);
        final afterMutation = await repo.getMessages('dir-test-1');
        if (operation == 'delete') expect(afterMutation, isEmpty);
        if (operation == 'switch') {
          expect(afterMutation.last.content, '首轮正文');
          final artifacts =
              await persistence.loadArtifactsBySession('dir-test-1');
          expect(artifacts[1]?.currentVariantIndex, 0);
        }
        if (operation == 'undo') {
          expect(await repo.getCompactionPoints('dir-test-1'), isEmpty);
          expect(afterMutation.any((message) => message.isSummary), isFalse);
        }

        resolver.pauseSettings = true;
        final next = controller.sendMessage('合法输入');
        await resolver.entered.future;
        await mutate();
        resolver.resume.complete();
        expect(await next, isTrue);
        expect(persistence.calls, 1);
        final readBack = await repo.getMessages('dir-test-1');
        expect(readBack.map((message) => message.content), [
          if (operation != 'delete') ...['已收稿输入', '首轮正文'],
          '合法输入',
          '后续正文',
        ]);
        expect(
          controller.state.messages.map((message) => message.messageId),
          readBack.map((message) => message.messageId),
        );
      });
    }
  });

  // ── ：dispose 冲刷压缩缓冲 ────────────────────────

  /// 先吐一条 delta 再挂门闸——delta 进入 32ms 合帧缓冲后压缩挂起，
  /// 精确模拟「dispose 恰落在缓冲窗口内」。
  test('dispose 冲刷压缩缓冲尾段，之后零写入', () async {
    final chatRepo = ChatRepositoryImpl(database: db);
    // 5 轮完整对话（满足 minDialogueMessages=8 下限）
    for (var i = 1; i <= 10; i++) {
      await chatRepo.addMessage(
        ChatMessage(
          messageId: 'dm$i',
          sessionId: 'dir-test-1',
          role: i.isOdd ? 'user' : 'assistant',
          content: '第${(i + 1) ~/ 2}轮',
          createdAt: DateTime(2026),
        ),
      );
    }

    final gated = _GatedDeltaCompactionService();
    final controller = buildController(
      const [],
      compactionService: gated,
    );
    // 构造函数触发的 loadHistory 是异步链
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    // 前置：delta 已先于门闸到达并进入 32ms 合帧缓冲（state 未写入）
    unawaited(controller.manualCompact());
    // manualCompact 到 compact 之间有多级 await，轮询等到达门闸
    for (var i = 0; i < 50 && gated.compactCalls == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(gated.compactCalls, 1);
    expect(controller.state.isManualCompacting, isTrue);
    expect(controller.state.manualCompactionDelta, isEmpty);

    String? lastDelta;
    controller
      ..addListener((s) => lastDelta = s.manualCompactionDelta)
      // 压缩挂起中销毁控制器
      ..dispose();

    // 冲刷语义：挂起尾段在 dispose 时落账
    expect(
      lastDelta,
      isNotEmpty,
      reason: 'dispose 应冲刷压缩缓冲尾段',
    );

    // 零写入语义：等待超过合帧间隔，不得有任何挂起 Timer 再写 state
    await Future<void>.delayed(const Duration(milliseconds: 60));
  });

  // ── 2026-09-08 用户报告排查：导演手动压缩完成后摘要必须可见 ──────────
  //
  // 用户实测：流式压缩内容正常，但完成后「会话中没有压缩摘要、圆环数据
  // 不变、不确定是否成功」。本用例钉死成功链路的可观察产物：
  // persistManualCompaction 落库 + 重载后 state.messages 头部是摘要消息。
  test('manualCompact 成功：摘要消息落库并出现在过滤后历史头部', () async {
    final chatRepo = ChatRepositoryImpl(database: db);
    // 5 轮完整对话（满足 minDialogueMessages=8 下限）
    for (var i = 1; i <= 10; i++) {
      await chatRepo.addMessage(
        ChatMessage(
          messageId: 'mc$i',
          sessionId: 'dir-test-1',
          role: i.isOdd ? 'user' : 'assistant',
          content: '第${(i + 1) ~/ 2}轮的对话内容，长度足够参与压缩。',
          createdAt: DateTime(2026),
        ),
      );
    }

    final summaryMessage = ChatMessage(
      messageId: 'mc-summary',
      sessionId: 'dir-test-1',
      role: 'system',
      content: '这是压缩后的前情摘要。',
      isSummary: true,
      createdAt: DateTime(2026, 1, 1, 0, 0, 30),
    );
    final fake = _ImmediateCompactionService(summaryMessage);
    final controller = buildController(const [], compactionService: fake);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    final result = await controller.manualCompact();
    expect(result, ManualCompactResult.success, reason: '压缩应成功');
    expect(controller.state.isManualCompacting, isFalse);
    expect(
      controller.state.manualCompactionError,
      isNull,
      reason: '成功路径不得残留错误态',
    );
    expect(fake.compactCalls, 1);

    // 落库验证：压缩点存在
    final points = await chatRepo.getCompactionPoints('dir-test-1');
    expect(points, hasLength(1), reason: 'persistManualCompaction 必须落压缩点');
    expect(points.single['summaryMessageId'], 'mc-summary');

    // 重载验证：过滤后历史头部是摘要消息（会话内可见摘要卡的判据）
    expect(
      controller.state.messages.first.isSummary,
      isTrue,
      reason: '压缩完成后会话历史头部应是摘要消息（用户可见反馈）',
    );
    expect(controller.state.messages.first.messageId, 'mc-summary');
    // 保留区仍在（boundary 之后的近期对话不丢）
    expect(
      controller.state.messages.any((m) => m.messageId == 'mc10'),
      isTrue,
      reason: '压缩保留区必须保留近期消息',
    );
  });

  test('manualCompact 成功：当前预计扣除旧摘要，构成图按同一材料重建', () async {
    final chatRepo = ChatRepositoryImpl(database: db);
    for (var i = 1; i <= 10; i++) {
      await chatRepo.addMessage(
        ChatMessage(
          messageId: 'mc$i',
          sessionId: 'dir-test-1',
          role: i.isOdd ? 'user' : 'assistant',
          content: '第${(i + 1) ~/ 2}轮的对话内容，长度足够参与压缩。',
          createdAt: DateTime(2026),
        ),
      );
    }

    final summaryMessage = ChatMessage(
      messageId: 'mc-summary',
      sessionId: 'dir-test-1',
      role: 'system',
      content: '这是压缩后的前情摘要。',
      isSummary: true,
      createdAt: DateTime(2026, 1, 1, 0, 0, 30),
    );
    // 压缩前：锚点 150 = 规则 20 + 旧摘要 30 + 对话 100
    // 压缩服务口径：tokensBefore=100（仅对话）、tokensAfter=20（新摘要）
    // 正确新材料 = 150 - 100 - 30 + 20 = 40
    final fake = _ImmediateCompactionService(
      summaryMessage,
      tokensBefore: 100,
      tokensAfter: 20,
      replacedSummaryTokens: 30,
    );
    final controller = buildController(const [], compactionService: fake);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    controller.state = controller.state.copyWith(
      contextEstimate: ContextUsageEstimate.reported(tokens: 150),
      contextSegmentChars: const {
        'system': 100,
        'history': 999,
        'directive': 50,
      },
    );

    final result = await controller.manualCompact();
    expect(result, ManualCompactResult.success);

    final estimate = controller.state.contextEstimate!;
    expect(estimate.tokens, 40, reason: '旧摘要必须被扣除，不能残留 70');
    expect(estimate.isEstimated, isTrue);

    // 构成图与主数字同属压缩后材料修订：历史段按过滤后消息重建，
    // 不能用压缩前 999 字符的占比去分摊压缩后的总数。
    final expectedHistoryChars = controller.state.messages.fold<int>(
      0,
      (sum, m) => sum + (m.content?.length ?? 0),
    );
    expect(
      controller.state.contextSegmentChars!['history'],
      expectedHistoryChars,
    );
    expect(
      controller.state.contextSegmentChars!['system'],
      100,
      reason: '不受压缩影响的系统段保留原字符数',
    );
    expect(
      controller.state.contextSegmentChars!['directive'],
      0,
      reason: '上一轮指令已随用户消息进入历史，不得重复计入构成图',
    );
  });

  test('重进会话：没有有效快照时保持未知，不复活压缩前实报', () async {
    final chatRepo = ChatRepositoryImpl(database: db);
    for (var i = 1; i <= 10; i++) {
      await chatRepo.addMessage(
        ChatMessage(
          messageId: 'mc$i',
          sessionId: 'dir-test-1',
          role: i.isOdd ? 'user' : 'assistant',
          content: '第${(i + 1) ~/ 2}轮的对话内容，长度足够参与压缩。',
          createdAt: DateTime(2026),
        ),
      );
    }
    final summaryMessage = ChatMessage(
      messageId: 'mc-summary',
      sessionId: 'dir-test-1',
      role: 'system',
      content: '这是压缩后的前情摘要。',
      isSummary: true,
      createdAt: DateTime(2026, 1, 1, 0, 0, 30),
    );
    final fake = _ImmediateCompactionService(
      summaryMessage,
      tokensBefore: 100,
      tokensAfter: 20,
      replacedSummaryTokens: 30,
    );
    final first = buildController(const [], compactionService: fake);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    first.state = first.state.copyWith(
      contextEstimate: ContextUsageEstimate.reported(tokens: 150),
    );
    expect(await first.manualCompact(), ManualCompactResult.success);

    // 关闭重开：内存估算丢失；历史里仍有旧请求输入，但不得当当前值
    final reopened = buildController(const [], compactionService: fake);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(
      reopened.state.contextEstimate,
      isNull,
      reason: '重进不得把压缩前实报复活为当前预计',
    );
  });

  test('updateSession 配置变化：旧当前预计失效并重算容量', () async {
    final controller = buildController(const []);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    controller.state = controller.state.copyWith(
      contextEstimate: ContextUsageEstimate.reported(tokens: 12345),
    );

    final ok = await controller.updateSession(
      controller.state.session.copyWith(modelId: 'other-model'),
    );
    expect(ok, isTrue);
    expect(controller.state.session.modelId, 'other-model');
    expect(controller.state.contextEstimate, isNotNull);
    expect(
      controller.state.contextEstimate!.hasData,
      isFalse,
      reason: '模型变化后旧实报失效，保持未知直到下一次请求',
    );
  });

  test('配置失效后手动压缩不得复活旧配置输入锚点', () async {
    final chatRepo = ChatRepositoryImpl(database: db);
    for (var i = 1; i <= 10; i++) {
      await chatRepo.addMessage(
        ChatMessage(
          messageId: 'ci$i',
          sessionId: 'dir-test-1',
          role: i.isOdd ? 'user' : 'assistant',
          content: '第${(i + 1) ~/ 2}轮的对话内容，长度足够参与压缩。',
          createdAt: DateTime(2026),
        ),
      );
    }
    final fake = _ImmediateCompactionService(
      ChatMessage(
        messageId: 'ci-summary',
        sessionId: 'dir-test-1',
        role: 'system',
        content: '这是压缩后的前情摘要。',
        isSummary: true,
        createdAt: DateTime(2026, 1, 1, 0, 0, 30),
      ),
      tokensBefore: 100,
      tokensAfter: 20,
      replacedSummaryTokens: 30,
    );
    final controller = buildController(const [], compactionService: fake);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    controller.state = controller.state.copyWith(
      contextEstimate: ContextUsageEstimate.reported(tokens: 150),
    );
    await controller.updateSession(
      controller.state.session.copyWith(modelId: 'other-model'),
    );
    expect(controller.state.contextEstimate!.hasData, isFalse);

    final result = await controller.manualCompact();
    expect(result, ManualCompactResult.success);
    expect(
      controller.state.contextEstimate!.hasData,
      isFalse,
      reason: '已明确失效的旧配置实报不得经压缩差分恢复成当前预计',
    );
  });

  test('历史回填：数字与异常标识同源，冲突样本保持未知', () async {
    final chatRepo = ChatRepositoryImpl(database: db);
    for (var i = 1; i <= 2; i++) {
      await chatRepo.addMessage(
        ChatMessage(
          messageId: 'bf$i',
          sessionId: 'dir-test-1',
          role: i.isOdd ? 'user' : 'assistant',
          content: '用于回填的历史对话。',
          createdAt: DateTime(2026),
        ),
      );
    }
    // 旧摘要缺完整输入（模拟实施前落库的 agent_summary）
    await db.customStatement(
      'INSERT INTO intermediate_round_artifacts '
      '(session_id, turn_number, agent_summary, created_at) '
      'VALUES (?, ?, ?, ?)',
      [
        'dir-test-1',
        1,
        jsonEncode(
          const AgentWorkSummary(steps: 1, totalTokens: 1200, durationMs: 100)
              .toJson(),
        ),
        DateTime(2026).millisecondsSinceEpoch,
      ],
    );
    // 最新主请求事件：完整输入 1000、缓存 800，但字段冲突
    await AgentEventLogRepository(database: db).append(
      'dir-test-1',
      AgentDurableEvent(
        type: AgentEventTypes.stepEnd,
        time: DateTime(2026),
        data: const {
          'promptTokens': 1000,
          'totalInputTokens': 1000,
          'cacheReadTokens': 800,
          'usageWarnings': ['字段冲突'],
        },
      ),
    );

    final controller = buildController(const [], withEventLog: true);
    addTearDown(controller.dispose);
    expect(
      await until(() => controller.state.backfilledTotalInputTokens != null),
      isTrue,
      reason: '真实 loadHistory 应完成旧会话回填',
    );

    final sample = controller.state.latestMainRequestUsage!;
    expect(sample.inputTokens, 1000);
    expect(sample.cacheReadTokens, 800);
    expect(sample.warnings, ['字段冲突'], reason: '异常标识必须与数字同源回填');
    expect(controller.state.latestMainRequestCacheHitRatio, isNull);
    expect(controller.state.latestMainRequestCacheSampleInvalid, isTrue);
  });

  testWidgets('生产页面接线：回填冲突样本打开详情仍显示未知', (tester) async {
    final chatRepo = ChatRepositoryImpl(database: db);
    for (var i = 1; i <= 2; i++) {
      await chatRepo.addMessage(
        ChatMessage(
          messageId: 'pf$i',
          sessionId: 'dir-test-1',
          role: i.isOdd ? 'user' : 'assistant',
          content: '回填冲突样本的历史对话。',
          createdAt: DateTime(2026),
        ),
      );
    }
    await db.customStatement(
      'INSERT INTO intermediate_round_artifacts '
      '(session_id, turn_number, agent_summary, created_at) '
      'VALUES (?, ?, ?, ?)',
      [
        'dir-test-1',
        1,
        jsonEncode(
          const AgentWorkSummary(steps: 1, totalTokens: 1200, durationMs: 100)
              .toJson(),
        ),
        DateTime(2026).millisecondsSinceEpoch,
      ],
    );
    await AgentEventLogRepository(database: db).append(
      'dir-test-1',
      AgentDurableEvent(
        type: AgentEventTypes.stepEnd,
        time: DateTime(2026),
        data: const {
          'promptTokens': 1000,
          'totalInputTokens': 1000,
          'cacheReadTokens': 800,
          'usageWarnings': ['字段冲突'],
        },
      ),
    );

    final controller = buildController(const [], withEventLog: true);
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    });
    expect(controller.state.backfilledTotalInputTokens, 1000);

    await _pumpAdvancedPage(tester, db, controller);
    await _openDetailFromChip(tester);

    expect(find.text(t.common.contextRing.cacheSampleInvalid), findsOneWidget);
    expect(find.textContaining('80.0%'), findsNothing);
    // 历史分项仍按同源回填展示完整输入 1000
    expect(
      find.textContaining(ContextUsageDetailSheet.formatTokenCount(1000)),
      findsWidgets,
    );
  });

  testWidgets('生产页面接线：真实轮次末次合法 0 缓存经页面显示 0.0%', (tester) async {
    // 每步捕获到的 usage 注入流：首步制造计量冲突（早步异常），
    // 末步合法（完整输入 1000、缓存读取真实 0）。摘要落库必须只认
    // 末次请求自身的样本，不能被早步异常牵连。
    String withUsage(String body, {required bool conflict}) {
      final usage = <String, dynamic>{
        'prompt_tokens': 1000,
        'completion_tokens': 10,
        'total_tokens': 1010,
        'prompt_tokens_details': {'cached_tokens': conflict ? 800 : 0},
        if (conflict) ...{
          'prompt_cache_hit_tokens': 700,
          'prompt_cache_miss_tokens': 300,
        },
      };
      return body.replaceFirst(
        'data: [DONE]',
        'data: ${jsonEncode({'choices': <dynamic>[], 'usage': usage})}\n\n'
            'data: [DONE]',
      );
    }

    final controller = buildController([
      withUsage(finishRoundStep('warn-first', '首步正文。'), conflict: true),
      withUsage(
        finishRoundExemption('valid-second', '末步正文。'),
        conflict: false,
      ),
    ]);
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    });
    await tester.runAsync(() => controller.sendMessage('推进剧情'));

    final artifacts = controller.state.artifactsByTurnNumber!;
    final latest = artifacts.keys.reduce((a, b) => a > b ? a : b);
    final summary = artifacts[latest]!.agentWorkSummary!;
    expect(
      summary.totalTokens,
      2020,
      reason: '首步冲突样本确实进入了并账（两步各 1010）',
    );
    expect(summary.lastInputTokens, 1000);
    expect(summary.lastCacheReadTokens, 0);
    expect(summary.lastCacheHitRatio, 0.0);
    expect(
      summary.usageWarnings,
      isEmpty,
      reason: '早步冲突样本不得污染末次合法请求的摘要',
    );
    expect(controller.state.latestMainRequestCacheHitRatio, 0.0);

    await _pumpAdvancedPage(tester, db, controller);
    await _openDetailFromChip(tester);

    expect(find.textContaining('0.0%'), findsWidgets);
    expect(find.text(t.common.contextRing.cacheSampleInvalid), findsNothing);
  });

  testWidgets('已打开详情面板：真实页面内压缩成功后预计与构成同步', (tester) async {
    final chatRepo = ChatRepositoryImpl(database: db);
    for (var i = 1; i <= 10; i++) {
      await chatRepo.addMessage(
        ChatMessage(
          messageId: 'cw$i',
          sessionId: 'dir-test-1',
          role: i.isOdd ? 'user' : 'assistant',
          content: '第${(i + 1) ~/ 2}轮的对话内容，长度足够参与压缩。',
          createdAt: DateTime(2026),
        ),
      );
    }
    final fake = _ImmediateCompactionService(
      ChatMessage(
        messageId: 'cw-summary',
        sessionId: 'dir-test-1',
        role: 'system',
        content: '这是压缩后的前情摘要。',
        isSummary: true,
        createdAt: DateTime(2026, 1, 1, 0, 0, 30),
      ),
      tokensBefore: 100,
      tokensAfter: 20,
      replacedSummaryTokens: 30,
    );
    final controller = buildController(const [], compactionService: fake);
    // widget 测试的 fake async 不推进真实定时器：初始化统一放到 runAsync
    // 的真实事件循环里跑完，再经真实页面打开详情。
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    });

    controller.state = controller.state.copyWith(
      contextEstimate: ContextUsageEstimate.reported(tokens: 150),
      contextSegmentChars: const {
        'system': 100,
        'history': 50,
        'directive': 50,
      },
      // 历史实报：上一轮摘要带完整输入 150。压缩只调整「当前预计」，
      // 不得改写「最近请求」这条历史事实。
      artifactsByTurnNumber: {
        1: StoryRoundArtifacts(
          sessionId: 'dir-test-1',
          turnNumber: 1,
          createdAt: DateTime(2026),
          agentWorkSummary: const AgentWorkSummary(
            steps: 1,
            totalTokens: 150,
            durationMs: 100,
            lastPromptTokens: 150,
            lastInputTokens: 150,
            lastCacheReadTokens: 0,
          ),
        ),
      },
    );

    await _pumpAdvancedPage(tester, db, controller);
    await _openDetailFromChip(tester);

    // 面板已打开：主数字与构成来自真实页面消费的控制器状态
    expect(find.textContaining('150'), findsWidgets);
    expect(
      find.textContaining(t.advanced.contextComposition.directive),
      findsOneWidget,
    );
    expect(
      tester.widget<ContextUsageChip>(find.byType(ContextUsageChip)).numerator,
      150,
    );

    final result = await tester.runAsync(controller.manualCompact);
    expect(result, ManualCompactResult.success);
    await tester.pumpAndSettle();

    // 已打开面板随真实控制器压缩结果同步：150 -> 40，构成重建
    expect(find.byType(ContextUsageDetailSheet), findsOneWidget);
    expect(find.textContaining('40'), findsWidgets);
    expect(
      find.textContaining(t.advanced.contextComposition.directive),
      findsNothing,
      reason: '上一轮指令已迁入历史，构成图不得重复计入',
    );
    expect(
      controller.state.contextSegmentChars!['system'],
      100,
      reason: '历史实报与不受压缩影响的段保留',
    );
    // 历史实报不被当前估算覆盖
    expect(controller.state.latestMainRequestInputTokens, 150);
    expect(find.textContaining('150'), findsWidgets);
    // chip 仍在，并跟随压缩后的当前预计
    expect(find.byType(ContextUsageChip), findsOneWidget);
    expect(
      tester.widget<ContextUsageChip>(find.byType(ContextUsageChip)).numerator,
      40,
    );
  });

  test('轮前自动压缩：state.messages/compactedTurnBase 与摘要同步', () async {
    final chatRepo = ChatRepositoryImpl(database: db);
    for (var i = 1; i <= 10; i++) {
      await chatRepo.addMessage(
        ChatMessage(
          messageId: 'ac$i',
          sessionId: 'dir-test-1',
          role: i.isOdd ? 'user' : 'assistant',
          content: '第${(i + 1) ~/ 2}轮的历史对话内容。',
          createdAt: DateTime(2026),
        ),
      );
    }
    final summaryMessage = ChatMessage(
      messageId: 'auto-summary',
      sessionId: 'dir-test-1',
      role: 'system',
      content: '自动压缩摘要。',
      isSummary: true,
      createdAt: DateTime(2026, 1, 1, 0, 0, 30),
    );
    final compaction = _AutoCompactionService(summaryMessage);
    final controller = buildController(
      [
        sse([
          textDelta('夜色沉下来。'),
          finish('stop'),
          '[DONE]',
        ]),
      ],
      compactionService: compaction,
    );
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    await controller.sendMessage('继续');

    expect(compaction.compactCalls, 1);
    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.state.messages.first.isSummary, isTrue);
    expect(controller.state.messages.first.messageId, 'auto-summary');
    expect(controller.state.compactedTurnBase, 3);
  });

  for (final (ratio, threshold, compactions) in [
    (0.30, 9600, 1),
    (0.80, 25600, 0),
  ]) {
    test('常规上下文按保存的比例 $ratio 决定轮前压缩', () async {
      final repo = ChatRepositoryImpl(database: db);
      await repo.createSession(
        sessionId: 'dir-test-1',
        title: '测试导演',
        mode: 'advanced',
      );
      for (var i = 0; i < 10; i++) {
        await repo.addMessage(
          ChatMessage(
            messageId: 'history-$i',
            sessionId: 'dir-test-1',
            role: i.isEven ? 'user' : 'assistant',
            content: 'x' * 1400,
            createdAt: DateTime(2026, 1, 1, 0, 0, i),
          ),
        );
      }
      final compaction = _AutoCompactionService(
        ChatMessage(
          messageId: 'summary-fixture',
          sessionId: 'dir-test-1',
          role: 'system',
          content: '合成历史摘要',
          isSummary: true,
          createdAt: DateTime(2026),
        ),
        useRealThreshold: true,
      );
      final controller = buildController(
        [
          sse([textDelta('继续写作。'), finish('stop'), '[DONE]']),
        ],
        compactionService: compaction,
      );
      addTearDown(controller.dispose);
      await controller.loadHistory();
      await controller.updateSession(
        controller.state.session
            .copyWith(compactionTriggerRatioOverride: ratio),
      );
      expect(
        (await repo.getSession('dir-test-1')).compactionTriggerRatioOverride,
        ratio,
      );
      await controller.sendMessage('继续');
      expect(controller.state.compactionTriggerTokens, threshold);
      expect(compaction.compactCalls, compactions);
    });
  }

  test('mode=advanced：agent 检索 → finish_round → 复用 persistRound 落库', () async {
    final controller = buildController([
      // Step 1：search_story（参数分片）
      sse([
        textDelta('我先查一下。'),
        toolCallStart(0, 'call_s1', 'search_story', '{"query":'),
        r'{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"古碑\"}"}}]},"finish_reason":null}]}',
        finish('tool_calls'),
        '[DONE]',
      ]),
      // Step 2：正文经 prose 参数交付 + finish_round（终审闸门 B：尚无事件记忆 → 拒绝）
      finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
      // Step 3：补记事件记忆（闸门 B 的可行动反馈）
      sse([
        toolCallStart(
          0,
          'call_m1',
          'record_event_memory',
          '{"what":"苏明远夜探荒庙","importance":3}',
        ),
        finish('tool_calls'),
        '[DONE]',
      ]),
      // Step 4：二次 finish_round 放行
      finishRoundStep('call_f2', '夜色沉下来，苏明远推开荒庙的门。'),
    ]);

    await controller.sendMessage('苏明远进入荒庙');

    // 消息落库（复用故事模式 persistRound）
    final messages = await db.customSelect(
      'SELECT role, content FROM chat_messages WHERE session_id = ? '
      'ORDER BY created_at ASC',
      variables: [Variable.withString('dir-test-1')],
    ).get();
    expect(messages, hasLength(2));
    expect(messages.first.read<String>('role'), 'user');
    expect(messages.last.read<String>('content'), contains('夜色沉下来'));

    // 状态收敛
    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.state.messages, hasLength(2));
  });

  test('mode=advanced：事实写入经 FactApplier 生效', () async {
    final controller = buildController([
      sse([
        toolCallStart(
          0,
          'call_u1',
          'update_facts',
          '{"deltas":[{"action":"create_entity","confidence":4,'
              '"primary_name":"苏明远","entity_type":"character","importance":4}]}',
        ),
        finish('tool_calls'),
        '[DONE]',
      ]),
      finishRoundStep('call_f2', '故事继续。'),
      finishRoundExemption('call_f2b', '故事继续。'),
    ]);

    await controller.sendMessage('推进剧情');

    final entities = await db.customSelect(
      'SELECT COUNT(*) AS c FROM factual_entities WHERE session_id = ?',
      variables: [Variable.withString('dir-test-1')],
    ).getSingle();
    expect(entities.read<int>('c'), 1);
  });

  List<String> factRoundScript(
    int turn,
    String roundReply,
    String roundSummary,
    List<FactsDelta> deltas,
  ) =>
      [
        sse([
          toolCallStart(
            0,
            'facts-$turn',
            'update_facts',
            jsonEncode(
              {'deltas': deltas.map((delta) => delta.toJson()).toList()},
            ),
          ),
          finish('tool_calls'),
          '[DONE]',
        ]),
        sse([
          toolCallStart(
            0,
            'memory-$turn',
            'record_event_memory',
            jsonEncode({'what': roundSummary, 'importance': 3}),
          ),
          finish('tool_calls'),
          '[DONE]',
        ]),
        finishRoundStep('finish-$turn', roundReply),
      ];

  test('director mode publishes one warning for a committed partial fact write',
      () async {
    // The capability resolver selects streaming tool calls for this fixture.
    const host = 'api.openai.com.director-fixture.invalid';
    const baseUrl = 'https://fixture-user:fixture-password@'
        '$host/private-inference?api_key=fixture-query-key';
    const apiKey = 'fixture-request-key';
    const input = 'Inspect the harbor.';
    const reply = 'The keeper returned to the harbor.';
    const summary = 'The keeper inspected the harbor.';
    final chat = ChatRepositoryImpl(database: db);
    final session = await chat.createSession(
      title: 'Synthetic directed story',
      mode: 'advanced',
    );
    await rejectFixtureFactHistory(db);
    final logSink = _RecordingLogSink();
    Logger.addSink(logSink);
    addTearDown(() => Logger.removeSink(logSink));
    final chatClient = MockClient((_) async {
      throw StateError('Unexpected non-streaming fixture request');
    });
    addTearDown(chatClient.close);

    final controller = buildController(
      [
        ...factRoundScript(1, reply, summary, factWriteFixtureDeltas),
        ...factRoundScript(
          2,
          'The keeper rested at the beacon.',
          'The keeper rested.',
          guardedFactFixtureDeltas,
        ),
        finishRoundStep('finish-2-confirm', 'The keeper rested at the beacon.'),
      ],
      sessionId: session.sessionId,
      chatRepository: chat,
      resolver: _FakeResolver(baseUrl: baseUrl, apiKey: apiKey),
      chatClient: chatClient,
    );
    addTearDown(controller.dispose);
    final warnings = <(String, int, int, IntermediatePhase)>[];
    final removeListener = controller.addListener((state) {
      final warning = state.factWriteWarning;
      if (warning != null) {
        warnings.add(
          (
            state.session.sessionId,
            warning.turnNumber,
            warning.count,
            state.phase
          ),
        );
      }
    });
    addTearDown(removeListener);

    expect(await controller.sendMessage(input), isTrue);
    expect(warnings, [(session.sessionId, 1, 1, IntermediatePhase.idle)]);
    final start = logSink.records
        .singleWhere((record) => record.message == 'Director round start');
    expect(start.detail, contains('protocol=openaiCompatible'));
    for (final sensitiveText in [
      baseUrl,
      'fixture-user',
      'fixture-password',
      host,
      'private-inference',
      'fixture-query-key',
      apiKey,
    ]) {
      expect(start.toLine(), isNot(contains(sensitiveText)));
    }
    final factError = logSink.records.singleWhere(
      (record) => record.message == 'Failed to apply single delta, skipping',
    );
    expect(
      factError.detail,
      allOf(contains('action=createEntity'), contains('errorType=')),
    );
    expect(factError.error, isNull);
    expect(factError.stackTrace, isNotNull);
    expect(
      factError.toLine(),
      isNot(contains(factWriteFixtureDeltas.first.value)),
    );
    expect(
      controller.state.artifactsByTurnNumber?[1]?.factsChanges.single.newValue,
      savedFixtureFactName,
    );
    await expectCommittedFactFixtureRound(
      db,
      sessionId: session.sessionId,
      userInput: input,
      reply: reply,
      summary: '',
      what: summary,
    );

    await controller.loadHistory();
    expect(controller.state.factWriteWarning, isNull);
    expect(await controller.sendMessage('Return to the beacon.'), isTrue);
    expect(controller.state.artifactsByTurnNumber?[2]?.factsChanges, isEmpty);
    expect(controller.state.factWriteWarning, isNull);
    expect(warnings, hasLength(1));
  });

  test('director retains committed feedback even when variants cannot reload',
      () async {
    const input = 'Inspect the harbor.';
    const reply = 'The keeper returned to the harbor.';
    const summary = 'The keeper inspected the harbor.';
    final chat = ChatRepositoryImpl(database: db);
    final session = await chat.createSession(
      title: 'Synthetic directed story',
      mode: 'advanced',
    );
    await rejectFixtureFactHistory(db);
    final chatClient = MockClient((_) async {
      throw StateError('Unexpected non-streaming fixture request');
    });
    addTearDown(chatClient.close);
    final persistence = _FailingPostCommitVariantRefresh(db, chat);
    final controller = buildController(
      factRoundScript(1, reply, summary, factWriteFixtureDeltas),
      sessionId: session.sessionId,
      chatRepository: chat,
      persistenceService: persistence,
      resolver: _FakeResolver(
        baseUrl: 'https://api.openai.com.director-fixture.invalid/v1',
      ),
      chatClient: chatClient,
    );
    addTearDown(controller.dispose);
    await controller.loadHistory();
    final previousVariants = controller.state.variantsByTurn;
    expect(persistence.refreshFailures, 0);
    final warnings = <(String, int, int)>[];
    final removeListener = controller.addListener((state) {
      final warning = state.factWriteWarning;
      if (warning != null) {
        warnings
            .add((state.session.sessionId, warning.turnNumber, warning.count));
      }
    });
    addTearDown(removeListener);

    expect(await controller.sendMessage(input), isTrue);
    expect(persistence.refreshFailures, 1);
    await expectCommittedFactFixtureRound(
      db,
      sessionId: session.sessionId,
      userInput: input,
      reply: reply,
      summary: '',
      what: summary,
    );
    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.state.failureContext, isNull);
    expect(controller.state.messages.map((message) => message.content), [
      input,
      reply,
    ]);
    expect(
      controller.state.artifactsByTurnNumber?[1]?.factsChanges.single.newValue,
      savedFixtureFactName,
    );
    expect(controller.state.variantsByTurn, previousVariants);
    expect(warnings, [(session.sessionId, 1, 1)]);

    await controller.loadHistory();
    expect(persistence.refreshFailures, 1);
    expect(controller.state.factWriteWarning, isNull);
    expect(warnings, hasLength(1));
  });

  test('director keeps saved text when token estimation fails after commit',
      () async {
    const input = 'Inspect the harbor.';
    const reply = 'The keeper returned to the harbor.';
    const summary = 'The keeper inspected the harbor.';
    const promptTokens = 1200;
    final chat = ChatRepositoryImpl(database: db);
    final session = await chat.createSession(
      title: 'Synthetic directed story',
      mode: 'advanced',
    );
    await rejectFixtureFactHistory(db);
    final logSink = _RecordingLogSink();
    Logger.addSink(logSink);
    addTearDown(() => Logger.removeSink(logSink));
    final chatClient = MockClient((_) async {
      throw StateError('Unexpected non-streaming fixture request');
    });
    addTearDown(chatClient.close);
    final counter =
        _FailingCommittedEstimateCounter(chat, session.sessionId, reply);
    final script = factRoundScript(1, reply, summary, factWriteFixtureDeltas);
    script[script.length - 1] = withMeasuredUsage(script.last, promptTokens);
    final controller = buildController(
      script,
      sessionId: session.sessionId,
      chatRepository: chat,
      tokenCounter: counter,
      resolver: _FakeResolver(
        baseUrl: 'https://api.openai.com.director-fixture.invalid/v1',
      ),
      chatClient: chatClient,
    );
    addTearDown(controller.dispose);
    await controller.loadHistory();
    final warnings = <(String, int, int)>[];
    final removeListener = controller.addListener((state) {
      final warning = state.factWriteWarning;
      if (warning != null) {
        warnings
            .add((state.session.sessionId, warning.turnNumber, warning.count));
      }
    });
    addTearDown(removeListener);

    expect(counter.failures, 0);
    expect(await controller.sendMessage(input), isTrue);
    expect(counter.failures, 1);
    await expectCommittedFactFixtureRound(
      db,
      sessionId: session.sessionId,
      userInput: input,
      reply: reply,
      summary: '',
      what: summary,
    );
    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.state.failureContext, isNull);
    expect(controller.state.messages.map((message) => message.content), [
      input,
      reply,
    ]);
    expect(
      controller.state.contextEstimate,
      const ContextUsageEstimate.unknown(),
    );
    expect(controller.state.latestMainRequestInputTokens, promptTokens);
    expect(controller.state.latestMainRequestUsage?.completionTokens, 10);
    expect(
      controller.state.artifactsByTurnNumber?[1]?.factsChanges.single.newValue,
      savedFixtureFactName,
    );
    expect(warnings, [(session.sessionId, 1, 1)]);
    final estimateWarning = logSink.records.singleWhere(
      (record) => record.message == 'Estimate committed director reply failed',
    );
    expect(estimateWarning.detail, 'errorType=StateError');
    expect(
      estimateWarning.toLine(),
      isNot(contains(_FailingCommittedEstimateCounter.errorMessage)),
    );

    await controller.loadHistory();
    expect(counter.failures, 1);
    expect(controller.state.factWriteWarning, isNull);
    expect(warnings, hasLength(1));
    expect(controller.state.latestMainRequestInputTokens, promptTokens);
  });

  test('mode=advanced：工具失败后空响应弃疗 → failed 可重试（不再静默 idle）', () async {
    final script = <String>[
      // 步骤 1：update_facts 参数缺定位字段（弱模型形态）→ 失败信封回喂
      sse([
        toolCallStart(
          0,
          'call_bad',
          'update_facts',
          '{"deltas":[{"action":"create","confidence":4}]}',
        ),
        finish('tool_calls'),
        '[DONE]',
      ]),
    ];
    // 步骤 2 起：空响应（弃疗）。批 D 归一后 EMPTY_RESPONSE 会先自动
    // 重试（P5 默认 5 次）——脚本补足重试消耗的空响应条目，全部空后
    // 耗尽进 failed（终态语义不变：failed 可重试）
    for (var i = 0; i < 7; i++) {
      script.add(sse([finish('stop'), '[DONE]']));
    }
    final controller = buildController(script);

    await controller.sendMessage('推进剧情');

    // 空正文完成进 failed（此前静默回 idle，整轮无声消失）
    expect(controller.state.phase, IntermediatePhase.failed);
    expect(controller.state.failureContext?.errorCode, 'EAGENT');
    expect(controller.state.failureContext?.retryable, isTrue);
    // 批 D/E：空响应已被 EMPTY_RESPONSE 语义归一——先自动重试 5 次（P5）
    // 耗尽后进 failed；终态语义不变（failed 可重试），消息含空响应原因
    expect(controller.state.failureContext?.errorMessage, contains('空响应'));
    // 临时用户消息保留（重试入口的数据基础）
    expect(controller.state.pendingUserMessage, isNotNull);
    // DD2：先失败后弃疗 → 肇事步骤转红（只有中断本轮才用红色；
    // 同一轮里被模型修复的失败是 warning）
    final badStep = controller.state.agentSteps
        .where((s) => s.toolName == 'update_facts')
        .toList();
    expect(badStep, isNotEmpty, reason: '失败工具卡应留在步骤列表');
    expect(
      badStep.first.status,
      AgentStepStatus.error,
      reason: '中断轮的肇事步骤应升级为 error',
    );
    // 无任何消息落库
    final count = await db.customSelect(
      'SELECT COUNT(*) AS c FROM chat_messages WHERE session_id = ?',
      variables: [Variable.withString('dir-test-1')],
    ).getSingle();
    expect(count.read<int>('c'), 0);

    // pending 重新生成入口：重发后整轮恢复正常落库
    script.addAll([
      finishRoundStep('call_f9', '雨停了，他走出荒庙。'),
      finishRoundExemption('call_f9b', '雨停了，他走出荒庙。'),
    ]);
    await controller.retryPendingUserMessage();

    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.state.pendingUserMessage, isNull);
    final messages = await db.customSelect(
      'SELECT role, content FROM chat_messages WHERE session_id = ? '
      'ORDER BY created_at ASC',
      variables: [Variable.withString('dir-test-1')],
    ).get();
    expect(messages, hasLength(2));
    expect(messages.last.read<String>('content'), contains('雨停了'));
  });

  test('mode=advanced：失败日志记录真实 mode（不再硬编码 intermediate）', () async {
    // 解耦重构 0.2 修复：_fail 此前硬编码 mode: 'intermediate'，
    // 导演轮失败被误记为故事模式，污染诊断页筛选。
    // 经 _getConfig 抛错 → E010 → _fail 落日志（agent 空正文路径不经 _fail）。
    final failureLog = _RecordingFailureLogRepository();
    final controller = buildController(
      const [],
      failureLogRepository: failureLog,
      failConfig: true,
    );

    await controller.sendMessage('推进剧情');

    expect(controller.state.phase, IntermediatePhase.failed);
    expect(failureLog.modes, ['advanced']);
  });

  test('GM 未配置 → E010 落 generating + 报点级建议覆盖', () async {
    // 导演主模型未配置时失败卡此前标「关键词提取」阶段
    //（导演无此阶段）且建议是通用「前往设置配置 API 供应商和模型」，
    // 指不到导演设置的真实入口——连探索者都被误导成解析回归疑案。
    final controller =
        buildController(const [], resolver: _GmMissingResolver());

    await controller.sendMessage('推进剧情');

    expect(controller.state.phase, IntermediatePhase.failed);
    final ctx = controller.state.failureContext!;
    expect(ctx.errorCode, 'E010');
    // 导演无六步 phase：失败阶段不再误标 extracting（关键词提取）
    expect(ctx.failedPhase, IntermediatePhase.generating);
    expect(ctx.errorCategory, ErrorCategory.config);
    // 报点级建议覆盖指向导演设置具体入口
    expect(ctx.suggestionOverride, t.advanced.failure.gmMissing);
  });

  test('草稿会话 GM 未配置 → E010 保留输入（气泡可重放，不蒸发）', () async {
    final script = <String>[];
    final gm = _ToggleGmResolver();
    final controller = buildController(
      script,
      resolver: gm,
      sessionId: '${AdvancedChatController.draftSessionIdPrefix}new-user',
    );

    await controller.sendMessage('开启我的故事');

    expect(controller.state.phase, IntermediatePhase.failed);
    expect(controller.state.failureContext?.errorCode, 'E010');
    // 输入保留：气泡与失败栏「整轮重试」的数据基础
    expect(controller.state.userInput, '开启我的故事');
    expect(controller.state.pendingUserMessage?.content, '开启我的故事');
    final sessionId = controller.state.session.sessionId;
    final repo = ChatRepositoryImpl(database: db);
    // 编辑框收到清空事件或失焦时，失败气泡仍拥有已提交的首句。
    await controller.persistInputDraft(null);
    expect((await repo.getDirectorInputs(sessionId)).pending, '开启我的故事');

    // 补齐配置后从失败栏重试：同一份输入可重放（走正常轮链）
    gm.gmConfigured = true;
    script.addAll([
      finishRoundStep('call_d1', '雨夜，城门开了。'),
      finishRoundExemption('call_d1b', '雨夜，城门开了。'),
    ]);
    await controller.retryPendingUserMessage();
    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.state.pendingUserMessage, isNull);
    expect((await repo.getDirectorInputs(sessionId)).pending, isNull);
  });

  test('首句写入失败时拒绝消费，重发只留下一个会话', () async {
    final draft = buildController(
      const [],
      resolver: _GmMissingResolver(),
      sessionId: '${AdvancedChatController.draftSessionIdPrefix}write-failure',
    );
    addTearDown(draft.dispose);
    final repo = ChatRepositoryImpl(database: db);
    const input = '故障后的同一句';
    await db.customStatement('''
      CREATE TRIGGER fail_first_input
      BEFORE UPDATE OF director_pending_input ON chat_sessions
      WHEN NEW.director_pending_input IS NOT NULL
      BEGIN
        SELECT RAISE(ABORT, 'synthetic draft failure');
      END
    ''');

    expect(await draft.sendMessage(input), isFalse);
    expect(draft.isDraftSession, isTrue);
    expect(draft.state.pendingUserMessage, isNull);
    expect((await repo.getHomeSessions()).recent, isEmpty);
    await db.customStatement('DROP TRIGGER fail_first_input');

    expect(await draft.sendMessage(input), isTrue);
    final session = (await repo.getHomeSessions()).recent.single;
    expect(session.sessionId, draft.state.session.sessionId);
    expect((await repo.getDirectorInputs(session.sessionId)).pending, input);
  });

  test('未配置主模型的首句从最近会话恢复并只收稿一次', () async {
    final directory = await Directory.systemTemp.createTemp('director-input-');
    databaseDirectory = directory;
    final file = File('${directory.path}/director.sqlite');
    await db.close();
    db = AppDatabase.forTesting(NativeDatabase(file));
    const input = '潮汐退去，渡船停着。\n守夜人推开了窗！';
    const prose = '一束微光从潮湿的石阶下透了出来。';

    final draft = buildController(
      const [],
      resolver: _GmMissingResolver(),
      sessionId: '${AdvancedChatController.draftSessionIdPrefix}first-input',
    );
    final initialRepo = ChatRepositoryImpl(database: db);
    expect((await initialRepo.getHomeSessions()).recent, isEmpty);
    expect(await draft.sendMessage(input), isTrue);
    expect(draft.state.failureContext?.errorCode, 'E010');
    expect(hangClient.callCount, 0);
    final originalSessionId = draft.state.session.sessionId;
    draft.dispose();
    await db.close();

    db = AppDatabase.forTesting(NativeDatabase(file));
    final repo = ChatRepositoryImpl(database: db);
    final recent = (await repo.getHomeSessions()).recent;
    expect(recent, hasLength(1));
    final recovered = recent.single;
    expect(recovered.sessionId, originalSessionId);
    expect(recovered.lastMessagePreview, isNull);
    expect((await repo.getDirectorInputs(originalSessionId)).pending, input);
    expect(await repo.getMessages(originalSessionId), isEmpty);

    final bodies = <String>[];
    final gm = _ToggleGmResolver()..gmConfigured = true;
    final controller = buildController(
      [
        finishRoundStep('finish-first', prose),
        finishRoundExemption('finish-again', prose),
      ],
      resolver: gm,
      restoredSession: recovered,
      bodyLog: bodies,
    );
    addTearDown(controller.dispose);
    await controller.loadHistory();
    expect(controller.state.pendingUserMessage?.content, input);
    await controller.continueFromFailed();
    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.state.messages.map((m) => (m.role, m.content)), [
      ('user', input),
      ('assistant', prose),
    ]);
    expect((await repo.getDirectorInputs(originalSessionId)).pending, isNull);
    final messages = await repo.getMessages(originalSessionId);
    expect(messages.map((m) => (m.role, m.content)), [
      ('user', input),
      ('assistant', prose),
    ]);
    expect((await repo.getSession(originalSessionId)).nextTurn, 2);
    expect(bodies, hasLength(2));
    for (final body in bodies) {
      final request = jsonDecode(body) as Map<String, dynamic>;
      final messages =
          (request['messages'] as List<dynamic>).cast<Map<String, dynamic>>();
      final userContents = messages
          .where((message) => message['role'] == 'user')
          .map((message) => message['content'] as String)
          .join('\n');
      expect(
        RegExp(RegExp.escape(input)).allMatches(userContents),
        hasLength(1),
      );
    }
  });

  testWidgets('导演快速切会话时未读的首句和主动修改的草稿各归原会话', (tester) async {
    const first = '灯照过石桥，河面轻响。\n风停了。';
    const draft = '另一会话自己的草稿';
    const edited = '改过的未发送文字';
    final repo = ChatRepositoryImpl(database: db);
    final initial = buildController(
      const [],
      resolver: _GmMissingResolver(),
      sessionId: '${AdvancedChatController.draftSessionIdPrefix}navigation',
    );
    expect(await initial.sendMessage(first), isTrue);
    final sessionA = initial.state.session;
    initial.dispose();
    final settingsB = buildController(
      const [],
      sessionId: '${AdvancedChatController.draftSessionIdPrefix}settings',
    );
    expect(
      await settingsB.updateSession(
        settingsB.state.session.copyWith(title: '导演乙'),
      ),
      isTrue,
    );
    final sessionB = settingsB.state.session;
    await settingsB.persistInputDraft(draft);
    settingsB.dispose();
    final recent = (await repo.getHomeSessions()).recent;
    expect(
      recent.map((session) => session.sessionId),
      containsAll([sessionA.sessionId, sessionB.sessionId]),
    );
    expect(
      recent.map((session) => session.lastMessagePreview),
      everyElement(isNull),
    );
    final delayed = _DelayedComposerDraftRepository(
      database: db,
      delayedSessionId: sessionA.sessionId,
    );
    final a = buildController(
      const [],
      restoredSession: sessionA,
      chatRepository: delayed,
    );
    final b = buildController(
      const [],
      restoredSession: sessionB,
      chatRepository: delayed,
    );
    await Future.wait([a.loadHistory(), b.loadHistory()]);
    final current = ValueNotifier(sessionA);
    addTearDown(current.dispose);
    await _mountAdvancedPage(
      tester,
      delayed,
      {sessionA: a, sessionB: b},
      current,
    );
    expect(delayed.readStarted.isCompleted, isTrue);
    current.value = sessionB;
    await tester.pumpAndSettle();
    expect(find.text(first, findRichText: true), findsNothing);
    expect(find.text(draft), findsOneWidget);
    final writesBeforeRestore = [...delayed.writes];

    current.value = sessionA;
    await tester.pumpAndSettle();
    delayed.releaseRead.complete();
    await tester.pumpAndSettle();
    expect(writesBeforeRestore, isNot(contains((sessionA.sessionId, null))));
    expect(find.text(first, findRichText: true), findsOneWidget);
    expect(find.text(draft), findsNothing);

    current.value = sessionB;
    await tester.pumpAndSettle();
    final composer = find.byType(TextField);
    await tester.enterText(composer, edited);
    current.value = sessionA;
    await tester.pumpAndSettle();
    expect(await repo.getSessionDraft(sessionB.sessionId), edited);
    expect(find.text(edited), findsNothing);

    current.value = sessionB;
    await tester.pumpAndSettle();
    expect(find.text(edited), findsOneWidget);
    await tester.enterText(composer, '');
    current.value = sessionA;
    await tester.pumpAndSettle();
    expect(await repo.getSessionDraft(sessionB.sessionId), isNull);
    current.value = sessionB;
    await tester.pumpAndSettle();
    expect(find.text(edited), findsNothing);
    expect(find.text(first, findRichText: true), findsNothing);
  });

  for (final resend in [false, true]) {
    testWidgets(
      resend ? '首句保存并发送失败可在原编辑框重试' : '首句保存失败可在原编辑框重试',
      (tester) async {
        const original = '窗外落着旧雪。';
        const revised = '窗外落着新雪。\n门内一盏灯。';
        final controller = buildController(
          const [],
          resolver: _GmMissingResolver(),
          sessionId: '${AdvancedChatController.draftSessionIdPrefix}edit',
        );
        expect(await controller.sendMessage(original), isTrue);
        await _pumpAdvancedPage(tester, db, controller);
        await db.customStatement(
          'CREATE TRIGGER reject_first_edit BEFORE UPDATE ON chat_sessions '
          "BEGIN SELECT RAISE(ABORT, 'synthetic edit failure'); END",
        );
        await tester.tap(find.text(original, findRichText: true));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byTooltip(t.intermediate.chat.messageActions.edit),
        );
        await tester.pumpAndSettle();
        final field = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        );
        await tester.enterText(field, revised);
        await tester.pumpAndSettle();
        final label = resend
            ? t.intermediate.chat.messageActions.saveAndResend
            : t.intermediate.chat.messageActions.save;
        final action = find.widgetWithText(
          resend ? ElevatedButton : TextButton,
          label,
        );
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(field, findsOneWidget);
        expect(tester.widget<TextField>(field).controller?.text, revised);
        expect(controller.state.pendingUserMessage?.content, original);
        expect(controller.state.userInput, original);
        expect(hangClient.callCount, 0);
        final id = controller.state.session.sessionId;
        final repo = ChatRepositoryImpl(database: db);
        expect((await repo.getDirectorInputs(id)).pending, original);
        expect(find.text(t.advanced.failure.inputSaveFailed), findsOneWidget);

        await db.customStatement('DROP TRIGGER reject_first_edit');
        await tester.tap(action);
        await tester.pumpAndSettle();
        expect(field, findsNothing);
        expect(controller.state.pendingUserMessage?.content, revised);
        expect(controller.state.userInput, revised);
        expect((await repo.getDirectorInputs(id)).pending, revised);
        expect(controller.state.failureContext?.errorCode, 'E010');
      },
    );
  }

  test('草稿物化：初始化角色两列随草稿落库；卡路径物化时应用一次', () async {
    // 向导「初始化你的角色」产物随草稿带到首条消息物化：
    // 描述列留档（供第 1 轮尾部一次性注入读取），卡在拿到真实
    // sessionId 后走资料通道应用。
    final appliedCards = <String>[];
    final controller = buildController(
      [
        finishRoundStep('call_ci1', '林九推开酒馆的门。'),
        finishRoundExemption('call_ci1b', '林九推开酒馆的门。'),
      ],
      sessionId: '${AdvancedChatController.draftSessionIdPrefix}ci-user',
      characterInitPrompt: '林九，男，落魄刀客',
      characterInitCardId: 'card-1',
      resourceApplyService: _RecordingApplyService(appliedCards),
    );

    await controller.sendMessage('开始');

    expect(controller.state.phase, IntermediatePhase.idle);
    expect(appliedCards, ['card-1'], reason: '卡应用恰一次（物化后）');
    // 两列随草稿快照落库，重读仍在
    final persisted = await ChatRepositoryImpl(database: db)
        .getSession(controller.state.session.sessionId);
    expect(persisted.characterInitPrompt, '林九，男，落魄刀客');
    expect(persisted.characterInitCardId, 'card-1');
  });

  test('mode=advanced：推理烧完输出预算（length 截断空正文）→ failed 带诊断', () async {
    final controller = buildController([
      // 流式只有 finish_reason=length（无 content，推理耗尽预算）→ 直接诊断停止
      sse([finish('length'), '[DONE]']),
    ]);

    await controller.sendMessage('推进剧情');

    expect(controller.state.phase, IntermediatePhase.failed);
    expect(controller.state.failureContext?.errorCode, 'EAGENT');
    expect(controller.state.failureContext?.retryable, isTrue);
    expect(
      controller.state.failureContext?.errorMessage,
      contains('finish_reason=length'),
    );
    expect(
      controller.state.failureContext?.rawError,
      contains('输出上限'),
    );
  });

  test('mode=advanced：D5 修复——会话 maxDurationMinutes 优先于全局时间预算', () async {
    // 会话列 0 分钟 → 首步前时间预算即耗尽（修复前只读全局 5 分钟，
    // 会话面板的「单轮时间预算」写入后被静默忽略）
    final controller = buildController(
      [
        finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
        finishRoundExemption('call_f1b', '夜色沉下来，苏明远推开荒庙的门。'),
      ],
      maxDurationMinutes: 0,
    );

    await controller.sendMessage('苏明远进入荒庙');

    expect(controller.state.phase, IntermediatePhase.failed);
    expect(controller.state.failureContext?.errorCode, 'EAGENT');
    // budgetDuration 的 i18n 文案（时间预算耗尽映射为「本轮超时」）
    expect(
      controller.state.failureContext?.errorMessage,
      contains('本轮超时'),
    );
  });

  test('mode=advanced：失败后 continueFromFailed 重跑 agent loop（不再误入六步管线）',
      () async {
    // maxSteps=1 → 首步检索工具后即达上限：软着陆（工具停用）后模型仍调
    // 工具 → 停用信封 → 二次耗尽失败。注意 0 现在表示「无上限」（对齐
    // AgentBudget 约定），不能再当作零预算触发失败路径。
    final controller = buildController(
      [
        // 首轮步骤 1：预算未到，检索工具正常执行
        sse([
          toolCallStart(0, 'call_x1', 'search_story', '{"query":"古碑"}'),
          finish('tool_calls'),
          '[DONE]',
        ]),
        // 首轮步骤 2：软着陆通牒后模型仍调工具 → 停用信封 → 二次耗尽失败
        sse([
          toolCallStart(0, 'call_x2', 'search_story', '{"query":"月光"}'),
          finish('tool_calls'),
          '[DONE]',
        ]),
        // continueFromFailed 后的一次成功 agent 步：正文经 prose 参数交付
        finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
        finishRoundExemption('call_f1b', '夜色沉下来，苏明远推开荒庙的门。'),
      ],
      maxSteps: 1,
    );

    await controller.sendMessage('苏明远进入荒庙');

    // 首轮失败：agent loop 以 generating 阶段失败，保留 _round
    expect(controller.state.phase, IntermediatePhase.failed);
    expect(controller.state.failureContext?.errorCode, 'EAGENT');
    expect(
      controller.state.failureContext?.failedPhase,
      IntermediatePhase.generating,
    );

    // 用户调大每轮步数后，从中断处重试（此前会误入故事模式 _runGeneratePhase）
    await controller.updateSession(
      controller.state.session.copyWith(maxSteps: 8),
    );
    await controller.continueFromFailed();

    // 重跑的是 agent loop：finish_round 工具步骤已随 artifacts 持久化
    // （故事模式六步管线不产生 agentSteps，可据此区分内核）
    expect(controller.state.phase, IntermediatePhase.idle);
    final artifacts = controller.state.artifactsByTurnNumber?[1];
    expect(artifacts, isNotNull);
    expect(artifacts!.agentSteps, isNotEmpty);
    expect(artifacts.agentSteps.first.toolName, 'finish_round');

    final messages = await db.customSelect(
      'SELECT role, content FROM chat_messages WHERE session_id = ? '
      'ORDER BY created_at ASC',
      variables: [Variable.withString('dir-test-1')],
    ).get();
    expect(messages, hasLength(2));
    expect(messages.last.read<String>('content'), contains('夜色沉下来'));
  });

  // 失败续跑（真续跑）：上次尝试的事件是唯一真实历史，不再删除重写——
  // 双计防线=不重发已完成请求 + 不重写 bootstrap + 步号续起（旧「删除
  // 上一尝试」契约服务于重放式重跑，真续跑不重放，保留才准确）。
  test('mode=advanced：失败真续跑——不重发已完成请求，事件不双计', () async {
    final bodies = <String>[];
    final controller = buildController(
      [
        // 首轮步骤 1：检索工具正常执行
        sse([
          toolCallStart(0, 'call_x1', 'search_story', '{"query":"古碑"}'),
          finish('tool_calls'),
          '[DONE]',
        ]),
        // 首轮步骤 2：软着陆后仍调工具 → 停用信封 → 二次耗尽失败
        sse([
          toolCallStart(0, 'call_x2', 'search_story', '{"query":"月光"}'),
          finish('tool_calls'),
          '[DONE]',
        ]),
        // 续跑成功步（finish_round 首被事件记忆闸门拒 → 豁免重提）
        finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
        finishRoundExemption('call_f1b', '夜色沉下来，苏明远推开荒庙的门。'),
      ],
      maxSteps: 1,
      withEventLog: true,
      bodyLog: bodies,
    );

    await controller.sendMessage('苏明远进入荒庙');
    expect(controller.state.phase, IntermediatePhase.failed);

    // 步数预算含前序尝试（种子 2 步已烧）：调大上限后续跑
    await controller.updateSession(
      controller.state.session.copyWith(maxSteps: 8),
    );
    await controller.continueFromFailed();
    expect(controller.state.phase, IntermediatePhase.idle);

    // 不重发证明：全程恰 4 次 LLM 请求（上次 2 + 续跑 2），已完成的
    // 检索步不重烧；续跑首请求体含上次尝试的 search_story 调用
    // （surface 投影回放，非重新装配）
    expect(hangClient.callCount, 4);
    expect(bodies, hasLength(4));
    expect(bodies[2], contains('search_story'));
    expect(bodies[2], contains('古碑'));

    final events = await AgentEventLogRepository(
      database: db,
    ).readEvents('dir-test-1');

    // 事件不双计：两段各一次 turn/begin（续跑段带 resumed 标记）
    final turnBegins =
        events.where((e) => e.type == AgentEventTypes.turnBegin).toList();
    expect(turnBegins, hasLength(2));
    expect(turnBegins.last.data['resumed'], isTrue);
    // bootstrap 单份：真实用户消息只落一次（续跑不重写补账）
    final userMessages = events.where(
      (e) =>
          e.type == AgentEventTypes.userMessage && e.data['source'] == 'user',
    );
    expect(userMessages, hasLength(1));
    // 步号跨尝试连续无重叠：1,2（上次）→ 3,4（续跑；stepEnd 为后置
    // 递增的 1 基序号，续跑种子 2 使其从 3 续起）
    final stepEnds = events
        .where((e) => e.type == AgentEventTypes.stepEnd)
        .map((e) => e.data['stepIndex'])
        .toList();
    expect(stepEnds, [1, 2, 3, 4]);
    // 聚合口径：统计=两段真实消耗之和（4 步），无重复计数
    final stats = agentSessionStatsFrom(events);
    expect(stats.stepsByTurn[1], 4);
  });

  // 开启态失败续跑：出站=账本纪元投影（同源 stepSurfaceSource），
  // 不因 resume 绕回 working-only；补账不重写（u_k 单份）。
  test('开启态失败续跑：出站含前序轨迹与冻结前缀，投影源生效', () async {
    final bodies = <String>[];
    final controller = buildController(
      [
        sse([
          toolCallStart(0, 'call_x1', 'search_story', '{"query":"古碑"}'),
          finish('tool_calls'),
          '[DONE]',
        ]),
        sse([
          toolCallStart(0, 'call_x2', 'search_story', '{"query":"月光"}'),
          finish('tool_calls'),
          '[DONE]',
        ]),
        finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
        finishRoundExemption('call_f1b', '夜色沉下来，苏明远推开荒庙的门。'),
      ],
      maxSteps: 1,
      withEventLog: true,
      withEngineeringSwitch: true,
      bodyLog: bodies,
    );
    for (var i = 0; i < 500 && controller.state.loadingHistory; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // 模式切换回填读取会话行：harness 会话默认只存在于内存，先落库
    await db.into(db.chatSessionsTable).insert(
          ChatSessionsTableCompanion.insert(
            sessionId: 'dir-test-1',
            title: '测试导演',
            mode: const Value('advanced'),
            maxSteps: const Value(1),
          ),
        );
    final switched = await controller.setEngineeringContextEnabled(
      enabled: true,
    );
    expect(switched, isTrue);
    expect(
      controller.state.engineeringMode,
      EngineeringRuntimeMode.normalOpen,
    );
    // 种一条关键实体（importance≥阈值5），使开启态快照（coreBlocks）
    // 真实非空——快照不可变顺序断言才有被试对象
    await FactualRepositoryImpl(database: db).createEntity(
      FactualEntity(
        entityId: 'ent-temple',
        sessionId: 'dir-test-1',
        type: FactualEntityType.location,
        primaryName: '荒庙',
        aliases: const [],
        importance: 5,
        createdTurn: 0,
        createdAt: DateTime(2026),
      ),
    );

    await controller.sendMessage('苏明远进入荒庙');
    expect(controller.state.phase, IntermediatePhase.failed);

    // 开启态轮首固定顺序：u_k → 世界事实快照 → 指令面（工作契约）。
    // 快照为不可变注入面（绝对标注全量快照，按轮标注）
    expect(bodies, isNotEmpty);
    final firstBody = bodies.first;
    final ukAt = firstBody.indexOf('苏明远进入荒庙');
    final snapshotAt = firstBody.indexOf('〔世界事实快照·第1轮〕');
    final contractAt = firstBody.indexOf('【工作契约】');
    expect(ukAt, greaterThanOrEqualTo(0), reason: 'u_k 在出站面');
    expect(snapshotAt, greaterThan(ukAt), reason: '快照在 u_k 之后');
    expect(contractAt, greaterThan(snapshotAt), reason: '指令面在快照之后');

    await controller.updateSession(
      controller.state.session.copyWith(maxSteps: 8),
    );
    await controller.continueFromFailed();
    expect(controller.state.phase, IntermediatePhase.idle);

    // 续跑首请求体 = 账本纪元投影：冻结前缀（含新模式工作约定）+
    // 上次尝试的检索轨迹原样在场
    expect(bodies.length, greaterThanOrEqualTo(3));
    expect(bodies[2], contains('search_story'));
    expect(bodies[2], contains('古碑'));
    expect(bodies[2], contains('【历史工作与状态】'));

    // 账本不变量：开启态 u_k 单份（续跑不重写补账）、两次 turn/begin
    final events = await AgentEventLogRepository(
      database: db,
    ).readEvents('dir-test-1');
    final userMessages = events.where(
      (e) =>
          e.type == AgentEventTypes.userMessage && e.data['source'] == 'user',
    );
    expect(userMessages, hasLength(1));
    final turnBegins =
        events.where((e) => e.type == AgentEventTypes.turnBegin).toList();
    expect(turnBegins, hasLength(2));
    expect(turnBegins.last.data['resumed'], isTrue);
  });

  test('开启工程上下文后重生成旧轮，发送保留历史与本轮工具结果', () async {
    final bodies = <String>[];
    const retainedProse = '留下的正文：守卫打开城门。';
    const targetInput = '改写山洞这一轮';
    const oldProse = '待替换的旧稿：巨龙飞过山洞。';
    const downstreamProse = '被回退的后续：巨龙飞向海边。';
    const newProse = '新稿：山洞里只有一盏灯。';
    final controller = buildController(
      [
        sse([textDelta(retainedProse), finish('stop'), '[DONE]']),
        sse([textDelta(oldProse), finish('stop'), '[DONE]']),
        sse([textDelta(downstreamProse), finish('stop'), '[DONE]']),
        sse([
          toolCallStart(0, 'lookup', 'search_story', '{"query":"城门"}'),
          finish('tool_calls'),
          '[DONE]',
        ]),
        sse([textDelta(newProse), finish('stop'), '[DONE]']),
      ],
      withEventLog: true,
      withEngineeringSwitch: true,
      bodyLog: bodies,
    );
    addTearDown(controller.dispose);
    expect(await until(() => !controller.state.loadingHistory), isTrue);
    await db.into(db.chatSessionsTable).insert(
          ChatSessionsTableCompanion.insert(
            sessionId: 'dir-test-1',
            title: '测试导演',
            mode: const Value('advanced'),
          ),
        );
    await controller.sendMessage('打开城门');
    await controller.sendMessage(targetInput);
    await controller.sendMessage('继续写巨龙');
    expect(controller.state.messages, hasLength(6));
    expect(
      await controller.setEngineeringContextEnabled(enabled: true),
      isTrue,
    );

    final target = controller.state.messages.singleWhere(
      (message) => message.content == oldProse,
    );
    final log = AgentEventLogRepository(database: db);
    final chatRepository = ChatRepositoryImpl(database: db);
    final originalEvents = await log.readEvents('dir-test-1');
    await db.customStatement(
      'CREATE TRIGGER fail_mode_capture BEFORE INSERT ON agent_events '
      "WHEN NEW.type = 'mode/capture' "
      "BEGIN SELECT RAISE(ABORT, 'synthetic capture failure'); END",
    );
    await controller.regenerateMessage(target);
    expect(bodies, hasLength(3));
    expect(controller.state.isPreparingRegenerate, isFalse);
    final originalMessages = await chatRepository.getMessages('dir-test-1');
    expect(
      originalMessages.map((message) => message.content),
      containsAll([
        retainedProse,
        oldProse,
        downstreamProse,
      ]),
    );
    expect(
      (await log.readEvents('dir-test-1')).map((event) => event.data),
      originalEvents.map((event) => event.data),
    );
    await db.customStatement('DROP TRIGGER fail_mode_capture');

    await controller.regenerateMessage(target);

    expect(controller.state.failureContext?.rawError, isNull);
    expect(controller.state.phase, IntermediatePhase.idle);
    expect(bodies, hasLength(5));
    final firstBody = jsonDecode(bodies[3]) as Map<String, dynamic>;
    final messages =
        (firstBody['messages'] as List<dynamic>).cast<Map<String, dynamic>>();
    expect(
      messages.map((message) => message['content']),
      contains(retainedProse),
    );
    expect(
      messages.where((message) => message['content'] == targetInput),
      hasLength(1),
    );
    expect(bodies[3], isNot(contains(oldProse)));
    expect(bodies[3], isNot(contains(downstreamProse)));
    final secondBody = jsonDecode(bodies[4]) as Map<String, dynamic>;
    final nextMessages =
        (secondBody['messages'] as List<dynamic>).cast<Map<String, dynamic>>();
    expect(
      nextMessages
          .where((message) => message['role'] == 'tool')
          .single['tool_call_id'],
      'lookup',
    );
    expect(controller.state.messages.last.content, newProse);
    expect(controller.state.variantsByTurn?[2], hasLength(2));
    final session = await chatRepository.getSession('dir-test-1');
    expect(
      resolveEngineeringMode(
        enabled: session.engineeringContextEnabled,
        events: await log.readEvents('dir-test-1'),
      ).mode,
      EngineeringRuntimeMode.normalOpen,
    );
  });

  test('修复缺纪元的会话后，重开并重跑失败轮仍保留已捕获历史', () async {
    const savedProse = '已经保存的历史：城门关闭了。';
    const newInput = '问问守卫发生了什么';
    const newProse = '守卫说风暴快到了。';
    const sessionId = 'dir-test-1';
    final initial = buildController(
      [
        sse([textDelta(savedProse), finish('stop'), '[DONE]']),
        sse([finish('length'), '[DONE]']),
      ],
      withEventLog: true,
    );
    addTearDown(initial.dispose);
    expect(await until(() => !initial.state.loadingHistory), isTrue);
    await db.into(db.chatSessionsTable).insert(
          ChatSessionsTableCompanion.insert(
            sessionId: sessionId,
            title: '测试导演',
            mode: const Value('advanced'),
          ),
        );
    await initial.sendMessage('写下城门的场景');
    await initial.sendMessage('这次生成失败');
    expect(
      initial.state.failureContext?.errorMessage,
      contains('finish_reason=length'),
    );

    // 模拟旧版本留下的会话列与账本不一致，保留同轮失败留下的事件。
    await db.customStatement(
      'UPDATE chat_sessions SET engineering_context_enabled = 1 WHERE session_id = ?',
      [sessionId],
    );
    final chatRepository = ChatRepositoryImpl(database: db);
    final repair = buildController(
      const [],
      withEventLog: true,
      withEngineeringSwitch: true,
      restoredSession: await chatRepository.getSession(sessionId),
    );
    addTearDown(repair.dispose);
    expect(await until(() => !repair.state.loadingHistory), isTrue);
    expect(
      repair.state.engineeringMode,
      EngineeringRuntimeMode.recoveryRequired,
    );
    expect(await repair.setEngineeringContextEnabled(enabled: true), isTrue);

    final bodies = <String>[];
    final reopened = buildController(
      [
        sse([
          toolCallStart(
            0,
            'second_turn_lookup',
            'search_story',
            '{"query":"城门"}',
          ),
          finish('tool_calls'),
          '[DONE]',
        ]),
        sse([textDelta(newProse), finish('stop'), '[DONE]']),
      ],
      withEventLog: true,
      withEngineeringSwitch: true,
      bodyLog: bodies,
      restoredSession: await chatRepository.getSession(sessionId),
    );
    addTearDown(reopened.dispose);
    expect(await until(() => !reopened.state.loadingHistory), isTrue);
    final log = AgentEventLogRepository(database: db);
    expect(
      DirectorSurfaceV2.epochWindowProjection(await log.readEvents(sessionId))
          .messages
          .map((message) => message.content),
      contains(savedProse),
    );

    await reopened.sendMessage(newInput);

    expect(reopened.state.failureContext?.rawError, isNull);
    expect(reopened.state.phase, IntermediatePhase.idle);
    expect(bodies, hasLength(2));
    expect(bodies.first, contains(savedProse));
    expect(bodies.first, contains(newInput));
    expect(bodies.first, isNot(contains('这次生成失败')));
    expect(bodies.last, contains('"tool_call_id":"second_turn_lookup"'));
    final persisted = await chatRepository.getMessages(sessionId);
    expect(persisted.last.content, newProse);
  });

  // 组合回归：检索 → calc（eval/date）→ finish_round 在工程开启态
  // 全链走通（真实控制器+桩网关，calc 与检索工具同源装配并回执入账）。
  test('开启态组合：检索 → calc_eval/calc_date → finish_round 全链', () async {
    final bodies = <String>[];
    final controller = buildController(
      [
        sse([
          toolCallStart(0, 'call_r1', 'search_story', '{"query":"古碑"}'),
          finish('tool_calls'),
          '[DONE]',
        ]),
        sse([
          toolCallStart(
            0,
            'call_c1',
            'calc_eval',
            '{"expression":"0.1 + 0.2"}',
          ),
          finish('tool_calls'),
          '[DONE]',
        ]),
        sse([
          toolCallStart(
            0,
            'call_c2',
            'calc_date',
            '{"date":"2026-01-31","add":"1mo"}',
          ),
          finish('tool_calls'),
          '[DONE]',
        ]),
        finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
        finishRoundExemption('call_f1b', '夜色沉下来，苏明远推开荒庙的门。'),
      ],
      withEventLog: true,
      withEngineeringSwitch: true,
      bodyLog: bodies,
    );
    for (var i = 0; i < 500 && controller.state.loadingHistory; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await db.into(db.chatSessionsTable).insert(
          ChatSessionsTableCompanion.insert(
            sessionId: 'dir-test-1',
            title: '测试导演',
            mode: const Value('advanced'),
          ),
        );
    expect(
      await controller.setEngineeringContextEnabled(enabled: true),
      isTrue,
    );

    await controller.sendMessage('苏明远进入荒庙');
    expect(controller.state.phase, IntermediatePhase.idle);

    // 首请求工具目录：calc 两工具与检索工具同源装配（同一 buildAgentTools）
    expect(bodies.first, contains('"calc_eval"'));
    expect(bodies.first, contains('"calc_date"'));

    // calc 回执进入后续出站面：精确分数与月末钳制日期原样在场
    final joined = bodies.skip(1).join('\n');
    expect(joined, contains('3/10'));
    expect(joined, contains('2026-02-28T00:00:00Z'));

    // 账本：calc 工具结果事件成对落账（toolName/output），非 isError
    final events = await AgentEventLogRepository(
      database: db,
    ).readEvents('dir-test-1');
    final calcResults = events
        .where(
          (e) =>
              e.type == AgentEventTypes.toolResult &&
              (e.data['toolName'] as String?) != null &&
              (e.data['toolName'] as String).startsWith('calc_'),
        )
        .toList();
    expect(calcResults, hasLength(2));
    final evalResult = calcResults.firstWhere(
      (e) => e.data['toolName'] == 'calc_eval',
    );
    expect(evalResult.data['isError'], isNot(true));
    expect(evalResult.data['output'], contains('3/10'));
    final dateResult = calcResults.firstWhere(
      (e) => e.data['toolName'] == 'calc_date',
    );
    expect(dateResult.data['isError'], isNot(true));
    expect(dateResult.data['output'], contains('2026-02-28'));

    // 正文唯一成果照常落库
    final messages = await db.customSelect(
      'SELECT role, content FROM chat_messages WHERE session_id = ? '
      'ORDER BY created_at ASC',
      variables: [Variable.withString('dir-test-1')],
    ).get();
    expect(messages, hasLength(2));
    expect(messages.last.read<String>('content'), contains('夜色沉下来'));

    // 工具集变化沿冻结前缀政策留痕：本轮捕获的 system/frozen 事件
    // 已含 calc 工具索引行（旧前缀事件不被改写，新值由追加事件承载）
    final frozenEvents =
        events.where((e) => e.type == AgentEventTypes.systemFrozen).toList();
    expect(frozenEvents, isNotEmpty);
    expect(frozenEvents.last.data['content'], contains('calc_eval'));
    expect(frozenEvents.last.data['content'], contains('calc_date'));
  });

  // 差分反例：25000+1000=26000 且 persist 不再加；
  // 无锚点 unknown；构成图包含本轮工具/正文轨迹。
  test('开启态材料差分闭合：锚点+真实表面差分，persist 不再二次加 reply', () async {
    final bodies = <String>[];
    String withUsage(String body) => body.replaceFirst(
          'data: [DONE]',
          'data: ${jsonEncode({
                'choices': <dynamic>[],
                'usage': {
                  'prompt_tokens': 25000,
                  'completion_tokens': 10,
                  'total_tokens': 25010,
                },
              })}\n\n'
              'data: [DONE]',
        );
    final controller = buildController(
      [
        withUsage(finishRoundStep('call_m1', '夜色沉下来。')),
        withUsage(finishRoundExemption('call_m2', '夜色沉下来。')),
      ],
      maxSteps: 8,
      withEventLog: true,
      withEngineeringSwitch: true,
      bodyLog: bodies,
    );
    for (var i = 0; i < 500 && controller.state.loadingHistory; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await db.into(db.chatSessionsTable).insert(
          ChatSessionsTableCompanion.insert(
            sessionId: 'dir-test-1',
            title: '测试导演',
            mode: const Value('advanced'),
            maxSteps: const Value(8),
          ),
        );
    final switched = await controller.setEngineeringContextEnabled(
      enabled: true,
    );
    expect(switched, isTrue);

    await controller.sendMessage('苏明远进入荒庙');
    expect(controller.state.phase, IntermediatePhase.idle);

    // 锚点 = 可靠实报配对（末次请求 usage ↔ 该次出站面，两步都回
    // usage → 末步配对）；差分 = 持久化后最终投影相对锚点表面的字符
    // 增量，口径=wire-map（与适配器出站面同源）——首轮：末步 assistant
    // 调用消息 + finish 回执两条新消息。persist 的 reply shift 已在
    // 开启态退役——重复并入会使数值偏高。
    const prose = '夜色沉下来。';
    final wire = AgentWireOptions.forProtocolName('openaiCompatible');
    final assistantWire = jsonEncode(
      AgentMessage.assistant(
        text: '',
        toolCalls: [
          const AgentToolCall(
            id: 'call_m2',
            name: 'finish_round',
            arguments: {'prose': prose},
          ),
        ],
      ).toRequestMap(wire),
    ).length;
    final receiptWire = jsonEncode(
      AgentMessage.toolResult(
        toolCallId: 'call_m2',
        content: '本轮已完成提交。回复正文：$prose',
      ).toRequestMap(wire),
    ).length;
    final expected = 25000 + (assistantWire + receiptWire) ~/ 4;
    final estimate = controller.state.contextEstimate;
    expect(
      estimate?.tokens,
      expected,
      reason: '锚点(25000)+真实表面差分；persist 不再二次加 reply',
    );
    expect(estimate?.isEstimated, isTrue, reason: '预计标 ≈');

    // 构成图按最终投影闭合：本轮工具轨迹+正文入 history，u_k/指令面
    // 入 directive，冻结前缀入 system
    final chars = controller.state.contextSegmentChars;
    expect(chars, isNotNull);
    expect(chars!['system'], greaterThan(0));
    expect(chars['history'], greaterThan(0), reason: '含本轮调用签名+回执');
    expect(chars['directive'], greaterThan(0), reason: '含本轮 u_k+尾部指令');
  });

  test('开启态无锚点（端点未回 usage）→ unknown（「—」不冒充数值）', () async {
    final controller = buildController(
      [
        finishRoundStep('call_n1', '夜色沉下来。'),
        finishRoundExemption('call_n2', '夜色沉下来。'),
      ],
      maxSteps: 8,
      withEventLog: true,
      withEngineeringSwitch: true,
    );
    for (var i = 0; i < 500 && controller.state.loadingHistory; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await db.into(db.chatSessionsTable).insert(
          ChatSessionsTableCompanion.insert(
            sessionId: 'dir-test-1',
            title: '测试导演',
            mode: const Value('advanced'),
            maxSteps: const Value(8),
          ),
        );
    await controller.setEngineeringContextEnabled(enabled: true);
    await controller.sendMessage('苏明远进入荒庙');
    expect(controller.state.phase, IntermediatePhase.idle);
    final estimate = controller.state.contextEstimate;
    expect(estimate?.tokens, isNull, reason: '无实报锚点不得用估算冒充');
    expect(estimate?.hasData, isFalse);
  });

  test('mode=advanced：E104 临时降级 → 真续跑不重烧已完成的检索步', () async {
    final bodies = <String>[];
    final controller = buildController(
      [
        sse([
          toolCallStart(0, 'call_s1', 'search_story', '{"query":"古碑"}'),
          finish('tool_calls'),
          '[DONE]',
        ]),
        finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
        finishRoundExemption('call_f1b', '夜色沉下来，苏明远推开荒庙的门。'),
      ],
      resolver: _EmbeddingFailResolver(),
      withEventLog: true,
      bodyLog: bodies,
    );

    await controller.sendMessage('推进剧情');
    expect(controller.state.phase, IntermediatePhase.failed);
    expect(controller.state.failureContext?.errorCode, 'E104');
    final callsAtFailure = hangClient.callCount;

    await controller.continueWithFts5Only();
    expect(controller.state.phase, IntermediatePhase.idle);

    // 真续跑：续跑段只发 2 个请求（finish_round + 豁免重提），上次已完成的
    // 检索步不重烧；致命步骤由占位结果配对后模型直接执笔
    expect(callsAtFailure, 1);
    expect(hangClient.callCount, callsAtFailure + 2);
    expect(bodies.last, contains('search_story'), reason: '续跑请求体复用上次已完成的检索步骤');
    final events = await AgentEventLogRepository(
      database: db,
    ).readEvents('dir-test-1');
    expect(
      events
          .where((e) => e.type == AgentEventTypes.turnBegin)
          .last
          .data['resumed'],
      isTrue,
    );
  });

  test('mode=advanced：user_stopped 半截正文 → 续跑合成进 surface 可见断句', () async {
    final bodies = <String>[];
    final controller = buildController(
      [
        finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。雾里有人影。'),
        finishRoundExemption('call_f1b', '夜色沉下来，苏明远推开荒庙的门。雾里有人影。'),
      ],
      hangAt: 0,
      withEventLog: true,
      bodyLog: bodies,
    );

    unawaited(controller.sendMessage('苏明远进入荒庙'));
    await hangClient.hangFired.future.timeout(const Duration(seconds: 20));
    expect(
      await until(
        () => controller.state.liveBlocks.any(
          (b) => b.kind == AgentLiveBlockKind.text && !b.isEmpty,
        ),
      ),
      isTrue,
    );
    await controller.cancel();
    expect(
      await until(
        () =>
            controller.state.phase == IntermediatePhase.failed &&
            !controller.state.isStopping,
      ),
      isTrue,
    );
    expect(controller.state.failureContext?.errorCode, 'user_stopped');

    // 等上一尝试的取消 unwind 完全落库（turn/end{cancelled} 与半截分片
    // 冲刷入账）再续跑——与真机时序等价（unwind 毫秒级完成，用户点击
    // 在秒级之后；不等会让续跑读到处置中的事件流）
    final unwindRepo = AgentEventLogRepository(database: db);
    var unwound = false;
    for (var i = 0; i < 500 && !unwound; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 4));
      final evs = await unwindRepo.readEvents('dir-test-1');
      unwound = evs.any(
        (e) => e.type == AgentEventTypes.turnEnd && e.data['turn'] == 1,
      );
    }
    expect(unwound, isTrue, reason: '等待取消轮完全退场（turn/end 落账）');
    // 取消终态稳定：user_stopped failed 不被防御性 idle 覆写
    expect(controller.state.phase, IntermediatePhase.failed);

    await controller.continueFromFailed();
    expect(controller.state.phase, IntermediatePhase.idle);

    // 半截正文合成 assistant/message（interrupted 标记）落日志
    final events = await unwindRepo.readEvents('dir-test-1');
    final synthesized = events.where(
      (e) =>
          e.type == AgentEventTypes.assistantMessage &&
          e.data['interrupted'] == true,
    );
    expect(synthesized, hasLength(1));
    // 续跑请求体含半截正文（模型从自己写过的断句处继续）
    expect(bodies.last, contains('夜色沉下来'));
    // 轮成功收口：消息对落库
    final messages = await db.customSelect(
      'SELECT role, content FROM chat_messages WHERE session_id = ? '
      'ORDER BY created_at ASC',
      variables: [Variable.withString('dir-test-1')],
    ).get();
    expect(messages, hasLength(2));
    expect(messages.last.read<String>('content'), contains('雾里有人影'));
  });

  test('mode=advanced：无事件日志仓库 → 续跑回退整轮重跑（现状行为等价）', () async {
    // withEventLog=false：无仓库可投影，回退旧路径（清理无门、重新装配、
    // 整轮重进 agent loop）——回退面保证与既有行为等价
    final bodies = <String>[];
    final controller = buildController(
      [
        sse([
          toolCallStart(0, 'call_x1', 'search_story', '{"query":"古碑"}'),
          finish('tool_calls'),
          '[DONE]',
        ]),
        sse([
          toolCallStart(0, 'call_x2', 'search_story', '{"query":"月光"}'),
          finish('tool_calls'),
          '[DONE]',
        ]),
        finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
        finishRoundExemption('call_f1b', '夜色沉下来，苏明远推开荒庙的门。'),
      ],
      maxSteps: 1,
      bodyLog: bodies,
    );

    await controller.sendMessage('苏明远进入荒庙');
    expect(controller.state.phase, IntermediatePhase.failed);

    await controller.updateSession(
      controller.state.session.copyWith(maxSteps: 8),
    );
    await controller.continueFromFailed();
    expect(controller.state.phase, IntermediatePhase.idle);

    // 回退=重新装配整轮重跑：续跑首请求不含上次尝试的检索调用
    // （fresh surface 只含 bootstrap 面与历史；「古碑」只存在于上次
    // 尝试的 assistant 工具调用参数里，tool 定义里没有）
    expect(bodies, hasLength(4));
    expect(bodies[2], isNot(contains('古碑')));
  });

  test('step 请求中断重试：半截直播块清空，不与重试全文拼接（契约 §7.1）', () async {
    final controller = buildController(
      [
        sse([textDelta('重试后的完整正文。'), finish('stop'), '[DONE]']),
      ],
      partialStreamErrorAt: 0,
    );

    await controller.sendMessage('推进剧情');

    expect(controller.state.phase, IntermediatePhase.idle);
    // 修复前：半截文本与重试全文拼进同一直播块 → 落库正文被污染
    final messages = await db.customSelect(
      'SELECT role, content FROM chat_messages WHERE session_id = ? '
      'ORDER BY created_at ASC',
      variables: [Variable.withString('dir-test-1')],
    ).get();
    expect(messages.last.read<String>('content'), '重试后的完整正文。');
    expect(messages.last.read<String>('content'), isNot(contains('半截')));
  });

  test('mode=advanced：durable 事件日志落库（体验重构 C1）', () async {
    final controller = buildController(
      [
        finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
        finishRoundExemption('call_f1b', '夜色沉下来，苏明远推开荒庙的门。'),
      ],
      withEventLog: true,
    );

    await controller.sendMessage('苏明远进入荒庙');

    // agent_events 表：turn/begin + turn/end 成对落库（崩溃可重放）
    final events = await db.customSelect(
      'SELECT type FROM agent_events WHERE session_id = ? ORDER BY seq ASC',
      variables: [Variable.withString('dir-test-1')],
    ).get();
    final types = events.map((row) => row.read<String>('type')).toList();
    expect(types, contains('turn/begin'));
    expect(types, contains('turn/end'));
    expect(types.indexOf('turn/begin'), lessThan(types.indexOf('turn/end')));
    // 工具结果与 assistant 消息进 surface 投影
    expect(types, contains('tool/result'));
    expect(types, contains('assistant/message'));
  });

  test('mode=advanced：editAndResend/deleteRound 清理事件日志（B4-4 补全）', () async {
    Future<int> agentEventCount() async {
      final row = await db.customSelect(
        'SELECT COUNT(*) AS c FROM agent_events WHERE session_id = ?',
        variables: [Variable.withString('dir-test-1')],
      ).getSingle();
      return row.read<int>('c');
    }

    Future<int> turnBeginCount() async {
      final row = await db.customSelect(
        'SELECT COUNT(*) AS c FROM agent_events WHERE session_id = ? '
        "AND type = 'turn/begin'",
        variables: [Variable.withString('dir-test-1')],
      ).getSingle();
      return row.read<int>('c');
    }

    final controller = buildController(
      [
        finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
        finishRoundExemption('call_f1b', '夜色沉下来，苏明远推开荒庙的门。'),
        // 编辑重发后的同轮重跑
        finishRoundStep('call_f2', '改写后的正文。'),
        finishRoundExemption('call_f2b', '改写后的正文。'),
      ],
      withEventLog: true,
    );

    await controller.sendMessage('苏明远进入荒庙');
    expect(await agentEventCount(), greaterThan(0));
    expect(await turnBeginCount(), 1);

    // 编辑重发：同轮号重跑，旧尝试的事件必须被清理（不与新的混算）
    final userMessage =
        controller.state.messages.firstWhere((m) => m.role == 'user');
    await controller.editAndResend(userMessage, '换个写法再讲一遍');
    expect(controller.state.phase, IntermediatePhase.idle);
    expect(await turnBeginCount(), 1);
    expect(await agentEventCount(), greaterThan(0));

    // 删除整轮：轮事件随之清空（：会话级 system/frozen 前缀豁免保留）
    final assistant =
        controller.state.messages.firstWhere((m) => m.role == 'assistant');
    await controller.deleteRound(assistant);
    final remainingTypes = await db.customSelect(
      'SELECT type FROM agent_events WHERE session_id = ?',
      variables: [Variable.withString('dir-test-1')],
    ).get();
    expect(
      remainingTypes.map((row) => row.read<String>('type')),
      everyElement('system/frozen'),
    );
  });

  group('导演回滚的数据库事务', () {
    late List<String> injectedFaults;
    late ChatRepositoryImpl chatRepo;
    late ExperienceRepositoryImpl experienceRepo;
    late FactualRepositoryImpl factRepo;
    late StoryPersistenceServiceImpl persistence;
    late AgentEventLogRepository eventLog;

    setUp(() async {
      // SQLite 回滚数据库写入后，测试仍能确认两处故障的触发条件确实命中。
      await db.close();
      injectedFaults = [];
      db = AppDatabase.forTesting(
        NativeDatabase.memory(
          setup: (sqlite) => sqlite.createFunction(
            functionName: 'observe_rollback_fault',
            directOnly: false,
            function: (args) {
              injectedFaults.add(args[0]! as String);
              return null;
            },
          ),
        ),
      );
      chatRepo = ChatRepositoryImpl(database: db);
      experienceRepo = ExperienceRepositoryImpl(
        database: db,
        vectorEngine: const VectorEngine(),
      );
      factRepo = FactualRepositoryImpl(database: db);
      persistence = StoryPersistenceServiceImpl(
        database: db,
        chatRepository: chatRepo,
        experienceRepository: experienceRepo,
        factApplier: FactApplier(repository: factRepo),
      );
      eventLog = AgentEventLogRepository(database: db);
    });

    String projectedFactId(String id) => '$id-worldbook';

    Future<void> seedStory(String id) async {
      final projectedFact = await factRepo.createEntity(
        FactualEntity(
          entityId: projectedFactId(id),
          sessionId: id,
          type: FactualEntityType.lore,
          primaryName: 'worldbook-fixture',
          aliases: const [],
          importance: 3,
          createdTurn: 0,
          createdAt: DateTime(2026),
          source: FactualSource.worldbook,
        ),
      );
      await factRepo.rebuildEntityFts(projectedFact.entityId);
      for (var turn = 1; turn <= 3; turn++) {
        final createdAt = DateTime(2026, 1, 1, 0, 0, turn * 2);
        final summary = EventSummary(
          importance: 4,
          tags: const [],
          turnNumber: turn,
          summary: 'memoryturn$turn',
          narrativeTime: 'storytime$turn',
        );
        await persistence.persistRound(
          userMessage: ChatMessage(
            messageId: '$id-input-$turn',
            sessionId: id,
            role: 'user',
            content: 'input-$turn',
            createdAt: createdAt,
          ),
          assistantMessage: ChatMessage(
            messageId: '$id-prose-$turn',
            sessionId: id,
            role: 'assistant',
            content: 'prose-$turn',
            createdAt: createdAt.add(const Duration(seconds: 1)),
          ),
          eventSummary: summary,
          embedding: null,
          artifacts: StoryRoundArtifacts(
            sessionId: id,
            turnNumber: turn,
            eventSummary: summary,
            storyAnchor: StoryAnchor(updatedTurn: turn, arc: 'arc-$turn'),
            createdAt: createdAt,
          ),
          factualConfig: const FactualConfig(),
          factsDeltas: [
            FactsDelta(
              action: FactAction.createEntity,
              confidence: 5,
              primaryName: 'factturn$turn',
              entityType: 'location',
              attrKey: 'description',
              value: 'description-$turn',
            ),
            if (turn == 2)
              const FactsDelta(
                action: FactAction.updateAttr,
                confidence: 5,
                primaryName: 'factturn1',
                attrKey: 'description',
                value: 'changed-at-turn-2',
                reason: 'synthetic fact update',
              ),
          ],
        );
        // 模拟旧数据为后续轮事实留下的全文索引行。
        if (turn >= 2) {
          final fact =
              (await factRepo.findByName(id, ['factturn$turn'])).single;
          await factRepo.insertFactualFts(
            entityId: fact.entityId,
            sessionId: id,
            primaryName: fact.primaryName,
            aliases: const [],
            description: 'searchable-$turn',
          );
        }
        await persistence.snapshotMessageVariant(
          sessionId: id,
          turnNumber: turn,
          content: 'previous-variant-$turn',
          sourceInput: 'previous-input-$turn',
        );
      }
      await eventLog.appendAll(id, [
        AgentDurableEvent(
          type: AgentEventTypes.systemFrozen,
          data: const {'turn': 1, 'content': 'original-prefix'},
        ),
        for (var turn = 1; turn <= 3; turn++) ...[
          AgentDurableEvent(
            type: AgentEventTypes.turnBegin,
            data: {'turn': turn, 'marker': 'old-event-$turn'},
          ),
          if (turn == 3)
            AgentDurableEvent(
              type: AgentEventTypes.systemFrozen,
              data: const {'turn': 3, 'content': 'later-prefix'},
            ),
          AgentDurableEvent(
            type: AgentEventTypes.turnEnd,
            data: {'turn': turn},
          ),
        ],
      ]);
    }

    Future<Map<String, List<Map<String, Object?>>>> readStory(String id) async {
      final tables = <String, String>{
        for (final table in [
          'chat_messages',
          'experiential_memories',
          'memories_fts',
          'factual_entities',
          'factual_fts',
          'intermediate_round_artifacts',
          'message_variants',
          'agent_events',
          'chat_sessions',
        ])
          table: 'session_id = ?',
        for (final table in ['factual_attributes', 'factual_memory_history'])
          table: 'entity_id IN ( '
              'SELECT entity_id FROM factual_entities WHERE session_id = ?)',
      };
      return {
        for (final entry in tables.entries)
          entry.key: (await db.customSelect(
            'SELECT * FROM ${entry.key} WHERE ${entry.value} ORDER BY rowid',
            variables: [Variable.withString(id)],
          ).get())
              .map((row) => row.data)
              .toList(),
      };
    }

    test('冻结前缀备忘仅在截断已提交后失效', () async {
      final session = await chatRepo.createSession(
        title: 'Frozen prefix story',
        mode: 'advanced',
      );
      final id = session.sessionId;
      final controller = buildController(
        [
          for (var attempt = 1; attempt <= 5; attempt++) ...[
            sse([
              toolCallStart(
                0,
                'memory-$attempt',
                'record_event_memory',
                '{"what":"recorded event $attempt","importance":3}',
              ),
              finish('tool_calls'),
              '[DONE]',
            ]),
            finishRoundStep('finish-$attempt', 'prose-$attempt'),
          ],
        ],
        sessionId: id,
        persistenceService: persistence,
        eventLogRepository: eventLog,
      );
      addTearDown(controller.dispose);
      Future<List<AgentDurableEvent>> frozenEvents() async =>
          (await eventLog.readEvents(id))
              .where((event) => event.type == AgentEventTypes.systemFrozen)
              .toList();

      Future<void> send(String input) async {
        final accepted = await controller.sendMessage(input).timeout(
              const Duration(seconds: 5),
              onTimeout: () => throw TestFailure(
                '$input did not finish, phase=${controller.state.phase}, '
                'requests=${hangClient.callCount}',
              ),
            );
        expect(accepted, isTrue);
        expect(controller.state.phase, IntermediatePhase.idle);
      }

      await send('input-1');
      await send('input-2');
      final target = controller.state.messages[2];
      expect(
        await controller.updateSession(
          controller.state.session
              .copyWith(systemPromptOverride: 'revised rules'),
        ),
        isTrue,
      );
      await send('input-3');
      final originalPrefix = await frozenEvents();
      expect(originalPrefix.map((event) => event.data['turn']), [1, 3]);
      expect(originalPrefix.last.data['content'], contains('revised rules'));
      await db.customStatement('''
        CREATE TRIGGER reject_memo_rollback
        BEFORE UPDATE OF current_narrative_time ON chat_sessions
        WHEN OLD.session_id = '$id' AND NOT EXISTS (
          SELECT 1 FROM agent_events
          WHERE session_id = '$id' AND seq = ${originalPrefix.last.seq}
        )
        BEGIN
          SELECT observe_rollback_fault('after-frozen-truncate');
          SELECT RAISE(ABORT, 'injected freeze rollback failure');
        END
      ''');

      await controller.deleteRound(target);
      expect(injectedFaults, ['after-frozen-truncate']);
      expect(controller.state.messages, hasLength(6));
      expect(
        (await frozenEvents()).map((event) => event.toJson()),
        originalPrefix.map((event) => event.toJson()),
      );
      await db.customStatement('DROP TRIGGER reject_memo_rollback');
      await send('input-4');
      expect(
        (await frozenEvents()).map((event) => event.toJson()),
        originalPrefix.map((event) => event.toJson()),
      );

      await controller.deleteRound(target);
      expect(
        (await frozenEvents()).single.toJson(),
        originalPrefix.first.toJson(),
      );
      await send('replacement input');
      final newPrefix = await frozenEvents();
      expect(newPrefix.map((event) => event.data['turn']), [1, 2]);
      expect(
        newPrefix.last.data['content'],
        originalPrefix.last.data['content'],
      );
    });

    for (final operation in ['delete', 'edit', 'regenerate']) {
      for (final fault in ['before-event-delete', 'after-event-delete']) {
        test('$operation rolls back after $fault and can be retried', () async {
          final session = await chatRepo.createSession(
            title: 'Rollback story',
            mode: 'advanced',
          );
          final otherSession = await chatRepo.createSession(
            title: 'Independent story',
            mode: 'advanced',
          );
          final id = session.sessionId;
          await seedStory(id);
          await seedStory(otherSession.sessionId);
          final keepInput = operation == 'regenerate';
          final startsModel = operation != 'delete';

          // 滚动保留裁掉目标轮，仍须从幸存的更晚轮起点截断事件。
          final cropped =
              operation == 'delete' && fault == 'before-event-delete';
          if (cropped) {
            expect(await eventLog.trimToRecentTurns(id, 1), greaterThan(0));
          }
          final oldEvents = await eventLog.readEvents(id);
          expect(
            oldEvents.any((event) => event.data['turn'] == 2),
            !cropped,
          );
          final firstDeletedSeq = oldEvents
                  .firstWhere(
                    (event) =>
                        event.type == AgentEventTypes.turnBegin &&
                        event.data['turn'] == (cropped ? 3 : 2),
                  )
                  .seq ??
              fail('The first deleted event must have a persisted sequence');
          final retainedEvents = oldEvents
              .where((event) {
                final seq = event.seq ??
                    fail('Every persisted event must have a sequence');
                return seq < firstDeletedSeq;
              })
              .map((event) => event.toJson())
              .toList();
          final controller = buildController(
            [
              finishRoundStep('replacement-first', 'replacement prose'),
              finishRoundExemption('replacement-final', 'replacement prose'),
            ],
            sessionId: id,
            persistenceService: persistence,
            eventLogRepository: eventLog,
            hangAt: 0,
          );
          addTearDown(controller.dispose);
          final client = hangClient
            ..hangResponse =
                finishRoundStep('replacement-first', 'replacement prose');
          await controller.loadHistory();
          expect(controller.state.messages, hasLength(6));
          expect(controller.state.session.currentNarrativeTime, 'storytime3');
          expect(controller.state.session.nextTurn, 4);
          final originalPageMessages = controller.state.messages;
          final before = await readStory(id);
          final otherBefore = await readStory(otherSession.sessionId);
          final targetInput = originalPageMessages[2];
          final targetProse = originalPageMessages[3];

          if (fault == 'before-event-delete') {
            await db.customStatement('''
              CREATE TRIGGER reject_rollback BEFORE DELETE ON agent_events
              WHEN OLD.session_id = '$id' AND OLD.seq = $firstDeletedSeq
              AND NOT EXISTS (
                SELECT 1 FROM chat_messages
                WHERE message_id = '${targetProse.messageId}'
              )
              BEGIN
                SELECT observe_rollback_fault('$fault');
                SELECT RAISE(ABORT, 'injected event delete failure');
              END
            ''');
          } else {
            await db.customStatement('''
              CREATE TRIGGER reject_rollback
              BEFORE UPDATE OF current_narrative_time ON chat_sessions
              WHEN OLD.session_id = '$id'
              AND NEW.current_narrative_time = 'storytime1'
              AND NOT EXISTS (
                SELECT 1 FROM agent_events
                WHERE session_id = '$id' AND seq = $firstDeletedSeq
              )
              BEGIN
                SELECT observe_rollback_fault('$fault');
                SELECT RAISE(ABORT, 'injected session update failure');
              END
            ''');
          }
          Future<void> rollback() => switch (operation) {
                'edit' =>
                  controller.editAndResend(targetInput, 'replacement input'),
                'regenerate' => controller.regenerateMessage(targetProse),
                _ => controller.deleteRound(targetProse),
              };
          Future<bool> requestStarted(Future<void> action) => Future.any([
                client.hangFired.future.then((_) => true),
                action.then((_) => false, onError: (Object _) => false),
              ]);

          final failing = rollback();
          // 基线若提前请求，释放替身，使数据库读回能揭示最终的半提交结果。
          final requestedOnFailure = await requestStarted(failing);
          if (requestedOnFailure) client.hangReleased = true;
          Object? uncaughtError;
          try {
            await failing;
          } catch (error) {
            uncaughtError = error;
          }
          final afterFailure = await readStory(id);
          for (final table in before.keys) {
            expect(afterFailure[table], before[table], reason: table);
          }
          expect(injectedFaults, [fault]);
          expect(uncaughtError, isNull);
          expect(requestedOnFailure, isFalse);
          expect(client.callCount, 0);
          expect(controller.state.messages, originalPageMessages);
          expect(controller.state.session.nextTurn, 4);
          expect(controller.state.session.currentNarrativeTime, 'storytime3');
          expect(controller.state.session.storyAnchor?.arc, 'arc-3');
          expect(controller.state.isPreparingRegenerate, isFalse);
          expect(await readStory(otherSession.sessionId), otherBefore);

          await db.customStatement('DROP TRIGGER reject_rollback');
          final retry = rollback();
          try {
            expect(await requestStarted(retry), startsModel);
            final messages = await chatRepo.getMessages(id);
            expect(messages.map((message) => message.content), [
              'input-1',
              'prose-1',
              if (keepInput) 'input-2',
            ]);
            final persistedSession = await chatRepo.getSession(id);
            expect(persistedSession.messageCount, messages.length);
            expect(persistedSession.nextTurn, 2);
            expect(persistedSession.currentNarrativeTime, 'storytime1');
            expect(persistedSession.storyAnchor?.arc, 'arc-1');
            expect(controller.state.session.messageCount, messages.length);
            expect(controller.state.session.nextTurn, 2);
            expect(controller.state.session.currentNarrativeTime, 'storytime1');
            expect(controller.state.session.storyAnchor?.arc, 'arc-1');
            final experience =
                (await experienceRepo.getAllExperiences(id)).single;
            expect(experience.turnNumber, 1);
            expect(experience.summary, 'memoryturn1');
            expect((await persistence.loadArtifactsBySession(id)).keys, [1]);
            final fact = (await factRepo.findByName(id, ['factturn1'])).single;
            expect(
              (await factRepo.getAttributes(id, [fact.entityId])).single.value,
              'description-1',
            );
            expect(
              await factRepo.findByName(id, ['factturn2', 'factturn3']),
              isEmpty,
            );
            final rolledBack = await readStory(id);
            expect(
              rolledBack['memories_fts']?.map((row) => row['memory_id']),
              [experience.memoryId],
            );
            expect(
              rolledBack['factual_fts']?.map((row) => row['entity_id']),
              [projectedFactId(id)],
            );
            expect(
              (await factRepo.searchWorldFacts(id, ['worldbook-fixture']))
                  .map((entity) => entity.entityId),
              [projectedFactId(id)],
            );
            expect(
              await factRepo
                  .searchWorldFacts(id, ['searchable-2', 'searchable-3']),
              isEmpty,
            );
            expect(
              rolledBack['factual_memory_history']
                  ?.map((row) => row['turn_number']),
              [1],
            );
            final variants = await persistence.loadMessageVariants(id);
            expect(variants.keys, startsModel ? [1, 2] : [1]);
            expect(variants[1]?.single.content, 'previous-variant-1');
            if (startsModel) {
              expect(variants[2]?.map((variant) => variant.content), [
                'previous-variant-2',
                'prose-2',
              ]);
              expect(variants[2]?.last.sourceInput, 'input-2');
            }
            final events = await eventLog.readEvents(id);
            expect(
              events.take(retainedEvents.length).map((event) => event.toJson()),
              retainedEvents,
            );
            final replaced = events.skip(retainedEvents.length);
            expect(
              replaced.any((event) => event.data.containsKey('marker')),
              isFalse,
            );
            expect(replaced.any((event) => event.data['turn'] == 3), isFalse);
            expect(
              replaced.any((event) => event.type == AgentEventTypes.turnBegin),
              startsModel,
            );
            expect(await readStory(otherSession.sessionId), otherBefore);
          } finally {
            client.hangReleased = true;
            await retry;
          }
          if (startsModel) {
            expect(controller.state.messages.last.content, 'replacement prose');
            expect(
              (await persistence.loadMessageVariants(id))[2]
                  ?.map((variant) => variant.content),
              ['previous-variant-2', 'prose-2', 'replacement prose'],
            );
          }
        });
      }
    }
  });

  test('mode=advanced：剧情锚全链路（update_story_anchor → artifacts + 会话）', () async {
    // 会话行需预先存在（控制器不建行；story_anchor UPDATE 依赖它）
    await db.customStatement(
      'INSERT INTO chat_sessions (session_id, title, mode, created_at, '
      'last_active_at, message_count) '
      "VALUES ('dir-test-1', '测试导演', 'advanced', 0, 0, 0)",
    );
    final controller = buildController([
      sse([
        toolCallStart(
          0,
          'call_a1',
          'update_story_anchor',
          '{"arc":"古碑遗迹的真相","one_liner":"主角进入古碑遗迹",'
              '"narrative_time":"第三天黄昏","foreshadows":'
              '[{"text":"守碑人的身份"}]}',
        ),
        finish('tool_calls'),
        '[DONE]',
      ]),
      finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
      finishRoundExemption('call_f1b', '夜色沉下来，苏明远推开荒庙的门。'),
      // 编辑重发后的同轮重跑（不再动锚）
      finishRoundStep('call_f2', '改写后的正文。'),
      finishRoundExemption('call_f2b', '改写后的正文。'),
    ]);

    await controller.sendMessage('苏明远进入荒庙');

    // artifacts：该轮结束时的锚快照（Recap 卡数据源）
    final artifacts = controller.state.artifactsByTurnNumber?[1];
    expect(artifacts?.storyAnchor, isNotNull);
    expect(artifacts!.storyAnchor!.arc, '古碑遗迹的真相');
    expect(artifacts.storyAnchor!.openForeshadows.single.text, '守碑人的身份');

    // 会话当前锚同步（DB + 内存 state）
    final sessionRow = await db.customSelect(
      'SELECT story_anchor FROM chat_sessions WHERE session_id = ?',
      variables: [Variable.withString('dir-test-1')],
    ).getSingle();
    expect(sessionRow.read<String>('story_anchor'), contains('古碑遗迹的真相'));
    expect(controller.state.session.storyAnchor?.oneLiner, '主角进入古碑遗迹');

    // 剧情锚对称回滚：编辑重发删第 1 轮 → 该轮写的锚必须
    // 清空，DB 与内存态一致——
    // 否则被删稿经 update_story_anchor 登记的伏笔/弧线经 coreBlocks
    // 重新进入重生成轮上下文（用户实测「不该有的人物」根因）
    final anchorUserMessage =
        controller.state.messages.firstWhere((m) => m.role == 'user');
    await controller.editAndResend(anchorUserMessage, '换个写法再讲一遍');
    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.state.session.storyAnchor, isNull);
    final sessionRowAfterResend = await db.customSelect(
      'SELECT story_anchor FROM chat_sessions WHERE session_id = ?',
      variables: [Variable.withString('dir-test-1')],
    ).getSingle();
    expect(sessionRowAfterResend.readNullable<String>('story_anchor'), isNull);
  });

  test('mode=advanced：ask_user 全链路（体验重构 C2）', () async {
    final controller = buildController([
      sse([
        toolCallStart(
          0,
          'call_q1',
          'ask_user',
          '{"question":"守碑人是谁？","options":["旧友","仇人"]}',
        ),
        finish('tool_calls'),
        '[DONE]',
      ]),
      finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
      finishRoundExemption('call_f1b', '夜色沉下来，苏明远推开荒庙的门。'),
    ]);

    final round = controller.sendMessage('推进剧情');
    // 等待 ask_user 横幅出现（工具挂起等待回答）
    for (var i = 0; i < 50 && controller.state.agentAskPrompt == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(controller.state.agentAskPrompt?.question, '守碑人是谁？');
    expect(controller.state.agentAskPrompt?.options, ['旧友', '仇人']);

    // 回答后轮次继续走完
    controller.answerDirectorAsk('旧友');
    await round;

    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.state.agentAskPrompt, isNull);
    expect(controller.state.messages, hasLength(2));
  });

  test('mode=advanced：ask_user 0=一直等待（B8）——挂起期间无超时裁决，回答后照常走完', () async {
    final controller = buildController(
      [
        sse([
          toolCallStart(
            0,
            'call_q1',
            'ask_user',
            '{"question":"守碑人是谁？","options":["旧友","仇人"]}',
          ),
          finish('tool_calls'),
          '[DONE]',
        ]),
        finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
      ],
      // ask_user_timeout_minutes=0 → tuning.askUserTimeout=null →
      // runner 不挂 completer.timeout（走 await completer.future 分支）
      config: const AdvancedConfig(
        hitl: AdvancedHitlConfig(askUserTimeoutMinutes: 0),
      ),
    );

    final round = controller.sendMessage('推进剧情');
    for (var i = 0; i < 50 && controller.state.agentAskPrompt == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(controller.state.agentAskPrompt?.question, '守碑人是谁？');

    // 挂起等待：未回答期间轮次保持阻塞（无超时自动裁决）
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(controller.state.agentAskPrompt, isNotNull);
    expect(controller.state.phase, isNot(IntermediatePhase.idle));

    // 回答后照常走完
    controller.answerDirectorAsk('仇人');
    await round;

    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.state.agentAskPrompt, isNull);
  });

  test('mode=advanced：B12 E104 链路——embedding 失败 → E104 → 临时降级 → 轮成功', () async {
    // fallback_on_failure=false：host._resolveQueryVector 把 embed 失败
    // （stub 的 UnimplementedError）包装为 EmbeddingCallFailedException；
    // SearchStoryTool 不再吞（此前 catchError 吞成静默 FTS），
    // 经管线致命通道上抛 → runner error → ⑤ 判 E104。
    final controller = buildController(
      [
        sse([
          toolCallStart(0, 'call_s1', 'search_story', '{"query":"古碑"}'),
          finish('tool_calls'),
          '[DONE]',
        ]),
        finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
        finishRoundExemption('call_f1b', '夜色沉下来，苏明远推开荒庙的门。'),
      ],
      resolver: _EmbeddingFailResolver(),
    );

    await controller.sendMessage('推进剧情');

    // ① 首轮：search_story 的 embedding 调用失败 → E104（可临时降级）
    expect(controller.state.phase, IntermediatePhase.failed);
    expect(controller.state.failureContext?.errorCode, 'E104');
    expect(controller.state.embeddingDegradedForRound, isFalse);

    // ② 临时降级继续：置 degraded 后重跑导演轮。 修复后标记是
    // 轮内生命周期（置位 → persist 成功即复位），整轮在本次 await 内闭环，
    // 完成后无法再观测到 true——用监听器钉住轮内确曾置位。
    var sawDegradedDuringRound = false;
    controller.addListener((s) {
      if (s.embeddingDegradedForRound) sawDegradedDuringRound = true;
    });
    await controller.continueWithFts5Only();
    expect(sawDegradedDuringRound, isTrue);

    // ③ 降级轮：resolveQueryVector 跳过 embedding（FTS 兜底），轮成功
    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.state.failureContext, isNull);
    expect(controller.state.messages, hasLength(2));
    // 降级轮 persist 成功后重置跨轮降级标记——
    // 此前成功 copyWith 漏带，标记泄漏到后续所有轮次（永久跳过 embedding）
    expect(controller.state.embeddingDegradedForRound, isFalse);
  });

  // persist 阶段嵌入失败
  // 不再以 E104 阻断收稿——自动降级 has_embedding=false（FTS5 兜底）+
  // durable 事件留痕。E104 手动降级出口仍由检索侧（search_story）链路触达
  // （见上方  用例）。
  test('mode=advanced：G-01 persist 嵌入致命异常 → 自动降级收稿 + 事件留痕', () async {
    // importance=5 ≥ microVectorizeThreshold(4) → persist 阶段调用
    // _resolveEmbedding；_EmbeddingFailResolver（fallback=false）把 stub 的
    // UnimplementedError 包装为 EmbeddingCallFailedException 上抛。
    final controller = buildController(
      [
        sse([
          toolCallStart(
            0,
            'call_m1',
            'record_event_memory',
            '{"what":"苏明远夜探荒庙","importance":5}',
          ),
          finish('tool_calls'),
          '[DONE]',
        ]),
        finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
      ],
      resolver: _EmbeddingFailResolver(),
      withEventLog: true,
    );

    await controller.sendMessage('推进剧情');

    // ① 轮次正常收稿：不再 failed + E104，消息照常落库
    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.state.failureContext, isNull);
    expect(controller.state.messages, hasLength(2));

    // ② 记忆条目落库且 has_embedding=false（FTS5 检索兜底仍在）
    final memory = await db.customSelect(
      'SELECT has_embedding FROM experiential_memories WHERE session_id = ?',
      variables: [Variable.withString('dir-test-1')],
    ).getSingle();
    expect(memory.read<bool>('has_embedding'), isFalse);

    // ③ durable 事件留痕（log-only，轨迹页可查）
    final events = await AgentEventLogRepository(
      database: db,
    ).readEvents('dir-test-1');
    expect(
      events.any((e) => e.type == AgentEventTypes.persistEmbeddingDegraded),
      isTrue,
    );
  });

  // 非破坏性重生成端到端
  //
  // 重生成旧版快照为变体 0、新版记变体 1 并移指针；切回旧版后消息 content
  // 物化为旧版，下一轮请求上下文含所选版本（content 即上下文）。
  test('mode=advanced：G-08+09 重生成保留旧版可切换+切换后上下文含所选版', () async {
    final bodies = <String>[];
    final controller = buildController(
      [
        sse([
          toolCallStart(
            0,
            'call_m1',
            'record_event_memory',
            '{"what":"开局","importance":3}',
          ),
          finish('tool_calls'),
          '[DONE]',
        ]),
        finishRoundStep('call_f1', '第一版正文：夜色沉下来。'),
        sse([
          toolCallStart(
            0,
            'call_m2',
            'record_event_memory',
            '{"what":"重生成","importance":3}',
          ),
          finish('tool_calls'),
          '[DONE]',
        ]),
        finishRoundStep('call_f2', '第二版正文：雨还在下。'),
        sse([
          toolCallStart(
            0,
            'call_m3',
            'record_event_memory',
            '{"what":"第三轮","importance":3}',
          ),
          finish('tool_calls'),
          '[DONE]',
        ]),
        finishRoundStep('call_f3', '第三版正文：天亮了。'),
      ],
      bodyLog: bodies,
    );

    await controller.sendMessage('推进剧情');
    expect(controller.state.messages, hasLength(2));
    expect(controller.state.messages.last.content, contains('第一版正文'));

    // ① 重生成：旧版不销毁（快照为 variant 0），新版 = variant 1
    await controller.regenerateMessage(controller.state.messages.last);
    expect(controller.state.messages, hasLength(2));
    expect(controller.state.messages.last.content, contains('第二版正文'));
    expect(controller.state.variantFlashTurn, 1, reason: '新变体收稿高亮信号');
    // 收稿即同步内存变体面——切换器渲染条件为
    // variants.length>1 && currentVariantIndex!=null，此前两值在收稿后
    // 均不刷新（variantsByTurn 无写点、指针默认 null），切换器只在
    // 重开会话后可见， 主流程（重生成→切换）不可达。
    expect(
      controller.state.variantsByTurn?[1],
      hasLength(2),
      reason: '收稿后内存变体表立即可用（不依赖重开会话）',
    );
    expect(
      controller.state.artifactsByTurnNumber?[1]?.currentVariantIndex,
      1,
      reason: '内存变体指针随收稿回写为新版',
    );

    final svc = StoryPersistenceServiceImpl(
      database: db,
      chatRepository: ChatRepositoryImpl(database: db),
      experienceRepository: ExperienceRepositoryImpl(
        database: db,
        vectorEngine: const VectorEngine(),
      ),
    );
    final variants = await svc.loadMessageVariants('dir-test-1');
    expect(variants[1], hasLength(2), reason: '重生成后两版本并存');
    expect(variants[1]![0].content, contains('第一版正文'));
    expect(variants[1]![1].content, contains('第二版正文'));
    var artifactsMap = await svc.loadArtifactsBySession('dir-test-1');
    expect(artifactsMap[1]!.currentVariantIndex, 1, reason: '指针指向新版');

    // ② 切回 variant 0：消息正文物化为第一版，指针回 0
    await controller.switchMessageVariant(controller.state.messages.last, 0);
    expect(controller.state.messages.last.content, contains('第一版正文'));
    artifactsMap = await svc.loadArtifactsBySession('dir-test-1');
    expect(artifactsMap[1]!.currentVariantIndex, 0);
    expect(controller.state.variantFlashTurn, isNull);

    // ③ 下一轮请求上下文含所选版本（content 即上下文组装源）
    await controller.sendMessage('继续');
    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.state.messages, hasLength(4));
    expect(bodies.last, contains('第一版正文'), reason: '切换后下一轮请求含所选版本');

    // ④ 清除高亮信号可幂等调用
    controller.clearVariantFlash();
    expect(controller.state.variantFlashTurn, isNull);
  });

  test('mode=advanced：监督模式写前审批（体验重构 C2）', () async {
    final controller = buildController(
      [
        sse([
          toolCallStart(
            0,
            'call_u1',
            'update_facts',
            '{"deltas":[{"action":"create_entity","confidence":4,'
                '"primary_name":"苏明远","entity_type":"character","importance":4}]}',
          ),
          finish('tool_calls'),
          '[DONE]',
        ]),
        finishRoundStep('call_f2', '故事继续。'),
        finishRoundExemption('call_f2b', '故事继续。'),
      ],
      watchMode: true,
    );

    final round = controller.sendMessage('推进剧情');
    // 等待审批横幅出现（写档工具被审批 seam 拦住）
    for (var i = 0;
        i < 500 && controller.state.agentApprovalPrompt == null;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(controller.state.agentApprovalPrompt?.toolName, 'update_facts');
    expect(controller.state.agentApprovalPrompt?.summary, '1 处设定修订');

    // 允许后写入生效、轮次走完
    controller.resolveDirectorApproval(allow: true);
    await round;

    expect(controller.state.phase, IntermediatePhase.idle);
    final entities = await db.customSelect(
      'SELECT COUNT(*) AS c FROM factual_entities WHERE session_id = ?',
      variables: [Variable.withString('dir-test-1')],
    ).getSingle();
    expect(entities.read<int>('c'), 1);
  });

  test('mode=advanced：B12 投影等价——每步 outgoing == deriveAgentSurface(事件前缀)',
      () async {
    // 断言先行（不换真相源）：取真实轮的 durable 事件 + 当轮实际 outgoing
    // （HTTP body 快照），断言投影重建与真实请求逐字节等价。
    //
    // 已知近似项（显式豁免清单，随 / 逐项收敛）：
    // 1. 跨轮旧尾部残影：多轮会话的轮首 surface 从 chat_messages 重建
    //    （丢弃往轮注入面与工具结果，仅回插 round-work trace），投影则
    //    保留全部 append——本断言只覆盖「首轮起算的轮内增量」（本用例
    //    即首轮两步）；跨轮口径待请求面日志派生（远期）后收编。
    // 2. 子代理事件（起 log-only 中继落账）不进投影——relay 剥离
    //    surfaceOp，天然豁免。
    // 3. 恢复器补写的 assistant/message（interrupted 半截正文）只在投影
    //    侧存在——已恢复会话不在本断言范围。
    // 4. finish_round 的 prose 参数流（onToolArgDelta 直播）不产生 durable
    //    事件——终值经 assistant/message 与收割链路落账。
    final bodies = <String>[];
    final controller = buildController(
      [
        sse([
          textDelta('我先查一下。'),
          toolCallStart(0, 'call_s1', 'search_story', '{"query":"古碑"}'),
          finish('tool_calls'),
          '[DONE]',
        ]),
        finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
        finishRoundExemption('call_f1b', '夜色沉下来，苏明远推开荒庙的门。'),
      ],
      withEventLog: true,
      bodyLog: bodies,
    );

    await controller.sendMessage('苏明远进入荒庙');

    expect(controller.state.phase, IntermediatePhase.idle);
    expect(bodies, hasLength(3), reason: '三步：检索 + finish_round 两段（闸门 B 豁免）');

    final events = await AgentEventLogRepository(database: db).readEvents(
      'dir-test-1',
    );
    expect(events, isNotEmpty);

    // 各步 outgoing = 该步 assistant/message 事件之前的全部事件投影
    final assistantIndexes = <int>[];
    for (var i = 0; i < events.length; i++) {
      if (events[i].type == AgentEventTypes.assistantMessage) {
        assistantIndexes.add(i);
      }
    }
    expect(assistantIndexes, hasLength(3));

    final wire = AgentWireOptions.forProtocolName('openaiCompatible');
    for (var step = 0; step < assistantIndexes.length; step++) {
      final projection = deriveAgentSurface(
        events.sublist(0, assistantIndexes[step]),
      );
      final projected = [
        for (final message in projection.messages) message.toRequestMap(wire),
      ];
      final wireMessages = (jsonDecode(bodies[step])
          as Map<String, dynamic>)['messages'] as List<dynamic>;
      expect(
        projected,
        equals(wireMessages),
        reason: '第 ${step + 1} 步请求面与事件投影不等价',
      );
    }

    // 结构性抽检：第 1 步含冻结前缀 system + 本轮 user 输入；
    // 第 2 步追加 assistant(tool_calls) 与 tool 结果（配对合法）
    final firstRequest = (jsonDecode(bodies[0])
        as Map<String, dynamic>)['messages'] as List<dynamic>;
    expect((firstRequest.first as Map<String, dynamic>)['role'], 'system');
    expect(
      firstRequest.any(
        (m) => (m as Map<String, dynamic>)['role'] == 'user',
      ),
      isTrue,
    );
    final secondRequest = (jsonDecode(bodies[1])
        as Map<String, dynamic>)['messages'] as List<dynamic>;
    expect(
      secondRequest.any(
        (m) => (m as Map<String, dynamic>)['role'] == 'tool',
      ),
      isTrue,
      reason: '工具结果进第 2 步请求（投影与真实面同源）',
    );
  });

  test('mode=advanced：B7-4 审批「本会话总是允许」——后续同工具免审留痕，清除后恢复审批', () async {
    final script = <String>[
      sse([
        toolCallStart(
          0,
          'call_u1',
          'update_facts',
          '{"deltas":[{"action":"create_entity","confidence":4,'
              '"primary_name":"苏明远","entity_type":"character","importance":4}]}',
        ),
        finish('tool_calls'),
        '[DONE]',
      ]),
      finishRoundStep('call_f2', '故事继续。'),
      finishRoundExemption('call_f2b', '故事继续。'),
    ];
    final controller = buildController(script, watchMode: true);

    // ── 轮 1：首次审批，选「本会话总是允许」 ──
    final round1 = controller.sendMessage('推进剧情');
    for (var i = 0;
        i < 500 && controller.state.agentApprovalPrompt == null;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(controller.state.agentApprovalPrompt?.toolName, 'update_facts');
    controller.resolveDirectorApproval(allow: true, always: true);
    await round1;
    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.sessionApprovalAllowCount, 1);
    // 记忆写入的留痕随 artifacts 持久化（live 列表轮末清空）
    final turn1Steps =
        controller.state.artifactsByTurnNumber?[1]?.agentSteps ?? const [];
    expect(
      turn1Steps.any((s) => s.title.contains('本会话放行')),
      isTrue,
    );

    // ── 轮 2：同工具再次写入——不再弹横幅，自动放行留痕，轮次不阻塞 ──
    script.addAll([
      sse([
        toolCallStart(
          0,
          'call_u3',
          'update_facts',
          '{"deltas":[{"action":"create_entity","confidence":4,'
              '"primary_name":"林玉","entity_type":"character","importance":3}]}',
        ),
        finish('tool_calls'),
        '[DONE]',
      ]),
      finishRoundStep('call_f4', '故事推进。'),
      finishRoundExemption('call_f4b', '故事推进。'),
    ]);
    await controller.sendMessage('再推进');
    // 轮 2 结束后：审批横幅从未出现（无阻塞等待），写入已直接放行
    expect(controller.state.phase, IntermediatePhase.idle);
    final turn2Steps =
        controller.state.artifactsByTurnNumber?[2]?.agentSteps ?? const [];
    expect(
      turn2Steps.any((s) => s.title.contains('自动放行')),
      isTrue,
      reason: '会话级放行命中时 approvalRequiredFor 直接放行并留痕 L2',
    );

    // ── 清除放行后恢复逐次审批 ──
    expect(controller.clearSessionApprovalAllows(), 1);
    expect(controller.sessionApprovalAllowCount, 0);
  });

  test('mode=advanced：首回合能力提示注入、第二回合消失（P3.4）', () async {
    final bodies = <String>[];
    final script = <String>[
      finishRoundStep('call_f1', '第一幕开场。'),
      finishRoundExemption('call_f1b', '第一幕开场。'),
    ];
    final controller = buildController(script, bodyLog: bodies);

    await controller.sendMessage('开场');

    expect(controller.state.phase, IntermediatePhase.idle);
    // 首回合首个请求：surface 尾部（本轮用户输入之后）带能力提示
    expect(bodies.first, contains('能力提示'));
    expect(bodies.first, contains('spawn'));

    // 第二回合：提示不注入（历史回放也不含——surface 消息未持久化）
    script.addAll([
      finishRoundStep('call_f2', '第二幕推进。'),
      finishRoundExemption('call_f2b', '第二幕推进。'),
    ]);
    await controller.sendMessage('继续');

    expect(controller.state.phase, IntermediatePhase.idle);
    final turn2FirstRequest = bodies[2];
    expect(turn2FirstRequest, isNot(contains('能力提示')));
  });

  test('mode=advanced：重新生成后请求中该用户消息恰好出现一次', () async {
    const userText = '勇者进入边境庄园';
    final bodies = <String>[];
    final script = <String>[
      finishRoundStep('call_f1', '第一幕开场。'),
      finishRoundExemption('call_f1b', '第一幕开场。'),
    ];
    final controller = buildController(script, bodyLog: bodies);

    await controller.sendMessage(userText);
    expect(controller.state.phase, IntermediatePhase.idle);

    // 重新生成第一轮的 assistant 回复：user_N 刻意保留在库中（Fork 语义）
    script.addAll([
      finishRoundStep('call_f2', '重新生成第一幕。'),
      finishRoundExemption('call_f2b', '重新生成第一幕。'),
    ]);
    final assistantMessage = controller.state.messages
        .where((m) => m.role == 'assistant')
        .reduce((a, b) => b);
    await controller.regenerateMessage(assistantMessage);

    expect(controller.state.phase, IntermediatePhase.idle);
    expect(bodies.length, greaterThanOrEqualTo(4));
    // 修复前：history 重载末尾含 user_N，surface 组装再追加 userInput →
    // 同一条用户消息进上下文两次。断言重新生成的每个请求（含 step 续传）
    // 中该文本作为独立 user 消息恰好一次。
    for (final body in bodies.sublist(2)) {
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final messages = decoded['messages']! as List<dynamic>;
      expect(
        messages.where(
          (m) => m is Map && m['role'] == 'user' && m['content'] == userText,
        ),
        hasLength(1),
      );
    }
  });

  test('mode=advanced：轮时间线随 artifacts 持久化（思考/播报/动作交错，T4）', () async {
    final controller = buildController([
      // Step 0：思考 + 播报 + search_story
      sse([
        '{"choices":[{"delta":{"reasoning_content":"先查前情。"},"finish_reason":null}]}',
        textDelta('让我先翻翻前情。'),
        toolCallStart(0, 'call_s1', 'search_story', '{"query":"古碑"}'),
        finish('tool_calls'),
        '[DONE]',
      ]),
      // Step 1：正文经 prose 参数交付 + finish_round（闸门 B 拒绝）
      finishRoundStep('call_f1', '夜色沉下来，苏明远推开荒庙的门。'),
      // Step 2：补记事件记忆
      sse([
        toolCallStart(
          0,
          'call_m1',
          'record_event_memory',
          '{"what":"苏明远夜探荒庙","importance":3}',
        ),
        finish('tool_calls'),
        '[DONE]',
      ]),
      // Step 3：二次 finish_round 放行
      finishRoundStep('call_f2', '夜色沉下来，苏明远推开荒庙的门。'),
    ]);

    await controller.sendMessage('苏明远进入荒庙');
    expect(controller.state.phase, IntermediatePhase.idle);

    final artifacts = controller.state.artifactsByTurnNumber?[1];
    expect(artifacts, isNotNull);

    expect(artifacts!.agentSteps, isNotEmpty);
    expect(artifacts.agentTimeline.map((b) => b.kind).toList(), [
      AgentTimelineKind.thinking,
      AgentTimelineKind.narration,
      AgentTimelineKind.action,
      AgentTimelineKind.action,
      AgentTimelineKind.action,
      AgentTimelineKind.action,
    ]);
    expect(artifacts.agentTimeline[0].text, '先查前情。');
    expect(artifacts.agentTimeline[1].text, '让我先翻翻前情。');
    expect(artifacts.agentTimeline[2].action!.toolName, 'search_story');
    expect(artifacts.agentTimeline[2].stepIndex, 0);
    expect(
      artifacts.agentTimeline
          .where((b) => b.kind == AgentTimelineKind.narration)
          .length,
      1,
    );

    // 消息行 thinkingContent 合并串保持写入（现有消费者不感知）
    final assistant = controller.state.messages
        .where((m) => m.role == 'assistant')
        .reduce((a, b) => b);
    expect(assistant.thinkingContent, '先查前情。');

    // 数据库 agent_timeline 列实际落库
    final row = await db.customSelect(
      'SELECT agent_timeline FROM intermediate_round_artifacts '
      'WHERE session_id = ? AND turn_number = 1',
      variables: [Variable.withString('dir-test-1')],
    ).getSingle();
    expect(row.readNullable<String>('agent_timeline'), contains('narration'));
  });

  test('mode=advanced：重生成覆盖同轮时间线（T4）', () async {
    final script = <String>[
      finishRoundStep('call_f1', '旧版正文。'),
      finishRoundExemption('call_f1b', '旧版正文。'),
    ];
    final controller = buildController(script);

    await controller.sendMessage('推进剧情');
    expect(controller.state.phase, IntermediatePhase.idle);
    final artifactsV1 = controller.state.artifactsByTurnNumber![1]!;
    expect(
      artifactsV1.agentTimeline.map((b) => b.kind),
      [AgentTimelineKind.action, AgentTimelineKind.action],
    );
    expect(
      controller.state.messages.lastWhere((m) => m.role == 'assistant').content,
      '旧版正文。',
    );

    script.addAll([
      sse([
        '{"choices":[{"delta":{"reasoning_content":"换个写法。"},"finish_reason":null}]}',
        toolCallStart(0, 'call_f2', 'finish_round', '{"prose":"新版正文，换了开场。"}'),
        finish('tool_calls'),
        '[DONE]',
      ]),
      finishRoundExemption('call_f2b', '新版正文，换了开场。'),
    ]);
    final assistantMessage = controller.state.messages
        .where((m) => m.role == 'assistant')
        .reduce((a, b) => b);
    await controller.regenerateMessage(assistantMessage);
    expect(controller.state.phase, IntermediatePhase.idle);

    final regenerated = controller.state.artifactsByTurnNumber?[1];
    expect(regenerated, isNotNull);
    // 覆盖后是新版时间线：首块为思考，正文升格不进时间线
    expect(regenerated!.agentTimeline.first.kind, AgentTimelineKind.thinking);
    expect(regenerated.agentTimeline.first.text, '换个写法。');
    final rows = await db.customSelect(
      'SELECT COUNT(*) AS c FROM intermediate_round_artifacts '
      'WHERE session_id = ? AND turn_number = 1',
      variables: [Variable.withString('dir-test-1')],
    ).getSingle();
    expect(rows.read<int>('c'), 1, reason: '重生成覆盖同 turnNumber，不留旧行');
  });

  // ── 停止保留半截正文 + failed 态直发 ─────────────────────────────

  test('mode=advanced：直播正文流出后手动停止 → 保留为未完成稿件（不再蒸发）', () async {
    final controller = buildController(
      const [],
      hangAt: 0,
    );

    unawaited(controller.sendMessage('苏明远进入荒庙'));
    await hangClient.hangFired.future.timeout(const Duration(seconds: 20));
    // HTTP 层吐帧 ≠ 模型层建块：等 liveBlocks 出现非空文本块再停止
    // （太早停止会走「无稿清场」分支）。
    expect(
      await until(
        () => controller.state.liveBlocks.any(
          (b) => b.kind == AgentLiveBlockKind.text && !b.isEmpty,
        ),
      ),
      isTrue,
      reason: '等待直播正文块到达',
    );

    await controller.cancel();
    expect(
      await until(
        () =>
            controller.state.phase == IntermediatePhase.failed &&
            !controller.state.isStopping,
      ),
      isTrue,
      reason: '等待停止落定',
    );

    // 停止≠丢弃：进「已停止」failed 态，直播块与 pending 气泡保留
    expect(controller.state.failureContext?.errorCode, 'user_stopped');
    expect(
      controller.state.failureContext?.failedPhase,
      IntermediatePhase.generating,
    );
    expect(
      controller.state.liveBlocks.any(
        (b) => b.kind == AgentLiveBlockKind.text && !b.isEmpty,
      ),
      isTrue,
      reason: '半截直播正文保留为未完成稿件',
    );
    expect(controller.state.pendingUserMessage, isNotNull);
  });

  test('mode=advanced：停止后的 failed 态直发新消息 → 事务性清残留无幽灵轮', () async {
    final controller = buildController(
      [
        finishRoundStep('call_f1', '完整的第二轮正文。'),
        finishRoundExemption('call_f1b', '完整的第二轮正文。'),
      ],
      hangAt: 0,
    );

    unawaited(controller.sendMessage('第一条'));
    await hangClient.hangFired.future.timeout(const Duration(seconds: 20));
    expect(
      await until(
        () => controller.state.liveBlocks.any(
          (b) => b.kind == AgentLiveBlockKind.text && !b.isEmpty,
        ),
      ),
      isTrue,
    );
    await controller.cancel();
    expect(
      await until(
        () =>
            controller.state.phase == IntermediatePhase.failed &&
            !controller.state.isStopping,
      ),
      isTrue,
    );

    // failed 态直发：不再要求先清空本轮
    await controller.sendMessage('第二条');

    expect(controller.state.phase, IntermediatePhase.idle);
    expect(controller.state.failureContext, isNull);
    expect(controller.state.liveBlocks, isEmpty, reason: '旧直播块随新轮清理，不残留');
    // 幽灵轮检查：第一轮从未持久化，库里只有第二轮一对消息
    final messages = await db.customSelect(
      'SELECT role, content FROM chat_messages WHERE session_id = ? '
      'ORDER BY created_at ASC',
      variables: [Variable.withString('dir-test-1')],
    ).get();
    expect(messages, hasLength(2));
    expect(messages.last.read<String>('content'), contains('完整的第二轮正文'));
  });

  // ── 开启态事件暴露量闸门（03 §7.2 三类真实入口）────────────────
  //
  // 三类实体在真实控制器链上的排除/计入语义：压缩前旧正文实体（全历史
  // 口径 loadSessionMessages，state.messages 是压缩过滤视图）、既有事件
  // 记忆覆盖（事件记忆库 5W1E 子串，非事实卡）、真新实体（计入并首拒）。
  // 触发面比（surfaceEstimateRatio>0.6）用 26 万字符指令面真实撑过
  // （窗口 96k 默认解析；不 mock 闸门参数）。

  /// query_facts 一步（证据闸门的真实证据来源）
  String queryFactsStep(String callId, String name) => sse([
        toolCallStart(0, callId, 'query_facts', '{"name":${jsonEncode(name)}}'),
        finish('tool_calls'),
        '[DONE]',
      ]);

  Future<void> openEngineeringMode(
    AdvancedChatController controller,
  ) async {
    for (var i = 0; i < 500 && controller.state.loadingHistory; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await db.into(db.chatSessionsTable).insert(
          ChatSessionsTableCompanion.insert(
            sessionId: 'dir-test-1',
            title: '测试导演',
            mode: const Value('advanced'),
          ),
        );
  }

  Future<void> createKeyEntity(String name) async {
    await FactualRepositoryImpl(database: db).createEntity(
      FactualEntity(
        entityId: 'ent-${name.hashCode.abs()}',
        sessionId: 'dir-test-1',
        type: FactualEntityType.character,
        primaryName: name,
        aliases: const [],
        importance: 5,
        createdTurn: 0,
        createdAt: DateTime(2026),
      ),
    );
  }

  test('开启态暴露量闸门：压缩前旧实体与记忆覆盖不算新暴露（三类同轮）', () async {
    await createKeyEntity('沈青梧');
    await createKeyEntity('黑潮');
    await createKeyEntity('蚀骨门');
    final controller = buildController(
      [
        // 第 1 轮：正文引入沈青梧（名字在第 60 字之后，finish 回执的
        // 60 字预览不含它；轮末才 persist，闸门时 chat 行还空，暴露量
        // 1 < 3 正常放行）。文风 lint 真实生效，正文用自然文本。
        finishRoundStep(
          'call_r1f',
          '夜风起了。荒庙的门轴发出一声长长的呻吟，惊得梁上的灰簌簌落下。'
              '庙里没有灯。黑暗里能数出七根裂柱、两尊无头佛像和一张缺了腿的供桌。'
              '香炉是冷的。最后一炷香在很多年前熄灭，此后再没有人来添过。\n'
              '沈青梧把包袱放在供桌上，解开，又系上。里头只有半块玉牌、一柄短刀'
              '和三天的干粮。雨追着风到了。檐角滴水，一声，又一声，把夜敲得很空。'
              '她坐在供桌旁，把袖中那半块玉牌摸出来，翻过来，又翻过去。\n'
              '玉牌上有字，磨得只剩半个。她认得那半个字。认了二十年，也恨了二十年。'
              '山外的路被封了，信送不出去，人也走不出去。出庙门时，雨小了。'
              '她沿着塌了半边的石阶往下走，走了很久。山下的镇子亮着零星几盏灯。'
              '最亮的那盏在渡口。老周说过，渡口的灯不灭，就还有人等船。'
              '她现在要去吹灭它。刀就在腰后。路不远。',
        ),
        // 第 2 轮：先检索核对三个实体（证据闸门），再 finish_round
        queryFactsStep('call_q1', '沈青梧'),
        queryFactsStep('call_q2', '黑潮'),
        queryFactsStep('call_q3', '蚀骨门'),
        finishRoundStep('call_r2f', '沈青梧望向黑潮，蚀骨门的号角在城外响起。'),
        // 闸门若误拒，脚本走豁免重提交步（消耗第 6 次模型调用）
        finishRoundExemption(
          'call_r2f2',
          '沈青梧望向黑潮，蚀骨门的号角在城外响起。',
        ),
      ],
      maxSteps: 8,
      withEventLog: true,
      withEngineeringSwitch: true,
    );
    await openEngineeringMode(controller);
    final switched = await controller.setEngineeringContextEnabled(
      enabled: true,
    );
    expect(switched, isTrue);

    await controller.sendMessage('开场');
    expect(controller.state.phase, IntermediatePhase.idle);

    // 真实压缩（服务直调，trigger=manual 同一事务契约）：把第 1 轮正文
    // 整体遮蔽——此后 state.messages（投影）不再含旧正文，chat 行仍含
    final manualService = EngineeringCompactionService(
      database: db,
      eventRepository: AgentEventLogRepository(database: db),
      chatRepository: ChatRepositoryImpl(database: db),
      experienceRepository: ExperienceRepositoryImpl(
        database: db,
        vectorEngine: const VectorEngine(),
      ),
      summarizer: const _PlainSummarizer(),
      // 保尾 40 字符：只留 finish 回执（60 字预览不含实体名），含名字的
      // 正文/声明整体进遮蔽区间
      tuning: const EngineeringCompactionTuning(
        outputReserveTokens: 1000,
        headroomTokens: 500,
        retainRatio: 0,
        retainMinTokens: 10,
        retainMaxTokens: 10,
        oversizedResultChars: 500,
        degradeHeadChars: 100,
      ),
    );
    final compactResult = await manualService.compact(
      sessionId: 'dir-test-1',
      trigger: 'manual',
      contextWindowTokens: 32000,
      retrievalRatio: 0.15,
    );
    expect(compactResult.outcome, 'committed');

    // 前置证明：投影已丢旧正文（旧口径据此误判）、chat 全历史仍在
    final ledger =
        await AgentEventLogRepository(database: db).readEvents('dir-test-1');
    final projected = DirectorSurfaceV2.epochWindowProjection(ledger)
        .messages
        .map((m) => m.content ?? '')
        .join('\n');
    expect(
      projected,
      isNot(contains('沈青梧')),
      reason: '前置：压缩后投影不再含旧正文（被压缩视图误导的前提）',
    );
    final chatRows = await db.customSelect(
      'SELECT content FROM chat_messages WHERE session_id = ?',
      variables: [Variable.withString('dir-test-1')],
    ).get();
    expect(
      chatRows.map((r) => r.read<String>('content')).join('\n'),
      contains('沈青梧'),
      reason: '前置：chat_messages 全历史仍含旧正文',
    );

    // 第 2 轮：指令面 26 万字符撑过触发比；三个实体全部命中——
    // 修复后：沈青梧按全历史排除，新暴露=2 < 3 → 不首拒，轮正常完成
    await controller.sendMessage('${'x' * 260000}，继续写下一幕。');
    expect(
      controller.state.phase,
      IntermediatePhase.idle,
      reason: '压缩前旧实体不计入新暴露（旧口径把投影当全历史会误拒停轮）',
    );
    // durable 终审执行数==2（轮1+轮2 各一次成功提交；旧口径在第 2 轮
    // 首拒，会多一次豁免重提交的 finish_round 执行）
    final ledgerA =
        await AgentEventLogRepository(database: db).readEvents('dir-test-1');
    final finishCountA = ledgerA
        .where(
          (e) =>
              e.type == AgentEventTypes.toolResult &&
              e.data['toolName'] == 'finish_round',
        )
        .length;
    expect(
      finishCountA,
      2,
      reason: '第 2 轮首轮 finish_round 直接通过（未走首拒豁免）',
    );
    controller.dispose();
  });

  test('开启态暴露量闸门：既有事件记忆覆盖的实体不算新暴露', () async {
    await createKeyEntity('陆知远');
    await createKeyEntity('黑潮');
    await createKeyEntity('蚀骨门');
    // 既有事件记忆（5W1E 全文含实体名）——覆盖语义查事件记忆库
    await ExperienceRepositoryImpl(
      database: db,
      vectorEngine: const VectorEngine(),
    ).appendExperience(
      sessionId: 'dir-test-1',
      summary: '陆知远雨夜来访',
      what: '陆知远在雨夜叩门，携黑潮密信。',
      importance: 5,
      tags: const [],
      turnNumber: 1,
    );
    final controller = buildController(
      [
        finishRoundStep(
          'call_b1',
          '陆知远踏着黑潮而来，蚀骨门的气息紧随其后。',
        ),
        // 闸门若误拒，走豁免重提交（消耗第 2 次模型调用）
        finishRoundExemption(
          'call_b1b',
          '陆知远踏着黑潮而来，蚀骨门的气息紧随其后。',
        ),
      ],
      maxSteps: 8,
      withEventLog: true,
      withEngineeringSwitch: true,
    );
    await openEngineeringMode(controller);
    final switched = await controller.setEngineeringContextEnabled(
      enabled: true,
    );
    expect(switched, isTrue);

    await controller.sendMessage('${'x' * 260000}，写下这一幕。');
    // 陆知远被既有记忆覆盖 → 新暴露=2 < 3 → 不首拒
    expect(controller.state.phase, IntermediatePhase.idle);
    // durable 终审执行数==1（旧口径首拒会多一次 finish_round 执行；
    // 轮后标题生成是异步竞态，不可用作计数口径）
    final ledgerB =
        await AgentEventLogRepository(database: db).readEvents('dir-test-1');
    final finishCountB = ledgerB
        .where(
          (e) =>
              e.type == AgentEventTypes.toolResult &&
              e.data['toolName'] == 'finish_round',
        )
        .length;
    expect(
      finishCountB,
      1,
      reason: '记忆覆盖实体不计入新暴露，未走首拒',
    );
    controller.dispose();
  });

  test('开启态暴露量闸门：用户指令不算已登场，真新实体计入并首拒', () async {
    // 前一轮用户指令提到三个实体但正文没有他们登场——指令是「以后可以
    // 安排…这轮不要登场」，不构成已登场证明；下一轮三者首次出现在正文
    // 时必须计为新暴露（闸门漏拦=把指令当已见正文的退化）。
    await createKeyEntity('玄冥老祖');
    await createKeyEntity('黑潮');
    await createKeyEntity('蚀骨门');
    final controller = buildController(
      [
        // 第 1 轮：正文无实体登场（闸门直接放行，一步完成）
        finishRoundStep('prior_finish', '雨停了。门外仍然一片漆黑。'),
        // 第 2 轮：先检索核对三实体（排除证据闸门干扰），再 finish_round
        queryFactsStep('evidence_a', '玄冥老祖'),
        queryFactsStep('evidence_b', '黑潮'),
        queryFactsStep('evidence_c', '蚀骨门'),
        // 首次 finish_round 首拒（可行动 failure），脚本直接重提交豁免放行
        finishRoundStep('call_c1', '玄冥老祖借黑潮驱使蚀骨门压境。'),
        finishRoundExemption(
          'call_c1b',
          '玄冥老祖借黑潮驱使蚀骨门压境。',
        ),
      ],
      maxSteps: 8,
      withEventLog: true,
      withEngineeringSwitch: true,
    );
    await openEngineeringMode(controller);
    final switched = await controller.setEngineeringContextEnabled(
      enabled: true,
    );
    expect(switched, isTrue);

    await controller.sendMessage(
      '以后可以安排玄冥老祖、黑潮与蚀骨门，但这一轮不要让他们登场。',
    );
    expect(controller.state.phase, IntermediatePhase.idle);
    await controller.sendMessage('${'x' * 260000}，写下这一幕。');
    // 三个真新实体 exposure=3 ≥ 3 且触发比已过 → 首拒 → 豁免重提交放行
    expect(controller.state.phase, IntermediatePhase.idle);
    // durable 终审执行数==2：首拒（failure）+ 豁免重提交（成功）——
    // 证明闸门真实拦截（把指令当已见正文的退化时只有 1 次成功提交）
    final ledgerC =
        await AgentEventLogRepository(database: db).readEvents('dir-test-1');
    final finishResults = ledgerC
        .where(
          (e) =>
              e.type == AgentEventTypes.toolResult &&
              e.data['toolName'] == 'finish_round' &&
              e.data['callId'] != 'prior_finish',
        )
        .toList();
    expect(finishResults, hasLength(2));
    expect(finishResults.first.data['isError'], isTrue);
    expect(
      finishResults.first.data['output'],
      contains('终审提醒'),
      reason: '首拒给出可行动反馈（新实体清单）',
    );
    expect(finishResults.first.data['output'], contains('玄冥老祖'));
    expect(finishResults.last.data['isError'], isFalse);
    controller.dispose();
  });

  // ── 开启态自动触发的可靠实报锚点口径 ────────────────────────────
  //
  // 轮前触发估算=可靠实报锚点（末次主请求实报完整输入 ↔ 该次出站面成对
  // 快照）+ 同修订材料差分；无可靠锚点（未上报/指纹失配）才回退本地
  // 字符估算。供应商实报明显大于字符估算时，纯字符口径会显示接近上限
  // 却不提前压缩。

  /// 公共前置：长历史入会话 → 开启工程模式（捕获入账）→ 首轮带实报
  /// usage 完成；返回（控制器、事件仓库、触发前估算）。
  Future<(AdvancedChatController, AgentEventLogRepository, int?)>
      setupMeasuredTriggerTurn(int promptTokens) async {
    final chat = ChatRepositoryImpl(database: db);
    await chat.addMessage(
      ChatMessage(
        messageId: 'old-user',
        sessionId: 'dir-test-1',
        role: 'user',
        content: '旧输入',
        createdAt: DateTime.now(),
      ),
    );
    await chat.addMessage(
      ChatMessage(
        messageId: 'old-prose',
        sessionId: 'dir-test-1',
        role: 'assistant',
        content: '历史材料' * 9000,
        createdAt: DateTime.now(),
      ),
    );
    final controller = buildController(
      [
        withMeasuredUsage(
          finishRoundStep('anchor_a1', '夜色沉下来。'),
          promptTokens,
        ),
        withMeasuredUsage(
          finishRoundExemption('anchor_a2', '夜色沉下来。'),
          promptTokens,
        ),
      ],
      maxSteps: 8,
      withEventLog: true,
      withEngineeringSwitch: true,
    );
    await openEngineeringMode(controller);
    expect(
      await controller.setEngineeringContextEnabled(enabled: true),
      isTrue,
    );
    await controller.sendMessage('继续');
    expect(controller.state.phase, IntermediatePhase.idle);
    final estimate = controller.state.contextEstimate;
    expect(
      estimate?.tokens,
      greaterThanOrEqualTo(promptTokens),
      reason: '轮尾闭合应产出锚点差分预计',
    );
    return (
      controller,
      AgentEventLogRepository(database: db),
      estimate!.tokens,
    );
  }

  test('实报超阈值且有合法可压区间：轮前触发工程压缩', () async {
    final (controller, eventLog, estimate) =
        await setupMeasuredTriggerTurn(25000);
    expect(estimate, isNotNull);
    addTearDown(controller.dispose);
    final before = await eventLog.readEvents('dir-test-1');
    expect(
      before.where((e) => e.type == AgentEventTypes.compactionStart),
      isEmpty,
      reason: '首轮不应触发（触发发生在轮前，首轮无锚点）',
    );
    final window = DirectorSurfaceV2.epochWindowEvents(before);
    final folded = deriveAgentSurfaceSpans(window);
    expect(
      selectCompactionInterval(
        windowEvents: window,
        spans: folded.spans,
        projectionMessages:
            DirectorSurfaceV2.epochWindowProjection(before).messages,
        contextWindowTokens: 32000,
        tuning: const EngineeringCompactionTuning(),
      ),
      isNotNull,
      reason: '存在合法非空可压区间',
    );
    expect(
      estimate,
      greaterThan(
        compactionThresholdTokens(
          contextWindowTokens: 32000,
          retrievalRatio: 0.15,
          tuning: const EngineeringCompactionTuning(outputReserveTokens: 4096),
        ),
      ),
      reason: '实报锚点 25K+差分已过阈值（32000−max(4096,4800)−8192=19008）；'
          ' 纯字符口径不会触发',
    );
    await controller.sendMessage('继续');
    final after = await eventLog.readEvents('dir-test-1');
    expect(
      after.where((e) => e.type == AgentEventTypes.compactionStart),
      isNotEmpty,
      reason: '实报 25K+差分超过阈值必须触发轮前压缩；字符估算不得覆盖它',
    );
  });

  test('实报在阈值下：轮前不触发压缩', () async {
    final (controller, eventLog, _) = await setupMeasuredTriggerTurn(5000);
    addTearDown(controller.dispose);
    await controller.sendMessage('继续');
    final after = await eventLog.readEvents('dir-test-1');
    expect(
      after.where((e) => e.type == AgentEventTypes.compactionStart),
      isEmpty,
      reason: '实报 5K+差分在阈值下不得触发压缩',
    );
    expect(controller.state.phase, IntermediatePhase.idle);
  });

  for (final (ratio, triggerTokens, shouldCompact) in [
    (0.30, 9600, true),
    (0.80, 19712, false),
  ]) {
    test('工程上下文按保存的比例 $ratio 触发压缩并反映在用量详情', () async {
      final (controller, eventLog, _) = await setupMeasuredTriggerTurn(14000);
      addTearDown(controller.dispose);
      final session = controller.state.session;
      expect(
        await controller.updateSession(
          session.copyWith(compactionTriggerRatioOverride: ratio),
        ),
        isTrue,
      );
      final persisted =
          await ChatRepositoryImpl(database: db).getSession(session.sessionId);
      expect(persisted.compactionTriggerRatioOverride, ratio);
      await controller.sendMessage('继续');
      final events = await eventLog.readEvents(session.sessionId);
      expect(
        events.any((event) => event.type == AgentEventTypes.compactionStart),
        shouldCompact,
      );
      expect(controller.state.compactionTriggerTokens, triggerTokens);
    });
  }

  test('触发压缩提交后：预计按新材料下降', () async {
    // 摘要器可提交（保尾压到最小让区间覆盖旧正文）；第 1 轮实报 25K
    // 触发压缩，提交后第 2 轮跑在新材料上（真实供应商形态：压缩后输入
    // 实报显著回落）——轮尾闭合按新材料锚点差分，预计随之下降
    final chat = ChatRepositoryImpl(database: db);
    await chat.addMessage(
      ChatMessage(
        messageId: 'old-user',
        sessionId: 'dir-test-1',
        role: 'user',
        content: '旧输入',
        createdAt: DateTime.now(),
      ),
    );
    await chat.addMessage(
      ChatMessage(
        messageId: 'old-prose',
        sessionId: 'dir-test-1',
        role: 'assistant',
        content: '历史材料' * 100,
        createdAt: DateTime.now(),
      ),
    );
    // 第 1 轮实报 30K（须过本配置下的触发阈值 32000−max(4096,检索预留)
    // −500≈27404）；提交后第 2 轮跑在新材料上，实报回落 3K
    final controller = buildController(
      [
        withMeasuredUsage(finishRoundStep('anchor_a1', '夜色沉下来。'), 30000),
        withMeasuredUsage(finishRoundStep('anchor_a2', '天亮了。'), 3000),
      ],
      maxSteps: 8,
      withEventLog: true,
      withEngineeringSwitch: true,
      engineeringSummarizer: const _PlainSummarizer(),
      // 轮前触发与选材都读配置段（runner 每次传配置解析值）：保尾压到
      // 最小让区间覆盖旧正文；输出预留 4096 保持阈值 19008（实报 25K
      // 触发）
      config: const AdvancedConfig(
        engineeringCompaction: AdvancedEngineeringCompactionConfig(
          outputReserveTokens: 4096,
          headroomTokens: 500,
          retainRatio: 0,
          retainMinTokens: 10,
          retainMaxTokens: 10,
          oversizedResultChars: 500,
          degradeHeadChars: 100,
        ),
      ),
    );
    await openEngineeringMode(controller);
    expect(
      await controller.setEngineeringContextEnabled(enabled: true),
      isTrue,
    );
    await controller.sendMessage('继续');
    expect(controller.state.phase, IntermediatePhase.idle);
    final before = controller.state.contextEstimate!.tokens!;
    expect(before, greaterThanOrEqualTo(30000));
    await controller.sendMessage('继续');
    expect(controller.state.phase, IntermediatePhase.idle);
    final events =
        await AgentEventLogRepository(database: db).readEvents('dir-test-1');
    expect(
      events.where((e) => e.type == AgentEventTypes.compactionStart),
      isNotEmpty,
    );
    // 提交而非中止：checkpoint 本体已落账（user/message replace 遮蔽区间）
    expect(
      events.where(
        (e) =>
            e.type == AgentEventTypes.userMessage &&
            e.surfaceOp == AgentSurfaceOpKind.replace,
      ),
      isNotEmpty,
      reason: '压缩须真实提交（非仅触发）',
    );
    final after = controller.state.contextEstimate?.tokens;
    expect(after, isNotNull);
    expect(
      after,
      lessThan(before),
      reason: '压缩提交移除被压材料、并入纪要：第 2 轮实报与闭合差分都基于'
          ' 新材料，预计按新材料下降（3K 量级 vs 压缩前 30K）',
    );
    controller.dispose();
  });

  test('手动压缩接线：实际工具目录、协议 wire、冻结前缀与摘要共享前部契约', () async {
    // 先真实完成一轮：轮请求体里的工具目录 = 主对话实际目录（对账基准）
    final recorder = _RecordingEngineeringSummarizer();
    final recording = _RecordingEngineeringCompactionService(
      database: db,
      eventRepository: AgentEventLogRepository(database: db),
      chatRepository: ChatRepositoryImpl(database: db),
      experienceRepository: ExperienceRepositoryImpl(
        database: db,
        vectorEngine: const VectorEngine(),
      ),
      summarizer: recorder,
    );
    final bodies = <String>[];
    final controller = buildController(
      [finishRoundStep('call_m1', '夜色沉下来。')],
      withEventLog: true,
      withEngineeringSwitch: true,
      engineeringServiceOverride: recording,
      // 保尾压到最小：单轮材料也可压缩（手动 force 语义不检查阈值，
      // 但选材仍按配置段保尾预算执行）
      config: const AdvancedConfig(
        engineeringCompaction: AdvancedEngineeringCompactionConfig(
          outputReserveTokens: 4096,
          headroomTokens: 500,
          retainRatio: 0,
          retainMinTokens: 10,
          retainMaxTokens: 10,
          oversizedResultChars: 500,
          degradeHeadChars: 100,
        ),
      ),
      // manualCompact 的故事服务前置守卫（开启态不消费它，但入口要求
      // 已配置——生产 DI 两者恒齐备）
      compactionService: _ImmediateCompactionService(
        ChatMessage(
          messageId: 'unused-story-summary',
          sessionId: 'dir-test-1',
          role: 'system',
          content: '不消费的桩',
          isSummary: true,
          createdAt: DateTime(2026),
        ),
      ),
      bodyLog: bodies,
    );
    await openEngineeringMode(controller);
    expect(
      await controller.setEngineeringContextEnabled(enabled: true),
      isTrue,
    );
    await controller.sendMessage('推进剧情');
    expect(controller.state.phase, IntermediatePhase.idle);

    final body = jsonDecode(bodies.first) as Map<Object?, Object?>;
    final roundFunctions = [
      for (final t
          in (body['tools']! as List<Object?>).cast<Map<Object?, Object?>>())
        t['function']! as Map<Object?, Object?>,
    ];
    final roundToolNames = [
      for (final f in roundFunctions) f['name']! as String,
    ];
    expect(roundToolNames, isNotEmpty);

    final result = await controller.manualCompact();
    expect(result, ManualCompactResult.success);

    // 工具目录与轮请求完全一致（deny 集也同源；description 一并对账——
    // read_skill 的描述文本随技能清单生成，两路须同一来源）
    expect(
      [for (final t in recording.lastTools!) t.name],
      roundToolNames,
      reason: '手动压缩选材与摘要请求须用主对话实际工具目录',
    );
    expect(
      [for (final t in recording.lastTools!) t.description],
      [for (final f in roundFunctions) f['description']! as String],
      reason: '工具定义面（含描述文本）与轮请求完全一致',
    );
    // 协议 wire 面：openaiCompatible 会话走 openai 形态（reasoning_content 开）
    expect(recording.lastWireOptions!.openaiReasoningContent, isTrue);
    expect(recording.lastWireOptions!.anthropicExtras, isFalse);
    // 冻结前缀：与账本最新冻结前缀字符数一致且非零（固定面计入选材）
    final events =
        await AgentEventLogRepository(database: db).readEvents('dir-test-1');
    final frozen = DirectorSurfaceV2.latestFrozenPrefixOf(events);
    expect(frozen, isNotNull);
    expect(recording.lastFrozenPrefixChars, frozen!.length);
    expect(recording.lastFrozenPrefixChars, greaterThan(0));
    // 摘要请求共享前部契约：summarizer 收到同一工具目录与区间消息
    expect(
      [for (final t in recorder.lastTools!) t.name],
      roundToolNames,
      reason: '摘要请求携带主对话工具目录（共享前部契约）',
    );
    expect(recorder.lastIntervalMessages, isNotEmpty);
    controller.dispose();
  });

  group('单槽待发消息', () {
    test('已有收稿的会话写入待发时，编辑框清空不会擦掉待发', () async {
      const queuedInput = '已经接收的待发输入';
      final repo =
          _PausedDraftWriteRepository(database: db, input: queuedInput);
      final session = await repo.createSession(title: '已有导演', mode: 'advanced');
      final initial = buildController(
        [
          finishRoundStep('initial', '已收稿的正文'),
          finishRoundExemption('initial-again', '已收稿的正文'),
        ],
        restoredSession: session,
        chatRepository: repo,
      );
      expect(await initial.sendMessage('已收稿的输入'), isTrue);
      expect(initial.state.session.nextTurn, 2);
      initial.dispose();

      final controller = buildController(
        const [],
        restoredSession: await repo.getSession(session.sessionId),
        hangAt: 0,
        chatRepository: repo,
      );
      addTearDown(controller.dispose);
      final current = controller.sendMessage('正在进行的下一轮');
      await hangClient.hangFired.future.timeout(const Duration(seconds: 5));
      final queued = controller.sendMessage(queuedInput);
      try {
        await repo.writeStarted.future.timeout(const Duration(seconds: 5));
        final cleared = controller.persistInputDraft(null);
        repo.releaseWrite.complete();
        expect(await queued, isTrue);
        await cleared;
        expect(await repo.getSessionDraft(session.sessionId), queuedInput);
        expect(
          (await repo.getDirectorInputs(session.sessionId)).queued,
          isNull,
        );
      } finally {
        if (!repo.releaseWrite.isCompleted) repo.releaseWrite.complete();
        await controller.cancel();
        await current;
      }
    });

    test('冷开首句后加入待发，收稿失败重开可分开续写两轮', () async {
      final directory =
          await Directory.systemTemp.createTemp('director-queue-');
      databaseDirectory = directory;
      final file = File('${directory.path}/director.sqlite');
      await db.close();
      db = AppDatabase.forTesting(NativeDatabase(file));
      const first = '第一封信漂到桥洞。\n封口有泥。';
      const queued = '随后把第二封信送过河。';
      const firstProse = '第一封信被桥下的人捞起来。';
      const nextProse = '邮差将第二封信交给渡船上的人。';
      final gm = _ToggleGmResolver();
      final initial = buildController(
        const [],
        resolver: gm,
        sessionId: '${AdvancedChatController.draftSessionIdPrefix}queue',
      );
      expect(await initial.sendMessage(first), isTrue);
      expect(initial.state.failureContext?.errorCode, 'E010');
      final id = initial.state.session.sessionId;
      initial.dispose();
      await db.close();

      db = AppDatabase.forTesting(NativeDatabase(file));
      final firstResponse = finishRoundStep('a', firstProse);
      final restored = await ChatRepositoryImpl(database: db).getSession(id);
      final controller = buildController(
        [firstResponse, finishRoundExemption('ax', firstProse)],
        resolver: gm,
        restoredSession: restored,
        hangAt: 0,
      );
      await controller.loadHistory();
      expect(controller.state.pendingUserMessage?.content, first);
      expect(controller.state.queuedMessage, isNull);
      await db.customStatement(
        'CREATE TRIGGER reject_first_assistant BEFORE INSERT ON chat_messages '
        "WHEN new.role = 'assistant' BEGIN "
        "SELECT RAISE(ABORT, 'synthetic persistence failure'); END",
      );
      gm.gmConfigured = true;
      final recovery = controller.continueFromFailed();
      await hangClient.hangFired.future.timeout(const Duration(seconds: 5));
      expect(await controller.sendMessage(queued), isTrue);
      hangClient
        ..hangResponse = firstResponse
        ..hangReleased = true;
      await recovery;
      expect(controller.state.failureContext?.errorCode, 'E018');
      expect(controller.state.queuedMessage, queued);
      expect(await ChatRepositoryImpl(database: db).getMessages(id), isEmpty);
      controller.dispose();
      await db.close();

      db = AppDatabase.forTesting(NativeDatabase(file));
      final repo = ChatRepositoryImpl(database: db);
      await db.customStatement('DROP TRIGGER reject_first_assistant');
      expect(
        await repo.getDirectorInputs(id),
        (pending: first, queued: queued),
      );
      final requests = <String>[];
      final reopened = buildController(
        [
          finishRoundStep('a2', firstProse),
          finishRoundExemption('a2x', firstProse),
          finishRoundStep('b2', nextProse),
          finishRoundExemption('b2x', nextProse),
        ],
        resolver: gm,
        restoredSession: await repo.getSession(id),
        bodyLog: requests,
      );
      addTearDown(reopened.dispose);
      await reopened.loadHistory();
      expect(reopened.state.pendingUserMessage?.content, first);
      expect(reopened.state.queuedMessage, queued);
      expect(reopened.state.phase, IntermediatePhase.failed);

      await reopened.continueFromFailed();
      expect(
        await until(() => reopened.state.session.nextTurn == 3),
        isTrue,
      );
      final messages = await repo.getMessages(id);
      expect(messages.map((m) => (m.role, m.content)), [
        ('user', first),
        ('assistant', firstProse),
        ('user', queued),
        ('assistant', nextProse),
      ]);
      expect(await repo.getDirectorInputs(id), (pending: null, queued: null));
      expect((await repo.getSession(id)).nextTurn, 3);
      expect(requests, hasLength(4));
      for (var i = 0; i < requests.length; i++) {
        final body = jsonDecode(requests[i]) as Map<String, dynamic>;
        final users = (body['messages'] as List<dynamic>)
            .cast<Map<String, dynamic>>()
            .where((message) => message['role'] == 'user');
        final input = i < 2 ? first : queued;
        expect(users.where((m) => m['content'] == input), hasLength(1));
        if (i < 2) {
          expect(users.where((m) => m['content'] == queued), isEmpty);
        }
      }
    });

    test('收稿事务失败时保留待发和草稿，后台不会派发', () async {
      final requests = <String>[];
      final repo = ChatRepositoryImpl(database: db);
      final session = await repo.createSession(title: '已有导演', mode: 'advanced');
      await db.customStatement(
        'CREATE TRIGGER reject_test_assistant BEFORE INSERT ON chat_messages '
        "WHEN new.role = 'assistant' BEGIN "
        "SELECT RAISE(ABORT, 'synthetic persistence failure'); END",
      );
      final response = finishRoundStep('first', '首轮正文');
      final controller = buildController(
        [response, finishRoundExemption('exempt', '首轮正文')],
        sessionId: session.sessionId,
        hangAt: 0,
        bodyLog: requests,
      );
      addTearDown(controller.dispose);
      final first = controller.sendMessage('首轮输入');
      await hangClient.hangFired.future;
      expect(await controller.sendMessage('保留待发'), isTrue);

      hangClient
        ..hangResponse = response
        ..hangReleased = true;
      expect(await first, isTrue);
      expect(controller.state.phase, IntermediatePhase.failed);
      expect(controller.state.failureContext?.errorCode, 'E018');
      expect(controller.state.queuedMessage, '保留待发');
      expect((await repo.getDirectorInputs(session.sessionId)).queued, '保留待发');
      expect(await repo.getMessages(session.sessionId), isEmpty);
      expect(requests, hasLength(2));
    });

    test('停止后待发仍归原草稿，覆盖快照与写入期间拒绝新轮', () async {
      final guard = DataStoreOperationGuard();
      final repo = ChatRepositoryImpl(database: db);
      final requests = <String>[];
      final session = await repo.createSession(title: '已有导演', mode: 'advanced');
      final controller = buildController(
        const [],
        sessionId: session.sessionId,
        hangAt: 0,
        bodyLog: requests,
        withEventLog: true,
        operationGuard: guard,
      );
      addTearDown(controller.dispose);
      final first = controller.sendMessage('被停止的一轮');
      await hangClient.hangFired.future;
      expect(await controller.sendMessage('原待发'), isTrue);
      await controller.cancel();
      await first;
      expect(await until(() => !controller.state.isStopping), isTrue);
      await controller.clearRound();
      expect(controller.state.queuedMessage, '原待发');

      final backupRepo = PausedBackupRestore(database: db);
      final service = DataManagementService(
        chatRepository: repo,
        presetRepository: _StubPresetRepo(),
        settingsRepository: _ThrowingSettingsRepo(),
        backupRepository: backupRepo,
        operationGuard: guard,
      );
      const payload = '{"version":3,"sessions":[{"session":'
          '{"session_id":"restore-dir","title":"Restored","mode":"advanced"}}]}';
      final snapshotEntered = Completer<void>();
      final snapshotResume = Completer<void>();
      String? draftInSnapshot;
      final restore = service.importBackup(
        payload,
        ImportMode.overwrite,
        preImportSnapshot: () async {
          snapshotEntered.complete();
          await snapshotResume.future;
          draftInSnapshot =
              (await repo.getDirectorInputs(session.sessionId)).queued;
        },
      );
      try {
        await snapshotEntered.future;
        await controller.dispatchQueuedMessageAfterRound();
        expect(await controller.sendMessage('保留输入'), isFalse);
        expect(controller.state.queuedMessage, '原待发');
        expect(backupRepo.deletes, 0);
        expect(backupRepo.writes, 0);
        snapshotResume.complete();
        await backupRepo.entered.future;
        expect(draftInSnapshot, '原待发');
        await controller.dispatchQueuedMessageAfterRound();
        expect(await controller.sendMessage('保留输入'), isFalse);
        expect(controller.state.queuedMessage, '原待发');
        expect(controller.state.pendingUserMessage, isNull);
        expect(backupRepo.deletes, 1);
        expect(backupRepo.writes, 1);
      } finally {
        if (!snapshotResume.isCompleted) snapshotResume.complete();
        backupRepo.resume.complete();
      }
      expect((await restore).importedSessions, 1);
      expect((await repo.getAllSessions()).single.sessionId, 'restore-dir');
      expect(await repo.getMessages('restore-dir'), isEmpty);
      expect(requests, hasLength(1));
    });

    test('正常收稿后等事件日志收尾，待发只启动一轮', () async {
      final guard = DataStoreOperationGuard();
      final eventLog = _PausedResumeEventLog(database: db);
      final firstResponse = finishRoundStep('first', '首轮正文');
      final repo = ChatRepositoryImpl(database: db);
      final session = await repo.createSession(title: '已有导演', mode: 'advanced');
      final controller = buildController(
        [
          firstResponse,
          finishRoundExemption('first_again', '首轮正文'),
          finishRoundStep('second', '待发轮正文'),
          finishRoundExemption('second_again', '待发轮正文'),
        ],
        sessionId: session.sessionId,
        hangAt: 0,
        eventLogRepository: eventLog,
        operationGuard: guard,
      );
      addTearDown(controller.dispose);
      final service = DataManagementService(
        chatRepository: repo,
        presetRepository: _StubPresetRepo(),
        settingsRepository: _ThrowingSettingsRepo(),
        backupRepository: BackupRepositoryImpl(database: db),
        operationGuard: guard,
      );
      const backup = '{"version":3,"sessions":[{"session":'
          '{"session_id":"restored","title":"Restored"}}]}';
      var snapshots = 0;
      Future<void> expectBusy() => expectLater(
            service.importBackup(
              backup,
              ImportMode.overwrite,
              preImportSnapshot: () async => snapshots++,
            ),
            throwsA(isA<BackupOverwriteBusyException>()),
          );

      final first = controller.sendMessage('首轮输入');
      await hangClient.hangFired.future;
      expect(await controller.sendMessage('待发输入'), isTrue);
      expect((await repo.getDirectorInputs(session.sessionId)).queued, '待发输入');
      await expectBusy();

      eventLog
        ..trimEntered = Completer<void>()
        ..trimResume = Completer<void>();
      hangClient
        ..hangResponse = firstResponse
        ..hangReleased = true;
      await eventLog.trimEntered?.future;
      try {
        expect(controller.state.phase, IntermediatePhase.idle);
        await controller.dispatchQueuedMessageAfterRound();
        expect(controller.state.queuedMessage, '待发输入');
        expect(
          (await repo.getDirectorInputs(session.sessionId)).queued,
          '待发输入',
        );
        await expectBusy();
        final messages = await repo.getMessages(session.sessionId);
        expect(messages.map((message) => message.content), ['首轮输入', '首轮正文']);
        expect(snapshots, 0);
      } finally {
        eventLog.trimResume?.complete();
      }
      expect(await first, isTrue);
      expect(await until(() => controller.state.messages.length == 4), isTrue);
      expect(controller.state.queuedMessage, isNull);
      expect((await repo.getDirectorInputs(session.sessionId)).queued, isNull);
      final committed = await repo.getMessages(session.sessionId);
      expect(committed.map((message) => message.content), [
        '首轮输入',
        '首轮正文',
        '待发输入',
        '待发轮正文',
      ]);
      final events = await eventLog.readEvents(session.sessionId);
      expect(
        events.where((event) => event.type == AgentEventTypes.turnBegin),
        hasLength(2),
      );
    });

    test('生成中发送入槽；槽占用不覆盖；停止不自动发；撤回取回文本', () async {
      final controller = buildController(
        [finishRoundExemption('call_q1', '轮一正文。')],
        hangAt: 0,
      );
      unawaited(controller.sendMessage('第一条指令'));
      await hangClient.hangFired.future.timeout(const Duration(seconds: 20));
      expect(
        await until(
          // 导演轮运行相位 = reviewing（无六步 phase）
          () => controller.state.phase == IntermediatePhase.reviewing,
        ),
        isTrue,
      );

      // 生成中发送 → 入槽（不插入当前轮）
      final queued = await controller.sendMessage('排队内容');
      expect(queued, isTrue);
      expect(controller.state.queuedMessage, '排队内容');

      // 槽位已占用且未确认覆盖 → 拒收且不覆盖
      final occupied = await controller.sendMessage('第二条');
      expect(occupied, isFalse);
      expect(controller.state.queuedMessage, '排队内容');

      // 撤回：取回文本，槽清空，草稿列清空
      final withdrawn = await controller.withdrawQueuedMessage();
      expect(withdrawn, '排队内容');
      expect(controller.state.queuedMessage, isNull);

      // 重新入槽后停止轮：队列保留（不自动发不丢）
      await controller.sendMessage('保留的排队');
      expect(controller.state.queuedMessage, '保留的排队');
      await controller.cancel();
      expect(
        await until(
          () =>
              controller.state.phase == IntermediatePhase.failed &&
              !controller.state.isStopping,
        ),
        isTrue,
      );
      expect(
        controller.state.queuedMessage,
        '保留的排队',
        reason: '失败/停止不自动发送，也不清空队列',
      );

      controller.dispose();
    });

    test('轮正常结束后派发一次：清槽并发送排队内容', () async {
      final controller = buildController(
        [
          finishRoundExemption('call_h1', '挂住的正文。'),
          finishRoundExemption('call_q2', '排队轮正文。'),
        ],
        hangAt: 0,
      );
      unawaited(controller.sendMessage('第一条指令'));
      await hangClient.hangFired.future.timeout(const Duration(seconds: 20));
      expect(
        await until(
          // 导演轮运行相位 = reviewing（无六步 phase）
          () => controller.state.phase == IntermediatePhase.reviewing,
        ),
        isTrue,
      );

      await controller.sendMessage('排队内容');
      // 停止失败轮（队列保留），清空本轮回 idle
      await controller.cancel();
      expect(
        await until(
          () =>
              controller.state.phase == IntermediatePhase.failed &&
              !controller.state.isStopping,
        ),
        isTrue,
      );
      await controller.clearRound();
      expect(controller.state.phase, IntermediatePhase.idle);
      expect(controller.state.queuedMessage, '排队内容');

      // 派发：清槽 + 以排队内容开启新轮（脚本第二条收口）
      await controller.dispatchQueuedMessageAfterRound();
      expect(
        controller.state.queuedMessage,
        isNull,
        reason: '派发先清槽，至多发送一次',
      );
      expect(
        await until(
          () =>
              controller.state.phase == IntermediatePhase.idle &&
              controller.state.messages.isNotEmpty,
        ),
        isTrue,
      );
      // 排队内容作为新一轮用户输入落库
      final messages = await db.customSelect(
        'SELECT role, content FROM chat_messages WHERE session_id = ? '
        'ORDER BY created_at ASC',
        variables: [Variable.withString('dir-test-1')],
      ).get();
      expect(
        messages.map((m) => m.read<String>('content')).toList(),
        contains('排队内容'),
      );

      controller.dispose();
    });

    test('重生成准备期拒收：返回 false 且不留排队', () async {
      final controller = buildController(const []);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      // 直接构造准备中状态：regenerateMessage 的前置置位需消息对，
      // 此处用 state 校验路径——控制器守卫按 isPreparingRegenerate 拒收
      controller.state = controller.state.copyWith(
        isPreparingRegenerate: true,
      );
      final consumed = await controller.sendMessage('不应进入排队');
      expect(consumed, isFalse);
      expect(controller.state.queuedMessage, isNull);

      controller.dispose();
    });
  });

  group('长会话大周期维护取消收敛', () {
    test('任务二维护期取消：持久化任务一锁定正文与已暂存变更，重置维护状态', () async {
      final chatRepo = ChatRepositoryImpl(database: db);
      final factualRepo = FactualRepositoryImpl(database: db);
      final session = await _seedDirectorHistory(
        db,
        49,
        sessionId: 'dir-maint-cancel-1',
      );
      await factualRepo.createEntity(
        FactualEntity(
          entityId: 'ent_maint_cancel',
          sessionId: session.sessionId,
          type: FactualEntityType.character,
          primaryName: '林晚',
          aliases: const [],
          importance: 2,
          createdTurn: 1,
          createdAt: DateTime(2026),
        ),
      );

      final step1Event = sse([
        toolCallStart(
          0,
          'c_ev',
          'record_event_memory',
          jsonEncode({'what': '主角突破防线', 'importance': 4}),
        ),
        finish('tool_calls'),
        '[DONE]',
      ]);
      final step2FinishRound = finishRoundStep('c_lock', '第五十轮已锁定正文内容。');
      final step3Update = sse([
        toolCallStart(
          0,
          'c_upd',
          'update_facts',
          jsonEncode({
            'deltas': [
              {
                'action': 'set_importance',
                'entity_id': 'ent_maint_cancel',
                'importance': 5,
                'confidence': 5,
                'reason': '关键人物晋升',
              },
            ],
          }),
        ),
        finish('tool_calls'),
        '[DONE]',
      ]);
      final step4Hanging = sse([
        toolCallStart(0, 'c_list', 'list_facts', '{}'),
        finish('tool_calls'),
        '[DONE]',
      ]);

      final controller = buildController(
        [step1Event, step2FinishRound, step3Update, step4Hanging],
        restoredSession: session,
        hangAt: 3,
      );
      addTearDown(controller.dispose);
      await controller.loadHistory();

      final sendFuture = controller.sendMessage('推进第五十轮');
      await hangClient.hangFired.future.timeout(const Duration(seconds: 20));

      expect(controller.state.inMaintenancePhase, isTrue);
      expect(controller.state.maintenanceStepStart, greaterThan(0));

      await controller.cancel();
      await sendFuture;
      expect(await until(() => !controller.state.isStopping), isTrue);

      expect(controller.state.phase, IntermediatePhase.idle);
      expect(controller.state.failureContext, isNull);
      expect(controller.state.inMaintenancePhase, isFalse);
      expect(controller.state.maintenanceStepStart, 0);
      expect(controller.state.messages, hasLength(100));
      expect(controller.state.messages.skip(98).map((m) => m.content), [
        '推进第五十轮',
        '第五十轮已锁定正文内容。',
      ]);

      final persistedMsgs = await chatRepo.getMessages(session.sessionId);
      expect(persistedMsgs, hasLength(100));
      expect(persistedMsgs.skip(98).map((m) => m.content), [
        '推进第五十轮',
        '第五十轮已锁定正文内容。',
      ]);
      final updatedEntity = await factualRepo.getEntityById('ent_maint_cancel');
      expect(updatedEntity?.importance, 5);
    });
  });
}

/// 只记录 applyCharacterCard 调用（其余接口 noSuchMethod 兜底）。
class _RecordingApplyService implements ResourceApplyService {
  _RecordingApplyService(this.calls);

  final List<String> calls;

  @override
  Future<int> applyCharacterCard({
    required String sessionId,
    required String cardId,
    required String defaultCharacterName,
    required String duplicateErrorMessage,
    String? defaultSettingName,
  }) async {
    calls.add(cardId);
    return 3;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// 固定摘要桩（手动压缩用：正文不含实体名，宏记忆不构成记忆覆盖）
class _PlainSummarizer implements EngineeringSummarizer {
  const _PlainSummarizer();

  @override
  Future<EngineeringSummaryOutput> summarize({
    required String sessionId,
    required List<AgentMessage> intervalMessages,
    required int narrativeBoundaryTurn,
    required List<ToolDefinition> tools,
    required void Function(String delta)? onDelta,
  }) async =>
      const EngineeringSummaryOutput(
        summary: '压缩纪要：材料已概括。',
        narrativeSection: '已完成的剧情梗概。',
      );
}

/// 压缩摘要桩：测试轮不触发压缩（阈值未达）；万一触发则显式失败
class _ThrowingSummarizer implements EngineeringSummarizer {
  @override
  Future<EngineeringSummaryOutput> summarize({
    required String sessionId,
    required List<AgentMessage> intervalMessages,
    required int narrativeBoundaryTurn,
    required List<ToolDefinition> tools,
    required void Function(String delta)? onDelta,
  }) async =>
      throw UnimplementedError('compaction not expected in this test');
}

// ── 手动入口与自动/溢出共用面（工具目录/wire/冻结前缀）────────────
//
// 手动压缩三入口共用：实际工具目录（与轮装配同一构建器/权限求值）、
// 当前协议 wire 面、账本最新冻结前缀（固定面不进投影但进请求）；
// 摘要请求共享前部契约（system=冻结前缀+tools）同样适用。

/// 记录 compact() 入参后委托原实现
class _RecordingEngineeringCompactionService
    extends EngineeringCompactionService {
  _RecordingEngineeringCompactionService({
    required super.database,
    required super.eventRepository,
    required super.chatRepository,
    required super.experienceRepository,
    required super.summarizer,
  });

  List<ToolDefinition>? lastTools;
  AgentWireOptions? lastWireOptions;
  int? lastFrozenPrefixChars;
  Object? lastError;
  String? lastOutcome;
  String? lastReason;

  @override
  Future<EngineeringCompactionResult> compact({
    required String sessionId,
    required String trigger,
    required int contextWindowTokens,
    required double retrievalRatio,
    List<ToolDefinition> tools = const [],
    EngineeringCompactionTuning? tuning,
    CancellationToken? cancelToken,
    void Function(String delta)? onDelta,
    AgentWireOptions wireOptions = const AgentWireOptions(),
    int frozenPrefixChars = 0,
  }) async {
    lastTools = tools;
    lastWireOptions = wireOptions;
    lastFrozenPrefixChars = frozenPrefixChars;
    try {
      final result = await super.compact(
        sessionId: sessionId,
        trigger: trigger,
        contextWindowTokens: contextWindowTokens,
        retrievalRatio: retrievalRatio,
        tools: tools,
        tuning: tuning,
        cancelToken: cancelToken,
        onDelta: onDelta,
        wireOptions: wireOptions,
        frozenPrefixChars: frozenPrefixChars,
      );
      lastOutcome = result.outcome;
      lastReason = result.reason;
      return result;
    } catch (e) {
      lastError = e;
      rethrow;
    }
  }
}

/// 记录 summarize() 收到的工具目录与区间消息
class _RecordingEngineeringSummarizer implements EngineeringSummarizer {
  List<ToolDefinition>? lastTools;
  List<AgentMessage>? lastIntervalMessages;

  @override
  Future<EngineeringSummaryOutput> summarize({
    required String sessionId,
    required List<AgentMessage> intervalMessages,
    required int narrativeBoundaryTurn,
    required List<ToolDefinition> tools,
    required void Function(String delta)? onDelta,
  }) async {
    lastTools = tools;
    lastIntervalMessages = intervalMessages;
    // 提交侧要求摘要文本含叙事段标记（正文资产只写验证过的段）
    return const EngineeringSummaryOutput(
      summary: '压缩纪要：材料已概括。\n【已完成剧情梗概】已完成的剧情梗概。',
      narrativeSection: '已完成的剧情梗概。',
    );
  }
}
