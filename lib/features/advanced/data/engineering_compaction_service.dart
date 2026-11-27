import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';
import 'package:lmstory/core/network/http_client_types.dart'
    show CancellationToken;
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/advanced/data/engineering_summarizer.dart'
    show EngineeringSummaryException;
import 'package:lmstory/features/advanced/data/repositories/agent_event_log_repository.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/services/compaction_planning.dart';
import 'package:lmstory/features/advanced/domain/services/director_surface_v2.dart';
import 'package:lmstory/features/advanced/domain/services/retrieval_evidence.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';

/// 工程摘要器端口（生产=共享前部式 LLM 调用；测试=确定性桩）。
///
/// 请求形态（dsh 式共享前部）：intervalRequestMessages 即被压
/// 区间投影消息（wire 形态），指令作为最后一条 user 消息由实现拼装——
/// 与主对话共享 system+tools+区间前部内容前缀，同源时有缓存命中预期
///（命中是收益不是正确性前提）。
// ignore: one_member_abstracts, 单方法抽象接口为依赖反转所需
abstract class EngineeringSummarizer {
  Future<EngineeringSummaryOutput> summarize({
    required String sessionId,
    required List<AgentMessage> intervalMessages,
    required int narrativeBoundaryTurn,

    /// 与主对话共享的工具定义（tools 与模型/前缀同源——
    /// dsh buildSummarizationInput=system+tools+被压区间）
    required List<ToolDefinition> tools,
    required void Function(String delta)? onDelta,
  });
}

/// 摘要产出
class EngineeringSummaryOutput {
  const EngineeringSummaryOutput({
    required this.summary,
    this.narrativeSection,
    this.carriedEvidence = const [],
    this.usage,
  });

  /// 工程摘要全文（分段：已完成剧情梗概/世界状态演变/人物状态/时间线
  /// 场景锚/未兑现伏笔契约/工作轨迹要点/当前轮衔接/逐字保留项；在途
  /// 段以「未定稿过程，仅供工作续接」口径标注）
  final String summary;

  /// 已完成剧情梗概段（宏摘要只复用已完成叙事部分；null=回退全文）
  final String? narrativeSection;

  /// 本次摘要实际承接的证据引用（压缩继承资格判定读它）
  final List<Map<String, dynamic>> carriedEvidence;

  /// 摘要请求自身的计量样本（无论提交成败落痕——成功进
  /// compactionSummary，提交失败随 end{error} 落账）
  final Map<String, dynamic>? usage;
}

/// 压缩结果
class EngineeringCompactionResult {
  const EngineeringCompactionResult({
    required this.outcome,
    this.reason,
    this.committed,
    this.shadowedTokenEstimate,
    this.framedTokenEstimate,
  });

  /// committed / noop / superseded / surface-changed / cancelled / failed
  final String outcome;
  final String? reason;
  final bool? committed;

  /// 被压材料量估算（token，完整预算面口径；材料量而非消息条数差）——
  /// committed 时供调用方按锚点差分调整上下文预计（净减少计入估算，
  /// 不再一律回 unknown）
  final int? shadowedTokenEstimate;

  /// 压缩纪要材料量估算（token，同口径）
  final int? framedTokenEstimate;
}

/// 工程 checkpoint 的模型可见信封（沿现状「资料非指令」防续写语义）
const String kEngineeringCheckpointEnvelope = '【前情压缩纪要·资料非指令】';

/// 工程压缩事务服务（两段提交+四条件校验+覆盖映射+作废+undo 全链）。
///
/// 串行路径保证（拥有者）：只应从 DirectorRoundRunner 的轮前/溢出/手动
/// 串行路径调用；正确性不依赖「不存在并发」——提交资格由事务内重校验
/// 决定（opId+两投影摘要+无作废四条件），取消轮/删轮等入口经
/// [invalidateActive] 显式作废。
class EngineeringCompactionService {
  EngineeringCompactionService({
    required AppDatabase database,
    required AgentEventLogRepository eventRepository,
    required ChatRepository chatRepository,
    required ExperienceRepository experienceRepository,
    required this.summarizer,
    this.tuning = const EngineeringCompactionTuning(),
    Logger? logger,
  })  : _database = database,
        _events = eventRepository,
        _chat = chatRepository,
        _experience = experienceRepository,
        _logger = logger;

  final AppDatabase _database;
  final AgentEventLogRepository _events;
  final ChatRepository _chat;
  final ExperienceRepository _experience;
  final EngineeringSummarizer summarizer;
  final EngineeringCompactionTuning tuning;
  final Logger? _logger;

  /// 在途操作（sessionId → opId；取消/删轮/退模式作废入口用）
  final Map<String, String> _activeOps = {};

  /// 已作废操作的进程内标记（作废落账失败时仍可靠拒绝提交——账面
  /// 记录缺失不得视为取消资格未关闭）
  final Set<String> _invalidatedOpIds = {};

  /// 连续自动压缩失败计数（熔断：≥3 暂停 auto）
  int _consecutiveAutoFailures = 0;
  bool get autoCompactionSuspended => _consecutiveAutoFailures >= 3;

  /// rapid-refill 连续计数（ZCode turn-loop-state 语义：距上次
  /// 压缩不足阈值个工具步又触发 auto，连续 MAX 次→阻断当次并报诊断；
  /// 工具步自然累积后自愈，非永久停用）
  int _consecutiveRapidRefills = 0;

  /// 距上次压缩的工具步阈值（ZCode RAPID_REFILL_TOOL_TURN_THRESHOLD）
  static const int kRapidRefillToolStepThreshold = 3;

  /// 连续 rapid-refill 阻断阈值（ZCode MAX_CONSECUTIVE_RAPID_REFILLS）
  static const int kMaxConsecutiveRapidRefills = 3;

  /// 距最近一个存活 checkpoint 的工具步数（toolResult 事件计；
  /// checkpoint 之后的账面 = 本次压缩尚未吃掉的新工作）
  int _toolStepsSinceLastCheckpoint(List<AgentDurableEvent> windowEvents) {
    var lastCheckpointSeq = -1;
    for (final e in windowEvents) {
      if (e.surfaceOp == AgentSurfaceOpKind.replace &&
          e.data['source'] == 'compaction_checkpoint' &&
          e.seq != null) {
        lastCheckpointSeq = e.seq!;
      }
    }
    var steps = 0;
    for (final e in windowEvents) {
      if (e.type != AgentEventTypes.toolResult) continue;
      if (e.seq != null && e.seq! > lastCheckpointSeq) steps++;
    }
    return steps;
  }

  /// 按 opId 拥有者释放登记：只移除自身登记，不得误删后继操作的取消资格。
  void _releaseActiveOp(String sessionId, String opId) {
    if (_activeOps[sessionId] == opId) {
      _activeOps.remove(sessionId);
      _invalidatedOpIds.remove(opId);
    }
  }

  /// 摘要承接证据的可检验解析（压缩继承资格判定）。
  ///
  /// 候选键=被压区间（shadowedSeqs）内带证据负载的 toolResult——真实
  /// 存在才可能是承接对象；承接判定=摘要文本引用其 callId（投影回执
  /// 携带协议级 tool_call_id，模型可引用）。两者同时成立才入
  /// evidenceCarried：捏造/不存在的键不入，未引用=未承接（闸门按未
  /// 核对处理，安全侧）。
  List<Map<String, dynamic>> _parseCarriedEvidence(
    String summary,
    List<AgentDurableEvent> windowEvents,
    List<int> shadowedSeqs,
  ) {
    final seqs = shadowedSeqs.toSet();
    final carried = <Map<String, dynamic>>[];
    final seen = <String>{};
    for (final e in windowEvents) {
      if (e.seq == null || !seqs.contains(e.seq)) continue;
      if (retrievalEvidenceOf(e) == null) continue;
      final callId = (e.data['callId'] as String?) ?? '';
      if (callId.isEmpty || !summary.contains(callId)) continue;
      if (!seen.add(callId)) continue;
      carried.add({
        'turn': (e.data['turn'] as num?)?.toInt() ?? 0,
        'callId': callId,
      });
    }
    return carried;
  }

  /// 对在途压缩落显式作废事件（取消轮/退出会话/删轮等入口）。
  ///
  /// 表面没变≠取消后仍有提交资格——cancelRound 只取消令牌零账本事件，
  /// 投影/opId 可能全数未变；作废事件是唯一可靠的取消资格关闭。
  /// 返回是否已可靠作废（账面写入成功，或至少进程内拒绝标记已生效）。
  Future<bool> invalidateActive(String sessionId, String reason) async {
    final opId = _activeOps[sessionId];
    if (opId == null) return false;
    // 进程内拒绝标记先行：账面写入失败也不得继续提交
    _invalidatedOpIds.add(opId);
    try {
      await _events.appendAll(sessionId, [
        AgentDurableEvent(
          type: AgentEventTypes.compactionCancel,
          data: {'opId': opId, 'reason': reason},
        ),
      ]);
      return true;
    } catch (e) {
      _logger?.warn('Compaction invalidate write failed', detail: '$e');
      return false;
    } finally {
      // 只清理自身登记——期间新操作可能已注册
      if (_activeOps[sessionId] == opId) _activeOps.remove(sessionId);
    }
  }

  /// 压缩主流程（轮前 auto / 轮中溢出 overflow / 手动 manual）。
  ///
  /// [tools] 与主对话共享的工具定义（与模型/前缀同源——进入
  /// 摘要请求与完整预算面计量）。[tuning] 为调用方按会话配置解析的参数
  ///（配置单源=default_config.json；缺省回落构造注入/构造默认——测试
  /// 显式注入面）。
  Future<EngineeringCompactionResult> compact({
    required String sessionId,
    required String trigger,
    required int contextWindowTokens,
    required double retrievalRatio,
    List<ToolDefinition> tools = const [],
    EngineeringCompactionTuning? tuning,
    CancellationToken? cancelToken,
    void Function(String delta)? onDelta,
    // 完整预算面口径：出站 wire 选项（协议化思考表示按实际回传计入）与
    // 冻结前缀字符（不进投影但进请求，触发/选材估算不得漏计）
    AgentWireOptions wireOptions = const AgentWireOptions(),
    int frozenPrefixChars = 0,
  }) async {
    final effTuning = tuning ?? this.tuning;
    if (trigger == 'auto' && autoCompactionSuspended) {
      return const EngineeringCompactionResult(
        outcome: 'noop',
        reason: 'circuit-broken',
      );
    }
    // ── 选材（含超限降级重试一轮）────────────────────────────────
    var windowEvents = DirectorSurfaceV2.epochWindowEvents(
      await _events.readEvents(sessionId),
    );
    // rapid-refill 熔断（语义同 ZCode turn-loop-state）：距上次压缩不足 3 个工具
    // 步又触发 auto 压缩，连续 3 次→本轮阻断并报诊断（工具步自然累积
    // 后自愈，非永久停用）。manual 不受此闸约束。
    if (trigger == 'auto') {
      final toolSteps = _toolStepsSinceLastCheckpoint(windowEvents);
      if (toolSteps < kRapidRefillToolStepThreshold) {
        _consecutiveRapidRefills++;
        if (_consecutiveRapidRefills >= kMaxConsecutiveRapidRefills) {
          _logger?.warn(
            'Rapid-refill circuit breaker tripped',
            detail: 'consecutive=$_consecutiveRapidRefills, '
                'toolStepsSinceCompact=$toolSteps',
          );
          return const EngineeringCompactionResult(
            outcome: 'noop',
            reason: 'rapid-refill',
          );
        }
      } else {
        _consecutiveRapidRefills = 0;
      }
    }
    final toolsChars = toolDefinitionsChars(tools);
    var fold = deriveAgentSurfaceSpans(windowEvents);
    var plan = selectCompactionInterval(
      windowEvents: windowEvents,
      spans: fold.spans,
      projectionMessages: fold.projection.messages,
      contextWindowTokens: contextWindowTokens,
      tuning: effTuning,
      extraFixedChars: toolsChars + frozenPrefixChars,
      wireOptions: wireOptions,
    );
    if (plan == null) {
      return const EngineeringCompactionResult(
        outcome: 'noop',
        reason: 'empty-interval',
      );
    }
    if (plan.oversizedResultSeqs.isNotEmpty) {
      // 退出路径依赖：超限工具结果先 model-free 降级再重选
      await _degradeOversizedResults(
        sessionId,
        windowEvents,
        fold,
        plan,
        effTuning,
      );
      windowEvents = DirectorSurfaceV2.epochWindowEvents(
        await _events.readEvents(sessionId),
      );
      fold = deriveAgentSurfaceSpans(windowEvents);
      plan = selectCompactionInterval(
        windowEvents: windowEvents,
        spans: fold.spans,
        projectionMessages: fold.projection.messages,
        contextWindowTokens: contextWindowTokens,
        tuning: effTuning,
        extraFixedChars: toolsChars + frozenPrefixChars,
        wireOptions: wireOptions,
      );
      if (plan == null) {
        return const EngineeringCompactionResult(
          outcome: 'noop',
          reason: 'empty-after-degrade',
        );
      }
    }
    final surfaceDigest = projectionMessagesDigest(fold.projection.messages);
    final intervalMessages = fold.projection.messages.sublist(
      plan.projectionStart,
      plan.projectionEnd,
    );
    final intervalDigest = projectionMessagesDigest(intervalMessages);

    // ── phase1：操作标记（崩溃恢复标记；单独提交）────────────────
    final opId = 'cmp_${DateTime.now().millisecondsSinceEpoch}_'
        '${plan.startSeq}_${plan.endSeq}';
    _activeOps[sessionId] = opId;
    try {
      await _events.appendAll(sessionId, [
        AgentDurableEvent(
          type: AgentEventTypes.compactionStart,
          data: {
            'opId': opId,
            'trigger': trigger,
            'surfaceDigest': surfaceDigest,
            'intervalDigest': intervalDigest,
            'intervalSeqs': [plan.startSeq, plan.endSeq],
          },
        ),
      ]);
    } catch (_) {
      // start 标记落账失败：登记不留残（后续 compact 才能正常开新操作）
      _releaseActiveOp(sessionId, opId);
      rethrow;
    }

    // ── phase2：摘要调用（资格全由提交事务决定）──────────────────
    EngineeringSummaryOutput output;
    try {
      if (cancelToken?.isCancelled ?? false) {
        await _finishWithError(sessionId, opId, 'cancelled');
        _releaseActiveOp(sessionId, opId);
        return const EngineeringCompactionResult(outcome: 'cancelled');
      }
      output = await summarizer.summarize(
        sessionId: sessionId,
        intervalMessages: intervalMessages,
        narrativeBoundaryTurn: plan.narrativeBoundaryTurn ?? 0,
        tools: tools,
        onDelta: onDelta,
      );
      // 可检验承接解析：候选键=被压区间内真实证据
      // 回执（toolResult+retrievalEvidence），承接判定=摘要文本引用其
      // callId（投影回执带协议级 tool_call_id，模型可引用）。两者同时
      // 成立才入 evidenceCarried——捏造/不存在的键不入，未引用=未承接
      //（闸门按未核对处理，安全侧）。
      output = EngineeringSummaryOutput(
        summary: output.summary,
        narrativeSection: output.narrativeSection,
        carriedEvidence: _parseCarriedEvidence(
          output.summary,
          windowEvents,
          plan.shadowedSeqs,
        ),
        usage: output.usage,
      );
    } catch (e) {
      _logger?.warn('Engineering compaction summary failed', detail: '$e');
      // 响应已到达的失败（截断/带工具调用）同样把 usage 落痕
      final usage = e is EngineeringSummaryException ? e.usage : null;
      await _finishWithError(sessionId, opId, 'summary-error', usage: usage);
      _bumpFailure(trigger);
      _releaseActiveOp(sessionId, opId);
      return const EngineeringCompactionResult(
        outcome: 'failed',
        reason: 'summary-error',
      );
    }
    // 收缩校验（fail-closed）：framed ≥ shadowed 估算即拒（完整预算面
    // 口径——两侧同用 surfaceInputChars，含调用签名/回执）
    final framedEstimate = estimateTokensForChars(
      surfaceInputChars(
        [
          AgentMessage.system(
            '$kEngineeringCheckpointEnvelope\n${output.summary}',
          ),
        ],
        options: wireOptions,
      ),
      effTuning,
    );
    final shadowedEstimate = estimateTokensForChars(
      surfaceInputChars(intervalMessages, options: wireOptions),
      effTuning,
    );
    if (output.summary.isEmpty || framedEstimate >= shadowedEstimate) {
      await _finishWithError(
        sessionId,
        opId,
        'not-smaller',
        usage: output.usage,
      );
      _bumpFailure(trigger);
      _releaseActiveOp(sessionId, opId);
      return const EngineeringCompactionResult(
        outcome: 'failed',
        reason: 'not-smaller',
      );
    }

    // ── phase3′+phase4：事务内条件提交（校验与写入同一受保护单元）──
    final commit = await _commit(
      sessionId: sessionId,
      opId: opId,
      trigger: trigger,
      plan: plan,
      surfaceDigest: surfaceDigest,
      intervalDigest: intervalDigest,
      intervalMessages: intervalMessages,
      output: output,
      effTuning: effTuning,
      wireOptions: wireOptions,
    );
    _releaseActiveOp(sessionId, opId);
    if (commit != null) {
      // 提交被拒：只落自身失败原因，不动新状态（usage 已随响应到达——
      // 不论提交成败落痕）
      await _finishWithError(sessionId, opId, commit, usage: output.usage);
      // 摘要质量类拒绝计入熔断（结构类拒绝 superseded/surface-changed/
      // cancelled 不算失败——换一次时机即可）
      if (commit == 'narrative-section-missing') _bumpFailure(trigger);
      return EngineeringCompactionResult(outcome: commit);
    }
    if (trigger == 'auto') _consecutiveAutoFailures = 0;
    _logger?.info(
      'Engineering compaction committed',
      detail: 'sessionId=$sessionId, opId=$opId, trigger=$trigger, '
          'interval=${plan.startSeq}-${plan.endSeq}, '
          'narrativeTurn=${plan.narrativeBoundaryTurn}',
    );
    return EngineeringCompactionResult(
      outcome: 'committed',
      committed: true,
      shadowedTokenEstimate: shadowedEstimate,
      framedTokenEstimate: framedEstimate,
    );
  }

  void _bumpFailure(String trigger) {
    if (trigger == 'auto') _consecutiveAutoFailures++;
  }

  Future<void> _finishWithError(
    String sessionId,
    String opId,
    String error, {
    Map<String, dynamic>? usage,
  }) {
    return _events.appendAll(sessionId, [
      AgentDurableEvent(
        type: AgentEventTypes.compactionEnd,
        data: {
          'opId': opId,
          'error': error,
          // 摘要 usage 无论成败落痕（响应已到达时携带）
          if (usage != null) 'usage': usage,
        },
      ),
    ]);
  }

  /// 提交事务：四条件校验 + 三事件 + 正文三成果同库单事务。
  /// 返回 null=提交成功；否则为拒绝原因码（调用方落 end{error}）。
  Future<String?> _commit({
    required String sessionId,
    required String opId,
    required String trigger,
    required CompactionIntervalPlan plan,
    required String surfaceDigest,
    required String intervalDigest,
    required List<AgentMessage> intervalMessages,
    required EngineeringSummaryOutput output,
    required EngineeringCompactionTuning effTuning,
    required AgentWireOptions wireOptions,
  }) async {
    final rejection = <String?>[];
    try {
      await _database.transaction(() async {
        final events = await _events.readEvents(sessionId);
        final windowEvents = DirectorSurfaceV2.epochWindowEvents(events);
        final fold = deriveAgentSurfaceSpans(windowEvents);

        // 四条件（事务内重读校验）
        String? fail;
        if (projectionMessagesDigest(fold.projection.messages) !=
            surfaceDigest) {
          fail = 'surface-changed';
        } else if (plan.projectionEnd <= fold.projection.messages.length &&
            projectionMessagesDigest(
                  fold.projection.messages.sublist(
                    plan.projectionStart,
                    plan.projectionEnd,
                  ),
                ) !=
                intervalDigest) {
          fail = 'surface-changed';
        }
        var latestUnclosedOpId = '';
        var cancelled = false;
        for (final e in events) {
          if (e.type == AgentEventTypes.compactionStart) {
            final id = e.data['opId'];
            if (id is String) latestUnclosedOpId = id;
          } else if (e.type == AgentEventTypes.compactionEnd ||
              e.type == AgentEventTypes.compactionUndo) {
            final id = e.data['opId'] ?? e.data['targetOpId'];
            if (id is String && id == latestUnclosedOpId) {
              latestUnclosedOpId = '';
            }
          } else if (e.type == AgentEventTypes.compactionCancel) {
            if (e.data['opId'] == opId) cancelled = true;
          }
        }
        // 作废判定：账面作废记录 ∨ 进程内作废标记（落账失败的可靠兜底）
        cancelled = cancelled || _invalidatedOpIds.contains(opId);
        // 取消先于被取代：已作废的操作无论其后是否有新操作都按取消拒绝
        if (fail == null && cancelled) fail = 'cancelled';
        if (fail == null && latestUnclosedOpId != opId) fail = 'superseded';
        if (fail != null) {
          rejection.add(fail);
          throw _CommitRejected(fail);
        }

        // 正文资产守卫：区间含已完成轮时，摘要必须给出已完成剧情
        // 段——缺叙事段不得以工程全文兜底写叙事资产（fail-closed，零
        // 正文产物；重试或纯工程路径由上层按结果处理）
        final narrative = output.narrativeSection?.trim() ?? '';
        if (plan.narrativeBoundaryTurn != null && narrative.isEmpty) {
          rejection.add('narrative-section-missing');
          throw const _CommitRejected('narrative-section-missing');
        }

        // ── phase4：正文三成果（仅当区间含已完成轮）────────────────
        // 正文覆盖=区间内已完成且完整纳入本次摘要的轮（无未来内容、
        // 无覆盖扩大——boundaryMessageId 指向真实已落库消息，同事务可写）。
        String? summaryMessageId;
        String? boundaryMessageId;
        String? macroMemoryId;
        final boundaryTurn = plan.narrativeBoundaryTurn;
        if (boundaryTurn != null) {
          boundaryMessageId = await _resolveBoundaryMessageId(
            events,
            sessionId,
            boundaryTurn,
          );
          if (boundaryMessageId == null) {
            // binding 无 chatMessageId 且 chat 配对解析失败——宁可纯工程
            // checkpoint，不伪造 ID（正文侧零产物）
            rejection.add('boundary-unresolvable');
            throw const _CommitRejected('boundary-unresolvable');
          }
          final now = DateTime.now();
          summaryMessageId = 'eng-summary-${now.millisecondsSinceEpoch}-$opId';
          await _chat.addMessage(
            ChatMessage(
              messageId: summaryMessageId,
              sessionId: sessionId,
              role: 'system',
              content: narrative,
              createdAt: now,
              isSummary: true,
            ),
          );
          await _chat.addCompactionPoint(
            sessionId: sessionId,
            summaryMessageId: summaryMessageId,
            boundaryMessageId: boundaryMessageId,
            createdAt: now,
          );
          final macro = await _experience.appendMacroExperience(
            sessionId: sessionId,
            summary: narrative,
            importance: 3,
            tags: const ['compaction', 'macro_summary'],
            turnNumber: boundaryTurn,
            parentEventIds: const [],
            triggerReason: MacroTriggerReason.compaction,
          );
          macroMemoryId = macro.memoryId;
        }

        // ── agent_events 三事件（seq 连续分配）──────────────────────
        await _events.appendAll(sessionId, [
          AgentDurableEvent(
            type: AgentEventTypes.compactionSummary,
            data: {
              'opId': opId,
              'trigger': trigger,
              'shadowedSeqs': plan.shadowedSeqs,
              // 材料量口径：被压区间实际可回传表示的 token
              // 估算，不是消息条数差
              'shadowedTokenEstimate': estimateTokensForChars(
                surfaceInputChars(intervalMessages, options: wireOptions),
                effTuning,
              ),
              'framedTokenEstimate': estimateTokensForChars(
                surfaceInputChars(
                  [
                    AgentMessage.system(
                      '$kEngineeringCheckpointEnvelope\n${output.summary}',
                    ),
                  ],
                  options: wireOptions,
                ),
                effTuning,
              ),
              'evidenceCarried': output.carriedEvidence,
              // 摘要请求自身计量（成功路径落痕）
              if (output.usage != null) 'usage': output.usage,
              if (summaryMessageId != null)
                'narrativeBoundary': {
                  'summaryMessageId': summaryMessageId,
                  'boundaryMessageId': boundaryMessageId,
                  'macroMemoryId': macroMemoryId,
                  'turn': boundaryTurn,
                },
            },
          ),
          AgentDurableEvent(
            type: AgentEventTypes.userMessage,
            surfaceOp: AgentSurfaceOpKind.replace,
            replaceStart: plan.projectionStart,
            replaceEnd: plan.projectionEnd,
            sourceEventSeqs: plan.shadowedSeqs,
            data: {
              'content': '$kEngineeringCheckpointEnvelope\n${output.summary}',
              'source': 'compaction_checkpoint',
              'turn': boundaryTurn ?? 0,
              'opId': opId,
            },
          ),
          AgentDurableEvent(
            type: AgentEventTypes.compactionEnd,
            data: {'opId': opId},
          ),
        ]);
      });
    } on _CommitRejected {
      // 事务已整体回滚（四条件失配/写入异常）——调用方只落 end{error}
    }
    return rejection.isEmpty ? null : rejection.first;
  }

  /// 正文边界消息 ID：优先 binding 携带的 chatMessageId；旧数据回退
  /// chat 配对解析（user/assistant 位置配对推导轮号）。
  Future<String?> _resolveBoundaryMessageId(
    List<AgentDurableEvent> events,
    String sessionId,
    int boundaryTurn,
  ) async {
    String? fromBinding;
    for (final e in events.reversed) {
      if (e.type != AgentEventTypes.replayBinding) continue;
      if ((e.data['turn'] as num?)?.toInt() != boundaryTurn) continue;
      final id = e.data['chatMessageId'];
      if (id is String && id.isNotEmpty) {
        fromBinding = id;
        break;
      }
    }
    if (fromBinding != null) return fromBinding;
    // 回退：可见消息配对推导（压缩点过滤后的 user/assistant 对）
    try {
      final messages = await _chat.getMessages(sessionId);
      var turn = 0;
      for (final m in messages) {
        if (m.isSummary) continue;
        if (m.role == 'user') {
          turn++;
        }
        if (turn == boundaryTurn && m.role == 'assistant') {
          return m.messageId;
        }
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// 撤销最新一次压缩（全量撤销；按产物 ID 精确回退）。
  ///
  /// 约束：仅最新一次、其后不得有后续 compaction/branch/surface 结构
  /// 事件；纯工程 checkpoint（无正文产物）撤销不碰 chat 侧任何行，
  /// **禁盲删 compaction_points.last**。
  Future<bool> undo({required String sessionId}) async {
    return _database.transaction(() async {
      final events = await _events.readEvents(sessionId);
      // 最新未被撤销的 summary 事件
      AgentDurableEvent? latestSummary;
      for (final e in events) {
        if (e.type == AgentEventTypes.compactionSummary) {
          latestSummary = e;
        } else if (e.type == AgentEventTypes.compactionUndo) {
          final target = e.data['targetOpId'];
          if (latestSummary != null && target == latestSummary.data['opId']) {
            latestSummary = null;
          }
        }
      }
      if (latestSummary == null) return false;
      // 其后结构事件检查（该 summary 的 seq 之后）
      final summarySeq = latestSummary.seq ?? 0;
      final summaryOpId = latestSummary.data['opId'];
      for (final e in events) {
        final seq = e.seq ?? 0;
        if (seq <= summarySeq) continue;
        // 本 op 的 checkpoint/end 不算「后续结构事件」
        if (e.data['opId'] == summaryOpId) continue;
        final structural = e.type == AgentEventTypes.compactionSummary ||
            e.type == AgentEventTypes.compactionStart ||
            e.type == AgentEventTypes.branchRebuild ||
            e.surfaceOp == AgentSurfaceOpKind.replace;
        if (structural) {
          _logger?.warn(
            'Engineering compaction undo rejected: later structural events',
            detail: 'summarySeq=$summarySeq, blocking=${e.type}@${e.seq}',
          );
          return false;
        }
      }
      // 正文产物精确回退（narrativeBoundary 记录的 ID；缺任一→chat 侧
      // 零删除〔纯工程 checkpoint〕）
      final boundary = latestSummary.data['narrativeBoundary'];
      if (boundary is Map) {
        final summaryMessageId = boundary['summaryMessageId'];
        final macroMemoryId = boundary['macroMemoryId'];
        if (summaryMessageId is String && summaryMessageId.isNotEmpty) {
          await _chat.deleteCompactionPointBySummaryId(
            sessionId,
            summaryMessageId,
          );
          await _chat.deleteMessage(summaryMessageId);
        }
        if (macroMemoryId is String && macroMemoryId.isNotEmpty) {
          await _experience.deleteExperienceById(
            macroMemoryId,
            sessionId: sessionId,
          );
        }
      }
      // 恢复消息：剔除该 checkpoint 后重投影，取其原遮蔽区间——与压缩前
      // 逐条一致（checkpoint 之外的任何后续变化不受影响）。
      final targetOpId = latestSummary.data['opId'];
      final checkpoint = events.lastWhere(
        (e) =>
            e.type == AgentEventTypes.userMessage &&
            e.data['source'] == 'compaction_checkpoint' &&
            e.data['opId'] == targetOpId,
      );
      final withoutCheckpoint = [
        for (final e in events)
          if (!identical(e, checkpoint)) e,
      ];
      final restoredFold = deriveAgentSurfaceSpans(withoutCheckpoint);
      final restoreStart = checkpoint.replaceStart ?? 0;
      final restoreEnd = checkpoint.replaceEnd ?? restoreStart;
      final restoredMessages = restoreEnd <=
              restoredFold.projection.messages.length
          ? restoredFold.projection.messages.sublist(restoreStart, restoreEnd)
          : const <AgentMessage>[];
      // 当前 checkpoint 占位（undo 事件 replace 的目标区间）
      final currentFold = deriveAgentSurfaceSpans(events);
      var cpStart = -1;
      var cpEnd = -1;
      for (final span in currentFold.spans) {
        if (span.from < 0) continue;
        if (span.event.type != AgentEventTypes.userMessage) continue;
        if (span.event.data['opId'] != targetOpId) continue;
        cpStart = span.from;
        cpEnd = span.to;
        break;
      }
      await _events.appendAll(sessionId, [
        AgentDurableEvent(
          type: AgentEventTypes.compactionUndo,
          surfaceOp: cpStart >= 0 ? AgentSurfaceOpKind.replace : null,
          replaceStart: cpStart >= 0 ? cpStart : null,
          replaceEnd: cpStart >= 0 ? cpEnd : null,
          data: {
            'targetOpId': targetOpId,
            'targetStartSeq': summarySeq,
            'messages': [
              for (final m in restoredMessages) agentMessageToSurfaceData(m),
            ],
          },
        ),
      ]);
      return true;
    });
  }

  /// 超限工具结果的 model-free 降级：头 500 字+结论行+裁剪标记，
  /// tool/result 原位 replace（账本原文 shadowed 保留，可审计）。
  Future<void> _degradeOversizedResults(
    String sessionId,
    List<AgentDurableEvent> windowEvents,
    AgentSurfaceProjectionWithSpans fold,
    CompactionIntervalPlan plan,
    EngineeringCompactionTuning tuning,
  ) async {
    final degradeEvents = <AgentDurableEvent>[];
    for (final seq in plan.oversizedResultSeqs) {
      for (final span in fold.spans) {
        if (span.event.seq != seq || span.from < 0) continue;
        final output = span.event.data['output'];
        if (output is! String) continue;
        final head = output.substring(
          0,
          output.length < tuning.degradeHeadChars
              ? output.length
              : tuning.degradeHeadChars,
        );
        // 结论行：结果尾部最后一个非空行（检索回执的结论摘要惯居末行；
        // 纯转储类无可用结论则只有头段+裁剪标记，如实降级）
        final lines = output.trim().split('\n');
        final conclusion = lines.length > 1 ? lines.last.trim() : '';
        final degraded = conclusion.isNotEmpty
            ? '$head\n〔已裁剪：原文 ${output.length} 字符〕\n结论行：$conclusion'
            : '$head\n〔已裁剪：原文 ${output.length} 字符〕';
        degradeEvents.add(
          AgentDurableEvent(
            type: AgentEventTypes.toolResult,
            surfaceOp: AgentSurfaceOpKind.replace,
            replaceStart: span.from,
            replaceEnd: span.to,
            sourceEventSeqs: [seq],
            data: {
              ...span.event.data,
              'output': degraded,
              'pruned': true,
            },
          ),
        );
        break;
      }
    }
    if (degradeEvents.isEmpty) return;
    await _events.appendAll(sessionId, degradeEvents);
    _logger?.info(
      'Oversized tool results degraded (model-free)',
      detail: 'count=${degradeEvents.length}',
    );
  }
}

/// 提交被拒（事务内抛出→drift 整体回滚；调用方只落 end{error}）
class _CommitRejected implements Exception {
  const _CommitRejected(this.code);
  final String code;
}
