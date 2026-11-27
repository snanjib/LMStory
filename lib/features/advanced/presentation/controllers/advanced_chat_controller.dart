import 'dart:async';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/config/output_token_policy.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/llm/tool_calling/provider_tool_capabilities.dart';
import 'package:lmstory/core/services/data_store_operation_guard.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/throttled_delta_buffer.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/features/advanced/data/engineering_compaction_service.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_live_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/domain/entities/director_resume_context.dart';
import 'package:lmstory/features/advanced/domain/entities/director_round_tuning.dart';
import 'package:lmstory/features/advanced/domain/entities/retrieval_profile.dart';
import 'package:lmstory/features/advanced/domain/entities/tool_permissions.dart';
import 'package:lmstory/features/advanced/domain/services/agent_log_recovery.dart';
import 'package:lmstory/features/advanced/domain/services/compaction_planning.dart';
import 'package:lmstory/features/advanced/domain/services/director_core_blocks.dart';
import 'package:lmstory/features/advanced/domain/services/director_surface_v2.dart';
import 'package:lmstory/features/advanced/domain/services/engineering_context_mode.dart';
import 'package:lmstory/features/advanced/domain/services/latest_usage_probe.dart';
import 'package:lmstory/features/advanced/domain/services/trajectory_binding.dart';
import 'package:lmstory/features/advanced/domain/services/variant_trajectory.dart';
import 'package:lmstory/features/advanced/presentation/controllers/director_host.dart';
import 'package:lmstory/features/advanced/presentation/controllers/director_round_runner.dart';
import 'package:lmstory/features/advanced/presentation/controllers/director_work_trace.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_mode.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session_settings.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/diagnostics/domain/repositories/failure_log_repository.dart';
import 'package:lmstory/features/intermediate/presentation/controllers/intermediate_chat_controller.dart'
    show IntermediateChatController;
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart'
    show ExperienceRepositoryImpl;
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';
import 'package:lmstory/features/memory/domain/services/embedding_service.dart';
import 'package:lmstory/features/memory/domain/services/memory_index_health.dart';
import 'package:lmstory/features/memory/domain/services/memory_retrieval_exception.dart';
import 'package:lmstory/features/resource_library/domain/services/resource_apply_service.dart';
import 'package:lmstory/features/story_runtime/domain/entities/auxiliary_generation_failure.dart';
import 'package:lmstory/features/story_runtime/domain/entities/context_usage_estimate.dart';
import 'package:lmstory/features/story_runtime/domain/entities/message_variant_record.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_context.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_runtime_config.dart';
import 'package:lmstory/features/story_runtime/domain/services/compaction_service.dart';
import 'package:lmstory/features/story_runtime/domain/services/failure_classifier.dart';
import 'package:lmstory/features/story_runtime/domain/services/manual_compact_result.dart';
import 'package:lmstory/features/story_runtime/domain/services/memory_consolidator.dart';
import 'package:lmstory/features/story_runtime/domain/services/memory_embedding_text.dart';
import 'package:lmstory/features/story_runtime/domain/services/persistence_service.dart';
import 'package:lmstory/features/story_runtime/domain/services/retry_scheduler.dart';
import 'package:lmstory/features/story_runtime/domain/services/round_history_utils.dart';
import 'package:lmstory/features/story_runtime/domain/services/session_title_generator.dart';
import 'package:lmstory/features/story_runtime/domain/services/suggest_reply_generator.dart';
import 'package:lmstory/features/story_runtime/presentation/controllers/story_session_operations.dart';
import 'package:lmstory/features/story_runtime/presentation/controllers/stream_runner.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:uuid/uuid.dart';

part 'advanced_chat_controller_consolidation.dart';
part 'advanced_chat_controller_embeddings.dart';
part 'advanced_chat_controller_messages.dart';
// P2 解耦：导演模式独立控制器。原寄生在 IntermediateChatController 的
// agent part / advanced 分支迁出；消息操作/重试/持久化/推荐回复/记忆提炼/
// embedding 辅助等与故事模式同源的骨架逻辑受控复制（不搞继承），由
// [DirectorRoundRunner] 替代六步管线作为生成内核。
//
// 骨架 part 文件按职责划分（同 IntermediateChatController 的  拆分）：
// - _persist.dart：persisting 阶段（DB 事务写入，导演产物随 artifacts 持久化）
// - _retry.dart：失败处理 + 自动重试 + 手动续跑
// - _messages.dart：消息操作 + 简化 Fork
// - _suggest.dart：推荐回复气泡
// - _consolidation.dart：批量记忆提炼
// - _embeddings.dart：embedding 辅助
part 'advanced_chat_controller_persist.dart';
part 'advanced_chat_controller_retry.dart';
part 'advanced_chat_controller_suggest.dart';

typedef DirectorTitleUpdateResult = ({
  bool updated,
  AuxiliaryGenerationFailure? failure
});

/// 导演模式聊天控制器（v0.3 kernel swap 的 P2 解耦形态）
///
/// 状态机与故事模式共享 IntermediatePhase 原语；生成内核为
/// [DirectorRoundRunner]（AgentRunner 自主循环），产出写回 RoundContext
/// 后复用故事持久化事务落库——页面、会话设置、记忆查看器、消息操作
/// 与故事模式体验一致。
class AdvancedChatController extends StateNotifier<AdvancedChatState>
    implements DirectorHost {
  AdvancedChatController({
    required ChatRepository chatRepository,
    required ConfigurationResolver configurationResolver,
    required LlmService llmService,
    required ExperienceRepository experienceRepository,
    required EmbeddingService embeddingService,
    required StoryPersistenceService persistenceService,
    required FailureLogRepository failureLogRepository,
    required TokenCounter tokenCounter,
    required Future<AdvancedConfig> Function() getConfig,
    required Logger logger,
    required ChatSession session,
    DataStoreOperationGuard? operationGuard,
    SessionTitleGenerator? titleGenerator,
    MemoryConsolidator? consolidator,
    // 事实层仓库（agent loop 的 query_facts/update_facts 用；
    // nullable 向后兼容旧测试，仅在缺失时 E010）
    FactualRepository? factualRepository,
    // durable 事件日志仓库（事件日志 + 崩溃恢复；nullable 向后兼容旧测试）
    AgentEventLogStore? agentEventLogRepository,
    // 工程上下文模式原子切换（纪元事件+捕获+会话列同库单事务；null =
    // 旧测试环境——开关切换能力不可用，三态解析仍可用）
    EngineeringContextSwitchStore? engineeringContextSwitch,
    // 工程压缩事务服务（开启态轮前/溢出/手动压缩与撤销；null = 不可用）
    EngineeringCompactionService? engineeringCompaction,
    // CompactionPoint 压缩服务（导演轮轮前压缩；null = 未启用）
    StoryCompactionService? compactionService,
    // 资源应用服务（向导「初始化你的角色」卡路径物化时应用；
    // nullable 向后兼容旧测试）
    ResourceApplyService? resourceApplyService,
    // 可选显式能力画像覆盖（Demo 作用域等受控环境注入；null 走生产默认解析）
    ProviderToolCapabilities? capabilitiesOverride,
  })  : _chatRepository = chatRepository,
        _configurationResolver = configurationResolver,
        _llmService = llmService,
        _experienceRepository = experienceRepository,
        _embeddingService = embeddingService,
        _persistenceService = persistenceService,
        _failureLogRepository = failureLogRepository,
        _tokenCounter = tokenCounter,
        _getConfig = getConfig,
        _logger = logger,
        _titleGenerator = titleGenerator,
        _consolidator = consolidator,
        _factualRepository = factualRepository,
        _agentEventLogRepository = agentEventLogRepository,
        _engineeringContextSwitch = engineeringContextSwitch,
        _engineeringCompaction = engineeringCompaction,
        _compactionService = compactionService,
        _resourceApplyService = resourceApplyService,
        _capabilitiesOverride = capabilitiesOverride,
        _sessionOperations =
            StorySessionOperations(operationGuard, session.sessionId),
        _streamRunner = StreamRunner(llmService: llmService),
        super(AdvancedChatState.initial(session)) {
    // 与故事模式一致：构造函数加载历史（会话切换时 State 复用兜底）
    loadHistory();
  }

  final StorySessionOperations _sessionOperations;

  Future<T> _runSessionOperation<T>(
    T rejected,
    Future<T> Function() operation,
  ) async {
    if (!mounted ||
        state.isStopping ||
        state.isManualCompacting ||
        state.isPreparingRegenerate) {
      return rejected;
    }
    return _sessionOperations.run(
      rejected,
      () async {
        if (!mounted || !_historyReady) return rejected;
        return operation();
      },
      afterRelease: _dispatchAfterRelease,
    );
  }

  final ChatRepository _chatRepository;
  final ConfigurationResolver _configurationResolver;

  /// LLM 服务引用（推荐回复等非流式调用点使用）
  final LlmService _llmService;
  final ExperienceRepository _experienceRepository;
  final FactualRepository? _factualRepository;
  final EmbeddingService _embeddingService;
  final StoryPersistenceService _persistenceService;
  final FailureLogRepository _failureLogRepository;
  final TokenCounter _tokenCounter;
  final Future<AdvancedConfig> Function() _getConfig;
  final Logger _logger;

  /// 会话标题生成器（首轮 persist 成功后异步生成简短标题）
  final SessionTitleGenerator? _titleGenerator;

  /// 批量记忆提炼器（上下文 token 超阈值时异步合并低重要性记忆）
  final MemoryConsolidator? _consolidator;

  /// durable agent 事件日志仓库（事件日志 + 崩溃恢复）
  final AgentEventLogStore? _agentEventLogRepository;

  /// 工程上下文模式原子切换通道（进入/退出事务；null = 不可用）
  final EngineeringContextSwitchStore? _engineeringContextSwitch;

  Future<bool>? _engineeringModeChange;

  /// 工程压缩事务服务（开启态；null = 不可用——压缩走旧路径/被禁用）
  final EngineeringCompactionService? _engineeringCompaction;

  /// runner 侧消费（轮前/溢出压缩相位）
  @override
  EngineeringCompactionService? get engineeringCompactionService =>
      _engineeringCompaction;

  /// 工程压缩摘要器的 GM 配置解析（共享前部式请求的模型端点）
  Future<NamingConfig?> resolveAdvancedGeneratingNamingConfigForCompaction() {
    return _configurationResolver.resolveAdvancedGeneratingNamingConfig(
      state.session,
    );
  }

  /// 账本内最新冻结前缀（摘要请求共享前部的 system 段）
  Future<String> latestFrozenPrefixForCompaction() async {
    final repo = agentEventLogRepository;
    if (repo == null) return '';
    try {
      final events = await repo.readEvents(state.session.sessionId);
      return DirectorSurfaceV2.latestFrozenPrefixOf(events) ?? '';
    } catch (_) {
      return '';
    }
  }

  /// CompactionPoint 压缩服务（导演轮轮前压缩）
  final StoryCompactionService? _compactionService;

  /// 资源应用服务（向导「初始化你的角色」卡路径：物化时应用卡）
  final ResourceApplyService? _resourceApplyService;

  /// 可选显式能力画像覆盖（Demo 作用域等受控环境注入；null 走生产默认解析）
  final ProviderToolCapabilities? _capabilitiesOverride;

  /// manualCompact 摘要增量合帧缓冲（见 [_onManualCompactionDelta]）
  ThrottledDeltaBuffer? _manualCompactionDeltaBuffer;

  /// 压缩前的当前预计快照：撤销压缩时原样恢复。
  ///
  /// 撤销可能发生在压缩后又发过新请求之后——此时最近实报已是压缩后的
  /// 上下文，不能再拿来当撤销后的锚点。
  ContextUsageEstimate? _preCompactionEstimate;

  /// 失败分类器：异常 → ErrorCategory 自动分流 + i18n 文案
  final StoryFailureClassifier _classifier = const StoryFailureClassifier();

  /// 重试调度器（无状态纯决策：最大重试次数查询、阶段映射、延迟计算）
  final RetryScheduler _retryScheduler = const RetryScheduler();

  /// 推荐回复生成器（与故事模式同源）
  late final SuggestReplyGenerator _suggestGenerator = SuggestReplyGenerator(
    llmService: _llmService,
    logger: _logger,
  );

  /// 草稿会话的 sessionId 前缀。
  ///
  /// 与 [IntermediateChatController.draftSessionIdPrefix] 保持同一字符串值
  /// （'__draft_intermediate_'）：main_layout 的草稿检测/物化监听按前缀匹配，
  /// 换值会破坏既有草稿会话的识别。
  static const draftSessionIdPrefix = '__draft_intermediate_';

  /// 判断当前会话是否为草稿会话（未入库的临时会话）
  bool get isDraftSession =>
      state.session.sessionId.startsWith(draftSessionIdPrefix);

  static const _uuid = Uuid();

  /// LLM 流式执行 + 取消管理。
  ///
  /// 导演轮的生成内核是 AgentRunner（自带取消令牌），本控制器的
  /// StreamRunner 仅复用其取消标志语义（isCancelled 检查点 + cancel()
  /// 双保险），供 runner 各检查点与 cancel()/recoverIfStuck() 协调。
  final StreamRunner _streamRunner;

  /// 导演回合编排器（agent loop 内核）
  late final DirectorRoundRunner _directorRunner = DirectorRoundRunner(
    host: this,
  );

  /// 当前轮次上下文（自动重试时复用；failed 状态下保留供续跑）
  RoundContext? _round;

  /// 后台中断标志（App 切到后台时设置）
  bool _backgroundInterrupted = false;

  /// 强制命名在途标志（updateTitle force 重入去抖——按钮连点只跑一次请求）。
  bool _titleNamingInFlight = false;
  int _suggestGeneration = 0;

  // ==================== 主流程 ====================

  static const _initialDetailTurns = 8;
  final _loadedHistoryTurns = <int>{};
  Future<void>? _openingHistory;
  Future<void>? _readingHistoryTurns;
  Completer<void>? _historyMutation;
  int _historyRevision = 0;
  late bool _historyReady = isDraftSession;
  bool get _historyMutationInFlight => _historyMutation != null;

  /// 加载历史消息（非草稿会话；生成中绝不 reload）
  Future<void> loadHistory() {
    final opening = _openingHistory;
    if (opening != null) return opening;
    if (isDraftSession || !_canRollbackDirectorStory) return Future.value();
    return _openingHistory =
        _sessionOperations.initialize(_loadHistory).whenComplete(() {
      _openingHistory = null;
    });
  }

  Future<void> _loadHistory() async {
    if (!mounted) return;
    _historyReady = false;
    _historyRevision++;
    _loadedHistoryTurns.clear();
    state = state.copyWith(loadingHistory: true);
    try {
      final sessionId = state.session.sessionId;
      final filtered = await _loadFilteredMessages(
        sessionId,
        refreshSession: true,
      );
      if (!mounted) return;
      // 消息可以先阅读。账本检查结束前，写操作仍等待打开流程。
      state = state.copyWith(
        messages: filtered.messages,
        artifactsByTurnNumber: null,
        variantsByTurn: null,
        usageSummariesByTurn: null,
        backfilledPromptTokens: null,
        backfilledCacheReadTokens: null,
        backfilledTotalInputTokens: null,
        backfilledUsageWarnings: null,
        compactedTurnBase: filtered.compactedTurnBase,
        session: filtered.session,
      );

      await _loadInitialHistoryDetails(sessionId);
      if (!mounted) return;
      if (state.session.mode == ChatMode.advanced) {
        await _openEventLog(sessionId);
        await _restoreDirectorInputs(sessionId);
      }
      if (!mounted) return;
      _historyReady = true;

      // 旧会话回填（上下文用量指示 §3.2）：最新轮 summary 缺 lastPromptTokens
      // 时，从事件日志最后一条 step/end 回填（仅内存，不落库）
      await _backfillLastPromptTokens();
      // 上下文容量解析（§3.1：非轮中也可显示；失败不阻断加载）
      await _refreshContextCapacity();
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to load history',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
    } finally {
      if (mounted) state = state.copyWith(loadingHistory: false);
    }
    if (!mounted || !_historyReady) return;
    // 存量快照物化与首条发送同样串行。
    if (state.engineeringMode != EngineeringRuntimeMode.recoveryRequired) {
      await _materializeSnapshotColumnsIfNeeded();
    }
    // MEM-06：会话打开冷路径附带记忆索引体检（fire-and-forget，
    // 结果只记 logger.info——不阻塞会话打开，不弹任何 UI）
    unawaited(_logMemoryIndexHealth('session-open'));
  }

  Future<void> _restoreDirectorInputs(String sessionId) async {
    final saved = await _chatRepository.getDirectorInputs(sessionId);
    if (!mounted) return;
    _retainedInput = saved.pending;
    _hasRetainedQueue = saved.queued != null;
    final pending = saved.pending;
    if (pending == null) {
      if (saved.queued != null) {
        state = state.copyWith(queuedMessage: saved.queued);
      }
      return;
    }
    state = state.copyWith(
      phase: IntermediatePhase.failed,
      userInput: pending,
      pendingUserMessage: _pendingUserMessage(pending),
      queuedMessage: saved.queued,
      failureContext: FailureContext(
        errorCode: 'director_input_recovered',
        failedPhase: IntermediatePhase.generating,
        errorMessage: t.advanced.failure.inputRecovered,
        suggestionOverride: t.advanced.failure.inputRecoveredSuggestion,
        retryable: true,
      ),
    );
  }

  Future<T> _withHistoryMutation<T>(Future<T> Function() action) async {
    final mutation = _historyMutation = Completer<void>();
    _historyRevision++;
    try {
      return await action();
    } finally {
      _historyMutation = null;
      mutation.complete();
    }
  }

  Future<T> _runHistoryTransaction<T>(Future<T> Function() action) {
    final service = _persistenceService;
    return service is StoryHistoryReadStore
        ? (service as StoryHistoryReadStore).runHistoryTransaction(action)
        : action();
  }

  Map<int, T> _replaceHistoryRows<T>(
    Map<int, T>? existing,
    Set<int> turns,
    Map<int, T> readback,
  ) =>
      {...?existing}
        ..removeWhere((turn, _) => turns.contains(turn))
        ..addAll(readback);

  Future<void> _loadInitialHistoryDetails(String sessionId) async {
    try {
      final reader = _persistenceService;
      if (reader is StoryHistoryReadStore) {
        final summaries = await (reader as StoryHistoryReadStore)
            .loadHistorySummaries(sessionId);
        if (!mounted) return;
        state = state.copyWith(usageSummariesByTurn: summaries);
        final base = state.compactedTurnBase;
        final latest = completedTurnCount(
          compactedTurnBase: base,
          messages: state.messages,
        );
        final turns = {
          for (var offset = 0;
              offset < _initialDetailTurns && latest - offset > base;
              offset++)
            latest - offset,
        };
        await _mergeHistoryDetails(turns);
      } else {
        final artifacts = await reader.loadArtifactsBySession(sessionId);
        final variants = await reader.loadMessageVariants(sessionId);
        if (!mounted) return;
        state = state.copyWith(
          artifactsByTurnNumber: artifacts,
          variantsByTurn: variants,
        );
      }
    } catch (e, stackTrace) {
      _logger.warn('History details load failed', detail: '$e\n$stackTrace');
    }
  }

  /// Load the detailed process and manuscript variants for visible or targeted
  /// rounds. Repeated calls share the in-flight read and already loaded turns.
  Future<void> loadHistoryTurnDetails(Iterable<int> turns) async {
    if (_persistenceService is! StoryHistoryReadStore) return;
    final requested = turns.toSet();
    while (mounted) {
      final pending =
          _openingHistory ?? _historyMutation?.future ?? _readingHistoryTurns;
      if (pending != null) {
        await pending;
        continue;
      }
      if (!_historyReady ||
          state.loadingHistory ||
          state.isPreparingRegenerate ||
          state.phase == IntermediatePhase.persisting ||
          _loadedHistoryTurns.containsAll(requested)) {
        return;
      }
      final revision = _historyRevision;
      final read = _mergeHistoryDetails(requested)
          .onError((Object e, StackTrace stackTrace) {
        _logger.warn('History details load failed', detail: '$e\n$stackTrace');
      });
      _readingHistoryTurns = read;
      try {
        await read;
      } finally {
        _readingHistoryTurns = null;
      }
      if (revision == _historyRevision) return;
    }
  }

  Future<void> _mergeHistoryDetails(Set<int> requested) async {
    final turns = requested.difference(_loadedHistoryTurns);
    if (turns.isEmpty) return;
    final revision = _historyRevision;
    final details = await _readHistoryDetails(state.session.sessionId, turns);
    if (!mounted || revision != _historyRevision) return;
    _loadedHistoryTurns.addAll(turns);
    state = state.copyWith(
      artifactsByTurnNumber: _replaceHistoryRows(
        state.artifactsByTurnNumber,
        turns,
        details.artifacts,
      ),
      variantsByTurn:
          _replaceHistoryRows(state.variantsByTurn, turns, details.variants),
    );
  }

  Future<StoryHistoryTurnDetails> _readHistoryDetails(
    String sessionId,
    Set<int> turns,
  ) async {
    final service = _persistenceService;
    if (service is StoryHistoryReadStore) {
      return (service as StoryHistoryReadStore)
          .loadHistoryTurnDetails(sessionId, turns);
    }
    final artifacts = await service.loadArtifactsBySession(sessionId);
    final variants = await service.loadMessageVariants(sessionId);
    return (
      artifacts: {
        for (final turn in turns)
          if (artifacts[turn] case final details?) turn: details,
      },
      variants: {
        for (final turn in turns)
          if (variants[turn] case final records?) turn: records,
      },
    );
  }

  /// MEM-06：记忆索引体检挂耳（MemoryIndexHealthService.inspect）
  ///
  /// 触发点：会话打开冷路径（loadHistory 完成）与轮失败含 E104/检索
  /// 异常时（_fail）。结果只进 logger.info（诊断日志可查），不写 state、
  /// 不弹 UI、不阻塞正常生成；体检自身异常全吞（观测挂耳不反噬主流程）。
  /// 阈值与导演重建向量索引同源（advanced.retrieval 双门槛）。
  Future<void> _logMemoryIndexHealth(String trigger) async {
    try {
      final retrieval = (await _getConfig()).retrieval;
      final health = await MemoryIndexHealthService(
        experienceRepository: _experienceRepository,
      ).inspect(
        state.session.sessionId,
        importanceStorageThreshold: retrieval.importanceStorageThreshold,
        microVectorizeThreshold: retrieval.microVectorizeThreshold,
      );
      _logger.info(
        'Memory index health ($trigger)',
        detail: 'session=${state.session.sessionId}, '
            'active=${health.activeMemories}, '
            'unindexedIndexable=${health.unindexedIndexableMemories}, '
            'withoutEmbedding=${health.memoriesWithoutEmbedding}, '
            'staleEmbedding=${health.staleEmbeddingMemories}',
      );
    } catch (_) {
      // 体检失败静默——不阻塞、不弹 UI（挂耳语义）
    }
  }

  /// 解析冷路径裁剪的保留轮数（advanced.harness.event_log_retention_turns）
  ///
  /// 配置解析失败回落 null（runner 用默认值）——裁剪是卫生动作，
  /// 不因配置读取失败阻断会话打开。
  Future<int?> _resolveRetentionTurns() async {
    try {
      return (await _getConfig()).harness.eventLogRetentionTurns;
    } catch (e) {
      _logger.warn(
        'Resolve event log retention failed',
        detail: '$e',
      );
      return null;
    }
  }

  Future<void> _openEventLog(String sessionId) async {
    final repo = agentEventLogRepository;
    final sessionFlag = state.session.engineeringContextEnabled;
    final retentionTurns = repo == null ? null : await _resolveRetentionTurns();

    Future<({bool? enabled, EngineeringModeResolution mode})> open() async {
      // 重新读持久会话列，避免导航时传入的快照已落后于同库的纪元写入。
      final saved = repo is AgentLogMaintenanceStore
          ? await _loadSessionQuietly(sessionId)
          : null;
      final enabled =
          saved == null ? sessionFlag : saved.engineeringContextEnabled;
      final resolution =
          await _resolveEngineeringMode(sessionId, enabled: enabled);
      if (!resolution.isBlocked) {
        await _directorRunner.recoverEventLogIfNeeded(
          sessionId,
          retentionTurns: retentionTurns,
          trimEnabled: !resolution.isOpen,
        );
      }
      return (enabled: enabled, mode: resolution);
    }

    final result = repo is AgentLogMaintenanceStore
        ? await repo.runLogMaintenance(open)
        : await open();
    if (!mounted) return;
    state = state.copyWith(
      session:
          state.session.copyWith(engineeringContextEnabled: result.enabled),
      engineeringMode: result.mode.mode,
      engineeringModeReason: result.mode.reason,
    );
    if (result.mode.isBlocked) {
      _logger.error(
        'Engineering context mode blocked, data preserved',
        detail: 'sessionId=$sessionId, reason=${result.mode.reason}',
      );
    }
  }

  /// 工程上下文模式三态解析（会话列 × 账本纪元对账）。
  Future<EngineeringModeResolution> _resolveEngineeringMode(
    String sessionId, {
    required bool? enabled,
  }) async {
    final repo = agentEventLogRepository;
    if (repo == null) {
      // 无账本通道（旧测试装配）：无法验证纪元——列 true 视为矛盾（不
      // 放行无据开启），列非 true 按普通关闭处理。
      return (enabled ?? false)
          ? const EngineeringModeResolution(
              mode: EngineeringRuntimeMode.recoveryRequired,
              reason: 'enabled-without-epoch',
            )
          : const EngineeringModeResolution.closed();
    }
    if (repo is AgentLogMaintenanceStore) {
      return resolveEngineeringMode(
        enabled: enabled,
        events: await repo.readEngineeringModeEvidence(sessionId),
      );
    }
    if (enabled != true) {
      try {
        final epochEvents = await repo.readModeEpochEvents(sessionId);
        if (epochEvents.isEmpty) {
          return const EngineeringModeResolution.closed();
        }
      } catch (e) {
        // 预检通道异常：退回全量对账，不静默放行。
        _logger.warn(
          'Mode epoch precheck failed, falling back to full resolution',
          detail: '$e',
        );
      }
    }
    return resolveEngineeringMode(
      enabled: enabled,
      events: await repo.readEvents(sessionId),
    );
  }

  /// 工程上下文模式开关专用切换入口（设置面板/修复态处置调用）。
  ///
  /// 与通用 updateSession 的差异：开关变化必须与纪元事件同库单事务提交
  /// （进入=一次性捕获+pending/complete 纪元+置列 true；退出=exit 纪元+
  /// 置列 false——退出警示由 UI 层按保留配置呈现，确认后才调用）。
  ///
  /// 守卫：生成中/手动压缩中/停止中一律
  /// 拒绝；failed 态留有半截草稿（_round 未清）时须先显式重试或放弃，
  /// 防止半截草稿与旧 attempt 跨模式混淆；草稿会话（未物化）不支持。
  /// 会话操作守卫将转换、发轮和备份覆盖互斥，捕获在写入事务内完成。
  Future<bool> setEngineeringContextEnabled({required bool enabled}) async {
    if (_engineeringModeChange != null) return false;
    final operation = _runSessionOperation(
      false,
      () => _setEngineeringContextEnabled(enabled),
    );
    _engineeringModeChange = operation;
    try {
      return await operation;
    } finally {
      _engineeringModeChange = null;
    }
  }

  Future<bool> _setEngineeringContextEnabled(bool enabled) async {
    if (isDraftSession) return false;
    if (state.phase != IntermediatePhase.idle &&
        state.phase != IntermediatePhase.failed) {
      return false;
    }
    if (state.isManualCompacting ||
        state.isStopping ||
        state.isPreparingRegenerate) {
      return false;
    }
    if (state.phase == IntermediatePhase.failed && _round != null) {
      // 失败轮半截草稿未处置：要求先「从中断处继续/整轮重试/放弃」。
      return false;
    }
    // 正常态同值幂等；修复态的同值请求是真实处置（重捕获/确认退出），
    // 必须执行对应纪元操作——相同布尔值不代表相同有效状态。
    final isRecovery =
        state.engineeringMode == EngineeringRuntimeMode.recoveryRequired;
    if (!isRecovery &&
        enabled == (state.session.engineeringContextEnabled ?? false)) {
      return true;
    }
    final switchStore = _engineeringContextSwitch;
    final repo = agentEventLogRepository;
    if (switchStore == null || repo == null) return false;

    final sessionId = state.session.sessionId;
    final ok = await _runEngineeringModeSwitch(
      sessionId: sessionId,
      enabled: enabled,
      switchStore: switchStore,
      repo: repo,
    );
    if (ok && mounted) {
      _logger.info(
        'Engineering context mode switched',
        detail: 'sessionId=$sessionId, enabled=$enabled, '
            'mode=${state.engineeringMode.name}',
      );
    }
    return ok;
  }

  /// 在开启或回退事务内，从当前可见历史建立纪元快照。
  Future<EngineeringEnterCapture> _captureEngineeringHistory(
    String sessionId,
    String epochId, {
    int? fromTurn,
    String? regeneratingUserInput,
  }) async {
    final filtered = await _loadFilteredMessages(sessionId);
    final artifacts =
        await _persistenceService.loadArtifactsBySession(sessionId);
    final history = regeneratingUserInput == null
        ? filtered.messages
        : stripTrailingDuplicateUserInput(
            filtered.messages,
            regeneratingUserInput,
          );
    return EngineeringEnterCapture(
      fromTurn: fromTurn ??
          resolveTurnNumber(
            nextTurn: filtered.nextTurn,
            compactedTurnBase: filtered.compactedTurnBase,
            messages: history,
          ),
      captureEvents: buildEngineeringCaptureEvents(
        visibleSurface: mapHistoryWithWorkTraces(
          history: history,
          artifacts: artifacts,
          compactedTurnBase: filtered.compactedTurnBase,
        ),
        epochId: epochId,
      ),
    );
  }

  Future<bool> _truncateDirectorTurnEvents(
    String sessionId,
    int turn, {
    String? regeneratingUserInput,
  }) async {
    return await _agentEventLogRepository?.deleteTurnEvents(
          sessionId,
          turn,
          captureHistory: (epochId) => _captureEngineeringHistory(
            sessionId,
            epochId,
            fromTurn: turn,
            regeneratingUserInput: regeneratingUserInput,
          ),
        ) ??
        false;
  }

  Future<bool> _runEngineeringModeSwitch({
    required String sessionId,
    required bool enabled,
    required EngineeringContextSwitchStore switchStore,
    required AgentEventLogStore repo,
  }) async {
    try {
      if (enabled) {
        // 同快照进入：捕获读取（可见历史+产物）在写入事务内执行——
        // 并发写入被事务串行化排除，读快照与写入一致。
        final epochId = _uuid.v4();
        await switchStore.applyEngineeringContextEnterAtomic(
          sessionId: sessionId,
          epochId: epochId,
          prepare: () => _captureEngineeringHistory(sessionId, epochId),
        );
      } else {
        // 退出前先作废在途压缩（模式切换是提交资格的终结点）
        await _engineeringCompaction?.invalidateActive(
          sessionId,
          'mode-exit',
        );
        // 退出闭合账本内最新未闭合纪元（pending 残留/complete 未退出都
        // 属未闭合——修复态的确认退出同样经此闭合）；true 列缺纪元的
        // 异常账本 epochId 为 null，仅置列。
        final events = await repo.readModeEpochEvents(sessionId);
        await switchStore.applyEngineeringContextExit(
          sessionId: sessionId,
          epochId: unclosedEpochIdOf(events),
        );
      }
      // 事务提交成功后以库内行为准刷新内存态。
      final persisted = await _chatRepository.getSession(sessionId);
      if (!mounted) return true;
      state = state.copyWith(
        session: persisted,
        // 模式切换改变下一轮材料与缓存预期：旧「当前预计」与构成快照
        // 失效，重算容量（与 updateSession 的 configChanged 同口径）。
        contextEstimate: const ContextUsageEstimate.unknown(),
        contextSegmentChars: null,
      );
      final resolution = await _resolveEngineeringMode(
        sessionId,
        enabled: persisted.engineeringContextEnabled,
      );
      if (!mounted) return true;
      state = state.copyWith(
        engineeringMode: resolution.mode,
        engineeringModeReason: resolution.reason,
      );
      unawaited(_refreshContextCapacity());
      return true;
    } catch (e, stackTrace) {
      _logger.error(
        'Engineering context mode switch failed',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  /// 会话打开时的上下文容量解析（上下文用量指示 §3.1）
  ///
  /// 失败仅记日志：容量显示是附加能力，不阻断历史加载。
  int _contextCapacityRevision = 0;

  Future<void> _refreshContextCapacity() async {
    if (!mounted) return;
    final revision = ++_contextCapacityRevision;
    final session = state.session;
    try {
      final namingConfig =
          await _configurationResolver.resolveAdvancedGeneratingNamingConfig(
        session,
      );
      if (namingConfig == null ||
          namingConfig.baseUrl.isEmpty ||
          namingConfig.modelId.isEmpty) {
        return;
      }
      final modelWindow =
          await _configurationResolver.resolveContextWindowForPhase(
        presetId: namingConfig.presetId,
        modelId: namingConfig.modelId,
      );
      final resolvedSettings =
          await _configurationResolver.resolveAdvancedSettings(session);
      final resolvedWindow = _resolveContextWindow(
        resolvedSettings.settings.effectiveContextLimit,
        modelWindow,
      );
      final config = await _getConfig();
      final merged = _applyContextBudgetOverride(
        config.storyRuntime,
        resolvedSettings.settings,
      );
      if (!mounted ||
          revision != _contextCapacityRevision ||
          session.sessionId != state.session.sessionId ||
          _contextConfigChanged(session, state.session)) {
        return;
      }
      state = state.copyWith(
        contextWindowTokens: resolvedWindow,
        compactionTriggerTokens: _directorCompactionTrigger(
          contextWindow: resolvedWindow,
          config: merged,
          naming: namingConfig,
          settings: resolvedSettings.settings,
        ),
      );
    } catch (e, stackTrace) {
      _logger.warn(
        'Context capacity refresh failed',
        detail: '$e\n$stackTrace',
      );
    }
  }

  int _directorCompactionTrigger({
    required int contextWindow,
    required StoryRuntimeConfig config,
    required NamingConfig naming,
    required ChatSessionSettings settings,
  }) =>
      directorCompactionTriggerTokens(
        contextWindowTokens: contextWindow,
        budget: config.contextBudget,
        engineeringTuning:
            state.engineeringMode == EngineeringRuntimeMode.normalOpen
                ? EngineeringCompactionTuning.forDirectorRequest(
                    config.engineeringCompaction,
                    naming: naming,
                    settings: settings,
                  )
                : null,
      );

  /// 旧会话回填（上下文用量指示 §3.2）：仅内存补最新轮 lastPromptTokens
  Future<void> _backfillLastPromptTokens() async {
    final summary = state.latestHistoryTurnSummary;
    if (summary == null) return;
    // 新轮已同时写入 prompt/完整输入 → 无需回填；旧轮缺任一字段才探针补齐
    if (summary.lastPromptTokens != null && summary.lastInputTokens != null) {
      return;
    }
    final repo = agentEventLogRepository;
    if (repo == null) return;
    try {
      final sessionId = state.session.sessionId;
      final events = repo is AgentLogMaintenanceStore
          ? await repo.readLatestUsageEvent(sessionId)
          : await repo.readEvents(sessionId);
      if (!mounted) return;
      final usage = latestStepEndUsage(events);
      if (usage == null) return;
      state = state.copyWith(
        backfilledPromptTokens: usage.promptTokens,
        // cache 分项随同源探针回填（旧日志缺键保持 null）
        backfilledCacheReadTokens: usage.cacheReadTokens,
        // 完整输入面（旧日志缺键保持 null → 命中率样本降级）
        backfilledTotalInputTokens: usage.totalInputTokens,
        // 异常标识与数字同源回填：只补数字会让旧冲突样本重新算成精确比例
        backfilledUsageWarnings: usage.usageWarnings,
      );
    } catch (e, stackTrace) {
      _logger.warn('Prompt token backfill failed', detail: '$e\n$stackTrace');
    }
  }

  /// 手动压缩入口（上下文用量指示 §4.3：force 语义，不检查阈值与冷却）
  ///
  /// 守卫：压缩中/非 idle → busy；对话不足（与 shouldCompact 同源下限）→
  /// insufficient。实际压缩走 story_runtime 同一管线（流式增量写
  /// manualCompactionDelta 供面板实时打字），成功后 persistManualCompaction
  /// 单事务落库并重载过滤后历史；失败只写 manualCompactionError，不落任何库。
  Future<ManualCompactResult> manualCompact() =>
      _runSessionOperation(ManualCompactResult.busy, _manualCompact);

  Future<ManualCompactResult> _manualCompact() async {
    if (state.isManualCompacting) return ManualCompactResult.busy;
    if (state.phase != IntermediatePhase.idle) return ManualCompactResult.busy;
    final service = _compactionService;
    if (service == null) return ManualCompactResult.failed;
    // 工程上下文模式（开启态）：走账本压缩事务（两段提交+四条件校验；
    // 流式增量走摘要器回调）
    if (state.engineeringMode == EngineeringRuntimeMode.normalOpen) {
      final engineering = _engineeringCompaction;
      if (engineering == null) return ManualCompactResult.failed;
      try {
        // 手动压缩参数同样来自配置段（无轮上下文，输出预留走配置默认
        // ——outputReserve 只进自动触发阈值，手动 force 语义不检查阈值）。
        // 三入口共用面（与自动/溢出同源）：实际工具目录（与轮装配同一
        // 构建器/权限求值）、当前协议 wire 面、账本最新冻结前缀——固定面
        // 不进投影但进请求，选材/摘要共享前部契约同样适用。
        final engineeringTuning = EngineeringCompactionTuning.fromConfig(
          (await _getConfig()).engineeringCompaction,
        );
        NamingConfig? naming;
        try {
          naming = await _configurationResolver
              .resolveAdvancedGeneratingNamingConfig(state.session);
        } catch (_) {
          naming = null; // 协议不可知时回退默认表示（不阻断手动压缩）
        }
        final ledger = agentEventLogRepository;
        final frozenPrefixChars = ledger == null
            ? 0
            : DirectorSurfaceV2.latestFrozenPrefixOf(
                  await ledger.readEvents(state.session.sessionId),
                )?.length ??
                0;
        final result = await engineering.compact(
          sessionId: state.session.sessionId,
          trigger: 'manual',
          contextWindowTokens: state.contextWindowTokens ?? 32000,
          retrievalRatio: state.session.compactionTriggerRatioOverride ?? 0.15,
          tuning: engineeringTuning,
          tools: await _directorRunner.manualCompactionToolDefinitions(),
          wireOptions: naming == null
              ? const AgentWireOptions()
              : AgentWireOptions.forProtocolName(naming.protocol.name),
          frozenPrefixChars: frozenPrefixChars,
          onDelta: _onManualCompactionDelta,
        );
        if (result.outcome != 'committed') {
          state = state.copyWith(
            isManualCompacting: false,
            manualCompactionError: result.reason ?? result.outcome,
          );
          return result.outcome == 'noop' || result.reason == 'empty-interval'
              ? ManualCompactResult.insufficient
              : ManualCompactResult.failed;
        }
        final filtered = await _loadFilteredMessages(state.session.sessionId);
        state = state.copyWith(
          messages: filtered.messages,
          compactedTurnBase: filtered.compactedTurnBase,
          session: filtered.nextTurn == null
              ? state.session.copyWith(
                  messageCount: filtered.messages.length,
                )
              : state.session.copyWith(
                  messageCount: filtered.messages.length,
                  nextTurn: filtered.nextTurn,
                ),
          // 压缩后材料收缩：预计回未知（下一请求实报后重建）
          contextEstimate: const ContextUsageEstimate.unknown(),
          contextSegmentChars: null,
        );
        unawaited(_refreshContextCapacity());
        return ManualCompactResult.success;
      } catch (e, stackTrace) {
        _logger.error(
          'Engineering manual compaction failed',
          detail: '$e',
          error: e,
          stackTrace: stackTrace,
        );
        state = state.copyWith(isManualCompacting: false);
        return ManualCompactResult.failed;
      }
    }
    if (StoryCompactionService.countDialogueMessages(state.messages) <
        StoryCompactionService.minDialogueMessages) {
      return ManualCompactResult.insufficient;
    }

    state = state.copyWith(
      isManualCompacting: true,
      manualCompactionDelta: '',
      manualCompactionError: null,
    );
    try {
      final namingConfig =
          await _configurationResolver.resolveAdvancedGeneratingNamingConfig(
        state.session,
      );
      if (namingConfig == null ||
          namingConfig.baseUrl.isEmpty ||
          namingConfig.apiKey.isEmpty ||
          namingConfig.modelId.isEmpty) {
        state = state.copyWith(
          isManualCompacting: false,
          // 入 slang（原硬编码中文直达详情面板）
          manualCompactionError: t.advanced.contextRing.compactModelMissing,
        );
        return ManualCompactResult.failed;
      }
      final config = await _getConfig();
      final resolvedSettings =
          await _configurationResolver.resolveAdvancedSettings(state.session);
      final timeouts = await _configurationResolver.resolveTimeouts();
      final budget = _applyContextBudgetOverride(
        config.storyRuntime,
        resolvedSettings.settings,
      ).contextBudget;

      // 以 DB 过滤视图为准：自动压缩后内存态可能尚未同步，直接读 state
      // 会拿到旧摘要和已压缩消息，导致重复压缩旧范围。
      final initialFiltered =
          await _loadFilteredMessages(state.session.sessionId);
      if (StoryCompactionService.countDialogueMessages(
            initialFiltered.messages,
          ) <
          StoryCompactionService.minDialogueMessages) {
        state = state.copyWith(
          isManualCompacting: false,
          manualCompactionDelta: '',
        );
        return ManualCompactResult.insufficient;
      }
      final existingSummary = StoryCompactionService.extractPersistedSummary(
        initialFiltered.messages,
      );

      final result = await service.compact(
        history: initialFiltered.messages,
        sessionId: state.session.sessionId,
        namingConfig: namingConfig,
        contextWindow: state.contextWindowTokens ??
            ConfigurationResolver.defaultContextWindow,
        // 输出帽与故事侧手动压缩同源：按会话配置与实际执行模型上限钳制。
        maxTokens: _outputTokenReserveFor(
          resolvedSettings.settings.maxTokens,
          modelMaxOutput: namingConfig.maxOutputTokens,
        ),
        budget: budget,
        connectTimeout: timeouts.connectTimeout,
        readTimeout: timeouts.readTimeout,
        existingCompactionSummary: existingSummary,
        manual: true,
        onSummaryDelta: _onManualCompactionDelta,
      );
      _flushManualCompactionDeltas();

      final lastTurn = completedTurnCount(
        compactedTurnBase: initialFiltered.compactedTurnBase,
        messages: initialFiltered.messages,
      );
      // 手动压缩宏摘要同向量化（文本口径同落库侧：
      // 分段宏摘要优先，回退压缩摘要全文）；未配置/失败降级 null 不阻断压缩。
      final macroEmbedding = await _resolveManualMacroEmbedding(
        result.segmentMacroSummary ??
            result.compactedHistory.first.content ??
            '',
      );
      await _persistenceService.persistManualCompaction(
        compaction: CompactionPersistenceData(
          summaryMessage: result.compactedHistory.first,
          boundaryMessageId: result.boundaryMessageId,
          turnNumber: lastTurn,
          segmentMacroSummary: result.segmentMacroSummary,
          macroEmbedding: macroEmbedding,
        ),
      );

      // 重载过滤后历史（新摘要 + 保留区），同步压缩基数与计数
      final filtered = await _loadFilteredMessages(state.session.sessionId);
      // 压缩前快照：撤销时原样恢复。
      // 只接受当前有效的内存估算。历史实报可能来自失效配置（切模型/
      // 规则）或压缩前材料，不能再当作当前材料锚点；此时保持未知。
      final anchor = (state.contextEstimate?.hasData ?? false)
          ? state.contextEstimate!
          : const ContextUsageEstimate.unknown();
      _preCompactionEstimate = anchor;
      // 构成图与主数字必须同属压缩后材料修订：历史段字符按压缩后
      // 过滤视图重建；上一轮指令已随用户消息迁入历史，清空以免重复。
      final rebuiltChars = state.contextSegmentChars == null
          ? null
          : {
              ...state.contextSegmentChars!,
              'history': filtered.messages.fold<int>(
                0,
                (sum, m) => sum + (m.content?.length ?? 0),
              ),
              'directive': 0,
            };
      state = state.copyWith(
        messages: filtered.messages,
        compactedTurnBase: filtered.compactedTurnBase,
        isManualCompacting: false,
        manualCompactionDelta: '',
        // 压缩后消息列表被过滤视图替换，messageCount
        // 内存镜像同步刷新（口径同 persist 路径，与故事侧同构）。
        session: state.session.copyWith(
          messageCount: filtered.messages.length,
        ),
        // 压缩成功不重发主请求也要刷新「当前预计」：锚点 - 压缩前 + 压缩后。
        // 最近请求实报分项保留（详情面板「最近请求」是历史事实，不是当前值）。
        contextEstimate: ContextUsageEstimate.afterCompaction(
          current: anchor,
          tokensBefore: result.tokensBefore,
          tokensAfter: result.tokensAfter,
          replacedSummaryTokens: result.replacedSummaryTokens,
          at: DateTime.now(),
        ),
        contextSegmentChars: rebuiltChars,
      );
      _logger.info(
        'Manual compaction completed',
        detail: 'summaryLength=${result.summary.length}, '
            'tokensBefore=${result.tokensBefore}, '
            'tokensAfter=${result.tokensAfter}',
      );
      return ManualCompactResult.success;
    } on CompactionNoopException catch (e) {
      _flushManualCompactionDeltas();
      _logger.info(
        'Manual compaction skipped',
        detail: 'reason=${e.reason.name}',
      );
      state = state.copyWith(
        isManualCompacting: false,
        manualCompactionDelta: '',
        manualCompactionError: null,
      );
      return ManualCompactResult.insufficient;
    } catch (e, stackTrace) {
      _flushManualCompactionDeltas();
      _logger.warn('Manual compaction failed', detail: '$e\n$stackTrace');
      // 原始异常不再整段直达面板——分类标签 +
      // 截断的技术细节（面板是用户可见面；完整堆栈已在日志）
      final classified = _classifier.classifyError(e);
      final raw = '$e';
      final technical = raw.length > 240 ? raw.substring(0, 240) : raw;
      state = state.copyWith(
        isManualCompacting: false,
        manualCompactionError:
            '${_compactionErrorLabel(classified.category)}$technical',
      );
      return ManualCompactResult.failed;
    }
  }

  /// 手动压缩失败面板的分类前缀（错误三层的「是什么」层，
  /// 文案在 common.contextRing.compactErrorPrefix）
  static String _compactionErrorLabel(ErrorCategory category) {
    final labels = t.common.contextRing.compactErrorPrefix;
    switch (category) {
      case ErrorCategory.config:
        return labels.config;
      case ErrorCategory.network:
        return labels.network;
      case ErrorCategory.auth:
        return labels.auth;
      case ErrorCategory.rateLimit:
        return labels.rateLimit;
      case ErrorCategory.server:
        return labels.server;
      case ErrorCategory.request:
        return labels.request;
      case ErrorCategory.timeout:
        return labels.timeout;
      case ErrorCategory.format:
        return labels.format;
      case ErrorCategory.contextOverflow:
        return labels.contextOverflow;
      case ErrorCategory.persist:
        return labels.persist;
      case ErrorCategory.unknown:
        return labels.unknown;
    }
  }

  /// 撤销最新一次压缩（2026-09-04 撤销压缩）：仅 idle 可用
  ///
  /// 单事务回剥（U1 原语），随后重载过滤后历史——上一个压缩点重新生效
  /// 或旧对话全量恢复，压缩基数同步回剥。轮产物/事件日志不受影响
  ///  批4（收口）：压缩摘要流式增量 32ms 合帧——此前每原始
  /// delta 一次 state.copyWith（每 delta 整页重建 + O(全长) 字符串拼接）。
  /// 完成或异常时先冲刷（尾段不丢），重入 manualCompact 时缓冲重建。
  void _onManualCompactionDelta(String delta) {
    _manualCompactionDeltaBuffer ??= ThrottledDeltaBuffer((coalesced) {
      state = state.copyWith(
        manualCompactionDelta: state.manualCompactionDelta + coalesced,
      );
    });
    _manualCompactionDeltaBuffer!.add(delta);
  }

  void _flushManualCompactionDeltas() {
    _manualCompactionDeltaBuffer?.flushAndDispose();
    _manualCompactionDeltaBuffer = null;
  }

  /// （撤销只还原上下文前缀维度）。实现与故事侧同构。
  Future<bool> undoCompaction() => _runSessionOperation(false, _undoCompaction);

  Future<bool> _undoCompaction() async {
    if (state.isManualCompacting) return false;
    if (state.phase != IntermediatePhase.idle) return false;
    // 工程上下文模式（开启态）：全量撤销——compaction/undo 事件（影子
    // 区间回表面）+ chat 侧按 narrativeBoundary 产物 ID 精确回退（仅最新
    // 一次、其后无结构事件；纯工程 checkpoint 不碰 chat 侧）。
    if (state.engineeringMode == EngineeringRuntimeMode.normalOpen) {
      final engineering = _engineeringCompaction;
      if (engineering == null) return false;
      try {
        final undone = await engineering.undo(
          sessionId: state.session.sessionId,
        );
        if (!undone) return false;
        final filtered = await _loadFilteredMessages(state.session.sessionId);
        state = state.copyWith(
          messages: filtered.messages,
          compactedTurnBase: filtered.compactedTurnBase,
          session: filtered.nextTurn == null
              ? state.session.copyWith(
                  messageCount: filtered.messages.length,
                )
              : state.session.copyWith(
                  messageCount: filtered.messages.length,
                  nextTurn: filtered.nextTurn,
                ),
          contextEstimate: const ContextUsageEstimate.unknown(),
          contextSegmentChars: null,
        );
        unawaited(_refreshContextCapacity());
        return true;
      } catch (e, stackTrace) {
        _logger.error(
          'Engineering undo compaction failed',
          detail: '$e',
          error: e,
          stackTrace: stackTrace,
        );
        return false;
      }
    }
    try {
      final undone = await _persistenceService.undoCompaction(
        sessionId: state.session.sessionId,
      );
      if (!undone) return false;
      final filtered = await _loadFilteredMessages(state.session.sessionId);
      state = state.copyWith(
        messages: filtered.messages,
        compactedTurnBase: filtered.compactedTurnBase,
        // next_turn 计数器镜像到会话（与 loadHistory 同口径）。
        // copyWith 是哨兵语义（显式传 null 会清空计数器），nextTurn 保留
        // 原条件式；messageCount 镜像恒刷新（口径同 persist 路径）。
        session: filtered.nextTurn == null
            ? state.session.copyWith(messageCount: filtered.messages.length)
            : state.session.copyWith(
                messageCount: filtered.messages.length,
                nextTurn: filtered.nextTurn,
              ),
        // 撤销后回到压缩前材料：恢复压缩前快照；无有效快照时保持未知，
        // 不用历史实报冒充当前材料锚点。
        contextEstimate:
            _preCompactionEstimate ?? const ContextUsageEstimate.unknown(),
        // 构成图同步回到压缩前材料：历史段字符按恢复后的过滤视图重建；
        // 上一轮指令在历史中，清空指令段以免重复。
        contextSegmentChars: state.contextSegmentChars == null
            ? null
            : {
                ...state.contextSegmentChars!,
                'history': filtered.messages.fold<int>(
                  0,
                  (sum, m) => sum + (m.content?.length ?? 0),
                ),
                'directive': 0,
              },
      );
      _preCompactionEstimate = null;
      unawaited(_refreshContextCapacity());
      _logger.info('Manual compaction undone');
      return true;
    } catch (e, stackTrace) {
      _logger.warn('Undo compaction failed', detail: '$e\n$stackTrace');
      return false;
    }
  }

  /// 加载按最新 CompactionPoint 过滤后的消息列表
  ///
  /// 同时返回已压缩轮次基数（修复 2026-08-23），供 turnNumber 单调推导。
  /// 首次打开与压缩路径复用会话行读回，保持 next_turn 镜像更新。
  Future<
      ({
        List<ChatMessage> messages,
        int compactedTurnBase,
        int? nextTurn,
        ChatSession? session,
      })> _loadFilteredMessages(
    String sessionId, {
    bool refreshSession = false,
  }) async {
    if (_compactionService == null) {
      final (messages, session) = await (
        _chatRepository.getMessages(sessionId),
        refreshSession
            ? _loadSessionQuietly(sessionId)
            : Future<ChatSession?>.value(),
      ).wait;
      return (
        messages: messages,
        compactedTurnBase: 0,
        nextTurn: session?.nextTurn,
        session: session,
      );
    }
    final (allMessages, compactionPoints, session) = await (
      _chatRepository.getMessages(sessionId),
      _chatRepository.getCompactionPoints(sessionId),
      _loadSessionQuietly(sessionId),
    ).wait;
    return (
      messages: StoryCompactionService.filterByCompactionPoint(
        allMessages: allMessages,
        compactionPoints: compactionPoints,
      ),
      compactedTurnBase: StoryCompactionService.compactedTurnBaseFor(
        allMessages: allMessages,
        compactionPoints: compactionPoints,
      ),
      nextTurn: session?.nextTurn,
      session: session,
    );
  }

  /// 会话行读取失败时保留当前快照和旧库轮号推导。
  Future<ChatSession?> _loadSessionQuietly(String sessionId) async {
    try {
      return await _chatRepository.getSession(sessionId);
    } catch (_) {
      return null;
    }
  }

  /// 更新会话配置（供会话设置面板调用；生成中拒绝）
  Future<bool> updateSession(ChatSession updated) async {
    if (!mounted) return false;
    final modeChange = _engineeringModeChange;
    if (modeChange != null &&
        updated.engineeringContextEnabled ==
            state.session.engineeringContextEnabled) {
      // 普通设置可以等切换提交。等待期间不占用会话，写入时使用最新开关值。
      await modeChange;
      return _runSessionOperation(
        false,
        () => _updateSession(
          updated.copyWith(
            engineeringContextEnabled: state.session.engineeringContextEnabled,
          ),
        ),
      );
    }
    return _runSessionOperation(false, () => _updateSession(updated));
  }

  Future<bool> _updateSession(ChatSession updated) async {
    if (state.phase != IntermediatePhase.idle &&
        state.phase != IntermediatePhase.failed) {
      _logger.warn('updateSession rejected: phase is generating');
      return false;
    }
    // 工程上下文模式开关不进通用通道：true 置位必须与纪元事件同库单
    // 事务（专用原子路径 setEngineeringContextEnabled），旁路进入会造
    // 成「开而无纪元」的修复态挂起。
    if (updated.engineeringContextEnabled !=
        state.session.engineeringContextEnabled) {
      _logger.warn(
        'updateSession rejected: engineering context flag must go through '
        'the dedicated atomic switch path',
      );
      return false;
    }
    if (isDraftSession) {
      await _materializeDraftSessionWith(updated);
      unawaited(_refreshContextCapacity());
      return true;
    }
    try {
      final persisted = await _chatRepository.updateSession(updated);
      // 配置变化会改变下一轮材料/容量：旧「当前预计」、构成快照与窗口、
      // 触发线均失效，置 unknown 并异步重算容量。
      final configChanged = _contextConfigChanged(state.session, persisted);
      state = state.copyWith(
        session: persisted,
        contextEstimate: configChanged
            ? const ContextUsageEstimate.unknown()
            : state.contextEstimate,
        contextSegmentChars: configChanged ? null : state.contextSegmentChars,
      );
      if (configChanged) unawaited(_refreshContextCapacity());
      return true;
    } catch (e, stackTrace) {
      _logger.error(
        'updateSession failed',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  /// 会话配置是否影响下一轮材料或容量
  ///
  /// 只列会改变请求材料/窗口/触发线的字段：模型、预设（规则）、
  /// 提示词覆盖、输出帽、预算比例、工具权限、剧情锚与一次性角色注入。
  /// 标题/星标/排序/推荐回复等展示字段不参与。
  static bool _contextConfigChanged(ChatSession a, ChatSession b) {
    return a.modelId != b.modelId ||
        a.presetId != b.presetId ||
        a.systemPromptOverride != b.systemPromptOverride ||
        a.maxTokens != b.maxTokens ||
        a.maxContextMessages != b.maxContextMessages ||
        a.effectiveContextLimit != b.effectiveContextLimit ||
        a.reasoningEffort != b.reasoningEffort ||
        a.phaseModels != b.phaseModels ||
        a.reviewEnabledOverride != b.reviewEnabledOverride ||
        a.recentMinRatioOverride != b.recentMinRatioOverride ||
        a.retrievalRatioOverride != b.retrievalRatioOverride ||
        a.compactionTriggerRatioOverride != b.compactionTriggerRatioOverride ||
        a.maxSteps != b.maxSteps ||
        a.toolPermissions != b.toolPermissions ||
        a.narrativePacing != b.narrativePacing ||
        a.retrievalOverrides != b.retrievalOverrides ||
        a.storyAnchor != b.storyAnchor ||
        a.characterInitPrompt != b.characterInitPrompt ||
        a.characterInitCardId != b.characterInitCardId;
  }

  /// 侧边栏重命名后同步主区标题
  ///
  /// 新标题已由侧边栏持久化，此处只回填内存态展示字段，不重复写库；
  /// 不受生成中限制（仅触碰 session 值拷贝的 title，与生成链路无耦合）。
  void applyExternalTitle(String title) {
    state = state.copyWith(session: state.session.copyWith(title: title));
  }

  /// 编辑当前剧情锚（Recap 卡入口）
  ///
  /// 与 AI `update_story_anchor` 同一数据源——都落 chat_sessions.story_anchor
  /// 列（AI 走轮 persist 事务，此处走 [updateSession]，含生成中拒绝守卫）。
  /// 历史轮 artifacts 快照不动（轮末留痕，编辑只影响当前锚与后续轮）。
  /// 成功后同步 [AdvancedChatState.agentStoryAnchor]（live 锚）。
  Future<bool> updateStoryAnchor(StoryAnchor anchor) async {
    final ok = await updateSession(
      state.session.copyWith(storyAnchor: anchor),
    );
    if (ok) {
      state = state.copyWith(agentStoryAnchor: anchor);
    }
    return ok;
  }

  /// 场记板数据（「AI 眼中的现在」）
  ///
  /// 与 runner 注入面同源（共享 [assembleDirectorCoreBlocks]）：按当前
  /// 会话状态现算下一轮将注入的 core blocks 素材。历史轮快照未随轮存档，
  /// 本方法只做当前视图（历史轮场记板记为后续增强）。
  Future<DirectorCoreBlocksData?> loadScriptBoard() async {
    final factual = _factualRepository;
    if (factual == null) return null;
    try {
      final resolved = await _configurationResolver.resolveAdvancedSettings(
        state.session,
      );
      final config = await _getConfig();
      final merged = _applyContextBudgetOverride(
        config.storyRuntime,
        resolved.settings,
      );
      return await assembleDirectorCoreBlocks(
        factual: factual,
        experienceRepository: _experienceRepository,
        sessionId: state.session.sessionId,
        factualConfig: merged.memory.factual,
        narrativeTime: state.session.currentNarrativeTime,
        anchor: state.session.storyAnchor,
        logger: _logger,
      );
    } catch (e) {
      _logger.warn('Script board assembly failed', detail: '$e');
      return null;
    }
  }

  /// 只读批量查询实体主名映射（供旧记录缺失 `primaryName` 时补全展示）。
  Future<Map<String, String>> loadEntityPrimaryNames(
    Iterable<String> entityIds,
  ) async {
    final factual = _factualRepository;
    if (factual == null) return const {};
    final ids = entityIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList();
    if (ids.isEmpty) return const {};
    try {
      final entities = await factual.getEntitiesByIds(
        state.session.sessionId,
        ids,
      );
      return {
        for (final entity in entities)
          if (entity.primaryName.trim().isNotEmpty)
            entity.entityId: entity.primaryName,
      };
    } catch (e) {
      _logger.warn('Entity primary name lookup failed', detail: '$e');
      return const {};
    }
  }

  /// 将草稿会话转为真实会话。发送首句时一并提交可恢复的 [firstInput]。
  ///
  /// 物化时快照所有字段（草稿值 > 全局默认快照值，"快照而非引用"语义），
  /// 与故事模式一致。
  Future<void> _materializeDraftSessionWith(
    ChatSession draft, {
    String? firstInput,
  }) async {
    final sessionId = _uuid.v4();
    _sessionOperations.reserveMaterializedId(sessionId);
    final persisted = await _runHistoryTransaction(() async {
      final session = await _createSessionWithDefaults(draft, sessionId);
      if (firstInput != null) {
        await _chatRepository.setDirectorPendingInput(
          session.sessionId,
          firstInput,
        );
      }
      return session;
    });
    _sessionOperations.adoptMaterializedId(persisted.sessionId);
    if (mounted) state = state.copyWith(session: persisted);
    // 卡路径：物化拿到真实 sessionId 后应用角色卡（资料通道建基线实体）。
    // 失败只记 warn 不阻断开聊——用户可随时在会话设置里手动应用同款卡。
    final cardId = draft.characterInitCardId;
    if (cardId != null && cardId.isNotEmpty && _resourceApplyService != null) {
      try {
        await _resourceApplyService.applyCharacterCard(
          sessionId: persisted.sessionId,
          cardId: cardId,
          defaultCharacterName: t.settings.resourceLibrary.unnamedCharacter,
          defaultSettingName: t.settings.resourceLibrary.unnamedSetting,
          duplicateErrorMessage:
              t.common.seedResource.duplicateCharacter(name: cardId),
        );
      } catch (e) {
        _logger.warn(
          'Wizard character card apply failed',
          detail: 'card=$cardId, error=$e',
        );
      }
    }
  }

  Future<ChatSession> _createSessionWithDefaults(
    ChatSession draft,
    String sessionId,
  ) async {
    final snapshot = await _configurationResolver.snapshotAdvancedDefaults();
    final realSession = await _chatRepository.createSession(
      title: draft.title,
      sessionId: sessionId,
      mode: draft.mode,
      modelId: draft.modelId,
      presetId: draft.presetId,
    );

    final mergedPhaseModels = ConfigurationResolver.directorGeneratingModels(
      draft.phaseModels,
      defaultPresetId: snapshot.phaseModels?.generatingPresetId,
      defaultModelId: snapshot.phaseModels?.generatingModelId,
    );

    final sessionWithDefaults = realSession.copyWith(
      temperature: draft.temperature ?? snapshot.temperature,
      topP: draft.topP ?? snapshot.topP,
      maxTokens: draft.maxTokens ?? snapshot.maxTokens,
      presencePenalty: draft.presencePenalty ?? snapshot.presencePenalty,
      frequencyPenalty: draft.frequencyPenalty ?? snapshot.frequencyPenalty,
      // 上下文配置收敛：停止快照 chat 死键
      //（autoCompaction/compactionThreshold——导演运行时从不消费）与
      // 故事三段式遗产 override（recentMin/retrieval——组装侧已定死，
      // 会话列不再合并）；存量会话列值保留但 inert。
      streamEnabled: draft.streamEnabled ?? snapshot.streamEnabled,
      systemPromptOverride: draft.systemPromptOverride ?? snapshot.systemPrompt,
      reasoningEffort: draft.reasoningEffort ?? snapshot.reasoningEffort,
      phaseModels: mergedPhaseModels,
      compactionTriggerRatioOverride: draft.compactionTriggerRatioOverride ??
          snapshot.contextBudget?.compactionTriggerRatio,
      // 新建物化补齐五列——此前 NULL 继承全局，
      // 违反快照宪法（不留跟随态）。retrievalOverrides 的「平衡」档=
      // 当前全局行为的具体快照（语义）。
      maxSteps: draft.maxSteps ?? snapshot.maxSteps,
      maxDurationMinutes:
          draft.maxDurationMinutes ?? snapshot.maxDurationMinutes,
      narrativePacing: draft.narrativePacing ?? snapshot.narrativePacing,
      toolPermissions: draft.toolPermissions ?? _encodeToolsSnapshot(snapshot),
      retrievalOverrides:
          draft.retrievalOverrides ?? RetrievalProfile.balanced.encode(),
      // 向导「初始化你的角色」两列随草稿物化（快照而非引用；null = 未启用）
      characterInitPrompt: draft.characterInitPrompt,
      characterInitCardId: draft.characterInitCardId,
    );

    return _chatRepository.updateSession(sessionWithDefaults);
  }

  /// 全局工具权限 → 12 工具完整 map 快照（会话列形态）
  ///
  /// 全局 advanced.tools 只含用户显式配置的键；快照宪法要求会话持
  /// 具体值——未配置键展开为内置默认 allow，此后改全局不影响本会话。
  static String? _encodeToolsSnapshot(GlobalDefaultsSnapshot snapshot) {
    final global = snapshot.toolPermissions ?? const <String, String>{};
    return ToolPermissions.toJson({
      for (final tool in ToolPermissions.allTools)
        tool: global[tool] ?? 'allow',
    });
  }

  /// 存量会话惰性物化——配置列 NULL（跟随态）→ 全局当前快照
  ///
  /// 全量快照化之前的导演会话，配置列可能未物化（null=
  /// 跟随全局）。打开会话时一次性复制全局当前值写回；全列有值时零写入。
  /// 例外（不进判定也不产生跟随漂移闭环）：
  /// - reasoningEffort：模型语义 carve-out（null=「模型自行决定」）；
  /// - phaseModels / effectiveContextLimit：null 的语义是**具体态**
  ///   （「全局 GM 未配置」/「无限制」）——列入判定会让此类会话每次
  ///   打开都重写；快照时 null 保持 null。全局后来配了值的漂移残留
  ///   由用户改这两项时写具体值自然覆盖。
  /// - systemPrompt：全局空快照物化为空串（空串=「无规则」具体态，
  ///   阻断 resolver 回退）。
  /// 仅导演会话（mode=advanced）；故事侧共享表由其自身路径处置。
  Future<void> _materializeSnapshotColumnsIfNeeded() async {
    if (state.session.mode != 'advanced') return;
    final session = state.session;
    final needsMaterialize = session.temperature == null ||
        session.topP == null ||
        session.maxTokens == null ||
        session.presencePenalty == null ||
        session.frequencyPenalty == null ||
        session.streamEnabled == null ||
        session.systemPromptOverride == null ||
        session.maxSteps == null ||
        session.maxDurationMinutes == null ||
        session.narrativePacing == null ||
        session.toolPermissions == null ||
        session.retrievalOverrides == null ||
        session.compactionTriggerRatioOverride == null;
    if (!needsMaterialize) return;
    try {
      final snapshot = await _configurationResolver.snapshotAdvancedDefaults();
      // 全空快照（读取失败回退的
      // const GlobalDefaultsSnapshot()，或用户从未配置任何导演设置）
      // 跳过物化——否则 systemPrompt 被钉死空串（'' 之后非空，全局后配
      // 的规则永远补不进）、工具权限被展开为全 allow。跳过后会话列保持
      // null，运行时 resolver 回退链兜底，行为与真默认一致。
      final isBlankFallback = snapshot.temperature == null &&
          snapshot.maxTokens == null &&
          snapshot.maxSteps == null &&
          snapshot.systemPrompt == null &&
          snapshot.toolPermissions == null;
      if (isBlankFallback) return;
      // await 期间用户可能已编辑会话列
      // （极速打开设置改模型）——重取最新会话为合并基线，物化只填充
      // 仍为 null 的列，防止用「开头捕获的旧 null 基线」覆盖用户刚写的值。
      if (!mounted) return;
      final current = state.session;
      // phaseModels 的 copyWith 非哨兵（显式 null 会崩类型转换）——全局
      // GM 未配置（快照 null）时保持会话原值（同为空=「未配置」态）
      final mergedPhaseModels = current.phaseModels.isAllEmpty
          ? (snapshot.phaseModels ?? current.phaseModels)
          : current.phaseModels;
      final updated = current.copyWith(
        temperature: current.temperature ?? snapshot.temperature,
        topP: current.topP ?? snapshot.topP,
        maxTokens: current.maxTokens ?? snapshot.maxTokens,
        presencePenalty: current.presencePenalty ?? snapshot.presencePenalty,
        frequencyPenalty: current.frequencyPenalty ?? snapshot.frequencyPenalty,
        streamEnabled: current.streamEnabled ?? snapshot.streamEnabled,
        systemPromptOverride:
            current.systemPromptOverride ?? (snapshot.systemPrompt ?? ''),
        effectiveContextLimit:
            current.effectiveContextLimit ?? snapshot.effectiveContextLimit,
        phaseModels: mergedPhaseModels,
        maxSteps: current.maxSteps ?? snapshot.maxSteps,
        maxDurationMinutes:
            current.maxDurationMinutes ?? snapshot.maxDurationMinutes,
        narrativePacing: current.narrativePacing ?? snapshot.narrativePacing,
        toolPermissions:
            current.toolPermissions ?? _encodeToolsSnapshot(snapshot),
        retrievalOverrides:
            current.retrievalOverrides ?? RetrievalProfile.balanced.encode(),
        compactionTriggerRatioOverride:
            current.compactionTriggerRatioOverride ??
                snapshot.contextBudget?.compactionTriggerRatio,
      );
      final persisted = await _chatRepository.updateSession(updated);
      state = state.copyWith(session: persisted);
      _logger.info(
        'Legacy director session snapshot materialized',
        detail: 'sessionId=${session.sessionId}',
      );
    } catch (e) {
      _logger.warn(
        'Legacy session snapshot materialization skipped',
        detail: '$e',
      );
    }
  }

  /// 发送用户消息，启动导演回合（agent loop）
  ///
  /// 返回值：true = 已消费（正常发送 **或** 进入单槽待发）；false = 被
  /// 拒收（如停止中或首句保存失败），调用方应把文本还给输入框。
  ///
  /// 生成中发送 → 单槽待发（state.queuedMessage）：轮正常结束后自动
  /// 发送一次；失败/停止不自动发。槽位已占用且未确认覆盖时返回 false
  ///（不静默丢弃已有待发）。
  Future<bool> sendMessage(
    String userInput, {
    bool overwriteQueued = false,
  }) async {
    if (canQueueMessage) {
      return _stageQueuedMessage(userInput, overwrite: overwriteQueued);
    }
    if (state.phase != IntermediatePhase.idle &&
        state.phase != IntermediatePhase.failed) {
      return false;
    }
    return _runSessionOperation(false, () => _sendMessage(userInput));
  }

  /// Queueing starts when the agent loop starts, after round preparation.
  bool get canQueueMessage =>
      _directorRunner.isGenerating &&
      !_streamRunner.isCancelled &&
      !state.isStopping;

  String? _retainedInput;
  bool _hasRetainedQueue = false;

  bool get hasRetainedInput => _retainedInput != null;

  ChatMessage _pendingUserMessage(String input) => ChatMessage(
        messageId: _uuid.v4(),
        sessionId: state.session.sessionId,
        role: 'user',
        content: input,
        createdAt: DateTime.now(),
      );

  Future<bool> _sendMessage(String userInput) async {
    if (state.engineeringMode == EngineeringRuntimeMode.recoveryRequired) {
      return false;
    }
    if ((state.isAwaitingFirstRound || hasRetainedInput) &&
        _retainedInput != userInput &&
        !await _saveRetainedInput(userInput)) {
      return false;
    }
    if (!mounted) return true;

    // failed 态直发：先事务性清掉失败轮残留（旧 pending 气泡/直播块/
    // 步骤/失败上下文/_round），不留幽灵态再走正常首发链。
    var next = state;
    if (next.phase == IntermediatePhase.failed ||
        next.pendingUserMessage != null) {
      _round = null;
      next = next.clearTemporary();
    }

    state = next.copyWith(
      userInput: userInput,
      pendingUserMessage: _pendingUserMessage(userInput),
      regenerateTurnNumber: null,
      suggestReplies: [],
      isGeneratingSuggest: false,
      suggestExpanded: false,
      suggestFailure: null,
    );
    await _prepareAndRunRound();
    return true;
  }

  /// 保存首句后才消费输入。失败时调用方仍可把文字交还编辑框。
  Future<bool> _saveRetainedInput(String input) async {
    try {
      // 比发送更早排队的编辑框写入必须先完成。
      await _inputWrites;
      if (!mounted) return false;
      if (isDraftSession) {
        await _materializeDraftSessionWith(state.session, firstInput: input);
      } else {
        final sessionId = state.session.sessionId;
        await _runHistoryTransaction(() async {
          await _chatRepository.setDirectorPendingInput(sessionId, input);
          if (!hasRetainedInput) {
            await _chatRepository.setSessionDraft(sessionId, null);
          }
        });
      }
      _retainedInput = input;
      return true;
    } catch (e, stackTrace) {
      _logger.error(
        'Persist director input failed',
        detail: e.runtimeType.toString(),
        stackTrace: stackTrace,
      );
      return false;
    }
  }

  Future<void> _inputWrites = Future<void>.value();
  Future<bool>? _queueWrite;
  bool _dispatchQueuedOnRelease = false;

  Future<bool> _stageQueuedMessage(
    String text, {
    required bool overwrite,
  }) async {
    if (state.queuedMessage != null && !overwrite) return false;
    final retained = hasRetainedInput || _hasRetainedQueue;
    return _updateQueuedMessage(
      text: text,
      retained: retained,
      save: retained
          ? (id) => _chatRepository.setDirectorQueuedInput(id, text)
          : (id) => _chatRepository.setSessionDraft(id, text),
    );
  }

  /// 撤回待发消息，文本返回给输入框。
  Future<String?> withdrawQueuedMessage() async {
    final queued = state.queuedMessage;
    if (queued == null) return null;
    final saved = await _updateQueuedMessage(
      text: null,
      retained: false,
      save: _hasRetainedQueue
          ? (id) => _runHistoryTransaction(() async {
                await _chatRepository.setSessionDraft(id, queued);
                await _chatRepository.setDirectorQueuedInput(id, null);
              })
          : (id) => _chatRepository.setSessionDraft(id, null),
    );
    return saved ? queued : null;
  }

  Future<bool> _updateQueuedMessage({
    required String? text,
    required bool retained,
    required Future<void> Function(String sessionId) save,
  }) async {
    if (_queueWrite != null) return false;
    final write = _writeInput(save);
    if (write == null) return false;
    final publishing = _queueWrite = write.then((saved) {
      if (saved && mounted) {
        _hasRetainedQueue = retained;
        state = state.copyWith(queuedMessage: text);
      }
      return saved;
    });
    try {
      return await publishing;
    } finally {
      _queueWrite = null;
    }
  }

  /// 编辑框与待发写入顺序一致，写入成功后才接收新的待发文本。
  Future<bool>? _writeInput(Future<void> Function(String sessionId) save) {
    final release = _sessionOperations.tryBeginWrite();
    if (release == null) return null;
    final sessionId = state.session.sessionId;
    final write = _inputWrites.then((_) async {
      try {
        await save(sessionId);
        return true;
      } catch (e) {
        _logger.warn(
          'Persist director draft failed',
          detail: e.runtimeType.toString(),
        );
        return false;
      } finally {
        release();
      }
    });
    _inputWrites = write.then<void>((_) {});
    return write;
  }

  /// 普通编辑草稿独立于保全的首句及同轮待发。
  Future<void> persistInputDraft(String? text) async {
    final sharesDraftColumn = !hasRetainedInput && !_hasRetainedQueue;
    if (sharesDraftColumn &&
        (_queueWrite != null || state.queuedMessage != null)) {
      return;
    }
    await _writeInput((id) => _chatRepository.setSessionDraft(id, text));
  }

  void _dispatchAfterRelease() {
    if (!_dispatchQueuedOnRelease) return;
    _dispatchQueuedOnRelease = false;
    if (mounted) unawaited(dispatchQueuedMessageAfterRound());
  }

  /// 正常收稿并完成上一轮收尾后，取得新一轮的占用再取出待发文本。
  Future<void> dispatchQueuedMessageAfterRound() async {
    if (state.phase != IntermediatePhase.idle) return;
    await _runSessionOperation<void>(null, () async {
      final queued = state.queuedMessage;
      if (queued == null || queued.isEmpty) return;
      final saved = await _updateQueuedMessage(
        text: null,
        retained: false,
        save: _hasRetainedQueue
            ? (id) async {
                await _runHistoryTransaction(() async {
                  await _chatRepository.setDirectorPendingInput(id, queued);
                  await _chatRepository.setDirectorQueuedInput(id, null);
                });
                _retainedInput = queued;
              }
            : (id) => _chatRepository.setSessionDraft(id, null),
      );
      if (!saved || !mounted) return;
      await _sendMessage(queued);
    });
  }

  /// 解析单次请求实际使用的 contextWindow（与故事模式同规则）
  int _resolveContextWindow(int? effectiveContextLimit, int? modelWindow) {
    final resolved = modelWindow ?? ConfigurationResolver.defaultContextWindow;
    if (effectiveContextLimit == null || effectiveContextLimit <= 0) {
      return resolved;
    }
    return effectiveContextLimit < resolved ? effectiveContextLimit : resolved;
  }

  /// 准备并启动导演回合。
  ///
  /// 配置解析/校验与故事模式共用同一套（含 extracting 配置校验，
  /// 保持与原 kernel swap 分支完全一致的行为），差异仅在最后分派：
  /// 故事模式进入六步管线，导演模式进入 [DirectorRoundRunner]。
  Future<void> _prepareAndRunRound({bool cleanupAttemptEvents = true}) async {
    if (state.isStopping) return;
    _streamRunner.resetCancelled();
    _backgroundInterrupted = false;

    state = state.copyWith(
      phase: IntermediatePhase.extracting,
      agentActivity: AgentActivity.waitingResponse,
      agentActivityStepIndex: 0,
      failureContext: null,
      liveBlocks: const [],
      retryCounts: {},
      // 上一轮的步骤随 liveBlocks 一起清——否则轮前压缩期（一次
      // LLM 调用，可达数十秒）旧步骤以 live 微光复活成假直播
      clearAgentSteps: true,
    );

    AdvancedConfig config;
    try {
      config = await _getConfig();
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to load advanced config',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      await _fail(
        IntermediatePhase.generating,
        'E010',
        error: e,
        errorCategory: ErrorCategory.config,
      );
      return;
    }

    try {
      final resolved = await _configurationResolver.resolveAdvancedSettings(
        state.session,
      );
      final settings = resolved.settings;
      // 导演无六步 phase：模型仅 generating（GM）一条解析链，
      // RoundContext 的其余结构字段统一回退同值（E010 校验同源）。
      final generatingNamingConfig =
          await _configurationResolver.resolveAdvancedGeneratingNamingConfig(
        state.session,
      );
      if (generatingNamingConfig == null ||
          generatingNamingConfig.baseUrl.isEmpty ||
          generatingNamingConfig.apiKey.isEmpty ||
          generatingNamingConfig.modelId.isEmpty) {
        await _fail(
          IntermediatePhase.generating,
          'E010',
          errorCategory: ErrorCategory.config,
          suggestionOverride: t.advanced.failure.gmMissing,
        );
        return;
      }
      final generatingModelWindow =
          await _configurationResolver.resolveContextWindowForPhase(
        presetId: generatingNamingConfig.presetId,
        modelId: generatingNamingConfig.modelId,
      );
      final contextWindow = _resolveContextWindow(
        settings.effectiveContextLimit,
        generatingModelWindow,
      );

      final filtered = await _loadFilteredMessages(state.session.sessionId);
      // 重新生成时 user_N 仍持久化在库中（Fork 语义），重载的 history
      // 末尾就是本轮输入；不剔除会让同一条用户消息进上下文两次。
      final history = state.regenerateTurnNumber != null
          ? stripTrailingDuplicateUserInput(
              filtered.messages,
              state.userInput!,
            )
          : filtered.messages;
      //  修复：同步最新压缩基数到 state（UI 的 artifacts 键查找同用此值）
      // 同步 next_turn 计数器镜像（persist 成功后 state.session 与 DB 同源）
      state = state.copyWith(
        compactedTurnBase: filtered.compactedTurnBase,
        session: filtered.nextTurn == null
            ? null
            : state.session.copyWith(nextTurn: filtered.nextTurn),
      );

      final embeddingConfig =
          await _configurationResolver.resolveAdvancedEmbeddingConfig();

      final timeouts = await _configurationResolver.resolveTimeouts();

      final mergedConfig = _applyContextBudgetOverride(
        config.storyRuntime,
        settings,
      );

      // 上下文用量指示 §3.1：容量与触发线存入 state（与
      // _runDirectorCompactionPhase 的 shouldCompact 同源同值）
      state = state.copyWith(
        contextWindowTokens: contextWindow,
        compactionTriggerTokens: _directorCompactionTrigger(
          contextWindow: contextWindow,
          config: mergedConfig,
          naming: generatingNamingConfig,
          settings: settings,
        ),
      );

      _round = RoundContext(
        userInput: state.userInput!,
        history: history,
        settings: settings,
        generatingNamingConfig: generatingNamingConfig,
        extractNamingConfig: generatingNamingConfig,
        reviewingNamingConfig: generatingNamingConfig,
        summarizeNamingConfig: generatingNamingConfig,
        contextWindow: contextWindow,
        config: mergedConfig,
        embeddingConfig: embeddingConfig,
        //  turn 单一事实源：本轮轮号轮前一次定值，全轮复用
        //（重生成 = regenerateTurnNumber；普通 = next_turn ?? 公式，
        // 公式输入用 state.messages 轮前视图），与故事模式同口径。
        turnNumber: state.regenerateTurnNumber ??
            resolveTurnNumber(
              nextTurn: filtered.nextTurn,
              compactedTurnBase: filtered.compactedTurnBase,
              messages: state.messages,
            ),
        connectTimeout: timeouts.connectTimeout,
        readTimeout: timeouts.readTimeout,
        currentNarrativeTime: state.session.currentNarrativeTime,
        // 工程上下文模式（导演实验）：正常开启态注入 true；需要修复态
        // 发送入口已拦截，轮次不启动。
        engineeringContextEnabled:
            state.engineeringMode == EngineeringRuntimeMode.normalOpen,
      );

      // 回填持久化压缩摘要（2026-08-22 修复，与故事模式同构）：摘要消息是
      // system 角色，不会进入各阶段消息组装；不回填会导致压缩后摘要从请求中
      // 消失、压缩退化为每次从零重写、缓存前缀在次轮断裂。
      _round!.compactionSummary =
          StoryCompactionService.extractPersistedSummary(history);

      //（预算/HITL/doom-loop/子代理，导演设置）
      // runRound 经统一 catch-all 出口（_runDirectorRoundGuarded，
      // 见 retry part）——persist 嵌入等未被阶段内捕获的异常不再逃逸成
      // Zone uncaught；此处 try 块继续兜住轮前配置解析段。
      await _runDirectorRoundGuarded(
        _round!,
        tuning: DirectorRoundTuning.fromConfig(config),
        cleanupAttemptEvents: cleanupAttemptEvents,
      );
    } catch (e, stackTrace) {
      _logger.error(
        'Extract phase setup failed',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      // 导演无六步 phase，报点阶段统一 generating
      //（与 runner E010 / _getConfig catch 同口径）
      await _fail(
        IntermediatePhase.generating,
        'E010',
        error: e,
        errorCategory: ErrorCategory.config,
      );
    }
  }

  /// 合并会话级压缩阈值到运行时聚合（快照独立模式）
  ///
  /// 2026-09-13 上下文配置收敛：导演唯一上下文旋钮是压缩阈值
  ///（compactionTriggerRatio）。recentMin/retrieval 是故事三段式遗产，
  /// 组装侧已定死（[DirectorContextBudgetPin]），会话列不再合并——
  /// 存量会话列值保留但 inert。
  StoryRuntimeConfig _applyContextBudgetOverride(
    StoryRuntimeConfig config,
    ChatSessionSettings settings,
  ) {
    // 触发线钳制到导演 UI 域 [0.30, 0.80]（会话覆盖与全局都过钳制，
    // 手改配置/导入备份的域外值不再直达运行时）；钳制与导演定值形态
    // 收敛于 DirectorContextBudgetPin.directorClamped 单源。
    final sessionCompactionTrigger = settings.compactionTriggerRatioOverride;
    final globalBudget = config.contextBudget;
    final mergedBudget = globalBudget.directorClamped(
      sessionOverride: sessionCompactionTrigger,
    );
    if (sessionCompactionTrigger == null &&
        mergedBudget.compactionTriggerRatio ==
            globalBudget.compactionTriggerRatio) {
      return config;
    }

    return config.copyWith(contextBudget: mergedBudget);
  }

  /// 取消：停止 agent 循环 + 清理临时状态。
  ///
  /// 直播正文已流出非空文本段时不再丢弃——与失败路径同款保留（直播
  /// 块与稿件卡原样留在时间线），进「已停止」failed 态，失败栏提供
  /// 「从中断处继续/整轮重试」出口（文案区分：手动停止非错误）。
  Future<void> cancel() async {
    if (state.isStopping) return;
    if (state.phase == IntermediatePhase.idle ||
        state.phase == IntermediatePhase.failed) {
      return;
    }

    // Phase 1：立即更新状态（同步部分）
    final isMaintenanceConverge = state.inMaintenancePhase && _round != null;
    final cancelFuture = _streamRunner.cancel();
    _sessionOperations.interruptRetryWait();
    _directorRunner.cancelRound('用户停止');
    if (isMaintenanceConverge) {
      // 任务一已锁定并交付正文：维护阶段取消走收尾收敛，保留 _round 与当前阶段，
      // 放行随后的单事务持久化而不落入 failed(user_stopped)。
      state = state.copyWith(isStopping: true);
      unawaited(
        _waitForCancelCompletion(cancelFuture, resetStreamAfter: true),
      );
      return;
    }
    // 在途压缩显式作废（表面没变≠取消后有提交资格）
    await _engineeringCompaction?.invalidateActive(
      state.session.sessionId,
      'user-stop',
    );

    final hasManuscript = state.liveBlocks.any(
      (b) => b.kind == AgentLiveBlockKind.text && !b.isEmpty,
    );
    if (hasRetainedInput || (hasManuscript && _round != null)) {
      // 保留路径：_round 不清（「从中断处继续」复用已完成产出），
      // pending 气泡与直播块保持（与失败态呈现同构）。
      state = state.copyWith(
        phase: IntermediatePhase.failed,
        failureContext: FailureContext(
          errorCode: 'user_stopped',
          failedPhase: IntermediatePhase.generating,
          errorMessage: t.intermediate.chat.failure.stopped,
          retryable: true,
        ),
        isStopping: true,
      );
      unawaited(
        _waitForCancelCompletion(cancelFuture, resetStreamAfter: true),
      );
      return;
    }

    _round = null;
    state = state.clearTemporary().copyWith(
          pendingUserMessage: null,
          isStopping: true,
        );

    // Phase 2：后台等待清理完成，然后解除 isStopping
    unawaited(_waitForCancelCompletion(cancelFuture));
  }

  /// 后台等待取消 Future 完成，然后清除 isStopping（3 秒超时兜底）。
  ///
  /// [resetStreamAfter]：停止保留半截正文的分支置 true——订阅取消完成后
  /// 复位流式取消标志（先于 isStopping 清除）；否则收稿后的续跑/重试
  /// 出口不经 _prepareAndRunRound，后续流式事件会被残留标志丢弃。
  Future<void> _waitForCancelCompletion(
    Future<void> cancelFuture, {
    bool resetStreamAfter = false,
  }) async {
    final operationDone = _sessionOperations.completion;
    try {
      await cancelFuture.timeout(const Duration(seconds: 3));
    } catch (_) {
      // 超时或异常都视为清理完成
    }
    await operationDone;
    if (!mounted) return;
    if (resetStreamAfter) {
      _streamRunner.resetCancelled();
    }
    if (state.isStopping) {
      state = state.copyWith(isStopping: false);
    }
  }

  /// 清空 [AdvancedChatState.userInput]
  void clearUserInput() {
    state = state.copyWith(userInput: null);
  }

  /// App 切到后台时主动中断生成（由 `MainLayout._handleAppPaused` 调用）
  void onBackgroundInterrupt() {
    if (state.phase == IntermediatePhase.idle ||
        state.phase == IntermediatePhase.failed) {
      return;
    }
    _backgroundInterrupted = true;
    //  修复：与 cancel 对齐，同时终止 agent 循环。
    // 此前只 cancel 流式 runner——导演轮的 agent 循环会在后台继续烧 token，
    // 回前台后 recoverIfStuck 清空 state、runPersistPhase 静默放弃，
    // 整轮 LLM 消费无产出且无任何提示（僵尸轮）。
    _directorRunner.cancelRound('后台中断');
    _streamRunner.cancel();
    _sessionOperations.interruptRetryWait();
  }

  /// 检测并恢复卡死状态（App 从后台恢复时调用）
  ///
  /// 仅依赖后台中断标志。：导演轮全程不经
  /// StreamRunner 跑流（正文走 agent gateway），`!_streamRunner.isStreaming`
  /// 对进行中的导演轮恒为真——沿用故事模式的"流式阶段 + runner 空判"会把
  /// 活轮误判为卡死：只清 UI 态不取消 agent 循环，复活僵尸轮（修复在
  /// 桌面/Web 上反被此路径绕开）。后台真实中断由 [onBackgroundInterrupt]
  /// 置位标志并 cancelRound，此处负责恢复态。
  bool recoverIfStuck() {
    if (_backgroundInterrupted) {
      _backgroundInterrupted = false;
      // 直播正文已流出非空文本段：与手动停止同款保留半截正文——
      // 进「已停止」failed 态而非清场回 idle（失败栏给继续/重试出口）。
      final hasManuscript = state.liveBlocks.any(
        (b) => b.kind == AgentLiveBlockKind.text && !b.isEmpty,
      );
      if (hasRetainedInput || (hasManuscript && _round != null)) {
        state = state.copyWith(
          phase: IntermediatePhase.failed,
          failureContext: FailureContext(
            errorCode: 'user_stopped',
            failedPhase: IntermediatePhase.generating,
            errorMessage: t.intermediate.chat.failure.stopped,
            retryable: true,
          ),
          isStopping: false,
        );
        // 出口（继续/重试）不经 _prepareAndRunRound，同 cancel 复位标志
        _streamRunner.resetCancelled();
        return true;
      }
      _round = null;
      state = state.clearTemporary().copyWith(
            pendingUserMessage: null,
            isStopping: false,
          );
      return true;
    }
    return false;
  }

  // ==================== 会话标题更新与自动命名 ====================

  /// 自动命名写回的 CAS 允许集合——草稿标题与
  /// 空串；首轮在途期间用户手动重命名的会话不被自动命名覆盖
  ///（此前 advanced 侧无任何标题守卫，TOCTOU 窗口=整轮生成时长）。
  Set<String> get _autoNameAllowedTitles => <String>{
        '',
        t.advanced.home.newDirector,
      };

  /// 手动或自动更新会话标题
  ///
  /// [force] 为 true 时（手动触发）：
  /// - 绕过「仅对默认草稿标题自动命名」的限制，覆盖现有标题；
  /// - 失败时不落截断名（保持原标题不变）；
  /// - CAS 集合将当前会话标题纳入允许覆盖集合；
  /// - 返回是否成功写入了新标题（UI 据此提示 SnackBar）。
  Future<bool> updateTitle({
    bool force = false,
    String? userInput,
    String? assistantReply,
  }) async {
    final result = await updateTitleWithResult(
      force: force,
      userInput: userInput,
      assistantReply: assistantReply,
    );
    return result.updated;
  }

  Future<DirectorTitleUpdateResult> updateTitleWithResult({
    bool force = false,
    String? userInput,
    String? assistantReply,
  }) async {
    if (!mounted || (force && _titleNamingInFlight)) {
      return (updated: false, failure: null);
    }
    if (state.phase != IntermediatePhase.idle &&
        state.phase != IntermediatePhase.failed) {
      return (updated: false, failure: null);
    }
    if (force) _titleNamingInFlight = true;
    try {
      return await _performTitleUpdate(
        force: force,
        userInput: userInput,
        assistantReply: assistantReply,
      );
    } finally {
      if (force) _titleNamingInFlight = false;
    }
  }

  /// 对标 ChatModeController 的同名别名
  Future<bool> updateTitleFromSummary({bool force = false}) =>
      updateTitle(force: force);

  /// 执行标题生成与写回核心流程
  Future<DirectorTitleUpdateResult> _performTitleUpdate({
    required bool force,
    String? userInput,
    String? assistantReply,
  }) async {
    final session = state.session;
    try {
      final currentTitle = session.title;
      final allowedTitles = <String>{..._autoNameAllowedTitles};
      final isDraftTitle = allowedTitles.contains(currentTitle);
      if (!force && !isDraftTitle) {
        return (updated: false, failure: null);
      }
      if (force) {
        allowedTitles.add(currentTitle);
      }

      var effectiveUser = userInput;
      var effectiveAssistant = assistantReply;

      if (effectiveUser == null || effectiveAssistant == null) {
        final nonSystemMessages =
            state.messages.where((m) => m.role != 'system').toList();
        if (nonSystemMessages.isNotEmpty) {
          final firstUser =
              nonSystemMessages.firstWhereOrNull((m) => m.role == 'user');
          final firstAssistant =
              nonSystemMessages.firstWhereOrNull((m) => m.role == 'assistant');
          effectiveUser ??= firstUser?.content;
          effectiveAssistant ??= firstAssistant?.content;
        }
        if (effectiveUser == null) {
          final summary = state.messages.firstWhereOrNull((m) => m.isSummary);
          effectiveUser = summary?.content;
        }
      }

      if (effectiveUser == null || effectiveUser.trim().isEmpty) {
        return (
          updated: false,
          failure: const AuxiliaryGenerationFailure(
            AuxiliaryGenerationFailureKind.noConversation,
          ),
        );
      }
      effectiveAssistant ??= '';

      final namingConfig =
          await _configurationResolver.resolveTitleNamingConfig() ??
              await _configurationResolver
                  .resolveAdvancedGeneratingNamingConfig(session);
      final AuxiliaryGenerationResult<String> generated;
      if (namingConfig == null) {
        generated = (
          value: null,
          failure: const AuxiliaryGenerationFailure(
            AuxiliaryGenerationFailureKind.modelOrKeyUnavailable,
          ),
        );
      } else {
        final timeouts = await _configurationResolver.resolveTimeouts();
        final generator = _titleGenerator ??
            SessionTitleGenerator(llmService: _llmService, logger: _logger);
        generated = await generator.generateWithResult(
          userMessage: effectiveUser,
          assistantReply: effectiveAssistant,
          namingConfig: namingConfig,
          connectTimeout: timeouts.connectTimeout,
          readTimeout: timeouts.readTimeout,
        );
      }
      if (!mounted || state.session.sessionId != session.sessionId) {
        return (updated: false, failure: null);
      }
      final titleToWrite = generated.value ??
          (force
              ? null
              : SessionTitleGenerator.fallbackTitle(
                  effectiveUser,
                  defaultTitle: t.advanced.home.newDirector,
                ));

      if (titleToWrite == null || titleToWrite.trim().isEmpty) {
        return (updated: false, failure: generated.failure);
      }

      final bool written;
      try {
        written = await _chatRepository.updateSessionTitleIfCurrentTitleIn(
          session.sessionId,
          titleToWrite,
          allowedTitles,
        );
      } catch (_) {
        return (
          updated: false,
          failure: const AuxiliaryGenerationFailure(
            AuxiliaryGenerationFailureKind.saveFailed,
          ),
        );
      }
      if (!written) {
        return (
          updated: false,
          failure: const AuxiliaryGenerationFailure(
            AuxiliaryGenerationFailureKind.titleChanged,
          ),
        );
      }

      if (mounted && state.session.sessionId == session.sessionId) {
        state = state.copyWith(
          session: state.session.copyWith(title: titleToWrite),
        );
      }
      return (updated: true, failure: generated.failure);
    } catch (e) {
      return (
        updated: false,
        failure: AuxiliaryGenerationFailure.fromException(e),
      );
    }
  }

  /// 首轮 persist 成功后异步生成会话标题（不阻塞 UI）
  Future<void> _autoNameSession({
    required String userInput,
    required String assistantReply,
  }) async {
    final result = await updateTitleWithResult(
      userInput: userInput,
      assistantReply: assistantReply,
    );
    final failure = result.failure;
    if (failure != null &&
        failure.kind != AuxiliaryGenerationFailureKind.titleChanged) {
      _logger.warn(
        result.updated
            ? 'Director automatic title used fallback'
            : 'Director automatic title unavailable',
        detail: failure.diagnostic,
      );
    }
  }

  // ==================== DirectorHost 实现 ====================

  /// dispose 后 runner 取消收尾仍会读写 storyState
  ///（取消分支的 `state = state.copyWith(phase: idle)` 先读后写）——
  /// StateNotifier.state 的 getter/setter 在 debug 下对已 dispose 实例
  /// 断言 mounted。dispose 时拍最后一次状态快照：读走快照，写静默丢弃
  ///（宿主已销毁，写无意义）。仅在 !mounted（= dispose 已执行）时读，
  /// 赋值先于 super.dispose()，late final 不会未初始化读取。
  late final AdvancedChatState _storyStateAtDispose;

  @override
  AdvancedChatState get storyState => mounted ? state : _storyStateAtDispose;

  @override
  set storyState(AdvancedChatState value) {
    if (!mounted) return;
    state = value;
  }

  @override
  RoundContext? get currentRound => _round;

  @override
  bool get isStreamCancelled => _streamRunner.isCancelled;

  @override
  Logger get logger => _logger;

  @override
  Future<void> failRound(
    IntermediatePhase phase,
    String errorCode, {
    Object? error,
    ErrorCategory? errorCategory,
    StoryRuntimeConfig? config,
  }) {
    return _fail(
      phase,
      errorCode,
      error: error,
      errorCategory: errorCategory,
      config: config,
    );
  }

  @override
  Future<void> runPersistPhase(RoundContext round) => _runPersistPhase(round);

  @override
  Future<Float32List?> resolveQueryVector(String queryText) =>
      _resolveQueryVector(queryText);

  @override
  LlmService get llmService => _llmService;

  @override
  ProviderToolCapabilities? get capabilitiesOverride => _capabilitiesOverride;

  @override
  ExperienceRepository get experienceRepository => _experienceRepository;

  @override
  FactualRepository? get factualRepository => _factualRepository;

  @override
  AgentEventLogStore? get agentEventLogRepository => _agentEventLogRepository;

  @override
  StoryCompactionService? get compactionService => _compactionService;

  @override
  Future<List<ChatMessage>> loadSessionMessages(String sessionId) =>
      _chatRepository.getMessages(sessionId);

  @override
  Future<Map<int, StoryRoundArtifacts>> loadSessionArtifacts(
    String sessionId,
  ) =>
      _persistenceService.loadArtifactsBySession(sessionId);

  // ==================== 记忆管理（导演设置）====================

  /// 重建本会话向量索引（对齐故事面板 memoryManagement 组能力）。
  ///
  /// 配置源为 advanced 段（embedding 模型 / microVectorizeThreshold），
  /// 逻辑与故事侧 IntermediateChatController.rebuildEmbeddings 同构：
  /// 仅 idle 允许；逐条向量化，单条失败跳过不中断。
  Future<({int total, int succeeded, int failed, String? failureReason})>
      rebuildEmbeddings({
    required void Function(int processed, int total, int failed) onProgress,
  }) async {
    if (state.phase != IntermediatePhase.idle) {
      return (total: 0, succeeded: 0, failed: 0, failureReason: 'busy');
    }

    final embeddingConfig =
        await _configurationResolver.resolveAdvancedEmbeddingConfig();
    if (embeddingConfig == null) {
      return (
        total: 0,
        succeeded: 0,
        failed: 0,
        failureReason: 'not_configured',
      );
    }

    // 与持久化时的两级向量化策略对齐：低于阈值的记忆有意不建索引
    final microVectorizeThreshold =
        (await _getConfig()).retrieval.microVectorizeThreshold;

    // 以会话最近写入维度为基准并入陈旧行（维度不符
    // 的旧向量被检索静默跳过，重建即自愈），与故事侧 rebuildEmbeddings 同构。
    final expectedDimensions = await _experienceRepository
        .getLatestEmbeddingDimensions(state.session.sessionId);
    final memories = await _experienceRepository.getMemoriesWithoutEmbedding(
      state.session.sessionId,
      minImportance: microVectorizeThreshold,
      expectedDimensions: expectedDimensions,
    );
    if (memories.isEmpty) {
      return (total: 0, succeeded: 0, failed: 0, failureReason: null);
    }

    var succeeded = 0;
    var failed = 0;
    for (var i = 0; i < memories.length; i++) {
      final memory = memories[i];
      try {
        final embedding = await _embeddingService.embed(
          text: buildMemoryEmbeddingText(memory),
          // 重建索引是入库文本侧（非对称模型注入 input_type=passage）
          kind: EmbeddingInputKind.passage,
          model: embeddingConfig.model,
          baseUrl: embeddingConfig.baseUrl,
          apiKey: embeddingConfig.apiKey,
          timeout: Duration(milliseconds: embeddingConfig.timeoutMs),
        );
        await _experienceRepository.updateEmbedding(
          memory.memoryId,
          embedding,
        );
        succeeded++;
      } catch (e) {
        _logger.warn(
          'Rebuild embedding failed for memory ${memory.memoryId}',
          detail: '$e',
        );
        failed++;
      }
      onProgress(i + 1, memories.length, failed);
    }

    _logger.info(
      'Director rebuild embeddings completed',
      detail: 'total=${memories.length} succeeded=$succeeded failed=$failed',
    );
    return (
      total: memories.length,
      succeeded: succeeded,
      failed: failed,
      failureReason: null,
    );
  }

  /// 本会话待向量化的记忆数（重建按钮徽标；按 advanced 微摘要阈值筛选）。
  ///
  /// 拆分两口径——`missing` 未向量化、`stale` 有向量
  /// 但维度与基准不符（换嵌入模型后的陈旧行，重建即自愈）。
  Future<({int missing, int stale})> pendingEmbeddingCount() async {
    try {
      final microVectorizeThreshold =
          (await _getConfig()).retrieval.microVectorizeThreshold;
      // 并入维度不符的陈旧行，按 hasEmbedding 拆分两口径供设置页分列
      final expectedDimensions = await _experienceRepository
          .getLatestEmbeddingDimensions(state.session.sessionId);
      final memories = await _experienceRepository.getMemoriesWithoutEmbedding(
        state.session.sessionId,
        minImportance: microVectorizeThreshold,
        expectedDimensions: expectedDimensions,
      );
      return (
        missing: memories.where((m) => !m.hasEmbedding).length,
        stale: memories.where((m) => m.hasEmbedding).length,
      );
    } catch (e) {
      _logger.warn('Count memories without embedding failed', detail: '$e');
      return (missing: 0, stale: 0);
    }
  }

  // ==================== HITL 薄委托 ====================

  /// 回答待决的 ask_user（null = 跳过）
  void answerDirectorAsk(String? answer) =>
      _directorRunner.answerDirectorAsk(answer);

  /// 处置待确认写入（allow=false 可带反馈； always=本会话总是允许）
  void resolveDirectorApproval({
    required bool allow,
    String? feedback,
    bool always = false,
  }) =>
      _directorRunner.resolveDirectorApproval(
        allow: allow,
        feedback: feedback,
        always: always,
      );

  /// 当前生效的本会话审批放行工具数（设置面板展示用）
  int get sessionApprovalAllowCount =>
      _directorRunner.sessionApprovalAllowCount;

  /// 清除本会话审批放行（设置面板入口）；返回清除前生效的工具数
  int clearSessionApprovalAllows() =>
      _directorRunner.clearSessionApprovalAllows();

  @override
  void dispose() {
    _sessionOperations.interruptRetryWait();
    // dispose 先取消进行中导演轮再清理——
    // a) cancelRound 同步段打取消令牌并作废挂起 HITL（agent 网关已把
    //    令牌桥到 HTTP 层，进行中的流式请求随即中断），agent 循环在下一
    //    检查点退出，不再对孤儿 notifier 继续烧 token；
    // b) 丢弃直播合帧残段并销毁其 32ms Timer——Timer 到期的 onFlush 会
    //    对已 dispose 的 StateNotifier 写 state（StateError）。
    _directorRunner
      ..cancelRound('controller disposed', flushPending: false)
      ..discardLiveDeltas();
    // dispose 冲刷压缩缓冲——压缩流
    // 中途控制器被销毁时，挂起尾段落账后销毁 Timer；否则 32ms 后 Timer
    // 回调对已 dispose 的 StateNotifier 写 state（StateError）。
    _flushManualCompactionDeltas();
    _streamRunner.cleanup();
    // dispose 后 runner 收尾仍会读 storyState（见 [_storyStateAtDispose]）
    _storyStateAtDispose = state;
    super.dispose();
  }
}
