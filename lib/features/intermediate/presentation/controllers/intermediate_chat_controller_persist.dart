// clang-format off
// coverage:ignore-file
// part of IntermediateChatController，仅拆分用途，不引入新逻辑。
// 详见 intermediate_chat_controller.dart 顶部说明。
//
//  拆分：extension 不是 StateNotifier 子类，访问 `state`
// 触发 invalid_use_of_protected_member / invalid_use_of_visible_for_testing_member。
// 这是 part + extension 拆分方案的固有约束，运行无误，文件级忽略。
// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member

part of 'intermediate_chat_controller.dart';

/// 拆分到本 part 文件的 persisting 阶段方法（拆分）
///
/// 通过 extension 机制让方法仍属于 [IntermediateChatController] 类成员，
/// 可访问主文件中的私有字段（_logger / _persistenceService / state 等）。
extension IntermediateChatControllerPersist on IntermediateChatController {
  // ==================== persisting 阶段 ====================

  /// persisting 阶段（V2 六步流程，本地写入）
  ///
  /// V2 变更（Phase 6 Step 6.4）：从 [round] 读取 `replyText` / `eventSummary`，
  /// 不再通过方法参数传入（由 summarizing 阶段写入 round）。
  Future<void> _runPersistPhase(RoundContext round) async {
    // 取消检查点：persisting 入口
    // _round 身份验证 + isCancelled 双重检查
    if (_streamRunner.isCancelled || _round != round) return;

    final eventSummary = round.eventSummary!;
    final reply = round.replyText ?? '';
    final now = DateTime.now();
    final isRegenerate = state.regenerateTurnNumber != null;
    //  turn 单一事实源：本轮 turnNumber 轮前已在 [_prepareAndRunRound]
    // 一次定值（重生成 = regenerateTurnNumber；普通 = next_turn ?? 公式），
    // persist 复用同一值——消灭旧「轮前算 eventSummary、轮后按压缩视图重算
    // artifacts/compaction」的双轮号分裂：
    // 压缩当轮起两套公式互相一致但都与真实轮号差 1，与上一轮经历记忆撞号。
    final turnNumber =
        isRegenerate ? state.regenerateTurnNumber! : round.turnNumber;

    final assistantMsg = ChatMessage(
      messageId: IntermediateChatController._uuid.v4(),
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
            messageId: IntermediateChatController._uuid.v4(),
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
    //  修复：嵌入失败单独捕获映射 E104。
    // 此前该调用在 try 块之外，异常冒泡到 summarizing 的 catch-all 被误报为
    // E017"摘要生成失败"——用户既看不到真实原因，也拿不到 E104 专属的
    // "临时降级继续"出口（FailureBar 仅对 E104 展示该按钮）。
    final Float32List? embedding;
    if (importanceBelowStorageThreshold || !shouldVectorize) {
      embedding = null;
    } else {
      try {
        embedding = await _resolveEmbedding(_buildEmbeddingText(eventSummary));
      } on EmbeddingCallFailedException catch (e, stackTrace) {
        _logger.error(
          'Persist embedding failed',
          detail: '$e',
          error: e,
          stackTrace: stackTrace,
        );
        await _fail(
          IntermediatePhase.persisting,
          'E104',
          error: e,
          config: round.config,
        );
        return;
      } on EmbeddingRateLimitedException catch (e, stackTrace) {
        // 429 限流与调用失败是兄弟异常类
        //（无继承关系），此前恰好逃出此 catch 落进 summarizing 的
        // catch-all 被误报为 E017——embedding 最常见的失败形态反而
        // 拿不到 E104 的"临时降级"出口。
        _logger.error(
          'Persist embedding rate-limited',
          detail: '$e',
          error: e,
          stackTrace: stackTrace,
        );
        await _fail(
          IntermediatePhase.persisting,
          'E104',
          error: e,
          config: round.config,
        );
        return;
      }
    }

    // 轮次身份验证：embedding 是网络调用，期间用户可能 cancel + 发送新消息，
    // 导致 _round 被替换为新轮次。若身份不匹配则中止旧轮次的持久化，
    // 防止用旧 assistantMsg + 新 state 覆盖数据库和 UI 状态。
    if (_round != round) return;

    // 压缩宏摘要向量化——文本口径
    // 与 _persistCompactionInTransaction 的 macro 落库一致（分段宏摘要优先，
    // 回退压缩摘要全文）。失败一律降级 null + warn，不阻断收稿（FTS5 兜底，
    // 重建向量索引可补）；未配置/本轮降级时 _resolveEmbedding 直接返回 null。
    Float32List? macroEmbedding;
    if (round.compactionSummaryMessage != null &&
        round.compactionBoundaryMessageId != null) {
      try {
        macroEmbedding = await _resolveEmbedding(
          round.segmentMacroSummary ??
              round.compactionSummaryMessage!.content ??
              '',
        );
      } catch (e) {
        _logger.warn(
          'Macro summary embedding failed, degrade to null',
          detail: '$e',
        );
      }
      if (_round != round) return;
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
      // v0.3 导演模式：agent 步骤/摘要/剧情锚三列由导演侧写入；
      // 故事模式省略（构造默认：空列表 / null / null）。
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
      final PersistRoundResult persistResult;
      if (isRegenerate) {
        //  重新生成：user_N 已存在，只写 assistant + 事件摘要
        // 事实层 deltas 同事务写入（DOC-11 §8.2， 修复 2026-07-20）
        persistResult = await _persistenceService.persistRegeneratedRound(
          assistantMessage: assistantMsg,
          eventSummary: eventSummary,
          embedding: embedding,
          artifacts: artifacts,
          indexForRetrieval: indexForRetrieval,
          factsDeltas: round.factsDeltas,
          factualConfig: round.config.memory.factual,
          compaction: compaction,
          // 新版记为下一变体并移指针
          //（旧版已在删除阶段前快照）
          recordVariant: true,
          variantSourceInput: round.userInput,
          hasVerifiedSourceTurn: true,
        );
      } else {
        // 普通发送/编辑重发：写 user + assistant + 事件摘要
        // 事实层 deltas 同事务写入（DOC-11 §8.2， 修复 2026-07-20）
        // 编辑重发时旧版已在删除阶段前快照为变体行，service 侧按
        // 「该轮已存在变体行」自动把新内容记为变体并移指针。
        persistResult = await _persistenceService.persistRound(
          userMessage: userMsg!,
          assistantMessage: assistantMsg,
          eventSummary: eventSummary,
          embedding: embedding,
          artifacts: artifacts,
          indexForRetrieval: indexForRetrieval,
          factsDeltas: round.factsDeltas,
          factualConfig: round.config.memory.factual,
          compaction: compaction,
          variantSourceInput: round.userInput,
          hasVerifiedSourceTurn: true,
        );
      }
      // 轮次身份验证：DB 写入是 async，期间用户可能 cancel + 发新消息
      if (!mounted || state.session.sessionId != assistantMsg.sessionId) return;
      if (_round != round) {
        // (c)：事务已提交但身份已丢失（后台复位/取消清空了 _round）
        // ——DB 是完整的，仅内存态落后。若没有新一轮接管，重载历史让
        // 「第 N 轮 · 摘要已生成」等完成态回到 UI（否则重进会话才自愈）。
        await _resyncAfterCommittedPersistLoss(turnNumber);
        return;
      }

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

      // 收稿后刷新内存变体面——
      // variantsByTurn 此前只有 loadHistory/切换/删除三个写点，重生成收稿
      // 既不重载变体表也不回写指针（内存 artifacts 构造时
      // currentVariantIndex 默认 null，DB 指针由 service 内 UPDATE 完成不
      // 回传），首刷重生成后切换器（variants.length>1 && 指针非 null）不
      // 渲染。每轮一次轻查（变体行小、loadHistory 同款全量读），同时覆盖
      // 编辑重发路径（旧版变体由删除阶段保留在 DB）。读失败降级保持现
      // 状内存面（下次 loadHistory 收敛），不失败收稿。
      Map<int, List<MessageVariantRecord>>? reloadedVariants;
      int? newVariantIndex;
      try {
        reloadedVariants = await _persistenceService.loadMessageVariants(
          assistantMsg.sessionId,
        );
        final turnVariants =
            reloadedVariants[turnNumber] ?? const <MessageVariantRecord>[];
        // 编辑重发轮该轮也有变体行（service 侧已记录+移指针），
        // 与重生成同取最新变体序号；普通发送轮变体表为空不受影响。
        newVariantIndex =
            turnVariants.isNotEmpty ? turnVariants.last.variantIndex : null;
      } catch (e) {
        _logger.warn('Reload variants after persist failed', detail: '$e');
      }
      if (!mounted || state.session.sessionId != assistantMsg.sessionId) return;
      if (_round != round) {
        await _resyncAfterCommittedPersistLoss(turnNumber);
        return;
      }

      // 把本轮 artifacts 写入 state.artifactsByTurnNumber
      // 重新生成场景：覆盖原 turnNumber 的 entry；普通场景：新增 entry
      final updatedArtifacts = Map<int, StoryRoundArtifacts>.from(
        state.artifactsByTurnNumber ?? const {},
      )..[turnNumber] = artifacts.copyWithFactsChanges(
          persistResult.factsChanges,
          currentVariantIndex: newVariantIndex,
        );

      // 刚完成请求的实报输入不含本轮新回复；下一轮会带上它。按同一
      // 材料边界增量调整当前预计并降级为 estimated。
      var carriedEstimate = state.contextEstimate;
      if (reply.isNotEmpty) {
        try {
          final replyTokens = await _tokenCounter.countTokens(reply);
          if (replyTokens > 0) {
            carriedEstimate = carriedEstimate?.shift(
              removedTokens: 0,
              addedTokens: replyTokens,
              at: DateTime.now(),
            );
          }
        } catch (error) {
          // 事务已提交；新回复无法计量时，下一次请求的预计用量未知。
          _logger.warn(
            'Reply token estimate failed after commit',
            detail: 'type=${error.runtimeType}',
          );
          carriedEstimate = const ContextUsageEstimate.unknown();
        }
        if (!mounted || state.session.sessionId != assistantMsg.sessionId) {
          return;
        }
        if (_round != round) {
          await _resyncAfterCommittedPersistLoss(turnNumber);
          return;
        }
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
        contextEstimate: carriedEstimate,
        // + 修复：同步刷新 session.messageCount，避免下游依赖
        // （如 canOperateMessage / 历史会话卡片显示）拿到过期值。
        // 与 regenerateMessage / editAndResend / deleteRound 风格一致。
        // 镜像 next_turn 计数器（persist 事务已写 DB，此处同步内存）。
        session: state.session.copyWith(
          messageCount: newMessages.length,
          // 同步叙事时间（已在事务内更新到 DB，此处同步到内存 state）
          currentNarrativeTime:
              eventSummary.narrativeTime ?? state.session.currentNarrativeTime,
          nextTurn: turnNumber + 1,
        ),
        streamingGenerated: null,
        extractedKeywords: null,
        retrievedMemories: null,
        // 轮内中间态字段全家清空——
        // classifiedKeywords/retrievedFacts/两 thinking 字段此前残留到
        // 下一轮开始（世界状态条事实槽重进会话即消失，生命周期不一致；
        // 检索面板/思考区块读的是 artifacts，清空无显示损失）。
        classifiedKeywords: null,
        retrievedFacts: null,
        streamingGeneratedThinking: null,
        streamingReply: null,
        streamingReplyThinking: null,
        currentEventSummary: null,
        currentFactsChanges: null,
        generatedText: null,
        userInput: null,
        regenerateTurnNumber: null, // 清空重新生成标识
        // persist 成功即本轮闭环，重置跨轮降级标记。
        // 字段文档承诺「persist 成功或清空时重置」，此前成功 copyWith 漏带，
        // 降级轮之后所有轮次永久跳过 embedding（语义检索静默失效）。
        embeddingDegradedForRound: false,
        retryCounts: {},
        artifactsByTurnNumber: updatedArtifacts, // 保留本轮 artifacts
        // 收稿同步内存变体表（DB 为准，切换器立即可达；读失败
        // 降级时回退现值）
        variantsByTurn: reloadedVariants ?? state.variantsByTurn,
        // Stage 3：清空 pendingUserMessage（已落入 state.messages）
        pendingUserMessage: null,
        // 重生成轮收稿 → 切换器高亮 2s（起表时刻随收稿写入，
        //  口径：行物化早晚只影响剩余高亮时长）
        variantFlashTurn: isRegenerate ? turnNumber : null,
        variantFlashStartedAtMs:
            isRegenerate ? DateTime.now().millisecondsSinceEpoch : null,
        // 中断快照随收稿清空（正文已入 messages，卡片功成身退）
        partialReplySnapshot: null,
      );
      // 轮次完成，清理上下文
      _round = null;

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

  /// (c)：persist 事务已提交但轮次身份
  /// 丢失后的兜底重载。仅 idle（被后台复位清空 _round）时执行——新一轮
  /// 或失败恢复已接管时不打扰。loadHistory 自带 idle 守卫，重入安全。
  Future<void> _resyncAfterCommittedPersistLoss(int turnNumber) async {
    if (state.phase != IntermediatePhase.idle) return;
    _logger.warn(
      'Persist committed but round identity lost, resyncing history',
      detail: 'turn=$turnNumber',
    );
    await _loadHistory();
  }
}
