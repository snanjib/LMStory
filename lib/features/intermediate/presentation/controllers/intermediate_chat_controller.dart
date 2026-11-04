import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/config/output_token_policy.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/llm/context_overflow.dart';
import 'package:lmstory/core/network/http_client.dart' show CancellationToken;
import 'package:lmstory/core/network/retry_policy.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/throttled_delta_buffer.dart';
import 'package:lmstory/core/utils/token_counter.dart';
// v0.3 导演模式（agent loop kernel swap）
// P2 解耦：导演编排已迁入 advanced（AdvancedChatController + DirectorRoundRunner）。
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session_settings.dart';
import 'package:lmstory/features/chat/domain/entities/session_phase_models.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/diagnostics/domain/repositories/failure_log_repository.dart';
import 'package:lmstory/features/intermediate/domain/entities/intermediate_chat_state.dart';
import 'package:lmstory/features/intermediate/domain/services/intermediate_context_builder.dart';
import 'package:lmstory/features/intermediate/presentation/controllers/phases/extract_phase_handler.dart';
import 'package:lmstory/features/intermediate/presentation/controllers/phases/summarize_phase_handler.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart'
    show ExperienceRepositoryImpl;
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/facts_change_record.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/scored_memory.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/services/embedding_service.dart';
import 'package:lmstory/features/memory/domain/services/fact_context_builder.dart';
import 'package:lmstory/features/memory/domain/services/memory_query.dart';
import 'package:lmstory/features/memory/domain/services/memory_retrieval_exception.dart';
import 'package:lmstory/features/story_runtime/domain/entities/classified_keywords.dart';
import 'package:lmstory/features/story_runtime/domain/entities/message_variant_record.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_context.dart';
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

part 'intermediate_chat_controller_consolidation.dart';
part 'intermediate_chat_controller_embeddings.dart';
part 'intermediate_chat_controller_logs.dart';
part 'intermediate_chat_controller_messages.dart';
//  拆分：控制器原 3098 行，超出项目规则 300-500 行限制。
// 采用 `part` 机制将低耦合的方法块抽到独立文件，私有字段跨 part 共享，
// 零行为变更。各 part 文件按职责划分：
// - _persist.dart：persisting 阶段（DB 事务写入）
// - _consolidation.dart：批量记忆提炼
// - _embeddings.dart：embedding 辅助（查询向量 / 摘要向量 / 文本构造）
// - _logs.dart：调试日志格式化
// - _phases.dart：六步流程阶段执行（compacting/extracting/retrieving/generating/reviewing/summarizing）
// - _retry.dart：失败处理 + 自动重试 + 手动续跑（_fail / _scheduleRetry / retry /
//   continueWithFts5Only / continueFromFailed / _reloadRoundConfigPreservingOutputs）
// - _messages.dart：消息操作 + 简化 Fork（canOperateMessage / regenerateMessage /
//   editAndResend / deleteRound / _rollbackNarrativeTime / editPendingUserMessage /
//   deletePendingUserMessage / _computeTurnNumber / _removeArtifactsFromTurn / clearRound）
// - _suggest.dart：推荐回复气泡（generateSuggestReplies / selectSuggestReply /
//   toggleSuggest / closeSuggest）
// 主文件保留：字段/构造/公共 API/状态机编排/_prepareAndRunRound/配置覆盖/cancel/
// recoverIfStuck/会话标题生成/dispose。
part 'intermediate_chat_controller_persist.dart';
part 'intermediate_chat_controller_phases.dart';
part 'intermediate_chat_controller_retry.dart';
part 'intermediate_chat_controller_suggest.dart';

int _outputTokenReserveFor(
  int configured, {
  int? modelMaxOutput,
}) =>
    OutputTokenPolicy.contextReserve(
      configured: configured,
      modelMaxOutput: modelMaxOutput,
    );

/// 中级模式聊天控制器（状态机编排 +  自动重试 + Phase 6 六步流程）
///
/// 驱动故事模式生成的状态机：
/// `idle → compacting? → extracting → retrieving → generating → reviewing? → summarizing → persisting → idle`
/// 其中 compacting 与 reviewing 为可选阶段（见下方说明）。
/// 任一阶段失败 → 自动重试（同阶段内，按 [RetryConfig]）→ 用尽后 `failed`。
///
/// **V2 六步流程**（v0.2.2 架构调整，Phase 6 重构）：
/// - compacting（可选）：原文区 token 超过上限时触发，压缩旧对话为摘要前缀。
///   未超上限时跳过此阶段。失败映射 E018（三选项失败处理）。
/// - extracting/retrieving：关键词提取 + 5 路并行检索（本地操作 + LLM 结构化输出）
/// - generating：[StreamRunner.runPlainText]（纯文本，无标记/JSON）
/// - reviewing（可选）：开启 [IntermediateConfig.reviewEnabled] 时执行审查修正；
///   默认关闭（生成即最终），跳过此阶段。
/// - summarizing：[SummarizePhaseHandler]（工具调用 fallback → JSON 模式降级）
/// - persisting：本地 DB 写入
///
/// 历史标注：Phase 6 原为"四步流程"（generating/extracting/reviewing/summarizing），
/// v0.2.2 调整为六步（前置 extracting、新增可选 compacting、reviewing 改可选）。
///
/// 流式驱动（不复用 Simple 的 StreamHandler，因其耦合 Fork/think/toolcall）：
/// LLM 传输细节（SSE 解析、请求体构造）由 [LlmService] 的 Data 层实现收口，
/// 流式解析与取消管理封装在 [StreamRunner]，结构化步骤由 PhaseHandler 处理。
///
/// 权威设计：DOC-09A-1（状态机）、DOC-09A-2 §6（失败处理）、
/// DOC-09B §7（State 字段）、DOC-09B §8.6（JSON 兜底）、DOC-09C §1（持久化时序）。
class IntermediateChatController extends StateNotifier<IntermediateChatState> {
  IntermediateChatController({
    required ChatRepository chatRepository,
    required ConfigurationResolver configurationResolver,
    required LlmService llmService,
    required ExperienceRepository experienceRepository,
    required EmbeddingService embeddingService,
    required StoryPersistenceService persistenceService,
    required FailureLogRepository failureLogRepository,
    required TokenCounter tokenCounter,
    required Future<IntermediateConfig> Function() getConfig,
    required Logger logger,
    required ChatSession session,
    SessionTitleGenerator? titleGenerator,
    MemoryConsolidator? consolidator,
    FactContextBuilder? factContextBuilder,
    // CompactionPoint 压缩服务（nullable 向后兼容旧测试）
    StoryCompactionService? compactionService,
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
        _factContextBuilder = factContextBuilder,
        _compactionService = compactionService,
        _streamRunner = StreamRunner(llmService: llmService),
        super(IntermediateChatState.initial(session)) {
    // 2026-07-22 修复：构造函数中加载历史消息，与 ChatModeController 一致。
    // 之前 loadHistory() 由 page.initState 触发，但故事模式→故事模式切换会话时
    // IntermediateChatPage 的 State 被复用（widget 类型相同且无 key），
    // initState 不重新调用，导致新 controller 的 state 保持空消息列表，
    // UI 显示空状态（"起始背景"）。改为构造函数加载后，无论新建还是切换会话，
    // controller 创建时都会自动加载消息。
    loadHistory();
  }

  final ChatRepository _chatRepository;
  final ConfigurationResolver _configurationResolver;

  /// LLM 服务引用（2026-07-29 新增）
  ///
  /// 原本只注入 [_streamRunner] 用，推荐回复功能需要非流式 [LlmService.chat]，
  /// 故保留原始引用供 [_suggestGenerator] 等非流式调用点使用。
  final LlmService _llmService;
  final ExperienceRepository _experienceRepository;
  final EmbeddingService _embeddingService;
  final StoryPersistenceService _persistenceService;
  final FailureLogRepository _failureLogRepository;
  final TokenCounter _tokenCounter;
  final Future<IntermediateConfig> Function() _getConfig;
  final Logger _logger;

  /// 会话标题生成器（新增，nullable 向后兼容）
  ///
  /// 首轮 persist 成功后异步调用 LLM 生成简短标题。
  /// null 时不触发标题生成（测试 stub 可不注入）。
  final SessionTitleGenerator? _titleGenerator;

  /// 批量记忆提炼器（新增，nullable 向后兼容）
  ///
  /// 上下文 token 超阈值时异步合并低重要性记忆为高重要性记忆。
  /// null 时不触发提炼（测试 stub 可不注入）。
  final MemoryConsolidator? _consolidator;

  /// 事实上下文构建器（DOC-11 §6 新增，nullable 向后兼容）
  ///
  /// retrieving 阶段调用，加载关键实体 + 关键词命中实体，构建【世界设定】
  /// 注入文本供 reviewing 阶段使用。null 时不启用事实层（v0.2 部分环境未注入）。
  final FactContextBuilder? _factContextBuilder;

  /// CompactionPoint 压缩服务（新增，nullable 向后兼容旧测试）
  ///
  /// extracting 阶段之前调用，检查总占用 token 是否超过 compactionTriggerRatio，
  /// 超过时将旧对话压缩为剧情宏观骨架摘要作为稳定前缀注入 generating/reviewing。
  /// null 时不启用压缩（旧测试可不注入）。
  /// v0.3 体验重构 ：导演轮同样触发（DirectorRoundRunner 轮前压缩）。
  final StoryCompactionService? _compactionService;

  /// manualCompact 摘要增量合帧缓冲（见 [_onManualCompactionDelta]）
  ThrottledDeltaBuffer? _manualCompactionDeltaBuffer;

  /// 失败分类器：异常 → ErrorCategory 自动分流 + i18n 文案
  final StoryFailureClassifier _classifier = const StoryFailureClassifier();

  /// 重试调度器（Phase 5 Step 5.3 提取）
  ///
  /// 无状态纯决策：最大重试次数查询、阶段映射、延迟计算、状态清理、格式提醒。
  /// 重试编排（设置 state / 降级标志 / 重跑阶段）留在控制器。
  final RetryScheduler _retryScheduler = const RetryScheduler();

  /// 本轮自动重试累计纯等待（2026-10-15 批 E / P6 预算闸：累计超 90s
  /// 提前放弃，防 5 连长冷却纯等约 5 分钟；新一轮清零）
  Duration _retryWaitTotal = Duration.zero;

  /// 关键词提取阶段处理器（Phase 6 Step 6.2 新增）
  ///
  /// 工具调用 → JSON 模式降级链，产出 ClassifiedKeywords。
  /// 由 `_runExtractPhase` 调用。late final 确保 _streamRunner / _logger
  /// 在首次访问前已初始化。
  late final ExtractPhaseHandler _extractHandler = ExtractPhaseHandler(
    streamRunner: _streamRunner,
    logger: _logger,
  );

  /// 事件摘要阶段处理器（Phase 6 Step 6.3 新增）
  ///
  /// 工具调用 → JSON 模式降级链，产出 EventSummary。
  /// 由 `_runSummarizePhase` 调用。compact 降级时仍执行（生成摘要）。
  late final SummarizePhaseHandler _summarizeHandler = SummarizePhaseHandler(
    streamRunner: _streamRunner,
    logger: _logger,
    // 2026-07-22 修复：注入 FactContextBuilder，用于 summarizing 阶段
    // 查询已知实体并替换 {{known_entities}} 占位符（DOC-11 §5.2）。
    // 修复前 LLM 看到字面占位符，不知道已有实体的 entityId，无法发起
    // update_attr 等属性修改操作，导致 factual_attributes 表永远无新记录。
    factContextBuilder: _factContextBuilder,
    // 2026-07-25 新增（叙事时间机制）：注入 ExperienceRepository，
    // 查询最近几轮经历记忆的 narrativeTime 构建时间线上下文，
    // 替换 {{recent_timeline}} 占位符，让 LLM 判断本轮时间是否推进。
    experienceRepository: _experienceRepository,
  );

  /// 推荐回复生成器（2026-07-29 新增）
  ///
  /// 由 `generateSuggestReplies` 调用，基于最近 1 轮对话全文 + 前 2 轮
  /// micro 摘要生成 3 条候选用户回复。复用统一 [LlmService] 调用层
  /// （非流式、禁用 reasoning、JSON 输出），省 token 设计。
  late final SuggestReplyGenerator _suggestGenerator = SuggestReplyGenerator(
    llmService: _llmService,
    logger: _logger,
  );

  /// 草稿会话的 sessionId 前缀。
  /// 草稿会话不存入数据库，仅在用户发送第一条消息时才创建真实会话。
  static const draftSessionIdPrefix = '__draft_intermediate_';

  /// 判断当前会话是否为草稿会话（未入库的临时会话）
  bool get isDraftSession =>
      state.session.sessionId.startsWith(draftSessionIdPrefix);

  static const _uuid = Uuid();

  /// LLM 流式执行 + 取消管理（Phase 5 Step 5.2 提取）
  ///
  /// 封装 streamChat 订阅、CancellationToken 双保险取消、JSON 兜底缓冲。
  /// 控制器通过 `_streamRunner.run` 发起流式请求，`cancel` / `cleanup`
  /// 委托本类取消。降级链判定仍留在控制器（访问降级标志 + logger）。
  final StreamRunner _streamRunner;

  /// 当前在途压缩的取消令牌：压缩 LLM 调用不经
  /// StreamRunner，用户停止/后台中断原本无法终止（token 燃烧）。
  /// 轮前/自愈压缩在 phases 里赋值、手动压缩在 manualCompact 赋值，
  /// [cancel] 与 [onBackgroundInterrupt] 同步取消；调用点用完即清。
  CancellationToken? _activeCompactionToken;

  /// 当前轮次上下文（：自动重试时复用）
  ///
  /// sendMessage 时创建，persist 成功 / cancel / clearRound / retry 时清空。
  /// failed 状态下保留，供 continueFromFailed（从中断处继续）复用已完成阶段产出。
  /// 各阶段产出（generatedText/keywords/scoredMemories）存入此对象供重试复用。
  RoundContext? _round;

  /// 后台中断标志（App 切到后台时设置）
  ///
  /// `onBackgroundInterrupt` 时设为 true，`_prepareAndRunRound` 时重置为 false。
  /// `recoverIfStuck` 检查此标志：即使 `_streamRunner.isStreaming` 仍为 true
  /// （cancel 的 `await sub?.cancel()` 尚未完成），也能检测到后台中断并恢复。
  /// 同时阻止 `_fail` -> `_scheduleRetry` 自动重试（`_streamRunner.cancel()`
  /// 设置 `_isCancelled = true`，`_fail` 的 guard 直接返回）。
  bool _backgroundInterrupted = false;

  // ==================== 主流程 ====================

  /// 加载历史消息（非草稿会话）
  ///
  /// 页面 initState 时调用，从数据库加载已持久化的消息到 state.messages。
  /// 草稿会话跳过（未入库，无历史）。
  ///
  /// **生成中绝不 reload**（边界修复）：`phase != idle` 时跳过，
  /// 避免数据库旧消息覆盖内存中正在生成/已生成未持久化的 state。
  /// 后台续跑场景下，用户切回页面时若生成仍在进行或刚结束（state 已更新），
  /// 直接展示当前 state 即可，无需从数据库重载。
  ///
  /// 同时批量加载 [StoryRoundArtifacts]（每轮的生成内容/关键词/检索结果），
  /// 填充到 [IntermediateChatState.artifactsByTurnNumber]，使历史轮次的小窗
  /// 在切换会话或重新进入时仍可见（修复"生成内容和检索过程消失"问题）。
  /// 故事存量会话惰性物化——配置列 NULL（跟随态）→
  /// 全局当前快照一次性写回。例外：reasoningEffort（模型语义 carve-out）
  /// 与 effectiveContextLimit/phaseModels 空态（null=未配置/无限制的
  /// 具体态，列入判定会致每次打开重写）。仅故事会话（mode=intermediate）。
  Future<void> _materializeSnapshotColumnsIfNeeded() async {
    if (state.session.mode != 'intermediate') return;
    final session = state.session;
    final needs = session.temperature == null ||
        session.topP == null ||
        session.maxTokens == null ||
        session.presencePenalty == null ||
        session.frequencyPenalty == null ||
        session.streamEnabled == null ||
        session.systemPromptOverride == null ||
        session.jsonModeOverride == null ||
        session.reviewEnabledOverride == null ||
        session.suggestReplyPresetId == null ||
        session.suggestReplyModelId == null ||
        session.suggestReplyPromptOverride == null ||
        session.recentMinRatioOverride == null ||
        session.retrievalRatioOverride == null ||
        session.compactionTriggerRatioOverride == null;
    if (!needs) return;
    try {
      final snapshot =
          await _configurationResolver.snapshotIntermediateDefaults();
      // await 期间用户可能已编辑会话列
      // （极速打开设置改模型）——重取最新会话为合并基线，物化只填充
      // 仍为 null 的列，防止用「开头捕获的旧 null 基线」覆盖用户刚写的值。
      final current = state.session;
      final budget = snapshot.contextBudget;
      final updated = current.copyWith(
        temperature: current.temperature ?? snapshot.temperature,
        topP: current.topP ?? snapshot.topP,
        maxTokens: current.maxTokens ?? (snapshot.maxTokens ?? 0),
        presencePenalty: current.presencePenalty ?? snapshot.presencePenalty,
        frequencyPenalty: current.frequencyPenalty ?? snapshot.frequencyPenalty,
        streamEnabled: current.streamEnabled ?? snapshot.streamEnabled,
        systemPromptOverride:
            current.systemPromptOverride ?? (snapshot.systemPrompt ?? ''),
        jsonModeOverride: current.jsonModeOverride ?? snapshot.jsonMode,
        effectiveContextLimit:
            current.effectiveContextLimit ?? snapshot.effectiveContextLimit,
        reviewEnabledOverride:
            current.reviewEnabledOverride ?? snapshot.reviewEnabled,
        suggestReplyPresetId:
            current.suggestReplyPresetId ?? snapshot.suggestReplyPresetId,
        suggestReplyModelId:
            current.suggestReplyModelId ?? snapshot.suggestReplyModelId,
        suggestReplyPromptOverride: current.suggestReplyPromptOverride ??
            (snapshot.suggestReplyPromptOverride ?? ''),
        recentMinRatioOverride:
            current.recentMinRatioOverride ?? budget?.recentMinRatio,
        retrievalRatioOverride:
            current.retrievalRatioOverride ?? budget?.retrievalRatio,
        compactionTriggerRatioOverride:
            current.compactionTriggerRatioOverride ??
                budget?.compactionTriggerRatio,
      );
      final persisted = await _chatRepository.updateSession(updated);
      state = state.copyWith(session: persisted);
      _logger.info(
        'Legacy intermediate session snapshot materialized',
        detail: 'sessionId=${current.sessionId}',
      );
    } catch (e) {
      _logger.warn(
        'Legacy intermediate session snapshot materialization skipped',
        detail: '$e',
      );
    }
  }

  Future<void> loadHistory() async {
    if (isDraftSession) return;
    if (state.phase != IntermediatePhase.idle) return;
    try {
      // 2026-08-04 修复：按最新 CompactionPoint 过滤已压缩的旧消息，
      // 避免 UI 展示已压缩的旧消息 + 防止下一轮 shouldCompact 误触发。
      // 过滤逻辑：无 CompactionPoint → 全量；有 → [最新summary, ...boundary之后]
      final sessionId = state.session.sessionId;
      final historyParts = await Future.wait<Object>([
        _loadFilteredMessages(sessionId),
        _persistenceService.loadArtifactsBySession(sessionId),
        // 历史轮变体随装载入内存（切换器数据源）
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
        //  修复：装载历史时同步"已压缩轮次基数"，保证 turnNumber 跨压缩单调
        compactedTurnBase: filtered.compactedTurnBase,
      );

      // 上下文容量解析（：非轮中也可显示；失败不阻断加载）
      await _refreshContextCapacity();
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to load history',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
    }
    // 存量会话惰性物化——置于历史载入完成后：物化的
    // await 链前置于消息载入会翻转与 sendMessage 的竞态窗口
    //（integration 时序实证），尾置则无论物化多久消息载入时机不变。
    await _materializeSnapshotColumnsIfNeeded();
  }

  /// 会话打开时的上下文容量解析（上下文用量指示 §3.1）
  ///
  /// 与每轮准备阶段同一公式（generating 模型窗口 × compactionTriggerRatio），
  /// 失败仅记日志：容量显示是附加能力，不阻断历史加载。
  Future<void> _refreshContextCapacity() async {
    try {
      final generatingNamingConfig =
          await _configurationResolver.resolveIntermediatePhaseNamingConfig(
        state.session,
        'generating',
      );
      if (generatingNamingConfig == null ||
          generatingNamingConfig.baseUrl.isEmpty ||
          generatingNamingConfig.modelId.isEmpty) {
        return;
      }
      final modelWindow =
          await _configurationResolver.resolveContextWindowForPhase(
        presetId: generatingNamingConfig.presetId,
        modelId: generatingNamingConfig.modelId,
      );
      final resolvedSettings =
          await _configurationResolver.resolveIntermediateSettings(
        state.session,
      );
      final resolvedWindow = _resolveContextWindow(
        resolvedSettings.settings.effectiveContextLimit,
        modelWindow,
      );
      final config = await _getConfig();
      final merged = _applyContextBudgetOverride(
        config,
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

  /// 手动压缩入口（上下文用量指示 §4.3：force 语义，不检查阈值与冷却）
  ///
  /// 守卫：压缩中/非 idle → busy；对话不足（与 shouldCompact 同源下限）→
  /// insufficient。实际压缩走 story_runtime 同一管线（流式增量写
  /// manualCompactionDelta 供面板实时打字），成功后 persistManualCompaction
  /// 单事务落库并重载过滤后历史；失败只写 manualCompactionError，不落任何库。
  /// 实现与导演侧 AdvancedChatController.manualCompact 同构（分母/守卫/落库
  /// 口径一致，差异仅命名配置解析链）。
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
    // 手动压缩走流式路径，令牌取消即中断在途请求
    final compactionToken = CancellationToken();
    _activeCompactionToken = compactionToken;
    try {
      final namingConfig =
          await _configurationResolver.resolveIntermediatePhaseNamingConfig(
        state.session,
        'generating',
      );
      if (namingConfig == null ||
          namingConfig.baseUrl.isEmpty ||
          namingConfig.apiKey.isEmpty ||
          namingConfig.modelId.isEmpty) {
        state = state.copyWith(
          isManualCompacting: false,
          manualCompactionError:
              t.intermediate.chat.contextRing.compactModelMissing,
        );
        return ManualCompactResult.failed;
      }
      final config = await _getConfig();
      final resolvedSettings =
          await _configurationResolver.resolveIntermediateSettings(
        state.session,
      );
      final timeouts = await _configurationResolver.resolveTimeouts();
      final budget = _applyContextBudgetOverride(
        config,
        resolvedSettings.settings,
      ).contextBudget;
      // 过滤后历史头部即最新压缩摘要（filterByCompactionPoint 口径）
      final existingSummary =
          StoryCompactionService.extractPersistedSummary(state.messages);

      final result = await service.compact(
        history: state.messages,
        sessionId: state.session.sessionId,
        namingConfig: namingConfig,
        contextWindow: state.contextWindowTokens ??
            ConfigurationResolver.defaultContextWindow,
        // 输出帽与轮前压缩同源：按会话配置与实际执行模型上限钳制，
        // 防止固定帽超过小输出模型上限被严格端点拒绝。
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
        cancelToken: compactionToken,
      );
      _flushManualCompactionDeltas();

      final lastTurn = completedTurnCount(
        compactedTurnBase: state.compactedTurnBase,
        messages: state.messages,
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

      // 重载过滤后历史（新摘要 + 保留区），同步压缩基数
      // 手动压缩此前不写摘要卡标注——此前若有轮内
      // 自动压缩，旧 archivedTurnRange 会残留显示在手动压缩的新摘要卡上
      //（覆盖范围已变大、数字错误）；hitRetentionFloor 触底警示也被丢弃
      //（手动路径最易触底：通常是用户感知上下文吃满才手动压）。
      final previousBase = state.compactedTurnBase;
      final filtered = await _loadFilteredMessages(state.session.sessionId);
      final newlyCoveredTurns = lastTurn - previousBase;
      state = state.copyWith(
        messages: filtered.messages,
        compactedTurnBase: filtered.compactedTurnBase,
        isManualCompacting: false,
        manualCompactionDelta: '',
        // 压缩后消息列表被过滤视图替换，session
        // 的 messageCount 内存镜像同步刷新（口径同 persist 路径
        // messageCount: newMessages.length），避免历史会话卡片/消息窗口
        // 判定拿到过期值。
        session: state.session.copyWith(
          messageCount: filtered.messages.length,
        ),
        archivedTurnRange: newlyCoveredTurns > 0
            ? (from: previousBase + 1, to: lastTurn)
            : null,
        compactionFloorWarningTurn: result.hitRetentionFloor ? lastTurn : null,
      );
      _activeCompactionToken = null;
      _logger.info(
        'Manual compaction completed',
        detail: 'summaryLength=${result.summary.length}, '
            'tokensBefore=${result.tokensBefore}, '
            'tokensAfter=${result.tokensAfter}',
      );
      return ManualCompactResult.success;
    } on CompactionNoopException catch (e) {
      _activeCompactionToken = null;
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
      _activeCompactionToken = null;
      _flushManualCompactionDeltas();
      // 主动取消不算失败——用户点了停止/切后台，不弹错误红字
      if (compactionToken.isCancelled) {
        _logger.info('Manual compaction cancelled by user');
        state = state.copyWith(
          isManualCompacting: false,
          manualCompactionDelta: '',
        );
        return ManualCompactResult.failed;
      }
      _logger.warn('Manual compaction failed', detail: '$e\n$stackTrace');
      state = state.copyWith(
        isManualCompacting: false,
        manualCompactionError: '$e',
      );
      return ManualCompactResult.failed;
    }
  }

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

  /// 撤销最新一次压缩（2026-09-04 撤销压缩）：仅 idle 可用
  ///
  /// 单事务回剥（U1 原语），随后重载过滤后历史——上一个压缩点重新生效
  /// 或旧对话全量恢复，压缩基数同步回剥。失败仅记日志返回 false，
  /// 不落任何脏状态。实现与导演侧 AdvancedChatController.undoCompaction
  /// 同构（守卫/重载/容量刷新口径一致）。
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
        // 撤销后全量消息重新可见，messageCount 内存
        // 镜像同步刷新（口径同 persist 路径），避免下游拿到压缩期的过期值。
        session: state.session.copyWith(
          messageCount: filtered.messages.length,
        ),
        // 撤销后重新可见的上一张摘要卡无可信区间——清空标注与
        // 触底警示，此前残留的是被撤销那次的范围（直接误导）
        archivedTurnRange: null,
        compactionFloorWarningTurn: null,
      );
      unawaited(_refreshContextCapacity());
      _logger.info('Manual compaction undone');
      return true;
    } catch (e, stackTrace) {
      _logger.warn('Undo compaction failed', detail: '$e\n$stackTrace');
      return false;
    }
  }

  /// 记录本轮主请求的真实 usage（上下文用量指示）
  ///
  /// generating 与 reviewing 两处调用：reviewing 启用时后写覆盖前写，
  /// 环形指示器对齐上下文最全的那次请求。会话累计（缓存命中率分母分子）
  /// 同批累加，重进会话后归零重算。
  ///
  /// 兜底（内测反馈「面板全是 —」）：端点未回 usage 时用 tiktoken 本地
  /// 估算 prompt/completion 写入并置 lastUsageIsEstimated，详情面板加
  /// 「≈」标注。缓存分项本地不可估算，显式清 null（面板「—」）；估算值
  /// 不进会话累计——命中率口径只吃端点真实数据。无任何可估来源（流异常
  /// 截断且 payload 缺失）时保持现状。
  Future<void> _recordRequestUsage(
    LlmUsage? usage, {
    List<String> promptTexts = const [],
    String completionText = '',
  }) async {
    if (usage != null && usage.promptTokens != null) {
      state = state.copyWith(
        lastPromptTokens: usage.promptTokens,
        lastCompletionTokens: usage.completionTokens,
        lastCacheReadTokens: usage.cacheReadTokens,
        lastUsageIsEstimated: false,
        contextPromptTokensTotal:
            state.contextPromptTokensTotal + usage.promptTokens!,
        contextCacheReadTokensTotal:
            state.contextCacheReadTokensTotal + (usage.cacheReadTokens ?? 0),
      );
      return;
    }
    final promptTokens = promptTexts.isEmpty
        ? null
        : await _tokenCounter.countTokensForMessages(promptTexts);
    final completionTokens = completionText.isEmpty
        ? null
        : await _tokenCounter.countTokens(completionText);
    if (promptTokens == null && completionTokens == null) return;
    state = state.copyWith(
      lastPromptTokens: promptTokens,
      lastCompletionTokens: completionTokens,
      // 上一轮的端点真实缓存分项不得与本轮估算值混排（口径错位）
      lastCacheReadTokens: null,
      lastUsageIsEstimated: true,
    );
  }

  /// 测试直通：估算兜底逻辑走真实生成管线才能触达（HTTP/SSE 集成面），
  /// 单元测试经此入口驱动 [_recordRequestUsage]。
  @visibleForTesting
  Future<void> recordRequestUsageForTest(
    LlmUsage? usage, {
    List<String> promptTexts = const [],
    String completionText = '',
  }) {
    return _recordRequestUsage(
      usage,
      promptTexts: promptTexts,
      completionText: completionText,
    );
  }

  /// 请求 payload 的文本内容列表（估算兜底取数）：content 为字符串的
  /// 消息原样取用，多模态数组只收 text 段，其余跳过。
  /// 实例方法（非静态）——phases extension 对本类静态成员须类型限定，
  /// 实例成员则可裸引。
  List<String> _promptTextsForEstimate(
    List<Map<String, dynamic>> messages,
  ) {
    final texts = <String>[];
    for (final message in messages) {
      final content = message['content'];
      if (content is String) {
        texts.add(content);
      } else if (content is List) {
        for (final part in content) {
          if (part is Map && part['text'] is String) {
            texts.add(part['text'] as String);
          }
        }
      }
    }
    return texts;
  }

  /// 加载按最新 CompactionPoint 过滤后的消息列表（2026-08-04 新增）
  ///
  /// 对标 Simple 模式 CompactionService.getCompressedMessages：
  /// - 无 CompactionPoint → 返回全量消息（首轮或未触发过压缩）
  /// - 有 CompactionPoint → 返回 [最新summary, ...boundary之后的消息（排除旧摘要）]
  ///
  /// **为什么需要过滤**：
  /// 1. UI 层：已压缩的旧消息不应再展示给用户（已被摘要替代）
  /// 2. 计算层：shouldCompact 计算 historyTokens 时不应包含已压缩的旧消息，
  ///    否则每次压缩后 historyTokens 持续累积，导致每轮都误触发压缩
  ///
  /// **compactionService 为 null 时（旧测试环境）**：回退到全量加载，
  /// 保持向后兼容。
  /// **compactedTurnBase（修复 2026-08-23）**：同时返回最新 CompactionPoint
  /// 已覆盖的轮次基数，供 turnNumber 单调推导（见
  /// [StoryCompactionService.compactedTurnBaseFor]）。
  /// **nextTurn（turn 单一事实源）**：同批读取 chat_sessions.next_turn
  /// 计数器（DB 内的最新值，不依赖 state.session 内存镜像——轮次间计数器
  /// 已由 persist 事务递增）。会话行缺失等异常回退 null（公式惰性兼容）。
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

  /// 更新会话配置（配置完善，供会话设置面板调用）
  ///
  /// - **草稿会话**：首次修改配置时触发物化（用户需求 2026-07-22）：
  ///   "会话成立的标志是发第一条消息或会话配置变更"。物化时快照所有字段
  ///   （含 phaseModels），实现"快照而非引用"语义
  /// - **真实会话**：调 [ChatRepository.updateSession] 持久化 + 更新 state.session
  ///
  /// 生成中（phase 既非 idle 也非 failed）拒绝更新（避免配置中途变更导致状态不一致）。
  /// idle 与 failed 状态下允许更新：failed 状态下用户可调整模型/温度后重试出错步骤。
  Future<bool> updateSession(ChatSession updated) async {
    if (state.phase != IntermediatePhase.idle &&
        state.phase != IntermediatePhase.failed) {
      _logger.warn('updateSession rejected: phase is generating');
      return false;
    }
    if (isDraftSession) {
      // 草稿会话期间首次修改配置 → 触发物化
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

  /// 将草稿会话转为真实会话（入库）。
  ///
  /// 在用户发送第一条消息时调用（[sendMessage]）。
  /// 委托给 [_materializeDraftSessionWith]，使用当前 state.session 作为草稿。
  Future<void> _materializeDraftSession() async {
    await _materializeDraftSessionWith(state.session);
  }

  /// 将草稿会话转为真实会话（入库），并应用 [updated] 配置。
  ///
  /// 触发时机（用户需求 2026-07-22）：
  /// 1. 发送第一条消息时（[sendMessage] → [_materializeDraftSession]）
  /// 2. 草稿期间首次修改会话配置时（[updateSession]）
  ///
  /// 物化时快照所有字段（不只 modelId/presetId）：
  /// - 草稿值非 null → 使用草稿值（保留用户在生成阶段所做的修改）
  /// - 草稿值为 null → 使用全局默认快照值（"快照而非引用"语义：
  ///   后续全局配置变更不影响此会话）
  ///
  /// **快照语义说明**：用户需求"如果使用的是全局设置的值，使用这一刻的值，
  /// 而不是全局设置那一项的引用"。本方法在物化时刻调用
  /// [ConfigurationResolver.snapshotIntermediateDefaults] 读取当前全局默认的具体值，
  /// 写入会话级字段。后续用户修改全局配置不会影响已物化的会话。
  Future<void> _materializeDraftSessionWith(ChatSession updated) async {
    final draft = updated;
    final realSession = await _chatRepository.createSession(
      title: draft.title,
      // v0.3 导演模式：保留草稿 mode（intermediate/advanced），不再硬编码
      mode: draft.mode,
      modelId: draft.modelId,
      presetId: draft.presetId,
    );

    // 快照当前全局默认值（"快照而非引用"语义）
    final snapshot =
        await _configurationResolver.snapshotIntermediateDefaults();

    // 合并 phaseModels：会话级 > 全局快照
    final mergedPhaseModels = _mergePhaseModels(
      draft.phaseModels,
      snapshot.phaseModels,
    );

    // 合并：草稿值 > 全局快照值
    final sessionWithDefaults = realSession.copyWith(
      // 生成参数：草稿值 > intermediate.generation 快照值
      temperature: draft.temperature ?? snapshot.temperature,
      topP: draft.topP ?? snapshot.topP,
      maxTokens: draft.maxTokens ?? snapshot.maxTokens,
      presencePenalty: draft.presencePenalty ?? snapshot.presencePenalty,
      frequencyPenalty: draft.frequencyPenalty ?? snapshot.frequencyPenalty,
      // 非生成参数：草稿值 > broadcastChat 快照值
      autoCompaction: draft.autoCompaction ?? snapshot.autoCompaction,
      compactionThreshold:
          draft.compactionThreshold ?? snapshot.compactionThreshold,
      streamEnabled: draft.streamEnabled ?? snapshot.streamEnabled,
      // 系统提示词：草稿值 > intermediate.systemPrompt 快照值
      systemPromptOverride: draft.systemPromptOverride ?? snapshot.systemPrompt,
      // 以下字段无全局默认值或仅会话级配置
      // v0.2.2 阶段 2-F：maxContextMessages 不再物化（故事模式由压缩机制
      // 管理原文区，此字段对故事模式无效，保持 null）
      reasoningEffort: draft.reasoningEffort ?? snapshot.reasoningEffort,
      // 工具调用：草稿值 > intermediate.stream.tool_calling_enabled 快照值
      jsonModeOverride: draft.jsonModeOverride ?? snapshot.jsonMode,
      // 分步骤模型配置：会话级 > 全局快照
      phaseModels: mergedPhaseModels,
      // contextBudget：草稿值 > 全局快照值（快照独立模式）
      // 物化时复制全局当前值到会话级，后续全局变更不影响此会话。
      // 重置按钮可重新复制当前全局值。
      recentMinRatioOverride: draft.recentMinRatioOverride ??
          snapshot.contextBudget?.recentMinRatio,
      retrievalRatioOverride: draft.retrievalRatioOverride ??
          snapshot.contextBudget?.retrievalRatio,
      compactionTriggerRatioOverride: draft.compactionTriggerRatioOverride ??
          snapshot.contextBudget?.compactionTriggerRatio,
      // 补齐五列：此前新建后仍 null=跟随全局。
      // effectiveContextLimit 的全局未配置保持 null（=无限制具体态）。
      effectiveContextLimit:
          draft.effectiveContextLimit ?? snapshot.effectiveContextLimit,
      // 快照 null（配置未载）时保持 null——resolver 回退链兜底，
      // 不得写死 false 覆盖「null→全局」语义
      reviewEnabledOverride:
          draft.reviewEnabledOverride ?? snapshot.reviewEnabled,
      suggestReplyPresetId:
          draft.suggestReplyPresetId ?? snapshot.suggestReplyPresetId,
      suggestReplyModelId:
          draft.suggestReplyModelId ?? snapshot.suggestReplyModelId,
      suggestReplyPromptOverride: draft.suggestReplyPromptOverride ??
          (snapshot.suggestReplyPromptOverride ?? ''),
    );

    final persisted = await _chatRepository.updateSession(sessionWithDefaults);
    state = state.copyWith(session: persisted);
  }

  /// 合并会话级与全局快照的分步骤模型配置
  ///
  /// 对每个步骤：会话级非 null 则用会话级，否则用全局快照值。
  /// 实现"快照而非引用"语义：物化时刻的全局 phaseModels 值被写入会话级，
  /// 后续全局配置变更不影响此会话。
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
      extractingPresetId:
          session.extractingPresetId ?? snapshot.extractingPresetId,
      extractingModelId:
          session.extractingModelId ?? snapshot.extractingModelId,
      reviewingPresetId:
          session.reviewingPresetId ?? snapshot.reviewingPresetId,
      reviewingModelId: session.reviewingModelId ?? snapshot.reviewingModelId,
      summarizingPresetId:
          session.summarizingPresetId ?? snapshot.summarizingPresetId,
      summarizingModelId:
          session.summarizingModelId ?? snapshot.summarizingModelId,
    );
  }

  /// 发送用户消息，启动故事模式生成状态机
  ///
  /// 创建 [_round] 上下文，各阶段产出存入其中供自动重试复用。
  /// 失败时由 [_fail] 按 [RetryConfig] 决定自动重试或进 failed。
  ///
  /// 抽取 [_prepareAndRunRound] 公共方法，与 [regenerateMessage] /
  /// [editAndResend] 共享状态机入口。本方法仅负责"普通发送"场景：
  /// 草稿会话物化 + 设置 userInput + 显式 regenerateTurnNumber=null（走 persistRound）。
  ///
  /// Stage 3：立即创建 pendingUserMessage 写入 state，UI 立即显示用户消息气泡
  /// （对齐 DOC-09A-2 §6.5）。persist 成功后清空（已落入 state.messages），
  /// 失败时保留（clearTemporary 不清空本字段）。
  Future<void> sendMessage(String userInput) async {
    // 守卫：非 idle/failed 状态忽略（DOC-09C §3 单会话串行）。
    // failed 放行直发新消息——放弃失败轮不必先清空。
    if (state.phase != IntermediatePhase.idle &&
        state.phase != IntermediatePhase.failed) {
      return;
    }
    // 守卫：手动压缩以压缩事务为先（上下文用量指示 §4.3）
    if (state.isManualCompacting) return;
    // 守卫：停止中不允许启动新轮次（防止与后台 cancel 竞态）
    if (state.isStopping) return;
    // 守卫：重生成/编辑重发「准备中」窗口（快照/删除/回滚多个 await）
    // 内 phase 仍为 idle——此窗口发送新消息会与随后的状态覆写互踩两轮。
    if (state.isPreparingRegenerate) return;

    // failed 态直发：先事务性清掉失败轮残留（旧 pending 气泡/半截快照/
    // 流式缓冲/失败上下文/_round），不留幽灵态再走正常首发链。
    if (state.phase == IntermediatePhase.failed) {
      _round = null;
      state = state.clearTemporary().copyWith(pendingUserMessage: null);
    }

    // 草稿会话检查：首次发送消息时创建真实会话
    if (isDraftSession) {
      // 草稿场景先验配置再物化——对话模式
      // 已有同款守卫，故事/导演此前先物化再在生成期报 E010，
      // 新手反复尝试会累积一串空会话。generating 与 extracting 均不可用
      // 才拦截（与配置解析的回落链一致）。
      if (!await _precheckAndMaterializeDraft()) {
        // 轮前失败也先落 userInput +
        // pendingUserMessage（对齐正常路径），失败栏「整轮重试」才有
        // 输入可重放；否则 userInput=null + _round=null 会让
        // 「整轮重试」「从中断处继续」双静默 no-op。
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
          IntermediatePhase.extracting,
          'E010',
          errorCategory: ErrorCategory.config,
        );
        return;
      }
    }

    // 立即创建 pendingUserMessage，UI 立即可见（DOC-09A-2 §6.5）
    final pendingMsg = ChatMessage(
      messageId: _uuid.v4(),
      sessionId: state.session.sessionId,
      role: 'user',
      content: userInput,
      createdAt: DateTime.now(),
    );

    // 普通发送：清空重新生成标识，走 persistRound 分支
    state = state.copyWith(
      userInput: userInput,
      pendingUserMessage: pendingMsg,
      regenerateTurnNumber: null,
      // 2026-07-29 推荐回复：用户发送消息 → 本轮结束，清空候选气泡
      // （用户需求：气泡生命周期结束于"发送消息"节点）
      suggestReplies: [],
      isGeneratingSuggest: false,
      suggestExpanded: false,
      suggestFailed: false,
    );
    await _prepareAndRunRound();
  }

  /// 草稿会话发送前置检查 + 物化（抽出供 [retry] 复用）
  ///
  /// generating 与 extracting 命名配置均不可用时返回 false（调用方按
  /// E010 拦截，不物化草稿、不制造空会话）；可用时物化草稿并返回 true。
  /// 从 [sendMessage] 抽出——草稿预检 E010 失败后
  /// 用户补齐配置再点失败栏「整轮重试」，重试路径与首发同口径。
  Future<bool> _precheckAndMaterializeDraft() async {
    final preGenerating = await _configurationResolver
        .resolveIntermediatePhaseNamingConfig(state.session, 'generating');
    final preExtracting = preGenerating ??
        await _configurationResolver.resolveIntermediatePhaseNamingConfig(
          state.session,
          'extracting',
        );
    if (preExtracting == null) return false;
    await _materializeDraftSession();
    return true;
  }

  /// 准备并启动故事模式生成状态机（抽取的公共入口）
  ///
  /// 前置条件：调用方已设置 [IntermediateChatState.userInput] 和
  /// [IntermediateChatState.regenerateTurnNumber]：
  /// - [sendMessage]：regenerateTurnNumber=null（走 persistRound）
  /// - [regenerateMessage]：regenerateTurnNumber=targetTurn（走 persistRegeneratedRound）
  /// - [editAndResend]：regenerateTurnNumber=null（user 也删了，走 persistRound）
  ///
  /// 内部完成：state 切 generating → 加载 config → resolveSettings →
  /// 创建 [_round] → 调用 [_runGeneratePhase]。

  /// 解析单次请求实际使用的 contextWindow（v0.2，2026-07-29 新增）
  ///
  /// 优先级：取 `min(effectiveContextLimit, modelWindow)`。
  /// - `effectiveContextLimit`：会话级 > 全局 intermediate.context.effectiveContextLimit
  ///   由 [ConfigurationResolver.resolveIntermediateSettings] 解析得到
  /// - `modelWindow`：模型元数据 `contextWindowTokens`，未知回退到 96000
  ///
  /// 边界处理：
  /// - effectiveContextLimit=null/<=0 → 使用 modelWindow（保持原行为）
  /// - effectiveContextLimit >= modelWindow → 使用 modelWindow（避免超模型能力）
  /// - effectiveContextLimit < modelWindow → 使用 effectiveContextLimit（用户主动限制）
  ///
  /// 用途：应对 TPM 限制（如腾讯云 500万 TPM），用户可通过此配置主动控制
  /// 每次请求塞入的 token 数，避免单次请求就触发 429。
  /// 仅影响 generating/reviewing 阶段的 token 预算缩减。
  int _resolveContextWindow(int? effectiveContextLimit, int? modelWindow) {
    final resolved = modelWindow ?? ConfigurationResolver.defaultContextWindow;
    if (effectiveContextLimit == null || effectiveContextLimit <= 0) {
      return resolved;
    }
    return effectiveContextLimit < resolved ? effectiveContextLimit : resolved;
  }

  Future<void> _prepareAndRunRound() async {
    // 守卫：停止中不允许启动新轮次（防止与后台 cancel 竞态）
    if (state.isStopping) return;
    _streamRunner.resetCancelled();
    _backgroundInterrupted = false;

    // 审查  修复：初始设为 compacting 而非 extracting。
    // compacting 阶段会先检查是否需要压缩，不需要时再切到 extracting。
    // 这样避免 extracting → compacting → extracting 的阶段闪烁。
    // UI 在 compacting 阶段显示压缩检查/压缩中的加载态（审查  修复）。
    //
    // 2026-08-01 修复：首轮（消息数 < 8 = 4 轮 × 2 条）时直接设为 extracting，
    // 避免 compacting 阶段闪现压缩提示。shouldCompact 内部有相同的
    // _minRecentMessages * 2 保护，但 phase 已被设为 compacting 时 UI 会显示提示。
    //
    // 2026-08-04 修复（重要）：phase 统一初始化为 extracting。
    // 用户反馈"每轮都看到正在压缩对话历史"有两个根因：
    // 1. service=null 未注入（已修复注入）
    // 2. 不压缩时 phase 停留在 compacting（_runCompactionPhase 未切回，
    //    已在 phases.dart 修复）
    // 3. 初始 phase=compacting 导致检查期间（配置加载 + token 计数）
    //    UI 仍显示压缩提示
    // 现在统一初始化为 extracting：只有 _runCompactionPhase 确认要压缩时
    // 才切到 compacting，未触发压缩时用户完全看不到压缩提示。
    _retryWaitTotal = Duration.zero; // 新轮预算闸累计清零（批 E）
    state = state.copyWith(
      phase: IntermediatePhase.extracting,
      failureContext: null,
      streamingGenerated: '',
      streamingGeneratedThinking: null,
      retryCounts: {},
      // 疑似重复候选随新一轮清空
      similarNameCandidates: null,
    );

    IntermediateConfig config;
    try {
      config = await _getConfig();
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to load intermediate config',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      //  修复：配置加载失败发生在任何阶段之前，此前记
      // phase=generating 会让失败栏误显示"失败阶段：生成回复"，误导排查
      // 方向；改为 extracting（与 :703 处命名配置缺失同口径，也是重试
      // 的正确重入阶段）。
      await _fail(
        IntermediatePhase.extracting,
        'E010',
        error: e,
        errorCategory: ErrorCategory.config,
      );
      return;
    }

    // 应用会话级工具调用覆盖（DOC-09B §8.6 / §10.2 V2）
    // session.jsonModeOverride != null 时强制覆盖 stream.toolCallingEnabled
    //（V2 六步流程中 extracting/summarizing 读取此字段决定结构化输出策略）
    final jsonOverride = state.session.jsonModeOverride;
    if (jsonOverride != null) {
      config = _applyToolCallingOverride(config, jsonOverride);
    }

    try {
      final resolved = await _configurationResolver.resolveIntermediateSettings(
        state.session,
      );
      final settings = resolved.settings;
      // 分步骤模型配置：各阶段各自解析 NamingConfig（未配置时回退到全局默认）
      final generatingNamingConfig =
          await _configurationResolver.resolveIntermediatePhaseNamingConfig(
        state.session,
        'generating',
      );
      final extractNamingConfig =
          await _configurationResolver.resolveIntermediatePhaseNamingConfig(
        state.session,
        'extracting',
      );
      final reviewingNamingConfig =
          await _configurationResolver.resolveIntermediatePhaseNamingConfig(
        state.session,
        'reviewing',
      );
      final summarizeNamingConfig =
          await _configurationResolver.resolveIntermediatePhaseNamingConfig(
        state.session,
        'summarizing',
      );
      // 2026-08-04 修复：contextWindow 从 generating 阶段的模型配置解析，
      // 而非 resolveModelDisplayInfo（后者用 Simple 模式的 session.presetId/modelId，
      // 中级模式会话这两个字段为空，导致回退到默认 96000，远小于用户实际模型的 200k）。
      final generatingModelWindow =
          await _configurationResolver.resolveContextWindowForPhase(
        presetId: generatingNamingConfig?.presetId,
        modelId: generatingNamingConfig?.modelId,
      );
      final contextWindow = _resolveContextWindow(
        settings.effectiveContextLimit,
        generatingModelWindow,
      );

      // 校验 extracting 阶段配置（extracting 是第一步，必须可用）
      // extractNamingConfig 未配置时回退到 generatingNamingConfig
      final effectiveExtractNaming =
          extractNamingConfig ?? generatingNamingConfig;
      if (effectiveExtractNaming == null ||
          effectiveExtractNaming.baseUrl.isEmpty ||
          effectiveExtractNaming.apiKey.isEmpty ||
          effectiveExtractNaming.modelId.isEmpty) {
        await _fail(
          IntermediatePhase.extracting,
          'E010',
          errorCategory: ErrorCategory.config,
        );
        return;
      }

      // 2026-08-04 修复：使用按 CompactionPoint 过滤后的历史消息，
      // 避免 shouldCompact 看到已压缩的旧消息导致每轮误触发压缩。
      // 过滤逻辑详见 _loadFilteredMessages。
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

      // V1：解析 embedding 配置（全局，null = 未配置 → FTS5 兜底）
      final embeddingConfig =
          await _configurationResolver.resolveEmbeddingConfig();

      // 解析全局网络超时配置（修复 timeout 在故事模式不生效的 bug）
      // 故事模式 9 处 LlmRequest 构造点通过 RoundContext 透传 timeout
      final timeouts = await _configurationResolver.resolveTimeouts();

      // 创建轮次上下文，供自动重试复用
      // userInput 由调用方预设（sendMessage/regenerateMessage/editAndResend）
      // turnNumber 推导：每轮 = user + assistant 两条，+1 表示当前轮次序号
      // 审查  修复：合并会话级 contextBudget 覆盖到全局配置
      // 会话级覆盖优先级：会话级（非NULL）> 全局
      final mergedConfig = _applyContextBudgetOverride(config, settings);

      // 上下文用量指示 §3.1：容量与触发线存入 state（与
      // _runCompactionPhase 的 shouldCompact 同源同值）
      state = state.copyWith(
        contextWindowTokens: contextWindow,
        compactionTriggerTokens:
            (contextWindow * mergedConfig.contextBudget.compactionTriggerRatio)
                .floor(),
      );

      // 分步骤模型配置（2026-07-21 重构后）：
      // - 各阶段使用对应 NamingConfig
      // - 若 extracting/reviewing/summarizing 未配置（resolveIntermediatePhaseNamingConfig
      //   返回 null），降级复用 generatingNamingConfig
      // - generatingNamingConfig 为 null 时已在上面 E010 错误终止，此处保证非 null
      // 轮前输入被异步清空（取消/状态回写竞态）时不再让
      // `!` 抛裸 Null check 进 Zone（表现为失败横幅下「整轮重试」无响应），
      // 安全复位为 idle 让用户重新发送。
      final roundInput = state.userInput;
      if (roundInput == null || roundInput.isEmpty) {
        _logger.warn(
          'Round input missing at RoundContext build; aborting to idle',
        );
        state = state.copyWith(
          phase: IntermediatePhase.idle,
          pendingUserMessage: null,
          failureContext: null,
        );
        return;
      }
      _retryWaitTotal = Duration.zero;
      _round = RoundContext(
        userInput: roundInput,
        history: history,
        settings: settings,
        generatingNamingConfig:
            generatingNamingConfig ?? effectiveExtractNaming,
        extractNamingConfig: effectiveExtractNaming,
        reviewingNamingConfig: reviewingNamingConfig ?? effectiveExtractNaming,
        summarizeNamingConfig: summarizeNamingConfig ?? effectiveExtractNaming,
        contextWindow: contextWindow,
        config: mergedConfig.storyRuntime,
        embeddingConfig: embeddingConfig,
        //  turn 单一事实源：本轮轮号在轮前一次定值，全轮复用——
        // 重生成场景用 regenerateTurnNumber（覆盖该轮）；
        // 普通场景 next_turn 计数器优先（DB 内最新值），NULL 惰性回退公式
        //（公式输入用 state.messages 轮前视图：persist/删除/压缩各路径
        // 均同步维护它，且不受轮内压缩替换影响——轮号已在此刻定值）。
        // 轮内压缩不再重算（旧公式轮前/轮后各算一次，压缩边界分裂时
        // eventSummary 与 artifacts 写入不同轮号，即  同事务双轮号）。
        turnNumber: state.regenerateTurnNumber ??
            resolveTurnNumber(
              nextTurn: filtered.nextTurn,
              compactedTurnBase: filtered.compactedTurnBase,
              messages: state.messages,
            ),
        connectTimeout: timeouts.connectTimeout,
        readTimeout: timeouts.readTimeout,
        // 叙事时间机制：传入会话当前叙事时间，
        // 供 summarizing 阶段构建时间线上下文判断本轮时间是否推进。
        currentNarrativeTime: state.session.currentNarrativeTime,
      );

      // 回填持久化压缩摘要（2026-08-22 修复）：filterByCompactionPoint 返回的
      // 摘要消息是 system 角色，不会进入各阶段消息组装；不回填会导致压缩后
      // 摘要从所有请求中消失（已压缩剧情丢失）、压缩退化为每次从零重写
      // （非累积），且 generating/extracting 的缓存前缀在次轮断裂。
      _round!.compactionSummary =
          StoryCompactionService.extractPersistedSummary(history);

      // extracting 前置，先提取关键词再检索，最后生成生成内容
      // compacting 前置于 extracting，检查 token 阈值并压缩旧对话
      // _runCompactionPhase 内部判断是否需要压缩，无论是否压缩最终都调用 _runExtractPhase

      // v0.2.2 新增：预先计算本轮是否启用审查阶段，存入 state 供 UI 使用。
      // UI 据此决定 generating 阶段是否显示 GeneratePanel：
      // - true：显示生成面板（generating 流式生成 → reviewing 流式回复）
      // - false：不显示生成面板（generating 流式直接在回复气泡位置显示）
      final reviewEnabled = _shouldReview(_round!);
      state = state.copyWith(isReviewEnabled: reviewEnabled);

      await _runCompactionPhase(_round!);
    } catch (e, stackTrace) {
      _logger.error(
        'Extract phase setup failed',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      await _fail(
        IntermediatePhase.extracting,
        'E010',
        error: e,
        errorCategory: ErrorCategory.config,
      );
    }
  }

  // _runCompactionPhase / _runExtractPhase / _runRetrievePhase /
  // _runDraftPhase / _runRevisePhase / _runSummarizePhase / _shouldRevise
  // 已拆分到 intermediate_chat_controller_phases.dart
  // _runPersistPhase 已拆分到 intermediate_chat_controller_persist.dart

  // ==================== 失败 / 重试 / 取消 ====================

  // _fail / _scheduleRetry / retry / continueWithFts5Only /
  // continueFromFailed / _reloadRoundConfigPreservingOutputs
  // 已拆分到 intermediate_chat_controller_retry.dart

  /// 应用会话级工具调用覆盖（DOC-09B §8.6 / §10.2 V2）
  ///
  /// 会话级 `jsonModeOverride` 非 null 时，强制覆盖 `stream.toolCallingEnabled`，
  /// 控制 V2 六步流程中 extracting/summarizing 的结构化输出策略：
  /// - `true`：优先工具调用，不兼容时自动降级到 JSON 模式
  /// - `false`：直接使用 JSON 模式（兼容不支持工具调用的供应商）
  ///
  /// 返回新的 [IntermediateConfig] 实例（原 config 不变，避免污染 provider 缓存）。
  IntermediateConfig _applyToolCallingOverride(
    IntermediateConfig config,
    bool enabled,
  ) {
    final stream = config.stream;
    if (stream.toolCallingEnabled == enabled) {
      // 全局配置已与会话级覆盖一致，无需重建
      return config;
    }
    return IntermediateConfig(
      embeddingPresetId: config.embeddingPresetId,
      embeddingModelId: config.embeddingModelId,
      systemPrompt: config.systemPrompt,
      generation: config.generation,
      retrieval: config.retrieval,
      context: config.context,
      retry: config.retry,
      phaseModels: config.phaseModels,
      embedding: config.embedding,
      stream: StreamConfig(
        toolCallingEnabled: enabled,
        skipReviewWhenEmptyRetrieval: stream.skipReviewWhenEmptyRetrieval,
        generatingFoldDelayMs: stream.generatingFoldDelayMs,
        retrievalFoldDelayMs: stream.retrievalFoldDelayMs,
      ),
      fork: config.fork,
      prompts: config.prompts,
      consolidation: config.consolidation,
      memory: config.memory,
      suggestReply: config.suggestReply,
      // 修复：_applyToolCallingOverride 重建 config 时必须透传
      // reviewEnabled，否则 jsonModeOverride != null 时会丢失 forceReviewEnabled
      // 设置的 true 值，导致 reviewing 被意外跳过。
      reviewEnabled: config.reviewEnabled,
      contextBudget: config.contextBudget,
    );
  }

  /// 合并会话级 contextBudget 到全局配置（快照独立模式）
  ///
  /// 物化时会话级字段已从全局复制快照值（非 null），直接使用会话级值。
  /// 草稿阶段（未物化）字段为 null，回退到全局配置。
  ///
  /// 优先级：会话级（非NULL）> 全局
  /// - [ChatSession.compactionTriggerRatioOverride] → ContextBudget.compactionTriggerRatio
  /// - [ChatSession.recentMinRatioOverride] → ContextBudget.recentMinRatio
  /// - [ChatSession.retrievalRatioOverride] → ContextBudget.retrievalRatio
  ///
  /// 若会话级字段均为 null（草稿阶段），直接返回原 config。
  IntermediateConfig _applyContextBudgetOverride(
    IntermediateConfig config,
    ChatSessionSettings settings,
  ) {
    final sessionCompactionTrigger = settings.compactionTriggerRatioOverride;
    final sessionRecentMin = settings.recentMinRatioOverride;
    final sessionRetrieval = settings.retrievalRatioOverride;

    // 无会话级覆盖，直接返回原 config
    if (sessionCompactionTrigger == null &&
        sessionRecentMin == null &&
        sessionRetrieval == null) {
      return config;
    }

    final globalBudget = config.contextBudget;
    final mergedBudget = ContextBudget(
      compactionTriggerRatio:
          sessionCompactionTrigger ?? globalBudget.compactionTriggerRatio,
      recentMinRatio: sessionRecentMin ?? globalBudget.recentMinRatio,
      retrievalRatio: sessionRetrieval ?? globalBudget.retrievalRatio,
      recentMinTokenTarget: globalBudget.recentMinTokenTarget,
    );

    return IntermediateConfig(
      embeddingPresetId: config.embeddingPresetId,
      embeddingModelId: config.embeddingModelId,
      systemPrompt: config.systemPrompt,
      generation: config.generation,
      retrieval: config.retrieval,
      context: config.context,
      retry: config.retry,
      phaseModels: config.phaseModels,
      embedding: config.embedding,
      stream: config.stream,
      fork: config.fork,
      prompts: config.prompts,
      consolidation: config.consolidation,
      memory: config.memory,
      suggestReply: config.suggestReply,
      reviewEnabled: config.reviewEnabled,
      contextBudget: mergedBudget,
    );
  }

  // ==================== 重建向量索引（2026-07-21 新增）====================

  /// 重建会话内全部未向量化的经历类记忆的 embedding 向量。
  ///
  /// 用户在会话设置 sheet 中手动触发补全 embedding。
  /// 触发场景：
  /// - 之前未配置 embedding 模型时持久化的记忆（has_embedding=false）
  /// - E104 错误后用户选择"临时降级继续"的本轮记忆（has_embedding=false）
  /// - embedding API 失败 + fallbackOnFailure=true 的旧记忆（has_embedding=false）
  ///
  /// 流程：
  /// 1. 守卫：phase=idle（生成中不允许重建，避免与 persisting 阶段并发写 embedding）
  /// 2. 解析当前 embedding 配置（全局，未配置 → 返回 failureReason='not_configured'）
  /// 3. 查询 has_embedding=false 的记忆列表（按 turn_number 升序）
  /// 4. 逐条调用 [EmbeddingService.embed] → [ExperienceRepository.updateEmbedding]
  /// 5. 失败的记忆跳过（不中断整体重建），最终返回统计
  ///
  /// [onProgress] 进度回调：(processed, total, failed) — UI 用于更新进度条。
  /// 调用方在每条记忆处理完成后回调一次（首条前不回调，末条后回调最后一次）。
  ///
  /// 返回 `({total, succeeded, failed, failureReason})`：
  /// - `failureReason` 非 null 表示全局失败（'busy' / 'not_configured'），后续字段全为 0
  /// - `failureReason` 为 null 时 `succeeded` + `failed` = `total`
  Future<({int total, int succeeded, int failed, String? failureReason})>
      rebuildEmbeddings({
    required void Function(int processed, int total, int failed) onProgress,
  }) async {
    // 1. 守卫：仅 idle 状态允许重建
    if (state.phase != IntermediatePhase.idle) {
      return (
        total: 0,
        succeeded: 0,
        failed: 0,
        failureReason: 'busy',
      );
    }

    // 2. 解析 embedding 配置
    final embeddingConfig =
        await _configurationResolver.resolveEmbeddingConfig();
    if (embeddingConfig == null) {
      return (
        total: 0,
        succeeded: 0,
        failed: 0,
        failureReason: 'not_configured',
      );
    }

    // 2026-07-22 修复：读取 microVectorizeThreshold，对齐持久化时的两级向量化
    // 策略。持久化时 importance < microVectorizeThreshold(默认4) 的记忆有意不
    // 建 embedding，重建时也不应补齐这些记忆。
    final microVectorizeThreshold =
        await _configurationResolver.resolveMicroVectorizeThreshold();

    // 3. 查询需要（重）向量化的记忆（按 importance 阈值筛选）。
    // 以会话最近写入维度为基准并入陈旧行——换嵌入
    // 模型后维度不符的旧向量被检索静默跳过，重建即自愈。
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

    // 4. 逐条向量化
    var succeeded = 0;
    var failed = 0;
    for (var i = 0; i < memories.length; i++) {
      final memory = memories[i];
      try {
        final text = _buildMemoryEmbeddingText(memory);
        final embedding = await _embeddingService.embed(
          text: text,
          // 重建索引是入库文本侧（非对称模型注入 input_type=passage）
          kind: EmbeddingInputKind.passage,
          model: embeddingConfig.model,
          baseUrl: embeddingConfig.baseUrl,
          apiKey: embeddingConfig.apiKey,
          timeout: Duration(milliseconds: embeddingConfig.timeoutMs),
        );
        await _experienceRepository.updateEmbedding(memory.memoryId, embedding);
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
      'Rebuild embeddings completed',
      detail: 'total=${memories.length} succeeded=$succeeded failed=$failed',
    );
    return (
      total: memories.length,
      succeeded: succeeded,
      failed: failed,
      failureReason: null,
    );
  }

  // _buildMemoryEmbeddingText 已拆分到 intermediate_chat_controller_embeddings.dart

  // canOperateMessage / regenerateMessage / editAndResend / deleteRound /
  // _rollbackNarrativeTime / editPendingUserMessage / deletePendingUserMessage /
  // _computeTurnNumber / _removeArtifactsFromTurn / clearRound
  // 已拆分到 intermediate_chat_controller_messages.dart

  /// 取消：停止 SSE + 清理临时状态（DOC-09C §3）
  ///
  /// 生成/审查流式中途停止且正文已流出时，不再丢弃半截正文——与失败
  /// 路径同款快照通路：进「已停止」failed 态，保留未完成稿件卡与
  /// 「以此收稿/续写」出口（失败栏文案区分：手动停止非错误）。其余
  /// 阶段（提取/摘要/压缩/持久化）无正文可保，维持清场回 idle 行为。
  ///
  /// 同时清空 pendingUserMessage（气泡消失），保留 userInput 供页面层
  /// 回写到输入框（用户无需重新打字）。
  ///
  /// **响应优化**：改为 fire-and-forget 模式 --
  /// 1. 立即（同步）设置 isStopping=true + 清空 _round + 清理临时 state
  /// 2. 后台执行 _streamRunner.cancel()（await subscription.cancel()）
  /// 3. 后台完成后清空 isStopping
  ///
  /// 这样用户点击停止按钮后 UI 立即响应（按钮变灰 + 文本回写），
  /// 不需要等待流式订阅的异步取消完成。
  Future<void> cancel() async {
    // 守卫：已在停止中或不在生成状态，忽略重复调用
    if (state.isStopping) return;
    if (state.phase == IntermediatePhase.idle ||
        state.phase == IntermediatePhase.failed) {
      return;
    }

    // Phase 1：立即更新状态（同步部分）
    // _streamRunner.cancel() 返回 Future，但其同步部分（_isCancelled=true
    // + token.cancel()）在调用时立即执行，无需 await
    final cancelFuture = _streamRunner.cancel();
    // 压缩阶段（无流式订阅）的停止走压缩令牌
    _activeCompactionToken?.cancel();

    // 正文快照优先 streamingGenerated（review-on 生成草稿——中断时即
    // 正文最完整形态），回退 streamingReply（review-off 直写/审查修正稿），
    // 与 _fail 的快照口径一致。
    final stoppedPhase = state.phase;
    final partial = switch (stoppedPhase) {
      IntermediatePhase.generating ||
      IntermediatePhase.generatingRetry ||
      IntermediatePhase.reviewing ||
      IntermediatePhase.reviewingRetry =>
        _firstNonEmpty(
          state.streamingGenerated,
          state.streamingReply,
        ),
      _ => null,
    };
    if (partial != null && partial.isNotEmpty && _round != null) {
      // 保留路径：_round 不清（收稿/续写出口依赖），pending 气泡保留
      //（与失败态呈现同构）；失败阶段归一到 generating/reviewing 基础
      // 相位（收稿守卫 canAcceptPartialReply 只认基础相位）。
      final failedPhase = stoppedPhase == IntermediatePhase.reviewing ||
              stoppedPhase == IntermediatePhase.reviewingRetry
          ? IntermediatePhase.reviewing
          : IntermediatePhase.generating;
      state = state.clearTemporary().copyWith(
            phase: IntermediatePhase.failed,
            failureContext: FailureContext(
              errorCode: 'user_stopped',
              failedPhase: failedPhase,
              errorMessage: t.intermediate.chat.failure.stopped,
              retryable: true,
            ),
            partialReplySnapshot: partial,
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

    // Phase 2：后台等待流式清理完成，然后解除 isStopping
    // 不用 await -- 让 cancel() 方法立即返回，UI 即刻响应
    unawaited(_waitForCancelCompletion(cancelFuture));
  }

  /// 后台等待 `_streamRunner.cancel` 的 Future 完成，然后清除 isStopping。
  ///
  /// 使用 3 秒超时兜底，防止 subscription.cancel() 卡住导致永久 stopping。
  ///
  /// [resetStreamAfter]：停止保留半截正文的分支置 true——订阅取消完成后
  /// 复位流式取消标志（先于 isStopping 清除，避免 UI 见到可交互态时标志
  /// 仍拦截事件）；否则收稿/续写等出口不经 _prepareAndRunRound，其后续
  /// 流式事件会被残留的取消标志全部丢弃。
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

  /// 清空 [IntermediateChatState.userInput]
  ///
  /// 页面层把 userInput 回写到输入框后调用，避免重复触发回写逻辑。
  void clearUserInput() {
    state = state.copyWith(userInput: null);
  }

  // generateSuggestReplies / selectSuggestReply / toggleSuggest / closeSuggest
  // 已拆分到 intermediate_chat_controller_suggest.dart

  /// App 切到后台时主动中断生成（由 `MainLayout._handleAppPaused` 调用）。
  ///
  /// 核心机制：
  /// 1. 设置 `_backgroundInterrupted = true`，让 `recoverIfStuck` 在 resumed
  ///    时能检测到（即使 cancel 的 `await sub?.cancel()` 尚未完成、
  ///    `_streamRunner.isStreaming` 仍为 true 也能检测到）。
  /// 2. 调用 `_streamRunner.cancel()`（fire-and-forget）：
  ///    - `_isCancelled = true` 立即生效（同步）
  ///    - `token?.cancel()` 同步触发 SSE 底层 `addError(CancelledException)`
  ///    - SSE 流 onError -> catch 块 -> `_fail` ->
  ///      `if (_streamRunner.isCancelled) return;` 直接返回，**不自动重试**
  ///    - `readTimer` 被取消，不会触发 readTimeout
  ///
  /// 为什么不依赖 readTimeout 被动超时：
  /// readTimeout 超时后 `_fail` 会触发 `_scheduleRetry` 自动重试，
  /// 重试发起的新 SSE 请求让 `recoverIfStuck` 的 `isStreaming` 检测失效，
  /// 导致用户回到前台后看到"从中断步骤继续生成"（实际是自动重试），
  /// 且重试使用可能不完整的 `_round` 上下文（compacting 修改了 history
  /// 但 CompactionPoint 未持久化），导致上下文缺失。
  void onBackgroundInterrupt() {
    // 守卫：只有非 idle/failed 状态才需要中断，idle/failed 直接跳过
    if (state.phase == IntermediatePhase.idle ||
        state.phase == IntermediatePhase.failed) {
      return;
    }
    // persisting 豁免——此时六步管线
    // 的全部 LLM 产出已收全，persist 是本地事务+一次可降级的 embedding 调用；
    // 置位中断标志会让 recoverIfStuck 在恢复时把 _round 清空，与 persist
    // 事务竞态（「完成不报」：DB 已提交、UI 面板整组消失）。
    if (state.phase == IntermediatePhase.persisting) {
      return;
    }
    _backgroundInterrupted = true;
    // fire-and-forget：_isCancelled = true 立即生效（同步），
    // 不需要 await（didChangeAppLifecycleState 是同步回调）
    _streamRunner.cancel();
    // 后台中断同样终止在途压缩
    _activeCompactionToken?.cancel();
  }

  /// 检测并恢复卡死状态（App 从后台恢复时调用）。
  ///
  /// 场景：App 切后台时 OS 暂停网络 → 30s readTimeout 误杀流 → 流死但
  /// phase 仍停在 generating/reviewing/extracting/summarizing 等流式阶段。
  /// 切回前台时检测到 `!_streamRunner.isStreaming` 但 phase 非 idle/failed
  /// → 清理到 idle。
  ///
  /// 覆盖所有使用 StreamRunner 的流式阶段：
  /// generating/generatingRetry/reviewing/reviewingRetry（纯文本流式）+
  /// extracting/extractingRetry/summarizing/summarizingRetry（工具调用流式）。
  /// persisting 是 DB 事务（无流），retrieving 是 DB 查询（无流）——
  /// 这些阶段不靠流式订阅判断，且通常很快完成。
  ///
  /// 返回 true 表示发生了恢复（调用方应提示用户"后台生成已中断"）。
  ///
  /// **后台中断检测增强**：`onBackgroundInterrupt` 设置 `_backgroundInterrupted`
  /// 后，即使 `_streamRunner.isStreaming` 仍为 true（cancel 的 async 部分
  /// 尚未完成），也能通过此标志检测到并恢复。
  bool recoverIfStuck() {
    // persisting 阶段放行——标志可能是在更早的流式阶段置位、
    // 流已自然完成并推进到 persisting；此时数据已收全，复位会与 persist
    // 事务竞态（清 _round 导致事务提交后状态更新被身份检查静默丢弃）。
    // 清标志返回未恢复，让 persist 自然完成（轮数据完整性由事务保证）。
    if (state.phase == IntermediatePhase.persisting) {
      _backgroundInterrupted = false;
      return false;
    }
    final isStreamingPhase = state.phase == IntermediatePhase.generating ||
        state.phase == IntermediatePhase.generatingRetry ||
        state.phase == IntermediatePhase.reviewing ||
        state.phase == IntermediatePhase.reviewingRetry ||
        state.phase == IntermediatePhase.extracting ||
        state.phase == IntermediatePhase.extractingRetry ||
        state.phase == IntermediatePhase.summarizing ||
        state.phase == IntermediatePhase.summarizingRetry;
    // 后台中断 或 流式阶段但流已死 -> 恢复
    if (_backgroundInterrupted ||
        (isStreamingPhase && !_streamRunner.isStreaming)) {
      _backgroundInterrupted = false;
      // 生成/审查流式中断且正文已流出：与手动停止同款保留半截正文——
      // 进「已停止」failed 态而非清场回 idle（失败栏给收稿/续写出口）。
      final interruptedPhase = state.phase;
      final partial = switch (interruptedPhase) {
        IntermediatePhase.generating ||
        IntermediatePhase.generatingRetry ||
        IntermediatePhase.reviewing ||
        IntermediatePhase.reviewingRetry =>
          _firstNonEmpty(
            state.streamingGenerated,
            state.streamingReply,
          ),
        _ => null,
      };
      if (partial != null && partial.isNotEmpty && _round != null) {
        final failedPhase = interruptedPhase == IntermediatePhase.reviewing ||
                interruptedPhase == IntermediatePhase.reviewingRetry
            ? IntermediatePhase.reviewing
            : IntermediatePhase.generating;
        state = state.clearTemporary().copyWith(
              phase: IntermediatePhase.failed,
              failureContext: FailureContext(
                errorCode: 'user_stopped',
                failedPhase: failedPhase,
                errorMessage: t.intermediate.chat.failure.stopped,
                retryable: true,
              ),
              partialReplySnapshot: partial,
              // 恢复点即解除停止残留（后台 cancel 回调不会再跑）
              isStopping: false,
            );
        // 出口（收稿/续写）不经 _prepareAndRunRound，同 cancel 复位标志
        _streamRunner.resetCancelled();
        return true;
      }
      _round = null;
      // 清空 pendingUserMessage（气泡消失），保留 userInput 供页面层
      // 回写到输入框（用户无需重新打字）
      // 同时清除 isStopping（后台恢复时停止状态可能残留）
      state = state.clearTemporary().copyWith(
            pendingUserMessage: null,
            isStopping: false,
          );
      return true;
    }
    return false;
  }

  // ==================== 辅助方法 ====================

  // ──  会话标题自动生成 ──────────────────────────────────────────

  /// 自动命名写回的 CAS 允许集合——草稿标题与空串；
  /// 首轮生成在途期间用户手动重命名的会话（当前标题不在此集合）不被自动
  /// 命名覆盖。（前的旧默认「故事」不入集合：本文件不在中文字面量
  /// 门禁白名单，且该存量会话重生成首论的更命名属极窄边缘，可接受跳过。）
  Set<String> get _autoNameAllowedTitles => <String>{
        '',
        t.intermediate.draft.title,
      };

  /// 首轮 persist 成功后异步生成会话标题
  ///
  /// 由 [_runPersistPhase] 在 `turnNumber == 1 && !isRegenerate` 时触发，
  /// 使用 `unawaited` 包裹，不阻塞 UI、不影响主流程。
  ///
  /// 流程（2026-09-09 标题模型三级优先级）：
  /// 1. 调用 [ConfigurationResolver.resolveTitleNamingConfig] 解析配置的标题模型
  ///    （`common.title_model`）
  /// 2. 未配置 → 回退 generating 阶段业务模型
  ///    [ConfigurationResolver.resolveIntermediatePhaseNamingConfig]
  /// 3. 两者均不可用 → 走 [SessionTitleGenerator.fallbackTitle] fallback（回复前缀）
  /// 4. 可用 → 调用 [SessionTitleGenerator.generate] 让 LLM 生成简短标题
  /// 5. 成功 → 持久化标题 + 更新 state
  /// 6. LLM 失败/超时 → 走 [SessionTitleGenerator.fallbackTitle] fallback
  /// 7. 整体异常 → 记 warn 日志，不抛出（标题生成失败不影响会话）
  ///
  /// 2026-07-21 配置架构重构：原方法接受 `namingConfig` 参数（来自 generating
  /// 阶段的业务模型配置），现改为内部调用 `resolveTitleNamingConfig()`，
  /// 与业务模型解耦，所有模式的标题生成统一走 `common.title_model`。
  ///
  /// 设计依据：DOC-09B §10（配置参数），复用统一 [LlmService] 调用层
  /// （区别于 Simple 模式直接 http.post，中级模式走 Domain 抽象接口）。
  Future<void> _autoNameSession({
    required String userInput,
    required String assistantReply,
  }) async {
    try {
      // 解析标题模型（2026-09-09 三级优先级：common.title_model > generating
      // 阶段业务模型 > fallback 前缀；第 3 级在下方 generated 为 null 时兜底）
      final namingConfig =
          await _configurationResolver.resolveTitleNamingConfig() ??
              await _configurationResolver.resolveIntermediatePhaseNamingConfig(
                state.session,
                'generating',
              );
      if (namingConfig == null) {
        // 标题模型与生成模型均不可用 → 直接走 fallback（回复前缀）
        final title = SessionTitleGenerator.fallbackTitle(
          userInput,
          defaultTitle: t.chat.draft.title,
        );
        final written =
            await _chatRepository.updateSessionTitleIfCurrentTitleIn(
          state.session.sessionId,
          title,
          _autoNameAllowedTitles,
        );
        if (!written) return;
        state = state.copyWith(
          session: state.session.copyWith(title: title),
        );
        return;
      }

      final generated = await _titleGenerator!.generate(
        userMessage: userInput,
        assistantReply: assistantReply,
        namingConfig: namingConfig,
      );

      // LLM 失败/超时返回 null → 走 fallback（截取首条用户消息前 20 字符）
      final title = generated ??
          SessionTitleGenerator.fallbackTitle(
            userInput,
            defaultTitle: t.chat.draft.title,
          );

      final written = await _chatRepository.updateSessionTitleIfCurrentTitleIn(
        state.session.sessionId,
        title,
        _autoNameAllowedTitles,
      );
      if (!written) return;

      state = state.copyWith(
        session: state.session.copyWith(title: title),
      );
    } catch (e, stackTrace) {
      // 标题生成失败不影响会话主流程，仅记日志
      _logger.warn(
        'Auto-name session failed',
        detail: '$e\n$stackTrace',
      );
    }
  }

  // _maybeConsolidateMemories / _runConsolidation 已拆分到
  // intermediate_chat_controller_consolidation.dart
  // _formatMessagesForLog / _formatMemoriesForLog 已拆分到
  // intermediate_chat_controller_logs.dart
  // _resolveQueryVector / _buildEmbeddingText / _resolveEmbedding 已拆分到
  // intermediate_chat_controller_embeddings.dart

  @override
  void dispose() {
    // dispose 冲刷压缩缓冲——压缩流
    // 中途控制器被销毁时，挂起尾段落账后销毁 Timer；否则 32ms 后 Timer
    // 回调对已 dispose 的 StateNotifier 写 state（StateError）。
    _flushManualCompactionDeltas();
    _streamRunner.cleanup();
    super.dispose();
  }
}
