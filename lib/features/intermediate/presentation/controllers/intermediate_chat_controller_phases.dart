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

/// 拆分到本 part 文件的六步流程阶段执行方法（拆分）
///
/// 通过 extension 机制让方法仍属于 [IntermediateChatController] 类成员，
/// 可访问主文件中的私有字段（_streamRunner / _logger / state 等）。
///
/// 调用链（V2 六步流程）：
/// `_runCompactionPhase? → _runExtractPhase → _runRetrievePhase →
/// _runGeneratePhase → _runReviewPhase? → _runSummarizePhase → _runPersistPhase`
/// （_runPersistPhase 已拆分到 intermediate_chat_controller_persist.dart）
extension IntermediateChatControllerPhases on IntermediateChatController {
  // ==================== compacting 阶段（可选）====================

  Future<void> _runCompactionPhase(RoundContext round) async {
    final service = _compactionService;
    if (service == null) {
      // 服务未注入（旧测试环境）→ 跳过压缩，直接进入 extracting
      // 2026-08-04 修复：显式切回 extracting。否则从 continueFromFailed
      // 的 compacting 分支进入时 phase 仍为 compacting，UI 会误显示
      // "正在压缩对话历史"直到 extract 阶段结束。
      state = state.copyWith(phase: IntermediatePhase.extracting);
      await _runExtractPhase(round);
      return;
    }

    try {
      // 审查  修复：phase 初始为 extracting（2026-08-04 修订），
      // shouldCompact 检查期间 UI 显示 extracting 而非压缩提示；
      // 仅当确认要压缩时才切为 compacting（见下方 state.copyWith）。
      // v0.2.2（#6）：shouldCompact 基于总占用（基础上下文+检索区+历史）判断，
      // 需传入角色提示词/压缩摘要/用户输入以统计基础上下文 token。
      final rolePrompt = IntermediateContextBuilder.resolveRolePrompt(
        round.settings.systemPrompt,
        round.config.systemPrompt,
        round.config.prompts,
      );
      final shouldCompact = await service.shouldCompact(
        history: round.history,
        contextWindow: round.contextWindow,
        budget: round.config.contextBudget,
        rolePrompt: rolePrompt,
        compactionSummary: round.compactionSummary,
        userInput: round.userInput,
      );

      if (!shouldCompact) {
        // 未超阈值 → 跳过压缩，直接进入 extracting
        // 2026-08-04 修复（重要）：显式切回 extracting。原代码在此只调用
        // _runExtractPhase 而不改 phase，而 _runExtractPhase 开头也不设
        // phase（仅在 extract LLM 调用完成后设 retrieving），导致 phase
        // 一直停留在 compacting——UI 全程显示"正在压缩对话历史..."直到
        // extract 完成。用户反馈"每轮都看到正在压缩对话历史"即源于此。
        state = state.copyWith(phase: IntermediatePhase.extracting);
        await _runExtractPhase(round);
        return;
      }

      // 超阈值 → 确认要压缩，此时才切 phase=compacting 显示压缩提示。
      // （phase 初始为 extracting，避免未触发压缩时也显示压缩提示）
      state = state.copyWith(phase: IntermediatePhase.compacting);
      // 审查  修复：压缩是总结类任务，应使用 summarizeNamingConfig
      //（summarizing 阶段模型），而非 generatingNamingConfig（生成模型）。
      // summarizing 模型通常更轻量、低温度，适合生成稳定的剧情骨架摘要。
      final result = await service.compact(
        history: round.history,
        sessionId: state.session.sessionId,
        namingConfig: round.summarizeNamingConfig,
        contextWindow: round.contextWindow,
        // API 上限与上下文预留解耦：0 时仍预留 8192，避免输入塞满窗口。
        // modelMaxOutput 取实际执行
        // 压缩的 summarize 模型上限——此前误用 generating 模型上限，
        // 分步配轻量摘要模型时输出帽与真实执行模型脱节。
        maxTokens: _outputTokenReserveFor(
          round.settings.maxTokens,
          modelMaxOutput: round.summarizeNamingConfig.maxOutputTokens,
        ),
        budget: round.config.contextBudget,
        connectTimeout: round.connectTimeout,
        readTimeout: round.readTimeout,
        // v0.2.3：传入已有压缩摘要，用于判断是否需要生成分段宏摘要
        existingCompactionSummary: round.compactionSummary,
        // 2026-08-22 死亡螺旋修复：传入基础上下文 token，
        // 使保留量上限受"触发线 − 检索预留 − 基础上下文"包络约束
        baseContextTokens: await service.estimateBaseContextTokens(
          rolePrompt: rolePrompt,
          compactionSummary: round.compactionSummary,
          userInput: round.userInput,
        ),
        // 轮前压缩挂取消令牌（cancel/后台中断同步终止）；
        // 非流式路径生效点为请求发送前
        cancelToken: _beginCompaction(),
      );

      // 审查收官 ：轮次身份检查与溢出自愈路径同构——压缩秒级
      // await 期间用户可能取消并发起新轮，旧轮继续写回会污染新轮 state
      if (_streamRunner.isCancelled || _round != round) return;

      //  修复：压缩成功后追加本轮新覆盖的轮数到基数，
      // 保证同一会话生命周期内 turnNumber 继续单调（下次 loadHistory 会重算）。
      // boundary 定位必须在替换前的旧历史上进行，故先保存引用。
      final historyBeforeCompaction = round.history;
      _applyCompactionResult(round, result, historyBeforeCompaction);

      _logger.info(
        'Compaction completed',
        detail: 'summaryLength=${result.summary.length}, '
            'boundaryMessageId=${result.boundaryMessageId}, '
            'compactedHistoryLength=${result.compactedHistory.length}',
      );

      // 切到 extracting 阶段，继续六步流程
      state = state.copyWith(phase: IntermediatePhase.extracting);
      await _runExtractPhase(round);
    } on CompactionNoopException catch (e) {
      _logger.info(
        'Compaction skipped: no benefit',
        detail: 'reason=${e.reason.name}',
      );
      state = state.copyWith(phase: IntermediatePhase.extracting);
      await _runExtractPhase(round);
    } on CompactionException catch (e, stackTrace) {
      _logger.error(
        'Compaction failed (CompactionException)',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      await _fail(
        IntermediatePhase.compacting,
        'E018',
        error: e,
        errorCategory: ErrorCategory.persist,
        config: round.config,
      );
    } catch (e, stackTrace) {
      _logger.error(
        'Compaction phase failed',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      await _fail(
        IntermediatePhase.compacting,
        'E018',
        error: e,
        errorCategory: ErrorCategory.persist,
        config: round.config,
      );
    }
  }

  // ==================== generating 阶段（请求1：纯文本生成）====================

  /// 压缩结果写回轮次与状态（提取：轮前压缩与溢出自愈共用）
  ///
  /// [historyBeforeCompaction] 必须是压缩前的旧历史引用（boundary 定位
  /// 依赖旧下标）。包含：RoundContext 四字段 + compactedTurnBase/messages
  /// 同步（残留修复）+ 摘要卡范围+ 触底警示。
  void _applyCompactionResult(
    RoundContext round,
    CompactionResult result,
    List<ChatMessage> historyBeforeCompaction,
  ) {
    round
      ..compactionSummary = result.summary
      ..compactionBoundaryMessageId = result.boundaryMessageId
      ..compactionSummaryMessage = result.compactedHistory.first
      ..segmentMacroSummary = result.segmentMacroSummary
      ..history = result.compactedHistory;

    final boundaryIndexInOldHistory = historyBeforeCompaction.indexWhere(
      (m) => m.messageId == result.boundaryMessageId,
    );
    if (boundaryIndexInOldHistory != -1) {
      final newlyCoveredTurns = StoryCompactionService.countDialogueMessages(
            historyBeforeCompaction.take(boundaryIndexInOldHistory + 1),
          ) ~/
          2;
      //  残留修复：追加基数的同时必须把
      // state.messages 同步为压缩后视图——否则 persist 的
      // 基数 + 全量列表计数 双重计入已压缩轮次，压缩当轮起 turnNumber
      // 持续虚高（artifacts 键查不到、重生成按轮删除漏杀、recency 失真），
      // 直到重进会话才回正。同步后与 loadHistory 的过滤视图同口径。
      //
      // 先算新基数再 copyWith——修复前
      // 三个参数表达式都读旧 compactedTurnBase，首次压缩（B=0）渲染
      // 「已归档第 -N+1–0 轮」，后续压缩滞回显示上一轮压缩的范围。
      final newBase = state.compactedTurnBase + newlyCoveredTurns;
      state = state.copyWith(
        compactedTurnBase: newBase,
        messages: result.compactedHistory,
        // 摘要卡「已归档第 X–Y 轮」范围（历史累计+1 起，
        // 本轮压缩覆盖至新基数 = B+T；null 清空）
        archivedTurnRange: (
          from: newBase - newlyCoveredTurns + 1,
          to: newBase,
        ),
      );
    }

    //  触底警示：保留量触底时在压缩摘要卡上警示用户
    //（旧实现仅 logger.warn，用户对"每轮都在压缩"毫无感知）。
    // 触发线被检索预留 + 基础上下文吃满 → 保留区只剩保底 4 条，
    // 后续轮次极易再次触发压缩（死亡螺旋边缘）。
    // 未触底的后续压缩会解除警示（保留区已恢复）。
    state = state.copyWith(
      compactionFloorWarningTurn:
          result.hitRetentionFloor ? round.turnNumber : null,
    );
  }

  /// 上下文超限自愈（故事路对齐）：压缩旧历史一次，成功返回 true
  ///
  /// 与轮前阈值压缩共用 [StoryCompactionService] 同一管线与写回逻辑
  ///（[_applyCompactionResult]），不建第二套口径。压缩失败/消息不足/
  /// 已取消返回 false（调用方按原失败路径收场）。
  Future<bool> _selfHealContextOverflow(RoundContext round) async {
    final service = _compactionService;
    if (service == null) return false;
    final compactionToken = _beginCompaction();
    try {
      state = state.copyWith(phase: IntermediatePhase.compacting);
      final rolePrompt = IntermediateContextBuilder.resolveRolePrompt(
        round.settings.systemPrompt,
        round.config.systemPrompt,
        round.config.prompts,
      );
      final historyBefore = round.history;
      final result = await service.compact(
        history: historyBefore,
        sessionId: state.session.sessionId,
        namingConfig: round.summarizeNamingConfig,
        contextWindow: round.contextWindow,
        // 同轮前压缩——输出帽取实际执行的 summarize 模型上限
        maxTokens: _outputTokenReserveFor(
          round.settings.maxTokens,
          modelMaxOutput: round.summarizeNamingConfig.maxOutputTokens,
        ),
        budget: round.config.contextBudget,
        connectTimeout: round.connectTimeout,
        readTimeout: round.readTimeout,
        existingCompactionSummary: round.compactionSummary,
        baseContextTokens: await service.estimateBaseContextTokens(
          rolePrompt: rolePrompt,
          compactionSummary: round.compactionSummary,
          userInput: round.userInput,
        ),
        // 自愈压缩同挂取消令牌
        cancelToken: compactionToken,
      );
      if (_streamRunner.isCancelled || _round != round) return false;
      _applyCompactionResult(round, result, historyBefore);
      _logger.info(
        'Context overflow self-healed by compaction',
        detail: 'summaryLength=${result.summary.length}, '
            'boundaryMessageId=${result.boundaryMessageId}',
      );
      state = state.copyWith(phase: IntermediatePhase.generating);
      return true;
    } on CompactionNoopException catch (e) {
      _logger.info(
        'Context overflow self-heal skipped: no benefit',
        detail: 'reason=${e.reason.name}',
      );
      state = state.copyWith(phase: IntermediatePhase.generating);
      return false;
    } catch (e) {
      _logger.warn(
        'Context overflow self-heal compaction failed',
        detail: '$e',
      );
      return false;
    }
  }

  /// 判断本轮是否需要执行 reviewing 阶段（新增）
  ///
  /// 优先级：会话级 `reviewEnabledOverride` > 全局 `config.reviewEnabled`
  /// - `true`：执行 reviewing 审查修正（4 次 LLM 调用）
  /// - `false`（默认）：跳过 reviewing，生成即最终（3 次 LLM 调用）
  ///
  /// 在 [_runGeneratePhase] 末尾和 [continueFromFailed]（reviewing 失败重试）中调用，
  /// 确保两条路径的判断逻辑一致。
  bool _shouldReview(RoundContext round) {
    return round.settings.reviewEnabledOverride ?? round.config.reviewEnabled;
  }

  /// 轮前/自愈压缩的取消令牌登记（cancel/后台中断同步取消；
  /// 压缩 await 返回后无需显式清除——下一轮压缩会覆盖，字段为 null 时
  /// 取消调用是安全 no-op）。
  CancellationToken _beginCompaction() {
    final token = CancellationToken();
    _activeCompactionToken = token;
    return token;
  }

  /// generating 阶段（V2 六步流程，后为第 3 步）
  ///
  /// 变更：
  /// - extracting 前置后，generating 从第 1 步变为第 3 步（extracting → retrieving → generating）
  /// - generating 前已有检索结果，后续将注入记忆（任务）
  /// - 后续阶段从 extracting 改为 reviewing
  ///
  /// V2 变更（Phase 6 Step 6.4）：
  /// - 使用 `buildGenerateMessagesV2`（`kGeneratingSuffixPromptV2`，纯文本生成，无 JSON/关键词）
  /// - 使用 `runPlainText`（不解析标记/JSON，直接累积文本并流式显示）
  /// - 不再提取关键词（交由 extracting 阶段）
  /// - 不再有 JSON 模式/标记模式降级链（纯文本无需结构化）
  ///
  /// 产出：`round.generatedText` + `state.streamingGenerated` + `state.generatedText`
  /// 后续：根据 [_shouldReview] 决定调用 [_runReviewPhase] 或直接进入 summarizing
  ///
  ///  上下文超限自愈：捕获超限（core/llm/context_overflow 模式口径）→
  /// [_selfHealContextOverflow] 压缩一次 → 同阶段重试一次；再超限或压缩
  /// 不可用按 E016 + contextOverflow 类别进失败横幅（专属文案）。
  Future<void> _runGeneratePhase(
    RoundContext round, {
    bool overflowSelfHealed = false,
  }) async {
    final builder = IntermediateContextBuilder(tokenCounter: _tokenCounter);
    // 轮前定值的单一轮次号（与 retrieving/reviewing/persisting 同源）
    final currentTurnNumber = round.turnNumber;
    try {
      // 消息组装移入 try——此前在 try 块外，本地
      // 异常（如 token 计数抛错）沿调用链落入 _runExtractPhase 的
      // catch-all，被标成 E013「关键词提取失败」（阶段与码双重错标）。
      // E010 的用户文案是中性的「生成失败」，承载本地异常不误导。
      final assembly = await builder.buildGeneratePromptAssembly(
        userInput: round.userInput,
        history: round.history,
        sessionSystemPrompt: round.settings.systemPrompt,
        // v0.2.2 阶段 2-F：maxContextMessages 已移除，由压缩机制管理原文区
        contextWindow: round.contextWindow,
        // API 上限与上下文预留解耦：0 时仍预留固定预算。
        maxTokens: _outputTokenReserveFor(
          round.settings.maxTokens,
          modelMaxOutput: round.generatingNamingConfig.maxOutputTokens,
        ),
        prompts: round.config.prompts,
        globalSystemPrompt: round.config.systemPrompt,
        // 新增：注入检索记忆（retrieving 阶段产出）
        retrievedMemories: round.scoredMemories ?? const [],
        factBlock: round.retrievedFacts?.factBlock ?? '',
        currentTurnNumber: currentTurnNumber,
        // 修复（审查）：传入压缩摘要作为稳定前缀，避免长对话早期剧情丢失
        compactionSummary: round.compactionSummary,
        // 审查  修复：传入检索区预算比例，三区预算联动
        retrievalRatio: round.config.contextBudget.retrievalRatio,
        // 中断续写注入（非 null = 续跑救援路径）
        continuationPrefix: round.continuationPrefix,
      );
      final messages = assembly.messages;

      final request = LlmRequest(
        baseUrl: round.generatingNamingConfig.baseUrl,
        apiKey: round.generatingNamingConfig.apiKey,
        modelId: round.generatingNamingConfig.modelId,
        messages: messages.map(Map<String, dynamic>.from).toList(),
        temperature: round.settings.temperature,
        topP: round.settings.topP,
        maxTokens: round.settings.maxTokens,
        modelMaxOutputTokens: round.generatingNamingConfig.maxOutputTokens,
        // 生成参数：生成阶段应用惩罚参数，避免剧情单调、描写重复
        presencePenalty: round.settings.presencePenalty,
        frequencyPenalty: round.settings.frequencyPenalty,
        // 2026-07-28 修复：移除 supportsReasoning 硬拦截——许多 API 供应商
        //（如 NVIDIA NIM）不返回 capabilities 字段导致 supportsReasoning=false，
        // 用户配置的 reasoningEffort 被直接丢弃。改为无条件传递，
        // 由 OpenAiAdapter.ThinkingParamBuilder 在适配器层过滤。
        reasoningEffort: round.settings.reasoningEffort,
        protocol: round.generatingNamingConfig.protocol,
        providerOptions: round.generatingNamingConfig.providerOptions,
        // OpenAI 兼容流式端点默认不返回 usage；故事模式需要它来显示
        // prompt/cache token 与缓存命中率。
        includeUsage: true,
        // 与 messages 同源：稳定 system 段块数，仅 Anthropic 适配器消费。
        stableSystemPrefixCount: assembly.stableSystemPrefixCount,
        connectTimeout: round.connectTimeout,
        readTimeout: round.readTimeout,
      );

      if (Logger.debugOptions.logPrompts) {
        _logger.info(
          'Generate request messages (V2)',
          detail: _formatMessagesForLog(messages),
        );
      }

      final textBuffer = ThrottledDeltaBuffer((display) {
        if (state.isReviewEnabled) {
          state = state.copyWith(
            streamingGenerated: (state.streamingGenerated ?? '') + display,
          );
        } else {
          state = state.copyWith(
            streamingReply: (state.streamingReply ?? '') + display,
          );
        }
      });
      final thinkingBuffer = ThrottledDeltaBuffer((thinking) {
        if (state.isReviewEnabled) {
          state = state.copyWith(
            streamingGeneratedThinking:
                (state.streamingGeneratedThinking ?? '') + thinking,
          );
        } else {
          state = state.copyWith(
            streamingReplyThinking:
                (state.streamingReplyThinking ?? '') + thinking,
          );
        }
      });
      late final StreamResult result;
      try {
        result = await _streamRunner.runPlainText(
          request: request,
          phaseLabel: 'generating',
          onDelta: textBuffer.add,
          onThinkingDelta: thinkingBuffer.add,
        );
      } finally {
        textBuffer.flushAndDispose();
        thinkingBuffer.flushAndDispose();
      }

      if (_streamRunner.isCancelled) return;

      // 主请求 usage 入 state（reviewing 启用时随后被其覆盖）；
      // 端点未回 usage 时回退本地估算（面板「≈」标注）
      await _recordRequestUsage(
        result.usage,
        promptTexts: _promptTextsForEstimate(messages),
        completionText: result.displayText,
      );

      final generatedText = result.displayText;
      round
        ..generatedText = generatedText
        // 2026-07-28 修复：生成阶段同样保存思考内容，供 artifacts/小窗展示
        ..thinkingContent = result.thinkingContent;

      // reviewing 可选化（默认关）
      // - reviewEnabled=false（默认）→ 生成即最终，跳过 reviewing，直达 summarizing（3 次 LLM 调用）
      // - reviewEnabled=true -> 执行 reviewing 审查修正（4 次 LLM 调用）
      // 优先级：会话级 reviewEnabledOverride > 全局 reviewEnabled
      if (_shouldReview(round)) {
        state = state.copyWith(
          streamingGenerated: generatedText,
          generatedText: generatedText,
          phase: IntermediatePhase.reviewing,
        );
        await _runReviewPhase(round);
      } else {
        // 生成即最终：跳过 reviewing，直达 summarizing
        // - round.replyText 必须设为生成内容（summarizing 阶段需要 replyText）
        // - state.streamingReply 设为生成内容（UI 需要显示最终回复）
        // - round.thinkingContent 保持 generating 阶段的值（不覆盖）
        // v0.2.2：streamingReply 已通过 onDelta 实时更新，
        // 此处设为最终 generatedText 确保值一致
        round.replyText = generatedText;
        state = state.copyWith(
          streamingGenerated: generatedText,
          generatedText: generatedText,
          streamingReply: generatedText,
          streamingReplyThinking: result.thinkingContent,
          phase: IntermediatePhase.summarizing,
        );
        await _runSummarizePhase(round);
      }
    } on StreamErrorException catch (e, stackTrace) {
      // 上下文超限 → 压缩自愈一次后重试同阶段
      if (!overflowSelfHealed &&
          isContextOverflowText(e.message, e.code) &&
          await _selfHealContextOverflow(round) &&
          !_streamRunner.isCancelled &&
          _round == round) {
        await _runGeneratePhase(round, overflowSelfHealed: true);
        return;
      }
      _logger.error(
        'Generate stream interrupted',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      await _fail(
        IntermediatePhase.generating,
        'E016',
        error: e,
        errorCategory: isContextOverflowText(e.message, e.code)
            ? ErrorCategory.contextOverflow
            : null,
        config: round.config,
      );
    } catch (e, stackTrace) {
      // 非流式路径的超限（连接期 AppHttpException 带 400+文案）同口径自愈
      if (!overflowSelfHealed &&
          e is AppHttpException &&
          isContextOverflowText(
            '${e.message}${e.responseBody ?? ''}',
            e.code,
          ) &&
          await _selfHealContextOverflow(round) &&
          !_streamRunner.isCancelled &&
          _round == round) {
        await _runGeneratePhase(round, overflowSelfHealed: true);
        return;
      }
      _logger.error(
        'Generate phase failed',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      await _fail(
        IntermediatePhase.generating,
        'E010',
        error: e,
        errorCategory: e is AppHttpException &&
                isContextOverflowText(
                  '${e.message}${e.responseBody ?? ''}',
                  e.code,
                )
            ? ErrorCategory.contextOverflow
            : null,
        config: round.config,
      );
    }
  }

  // ==================== extracting 阶段（请求1：关键词提取，前置）====================

  /// extracting 阶段（V2 六步流程，后为第 1 步）
  ///
  /// 变更：
  /// - 从 generating 之后前置到 generating 之前（现在是第 1 步）
  /// - 输入从"用户消息+生成内容"改为"用户当前消息+最近对话"
  /// - 关键词从 2 类（entities/events）扩展为 5 类（characters/items/locations/actions/plots）
  ///
  /// 调用 [ExtractPhaseHandler] 从用户消息和最近对话中提取 5 类检索关键词：
  /// - 工具调用模式（`toolCallingEnabled=true`）→ JSON 模式降级链
  /// - 产出 [ClassifiedKeywords] → 存 `round.keywords` + `state.classifiedKeywords`
  ///
  /// 失败映射：
  /// - [ExtractFailedException]（解析失败）→ E013（格式错误，extractingMaxRetries 重试）
  /// - [StreamErrorException]（流式中断）→ E016（streamInterruptRetry 重试）
  /// - 其他异常 → E013
  ///
  /// 后续：调用 [_runRetrievePhase] 检索相关记忆
  Future<void> _runExtractPhase(RoundContext round) async {
    try {
      final keywords = await _extractHandler.run(
        ctx: round,
        toolCallingEnabled: round.config.stream.toolCallingEnabled,
      );

      if (_streamRunner.isCancelled) return;

      round.keywords = keywords;

      if (Logger.debugOptions.logKeywords) {
        _logger.info(
          'Extract keywords parsed',
          detail: 'characters=${keywords.characters}, items=${keywords.items}, '
              'locations=${keywords.locations}, actions=${keywords.actions}, '
              'plots=${keywords.plots}, count=${keywords.length}',
        );
      }

      state = state.copyWith(
        extractedKeywords: keywords.flatten(),
        classifiedKeywords: keywords,
        phase: IntermediatePhase.retrieving,
      );

      await _runRetrievePhase(round);
    } on ExtractFailedException catch (e, stackTrace) {
      _logger.error(
        'Extract phase failed (format)',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      await _fail(
        IntermediatePhase.extracting,
        'E013',
        error: e,
        errorCategory: ErrorCategory.format,
        config: round.config,
      );
    } on StreamErrorException catch (e, stackTrace) {
      _logger.error(
        'Extract stream interrupted',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      await _fail(
        IntermediatePhase.extracting,
        'E016',
        error: e,
        config: round.config,
      );
    } catch (e, stackTrace) {
      _logger.error(
        'Extract phase failed',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      await _fail(
        IntermediatePhase.extracting,
        'E013',
        error: e,
        config: round.config,
      );
    }
  }

  // ==================== retrieving 阶段 ====================

  Future<void> _runRetrievePhase(RoundContext round) async {
    final keywords = round.keywords ?? const ClassifiedKeywords();
    var scoredMemories = const <ScoredMemory>[];

    if (keywords.isNotEmpty) {
      // 5 路并行检索（3 FTS5 + 2 Vector）
      // - FTS5 通道 3 路：characters / items / locations（精确匹配实体名）
      // - Vector 通道 2 路：actions / plots（语义匹配事件）
      // 某类关键词为空时该路 query 为空，repository 自动跳过。
      final fts5Queries = <String>[
        keywords.characters.join(' '),
        keywords.items.join(' '),
        keywords.locations.join(' '),
      ];

      // Vector 通道：actions 和 plots 各一个 query+vector
      // embedding 配置未配置 / 本轮降级 → _resolveQueryVector 返回 null → 该路跳过
      final vectorQueryTexts = <String>[
        if (keywords.actions.isNotEmpty) keywords.actions.join(' '),
        if (keywords.plots.isNotEmpty) keywords.plots.join(' '),
      ];
      // 取消检查点：embedding 请求前
      // 同时检查轮次身份：cancel 后 _round=null，新轮次 _round=新对象
      if (_streamRunner.isCancelled || _round != round) return;
      // 查询 embedding 失败此前不在本阶段
      // try 内，异常沿 await 冒泡进 extracting 的 catch-all 被误报为
      // E013"关键词提取失败"，按  立即×2 重试只是反复烧 extract LLM，
      // 且 FailureBar 的 E104"临时降级"按钮永不出现。单独捕获映射 E104。
      final List<Float32List?> queryVectors;
      try {
        queryVectors = await Future.wait(
          vectorQueryTexts.map(_resolveQueryVector),
        );
      } on EmbeddingCallFailedException catch (e, stackTrace) {
        _logger.error(
          'Query embedding failed in retrieving',
          detail: '$e',
          error: e,
          stackTrace: stackTrace,
        );
        await _fail(
          IntermediatePhase.retrieving,
          'E104',
          error: e,
          config: round.config,
        );
        return;
      } on EmbeddingRateLimitedException catch (e, stackTrace) {
        _logger.error(
          'Query embedding rate-limited in retrieving',
          detail: '$e',
          error: e,
          stackTrace: stackTrace,
        );
        await _fail(
          IntermediatePhase.retrieving,
          'E104',
          error: e,
          config: round.config,
        );
        return;
      }
      // 取消检查点：embedding 请求后、DB 检索前
      if (_streamRunner.isCancelled || _round != round) return;
      final vectorQueries = <({String query, Float32List? vector})>[
        for (var i = 0; i < vectorQueryTexts.length; i++)
          (query: vectorQueryTexts[i], vector: queryVectors[i]),
      ];

      // currentTurnNumber 推导
      // 轮前定值的单一轮次号（与 generating/reviewing/persisting 同源）
      final currentTurnNumber = round.turnNumber;
      try {
        scoredMemories =
            await _experienceRepository.searchExperiencesMultiChannel(
          sessionId: state.session.sessionId,
          fts5Queries: fts5Queries,
          vectorQueries: vectorQueries,
          topK: round.config.retrieval.topK,
          fts5Weight: round.config.retrieval.fts5Weight,
          vectorWeight: round.config.retrieval.vectorWeight,
          keyEventThreshold: round.config.retrieval.keyEventThreshold,
          keyEventBoost: round.config.retrieval.keyEventBoost,
          normalizationEpsilon: round.config.retrieval.normalizationEpsilon,
          //  新增参数
          recencyWeight: round.config.retrieval.recencyWeight,
          importanceWeight: round.config.retrieval.importanceWeight,
          recencyHalfLife: round.config.retrieval.recencyHalfLife,
          vectorScoreThreshold: round.config.retrieval.vectorScoreThreshold,
          currentTurnNumber: currentTurnNumber,
        );
      } on MemoryRetrievalUnavailableException catch (e) {
        // 2026-09-09：全通道失败 ≠ 整轮失败。降级为
        // "无评分记忆"并交给下方子串兜底补位（fail-open，不打断故事生成）。
        _logger.warn('Retrieval channels unavailable', detail: '$e');
      } catch (e, stackTrace) {
        _logger.error(
          'Retrieval failed',
          detail: '$e',
          error: e,
          stackTrace: stackTrace,
        );
        await _fail(
          IntermediatePhase.retrieving,
          'E012',
          error: e,
          config: round.config,
        );
        return;
      }

      // 质量阈值过滤（接入配置，替换 ContextBuilder 硬编码）
      // 双阈值取严格：finalScore 必须同时 ≥ 绝对阈值和相对阈值（本批最高分 × 比例）
      // 才保留。全部被过滤 → scoredMemories 空 → reviewing 仅做润色。
      //
      // FTS 未命中（<0.02 偶然
      // 命中线）的纯语义候选不走 absoluteThreshold——FTS=0 时
      // finalScore=vec/2（vec 为 (cosine+1)/2 归一化），过 0.5 绝对阈
      // 等价于原始 cosine ≥0.625，跨轮非对称嵌入的典型 0.3-0.6 全灭
      // （语义召回窄带：新实体/新情节关键词场景系统性 0 召回）。改为
      // 原始 cosine ≥ vector_only_cosine_floor（默认 0.3）即保留；混合
      // 命中（FTS 有分）仍走双阈值不受影响。相对阈值两态共享。
      if (scoredMemories.isNotEmpty) {
        final maxScore = scoredMemories.first.finalScore;
        final relThresh = maxScore * round.config.retrieval.relativeThreshold;
        final vectorOnlyFloor =
            round.config.retrieval.vectorOnlyCosineFloor.clamp(0.0, 1.0);
        scoredMemories = scoredMemories.where((m) {
          if (m.finalScore < relThresh) return false;
          if (m.fts5Score >= 0.02) {
            return m.finalScore >= round.config.retrieval.absoluteThreshold;
          }
          // 纯语义候选：归一化逆变换回原始 cosine 刻度再比低阈
          return (m.vectorScore * 2 - 1) >= vectorOnlyFloor;
        }).toList();
      }

      // 2026-09-09：评分通道只覆盖已建索引/已
      // 向量化的记忆；阈值全清空或全通道失败时用主表子串兜底补位——保证
      // 「记忆库里看得见的记忆」不会整轮消失。可经
      // retrieval.substring_fallback_enabled 关闭。
      if (scoredMemories.isEmpty &&
          round.config.retrieval.substringFallbackEnabled) {
        // 兜底词表并入 vectorQueryTexts——此前只
        // tokenize fts5Queries（三路实体词），动作/情节词为主的检索意图
        //（新会话第 2 轮常见）被阈值清空后兜底盲区；纯扩大可达性，不动评分。
        final fallbackTerms = MemoryQuery.tokenizeAll(
          [...fts5Queries, ...vectorQueryTexts],
        );
        if (fallbackTerms.isNotEmpty) {
          final fallback =
              await _experienceRepository.searchExperiencesBySubstring(
            state.session.sessionId,
            fallbackTerms,
            limit: round.config.retrieval.substringFallbackLimit,
          );
          scoredMemories = [
            for (final memory in fallback)
              ScoredMemory(
                memory: memory,
                fts5Score: 0,
                vectorScore: 0,
                temporalScore: 0,
                finalScore: 0,
              ),
          ];
          if (scoredMemories.isNotEmpty) {
            _logger.info(
              'Retrieval substring fallback used',
              detail: 'count=${scoredMemories.length}',
            );
          }
        }
      }
    }

    if (_streamRunner.isCancelled || _round != round) return;

    // 存入 round 供 reviewing 阶段/重试复用
    round.scoredMemories = scoredMemories;

    // 取消检查点：事实层检索前
    if (_streamRunner.isCancelled || _round != round) return;

    // DOC-11 §6.1 事实层检索（retrieving 阶段并行执行）
    // 失败不阻塞经历层检索（_factContextBuilder 内部已 catch 异常返回空）。
    // 仅当 _factContextBuilder 注入 + factual.enabled=true 时执行。
    final factBuilder = _factContextBuilder;
    if (factBuilder != null && round.config.memory.factual.enabled) {
      try {
        final factResult = await factBuilder.buildFactBlock(
          sessionId: state.session.sessionId,
          keywords: keywords,
          config: round.config.memory.factual,
          injectionTitle: round.config.prompts.factInjectionTitle,
          directiveInjectionTitle: round.config.prompts.directiveInjectionTitle,
        );
        round.retrievedFacts = factResult;

        if (Logger.debugOptions.logMemories && factResult.hasFacts) {
          _logger.info(
            'Retrieved facts',
            detail: 'count=${factResult.facts.length}',
          );
        }
      } catch (e, stackTrace) {
        // 兜底：FactContextBuilder 内部已 catch，这里防止极端情况
        _logger.warn(
          'Fact retrieval failed (non-blocking)',
          detail: 'error=${e.runtimeType}: $e, stack=$stackTrace',
        );
      }
    }

    if (_streamRunner.isCancelled || _round != round) return;

    // 2026-07-16 优化项10：移除 compact 降级，reviewing 照常跑
    // 原设计：检索结果为空/低质量时跳过 reviewing，生成即最终
    // 新设计：reviewing 有双重功能（按记忆修正 + 润色文案），即使无记忆也有润色价值
    // 注入前质量过滤（双阈值取严格）已从 ContextBuilder
    // 迁移到本阶段（上方 try 块内），由 RetrievalConfig 配置驱动。如果全部记忆都
    // 不满足阈值，scoredMemories 为空，【相关往事】区块省略，reviewing 只做润色。
    // 配置项 skipReviewWhenEmptyRetrieval 保留但不再生效（向后兼容）。

    // Stage 5：调试日志——记录记忆检索结果（含分数）
    if (Logger.debugOptions.logMemories) {
      _logger.info(
        'Retrieved memories',
        detail: _formatMemoriesForLog(scoredMemories),
      );
    }

    final memories = scoredMemories.map((s) => s.memory).toList();

    // V2 六步流程：reviewing 照常跑（不再有 compact 降级跳过）
    // retrieving 后进入 generating（而非 reviewing），生成阶段注入记忆
    state = state.copyWith(
      retrievedMemories: memories,
      retrievedFacts: round.retrievedFacts?.facts,
      phase: IntermediatePhase.generating,
    );
    await _runGeneratePhase(round);
  }

  // ==================== reviewing 阶段（请求3：纯文本审查）====================

  /// reviewing 阶段（V2 六步流程，请求3）
  ///
  /// V2 变更（Phase 6 Step 6.4）：
  /// - 使用 `buildReviewMessagesV2`（`kReviewSuffixPromptV2`，纯文本回复，无 JSON/事件摘要）
  /// - 使用 `runPlainText`（不解析标记/JSON，直接累积文本并流式显示）
  /// - 不再提取事件摘要（交由 summarizing 阶段）
  /// - 不再有 JSON 模式/标记模式降级链（纯文本无需结构化）
  /// - compact 降级在 [_runRetrievePhase] 末尾处理（跳过本方法，直接 summarizing）
  ///
  /// 产出：`round.replyText` + `state.streamingReply`
  /// 后续：调用 [_runSummarizePhase] 提取事件摘要
  Future<void> _runReviewPhase(RoundContext round) async {
    final builder = IntermediateContextBuilder(tokenCounter: _tokenCounter);
    // 轮前定值的单一轮次号（与 generating/retrieving/persisting 同源）
    final currentTurnNumber = round.turnNumber;

    // 组装移入 try—— 只补了 generating 侧，
    // reviewing 侧的本地异常（token 计数/组装抛错）仍会沿 await 冒泡进
    // _runGeneratePhase 的 catch-all，以 E010「生成失败」收场，而此时
    // state.phase 已是 reviewing，阶段与错误码双重错标。对齐 generating
    // 侧：本地异常按 E014「审查阶段失败」分类，失败栏指向正确阶段。
    try {
      final assembly = await builder.buildReviewPromptAssembly(
        userInput: round.userInput,
        generated: round.generatedText ?? '',
        retrievedMemories: round.scoredMemories ?? const [],
        factBlock: round.retrievedFacts?.factBlock ?? '',
        sessionSystemPrompt: round.settings.systemPrompt,
        contextWindow: round.contextWindow,
        maxTokens: _outputTokenReserveFor(
          round.settings.maxTokens,
          modelMaxOutput: round.reviewingNamingConfig.maxOutputTokens,
        ),
        currentTurnNumber: currentTurnNumber,
        prompts: round.config.prompts,
        globalSystemPrompt: round.config.systemPrompt,
        // 审查  修复：传入检索区预算比例，三区预算联动
        retrievalRatio: round.config.contextBudget.retrievalRatio,
      );
      final messages = assembly.messages;

      final request = LlmRequest(
        baseUrl: round.reviewingNamingConfig.baseUrl,
        apiKey: round.reviewingNamingConfig.apiKey,
        modelId: round.reviewingNamingConfig.modelId,
        messages: messages.map(Map<String, dynamic>.from).toList(),
        temperature: round.settings.temperature,
        topP: round.settings.topP,
        maxTokens: round.settings.maxTokens,
        modelMaxOutputTokens: round.reviewingNamingConfig.maxOutputTokens,
        // 生成参数：修正阶段同样应用惩罚参数，保持与生成阶段一致的生成风格
        presencePenalty: round.settings.presencePenalty,
        frequencyPenalty: round.settings.frequencyPenalty,
        // 2026-07-28 修复：移除 supportsReasoning 硬拦截（同生成阶段），无条件传递
        reasoningEffort: round.settings.reasoningEffort,
        protocol: round.reviewingNamingConfig.protocol,
        providerOptions: round.reviewingNamingConfig.providerOptions,
        // 与 generating 保持一致，确保 OpenAI 兼容端点返回缓存分项。
        includeUsage: true,
        // 与 messages 同源：稳定 system 段块数，仅 Anthropic 适配器消费。
        stableSystemPrefixCount: assembly.stableSystemPrefixCount,
        connectTimeout: round.connectTimeout,
        readTimeout: round.readTimeout,
      );

      if (Logger.debugOptions.logPrompts) {
        _logger.info(
          'Review request messages (V2)',
          detail: _formatMessagesForLog(messages),
        );
      }

      state = state.copyWith(
        streamingReply: '',
        streamingReplyThinking: null,
      );

      final textBuffer = ThrottledDeltaBuffer((display) {
        state = state.copyWith(
          streamingReply: (state.streamingReply ?? '') + display,
        );
      });
      final thinkingBuffer = ThrottledDeltaBuffer((thinking) {
        state = state.copyWith(
          streamingReplyThinking:
              (state.streamingReplyThinking ?? '') + thinking,
        );
      });
      late final StreamResult result;
      try {
        result = await _streamRunner.runPlainText(
          request: request,
          phaseLabel: 'reviewing',
          onDelta: textBuffer.add,
          onThinkingDelta: thinkingBuffer.add,
        );
      } finally {
        textBuffer.flushAndDispose();
        thinkingBuffer.flushAndDispose();
      }

      if (_streamRunner.isCancelled) return;

      // 主请求 usage 入 state（reviewing 是上下文最全的请求，终值口径）；
      // 端点未回 usage 时回退本地估算（面板「≈」标注）
      await _recordRequestUsage(
        result.usage,
        promptTexts: _promptTextsForEstimate(messages),
        completionText: result.displayText,
      );

      final reply = result.displayText;
      round
        ..replyText = reply
        ..thinkingContent = result.thinkingContent;

      if (Logger.debugOptions.logResponses) {
        _logger.info(
          'Revise result (V2)',
          detail: 'replyLength=${reply.length}\n--- reply ---\n$reply',
        );
      }

      state = state.copyWith(
        streamingReply: reply,
        phase: IntermediatePhase.summarizing,
      );

      await _runSummarizePhase(round);
    } on StreamErrorException catch (e, stackTrace) {
      _logger.error(
        'Review stream interrupted',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      await _fail(
        IntermediatePhase.reviewing,
        'E016',
        error: e,
        config: round.config,
      );
    } catch (e, stackTrace) {
      _logger.error(
        'Revise phase failed',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      await _fail(
        IntermediatePhase.reviewing,
        'E014',
        error: e,
        config: round.config,
      );
    }
  }

  // ==================== summarizing 阶段（请求4：事件摘要提取）====================

  /// summarizing 阶段（V2 六步流程，请求4）
  ///
  /// 调用 [SummarizePhaseHandler] 从回复中提取事件摘要：
  /// - 工具调用模式（`toolCallingEnabled=true`）→ JSON 模式降级链
  /// - 产出 [EventSummary] → 存 `round.eventSummary` + `state.currentEventSummary`
  /// - compact 降级复用：summarizing 始终执行（即使 compact 模式也生成摘要）
  ///
  /// 失败映射：
  /// - [SummarizeFailedException]（解析失败）→ E017（格式错误，summarizingMaxRetries 重试）
  /// - [StreamErrorException]（流式中断）→ E016（streamInterruptRetry 重试）
  /// - 其他异常 → E017
  ///
  /// 后续：调用 [_runPersistPhase] 持久化
  Future<void> _runSummarizePhase(RoundContext round) async {
    try {
      final result = await _summarizeHandler.run(
        ctx: round,
        toolCallingEnabled: round.config.stream.toolCallingEnabled,
        sessionId: state.session.sessionId,
      );

      if (_streamRunner.isCancelled) return;

      round
        ..eventSummary = result.summary
        ..factsDeltas = result.factsDeltas;

      // facts 相关日志默认输出（之前被 logResponses 包裹导致静默，
      // 用户无法定位"事实层始终为空"问题）。summary 文本仍受 logResponses 控制。
      _logger.info(
        'Summarize result parsed',
        detail: 'turn=${result.summary.turnNumber}, '
            'facts=${result.factsDeltas.length}'
            '${Logger.debugOptions.logResponses ? ', summary=${result.summary.summary}' : ''}',
      );

      state = state.copyWith(
        currentEventSummary: result.summary,
        currentFactsChanges:
            result.factsDeltas.map(FactsChangeRecord.fromDelta).toList(),
        phase: IntermediatePhase.persisting,
      );

      // 创建类 delta 的疑似重复候选进事实变更小窗（与
      // applier 创建侧警告同口径；候选实体 ID 供记忆库归并预选）
      final createdNames = result.factsDeltas
          .where((d) => d.action == FactAction.createEntity)
          .map((d) => d.primaryName)
          .whereType<String>()
          .toList();
      final factBuilder = _factContextBuilder;
      if (factBuilder != null && createdNames.isNotEmpty) {
        final candidates = await factBuilder.findSimilarNameCandidates(
          state.session.sessionId,
          createdNames,
        );
        if (!mounted) return;
        if (candidates.isNotEmpty) {
          state = state.copyWith(similarNameCandidates: candidates);
        }
      }

      await _runPersistPhase(round);
    } on SummarizeFailedException catch (e, stackTrace) {
      _logger.error(
        'Summarize phase failed (format)',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      await _fail(
        IntermediatePhase.summarizing,
        'E017',
        error: e,
        errorCategory: ErrorCategory.format,
        config: round.config,
      );
    } on StreamErrorException catch (e, stackTrace) {
      _logger.error(
        'Summarize stream interrupted',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      await _fail(
        IntermediatePhase.summarizing,
        'E016',
        error: e,
        config: round.config,
      );
    } catch (e, stackTrace) {
      _logger.error(
        'Summarize phase failed',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      await _fail(
        IntermediatePhase.summarizing,
        'E017',
        error: e,
        config: round.config,
      );
    }
  }
}
