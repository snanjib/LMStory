import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:lmstory/core/agent/agent_budget.dart';
import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_events.dart';
import 'package:lmstory/core/agent/agent_llm_gateway.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/agent/agent_runner.dart';
import 'package:lmstory/core/agent/agent_skill_registry.dart';
import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/core/agent/agent_tool_pipeline.dart';
import 'package:lmstory/core/agent/doom_loop_detector.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/output_token_policy.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/llm/context_overflow.dart';
import 'package:lmstory/core/llm/reasoning_effort.dart';
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';
import 'package:lmstory/core/network/http_client_types.dart';
import 'package:lmstory/core/network/llm_adapters/anthropic_compat_options.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/advanced/data/agent_durable_event_sink.dart';
import 'package:lmstory/features/advanced/data/asset_skill_loader.dart';
import 'package:lmstory/features/advanced/data/director_step_surface_source.dart';
import 'package:lmstory/features/advanced/data/engineering_summarizer.dart';
import 'package:lmstory/features/advanced/data/story_compaction_overflow_compactor.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_event_source.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_live_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_round_draft.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/domain/entities/director_resume_context.dart';
import 'package:lmstory/features/advanced/domain/entities/director_round_tuning.dart';
import 'package:lmstory/features/advanced/domain/entities/director_session_extension.dart';
import 'package:lmstory/features/advanced/domain/entities/tool_permissions.dart';
import 'package:lmstory/features/advanced/domain/services/agent_approval_composer.dart';
import 'package:lmstory/features/advanced/domain/services/agent_live_delta_coalescer.dart';
import 'package:lmstory/features/advanced/domain/services/agent_log_recovery.dart';
import 'package:lmstory/features/advanced/domain/services/agent_pacing.dart';
import 'package:lmstory/features/advanced/domain/services/agent_prose_dedup.dart';
import 'package:lmstory/features/advanced/domain/services/agent_prose_extractor.dart';
import 'package:lmstory/features/advanced/domain/services/agent_session_tools.dart';
import 'package:lmstory/features/advanced/domain/services/agent_story_reader.dart';
import 'package:lmstory/features/advanced/domain/services/agent_style_lint.dart';
import 'package:lmstory/features/advanced/domain/services/agent_subagent.dart';
import 'package:lmstory/features/advanced/domain/services/agent_system_prompt.dart';
import 'package:lmstory/features/advanced/domain/services/agent_timeline_assembler.dart';
import 'package:lmstory/features/advanced/domain/services/compaction_planning.dart';
import 'package:lmstory/features/advanced/domain/services/director_core_blocks.dart';
import 'package:lmstory/features/advanced/domain/services/director_surface_v2.dart';
import 'package:lmstory/features/advanced/domain/services/engineering_context_mode.dart';
import 'package:lmstory/features/advanced/domain/services/retrieval_evidence.dart';
import 'package:lmstory/features/advanced/domain/services/round_bootstrap.dart';
import 'package:lmstory/features/advanced/presentation/controllers/director_host.dart';
import 'package:lmstory/features/advanced/presentation/controllers/director_story_reader.dart';
import 'package:lmstory/features/advanced/presentation/controllers/director_work_trace.dart';
import 'package:lmstory/features/advanced/presentation/utils/agent_approval_labels.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_tool_card.dart'
    show stageVerbOf;
import 'package:lmstory/features/chat/data/agent/llm_service_agent_gateway.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/entities/scored_memory.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';
import 'package:lmstory/features/memory/domain/services/attribute_schema.dart';
import 'package:lmstory/features/memory/domain/services/fact_context_builder.dart';
import 'package:lmstory/features/story_runtime/domain/entities/context_usage_estimate.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_context.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/features/story_runtime/domain/services/compaction_service.dart';
import 'package:lmstory/features/story_runtime/domain/services/failure_classifier.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:meta/meta.dart';

int _outputTokenReserveFor(
  int configured, {
  int? modelMaxOutput,
}) =>
    OutputTokenPolicy.contextReserve(
      configured: configured,
      modelMaxOutput: modelMaxOutput,
    );

/// 导演模式一轮的编排器（P1：从 IntermediateChatController 的 agent part
/// 整体迁出，逻辑原样搬迁，私有访问经 [DirectorHost] 接口）。
///
/// v0.3 导演模式（kernel swap）：mode == 'advanced' 时，把故事模式的六步
/// 管线换成 AgentRunner 自主循环。agent 的产出写回 RoundContext
/// （replyText / eventSummary / factsDeltas / scoredMemories /
/// retrievedFacts / thinkingContent），随后经 host.runPersistPhase 复用
/// 故事模式持久化落库——页面、会话设置、记忆查看器、消息操作与故事模式
/// 完全一致。
///
/// 轮次/会话级导演私有态（取消令牌、HITL completer、skill 缓存、
/// 崩溃恢复 once 标志）随迁为本类字段；HITL 公共 API（answerDirectorAsk /
/// resolveDirectorApproval）由宿主 controller 薄委托转发。
class DirectorRoundRunner {
  DirectorRoundRunner({required DirectorHost host}) : _host = host;

  final DirectorHost _host;

  /// spawn 同任务书防重——会话级「最近一次成功
  /// 交付」单槽 memo，同 brief 二次派发直接回执上次结论不真跑
  ///（spawn 豁免 doom 检测，此前同 brief 反复派发每次白烧 6 步子代理）。
  final SubagentBriefMemo _spawnBriefMemo = SubagentBriefMemo();

  ///  批3：直播文本/思考增量 32ms 合帧——chat/故事侧
  ///  合帧后，导演直播是最后一个按网络 delta 节奏逐次 state 通知的
  /// 流式面。合帧保持块边界语义（段间经 AgentLiveTranscript 分段规则），
  /// 每个 flush 只做一次 state 替换。非 delta 事件到达时先冲刷保序
  ///（见 [_onAgentEvent] 顶部与 [_onToolArgDelta] / `collectRound` 入口）。
  late final AgentLiveDeltaCoalescer _liveDeltas = AgentLiveDeltaCoalescer(
    (runs) => state = state.copyWith(
      liveBlocks: applyLiveDeltaRuns(state.liveBlocks, runs),
    ),
  );

  /// finish_round 参数流（正文最大
  /// 流）的 state 写入并入 32ms 合帧——此前逐 arg delta 全列表重建+整页
  /// 通知，是  合帧后最后一个按网络节奏逐次通知的流式面。提取器仍逐
  /// delta 喂入（纯计算），只有 liveBlocks 替换走合帧；早折叠判定挪到
  /// flush 时做（幂等：折叠后候选块变占位行，重复判定恒不命中）。
  late final AgentLiveDeltaCoalescer _proseLiveDeltas =
      AgentLiveDeltaCoalescer((runs) {
    final extractor = _activeProseExtractor;
    if (extractor == null) return;
    state = state.copyWith(
      liveBlocks: applyLiveDeltaRuns(
        AgentProseDedup.earlyFold(
          state.liveBlocks,
          extractor.buffer,
          t.advanced.draftMergedPlaceholder,
          streamingStepIndex: _currentStepIndex,
        ),
        runs,
      ),
    );
  });

  /// 当前参数流提取器（finish_round 终态工具一轮仅一个；flush 回调用）
  AgentProseExtractor? _activeProseExtractor;

  // ── 宿主桥接（保持迁出代码的名字与形状，仅换访问路径）────────────────

  AdvancedChatState get state => _host.storyState;
  set state(AdvancedChatState value) => _host.storyState = value;

  Logger get _logger => _host.logger;
  LlmService get _llmService => _host.llmService;
  ExperienceRepository get _experienceRepository => _host.experienceRepository;

  FactualRepository? get _factualRepository => _host.factualRepository;
  StoryCompactionService? get _compactionService => _host.compactionService;

  // ── 导演私有态（原 controller 字段迁入）──────────────────────────────

  /// agent loop 的取消令牌（宿主 cancel() 桥接 [cancelRound]）
  AgentCancellationToken? _cancellation;

  bool _isGenerating = false;
  bool get isGenerating => _isGenerating;

  ///  残留：导演侧压缩 LLM 调用的取消通道。
  /// 与 [_cancellation]（agent 循环，Domain 层）解耦——StoryCompactionService
  /// 消费 Core 的 [CancellationToken]；cancelRound 同步取消两者，用户点停止
  /// 后轮前/溢出自愈压缩不再跑到自然结束白烧 token。
  CancellationToken? _compactionToken;

  /// HITL completer 组（ask_user / 监督审批）
  Completer<String?>? _askCompleter;
  Completer<AgentApprovalVerdict>? _approvalCompleter;

  /// 挂起审批对应的工具名（「本会话总是允许」的记忆写入依据）
  String? _pendingApprovalToolName;

  /// 挂起审批的变更条数（durable 留痕「批准 N 处变更」用）
  int _pendingApprovalChangeCount = 0;

  /// 本会话审批放行记忆（「本会话总是允许」）：命中的 ask 态工具在
  /// approvalRequiredFor 直接放行并留痕 L2。随 runner 实例更换而清空
  ///（一 runner 一会话），设置面板可手动清除。
  final Set<String> _sessionApprovalAllows = {};

  /// 当前生效的本会话放行工具数（设置面板展示/反馈用）
  int get sessionApprovalAllowCount => _sessionApprovalAllows.length;

  /// 清除本会话审批放行（设置面板入口）；返回清除前生效的工具数
  int clearSessionApprovalAllows() {
    final count = _sessionApprovalAllows.length;
    _sessionApprovalAllows.clear();
    return count;
  }

  /// 内置 skill 资产缓存（会话内恒定，首次 agent 轮加载后复用）
  List<AgentSkill>? _skillCache;
  late AssetSkillLoader _skillLoader;

  /// 本会话上次落库的冻结前缀（：会话首次或变更时才写 system/frozen，
  /// 防每轮重复追加；会话切换随 runner 实例更换而重置）
  String? _lastLoggedFrozenPrefix;

  /// 事件清理删掉了 systemFrozen 行时重置补写备忘。
  /// frozen 在 turn N 变更后 stamp 的是 N；重生成更早轮时该行落在
  /// deleteTurnEvents 的删除区间内被删，而 [_lastLoggedFrozenPrefix]
  /// 仍等于当前前缀 → 下轮跳过补写，投影从此用旧前缀与真实请求分叉。
  void invalidateFrozenPrefixMemo() => _lastLoggedFrozenPrefix = null;

  /// 当前轮的活动 durable sink（：子代理事件中继的惰性解析目标；
  /// 工具装配在其创建之前完成，构造期拿不到引用故经字段晚绑定）
  DurableAgentEventSink? _activeDurableSink;

  /// finish_round 参数流提取器（按 toolCallId 一实例；每轮 runRound 重置，
  /// 防跨轮残留——正文交付契约 §4.3）
  final Map<(int, String), AgentProseExtractor> _proseExtractors = {};

  /// 最近一次轮草稿（失败轮的写工具累积/一次性豁免标记暂存，真续跑
  /// 复用；每次 runRound 开头刷新，新一轮自然覆盖旧残留）
  AgentRoundDraft? _lastRoundDraft;

  /// 当前生成尝试身份（runRound 开头写定；persist 写绑定留痕时读取）
  String? _currentAttemptId;

  /// 当前（或最近一次）生成尝试的轨迹身份
  String? get currentAttemptId => _currentAttemptId;

  /// 失败轮草稿读取（真续跑上下文构建用；turnNumber 不匹配返回 null）
  AgentRoundDraft? resumableDraftFor(int turnNumber) =>
      _lastRoundDraft != null && _lastRoundDraft!.turnNumber == turnNumber
          ? _lastRoundDraft
          : null;

  /// 当前 step 的 0 基序号（AgentStepStarted 追踪）
  ///
  /// 工具执行事件不带 stepIndex，且 AgentToolCallReceived 用的是自增后的
  /// 1 基序号——时间线归并键必须与直播增量（0 基）同口径，故从
  /// AgentStepStarted 盖章（工具执行总发生在下一个 StepStarted 之前）。
  int _currentStepIndex = 0;
  int _nextTimelineOrder = 0;
  (bool, int, AgentTextSource)? _contentKey;
  int? _contentOrder;

  final Map<(int, String), int> _proseOrders = {};

  int _orderForProse(String callId) {
    final id = (_currentStepIndex, callId);
    final key = (false, _currentStepIndex, AgentTextSource.finishRoundProse);
    if (_contentKey != key || _contentOrder != _proseOrders[id]) {
      _liveDeltas.flush();
      _proseLiveDeltas.flush();
      _contentKey = key;
      _contentOrder = _proseOrders.putIfAbsent(id, () => _nextTimelineOrder++);
    }
    return _contentOrder!;
  }

  int _orderForContent(bool thinking, int stepIndex) {
    final key = (thinking, stepIndex, AgentTextSource.assistant);
    if (_contentKey != key) {
      _liveDeltas.flush();
      _proseLiveDeltas.flush();
      _contentKey = key;
      _contentOrder = _nextTimelineOrder++;
    }
    return _contentOrder!;
  }

  /// 本轮运行旋钮（预算/HITL/doom-loop/子代理；runRound 开头按入参刷新，
  /// 重试路径不传则沿用上一轮——导演设置）
  DirectorRoundTuning _tuning =
      DirectorRoundTuning.fromConfig(const AdvancedConfig());

  /// 导演模式一轮：agent 自主执行，产出写回 [round] 后复用故事持久化。
  ///
  /// [resume] 非空时为真续跑：surface 用投影重建序列（跳过重新装配与
  /// 补账——bootstrap 已在日志中）、跳过轮前压缩、复用上次尝试草稿、
  /// 直播时间线与步骤保留续号；预算携带前序尝试消耗执法。
  Future<void> runRound(
    RoundContext round, {
    DirectorRoundTuning? tuning,
    DirectorResumeContext? resume,
  }) async {
    if (_host.isStreamCancelled || _host.currentRound != round) return;
    if (tuning != null) _tuning = tuning;

    final factual = _factualRepository;
    if (factual == null) {
      await _host.failRound(
        IntermediatePhase.generating,
        'E010',
        errorCategory: ErrorCategory.config,
      );
      return;
    }

    final sessionId = state.session.sessionId;
    final naming = round.generatingNamingConfig;
    // 续跑复用上次尝试草稿（turnNumber 防御性校验，不匹配回退新建——
    // 调用方构建上下文时已校验，此处兜底不炸主链路）
    final reuseDraft =
        resume != null && resume.draft.turnNumber == round.turnNumber;
    if (resume != null && !reuseDraft) {
      _logger.warn(
        'Director resume draft turn mismatch, starting fresh draft',
        detail: 'draftTurn=${resume.draft.turnNumber}, '
            'roundTurn=${round.turnNumber}',
      );
    }
    final draft = reuseDraft
        ? resume.draft
        : AgentRoundDraft(turnNumber: round.turnNumber);
    _lastRoundDraft = draft;

    final cancellation = AgentCancellationToken();
    _cancellation = cancellation;
    final compactionToken = CancellationToken();
    _compactionToken = compactionToken;
    // 生成尝试身份（不可变，一次写定）：续跑续接上次尝试的 attemptId
    //（同 attempt 续）；全新轮/重生成各得新身份。绑定留痕与变体切换的
    // 身份核对消费它。
    final attemptId = resume?.attemptId ??
        'att_${round.turnNumber}_${DateTime.now().millisecondsSinceEpoch}';
    _currentAttemptId = attemptId;

    var committed = false;
    var deliveryChannel = 'tool_args';

    // finish_round / 通道收割统一走这里：把草稿写回 round，不落库
    Future<String> collectRound(AgentRoundDraft d) async {
      //  批3：收割前冲刷合帧段——pickReplyBlock 必须看到全部已到文本
      _liveDeltas.flush();
      _proseLiveDeltas.flush();
      // 提交不变量（契约 §5.1）：永不提交空 prose。守卫已拦空参、④ 只在
      // pickReplyBlock 达标时调用——走到这里仍空属于结构性 bug，宁可炸出
      // 也不落一空章。
      final picked = AgentLiveTranscript.pickReplyBlock(
        explicitReply: d.explicitReply,
        blocks: state.liveBlocks,
      );
      if (picked == null) {
        throw StateError('collectRound 不变量被破坏：无可交付正文');
      }
      committed = true;
      final reply = picked.text;
      round
        ..replyText = reply
        ..generatedText = reply;
      final thinking = AgentLiveTranscript.joinedThinking(state.liveBlocks);
      round.thinkingContent = thinking.isEmpty ? null : thinking;
      // 轮时间线装配（对话流  + 契约 §5.2）：收割与升格同源同位——
      // pickReplyBlock 采信哪块，哪块升格稿件位不进时间线；explicitReply
      // 交付时 promotedIndex 为 null，全部自由文本进播报。
      // 装配态同源跑 L3 终局折叠（§6.2；直播态已折叠的块天然不再命中，
      // 此处兜住权威替换后新到的 content 近拷贝）——过滤结果回写 liveBlocks，
      // 稿件卡与时间线终局一致
      final foldedBlocks = AgentProseDedup.finalFold(
        reply,
        state.liveBlocks,
        t.advanced.draftMergedPlaceholder,
      );
      state = state.copyWith(liveBlocks: foldedBlocks);
      state = state.copyWith(
        agentTimeline: AgentTimelineAssembler.assemble(
          liveBlocks: foldedBlocks,
          agentSteps: state.agentSteps,
          promotedIndex: picked.promotedIndex,
        ),
      );
      final anchorNarrativeTime = d.storyAnchor?.narrativeTime?.trim();
      final baseEventSummary = d.eventSummary ??
          EventSummary(
            importance: 3,
            tags: const [],
            turnNumber: round.turnNumber,
            what: reply.length > 120 ? reply.substring(0, 120) : reply,
          );
      final eventNarrativeTime = baseEventSummary.narrativeTime?.trim();
      final resolvedEventSummary =
          (eventNarrativeTime == null || eventNarrativeTime.isEmpty) &&
                  anchorNarrativeTime != null &&
                  anchorNarrativeTime.isNotEmpty
              ? EventSummary(
                  importance: baseEventSummary.importance,
                  tags: baseEventSummary.tags,
                  turnNumber: baseEventSummary.turnNumber,
                  eventEnded: baseEventSummary.eventEnded,
                  summary: baseEventSummary.summary,
                  when: baseEventSummary.when,
                  where: baseEventSummary.where,
                  who: baseEventSummary.who,
                  what: baseEventSummary.what,
                  significance: baseEventSummary.significance,
                  extra: baseEventSummary.extra,
                  narrativeTime: anchorNarrativeTime,
                )
              : baseEventSummary;
      round
        ..eventSummary = resolvedEventSummary
        ..factsDeltas = await _filterBaseDriftedDeltas(d)
        ..scoredMemories = d.retrievedMemories
            .map(
              (m) => ScoredMemory(
                memory: m,
                fts5Score: 0,
                vectorScore: 0,
                temporalScore: 0,
                finalScore: 0,
              ),
            )
            .toList()
        ..retrievedFacts = FactRetrievalResult(
          factBlock: '',
          facts: List.of(d.retrievedFacts),
        );
      // 剧情锚继承：本轮未 update_story_anchor 时沿用会话当前锚
      // （Recap 卡每轮显示"当前锚"快照；会话从未设锚则保持 null 不显示）
      state = state.copyWith(
        agentStoryAnchor: d.storyAnchor ?? state.session.storyAnchor,
      );
      // 自然收尾兜底的文风 lint：无反馈通道，只留日志告警。
      // 违规数同样留痕（自然收尾轮的漂移信号与 finish_round 轮同口径）
      final lintReport = const AgentStyleLint().lint(reply);
      d.styleLintHits = lintReport.violations.length;
      if (!lintReport.isClean) {
        _logger.warn(
          'Director natural-finish style lint',
          detail: '${lintReport.violations.length} violations (not blocking)',
        );
      }
      return reply;
    }

    Future<List<ExperientialMemory>> loadLatestMacros() async {
      final recent = await _experienceRepository.getRecentExperiences(
        sessionId,
        limit: 20,
      );
      return recent.where((m) => m.isMacro).take(3).toList();
    }

    _logger.info(
      'Director round start',
      detail: 'model=${naming.modelId} protocol=${naming.protocol.name} '
          'mode=${state.session.mode} '
          'sessionGen=${state.session.phaseModels.generatingModelId}',
    );

    // ② 端点 + 预算（先于工具装配：spawnToolFactory 需要 endpoint）
    final endpoint = AgentModelEndpoint(
      baseUrl: naming.baseUrl,
      apiKey: naming.apiKey,
      modelId: naming.modelId,
      protocol: naming.protocol.name,
      providerOptions: naming.providerOptions,
      maxOutputTokens: naming.maxOutputTokens,
    );
    final baseMaxSteps =
        state.session.effectiveMaxSteps(_tuning.defaultMaxSteps);
    final initialMaxSteps = resume != null &&
            draft.phase == AgentRoundPhase.maintenance &&
            baseMaxSteps > 0
        ? baseMaxSteps + _tuning.maintenanceExtraSteps
        : baseMaxSteps;
    final budget = AgentBudget(
      //  三口径统一：会话列 > 全局当前值，读取走 effectiveMaxSteps
      //（与设置面板回显同一 getter）
      maxSteps: initialMaxSteps,
      // 成本预算（语义改名：累计消耗口径）
      maxTotalTokens: (round.contextWindow * _tuning.tokenBudgetRatio).round(),
      //  余量守卫：窗口 85% 触发线由 runner 计算，上下文装爆前软着陆
      contextWindowTokens: round.contextWindow,
      //  修复（2026-08-29 审查）：会话列 max_duration_minutes 优先——
      // 此前只读全局 advanced.budget.max_duration_minutes，会话面板的
      // 「单轮时间预算」写入后被静默忽略
      maxDuration: Duration(
        minutes: state.session.maxDurationMinutes ?? _tuning.maxDurationMinutes,
      ),
      maxRequestRetries: _tuning.maxRequestRetries,
    );

    // ── / 预备：压缩判定素材 + skill 加载 + core blocks ──────────
    // 项目规则三级回退：会话/全局值已由 resolveAdvancedSettings 合并进
    // settings.systemPrompt，此处仅空串回退内置编辑部规则（导演设置）。
    final rulesPrompt = round.settings.systemPrompt.isNotEmpty
        ? round.settings.systemPrompt
        : AgentSystemPromptBuilder.defaultRulesPrompt;
    final skills = await _ensureDirectorSkills();
    // core blocks 装配抽至共享服务（assembleDirectorCoreBlocks），
    // 注入面与场记板视图同源；失败返回 null 由下方各用点自行降级。
    // 续跑跳过：投影 surface 已含上次的 core 块；世界状态未变——
    // 事实层仅在 persist 落库，失败轮没有 persist。
    final coreBlocksData = resume == null
        ? await assembleDirectorCoreBlocks(
            factual: factual,
            experienceRepository: _experienceRepository,
            sessionId: sessionId,
            factualConfig: round.config.memory.factual,
            narrativeTime: state.session.currentNarrativeTime,
            anchor: state.session.storyAnchor,
            currentTurn: round.turnNumber,
            recentActiveEntitiesWindow: _tuning.recentActiveEntitiesWindow,
            recentActiveEntitiesCap: _tuning.recentActiveEntitiesCap,
            logger: _logger,
          )
        : null;
    final coreBlocks = coreBlocksData?.text;

    // ── // 跨轮素材：会话 artifacts（工作痕迹/风格漂移/维护周期
    // 统计；压缩不改 artifacts，此处一次加载全程复用）──
    final sessionArtifacts = await _host.loadSessionArtifacts(sessionId);
    if (_host.isStreamCancelled || _host.currentRound != round) return;

    final maintenanceSchedule = computeMaintenanceSchedule(
      artifacts: sessionArtifacts,
      currentTurn: round.turnNumber,
      maintenanceGapInterval: _tuning.maintenanceGapInterval,
      maintenanceNudgeCooldown: _tuning.maintenanceNudgeCooldown,
      majorReviewInterval: _tuning.majorReviewInterval,
    );
    if (resume == null) {
      draft.isMajorReviewRound = maintenanceSchedule.isMajorReviewRound;
    }
    final maintenanceGapLine =
        !draft.isMajorReviewRound && maintenanceSchedule.shouldIssueNudge
            ? maintenanceGapReminderText(
                factsGap: maintenanceSchedule.factsGap,
                anchorGap: maintenanceSchedule.anchorGap,
                eventGap: maintenanceSchedule.eventGap,
                gapInterval: _tuning.maintenanceGapInterval,
              )
            : null;
    final maintenanceNudgeIssued = maintenanceGapLine != null;

    // ── 工具权限求值（导演设置 ，设计文档 §5.2）──
    // 内置默认 allow → 全局 advanced.tools → 会话 tool_permissions 列，
    // 逐工具后写优先。deny → 不注册；ask → 走审批管线（横幅确认）。
    final sessionTools = state.session.sessionToolPermissions;
    ToolPermissionState permFor(String name) => ToolPermissions.effective(
          session: sessionTools,
          global: _tuning.globalTools,
          toolName: name,
        );
    final deniedTools = {
      for (final t in ToolPermissions.allTools)
        if (permFor(t) == ToolPermissionState.deny) t,
    };
    final needsApprovalPipeline = ToolPermissions.allTools.any(
      (t) => !deniedTools.contains(t) && permFor(t) == ToolPermissionState.ask,
    );

    // 工程上下文模式（开启态）标志——工具装配（证据闸门接线）与后续
    // 装配/压缩/trim 分支共用
    final engineeringOpen = round.engineeringContextEnabled;

    final tools = buildAgentTools(
      AgentToolDeps(
        sessionId: sessionId,
        draft: draft,
        factualRepository: factual,
        experienceRepository: _experienceRepository,
        storyReader: DirectorStoryReader(_host),
        latestMacros: loadLatestMacros,
        // ask_user 接线（UI 横幅等待回答）
        userInteraction: _DirectorUserInteractionPort(this),
        enableAskUser: true,
        commitRound: collectRound,
        embedQuery: _host.resolveQueryVector,
        factualConfig: round.config.memory.factual,
        // read_skill 接线 + 完稿 lint（机检兜底层）
        loadSkillBody:
            skills.isEmpty ? null : (name) => _skillLoader.loadBody(name),
        skillNames: [for (final s in skills) s.name],
        styleLint: const AgentStyleLint(),
        // 会话当前锚接线——此前仅测试构造传参，生产
        // 恒 null，update_story_anchor 单字段更新会以空锚为基底静默清空
        // 弧线/伏笔，finish_round 伏笔清点闸门在「本轮未动锚」时也恒空。
        currentAnchor: () => state.session.storyAnchor,
        // 终审闸门 A 的实体匹配素材之一（FinishRoundTool 拿不到 round）
        roundUserInput: () => round.userInput,
        // spawn 子代理接线（P3：research 档复用主工具集的只读工具，
        // 共享 draft——子代理检索命中登记进本轮审计快照；
        // 预算来自 advanced.subagent，导演设置）
        spawnToolFactory: (readOnlyTools) => SpawnTool(
          SubagentRunner(
            gateway: LlmServiceAgentGateway(
              llmService: _llmService,
              capabilitiesOverride: _host.capabilitiesOverride,
            ),
            endpoint: endpoint,
            availableTools: readOnlyTools,
            callConfig: AgentCallConfig(
              connectTimeout: round.connectTimeout,
              readTimeout: round.readTimeout,
              responseStartTimeout: _tuning.responseStartTimeout,
              nonStreamingTimeout: _tuning.nonStreamingTimeout,
            ),
            defaultMaxSteps: _tuning.subagentMaxSteps,
            defaultMaxDuration: _tuning.subagentMaxDuration,
            // 主轮 contextWindow × 比例；0 = 不限
            defaultMaxTotalTokens: _tuning.subagentTokenBudgetRatio > 0
                ? (round.contextWindow * _tuning.subagentTokenBudgetRatio)
                    .round()
                : null,
            // 子代理 doom 阈值与主循环同源（advanced.doom_loop）
            doomLoopThreshold: _tuning.doomLoopThreshold,
            // 子代理事件多播进主会话日志（log-only 中继，投影不动；
            // HAR-09：resolver 收 spawn callId，中继事件盖 subagentCallId）
            externalEventsResolver: (subagentCallId) =>
                _SubagentDurableRelay(this, subagentCallId),
          ),
          //  同任务书防重：memo 会话级存活（每轮重建 SpawnTool 仍命中）
          briefMemo: _spawnBriefMemo,
        ),
        //  零工具轮升级闸门（保留参数兼容）
        zeroMemoryRoundStreak: zeroMemoryRoundStreak(sessionArtifacts),
        // 伏笔定期清点（保留参数兼容）
        foreshadowCheckInterval: _tuning.foreshadowCheckInterval,
        // 大周期轮任务二独立步数预算增量
        maintenanceExtraSteps: _tuning.maintenanceExtraSteps,
        // search_story 的 embedQuery 短超时帽与用户配置同源——
        // 取 max(配置, 15s)：配置更长时不被默认帽截死，配置缺失/过短时
        // 保留  的 15s 循环安全下限
        embedQueryTimeout: () {
          final configuredMs = round.embeddingConfig?.timeoutMs;
          if (configuredMs == null || configuredMs <= 15000) return null;
          return Duration(milliseconds: configuredMs);
        }(),
        // 会话「检索松紧度」快照（NULL = 未物化，工具用内置默认）
        retrievalProfile: state.session.sessionRetrievalProfile,
        // 工程上下文模式（开启态）：证据闸门 + 事件暴露量闸门。
        // 关闭态 null——工具内旧闸门分支完整保留。
        retrievalEvidenceGate: engineeringOpen
            ? (prose) => _checkRetrievalEvidence(
                  prose,
                  _host,
                  draft,
                  round,
                )
            : null,
        eventExposureGate: engineeringOpen
            ? (prose) => _checkEventExposure(
                  prose,
                  draft,
                  round,
                  eventGap: maintenanceSchedule.eventGap,
                )
            : null,
      ),
      deniedTools: deniedTools,
    );

    // ──  压缩接线：导演轮超阈值时压缩旧历史（轮前、随 persist 同事务落库）
    // 续跑跳过：投影 surface 即上次实际发出的消息序列，轮前压缩若已跑
    // 其产出已在其中；重跑会多烧一次 LLM 调用且与投影分叉。
    // 工程上下文模式（开启态）：旧轮前压缩改写 chat_messages 装配，与新
    // 模式「出站=账本投影」结构性冲突——停用；新压缩事务由压缩工作包
    // 落地（触发线/溢出/手动届时全部走账本事务）。
    if (resume == null) {
      if (engineeringOpen) {
        await _runEngineeringCompactionPhase(
          round,
          tools: agentToolsToDefinitions(tools),
        );
      } else {
        await _runDirectorCompactionPhase(round, rulesPrompt);
      }
    }
    if (_host.isStreamCancelled || _host.currentRound != round) return;

    // ──  溢出自愈：轮中 CONTEXT_OVERFLOW 时复用同一压缩服务自救一次 ──
    // 开启态走账本压缩事务（提交后返回新纪元投影——runner 既有「working
    // 重建+requestMessages 替换+flush」逻辑复用；AgentSurfaceReplaced
    // 整面快照发射已由 stepSurfaceSource 分支跳过）。
    final engineeringService = _host.engineeringCompactionService;
    final eventLogForOverflow = _host.agentEventLogRepository;
    // 溢出路径压缩参数同样来自配置段（输出预留用当前协议最终请求面的
    // 有效输出预算——含 providerOptions 末位覆盖；API 未指定时回退配置
    // 保守预留，不冒充实报）
    final overflowTuning = EngineeringCompactionTuning.forDirectorRequest(
      round.config.engineeringCompaction,
      naming: round.generatingNamingConfig,
      settings: round.settings,
    );
    final overflowCompactor = engineeringOpen
        ? (engineeringService == null || eventLogForOverflow == null
            ? null
            : EngineeringOverflowCompactor(
                service: engineeringService,
                eventRepository: eventLogForOverflow,
                sessionId: sessionId,
                contextWindowTokens: round.contextWindow,
                retrievalRatio: round.config.contextBudget.retrievalRatio,
                tuning: overflowTuning,
                cancelToken: compactionToken,
                wireOptions: AgentWireOptions.forProtocolName(
                  round.generatingNamingConfig.protocol.name,
                ),
              ))
        : _compactionService == null
            ? null
            : StoryCompactionOverflowCompactor(
                service: _compactionService!,
                sessionId: sessionId,
                namingConfig: round.summarizeNamingConfig,
                contextWindow: round.contextWindow,
                maxTokens: _outputTokenReserveFor(
                  round.settings.maxTokens,
                  modelMaxOutput: naming.maxOutputTokens,
                ),
                budget: round.config.contextBudget,
                connectTimeout: round.connectTimeout,
                readTimeout: round.readTimeout,
                cancelToken: compactionToken,
                logger: _logger,
              );

    // ── durable 事件日志：live 多播 + 落库（崩溃可重放）──
    // 开启态装配需先落账再投影，创建提前到装配前；关闭态无行为差异
    //（创建无副作用，后续使用位不变）。
    // 来源三元组随 assistant 事件盖戳（跨脑重发时投影层清思考/签名
    // 表示的判定依据）+ 当前轮思考回传判定（同脑但本轮思考关闭也不回传）。
    final eventSource = AgentEventSourceMeta(
      protocol: naming.protocol.name,
      modelId: naming.modelId,
      endpointFingerprint: AgentEventSourceMeta.fingerprintEndpoint(
        naming.baseUrl,
      ),
    );
    final thinkingReplayAllowed = _thinkingReplayAllowedForCurrentRound(
      round: round,
    );
    final liveSink = _AgentEventSink(this);
    final eventLog = _host.agentEventLogRepository;
    final durableSink = eventLog == null
        ? null
        : DurableAgentEventSink(
            repository: eventLog,
            sessionId: sessionId,
            turnNumber: round.turnNumber,
            attemptId: attemptId,
            source: eventSource,
            // 分片最小粒度默认开（200 字符聚合）；全量档配置控制
            fullChunkEvents: _tuning.fullChunkEvents,
            logger: _logger,
          );
    _activeDurableSink = durableSink;
    final sink = durableSink == null
        ? liveSink as AgentEventSink
        : _MulticastAgentEventSink([liveSink, durableSink]);

    // ── ① 组装 surface：冻结前缀（规则+工作法+常驻文风+工具索引+技能目录）
    // → core blocks（断点后可 replace； 实验可挪尾）→ 历史 → 本轮输入 ──
    // 续跑跳过整段重装配：surface 用事件日志投影重建（上次实际发出的
    // 序列，含已完成的步骤与工具结果），bootstrap 补账也随之下移跳过。
    // 工程上下文模式（开启态）：出站=账本纪元窗投影（见下方分支），
    // 本块只共用冻结前缀/尾部指令的计算（bootstrap 落账仍需它们）。
    final List<AgentMessage> surface;
    final List<AgentMessage> tailMessages;
    final List<String> tailKinds;
    final String? driftReminderLine;
    final String? previousTraceLine;
    final String frozenPrefix;
    final int? stablePrefixEndIndex;
    DirectorStepSurfaceSource? stepSurfaceSource;
    // 开启态构成图基线：u_k 之前的纪元窗投影字符（关闭态用 chat 历史 fold）
    int? openHistoryChars;
    if (resume == null) {
      final residentStyleGuide = [
        for (final s in skills)
          if (s.alwaysInject && s.residentBody.isNotEmpty) s.residentBody,
      ].join('\n\n');

      frozenPrefix = const AgentSystemPromptBuilder().buildFrozenPrefix(
        rulesPrompt: rulesPrompt,
        // 工具索引跟随实际注册集（含 read_skill/ask_user/spawn 等条件工具）
        toolNames: [for (final t in tools) t.name],
        residentStyleGuide:
            residentStyleGuide.isEmpty ? null : residentStyleGuide,
        // read_skill 未注册时目录尾句不再指引读取（不空许诺）
        skillCatalog: skills.isEmpty
            ? null
            : AgentSkillRegistry(skills).buildCatalogText(
                readSkillAvailable: tools.any((t) => t.name == 'read_skill'),
              ),
      );
      // 轮尾部指令（剧情节奏档位设计 §5.5）：turn1 开篇角色/能力提示在前，
      // 节奏指令收尾（recency 最优位）。节奏档每轮注入且只在尾部——档位
      // 可中途换，冻结前缀保持档位无关以保前缀缓存（§4.2）。
      //  提升为局部量：尾部面同时传给 surface 组装与轮首补账（落日志）。
      final tailToolNames = {for (final t in tools) t.name};
      final isFirstTurn = round.turnNumber == 1;
      // 开篇角色一次性提示（向导「初始化你的角色」自由描述路径）：
      // 只在 turn1 注入，此后角色由正文与事实层承载。
      final characterInitHint = isFirstTurn
          ? firstTurnCharacterInitHint(state.session.characterInitPrompt)
          : null;
      tailMessages = surfaceTailMessages(
        pacing: state.session.sessionNarrativePacing ?? _tuning.globalPacing,
        isFirstTurn: isFirstTurn,
        // deny 感知尾部文案按实际注册集生成（deny 工具不再被点名）
        toolNames: tailToolNames,
        // 世界状态含导入来源内容时追加资料边界重申
        importedDataPresent: coreBlocksData?.hasImported ?? false,
        characterInitHint: characterInitHint,
        maintenanceGapLine: maintenanceGapLine,
        isMajorReviewRound: draft.isMajorReviewRound,
      );
      //  补账的 kind 与 tailMessages 一一同序（单一事实源在此组装）
      tailKinds = [
        if (characterInitHint != null) AgentInjectedMessageKinds.characterInit,
        if (isFirstTurn && firstTurnCapabilityHint(tailToolNames) != null)
          AgentInjectedMessageKinds.firstTurnHint,
        AgentInjectedMessageKinds.tailContract,
        if (maintenanceGapLine != null)
          AgentInjectedMessageKinds.foreshadowSweep,
        AgentInjectedMessageKinds.styleIronRule,
        AgentInjectedMessageKinds.pacing,
        if (coreBlocksData != null && coreBlocksData.hasImported)
          AgentInjectedMessageKinds.dataBoundaryReassert,
      ];
      //  风格漂移监测：近几轮 lint 多次命中且未重读规范时的一次性告知
      driftReminderLine = styleDriftReminderFor(sessionArtifacts);
      // 上一轮的 round-work 痕迹（本轮装配期注入历史区；artifact 已在
      // 上一轮结束后生成）。同轮仅落一次，随轮尾补账进入日志。
      final previousArtifact = sessionArtifacts[round.turnNumber - 1];
      previousTraceLine =
          previousArtifact == null ? null : roundWorkTraceFor(previousArtifact);
      if (engineeringOpen && eventLog != null && durableSink != null) {
        // ── 开启态：出站=账本纪元窗投影（真源切换）──────────────────
        // 顺序唯一：先取 u_k 之前的历史投影（断点坐标 + 构成图基线）→
        // 轮首补账（frozen 变更/trace/u_k/尾部指令）落账 → 投影出站面。
        // 其后每步出站均由 stepSurfaceSource 重投影（等值守卫兜漂移）。
        final events = await eventLog.readEvents(sessionId);
        final window = DirectorSurfaceV2.epochWindowEvents(events);
        final preProjection = deriveAgentSurface(window);
        final preFrozen = DirectorSurfaceV2.latestFrozenPrefixOf(events);
        final preAssembled = DirectorSurfaceV2.assemble(
          epochWindowMessages: preProjection.messages,
          frozenPrefix: preFrozen,
        );
        // 开启态冻结前缀 = 基线前缀 + 新模式固定工作约定（纪元内稳定；
        // 首开启轮随补账落新 frozen 事件，投影取最新值——关闭态前缀
        // 字节不变）。约定随纪元建立进入，修改走显式变更留痕。
        final openFrozenPrefix = '$frozenPrefix\n$kEngineeringWorkConventions';
        // 快照无变化变更检测（marker 事件链为真源）：相同→单行标记，
        // 变化/首份→全量快照（绝对标注一次写入不可改写）。
        final snapshotDecision = coreBlocks == null
            ? null
            : decideCoreBlocksSnapshot(
                coreBlocks: coreBlocks,
                windowEvents: window,
              );
        final coreBlocksTailOverride = coreBlocks == null
            ? null
            : (snapshotDecision!.unchanged
                ? engineeringCoreBlocksUnchangedLine(
                    turn: round.turnNumber,
                    previousTurn: snapshotDecision.previousTurn ?? 1,
                  )
                : engineeringCoreBlocksSnapshot(
                    turn: round.turnNumber,
                    coreBlocks: coreBlocks,
                  ));
        await _appendRoundBootstrapEvents(
          durableSink,
          engineeringOpen: true,
          turnNumber: round.turnNumber,
          attemptId: attemptId,
          frozenPrefix: openFrozenPrefix,
          coreBlocks: coreBlocks,
          coreBlocksInTail: _tuning.coreBlocksInTail,
          coreBlocksTailOverride: coreBlocksTailOverride,
          userInput: round.userInput,
          tailMessages: tailMessages,
          tailKinds: tailKinds,
          driftReminderLine: driftReminderLine,
          // round-work trace 在新模式退役——真实工作轨迹跨轮在场，
          // 一行摘要反而失真（进入时捕获的旧 trace 属史料原样保留）。
          previousTraceLine: null,
        );
        // 轮首尾料入账标记（变更检测真源）落账
        await durableSink.appendNow(
          roundBootstrapMarkerEvent(
            turn: round.turnNumber,
            attemptId: attemptId,
            coreBlocksDigest:
                coreBlocks == null ? null : coreBlocksDigest(coreBlocks),
            unchanged: snapshotDecision?.unchanged ?? false,
          ),
        );
        stepSurfaceSource = DirectorStepSurfaceSource(
          durableSink: durableSink,
          repository: eventLog,
          sessionId: sessionId,
          currentSource: eventSource,
          thinkingReplayAllowed: thinkingReplayAllowed,
        );
        final step = await stepSurfaceSource.project();
        surface = step.messages;
        // 历史尾断点：u_k 之前最后一个历史表面节点（真实投影坐标，非
        // 正文条数换算）；空历史（首次开启后首轮且无捕获）不适用。
        stablePrefixEndIndex =
            preAssembled.isNotEmpty ? preAssembled.length - 1 : null;
        openHistoryChars = preProjection.messages.fold<int>(
          0,
          (sum, m) => sum + (m.content?.length ?? 0),
        );
      } else {
        final historyMessages = mapHistoryWithWorkTraces(
          history: round.history,
          artifacts: sessionArtifacts,
          compactedTurnBase: state.compactedTurnBase,
        );
        stablePrefixEndIndex = directorStablePrefixEndIndex(
          historyLength: historyMessages.length,
          hasCoreBlocks: coreBlocks != null,
          coreBlocksInTail: _tuning.coreBlocksInTail,
        );
        surface = buildDirectorSurface(
          frozenPrefix: frozenPrefix,
          // 历史映射 + 压缩纪元内各轮在 assistant 正文后插 round-work
          // trace（装配期合成，不落库不进压缩输入；冻结前缀不动。 折叠
          // 锚点：保留边界=压缩基点，纪元内纯追加保跨轮缓存前缀）
          historyMessages: historyMessages,
          coreBlocks: coreBlocks,
          coreBlocksInTail: _tuning.coreBlocksInTail,
          userInput: round.userInput,
          tailMessages: tailMessages,
          driftReminderLine: driftReminderLine,
        );
      }
    } else {
      surface = resume.surface;
      tailMessages = const [];
      tailKinds = const [];
      driftReminderLine = null;
      previousTraceLine = null;
      frozenPrefix = '';
      // 续跑投影无法可靠定位历史尾，跳过历史端缓存断点
      stablePrefixEndIndex = null;
      if (engineeringOpen && eventLog != null && durableSink != null) {
        // 开启态失败续跑：同源出站——每步仍 flush→账本投影→当前来源/
        // 思考策略→完整性/等值守卫，不因 resume 绕回 working-only。
        // 轮首补账不重复（上次尝试的 bootstrap 已在账内，投影即其结果；
        // 重写会造成 u_k 与尾部注入双份）。
        stepSurfaceSource = DirectorStepSurfaceSource(
          durableSink: durableSink,
          repository: eventLog,
          sessionId: sessionId,
          currentSource: eventSource,
          thinkingReplayAllowed: thinkingReplayAllowed,
        );
      }
    }

    // ③ 状态进入"生成/审校"式流式（直播分块时间线，复用 story 的气泡位）
    final stopwatch = Stopwatch()..start();
    // 续跑：步号从上次尝试续起（工具执行事件归并/直播增量同口径）
    _currentStepIndex = resume?.priorSteps ?? 0;
    _contentKey = null;
    _contentOrder = null;
    final priorOrders = [
      if (resume != null) ...[
        for (final block in state.liveBlocks)
          if (block.order != null) block.order!,
        for (final step in state.agentSteps)
          if (step.order != null) step.order!,
        for (final block in state.agentTimeline)
          if (block.order != null) block.order!,
      ],
    ];
    _nextTimelineOrder = priorOrders.isEmpty
        ? 0
        : priorOrders.reduce((a, b) => a > b ? a : b) + 1;

    _proseExtractors.clear();
    _proseOrders.clear();
    _activeProseExtractor = null;
    //  批3：换轮丢弃上一轮残段（不得落进新轮的 liveBlocks）
    _liveDeltas.discardPending();
    _proseLiveDeltas.discardPending();
    if (resume == null) {
      // 上下文构成分段字符数（装配期埋点，四段=系统提示词/场记板/
      // 历史对话/本轮指令——检索记忆走工具结果非前缀段，不单列）。
      // 开启态：历史段取自账本纪元窗投影字符（u_k 之前），系统段取
      // 冻结前缀全文——与出站面同源（构成图不退回 chat 正文 fold）。
      final contextSegmentChars = <String, int>{
        'system': engineeringOpen && frozenPrefix.isNotEmpty
            ? frozenPrefix.length
            : rulesPrompt.length,
        'coreBlocks': coreBlocks?.length ?? 0,
        'history': openHistoryChars ??
            round.history.fold<int>(
              0,
              (sum, m) => sum + (m.content?.length ?? 0),
            ),
        'directive': round.userInput.length +
            tailMessages.fold<int>(
              0,
              (sum, m) => sum + (m.content?.length ?? 0),
            ) +
            (driftReminderLine?.length ?? 0),
      };
      state = state.copyWith(
        phase: IntermediatePhase.reviewing,
        liveBlocks: const [],
        clearAgentSteps: true,
        agentWorkSummary: null,
        agentStoryAnchor: null,
        // 换轮重置重试等待状态
        agentRetryWait: null,
        // 轮中预算进度快照（maxSteps 与 AgentBudget 同源；步号
        // 由 AgentStepStarted 事件推进）——live 标题「第 N/M 步 · 已用 X:XX」
        agentRoundProgress: AgentRoundProgress(
          currentStep: 1,
          maxSteps: budget.maxSteps,
          startedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
        // 随轮刷新构成分段
        contextSegmentChars: contextSegmentChars,
      );
    } else {
      // 续跑：直播时间线/步骤/构成分段保留（新步续号追加），进度从上次
      // 尝试续起；时长重新起算（失败→继续的间隔是用户思考时间）。
      state = state.copyWith(
        phase: IntermediatePhase.reviewing,
        agentRetryWait: null,
        inMaintenancePhase: draft.phase == AgentRoundPhase.maintenance,
        agentRoundProgress: AgentRoundProgress(
          currentStep: resume.priorSteps + 1,
          maxSteps: budget.maxSteps,
          startedAtMs: DateTime.now().millisecondsSinceEpoch,
        ),
      );
    }

    final runner = AgentRunner(
      gateway: LlmServiceAgentGateway(
        llmService: _llmService,
        capabilitiesOverride: _host.capabilitiesOverride,
      ),
    );

    // 语义检查点：每次 LLM 请求前 flush durable 日志（"进模型的必已入日志"）
    // 自愈重试钩子追加 UI 通知（溢出压缩从无声修复到 3s 可见提示，
    // 页面监听 overflowHealedTick 弹 toast）
    final hooks = durableSink == null
        ? AgentRunnerHooks(selfHealRetry: [_notifyOverflowHealed])
        : AgentRunnerHooks(
            request: [
              (config, next) async {
                await durableSink.flush();
                return next();
              },
            ],
            // 溢出自愈重试不重跑 request 瀑布，flush 在此补位
            selfHealRetry: [durableSink.flush, _notifyOverflowHealed],
          );

    // ──  补账：轮首消息入日志（system/frozen 会话首次或变更时、
    // system/core 每轮、初始 user/message）——配合注入事件与轮内
    // assistant/tool 事件，日志从此可重建每步实际发出的消息序列 ──
    // 尾部装配面（coreBlocks 挪尾/工作契约/文风铁律/节奏指令/
    // 漂移提醒）与上一轮 round-work 痕迹一并落日志，投影重建含完整尾部面。
    // 续跑跳过：bootstrap 已在日志中，重写会造成投影里用户消息与
    // 尾部注入出现两遍。开启态已在装配分支内先落账（投影前置条件）。
    if (durableSink != null && resume == null && !engineeringOpen) {
      await _appendRoundBootstrapEvents(
        durableSink,
        engineeringOpen: false,
        turnNumber: round.turnNumber,
        attemptId: attemptId,
        frozenPrefix: frozenPrefix,
        coreBlocks: coreBlocks,
        coreBlocksInTail: _tuning.coreBlocksInTail,
        userInput: round.userInput,
        tailMessages: tailMessages,
        tailKinds: tailKinds,
        driftReminderLine: driftReminderLine,
        previousTraceLine: previousTraceLine,
      );
    }

    AgentTurnResult? result;
    var cancelledDuringRun = false;
    _isGenerating = true;
    try {
      result = await runner.runTurn(
        AgentTurnSpec(
          sessionId: sessionId,
          surface: surface,
          tools: tools,
          endpoint: endpoint,
          budget: budget,
          events: sink,
          cancellation: cancellation,
          hooks: hooks,
          // 续跑种子：上次尝试的步数/token 消耗并入预算执法（步号续起）
          resumeSeed: resume == null
              ? null
              : AgentResumeSeed(
                  initialSteps: resume.priorSteps,
                  priorTotalTokens: resume.priorTotalTokens,
                ),
          stablePrefixEndIndex: stablePrefixEndIndex,
          // 工程上下文模式（开启态）：每步出站消息的账本投影源（出站
          // 唯一来源 + 等值守卫）；关闭态为 null，走既有 preStep 路径。
          stepSurfaceSource: stepSurfaceSource,
          //  工具三态权限：任一注册工具为 ask 态即装审批管线；
          // 逐工具审批判定交给 approvalRequiredFor（ask 态才拦，
          // allow 直过；deny 已不注册）。旧 watchMode 布尔不再读取。
          //  无条件装管线以携带输出预算与单工具超时
          // （advanced.harness.*）；无 ask 态工具时审批 seam 不会被触发。
          watchMode: needsApprovalPipeline,
          // 被 deny 的工具名单——未知工具信封区分「禁用/不存在」
          deniedTools: deniedTools,
          pipeline: AgentToolPipeline(
            approvalSeam: needsApprovalPipeline
                ? _DirectorApprovalSeam(this)
                : const UnattendedApprovalSeam(),
            toolOutputLimit: _tuning.toolOutputLimit,
            executionTimeout: _tuning.toolTimeout,
            logger: _logger,
          ),
          approvalRequiredFor: (tool) {
            if (permFor(tool.name) != ToolPermissionState.ask) return false;
            // 会话级放行命中——直接放行并留痕 L2（每次调用一条，
            // 审计面与逐次审批等价）
            if (_sessionApprovalAllows.contains(tool.name)) {
              _appendTraceStep(
                t.advanced.approval.sessionAllowTrace(
                  tool: stageVerbOf(tool.name, t),
                ),
              );
              return false;
            }
            return true;
          },
          // 尾部执笔重述（≥3 步且全程未出现 finish_round 调用时注入
          // 一次文风铁律 + prose 交付锚定）
          penReminderText: kDefaultPenReminderText,
          // doom-loop 阈值来自 advanced.doom_loop.threshold（导演设置 ，
          // 原硬编码 DoomLoopDetector 默认 3）
          doomLoopDetector:
              DoomLoopDetector(threshold: _tuning.doomLoopThreshold),
          // 工具进度桥接——更新 running 步骤的展示文本（"正在检索…"）
          onToolProgress: _updateRunningStepProgress,
          // 正文交付契约 §4.3：finish_round 参数流直播（prose 提取器 →
          // liveBlocks，稿件卡/滚动/时间线零改动）
          onToolArgDelta: _onToolArgDelta,
          // 上下文超限自愈（压缩器为 null 时不自愈，维持原错误路径）
          overflowCompactor: overflowCompactor,
          // +缺陷修复（2026-08-27 导演设置）：生成参数统一取合并后的
          // round.settings（会话列 > advanced.generation），不再直读会话列把
          // null 透传给 LLM（API 默认静默偏离全局配置）。
          // 修复（2026-08-29 审查）：双惩罚与思考档位一并进请求——
          // 此前 UI 可配但 AgentCallConfig 不带，参数从未发送。
          callConfig: AgentCallConfig(
            temperature: round.settings.temperature,
            topP: round.settings.topP,
            maxTokens: round.settings.maxTokens,
            presencePenalty: round.settings.presencePenalty,
            frequencyPenalty: round.settings.frequencyPenalty,
            reasoningEffort: round.settings.reasoningEffort,
            connectTimeout: round.connectTimeout,
            readTimeout: round.readTimeout,
            responseStartTimeout: _tuning.responseStartTimeout,
            nonStreamingTimeout: _tuning.nonStreamingTimeout,
          ),
        ),
      );
    } on AgentCancelledException {
      _cancelPendingDirectorHITL();
      await durableSink?.flush();
      cancelledDuringRun = true;
    } finally {
      _isGenerating = false;
      // 轮结束（含失败路径）：缓冲事件全部落库
      await durableSink?.flush();
      _activeDurableSink = null;
    }

    final hasLockedMaintenanceProse =
        draft.phase == AgentRoundPhase.maintenance &&
            (draft.explicitReply?.trim().isNotEmpty ?? false);
    final cancelledInMaintenance =
        (cancelledDuringRun || result?.reason == AgentStopReason.cancelled) &&
            hasLockedMaintenanceProse;

    if (cancelledDuringRun && !cancelledInMaintenance) {
      return;
    }

    if (cancelledInMaintenance && !committed) {
      final normalizedSteps = AgentWorkStep.normalizeTerminal(state.agentSteps);
      if (!identical(normalizedSteps, state.agentSteps)) {
        state = state.copyWith(agentSteps: normalizedSteps);
      }
      await collectRound(draft);
    }

    // ④ 正文交付判定（契约 §2.2/§5.2：从"停止原因"解耦为"有无可交付正文"）
    //
    // committed（通道 A/D）照常落库；非 cancelled 未提交时收割通道 B/C：
    // explicitReply（工具已收到但提交未成）> 最后一个 ≥200 字文本块；
    // 自然停止（completed）另许最后一个非空文本块（短正文也是交付）。
    // 预算耗尽（duration/tokens/maxSteps 二次）、doom、error 尾巴只要
    // 任何通道有正文即拾取——"已交付正文不得蒸发"。
    if (!committed &&
        result != null &&
        result.reason != AgentStopReason.cancelled) {
      final picked = AgentLiveTranscript.pickReplyBlock(
        explicitReply: draft.explicitReply,
        blocks: state.liveBlocks,
        allowShortText: result.reason == AgentStopReason.completed,
      );
      if (picked != null) {
        if (picked.promotedIndex case final index?) {
          state = state.copyWith(
            liveBlocks:
                AgentLiveTranscript.confirmFallback(state.liveBlocks, index),
          );
        }
        draft.explicitReply = picked.text;
        if (draft.phase != AgentRoundPhase.maintenance) {
          deliveryChannel = 'text_fallback';
        }
        await collectRound(draft);
        if (draft.phase != AgentRoundPhase.maintenance) {
          _appendTraceStep(t.advanced.textFallbackCollected);
          _logger.info(
            'Director prose salvaged via text fallback',
            detail: 'reason=${result.reason.name}, '
                'length=${picked.text.length}',
          );
        }
      }
    }

    // ⑤ 有可提交正文则复用故事模式持久化；否则把失败原因接出来
    if (round.replyText == null || round.replyText!.isEmpty) {
      final nonNullResult = result!;
      // 取消：cancel() 已同步清理临时态，此处仅防御性回 idle，不判失败。
      // 停止保留半截正文路径 cancel()/后台中断已刻意置 failed(user_stopped)
      // ——防御性 idle 不覆写该终态，否则失败栏瞬态闪失、「从中断处继续」
      // 入口被吞。
      if (nonNullResult.reason == AgentStopReason.cancelled) {
        if (state.phase != IntermediatePhase.failed) {
          state = state.copyWith(phase: IntermediatePhase.idle);
        }
        return;
      }
      // 致命工具异常（embedding 失败，fallback=false）→ E104。
      // 此前 SearchStoryTool 的 catchError 把它吞成静默 FTS 检索，E104 与
      // 「临时降级继续」（continueWithFts5Only）在导演侧永不可达。
      final turnError = nonNullResult.error;
      final isEmbeddingFailure = turnError is EmbeddingCallFailedException ||
          turnError is EmbeddingRateLimitedException;
      if (turnError != null && isEmbeddingFailure) {
        // DD2：本轮确实中断 → 肇事步骤转红（可恢复失败仍是黄色）。
        _escalateInterruptedStepToError();
        const classifier = StoryFailureClassifier();
        final classified = classifier.classifyError(turnError);
        state = state.copyWith(
          phase: IntermediatePhase.failed,
          failureContext: FailureContext(
            errorCode: 'E104',
            failedPhase: IntermediatePhase.retrieving,
            errorMessage:
                classifier.resolveFailureMessage('E104', classified.category),
            retryable: true,
            errorCategory: classified.category,
            httpStatus: classified.httpStatus,
            rawError: turnError.toString(),
          ),
        );
        return;
      }
      // 2026-08-17 修复：「completed 但正文为空」同样进 failed。弱模型在
      // 工具失败信封后返回空响应/弃疗时，此前静默回 idle 导致整轮无声消失，
      // 无失败横幅也无重试入口（用户消息仍是 pending 气泡，操作按钮为空回调）。
      // 审查收官 ：溢出停轮（网关/runner 的 abort 文案）识别为
      // contextOverflow 类别——专属横幅文案与「立即压缩」建议在导演路可达
      final isOverflowStop = nonNullResult.errorMessage != null &&
          isContextOverflowText(nonNullResult.errorMessage!, null);
      // 失败分类走共享分类器：此前硬编码 unknown，400 请求被拒也显示
      // 「未知 / 请重试」，而重发同一载荷必然再失败。AgentLlmException 的
      // BAD_REQUEST/400 → request（确定性请求错误，不提供盲目重试语义）。
      const classifier = StoryFailureClassifier();
      final classified =
          turnError != null ? classifier.classifyError(turnError) : null;
      final category = isOverflowStop
          ? ErrorCategory.contextOverflow
          : classified?.category ?? ErrorCategory.unknown;
      final requestRejected = category == ErrorCategory.request;
      // DD2：本轮确实中断（零产出/停轮）→ 肇事步骤转红。
      _escalateInterruptedStepToError();
      state = state.copyWith(
        phase: IntermediatePhase.failed,
        failureContext: FailureContext(
          errorCode: 'EAGENT',
          failedPhase: IntermediatePhase.generating,
          errorMessage: isOverflowStop
              ? t.advanced.failure.contextOverflow
              : _agentStopMessage(nonNullResult),
          retryable: !requestRejected,
          errorCategory: category,
          httpStatus: classified?.httpStatus,
          rawError: nonNullResult.errorMessage,
        ),
      );
      return;
    }
    stopwatch.stop();
    final usage = result?.usage;
    state = state.copyWith(
      agentWorkSummary: AgentWorkSummary(
        // result.steps 已含续跑种子；token/时长在此并入前序尝试——
        // 轮摘要口径=整轮总消耗，与事件日志各段相加一致
        steps: result?.steps ?? state.agentSteps.length,
        totalTokens:
            (usage?.totalTokens ?? 0) + (resume?.priorTotalTokens ?? 0),
        durationMs:
            stopwatch.elapsedMilliseconds + (resume?.priorDurationMs ?? 0),
        deliveryChannel: deliveryChannel,
        // 上下文用量指示 §3.1：最后一次请求分项随 summary 落库。
        // 0 → null（端点未回 usage 时累计器留 0）：null 才能走「—」/
        // 空环展示并放行旧会话回填探针，0 会伪装成「真实为 0」
        lastPromptTokens:
            usage == null ? null : positiveOrNullOrNull(usage.lastPromptTokens),
        // 完整输入面（命中率分母；协议适配器已归一，0/缺省 → null）
        lastInputTokens: usage == null
            ? null
            : positiveOrNullOrNull(usage.lastCompleteInputTokens),
        lastCompletionTokens: usage == null
            ? null
            : positiveOrNullOrNull(usage.lastCompletionTokens),
        // 端点显式上报的 0 是有效样本（冷请求），不能按「未上报」抹成 null
        lastCacheReadTokens: usage?.lastCacheReadTokens != null &&
                usage!.lastCacheReadTokens! >= 0
            ? usage.lastCacheReadTokens
            : null,
        // 仅最后一次主请求自身的异常（整轮累计的 warnings 仍随 turn/end
        // 诊断持久化）：早先步骤/子代理异常不得把合法末次样本拖成未知
        usageWarnings: usage?.lastRequestWarnings ?? const [],
        //  风格漂移监测：本轮完稿 lint 终值留痕（null=本轮未过 lint）
        styleLintHits: draft.styleLintHits,
        maintenanceNudgeIssued: maintenanceNudgeIssued,
        majorReviewCompleted: draft.maintenanceCompleted ||
            (draft.phase == AgentRoundPhase.maintenance &&
                draft.maintenanceCheckedOrUpdated),
      ),
      // 新轮落地：主数字锚定「下一轮当前可知材料」，而不是本轮最后一次
      // 请求的完整输入。多步工具轮的后续请求会携带临时工作面（工具结果、
      // 工具调用消息），这些材料不会原样进入下一轮；首末输入之差即该
      // 工作面增量，需从锚点中扣除。回复文本由持久化阶段按落库内容追加。
      // 开启态：材料差分在持久化后按最终投影单点闭合——此处
      // 先显式 unknown（persist 窗口 UI 显「—」），不得用 liveBlocks 粗算
      // 预填（较早播报已在末次输入里，再叠加会重复计入）。
      contextEstimate: round.engineeringContextEnabled
          ? const ContextUsageEstimate.unknown()
          : (usage == null
              ? const ContextUsageEstimate.unknown()
              : _nextRoundEstimate(usage)),
    );
    // 锚点表面指纹（材料差分绑定）：锚点=末次主请求实报完整输入 ↔ 该次
    // 发出的消息序列 + 协议/模型指纹（指纹失配显示「—」）
    if (round.engineeringContextEnabled) {
      // 可靠实报锚点（成对快照）：实报输入只与「该次发出的出站面」配对
      // ——lastOutgoing（末次请求面）可能与实报请求错位（末步缺 usage
      // /计量异常），不得直接配对；无可靠配对→unknown（不伪装锚点）。
      final measured = result?.measuredInputAnchor;
      _anchorSurfaceFingerprint = _surfaceFingerprintOf(round);
      _anchorSurfaceMessages = measured?.outgoingMessages ?? const [];
      _anchorSurfaceTokens = measured?.inputTokens;
      // 触发锚点（轮前压缩触发口径）：有可靠配对才更新——本请求无有效
      // 输入实报时保留上一个可靠配对（跨轮缺 usage 的轮不降级也不清空；
      // 指纹失配由触发侧兜住）。触发锚点与闭合锚点分置，闭合的一次性
      // 消费语义不变。
      if (measured != null) {
        _triggerAnchorFingerprint = _surfaceFingerprintOf(round);
        _triggerAnchorMessages = measured.outgoingMessages;
        _triggerAnchorTokens = measured.inputTokens;
      }
    }
    await _host.runPersistPhase(round);
    if (state.inMaintenancePhase || state.maintenanceStepStart != 0) {
      state = state.copyWith(
        inMaintenancePhase: false,
        maintenanceStepStart: 0,
      );
    }
    // 开启态：材料差分持久化后单点闭合（最终投影=真实保留表面，回复/
    // 工具轨迹/绑定一次性并入，persist 侧不再二次 reply shift）。闭合面
    // 与出站面同管线（同一投影源：清不可回传表示剥离+冻结前缀装配，口径同源）。
    if (round.engineeringContextEnabled) {
      await _closeEngineeringMaterialDiff(
        round,
        stepSurfaceSource: stepSurfaceSource,
      );
    }
    // 批 I：轮完成即滚动清理超窗旧轮事件（失败仅记日志，不伤正果）
    await _trimEventLog();
  }

  // ── 材料差分锚点：末次主请求实报完整输入 ↔ 该次
  // 发出的消息序列 + 协议/模型指纹。persist 后按最终投影单点闭合。
  List<AgentMessage> _anchorSurfaceMessages = const [];
  int? _anchorSurfaceTokens;
  String? _anchorSurfaceFingerprint;

  // ── 触发锚点（轮前压缩触发口径）：末次有可靠实报的请求 ↔ 其出站面。
  // 与闭合锚点分置（闭合一次性消费；触发跨轮保留上一个可靠配对）。
  List<AgentMessage> _triggerAnchorMessages = const [];
  int? _triggerAnchorTokens;
  String? _triggerAnchorFingerprint;

  String _surfaceFingerprintOf(RoundContext round) {
    final naming = round.generatingNamingConfig;
    return '${naming.protocol.name}|${naming.modelId}';
  }

  /// 开启态材料差分闭合：预计 = max(0, 可靠完整输入锚点 +
  /// estimate(当前实际表面) − estimate(锚点表面))。两表面同口径
  ///（[surfaceInputChars] wire-map：按当前协议计入实际可回传表示——
  /// 正文/回执/调用签名/协议化思考与签名；剥离后的不可回传表示不在
  /// 投影里自然不计）；压缩/prune/思考清除计入净变化。无可靠锚点或
  /// 指纹失配 → unknown（UI 显「—」）；有数值预计标 ≈（estimated 既有标记）。
  Future<void> _closeEngineeringMaterialDiff(
    RoundContext round, {
    DirectorStepSurfaceSource? stepSurfaceSource,
  }) async {
    final eventLog = _host.agentEventLogRepository;
    final anchor = _anchorSurfaceTokens;
    final anchorMessages = _anchorSurfaceMessages;
    final fingerprint = _anchorSurfaceFingerprint;
    // 释放锚点（本轮闭合一次性消费，不留到下一轮）
    _anchorSurfaceMessages = const [];
    _anchorSurfaceTokens = null;
    _anchorSurfaceFingerprint = null;
    if (eventLog == null) return;
    if (anchor == null || anchor <= 0 || anchorMessages.isEmpty) {
      state = state.copyWith(
        contextEstimate: const ContextUsageEstimate.unknown(),
      );
      return;
    }
    if (_surfaceFingerprintOf(round) != fingerprint) {
      state = state.copyWith(
        contextEstimate: const ContextUsageEstimate.unknown(),
      );
      return;
    }
    try {
      // 闭合面与出站面同管线：同一投影源重投影（清不可回传表示剥离+冻结前缀
      // 装配）——两表面同口径，差分才成立。开启态轮必有
      // 投影源；缺失（异常装配）按 unknown 保守处理。
      if (stepSurfaceSource == null) {
        _logger.warn('Material diff closure skipped: no projection source');
        state = state.copyWith(
          contextEstimate: const ContextUsageEstimate.unknown(),
        );
        return;
      }
      final surface = await stepSurfaceSource.project();
      final tuning = EngineeringCompactionTuning.fromConfig(
        round.config.engineeringCompaction,
      );
      final wireOptions = AgentWireOptions.forProtocolName(
        round.generatingNamingConfig.protocol.name,
      );
      final finalChars = surfaceInputChars(
        surface.messages,
        options: wireOptions,
      );
      final anchorChars = surfaceInputChars(
        anchorMessages,
        options: wireOptions,
      );
      final estimate = math.max(
        0,
        anchor + (finalChars - anchorChars) ~/ tuning.charsPerToken,
      );
      final events = await eventLog.readEvents(state.session.sessionId);
      final window = DirectorSurfaceV2.epochWindowEvents(events);
      final fold = deriveAgentSurfaceSpans(window);
      state = state.copyWith(
        contextEstimate: ContextUsageEstimate.estimated(
          tokens: estimate,
          at: DateTime.now(),
        ),
        // 构成图按最终投影闭合：包含同一修订的工具名/参数/
        // 回执/结构化块与正文，不被 persist 的 newMessages.fold 覆写
        contextSegmentChars: _compositionFromSurface(
          window,
          fold,
          frozenPrefixChars: _frozenPrefixCharsOf(surface.messages),
        ),
      );
    } catch (e) {
      _logger.warn('Material diff closure failed', detail: '$e');
      state = state.copyWith(
        contextEstimate: const ContextUsageEstimate.unknown(),
      );
    }
  }

  /// 构成图分段（开启态，最终投影口径）：按存活 span 的事件分类累计
  /// 完整预算面字符。system=冻结前缀/捕获系统面；coreBlocks=世界事实
  /// 快照注入面；directive=最新轮的 u_k+尾部指令；history=其余（含
  /// 工具轨迹/正文/快照历史轮）。UI 呈现字符占比，非供应商 token 实报。
  Map<String, int> _compositionFromSurface(
    List<AgentDurableEvent> windowEvents,
    AgentSurfaceProjectionWithSpans fold, {
    int frozenPrefixChars = 0,
  }) {
    var latestTurn = 0;
    for (final e in windowEvents) {
      final t = (e.data['turn'] as num?)?.toInt() ?? 0;
      if (t > latestTurn) latestTurn = t;
    }
    final segments = <String, int>{
      // 冻结前缀不进纪元窗投影（assemble 单独前置）——构成图按出站面
      // 口径并入 system 段
      'system': frozenPrefixChars,
      'coreBlocks': 0,
      'history': 0,
      'directive': 0,
    };
    final sorted = [...fold.spans]..sort((a, b) => a.from.compareTo(b.from));
    for (final span in sorted) {
      if (span.from < 0) continue;
      final e = span.event;
      var chars = 0;
      final text = e.data['content'] ?? e.data['output'] ?? e.data['text'];
      if (text is String) chars += text.length;
      final calls = e.data['toolCalls'];
      if (calls is List && calls.isNotEmpty) chars += jsonEncode(calls).length;
      final seg = _segmentOfEvent(e, latestTurn);
      segments[seg] = (segments[seg] ?? 0) + chars;
    }
    return segments;
  }

  int _frozenPrefixCharsOf(List<AgentMessage> messages) {
    if (messages.isEmpty) return 0;
    final first = messages.first;
    return first.role == 'system' ? (first.content?.length ?? 0) : 0;
  }

  String _segmentOfEvent(AgentDurableEvent e, int latestTurn) {
    switch (e.type) {
      case AgentEventTypes.systemFrozen:
        return 'system';
      case AgentEventTypes.systemCore:
        return 'coreBlocks';
      case AgentEventTypes.modeCapture:
        return e.data['as'] == 'system' ? 'system' : 'history';
      case AgentEventTypes.userMessage:
        // 快照注入面归 coreBlocks；最新轮的 u_k+尾部指令归 directive，
        // 更早轮次归 history
        if (e.data['source'] == 'coreBlocksTail') return 'coreBlocks';
        final turn = (e.data['turn'] as num?)?.toInt() ?? 0;
        return turn == latestTurn ? 'directive' : 'history';
      default:
        return 'history';
    }
  }

  /// 下一轮当前可知材料的输入估算。
  ///
  /// 最后一次请求的完整输入包含本轮临时工具工作面（工具结果、工具调用
  /// 消息），这些材料不会原样进入下一轮。首末请求输入之差即该工作面
  /// 增量，扣除后回到本轮起始材料规模；落库回复由持久化阶段追加。
  ContextUsageEstimate _nextRoundEstimate(AgentUsageAccumulator usage) {
    return ContextUsageEstimate.nextRoundFromTurn(
      lastInputTokens: usage.lastCompleteInputTokens,
      firstInputTokens: usage.firstCompleteInputTokens,
      at: DateTime.now(),
    );
  }

  /// 导演会话打开时修复悬挂轮（崩溃/中断的轮补 turn/end{interrupted} +
  /// 未配对工具调用占位，surface 重放不报错）。打开流程已串行，重复
  /// 打开由账本现况判断是否还有待修复的记录。
  ///
  /// [retentionTurns] 由 controller 解析配置后传入——
  /// 冷路径执行时 [_tuning] 尚未经 runRound 刷新，恒为 const 默认（20），
  /// 不透出配置值会把用户配 50/0 的日志按 20 轮裁掉。null 回落默认。
  /// [trimEnabled] 工程上下文模式三态解析为正常开启时传 false——开启态
  /// 事件账本即模型可见真源，任何轮数窗口都不得删除（需要修复态在
  /// 更上游不进本方法）。
  Future<void> recoverEventLogIfNeeded(
    String sessionId, {
    int? retentionTurns,
    bool trimEnabled = true,
  }) async {
    final eventLog = _host.agentEventLogRepository;
    if (eventLog == null) return;
    await AgentLogRecoveryService(
      repository: eventLog,
      logger: _logger,
    ).recover(sessionId);
    // 批 I：会话打开恢复后顺带滚动清理（冷路径，长驻进程不重开的
    // 增长由轮完成钩子兜住）
    if (trimEnabled) {
      await _trimEventLogForSession(sessionId, retentionTurns: retentionTurns);
    }
  }

  /// 批 I：按 advanced.harness.event_log_retention_turns
  /// 滚动清理超窗旧轮事件（0=不限制）。失败仅记日志——清理是卫生动作，
  /// 绝不影响轮结果与恢复流程。冷打开时由控制器传入保留轮数。
  ///
  /// 工程上下文模式（导演实验）：三态解析为正常开启或需要修复时整体
  /// 跳过——开启态事件即模型可见真源；修复态数据保护铁律禁删（不能
  /// 只看最新事件字面，判据来自 loadHistory 的统一对账结果）。
  Future<void> _trimEventLog() async {
    if (state.engineeringMode != EngineeringRuntimeMode.normalClosed) return;
    await _trimEventLogForSession(state.session.sessionId);
  }

  Future<void> _trimEventLogForSession(
    String sessionId, {
    int? retentionTurns,
  }) async {
    final eventLog = _host.agentEventLogRepository;
    if (eventLog == null) return;
    try {
      await eventLog.trimToRecentTurns(
        sessionId,
        retentionTurns ?? _tuning.eventLogRetentionTurns,
      );
    } catch (e) {
      _logger.warn('Event log trim failed (ignored)', detail: '$e');
    }
  }

  /// 滚动清理事件日志（外部收尾入口）——persist-only 续跑等不经
  /// runRound 收尾的出口补用；正常轮完成在 runRound 末尾已带。
  Future<void> trimEventLog() => _trimEventLog();

  /// 取消进行中的导演回合（宿主 cancel() 桥接；无进行中回合时为 no-op）。
  ///
  /// 同时作废挂起的 HITL——ask/approval 挂起时
  /// agent 循环阻塞在 completer.future，令牌取消打不断它；不在此处作废
  /// 的话横幅会在 idle 态悬挂最长 10 分钟，且超时 finally 可能跨轮作废
  /// 新一轮的请示。作废后循环解除阻塞，走进既有的取消收尾路径。
  void cancelRound(String reason, {bool flushPending = true}) {
    if (flushPending) {
      _liveDeltas.flush();
      _proseLiveDeltas.flush();
    }
    discardLiveDeltas();
    _cancellation?.cancel(reason);
    _compactionToken?.cancel();
    _cancelPendingDirectorHITL();
  }

  /// 宿主 dispose 冲刷钩——丢弃未冲刷的直播增量并
  /// 销毁合帧 Timer。
  ///
  /// 控制器销毁后合帧 Timer 到期的 onFlush 会经宿主 storyState 对已
  /// dispose 的 StateNotifier 写 state（debug 断言 StateError），残段写到
  /// 已销毁的宿主也无意义。取「丢弃」而非「冲刷」：与换轮清理（runRound
  /// 开头的 discardPending）同口径；普通取消先冲刷以保留已接收正文，
  /// 销毁路径直接丢弃，避免对已销毁宿主写入。
  void discardLiveDeltas() {
    _liveDeltas.discardPending();
    _proseLiveDeltas.discardPending();
  }

  /// 把 agent 停止原因映射为用户可见的失败提示
  ///
  /// 文案迁入 slang（advanced.agentStop）——
  /// 此前整批硬编码中文，英文版前置的阻塞面。
  String _agentStopMessage(AgentTurnResult result) {
    final s = t.advanced.agentStop;
    switch (result.reason) {
      case AgentStopReason.error:
        return result.errorMessage?.isNotEmpty ?? false
            ? s.error(message: result.errorMessage!)
            : s.errorGeneric;
      case AgentStopReason.maxSteps:
        return s.maxSteps(steps: result.steps);
      case AgentStopReason.budgetTokens:
        return s.budgetTokens;
      case AgentStopReason.budgetDuration:
        return s.budgetDuration;
      case AgentStopReason.doomLoop:
        return s.doomLoop;
      // 余量越限/钩子拒绝此前落 default「本轮未完成」
      // —— 余量守卫是长会话主停止路径，用户需要可行动指引；钩子拒绝
      // 带 runner 留下的 reason
      case AgentStopReason.contextHeadroom:
        return s.contextHeadroom;
      case AgentStopReason.hookRejected:
        return s.hookRejected(
          reason: result.errorMessage ?? result.reason.name,
        );
      case AgentStopReason.completed:
      case AgentStopReason.completedByTool:
        // 走到这里的 completed 一定伴随空正文（见 runRound ⑤）；
        // 优先用 runner 留下的诊断（如长度截断），无则用通用文案
        final message = result.errorMessage;
        if (message != null && message.isNotEmpty) {
          return s.error(message: message);
        }
        return s.completedEmpty;
      case AgentStopReason.cancelled:
        return s.incomplete;
    }
  }

  /// 溢出自愈通知（selfHealRetry 钩子；页面消费 tick 弹 toast）
  Future<void> _notifyOverflowHealed() async {
    state = state.copyWith(
      overflowHealedTick: state.overflowHealedTick + 1,
    );
  }

  // ==================== HITL（体验重构 ：ask_user / 审批）====================

  /// ask_user 挂起：横幅展示问题并等待回答（跳过/超时 → null = 未回答）
  Future<String?> _pendingDirectorAsk(
    String question,
    List<String>? options,
  ) async {
    final completer = Completer<String?>();
    _askCompleter = completer;
    state = state.copyWith(
      agentAskPrompt: AgentAskPrompt(
        question: question,
        options: options ?? const [],
      ),
    );
    try {
      // 安全超时（advanced.hitl.ask_user_timeout_minutes，默认 3 分钟，
      // 导演设置）：超时视同"导演未回答"。
      // 「一直等待」档：配置 0 → tuning 为 null → 不挂 completer.timeout，
      // 一直等待导演回答（对齐 maxSteps 0=无上限语义；审批保持 fail-closed）。
      final timeout = _tuning.askUserTimeout;
      if (timeout == null) {
        return await completer.future;
      }
      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          //  修复：超时不再无声消失——正在阅读的用户
          // 不知道回合已被裁决；追加一步留痕（进 L2 步骤卡与持久化产物）
          _appendTraceStep(t.advanced.hitl.askTimeout);
          //  同族：横幅随 finally 消失，再弹 3s toast 提醒裁决
          state = state.copyWith(
            hitlAskTimeoutTick: state.hitlAskTimeoutTick + 1,
          );
          return null;
        },
      );
    } finally {
      // 身份校验——超时 finally 可能在新轮已发起新
      // 请示后才触发，无条件清空会把新轮的横幅与 completer 一并作废
      if (_askCompleter == completer) {
        _askCompleter = null;
        state = state.copyWith(agentAskPrompt: null);
      }
    }
  }

  /// 回答待决的 ask_user（null = 跳过，模型收到"导演未回答，按你判断继续"）
  void answerDirectorAsk(String? answer) {
    final completer = _askCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(answer);
    }
  }

  /// 监督模式审批挂起：横幅展示写入摘要并等待确认
  Future<AgentApprovalVerdict> _pendingDirectorApproval(
    ToolExecutionRequest request,
  ) async {
    // 2026-10-15 批 B：干跑组装变更明细——在挂 completer **之前**完成
    //（本地 SQLite 毫秒级，不占 fail-closed 倒计时锚点）；任一步异常降级
    // 空明细，审批照常（横幅退化为现状纯摘要）。
    var changes = const <AgentApprovalChange>[];
    final draft = _lastRoundDraft;
    try {
      final repo = _factualRepository;
      if (repo != null) {
        final composer = AgentApprovalComposer(
          repository: repo,
          sessionId: state.session.sessionId,
          draftTurnNumber: draft?.turnNumber ?? 1,
          currentAnchor: state.session.storyAnchor,
          draftAnchor: draft?.storyAnchor,
          draftEventSummary: draft?.eventSummary,
        );
        changes = await composer.compose(request);
      }
    } catch (e) {
      _logger.warn(
        'Approval changes composition failed, falling back to summary',
        detail: 'tool=${request.toolName}, error=$e',
      );
    }

    final completer = Completer<AgentApprovalVerdict>();
    _approvalCompleter = completer;
    _pendingApprovalToolName = request.toolName;
    _pendingApprovalChangeCount = changes.length;
    final summaryData =
        approvalSummaryDataOf(request.toolName, request.arguments);
    state = state.copyWith(
      agentApprovalPrompt: AgentApprovalPrompt(
        toolName: request.toolName,
        summary: formatApprovalSummary(t, request.toolName, summaryData),
        summaryData: summaryData,
        changes: changes,
        pendingPriorChanges: draft?.factsDeltas.length ?? 0,
      ),
    );
    try {
      // fail-closed：超时视同审批通道无响应（默认 5 分钟不变）；
      // P2 ：approval_timeout_enabled 关闭时永不超时——
      // 不挂 .timeout，横幅一直等待用户处置（停止按钮/重启中断/无人值守
      // 三道兜底不变，推翻 2026-08「审批不开放永等档」旧口径）。
      final timeout = _tuning.approvalTimeout;
      if (timeout == null) {
        return await completer.future;
      }
      return await completer.future.timeout(
        timeout,
        onTimeout: () {
          //  修复：同 ask 超时——留痕说明本轮写入为何被拒
          _appendTraceStep(t.advanced.hitl.approvalTimeout);
          // fail-closed 裁决 3s toast（横幅已随 finally 消失）
          state = state.copyWith(
            hitlApprovalTimeoutTick: state.hitlApprovalTimeoutTick + 1,
          );
          // 面向模型的信封消息（进 agent 上下文而非 UI），保持常量
          return const AgentApprovalUnavailable('确认超时未响应（fail-closed）');
        },
      );
    } finally {
      // 身份校验，同 _pendingDirectorAsk
      if (_approvalCompleter == completer) {
        _approvalCompleter = null;
        _pendingApprovalToolName = null;
        state = state.copyWith(agentApprovalPrompt: null);
      }
    }
  }

  /// 提交前基底漂移过滤（审批基底变化检测）
  ///
  /// 暂存（审批预览所见）之后被其他路径改写过的属性，其 update_attr
  /// delta 不静默覆盖：剔除并留痕，其余照常提交。同轮多次暂存同属性
  /// 不误报（轮内暂存不改 DB，提交前基底不变）。
  Future<List<FactsDelta>?> _filterBaseDriftedDeltas(
    AgentRoundDraft draft,
  ) async {
    if (draft.factsDeltas.isEmpty) return null;
    final repo = _factualRepository;
    if (repo == null || draft.factBaseSnapshots.isEmpty) {
      return List.of(draft.factsDeltas);
    }
    final drifted = await UpdateFactsTool.detectFactBaseDrift(
      draft: draft,
      repository: repo,
    );
    if (drifted.isEmpty) return List.of(draft.factsDeltas);

    final kept = <FactsDelta>[];
    final droppedLabels = <String>[];
    for (final delta in draft.factsDeltas) {
      if (delta.action == FactAction.updateAttr &&
          delta.entityId != null &&
          delta.attrKey != null) {
        var hit = false;
        try {
          final entity = await repo.getEntityById(delta.entityId!);
          if (entity != null) {
            final normalized = AttributeSchema.normalizeAttrKey(
              entity.type,
              delta.attrKey!,
            );
            hit = drifted.contains(
              UpdateFactsTool.factBaseKey(delta.entityId!, normalized),
            );
          }
        } catch (_) {
          // 实体读取失败不剔除（与暂存捕获的容错口径一致）
        }
        if (hit) {
          droppedLabels.add(
            '${delta.primaryName ?? delta.entityId}.${delta.attrKey}',
          );
          continue;
        }
      }
      kept.add(delta);
    }
    if (droppedLabels.isNotEmpty) {
      _appendTraceStep(
        t.advanced.approval.baseDriftTrace(items: droppedLabels.join('、')),
      );
    }
    return kept.isEmpty ? null : kept;
  }

  /// 追加一条流程留痕步骤（修复 2026-08-23）
  ///
  /// HITL 超时等"系统裁决"事件此前随横幅一起无声消失；现落进
  /// state.agentSteps——L1 过程行可见、展开 L2 有卡、随 artifacts 持久化。
  /// DD1：同步追加时间线动作块——历史轮优先按 agentTimeline 渲染，
  /// 只在 agentSteps 里追加会让该痕迹在历史轮丢失（正文回退收录的痕迹
  /// 恰恰是在 collectRound 装配之后追加的）。
  void _appendTraceStep(String title) {
    _liveDeltas.flush();
    _proseLiveDeltas.flush();
    _contentKey = null;
    final step = AgentWorkStep(
      toolName: 'system',
      title: title,
      stepIndex: _currentStepIndex,
      startedAtMs: DateTime.now().millisecondsSinceEpoch,
      order: _nextTimelineOrder++,
    );
    state = state.copyWith(
      agentSteps: [...state.agentSteps, step],
      agentTimeline: [
        ...state.agentTimeline,
        AgentTimelineBlock(
          kind: AgentTimelineKind.action,
          stepIndex: _currentStepIndex,
          action: step,
          order: step.order,
        ),
      ],
    );
  }

  /// 处置待确认写入（allow=false 可带反馈回给模型）。
  ///
  /// [feedback]：导演批注
  /// ——allow 时随 Granted 下发（工具成功回执尾部信封），deny 时与旧拒绝
  /// 留言通道完全一致；空 = 纯批准/纯拒绝，行为与现状一致。
  ///
  /// [always] = true（横幅「本会话总是允许」）时同时把该工具记入
  /// 会话级放行集——后续同工具的 ask 态调用不再弹横幅，直接放行留痕。
  /// **merge_entities 永不进放行集**：归并横幅不显示该按钮，
  /// 这里再兜一道底——即便误传 always 也不记入，永远逐次审批。
  void resolveDirectorApproval({
    required bool allow,
    String? feedback,
    bool always = false,
  }) {
    if (allow && always) {
      final toolName = _pendingApprovalToolName;
      if (toolName != null && toolName != 'merge_entities') {
        _sessionApprovalAllows.add(toolName);
        _appendTraceStep(
          t.advanced.approval.sessionAlwaysRemembered(
            tool: stageVerbOf(toolName, t),
          ),
        );
      }
    }
    if (allow) {
      // durable 留痕（批 B）：变更条数 + 是否附批注（不含全文，防事件膨胀）
      final toolName = _pendingApprovalToolName;
      if (toolName != null) {
        _appendTraceStep(
          '${t.advanced.approval.approvedTrace(
            tool: stageVerbOf(toolName, t),
            count: _pendingApprovalChangeCount,
          )}'
          '${feedback == null || feedback.trim().isEmpty ? '' : t.advanced.approval.approvedTraceNoted}',
        );
      }
    }
    final completer = _approvalCompleter;
    if (completer != null && !completer.isCompleted) {
      final trimmed = feedback?.trim();
      final hasNote = trimmed != null && trimmed.isNotEmpty;
      completer.complete(
        allow
            ? AgentApprovalGranted(feedback: hasNote ? trimmed : null)
            : AgentApprovalDenied(feedback),
      );
    }
  }

  /// 取消/失败时作废挂起的 HITL 请求（防 UI 悬挂横幅）
  void _cancelPendingDirectorHITL() {
    answerDirectorAsk(null);
    resolveDirectorApproval(allow: false, feedback: '本轮已中断');
  }

  void _setActivity(AgentActivity activity, [int? stepIndex]) {
    if (state.agentActivity == activity &&
        (stepIndex == null || state.agentActivityStepIndex == stepIndex)) {
      return;
    }
    state = state.copyWith(
      agentActivity: activity,
      agentActivityStepIndex: stepIndex,
    );
  }

  /// agent 事件 → story state（直播分块 + 工具步骤）
  void _onAgentEvent(AgentRunEvent event) {
    if ((_cancellation?.isCancelled ?? false) &&
        (event is AgentTextDeltaEvent ||
            event is AgentThinkingDeltaEvent ||
            event is AgentResponseCompleted)) {
      return;
    }
    //  批3：非 delta 事件先冲刷直播合帧缓冲——直播时间线里工具步骤/
    // 权威替换/收割都按真实顺序读 liveBlocks，合帧段必须先落账。
    // finish_round 参数流缓冲同冲（内容流先落，保持既有顺序）。
    if (event is! AgentTextDeltaEvent && event is! AgentThinkingDeltaEvent) {
      _liveDeltas.flush();
      _proseLiveDeltas.flush();
    }
    switch (event) {
      case AgentStepStarted(:final stepIndex, :final attempt):
        // 工具执行事件的归并步号由此追踪（见 _currentStepIndex 注释）
        _currentStepIndex = stepIndex;
        _contentKey = null;
        _setActivity(AgentActivity.waitingResponse, stepIndex);
        // 契约 §7.1：请求失败重试复用 stepIndex——失败尝试的半截直播块
        // 先清空，否则与重试全文拼进同一块污染稿件卡候选
        if (attempt > 0) {
          _proseExtractors.clear();
          _proseOrders.clear();
          _activeProseExtractor = null;
          state = state.copyWith(
            liveBlocks: AgentLiveTranscript.removeStep(
              state.liveBlocks,
              stepIndex,
            ),
          );
        }
        // step 开始 = 重试等待结束，撤下倒计时状态条
        state = state.copyWith(agentRetryWait: null);
        // 预算标题步号推进（重试复用 stepIndex，currentStep 不回退）
        state = state.copyWith(
          agentRoundProgress:
              state.agentRoundProgress?.copyWith(currentStep: stepIndex + 1),
        );
      case AgentRetryScheduled(
          :final waitMs,
          :final attempt,
          :final at,
          :final maxAttempts,
          :final cause,
        ):
        _setActivity(AgentActivity.retryWaiting);
        // 退避/Retry-After 等待可视化——以事件到达时刻为锚
        state = state.copyWith(
          agentRetryWait: AgentRetryWait(
            waitMs: waitMs,
            attempt: attempt,
            scheduledAtMs: at.millisecondsSinceEpoch,
            maxAttempts: maxAttempts,
            cause: cause,
          ),
        );
      case AgentResponseCompleted(
          :final stepIndex,
          :final text,
          :final reasoning,
          :final hadTextDelta,
          :final hadThinkingDelta
        ):
        var blocks = state.liveBlocks;
        if (!hadThinkingDelta &&
            reasoning != null &&
            reasoning.trim().isNotEmpty) {
          blocks = AgentLiveTranscript.appendThinking(
            blocks,
            stepIndex,
            reasoning,
            order: _orderForContent(true, stepIndex),
          );
        }
        if (!hadTextDelta && text.trim().isNotEmpty) {
          blocks = AgentLiveTranscript.appendText(
            blocks,
            stepIndex,
            text,
            order: _orderForContent(false, stepIndex),
          );
        }
        state = state.copyWith(
          liveBlocks: blocks,
          agentActivity: AgentActivity.processing,
        );
      case AgentToolCallReceived(:final call):
        // 正文交付契约 §4.3 权威替换：finish_round 的参数协议解析完成即用
        // 已解析 prose 整块替换该 step 直播文本块（修正流式反转义毛刺/围栏；
        // 早于工具执行与 collectRound，轮时间线装配看到的就是权威文本）。
        // 畸形 JSON 降级空 Map 时保留流式文本（通道 B 的收割素材）。
        if (call.name == 'finish_round' && !state.inMaintenancePhase) {
          final prose = FinishRoundTool.stripCodeFences(
            call.arguments['prose']?.toString() ?? '',
          );
          if (prose.trim().isNotEmpty) {
            final replaced = AgentLiveTranscript.replaceStepText(
              state.liveBlocks,
              _currentStepIndex,
              prose,
              order: _orderForProse(call.id),
            );
            // L3 终局折叠（§6.2）：本轮 ≥200 字 content 块与权威 prose 近拷贝
            // → 折叠为占位行；部分复制不折叠（残留当播报，不误伤）。
            // 权威块自身受保护——直播稿件卡仍要显示正文
            var authoritativeIndex = -1;
            for (var i = replaced.length - 1; i >= 0; i--) {
              final b = replaced[i];
              if (b.stepIndex < _currentStepIndex) break;
              if (b.isManuscript) {
                authoritativeIndex = i;
                break;
              }
            }
            state = state.copyWith(
              liveBlocks: AgentProseDedup.finalFold(
                prose,
                replaced,
                t.advanced.draftMergedPlaceholder,
                keepIndices:
                    authoritativeIndex >= 0 ? {authoritativeIndex} : const {},
              ),
            );
          }
        }
      case AgentTextDeltaEvent(:final stepIndex, :final delta, :final at):
        _setActivity(AgentActivity.narrating, stepIndex);
        //  批3：进 32ms 合帧（分段规则不变——同 step 同类型追加末块、
        // 否则新开一块，由 applyLiveDeltaRuns 经 AgentLiveTranscript 保证）
        _liveDeltas.add(
          AgentLiveDelta(
            thinking: false,
            order: _orderForContent(false, stepIndex),
            stepIndex: stepIndex,
            atMs: at.millisecondsSinceEpoch,
            text: delta,
          ),
        );
      case AgentThinkingDeltaEvent(:final stepIndex, :final delta, :final at):
        _setActivity(AgentActivity.thinking, stepIndex);
        _liveDeltas.add(
          AgentLiveDelta(
            thinking: true,
            order: _orderForContent(true, stepIndex),
            stepIndex: stepIndex,
            atMs: at.millisecondsSinceEpoch,
            text: delta,
          ),
        );
      case AgentToolExecutionStarted(
          :final callId,
          :final toolName,
          :final argsPreview,
          :final at,
        ):
        _setActivity(AgentActivity.tool);
        _contentKey = null;
        // 占位 running 步骤：工具卡先以微光态出现，finished 时原地转 done/error。
        // 正文交付契约 §4.3：finish_round 的参数即正文——argsPreview 会把
        // 正文在工具卡露一角，置空；running 标题「正在执笔…」兜住等待观感
        // （Gemini 原子到达/非流式回退的整块出稿尤其依赖它）。
        final isFinish = toolName == 'finish_round';
        state = state.copyWith(
          agentSteps: [
            ...state.agentSteps,
            AgentWorkStep(
              callId: callId,
              toolName: toolName,
              argsPreview: isFinish ? '' : argsPreview,
              title: isFinish ? t.advanced.penStreaming : '',
              status: AgentStepStatus.running,
              stepIndex: _currentStepIndex,
              startedAtMs: at.millisecondsSinceEpoch,
              order: _nextTimelineOrder++,
            ),
          ],
        );
      case AgentToolExecutionFinished(
          :final callId,
          :final toolName,
          :final title,
          :final output,
          :final isError,
          :final duration,
          :final metadata,
        ):
        _setActivity(AgentActivity.processing);
        final steps = List<AgentWorkStep>.of(state.agentSteps);
        final index = steps.lastIndexWhere((s) => s.callId == callId);
        final old = index >= 0 ? steps[index] : null;
        final finished = AgentWorkStep(
          callId: callId,
          toolName: toolName,
          argsPreview: old?.argsPreview ?? '',
          title: title,
          output: output,
          status: isError ? AgentStepStatus.warning : AgentStepStatus.done,
          durationMs: duration.inMilliseconds,
          stepIndex: old?.stepIndex ?? _currentStepIndex,
          startedAtMs: old?.startedAtMs,
          order: old?.order ?? _nextTimelineOrder++,
        );
        if (index >= 0) {
          steps[index] = finished;
        } else {
          steps.add(finished);
        }
        final enteringMaintenance = toolName == 'finish_round' &&
            !isError &&
            metadata?['phase'] == 'maintenance' &&
            !state.inMaintenancePhase;
        final extraSteps =
            (metadata?['extraMaxStepsDelta'] as num?)?.toInt() ?? 0;
        final currentProgress = state.agentRoundProgress;
        final nextProgress = enteringMaintenance &&
                currentProgress != null &&
                currentProgress.maxSteps > 0 &&
                extraSteps > 0
            ? currentProgress.copyWith(
                maxSteps: currentProgress.maxSteps + extraSteps,
              )
            : currentProgress;
        // DD1：时间线同步回补——collectRound 在 finish_round 工具体内装配
        // 时间线，此刻该步骤仍是 running；只更新 agentSteps 会让落库的
        // agentTimeline 永久停在 running（历史轮渲染成永久 spinner）。
        state = state.copyWith(
          agentSteps: steps,
          agentTimeline: _patchTimelineStep(state.agentTimeline, finished),
          inMaintenancePhase: enteringMaintenance ? true : null,
          maintenanceStepStart: enteringMaintenance ? steps.length : null,
          agentRoundProgress: nextProgress,
        );
      default:
        break;
    }
  }

  /// 把已完成的步骤回补进轮时间线（按 callId 原地替换动作块）。
  ///
  /// 无匹配块 / 无 callId / 时间线为空时原样返回（不产生新列表，避免
  /// 每步都触发一次 state 通知）。
  List<AgentTimelineBlock> _patchTimelineStep(
    List<AgentTimelineBlock> timeline,
    AgentWorkStep finished,
  ) {
    if (timeline.isEmpty || finished.callId.isEmpty) return timeline;
    var changed = false;
    final patched = <AgentTimelineBlock>[];
    for (final block in timeline) {
      if (block.isAction && block.action?.callId == finished.callId) {
        patched.add(block.copyWithAction(finished));
        changed = true;
      } else {
        patched.add(block);
      }
    }
    return changed ? patched : timeline;
  }

  /// 轮因失败中断 → 把"肇事步骤"升为红色 error（DD2）。
  ///
  /// 可恢复失败在 Finished 事件里一律先记 warning（黄色）；只有真正中断
  /// 本轮（E104 / 零产出 EAGENT / 停轮）才转红。肇事判定：最后一条仍
  /// running 的步骤（致命异常路径的防御分支），否则最后一条 warning 步骤。
  /// 用户主动取消不走本方法——取消不是失败。
  void _escalateInterruptedStepToError() {
    final steps = List<AgentWorkStep>.of(state.agentSteps);
    var index = steps.lastIndexWhere((s) => s.isRunning);
    if (index < 0) index = steps.lastIndexWhere((s) => s.isWarning);
    if (index < 0) return;
    final escalated = steps[index].withStatus(AgentStepStatus.error);
    steps[index] = escalated;
    state = state.copyWith(
      agentSteps: steps,
      agentTimeline: _patchTimelineStep(state.agentTimeline, escalated),
    );
  }

  /// finish_round 参数增量 → liveBlocks 直播（正文交付契约 §4.3）
  ///
  /// 提取器与最终 JSON 解析成败无关：参数尾部被截断（finish_reason=length）
  /// 时，缓冲里已提取的正文仍在——通道 B 的收割素材在直播层就已就位。
  void _onToolArgDelta(String toolCallId, String toolName, String delta) {
    if (_cancellation?.isCancelled ?? false) return;
    if (toolName == 'finish_round' && !state.inMaintenancePhase) {
      _setActivity(AgentActivity.generating);
    }
    if (toolName != 'finish_round' || state.inMaintenancePhase) return;
    //  批3：早折叠读 liveBlocks 前先冲刷合帧段（保序）
    _liveDeltas.flush();
    final extractor = _proseExtractors.putIfAbsent(
      (_currentStepIndex, toolCallId),
      AgentProseExtractor.new,
    );
    _activeProseExtractor = extractor;
    final out = extractor.push(delta);
    if (out.isEmpty) return;
    // 正文增量进 32ms 合帧（分段规则与内容流同源——
    // applyLiveDeltaRuns 经 AgentLiveTranscript 保证段边界语义）
    _proseLiveDeltas.add(
      AgentLiveDelta(
        thinking: false,
        source: AgentTextSource.finishRoundProse,
        order: _orderForProse(toolCallId),
        stepIndex: _currentStepIndex,
        atMs: DateTime.now().millisecondsSinceEpoch,
        text: out,
      ),
    );
  }

  ///  修复：工具执行进度 → running 步骤的展示文本
  ///
  /// 工具体内 `invocation.onProgress?.call('检索「xxx」')` 此前是空操作；
  /// 现经 AgentTurnSpec.onToolProgress 桥接到这里，原地更新对应 running
  /// 步骤的 title（L1 过程行优先展示 title，见 DirectorProcessRow._headline）。
  void _updateRunningStepProgress(String callId, String message) {
    final steps = List<AgentWorkStep>.of(state.agentSteps);
    final index = steps.lastIndexWhere(
      (s) => s.callId == callId && s.status == AgentStepStatus.running,
    );
    if (index < 0) return;
    final old = steps[index];
    steps[index] = AgentWorkStep(
      toolName: old.toolName,
      callId: old.callId,
      argsPreview: old.argsPreview,
      title: message,
      output: old.output,
      status: old.status,
      durationMs: old.durationMs,
      stepIndex: old.stepIndex,
      startedAtMs: old.startedAtMs,
      order: old.order,
    );
    state = state.copyWith(agentSteps: steps);
  }

  /// ──  轮首补账事件：system/frozen + system/core + 初始 user/message ──
  ///
  /// 目标是"从日志可重建每步实际发出的完整消息序列"：轮首基础消息
  /// 进 durable 日志（直接 appendNow 落库），轮内的注入/assistant/tool
  /// 事件由 sink 随流写入。system/frozen 只在会话首次或前缀变更时追加
  /// （冻结前缀本就跨轮恒定，变更=一次性事件）。
  ///
  /// 补账扩展（与 surface 组装同序）：
  /// - system/core 仅 A 案（coreBlocks 留 system 区）落账；B 案（挪尾）
  ///   改落 workbench-reminder user 消息（kind=core_blocks_tail）
  /// - 上一轮 round-work 痕迹（kind=work_trace，仅一次，随本轮补账入日志；
  ///   事件标本轮 turn——重生成清理按本轮区间删除后重落，不残留重复）
  /// - 尾部装配面（first_turn_hint?/tail_contract/foreshadow_sweep?/
  ///   style_iron_rule/pacing/data_boundary_reassert?，按 surfaceTailMessages
  ///   同序）与漂移告知（drift_reminder，触发轮才有）
  Future<void> _appendRoundBootstrapEvents(
    DurableAgentEventSink durableSink, {
    required bool engineeringOpen,
    required int turnNumber,
    required String attemptId,
    required String frozenPrefix,
    required String? coreBlocks,
    required bool coreBlocksInTail,
    required String userInput,
    required List<AgentMessage> tailMessages,
    required List<String> tailKinds,
    required String? driftReminderLine,
    required String? previousTraceLine,
    String? coreBlocksTailOverride,
  }) async {
    if (_lastLoggedFrozenPrefix != frozenPrefix) {
      _lastLoggedFrozenPrefix = frozenPrefix;
      await durableSink.appendNow(
        AgentDurableEvent(
          type: AgentEventTypes.systemFrozen,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {
            'content': frozenPrefix,
            'turn': turnNumber,
            'attemptId': attemptId,
          },
        ),
      );
    }
    if (engineeringOpen) {
      // 新模式固定顺序：u_k → 快照 → 指令。快照恒为不可变注入面
      //（绝对标注/无变化单行，一次写入不改写）——旧 A/B 配置的
      // systemCore 「当前值折叠」不进入新模式（原位覆盖会改写历史）。
      await durableSink.appendNow(
        AgentDurableEvent(
          type: AgentEventTypes.userMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: AgentUserMessageData(content: userInput).toJson()
            ..['turn'] = turnNumber
            ..['attemptId'] = attemptId,
        ),
      );
      if (coreBlocks != null) {
        await _appendInjectedUserMessage(
          durableSink,
          content: coreBlocksTailOverride ?? wrapCoreBlocksForTail(coreBlocks),
          kind: AgentInjectedMessageKinds.coreBlocksTail,
          turnNumber: turnNumber,
          attemptId: attemptId,
        );
      }
    } else {
      // 关闭态基线：core 进场记板（A 配置，投影按当前值折叠）/
      // trace/快照挪尾（B 配置）/u_k——逐字节保持既有顺序。
      if (coreBlocks != null && !coreBlocksInTail) {
        await durableSink.appendNow(
          AgentDurableEvent(
            type: AgentEventTypes.systemCore,
            surfaceOp: AgentSurfaceOpKind.append,
            data: {
              'content': coreBlocks,
              'turn': turnNumber,
              'attemptId': attemptId,
            },
          ),
        );
      }
      // 尾部装配面按 surface 顺序落账（折叠锚点后 trace 在历史区末尾）
      if (previousTraceLine != null) {
        await _appendInjectedUserMessage(
          durableSink,
          content: previousTraceLine,
          kind: AgentInjectedMessageKinds.workTrace,
          turnNumber: turnNumber,
          attemptId: attemptId,
        );
      }
      if (coreBlocks != null && coreBlocksInTail) {
        await _appendInjectedUserMessage(
          durableSink,
          content: coreBlocksTailOverride ?? wrapCoreBlocksForTail(coreBlocks),
          kind: AgentInjectedMessageKinds.coreBlocksTail,
          turnNumber: turnNumber,
          attemptId: attemptId,
        );
      }
      await durableSink.appendNow(
        AgentDurableEvent(
          type: AgentEventTypes.userMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: AgentUserMessageData(content: userInput).toJson()
            ..['turn'] = turnNumber
            ..['attemptId'] = attemptId,
        ),
      );
    }
    for (var i = 0; i < tailMessages.length && i < tailKinds.length; i++) {
      final content = tailMessages[i].content;
      if (content == null || content.isEmpty) continue;
      await _appendInjectedUserMessage(
        durableSink,
        content: content,
        kind: tailKinds[i],
        turnNumber: turnNumber,
        attemptId: attemptId,
      );
    }
    if (driftReminderLine != null) {
      await _appendInjectedUserMessage(
        durableSink,
        content: wrapWorkbenchReminder(driftReminderLine),
        kind: AgentInjectedMessageKinds.driftReminder,
        turnNumber: turnNumber,
        attemptId: attemptId,
      );
    }
  }

  /// 注入面 user/message 落账（：source=注入 kind，供投影与轮轨迹辨认）
  Future<void> _appendInjectedUserMessage(
    DurableAgentEventSink durableSink, {
    required String content,
    required String kind,
    required int turnNumber,
    required String attemptId,
  }) {
    return durableSink.appendNow(
      AgentDurableEvent(
        type: AgentEventTypes.userMessage,
        surfaceOp: AgentSurfaceOpKind.append,
        data: AgentUserMessageData(content: content, source: kind).toJson()
          ..['turn'] = turnNumber
          ..['attemptId'] = attemptId,
      ),
    );
  }

  /// 手动压缩的工具目录：与轮装配同一构建器、权限求值（deny 集一致）与
  /// 技能名来源（read_skill 描述文本随技能清单生成，两路须对齐）。
  /// 合成 draft 仅用于装配——工具定义面（name/description/schema）恒定，
  /// 工具对象构造仅存依赖引用，不触发任何仓储调用（demo 工具指纹同
  /// 先例）。factual 仓库缺失（不应发生）返回空目录（保守回退）。
  Future<List<ToolDefinition>> manualCompactionToolDefinitions() async {
    final factual = _factualRepository;
    if (factual == null) return const [];
    final skills = await _ensureDirectorSkills();
    final sessionTools = state.session.sessionToolPermissions;
    ToolPermissionState permFor(String name) => ToolPermissions.effective(
          session: sessionTools,
          global: _tuning.globalTools,
          toolName: name,
        );
    final deniedTools = {
      for (final t in ToolPermissions.allTools)
        if (permFor(t) == ToolPermissionState.deny) t,
    };
    final deps = AgentToolDeps(
      sessionId: state.session.sessionId,
      draft: AgentRoundDraft(turnNumber: state.session.nextTurn ?? 1),
      factualRepository: factual,
      experienceRepository: _experienceRepository,
      storyReader: DirectorStoryReader(_host),
      latestMacros: () async => const [],
      userInteraction: _DirectorUserInteractionPort(this),
      enableAskUser: true,
      // 定义面装配专用：提交/锚等行为闭包不参与工具定义，永不触发
      commitRound: (draft) async => '',
      embedQuery: _host.resolveQueryVector,
      // spawn 的定义面静态（demo 工具蓝图同先例）；runner 仅为装配存在
      spawnToolFactory: (readOnlyTools) =>
          SpawnTool(_BlueprintSubagentRunner()),
      loadSkillBody:
          skills.isEmpty ? null : (name) => _skillLoader.loadBody(name),
      skillNames: [for (final s in skills) s.name],
      styleLint: const AgentStyleLint(),
      currentAnchor: () => state.session.storyAnchor,
    );
    return agentToolsToDefinitions(
      buildAgentTools(deps, deniedTools: deniedTools),
    );
  }

  /// ──  压缩接线（开启态）：账本压缩事务（两段提交+四条件校验）──────
  ///
  /// 触发（完整预算面口径）：纪元窗投影实际可回传表示 + 工具定义
  /// 固定面的字符估算与用户阈值比较，输出预留可让压缩提前。失败/
  /// 被拒不阻断本轮（继续用未压缩表面，溢出由轮中自愈兜底）；熔断/rapid-
  /// refill 后当次跳过。
  Future<void> _runEngineeringCompactionPhase(
    RoundContext round, {
    required List<ToolDefinition> tools,
  }) async {
    final service = _host.engineeringCompactionService;
    final eventLog = _host.agentEventLogRepository;
    if (service == null || eventLog == null) return;
    // 触发/选材默认来自 default_config.json 配置段（不形成第二常量来源）
    // advanced.engineering_compaction；输出预留用当前协议最终请求面的
    // 有效输出预算（设置 0→模型上限；否则 min(设置, 模型上限)；含
    // providerOptions 末位覆盖——与实际请求同源，不得传原始设置值）
    final tuning = EngineeringCompactionTuning.forDirectorRequest(
      round.config.engineeringCompaction,
      naming: round.generatingNamingConfig,
      settings: round.settings,
    );
    try {
      final events = await eventLog.readEvents(state.session.sessionId);
      final projection = DirectorSurfaceV2.epochWindowProjection(events);
      // 完整预算面：投影可回传表示（wire-map 口径，含协议化思考/签名）+
      // 工具定义固定面 + 冻结前缀（不进投影但进请求，漏计会低估真实表面
      // 并高估可压空间）
      final frozenPrefixChars =
          DirectorSurfaceV2.latestFrozenPrefixOf(events)?.length ?? 0;
      final wireOptions = AgentWireOptions.forProtocolName(
        round.generatingNamingConfig.protocol.name,
      );
      final surfaceChars = surfaceInputChars(
        projection.messages,
        options: wireOptions,
        extraFixedChars: toolDefinitionsChars(tools) + frozenPrefixChars,
      );
      final threshold = directorCompactionTriggerTokens(
        contextWindowTokens: round.contextWindow,
        budget: round.config.contextBudget,
        engineeringTuning: tuning,
      );
      // 触发估算：优先可靠实报锚点 + 同修订材料差分（与轮尾闭合同一
      // 算术——锚点=末次可靠主请求实报完整输入，已含请求时的工具目录/
      // 冻结前缀/系统段；差分只对消息面做字符修正，工具目录与冻结前缀
      // 跨轮稳定，不重复计入）。无可靠锚点（未上报/指纹失配/配置变更）
      // 才回退本地字符估算（完整预算面口径）——供应商实报明显大于字符
      // 估算时，纯字符口径会显示接近上限却始终不提前压缩。
      final anchorTokens = _triggerAnchorTokens;
      final anchorMessages = _triggerAnchorMessages;
      final anchorUsable = anchorTokens != null &&
          anchorTokens > 0 &&
          anchorMessages.isNotEmpty &&
          _triggerAnchorFingerprint == _surfaceFingerprintOf(round);
      final currentMessageChars =
          surfaceInputChars(projection.messages, options: wireOptions) +
              frozenPrefixChars;
      final anchorMessageChars =
          surfaceInputChars(anchorMessages, options: wireOptions);
      final estimated = anchorUsable
          ? math.max(
              0,
              anchorTokens +
                  (currentMessageChars - anchorMessageChars) ~/
                      tuning.charsPerToken,
            )
          : estimateTokensForChars(surfaceChars, tuning);
      if (estimated < threshold) return;

      state = state.copyWith(phase: IntermediatePhase.compacting);
      final result = await service.compact(
        sessionId: state.session.sessionId,
        trigger: 'auto',
        contextWindowTokens: round.contextWindow,
        retrievalRatio: round.config.contextBudget.retrievalRatio,
        tools: tools,
        tuning: tuning,
        cancelToken: _compactionToken,
        wireOptions: wireOptions,
        frozenPrefixChars: frozenPrefixChars,
      );
      if (result.outcome == 'committed' &&
          result.shadowedTokenEstimate != null &&
          result.framedTokenEstimate != null) {
        // 材料收缩按真实量调整预计（净减少计入估算——锚点不变，
        // 移除被压材料、加入纪要；无锚点时 shift 保 unknown）
        state = state.copyWith(
          contextEstimate: state.contextEstimate?.shift(
            removedTokens: result.shadowedTokenEstimate!,
            addedTokens: result.framedTokenEstimate!,
            at: DateTime.now(),
          ),
          // 构成基线失效（下一轮装配重建；轮尾差分闭合再按最终投影重算）
          contextSegmentChars: null,
        );
      }
      _logger.info(
        'Engineering pre-round compaction finished',
        detail: 'outcome=${result.outcome}, reason=${result.reason}, '
            'estimated=$estimated, threshold=$threshold',
      );
    } catch (e, stackTrace) {
      if (_compactionToken?.isCancelled ?? false) return;
      _logger.warn(
        'Engineering pre-round compaction skipped on failure',
        detail: '$e\n$stackTrace',
      );
    }
  }

  /// ──  压缩接线：导演轮轮前压缩（与故事模式同构，结果随 persist 落库）──
  ///
  /// 复用故事模式 compaction 触发判定（compactionTriggerRatio）与压缩管线；
  /// 导演模式历史即普通消息+摘要，天然兼容。压缩结果写回 [round]，
  /// runPersistPhase 经 CompactionPersistenceData 在同一事务内持久化。
  /// 失败不阻断本轮（继续用未压缩历史，超长请求由 LLM 层重试机制兜底），
  /// 与故事模式"E018 整轮失败"不同——导演轮的事务不变量以"本轮正文"为先。
  Future<void> _runDirectorCompactionPhase(
    RoundContext round,
    String rulesPrompt,
  ) async {
    final service = _compactionService;
    if (service == null) return;

    try {
      final shouldCompact = await service.shouldCompact(
        history: round.history,
        contextWindow: round.contextWindow,
        budget: round.config.contextBudget,
        rolePrompt: rulesPrompt,
        compactionSummary: round.compactionSummary,
        userInput: round.userInput,
      );
      if (!shouldCompact) return;

      state = state.copyWith(phase: IntermediatePhase.compacting);
      final historyBefore = round.history;
      final result = await service.compact(
        history: historyBefore,
        sessionId: state.session.sessionId,
        namingConfig: round.summarizeNamingConfig,
        contextWindow: round.contextWindow,
        maxTokens: _outputTokenReserveFor(
          round.settings.maxTokens,
          modelMaxOutput: round.generatingNamingConfig.maxOutputTokens,
        ),
        budget: round.config.contextBudget,
        connectTimeout: round.connectTimeout,
        readTimeout: round.readTimeout,
        existingCompactionSummary: round.compactionSummary,
        cancelToken: _compactionToken,
        // 保留量上限受"触发线 − 检索预留 − 基础上下文"包络约束，
        // 避免压缩完成后 shouldCompact 仍为 true 每轮重复压缩
        baseContextTokens: await service.estimateBaseContextTokens(
          rolePrompt: rulesPrompt,
          compactionSummary: round.compactionSummary,
          userInput: round.userInput,
        ),
      );
      if (_host.isStreamCancelled || _host.currentRound != round) return;

      final newlyCoveredTurns = StoryCompactionService.newlyCoveredTurnsFor(
        historyBefore: historyBefore,
        boundaryMessageId: result.boundaryMessageId,
      );
      final newBase = state.compactedTurnBase + newlyCoveredTurns;
      round
        ..compactionSummary = result.summary
        ..compactionBoundaryMessageId = result.boundaryMessageId
        ..compactionSummaryMessage = result.compactedHistory.first
        ..segmentMacroSummary = result.segmentMacroSummary
        ..history = result.compactedHistory;
      // 与故事侧写回同口径：persist 基于压缩后视图追加本轮消息，
      // 手动压缩也以 state 的最新摘要/基数为输入。
      state = state.copyWith(
        messages: result.compactedHistory,
        compactedTurnBase: newBase,
      );

      _logger.info(
        'Director compaction completed',
        detail: 'summaryLength=${result.summary.length}, '
            'tokensBefore=${result.tokensBefore}, '
            'tokensAfter=${result.tokensAfter}, '
            'boundaryMessageId=${result.boundaryMessageId}',
      );
    } on CompactionNoopException catch (e) {
      _logger.info(
        'Director compaction skipped: no benefit',
        detail: 'reason=${e.reason.name}',
      );
      return;
    } catch (e, stackTrace) {
      if (_compactionToken?.isCancelled ?? false) {
        // 用户停止：压缩中止不算失败跳过，调用方的取消检查会终止轮次
        _logger.info('Director compaction cancelled by user stop');
        return;
      }
      _logger.warn(
        'Director compaction skipped on failure',
        detail: '$e\n$stackTrace',
      );
    }
  }

  // ──  core blocks：世界状态常驻注入（场记板）──
  //
  // 关键实体（imp≥阈值）+ 属性 + 最新宏摘要 + 叙事时间。作为独立 system
  // 消息置于冻结前缀之后（缓存断点后，可低频 replace）。给模型"每轮至少
  // 知道现在几点、主线在哪、谁在场"——不是大纲，是世界状态。
  //
  // 装配实现抽至共享服务
  // [assembleDirectorCoreBlocks]——注入面与场记板视图（用户可见的
  // 「AI 眼中的现在」）同一份数据，互验一致； 的 hasImported
  // 标记（任一关键实体来自导入，驱动尾部资料边界重申）随数据对象携带。

  /// 开启态证据闸门：关键实体需「成功∧命中∧修订未变∧资格
  ///（active/压缩承接）」证据；旧 calledTools 旁路不进判据。返回 null=过。
  Future<EntityCoverageCheck?> _checkRetrievalEvidence(
    String prose,
    DirectorHost host,
    AgentRoundDraft draft,
    RoundContext round,
  ) async {
    if (draft.turnNumber <= 1) return null;
    final eventLog = host.agentEventLogRepository;
    final factual = _factualRepository;
    if (eventLog == null || factual == null) return null;
    try {
      final events = await eventLog.readEvents(state.session.sessionId);
      final window = DirectorSurfaceV2.epochWindowEvents(events);

      // 正文中命中的关键实体（复用旧闸门抽取——只看 prose，不看输入）
      final keyEntities = await factual.getKeyEntities(
        state.session.sessionId,
        round.config.memory.factual.keyEntityImportanceThreshold,
        excludeInjectionDisabled: true,
      );
      final hitIds = <String>{};
      final hitNames = <String>{};
      for (final entity in keyEntities) {
        for (final candidate in [entity.primaryName, ...entity.aliases]) {
          final trimmed = candidate.trim();
          if (trimmed.length < 2) continue;
          if (prose.contains(trimmed)) {
            hitIds.add(entity.entityId);
            hitNames.add(trimmed);
            break;
          }
        }
      }
      if (hitIds.isEmpty) return null;

      // 当前修订身份（闸门时点）+ 变体遮蔽轮 + 压缩承接清单
      final currentRevisions = <String,
          ({String primaryName, int? updatedAtMs, String contentDigest})>{};
      for (final id in hitIds) {
        final entity = await factual.getEntityById(id);
        if (entity == null) continue;
        final attrs = await factual.getAttributes(
          state.session.sessionId,
          [id],
        );
        currentRevisions[id] = (
          primaryName: entity.primaryName,
          updatedAtMs: entity.updatedAt?.millisecondsSinceEpoch,
          // 与工具执行处证据快照共用同一规范化修订函数/排序/时间身份
          contentDigest: entityRevisionDigest(
            updatedAtMs: entity.updatedAt?.millisecondsSinceEpoch,
            attributes: [for (final a in attrs) (a.attrKey, a.value)],
          ),
        );
      }
      final maskedTurns = <int>{};
      for (final e in window) {
        if (e.type == AgentEventTypes.branchRebuild &&
            e.data['reason'] == 'variant-switch' &&
            e.data['retain'] == false) {
          final t = (e.data['turn'] as num?)?.toInt();
          if (t != null) maskedTurns.add(t);
        }
      }
      // 承接键按当前存活压缩产物推导：二次压缩遗漏后旧承接失效、undo
      // 恢复资格链——不做历史 summary 永久并集
      final carried = deriveCarriedEvidenceKeys(window);
      return checkEntityCoverage(
        keyEntities: currentRevisions,
        windowEvents: window,
        eligibility: EvidenceEligibilityInput(
          windowEvents: window,
          maskedTurns: maskedTurns,
          carriedEvidenceKeys: carried,
        ),
      );
    } catch (e) {
      _logger.warn('Retrieval evidence gate failed open', detail: '$e');
      return null; // 数据面异常不阻断提交（fail-open）
    }
  }

  /// 开启态事件暴露量闸门：新关键实体 + 0.5×update_facts 条数；
  /// 三条件同时才触发。返回 null=放行。
  ///
  /// 输入=本轮正文实际命中实体（按实体身份去重）与历史正文已见
  /// 集合——不把全部候选名当命中、不拿整段旧文当已见集合。
  Future<EventExposureCheck?> _checkEventExposure(
    String prose,
    AgentRoundDraft draft,
    RoundContext round, {
    int eventGap = 0,
  }) async {
    final factual = _factualRepository;
    if (factual == null) return null;
    try {
      final keyEntities = await factual.getKeyEntities(
        state.session.sessionId,
        round.config.memory.factual.keyEntityImportanceThreshold,
        excludeInjectionDisabled: true,
      );
      // 此前正文=此前各轮 assistant 正文（压缩前全历史——state.messages
      // 是压缩过滤视图，压缩掉的旧正文会把出过场的旧实体误算为新暴露；
      // 当前轮输入/正文在 persist 前不落库，天然不在扫描源内）。用户
      // 指令不是正文：指令里提到名字是安排意向，不等于此前正文已出场
      //（已见集合只锚定实际写出的正文——否则闸门被旧指令提前豁免漏拦）
      final priorProse = [
        for (final m
            in await _host.loadSessionMessages(state.session.sessionId))
          if (m.role == 'assistant' &&
              !m.isSummary &&
              (m.content?.isNotEmpty ?? false))
            m.content!,
      ];
      final inputs = collectExposureInputs(
        prose: prose,
        priorProseMessages: priorProse,
        keyEntities: [
          for (final e in keyEntities)
            (primaryName: e.primaryName, aliases: e.aliases),
        ],
        coveredByMemoryNames: await _memoryCoveredEntityNames(
          keyEntities,
          prose,
        ),
      );
      // 表面估算比（轮装配构成字符近似——暂用持久化构成面，未接实报输入）
      final chars = state.contextSegmentChars;
      final total =
          chars == null ? 0 : chars.values.fold<int>(0, (a, b) => a + b);
      final window = state.contextWindowTokens ?? 0;
      final ratio = window > 0 ? (total ~/ 4) / window : 0.0;
      return checkEventExposure(
        keyEntityNamesHitInProse: inputs.hitNames,
        entityNamesInPriorProse: inputs.priorSeenNames,
        updateFactsDeltaCount: draft.factsDeltas.length,
        recordedEventMemory:
            draft.calledTools.contains('record_event_memory') ||
                draft.eventSummary != null,
        surfaceEstimateRatio: ratio,
        eventGap: eventGap,
        eventGapFallback: _tuning.maintenanceGapInterval,
      );
    } catch (e) {
      _logger.warn('Event exposure gate failed open', detail: '$e');
      return null;
    }
  }

  /// 既有事件记忆覆盖的实体名（03 §7.2：FTS 查实体名）——本轮实际命中
  /// 的实体逐个查**事件记忆库**（5W1E 全文子串，主名+别名 OR；含已归档：
  /// 在库即在记忆），命中者不算新暴露。查询只在命中集合上进行（通常
  /// 个位数）。注意不是事实卡（factual entities）：update_facts 产的
  /// 事实行不是事件记忆，不构成覆盖。
  Future<Set<String>> _memoryCoveredEntityNames(
    List<FactualEntity> keyEntities,
    String prose,
  ) async {
    if (keyEntities.isEmpty) return const {};
    final experience = _host.experienceRepository;
    final covered = <String>{};
    for (final entity in keyEntities) {
      final candidates = [
        entity.primaryName,
        ...entity.aliases,
      ].map((c) => c.trim()).where((c) => c.length >= 2);
      // 只查本轮正文实际命中的实体（与 collectExposureInputs 的命中
      // 口径一致；未命中实体的覆盖状态不参与新暴露判定）
      if (!candidates.any(prose.contains)) continue;
      // 查询词与命中口径同滤（≥2 字）：单字别名子串易偶然命中无关记忆
      final found = await experience.searchExperiencesBySubstring(
        state.session.sessionId,
        candidates.toList(),
        limit: 1,
        includeArchived: true,
      );
      if (found.isNotEmpty) covered.add(entity.primaryName);
    }
    return covered;
  }

  /// 当前轮思考回传判定：anthropic 按 CompatOptions 的实际
  /// 请求思考开关；其余协议=effort 未禁用。同脑但本轮思考关闭时，历史
  /// 思考块/签名同样不回传（投影层清除）。
  bool _thinkingReplayAllowedForCurrentRound({required RoundContext round}) {
    final naming = round.generatingNamingConfig;
    if (naming.protocol.name == 'anthropic') {
      final compat = AnthropicCompatOptions.resolve(
        baseUrl: naming.baseUrl,
        providerOptions: naming.providerOptions,
        reasoningEffort: round.settings.reasoningEffort,
        requestedMaxTokens: round.settings.maxTokens,
        modelMaxOutputTokens: naming.maxOutputTokens,
      );
      return compat.requestThinkingEnabled(
        effectiveMaxTokens: compat.maxTokens,
      );
    }
    return round.settings.reasoningEffort != ReasoningEffort.disabled;
  }

  /// ──  skill 加载：内置资产，首次 agent 轮加载后缓存复用 ──
  Future<List<AgentSkill>> _ensureDirectorSkills() async {
    final cached = _skillCache;
    if (cached != null) return cached;
    final loader = AssetSkillLoader(logger: _logger);
    _skillLoader = loader;
    final skills = await loader.loadBuiltin();
    _skillCache = skills;
    if (skills.isNotEmpty) {
      _logger.info(
        'Director skills loaded',
        detail: 'count=${skills.length}, '
            'alwaysInject=${skills.where((s) => s.alwaysInject).length}',
      );
    }
    return skills;
  }
}

/// 把 live agent 事件桥接到 runner（更新 state）
class _AgentEventSink implements AgentEventSink {
  _AgentEventSink(this._runner);

  final DirectorRoundRunner _runner;

  @override
  void emit(AgentRunEvent event) {
    _runner._onAgentEvent(event);
  }
}

/// live + durable 多播出口（体验重构 ：durable 事件日志接线）
class _MulticastAgentEventSink implements AgentEventSink {
  _MulticastAgentEventSink(this._sinks);

  final List<AgentEventSink> _sinks;

  @override
  void emit(AgentRunEvent event) {
    for (final sink in _sinks) {
      sink.emit(event);
    }
  }
}

/// ask_user 的 UI 桥（体验重构 ：横幅等待回答）
class _DirectorUserInteractionPort implements AgentUserInteractionPort {
  _DirectorUserInteractionPort(this._runner);

  final DirectorRoundRunner _runner;

  @override
  Future<String?> askUser({
    required String question,
    List<String>? options,
  }) {
    return _runner._pendingDirectorAsk(question, options);
  }
}

/// 监督模式审批 seam（体验重构 ：横幅等待确认，fail-closed）
class _DirectorApprovalSeam implements AgentApprovalSeam {
  _DirectorApprovalSeam(this._runner);

  final DirectorRoundRunner _runner;

  @override
  Future<AgentApprovalVerdict> requestApproval(
    ToolExecutionRequest request,
  ) {
    return _runner._pendingDirectorApproval(request);
  }
}

/// 子代理事件 → 主会话 durable 日志的 log-only 中继
///
/// 经 [DurableAgentEventSink.relaySubagentEvent] 剥离 surface 语义落账：
/// spawn 内部（步数/usage/工具产出）在日志与轨迹页可观测，投影不受
/// 子代理独立上下文污染。sink 未激活（无日志仓库）时 no-op。
/// [_subagentCallId]（HAR-09）：发起本次 spawn 的 toolCallId，随中继
/// 落账区分同轮多次 spawn 的归属。
class _SubagentDurableRelay implements AgentEventSink {
  _SubagentDurableRelay(this._runner, this._subagentCallId);

  final DirectorRoundRunner _runner;
  final String _subagentCallId;

  @override
  void emit(AgentRunEvent event) {
    _runner._activeDurableSink?.relaySubagentEvent(
      event,
      subagentCallId: _subagentCallId,
    );
  }
}

/// 导演轮 surface 的稳定前缀结束位置（历史最后一条消息的下标）
///
/// 仅供 Anthropic 历史端缓存断点；history 为空时返回 null。
@visibleForTesting
int? directorStablePrefixEndIndex({
  required int historyLength,
  required bool hasCoreBlocks,
  required bool coreBlocksInTail,
}) {
  if (historyLength <= 0) return null;
  final prefixCount = 1 + (hasCoreBlocks && !coreBlocksInTail ? 1 : 0);
  return prefixCount + historyLength - 1;
}

/// 导演轮 surface 组装
///
/// 布局：冻结前缀 → coreBlocks（A 案）→ 历史 → coreBlocks（B 案） →
/// 本轮输入 → 尾部指令 → 漂移提醒。
/// [coreBlocksInTail] = false（A 案）：coreBlocks 是 system 第 1 条
/// （多 system 块各自的缓存断点见 Anthropic 适配器）。
/// = true（B 案，默认，advanced.harness.core_blocks_in_tail）：coreBlocks 挪到
/// 本轮用户输入之前、尾部提醒之前，以 workbench-reminder 包裹的 user 消息
/// 承载（recitation 位），system 区只剩冻结前缀——切换开关即一次性缓存
/// 失效，之后 system 段字节跨轮恒定。
@visibleForTesting
List<AgentMessage> buildDirectorSurface({
  required String frozenPrefix,
  required List<AgentMessage> historyMessages,
  required String? coreBlocks,
  required bool coreBlocksInTail,
  required String userInput,
  required List<AgentMessage> tailMessages,
  String? driftReminderLine,
}) {
  return [
    AgentMessage.system(frozenPrefix),
    if (coreBlocks != null && !coreBlocksInTail)
      AgentMessage.system(coreBlocks),
    ...historyMessages,
    if (coreBlocks != null && coreBlocksInTail)
      AgentMessage.user(wrapCoreBlocksForTail(coreBlocks)),
    AgentMessage.user(userInput),
    ...tailMessages,
    if (driftReminderLine != null)
      AgentMessage.user(wrapWorkbenchReminder(driftReminderLine)),
  ];
}

/// 审批横幅人话摘要的纯函数实现（2026-08-24   提取为顶层，
/// 供单测锁定"每个 write 工具都有专属摘要"——新工具漏 case 编译期无感，
/// 此前 merge_entities 落 default 裸 dump 参数 Map 即该缺口的实证）。
@visibleForTesting
String approvalSummaryOf(ToolExecutionRequest request, Translations t) =>
    formatApprovalSummary(
      t,
      request.toolName,
      approvalSummaryDataOf(request.toolName, request.arguments),
    );

/// 手动压缩工具目录装配专用的子代理桩（定义面静态；行为闭包不参与
/// 工具定义，永不触发）
class _BlueprintSubagentRunner implements SubagentRunner {
  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('blueprint-only stub');
}
