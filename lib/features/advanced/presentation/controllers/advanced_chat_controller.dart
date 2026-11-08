import 'dart:async';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/config/output_token_policy.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/llm/tool_calling/provider_tool_capabilities.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/throttled_delta_buffer.dart';
import 'package:lmstory/core/utils/token_counter.dart';
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
import 'package:lmstory/features/advanced/domain/services/director_core_blocks.dart';
import 'package:lmstory/features/advanced/domain/services/latest_usage_probe.dart';
import 'package:lmstory/features/advanced/presentation/controllers/director_host.dart';
import 'package:lmstory/features/advanced/presentation/controllers/director_round_runner.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_mode.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session_settings.dart';
import 'package:lmstory/features/chat/domain/entities/session_phase_models.dart';
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
import 'package:lmstory/features/resource_library/domain/services/resource_apply_service.dart';
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
    SessionTitleGenerator? titleGenerator,
    MemoryConsolidator? consolidator,
    // 事实层仓库（agent loop 的 query_facts/update_facts 用；
    // nullable 向后兼容旧测试，仅在缺失时 E010）
    FactualRepository? factualRepository,
    // durable 事件日志仓库（事件日志 + 崩溃恢复；nullable 向后兼容旧测试）
    AgentEventLogStore? agentEventLogRepository,
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
        _compactionService = compactionService,
        _resourceApplyService = resourceApplyService,
        _capabilitiesOverride = capabilitiesOverride,
        _streamRunner = StreamRunner(llmService: llmService),
        super(AdvancedChatState.initial(session)) {
    // 与故事模式一致：构造函数加载历史（会话切换时 State 复用兜底）
    loadHistory();
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

  /// CompactionPoint 压缩服务（导演轮轮前压缩）
  final StoryCompactionService? _compactionService;

  /// 资源应用服务（向导「初始化你的角色」卡路径：物化时应用卡）
  final ResourceApplyService? _resourceApplyService;

  /// 可选显式能力画像覆盖（Demo 作用域等受控环境注入；null 走生产默认解析）
  final ProviderToolCapabilities? _capabilitiesOverride;

  /// manualCompact 摘要增量合帧缓冲（见 [_onManualCompactionDelta]）
  ThrottledDeltaBuffer? _manualCompactionDeltaBuffer;

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

  // ==================== 主流程 ====================

  /// 加载历史消息（非草稿会话；生成中绝不 reload）
  Future<void> loadHistory() async {
    if (isDraftSession) return;
    if (state.phase != IntermediatePhase.idle) return;
    // loading 骨架置位在首个 await 之前——同步段完成，重会话
    // 打开首帧即骨架，不闪空态引导
    state = state.copyWith(loadingHistory: true);
    try {
      // 按最新 CompactionPoint 过滤已压缩的旧消息（与故事模式一致）
      final sessionId = state.session.sessionId;
      final historyParts = await Future.wait<Object>([
        _loadFilteredMessages(sessionId),
        _persistenceService.loadArtifactsBySession(sessionId),
        _persistenceService.loadMessageVariants(sessionId),
      ]);
      final filtered = historyParts[0] as ({
        List<ChatMessage> messages,
        int compactedTurnBase,
        int? nextTurn,
      });
      final artifactsMap = historyParts[1] as Map<int, StoryRoundArtifacts>;
      final variantsMap =
          historyParts[2] as Map<int, List<MessageVariantRecord>>;
      state = state.copyWith(
        messages: filtered.messages,
        artifactsByTurnNumber: artifactsMap,
        variantsByTurn: variantsMap,
        //  修复：同步"已压缩轮次基数"，保证导演轮 turnNumber 跨压缩单调
        compactedTurnBase: filtered.compactedTurnBase,
        // 镜像 next_turn 计数器（公式回退场景下的会话级单一事实源）
        session: filtered.nextTurn == null
            ? null
            : state.session.copyWith(nextTurn: filtered.nextTurn),
      );

      // 导演会话打开时修复悬挂轮（崩溃/中断的轮补 turn/end{interrupted}）
      if (state.session.mode == ChatMode.advanced) {
        // 冷路径裁剪同样按用户配置——runner
        // _tuning 仅 runRound 刷新，会话打开时仍是 const 默认（20），
        // 不传会把用户配 50/0 的保留窗按 20 轮裁掉。
        await _directorRunner.recoverEventLogIfNeeded(
          sessionId,
          retentionTurns: await _resolveRetentionTurns(),
        );
      }

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
      state = state.copyWith(loadingHistory: false);
    }
    // 存量会话惰性物化——置于历史载入完成后：
    // 物化的 await 链前置于消息载入会翻转与 sendMessage 的竞态窗口
    //（integration 时序实证，故事侧同修）。失败静默（resolver
    // 回退链仍兜底旧会话行为）。
    await _materializeSnapshotColumnsIfNeeded();
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

  /// 会话打开时的上下文容量解析（上下文用量指示 §3.1）
  ///
  /// 失败仅记日志：容量显示是附加能力，不阻断历史加载。
  Future<void> _refreshContextCapacity() async {
    try {
      final namingConfig =
          await _configurationResolver.resolveAdvancedGeneratingNamingConfig(
        state.session,
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
          await _configurationResolver.resolveAdvancedSettings(state.session);
      final resolvedWindow = _resolveContextWindow(
        resolvedSettings.settings.effectiveContextLimit,
        modelWindow,
      );
      final config = await _getConfig();
      final merged = _applyContextBudgetOverride(
        config.storyRuntime,
        resolvedSettings.settings,
      );
      state = state.copyWith(
        contextWindowTokens: resolvedWindow,
        compactionTriggerTokens:
            (resolvedWindow * merged.contextBudget.compactionTriggerRatio)
                .floor(),
      );
    } catch (e, stackTrace) {
      _logger.warn(
        'Context capacity refresh failed',
        detail: '$e\n$stackTrace',
      );
    }
  }

  /// 旧会话回填（上下文用量指示 §3.2）：仅内存补最新轮 lastPromptTokens
  Future<void> _backfillLastPromptTokens() async {
    final artifacts = state.artifactsByTurnNumber;
    if (artifacts == null || artifacts.isEmpty) return;
    final latestTurn = artifacts.keys.reduce((a, b) => a > b ? a : b);
    final summary = artifacts[latestTurn]?.agentWorkSummary;
    if (summary == null || summary.lastPromptTokens != null) return;
    final repo = agentEventLogRepository;
    if (repo == null) return;
    try {
      final events = await repo.readEvents(state.session.sessionId);
      final usage = latestStepEndUsage(events);
      if (usage == null) return;
      state = state.copyWith(
        backfilledPromptTokens: usage.promptTokens,
        // cache 分项随同源探针回填（旧日志缺键保持 null）
        backfilledCacheReadTokens: usage.cacheReadTokens,
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
  Future<ManualCompactResult> manualCompact() async {
    if (state.isManualCompacting) return ManualCompactResult.busy;
    if (state.phase != IntermediatePhase.idle) return ManualCompactResult.busy;
    final service = _compactionService;
    if (service == null) return ManualCompactResult.failed;
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
        backfilledPromptTokens: null,
        backfilledCacheReadTokens: null,
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
  Future<bool> undoCompaction() async {
    if (state.isManualCompacting) return false;
    if (state.phase != IntermediatePhase.idle) return false;
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
      );
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
  /// 同批返回 chat_sessions.next_turn 计数器（DB 内最新值）。
  Future<
      ({
        List<ChatMessage> messages,
        int compactedTurnBase,
        int? nextTurn,
      })> _loadFilteredMessages(String sessionId) async {
    if (_compactionService == null) {
      final messages = await _chatRepository.getMessages(sessionId);
      return (messages: messages, compactedTurnBase: 0, nextTurn: null);
    }
    final parts = await Future.wait<Object?>([
      _chatRepository.getMessages(sessionId),
      _chatRepository.getCompactionPoints(sessionId),
      _loadSessionQuietly(sessionId),
    ]);
    final allMessages = parts[0]! as List<ChatMessage>;
    final compactionPoints = parts[1]! as List<Map<String, dynamic>>;
    return (
      messages: StoryCompactionService.filterByCompactionPoint(
        allMessages: allMessages,
        compactionPoints: compactionPoints,
      ),
      compactedTurnBase: StoryCompactionService.compactedTurnBaseFor(
        allMessages: allMessages,
        compactionPoints: compactionPoints,
      ),
      nextTurn: (parts[2] as ChatSession?)?.nextTurn,
    );
  }

  /// 读取会话行（异常静默为 null）
  ///
  /// [_loadFilteredMessages] 并行读取 next_turn 计数器用：会话行缺失
  /// （草稿未物化等异常场景）不应中断轮次启动，回退公式惰性兼容。
  Future<ChatSession?> _loadSessionQuietly(String sessionId) async {
    try {
      return await _chatRepository.getSession(sessionId);
    } catch (_) {
      return null;
    }
  }

  /// 更新会话配置（供会话设置面板调用；生成中拒绝）
  Future<bool> updateSession(ChatSession updated) async {
    if (state.phase != IntermediatePhase.idle &&
        state.phase != IntermediatePhase.failed) {
      _logger.warn('updateSession rejected: phase is generating');
      return false;
    }
    if (isDraftSession) {
      await _materializeDraftSessionWith(updated);
      return true;
    }
    try {
      final persisted = await _chatRepository.updateSession(updated);
      state = state.copyWith(session: persisted);
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

  /// 将草稿会话转为真实会话（入库）
  Future<void> _materializeDraftSession() async {
    await _materializeDraftSessionWith(state.session);
  }

  /// 将草稿会话转为真实会话（入库），并应用 [updated] 配置。
  ///
  /// 物化时快照所有字段（草稿值 > 全局默认快照值，"快照而非引用"语义），
  /// 与故事模式一致。
  Future<void> _materializeDraftSessionWith(ChatSession updated) async {
    final draft = updated;
    final realSession = await _chatRepository.createSession(
      title: draft.title,
      mode: draft.mode,
      modelId: draft.modelId,
      presetId: draft.presetId,
    );

    final snapshot = await _configurationResolver.snapshotAdvancedDefaults();

    final mergedPhaseModels = _mergePhaseModels(
      draft.phaseModels,
      snapshot.phaseModels,
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

    final persisted = await _chatRepository.updateSession(sessionWithDefaults);
    state = state.copyWith(session: persisted);
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

  /// 合并会话级与全局快照的模型配置（审查收窄：导演仅 GM/generating
  /// 一条模型链，不再照抄故事四阶段全量合并——快照侧本就只填 generating）
  SessionPhaseModels _mergePhaseModels(
    SessionPhaseModels session,
    SessionPhaseModels? snapshot,
  ) {
    if (snapshot == null) return session;
    return SessionPhaseModels(
      generatingPresetId:
          session.generatingPresetId ?? snapshot.generatingPresetId,
      generatingModelId:
          session.generatingModelId ?? snapshot.generatingModelId,
    );
  }

  /// 发送用户消息，启动导演回合（agent loop）
  Future<void> sendMessage(String userInput) async {
    // failed 放行直发新消息——放弃失败轮不必先清空（DOC-09C §3 单会话
    // 串行口径下其余相位仍拦截）。
    if (state.phase != IntermediatePhase.idle &&
        state.phase != IntermediatePhase.failed) {
      return;
    }
    // 手动压缩以压缩事务为先（上下文用量指示 §4.3）
    if (state.isManualCompacting) return;
    if (state.isStopping) return;
    // 重生成/编辑重发「准备中」窗口（snapshot/deleteRound/rollbackNarrative
    // 多个 await）内 phase 仍为 idle——此窗口发送新消息会与随后的
    // regenerate copyWith（截断 messages/覆写 userInput）互踩两轮状态。
    if (state.isPreparingRegenerate) return;

    // failed 态直发：先事务性清掉失败轮残留（旧 pending 气泡/直播块/
    // 步骤/失败上下文/_round），不留幽灵态再走正常首发链。
    if (state.phase == IntermediatePhase.failed) {
      _round = null;
      state = state.clearTemporary().copyWith(pendingUserMessage: null);
    }

    // 草稿会话检查：首次发送消息时创建真实会话
    if (isDraftSession) {
      // 草稿场景先验配置再物化——对话模式
      // 已有同款守卫，故事/导演此前先物化再在生成期报 E010，
      // 新手反复尝试会累积一串空会话。导演仅验 GM（generating）一条链。
      // 导演无六步 phase，失败阶段统一 generating；
      // GM 未配置用报点级建议覆盖，通用 config 建议指不到导演设置入口。
      final preGenerating =
          await _configurationResolver.resolveAdvancedGeneratingNamingConfig(
        state.session,
      );
      if (preGenerating == null) {
        // 预检失败先落 userInput + pendingUserMessage（与故事侧同款）：
        // 输入框在 onSend 前已被清空，若 state 不存这份输入，用户
        // 首条消息直接蒸发；落态后气泡与失败栏「整轮重试」都有据可重放。
        state = state.copyWith(
          userInput: userInput,
          pendingUserMessage: ChatMessage(
            messageId: _uuid.v4(),
            sessionId: state.session.sessionId,
            role: 'user',
            content: userInput,
            createdAt: DateTime.now(),
          ),
        );
        await _fail(
          IntermediatePhase.generating,
          'E010',
          errorCategory: ErrorCategory.config,
          suggestionOverride: t.advanced.failure.gmMissing,
        );
        return;
      }
      await _materializeDraftSession();
    }

    final pendingMsg = ChatMessage(
      messageId: _uuid.v4(),
      sessionId: state.session.sessionId,
      role: 'user',
      content: userInput,
      createdAt: DateTime.now(),
    );

    state = state.copyWith(
      userInput: userInput,
      pendingUserMessage: pendingMsg,
      regenerateTurnNumber: null,
      suggestReplies: [],
      isGeneratingSuggest: false,
      suggestExpanded: false,
      suggestFailed: false,
    );
    await _prepareAndRunRound();
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
  Future<void> _prepareAndRunRound() async {
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
        // 同草稿预检——generating + 报点级建议覆盖
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
        compactionTriggerTokens:
            (contextWindow * mergedConfig.contextBudget.compactionTriggerRatio)
                .floor(),
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
      );

      // 回填持久化压缩摘要（2026-08-22 修复，与故事模式同构）：摘要消息是
      // system 角色，不会进入各阶段消息组装；不回填会导致压缩后摘要从请求中
      // 消失、压缩退化为每次从零重写、缓存前缀在次轮断裂。
      _round!.compactionSummary =
          StoryCompactionService.extractPersistedSummary(history);

      // 导演模式：agent loop 替换六步管线；运行旋钮从 advanced 段组装
      // 重生成清理——删除上一尝试同 turn 的全部事件后再开新尝试，
      // 日志中同 turn 仅保留最新一组（轮轨迹页/投影不再见旧尝试残影）
      final regenerateTurn = state.regenerateTurnNumber;
      if (regenerateTurn != null) {
        final frozenDeleted = await _agentEventLogRepository?.deleteTurnEvents(
              state.session.sessionId,
              regenerateTurn,
            ) ??
            false;
        // 删到 systemFrozen 行时重置补写备忘（本轮 bootstrap 会重落）
        if (frozenDeleted) _directorRunner.invalidateFrozenPrefixMemo();
      }

      //（预算/HITL/doom-loop/子代理，导演设置）
      // runRound 经统一 catch-all 出口（_runDirectorRoundGuarded，
      // 见 retry part）——persist 嵌入等未被阶段内捕获的异常不再逃逸成
      // Zone uncaught；此处 try 块继续兜住轮前配置解析段。
      await _runDirectorRoundGuarded(
        _round!,
        tuning: DirectorRoundTuning.fromConfig(config),
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
    final cancelFuture = _streamRunner.cancel();
    _directorRunner.cancelRound('用户停止');

    final hasManuscript = state.liveBlocks.any(
      (b) => b.kind == AgentLiveBlockKind.text && !b.isEmpty,
    );
    if (hasManuscript && _round != null) {
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
    try {
      await cancelFuture.timeout(const Duration(seconds: 3));
    } catch (_) {
      // 超时或异常都视为清理完成
    }
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
      if (hasManuscript && _round != null) {
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
    if (force && _titleNamingInFlight) return false;
    if (state.phase != IntermediatePhase.idle &&
        state.phase != IntermediatePhase.failed) {
      return false;
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
  Future<bool> _performTitleUpdate({
    required bool force,
    String? userInput,
    String? assistantReply,
  }) async {
    try {
      final currentTitle = state.session.title;
      final allowedTitles = <String>{..._autoNameAllowedTitles};
      final isDraftTitle = allowedTitles.contains(currentTitle);
      if (!force && !isDraftTitle) {
        return false;
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
        return false;
      }
      effectiveAssistant ??= '';

      final namingConfig =
          await _configurationResolver.resolveTitleNamingConfig() ??
              await _configurationResolver
                  .resolveAdvancedGeneratingNamingConfig(state.session);
      if (namingConfig == null) {
        if (!force) {
          final title = SessionTitleGenerator.fallbackTitle(
            effectiveUser,
            defaultTitle: t.advanced.home.newDirector,
          );
          final written =
              await _chatRepository.updateSessionTitleIfCurrentTitleIn(
            state.session.sessionId,
            title,
            allowedTitles,
          );
          if (!written) return false;
          state = state.copyWith(
            session: state.session.copyWith(title: title),
          );
          return true;
        }
        return false;
      }

      final timeouts = await _configurationResolver.resolveTimeouts();
      final generator = _titleGenerator ??
          SessionTitleGenerator(
            llmService: _llmService,
            logger: _logger,
          );

      final generated = await generator.generate(
        userMessage: effectiveUser,
        assistantReply: effectiveAssistant,
        namingConfig: namingConfig,
        connectTimeout: timeouts.connectTimeout,
        readTimeout: timeouts.readTimeout,
      );

      final titleToWrite = generated ??
          (force
              ? null
              : SessionTitleGenerator.fallbackTitle(
                  effectiveUser,
                  defaultTitle: t.advanced.home.newDirector,
                ));

      if (titleToWrite == null || titleToWrite.trim().isEmpty) {
        return false;
      }

      final written = await _chatRepository.updateSessionTitleIfCurrentTitleIn(
        state.session.sessionId,
        titleToWrite,
        allowedTitles,
      );
      if (!written) return false;

      state = state.copyWith(
        session: state.session.copyWith(title: titleToWrite),
      );
      return true;
    } catch (e, stackTrace) {
      _logger.warn(
        'Auto-name session failed',
        detail: '$e\n$stackTrace',
      );
      return false;
    }
  }

  /// 首轮 persist 成功后异步生成会话标题（不阻塞 UI）
  Future<void> _autoNameSession({
    required String userInput,
    required String assistantReply,
  }) async {
    await updateTitle(
      userInput: userInput,
      assistantReply: assistantReply,
    );
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
