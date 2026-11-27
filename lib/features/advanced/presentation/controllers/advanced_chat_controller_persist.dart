// clang-format off
// coverage:ignore-file
// part of IntermediateChatController，仅拆分用途，不引入新逻辑。
// 详见 intermediate_chat_controller.dart 顶部说明。
//
//  拆分：extension 不是 StateNotifier 子类，访问 `state`
// 触发 invalid_use_of_protected_member / invalid_use_of_visible_for_testing_member。
// 这是 part + extension 拆分方案的固有约束，运行无误，文件级忽略。
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

part of 'advanced_chat_controller.dart';

/// persisting 阶段（P2 解耦：导演产物 agentSteps/agentWorkSummary/storyAnchor
/// 随 artifacts 同事务持久化；故事侧对应逻辑留在 intermediate 的 persist part）
///
/// 通过 extension 机制让方法仍属于 [AdvancedChatController] 类成员，
/// 可访问主文件中的私有字段（_logger / _persistenceService / state 等）。
extension AdvancedChatControllerPersist on AdvancedChatController {
  // ==================== persisting 阶段 ====================

  /// persisting 阶段（V2 六步流程，本地写入）
  ///
  /// V2 变更（Phase 6 Step 6.4）：从 [round] 读取 `replyText` / `eventSummary`，
  /// 不再通过方法参数传入（由 summarizing 阶段写入 round）。
  Future<void> _runPersistPhase(RoundContext round) async {
    // 待发按钮可能在最后一个模型响应返回时仍在等写入。
    await _queueWrite;
    // 取消检查点：persisting 入口
    // _round 身份验证 + isCancelled 双重检查；任务二维护期已锁定正文时放行收敛提交
    final allowMaintenanceConvergence = state.inMaintenancePhase &&
        (round.replyText?.trim().isNotEmpty ?? false);
    if (!mounted ||
        (_streamRunner.isCancelled && !allowMaintenanceConvergence) ||
        _round != round) {
      return;
    }

    final eventSummary = round.eventSummary!;
    final reply = round.replyText ?? '';
    final now = DateTime.now();
    final isRegenerate = state.regenerateTurnNumber != null;
    //  turn 单一事实源：本轮 turnNumber 轮前已一次定值
    // （重生成 = regenerateTurnNumber；普通 = next_turn ?? 公式），
    // persist 复用同一值——与故事模式同口径，消灭轮前/轮后双公式分裂
    // 。
    final turnNumber =
        isRegenerate ? state.regenerateTurnNumber! : round.turnNumber;

    final assistantMsg = ChatMessage(
      messageId: AdvancedChatController._uuid.v4(),
      sessionId: state.session.sessionId,
      role: 'assistant',
      content: reply,
      createdAt: now,
      thinkingContent: round.thinkingContent,
    );
    // 普通场景才创建 userMsg（重新生成场景 user_N 已存在）
    final userMsg = isRegenerate
        ? null
        : ChatMessage(
            messageId: AdvancedChatController._uuid.v4(),
            sessionId: state.session.sessionId,
            role: 'user',
            content: state.userInput ?? '',
            createdAt: now,
          );

    //  + DOC-10 §8.2 两级向量化策略：
    // - importance < importanceStorageThreshold(3)：不建 FTS5、不建 embedding（仅留原始记录）
    // - importanceStorageThreshold(3) <= importance < microVectorizeThreshold(4)：仅建 FTS5
    // - importance >= microVectorizeThreshold(4)：建 FTS5 + embedding
    final importanceStorageThreshold =
        round.config.retrieval.importanceStorageThreshold;
    final microVectorizeThreshold =
        round.config.retrieval.microVectorizeThreshold;
    final importanceBelowStorageThreshold =
        eventSummary.importance < importanceStorageThreshold;
    final shouldVectorize = eventSummary.importance >= microVectorizeThreshold;
    // V1：embedding 配置未配置 → embedding=null → has_embedding=false（FTS5 兜底）
    // v0.2 Phase C 方案二：embedding 输入从 summary 单字段改为拼接 5W1E 6 字段
    // （+ summary 兜底），让向量更准确反映事件全貌。
    // persist 嵌入是收稿后的后台向量化，
    // 失败一律自动降级 has_embedding=false（FTS5 检索兜底已存在）+ durable
    // 事件留痕，绝不阻断收稿—— 的「正在落幕…」假死即源于此调用
    // 失败沿 runRound 逃逸（曾收口为 E104+手动降级出口，2026-09-08
    // 改为自动降级；E104 出口仍由检索侧 _resolveQueryVector 链路触达）。
    // 20s 硬超时兜住服务层超时配置异常大的病态情形。
    Float32List? embedding;
    String? embeddingDegradedError;
    if (importanceBelowStorageThreshold || !shouldVectorize) {
      embedding = null;
    } else {
      try {
        embedding = await _resolveEmbedding(
          _buildEmbeddingText(eventSummary),
        ).timeout(const Duration(seconds: 20));
      } catch (e, stackTrace) {
        embedding = null;
        embeddingDegradedError = e.toString();
        _logger.warn(
          'Persist embedding degraded (has_embedding=false)',
          detail: '$e\n$stackTrace',
        );
      }
    }

    // 轮次身份验证：embedding 是网络调用，期间用户可能 cancel + 发送新消息，
    // 导致 _round 被替换为新轮次。若身份不匹配则中止旧轮次的持久化，
    // 防止用旧 assistantMsg + 新 state 覆盖数据库和 UI 状态。
    if (_round != round) return;

    if (embeddingDegradedError != null) {
      await _appendPersistEmbeddingDegradedEvent(
        turnNumber: turnNumber,
        errorText: embeddingDegradedError,
      );
    }

    // 压缩宏摘要向量化——文本口径
    // 与 _persistCompactionInTransaction 的 macro 落库一致。降级口径同上方
    // persist 嵌入：失败降级 null + warn + durable 事件留痕，绝不
    // 阻断收稿（FTS5 兜底，重建向量索引可补）。
    Float32List? macroEmbedding;
    if (round.compactionSummaryMessage != null &&
        round.compactionBoundaryMessageId != null) {
      try {
        macroEmbedding = await _resolveEmbedding(
          round.segmentMacroSummary ??
              round.compactionSummaryMessage!.content ??
              '',
        ).timeout(const Duration(seconds: 20));
      } catch (e, stackTrace) {
        macroEmbedding = null;
        _logger.warn(
          'Macro summary embedding degraded (has_embedding=false)',
          detail: '$e\n$stackTrace',
        );
        await _appendPersistEmbeddingDegradedEvent(
          turnNumber: turnNumber,
          errorText: '[macro] $e',
        );
      }
      if (!mounted || _round != round) return;
    }

    final indexForRetrieval = !importanceBelowStorageThreshold;

    // 构造本轮中间产物快照（生成内容/关键词/检索结果），持久化到独立表
    // 使历史轮次的小窗在切换会话或重新进入时仍可见
    // 从 round（不可变快照）读取，而非 state（可能已被新轮次替换）
    // v0.2.2 新增：记录本轮是否执行了 reviewing 阶段，供 UI 判断 idle 时
    // 是否显示 GeneratePanel（reviewExecuted=false 时不显示，生成即最终无对比价值）
    final artifacts = StoryRoundArtifacts(
      sessionId: state.session.sessionId,
      turnNumber: turnNumber,
      generatedText: round.generatedText,
      extractedKeywords: round.keywords?.flatten() ?? const [],
      retrievedMemories:
          round.scoredMemories?.map((m) => m.memory).toList() ?? const [],
      retrievedFacts: round.retrievedFacts?.facts ?? const [],
      replyText: reply,
      eventSummary: eventSummary,
      // v0.3 导演模式：本轮 agent 工具步骤随 artifacts 持久化，历史轮次
      // 重新进入时按 opencode 时间线重建工具卡（故事模式恒为空列表）。
      // DD1 不变量：轮已结束 → 任何 running 步骤归一为 done 再落库，
      // 否则历史轮（含重启后）会渲染出永久 spinner。
      agentSteps: AgentWorkStep.normalizeTerminal(state.agentSteps),
      // 对话流计划 ：轮时间线（思考/播报/动作交错）随 artifacts 双写，
      // 历史轮优先按此渲染单一折叠组；旧会话缺列回退 agentSteps 渲染。
      agentTimeline: AgentTimelineBlock.normalizeTerminalActions(
        state.agentTimeline,
      ),
      // 体验重构 ：工作摘要（步数/token/总时长）同步持久化，供历史轮次
      // L1 过程汇总行显示时长（故事模式恒为 null）。
      agentWorkSummary: state.agentWorkSummary,
      // 体验重构卡片 C：该轮结束时的剧情锚快照（更新值或继承值）
      storyAnchor: state.agentStoryAnchor,
      reviewExecuted: _shouldReview(round),
      createdAt: now,
    );

    // 若本轮触发了 CompactionPoint 压缩，构建持久化数据
    // 传给 persistRound / persistRegeneratedRound 在同一事务内写入
    // （chat_messages + compaction_points + experiential_memories macro）
    final compaction = round.compactionSummaryMessage != null &&
            round.compactionBoundaryMessageId != null
        ? CompactionPersistenceData(
            summaryMessage: round.compactionSummaryMessage!,
            boundaryMessageId: round.compactionBoundaryMessageId!,
            turnNumber: turnNumber,
            segmentMacroSummary: round.segmentMacroSummary,
            macroEmbedding: macroEmbedding,
          )
        : null;

    try {
      final turns = {turnNumber};
      final sessionId = assistantMsg.sessionId;
      _historyRevision++;
      final PersistRoundResult persistResult;
      if (userMsg == null) {
        // 重生成保留原 user，新稿成为下一变体。
        persistResult = await _persistenceService.persistRegeneratedRound(
          assistantMessage: assistantMsg,
          eventSummary: eventSummary,
          embedding: embedding,
          artifacts: artifacts,
          indexForRetrieval: indexForRetrieval,
          factsDeltas: round.factsDeltas,
          factualConfig: round.config.memory.factual,
          compaction: compaction,
          recordVariant: true,
          variantSourceInput: round.userInput,
        );
      } else {
        // 普通发送和编辑重发写入消息对；重发时已有旧稿快照。
        Future<PersistRoundResult> persist() =>
            _persistenceService.persistRound(
              userMessage: userMsg,
              assistantMessage: assistantMsg,
              eventSummary: eventSummary,
              embedding: embedding,
              artifacts: artifacts,
              indexForRetrieval: indexForRetrieval,
              factsDeltas: round.factsDeltas,
              factualConfig: round.config.memory.factual,
              compaction: compaction,
              variantSourceInput: round.userInput,
            );
        if (_retainedInput == round.userInput) {
          persistResult = await _runHistoryTransaction(() async {
            final result = await persist();
            await _chatRepository.clearDirectorPendingInputIfMatches(
              sessionId,
              round.userInput,
            );
            return result;
          });
          _retainedInput = null;
        } else {
          persistResult = await persist();
        }
      }
      // 轮次身份验证：DB 写入是 async，期间用户可能 cancel + 发新消息
      if (!mounted || _round != round) return;

      // 叙事时间已在 persistRound / persistRegeneratedRound 事务内更新
      // （2026-08-05 从此处移入事务，避免"消息成功但叙事时间失败"的不一致状态）

      // 事实层已在 persistRound / persistRegeneratedRound 事务内应用。
      // 数据库级异常仍会使事务回滚；单条非法/不安全 delta 由 FactApplier 记录并
      // 跳过，不影响同轮消息与经历记忆持久化。
      // 日志：persist 成功后记录事实层应用结果（默认输出，便于排查事实层问题）
      if (persistResult.factsChanges.isNotEmpty) {
        _logger.info(
          'Facts applied (in transaction)',
          detail: 'count=${persistResult.factsChanges.length}',
        );
      } else {
        _logger.info(
          'Facts not applied (no deltas)',
          detail: 'turn=$turnNumber（本轮无事实变更或 LLM 未调用 extract_facts）',
        );
      }

      // v0.2.3：独立宏摘要阶段已完全移除。
      // 宏摘要现在由压缩服务在压缩时生成分段宏摘要，通过 CompactionPersistenceData
      // 在同一事务内写入 experiential_memories，无需 persisting 后额外触发。

      // 更新 messages：重新生成只追加 assistant；普通场景追加 user+assistant
      final newMessages = userMsg != null
          ? [...state.messages, userMsg, assistantMsg]
          : [...state.messages, assistantMsg];

      // 仅刷新本轮变体。正文与事实已经提交，读回失败时仍正常收稿。
      StoryHistoryTurnDetails? detail;
      try {
        detail = await _readHistoryDetails(sessionId, turns);
      } catch (error) {
        _logger.warn(
          'Reload variants after persist failed',
          detail: 'errorType=${error.runtimeType}',
        );
      }
      if (!mounted || _round != round) return;
      final updatedVariantsByTurn = detail == null
          ? state.variantsByTurn
          : _replaceHistoryRows(state.variantsByTurn, turns, detail.variants);
      final newVariantIndex =
          detail?.artifacts[turnNumber]?.currentVariantIndex ??
              detail?.variants[turnNumber]?.lastOrNull?.variantIndex;

      // 把本轮 artifacts 写入 state.artifactsByTurnNumber
      // 重新生成场景：覆盖原 turnNumber 的 entry；普通场景：新增 entry
      final updatedArtifacts = Map<int, StoryRoundArtifacts>.from(
        state.artifactsByTurnNumber ?? const {},
      )..[turnNumber] = artifacts.copyWithFactsChanges(
          persistResult.factsChanges,
          currentVariantIndex: newVariantIndex,
        );

      // 刚完成请求的实报输入不含本轮新回复；下一轮请求会带上它。
      // 按同一材料边界增量调整「当前预计」并保持 estimated，不能让已完成
      // 的输入原样冒充下一次预计。
      final replyText = assistantMsg.content ?? '';

      // 正文版本绑定留痕（生成事实，入账后不可改写）：persist 成功即写
      // ——变体切换的身份核对（先 attemptId 后 proseHash）与证据资格判定
      // 读它。写失败不阻断收稿（留痕缺失时切换按保守遮蔽、证据按未核对）。
      final bindingAttemptId = _directorRunner.currentAttemptId;
      if (bindingAttemptId != null && detail != null) {
        try {
          await agentEventLogRepository?.appendAll(
            sessionId,
            [
              replayBindingEvent(
                turn: turnNumber,
                attemptId: bindingAttemptId,
                variantIndex: newVariantIndex ?? 0,
                prose: replyText,
                userInput: round.userInput,
                chatMessageId: assistantMsg.messageId,
              ),
            ],
          );
        } catch (e) {
          _logger.warn('Replay binding ledger write failed', detail: '$e');
        }
      }
      if (!mounted ||
          !identical(_round, round) ||
          state.session.sessionId != sessionId) {
        return;
      }
      final engineeringOpen =
          state.engineeringMode == EngineeringRuntimeMode.normalOpen;
      var carriedEstimate = state.contextEstimate;
      // 工程模式由轮运行器按最终投影估算。关闭态的正文已提交，估算失败
      // 时下一次请求的用量显示未知，保留本轮实报及收稿反馈。
      if (!engineeringOpen && replyText.isNotEmpty) {
        try {
          final replyTokens = await _tokenCounter.countTokens(replyText);
          if (replyTokens > 0) {
            carriedEstimate = carriedEstimate?.shift(
              removedTokens: 0,
              addedTokens: replyTokens,
              at: DateTime.now(),
            );
          }
        } catch (error) {
          _logger.warn(
            'Estimate committed director reply failed',
            detail: 'errorType=${error.runtimeType}',
          );
          carriedEstimate = const ContextUsageEstimate.unknown();
        }
        if (!mounted ||
            !identical(_round, round) ||
            state.session.sessionId != sessionId) {
          return;
        }
      }
      // 构成图同步到同一材料修订：历史段按落库后的完整消息重建；上一轮
      // 指令已随用户消息迁入历史，下一轮指令尚未产生，清空以免重复计入。
      // 工程上下文模式（开启态）：构成图在轮尾由 runner 按最终投影单点
      // 闭合（含本轮工具轨迹/正文）；此处不再按「旧基线+reply」
      // 部分覆写（会漏本轮工作且被闭合值立即取代）。
      final carriedChars = state.contextSegmentChars == null
          ? null
          : engineeringOpen
              ? null
              : {
                  ...state.contextSegmentChars!,
                  'history': newMessages.fold<int>(
                    0,
                    (sum, m) => sum + (m.content?.length ?? 0),
                  ),
                  'directive': 0,
                };

      final summaries = state.usageSummariesByTurn;
      if (detail != null) {
        _loadedHistoryTurns.add(turnNumber);
      } else {
        _loadedHistoryTurns.remove(turnNumber);
      }
      state = state.copyWith(
        phase: IntermediatePhase.idle,
        factWriteWarning: persistResult.factWriteFailureCount > 0
            ? (
                turnNumber: turnNumber,
                count: persistResult.factWriteFailureCount
              )
            : null,
        messages: newMessages,
        // + 修复：同步刷新 session.messageCount，避免下游依赖
        // （如消息窗口判定 / 历史会话卡片显示）拿到过期值。
        // 与 regenerateMessage / editAndResend / deleteRound 风格一致。
        session: state.session.copyWith(
          messageCount: newMessages.length,
          // 同步叙事时间（已在事务内更新到 DB，此处同步到内存 state）
          currentNarrativeTime:
              eventSummary.narrativeTime ?? state.session.currentNarrativeTime,
          // 体验重构卡片 C：同步剧情锚（事务内已更新到 DB）
          storyAnchor: state.agentStoryAnchor ?? state.session.storyAnchor,
          // 镜像 next_turn 计数器（persist 事务已写 DB，此处同步内存）
          nextTurn: turnNumber + 1,
        ),
        liveBlocks: const [],
        userInput: null,
        regenerateTurnNumber: null, // 清空重新生成标识
        // persist 成功即本轮闭环，重置跨轮降级标记。
        // 字段文档承诺「persist 成功或清空时重置」，此前成功 copyWith 漏带，
        // 降级轮之后所有轮次永久跳过 embedding（语义检索静默失效）。
        embeddingDegradedForRound: false,
        retryCounts: {},
        artifactsByTurnNumber: updatedArtifacts, // 保留本轮 artifacts
        usageSummariesByTurn: summaries == null
            ? null
            : {...summaries, turnNumber: artifacts.agentWorkSummary},
        // 当前预计按新回复材料增量调整（reported → estimated）
        contextEstimate: carriedEstimate,
        contextSegmentChars: carriedChars,
        // 收稿同步内存变体表（DB 为准，切换器立即可达）
        variantsByTurn: updatedVariantsByTurn,
        // 新轮 summary 自带 lastPromptTokens（上下文用量指示 §3.2），
        // 旧会话回填值作废
        backfilledPromptTokens: null,
        backfilledCacheReadTokens: null,
        backfilledTotalInputTokens: null,
        backfilledUsageWarnings: null,
        // v0.3 导演模式：本轮工具步骤已随 artifacts 持久化，清空 live 列表，
        // 避免时间线渲染时既按 artifacts 画一遍、又按 live agentSteps 追加一遍。
        clearAgentSteps: true,
        agentWorkSummary: null,
        // Stage 3：清空 pendingUserMessage（已落入 state.messages）
        pendingUserMessage: null,
        // 重生成轮收稿 → 切换器高亮 2s（Chatbox 式新变体提示）
        variantFlashTurn: isRegenerate ? turnNumber : null,
        // 起表时刻随收稿写入——行物化
        // 早晚只影响剩余高亮时长，不再与收稿时刻脱钩
        variantFlashStartedAtMs:
            isRegenerate ? DateTime.now().millisecondsSinceEpoch : null,
      );
      // 轮次完成，清理上下文
      _round = null;

      // 事件日志收尾也属于当前轮。由操作释放时启动待发轮。
      _dispatchQueuedOnRelease =
          state.queuedMessage != null && !_streamRunner.isCancelled;

      // 首轮 persist 成功后异步生成会话标题（不阻塞 UI）
      // 仅普通发送场景（非重新生成）+ 首轮 + titleGenerator 已注入时触发
      // 2026-07-21 重构：标题生成独立于业务模型，统一走 common.title_model 配置
      if (!isRegenerate && turnNumber == 1 && _titleGenerator != null) {
        unawaited(
          _sessionOperations.runBackgroundWrite(
            () => _autoNameSession(
              userInput: round.userInput,
              assistantReply: reply,
            ),
          ),
        );
      }

      //  上下文超阈值时异步触发批量记忆提炼（不阻塞 UI）
      // 仅普通发送场景（非重新生成）+ consolidator 已注入时触发。
      // 重新生成会删除下游记忆（context 收缩），无需触发提炼。
      if (!isRegenerate && _consolidator != null) {
        unawaited(
          _sessionOperations.runBackgroundWrite(
            () => _maybeConsolidateMemories(
              contextWindow: round.contextWindow,
              maxTokens: _outputTokenReserveFor(
                round.settings.maxTokens,
                modelMaxOutput: round.generatingNamingConfig.maxOutputTokens,
              ),
              consolidationConfig: round.config.consolidation,
              namingConfig: round.namingConfig,
              embeddingConfig: round.embeddingConfig,
              consolidationPrompt: round.config.prompts.consolidationPrompt,
            ),
          ),
        );
      }
    } catch (e, stackTrace) {
      _logger.error(
        'Persist failed',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      await _fail(
        IntermediatePhase.persisting,
        'E018',
        error: e,
        errorCategory: ErrorCategory.persist,
        config: _round?.config,
      );
    }
  }

  /// persist 嵌入降级 durable 留痕（log-only，不进 surface 投影，
  /// 轨迹页可查；data 带 turn 供按轮清理）。写入失败仅记日志——留痕是
  /// 卫生动作，绝不影响收稿。
  Future<void> _appendPersistEmbeddingDegradedEvent({
    required int turnNumber,
    required String errorText,
  }) async {
    final repo = agentEventLogRepository;
    if (repo == null) return;
    try {
      await repo.appendAll(state.session.sessionId, [
        AgentDurableEvent(
          type: AgentEventTypes.persistEmbeddingDegraded,
          data: {
            'turn': turnNumber,
            'error': errorText.length > 200
                ? '${errorText.substring(0, 200)}…'
                : errorText,
          },
        ),
      ]);
    } catch (e) {
      _logger.warn(
        'Persist embedding degraded event append failed',
        detail: '$e',
      );
    }
  }
}

/// 本轮是否启用审查（与故事模式同源计算，artifacts.reviewExecuted 对齐）
///
/// 原为故事 phases part 的私有辅助，导演 artifacts 的 review_executed 列
/// 沿用同一计算保持历史数据连续。
bool _shouldReview(RoundContext round) {
  return round.settings.reviewEnabledOverride ?? round.config.reviewEnabled;
}

int _outputTokenReserveFor(
  int configured, {
  int? modelMaxOutput,
}) =>
    OutputTokenPolicy.contextReserve(
      configured: configured,
      modelMaxOutput: modelMaxOutput,
    );
