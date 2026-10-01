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

/// 拆分到本 part 文件的失败处理 / 自动重试 / 手动续跑方法（拆分）
///
/// 通过 extension 机制让方法仍属于 [AdvancedChatController] 类成员，
/// 可访问主文件中的私有字段（_streamRunner / _retryScheduler / _round 等）。
extension AdvancedChatControllerRetry on AdvancedChatController {
  // ==================== 失败 / 重试 ====================

  /// 失败处理（：自动重试 + 整轮失败）
  ///
  /// 按错误码查询 [RetryConfig] 最大重试次数：
  /// - 未超限 → 进入 *Retry 状态，延迟后重跑该阶段（同一阶段内重试）
  /// - 已超限 → 进入 failed 状态，等用户手动重试（整轮从头来）
  ///
  /// 删除硬编码 errorMessage，改用分类器自动生成：
  /// - [error] 为 catch 块捕获的原始异常，分类器提取 category/httpStatus/rawError
  /// - [errorCategory] 手动覆盖分类结果（如 E010 强制 config、E013/E017 强制 format）
  /// - [config] 为当前轮次配置（重试次数查询用；persist 失败时可能为 null）
  ///
  /// 权威设计：DOC-09A-2 §6.2、DOC-09B §9。
  Future<void> _fail(
    IntermediatePhase phase,
    String errorCode, {
    Object? error,
    ErrorCategory? errorCategory,
    StoryRuntimeConfig? config,
    String? suggestionOverride,
  }) async {
    if (_streamRunner.isCancelled) return;

    // 上下文超限不进自动重试——与故事侧
    // intermediate_chat_controller_retry 同款口径（该处注释自称「导演侧同款
    // 口径」但本副本漏接）：超限重发同一载荷必然再超限，且自动重试会复位
    // 溢出自愈旗标造成「二次压缩+必败重发」循环。导演 agent 正文路径经
    // runner 结果直达 failed 不受影响；本分支守住共用故事管线的 compacting
    // 等阶段溢出异常仍可被 RetryConfig 放行的窗口。
    final overflowCategory = errorCategory == ErrorCategory.contextOverflow ||
        (error != null &&
            errorCategory == null &&
            _classifier.classifyError(error).category ==
                ErrorCategory.contextOverflow);
    final retryConfig = config?.retry;
    final maxRetries = overflowCategory
        ? 0
        : _retryScheduler.getMaxRetries(errorCode, retryConfig);
    final currentCount = state.retryCounts[phase] ?? 0;

    //  同款：
    // persisting 失败一律走 failed 终态，避免 toRetryPhase(persisting)=failed
    // 的空转（phase=failed 而 failureContext=null 的静默死态）。
    if (currentCount < maxRetries &&
        _round != null &&
        phase != IntermediatePhase.persisting) {
      // 可重试：进入 *Retry 状态，延迟后重跑
      await _scheduleRetry(
        phase: phase,
        errorCode: errorCode,
        retryCount: currentCount + 1,
      );
    } else {
      // 重试用尽或不可重试：进入 failed
      // 分类异常 + 提取 HTTP 状态 + 截断原始异常 → 构造 FailureContext
      ErrorCategory category;
      int? httpStatus;
      String? rawError;
      if (error != null) {
        final result = _classifier.classifyError(error);
        // errorCategory 手动覆盖优先（如 E010 配置错误强制为 config）
        category = errorCategory ?? result.category;
        httpStatus = result.httpStatus;
        rawError = result.rawError;
      } else {
        category = errorCategory ?? ErrorCategory.unknown;
      }
      final message = _classifier.resolveFailureMessage(errorCode, category);

      state = state.copyWith(
        phase: IntermediatePhase.failed,
        failureContext: FailureContext(
          errorCode: errorCode,
          failedPhase: phase,
          errorMessage: message,
          retryable: true,
          errorCategory: category,
          httpStatus: httpStatus,
          rawError: rawError,
          // 报点级建议覆盖（如导演主模型未配置），
          // 仅展示用，不写入失败日志
          suggestionOverride: suggestionOverride,
        ),
      );

      //  诊断包：持久化失败上下文到 failure_logs 表（unawaited 不阻塞状态机）
      // 日志写入失败由 Repository 静默降级，不影响主流程
      unawaited(
        _failureLogRepository.insertLog(
          sessionId: state.session.sessionId,
          mode: state.session.mode,
          errorCategory: category.name,
          errorCode: errorCode,
          failedPhase: phase.name,
          httpStatus: httpStatus,
          errorMessage: message,
          rawError: rawError,
        ),
      );
      // 2026-07-22 修复（问题 1-A）：不再清空 _round。
      // 保留 _round 让"从中断处继续"（continueFromFailed）能复用已完成阶段的产出。
      // 用户主动 clearRound / retry / cancel 时仍会清空 _round。
    }
  }

  /// 调度自动重试：进入 *Retry 状态，延迟后重跑该阶段
  Future<void> _scheduleRetry({
    required IntermediatePhase phase,
    required String errorCode,
    required int retryCount,
  }) async {
    final retryPhase = _retryScheduler.toRetryPhase(phase);
    state = state.copyWith(
      phase: retryPhase,
      retryCounts: {...state.retryCounts, phase: retryCount},
    );

    final delay = _retryScheduler.retryDelay(errorCode);
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }

    // 取消或状态已变（用户操作）则放弃重试
    if (_streamRunner.isCancelled ||
        state.phase != retryPhase ||
        _round == null) {
      return;
    }

    // 清理该阶段流式产物，避免新旧叠加
    state = _resetPhaseState(state, phase);

    // 重跑该阶段（V2 六步流程：6 个阶段均支持重试重跑）
    // compacting 失败映射 E018（0 次重试），不会走到此处重跑逻辑，
    // 与不可重试阶段一起 break（逻辑上不可达，仅为 switch 完备性）。
    // 导演轮只有一个整体的"generating"内核（agent loop），
    // 可重试阶段的统一重跑方式是重新进入 agent loop。
    switch (phase) {
      case IntermediatePhase.generating:
      case IntermediatePhase.extracting:
      case IntermediatePhase.retrieving:
      case IntermediatePhase.reviewing:
      case IntermediatePhase.summarizing:
      case IntermediatePhase.compacting:
        await _runDirectorRoundGuarded(_round!);
      case IntermediatePhase.idle:
      case IntermediatePhase.generatingRetry:
      case IntermediatePhase.extractingRetry:
      case IntermediatePhase.retrievingRetry:
      case IntermediatePhase.reviewingRetry:
      case IntermediatePhase.summarizingRetry:
      case IntermediatePhase.persisting:
      case IntermediatePhase.failed:
        break;
    }
  }

  /// agent loop（runRound）统一
  /// catch-all 出口。
  ///
  /// 此前 [_scheduleRetry] / [continueWithFts5Only] / [continueFromFailed]
  /// 三处裸 await runRound——任何未被阶段内捕获的异常沿 await 链逃出控制器
  /// 方法成为 Zone uncaught，状态机卡在 *Retry / retrieving 等中间态（无
  /// FailureBar、无失败日志）。此处与 [_prepareAndRunRound] 既有 catch 同款
  /// 映射（E010 / generating / config， 统一后同口径），
  /// 四处复用同一出口兜底。
  Future<void> _runDirectorRoundGuarded(
    RoundContext round, {
    DirectorRoundTuning? tuning,
  }) async {
    // 同 turn 重跑前统一清理上一尝试的
    // durable 事件（「同 turn 仅保留最新一组」语义从重生成/编辑重发推广
    // 到自动重试/手动重试/中断续跑/降级续跑——此前这些入口不清理，失败重试
    // 会追加第二组 bootstrap+turn 对，轨迹页步数与 token 双计、L3 请求重建
    // 里用户消息与尾部注入出现两遍）。首次运行的全新 turn 无 >=N 事件，
    // DELETE 为 no-op；崩溃恢复遗留的孤儿事件也顺带收敛。
    // 审查收官  口径：清理失败不阻断重跑（事件日志仅审计面）。
    try {
      final frozenDeleted = await _agentEventLogRepository?.deleteTurnEvents(
            state.session.sessionId,
            round.turnNumber,
          ) ??
          false;
      // 删到 systemFrozen 行时重置补写备忘（本轮 bootstrap 会重落）
      if (frozenDeleted) _directorRunner.invalidateFrozenPrefixMemo();
    } catch (e) {
      _logger.warn('Rerun event log cleanup failed', detail: '$e');
    }
    try {
      await _directorRunner.runRound(round, tuning: tuning);
    } catch (e, stackTrace) {
      _logger.error(
        'Director round crashed',
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
    }
  }

  /// 整轮重试：清中间产物，保留 userInput 和 regenerateTurnNumber，从 extracting 重新开始
  ///
  /// 若当前为"重新生成"流程（regenerateTurnNumber != null），重试时保留该标识，
  /// 重新走 persistRegeneratedRound 分支。普通发送场景重试走 persistRound 分支。
  Future<void> retry() async {
    if (state.phase != IntermediatePhase.failed) return;
    final input = state.userInput;
    if (input == null || input.isEmpty) return;

    // 保留跨重试的轮次标识（clearTemporary 会清空，这里恢复）
    final regenerateTurnNumber = state.regenerateTurnNumber;

    _round = null;
    state = state.clearTemporary().copyWith(
          userInput: input,
          regenerateTurnNumber: regenerateTurnNumber,
        );
    await _prepareAndRunRound();
  }

  /// 用户选择"临时降级继续本轮"（E104 错误时调用）
  ///
  /// 2026-07-21 新增。重跑 retrieving 阶段但跳过 embedding 调用，仅用 FTS5 检索。
  /// 本轮生成的记忆 has_embedding=false（后续可通过"重建向量索引"补全）。
  /// 本轮的检索小窗会显示「临时降级」标签。
  ///
  /// 实现要点：
  /// - 守卫：phase=failed + errorCode=E104（其他错误码不展示该按钮）
  /// - 标记 [AdvancedChatState.embeddingDegradedForRound] = true，
  ///   后续 [_resolveQueryVector] / [_resolveEmbedding] 检查该标记直接返回 null
  /// - 清空 failureContext 和 retryCounts，phase 切回 retrieving
  /// - 重跑 `_runRetrievePhase`：embedding 跳过 → 纯 FTS5 检索 → 后续阶段正常推进
  ///
  /// 与 [retry] 的区别：retry 完全重跑全流程（含 extracting）；本方法从 retrieving
  /// 阶段续跑（keywords 已存在，复用）。
  Future<void> continueWithFts5Only() async {
    if (_round == null) return;
    if (state.phase != IntermediatePhase.failed) return;
    if (state.failureContext?.errorCode != 'E104') return;

    state = state.copyWith(
      embeddingDegradedForRound: true,
      phase: IntermediatePhase.retrieving,
      failureContext: null,
      retryCounts: {},
    );

    // 重跑导演轮（agent loop）
    // _resolveQueryVector 会在开头检查 state.embeddingDegradedForRound
    // 并返回 null（跳过 embedding 调用），检索工具走 FTS5 兜底
    // 经 catch-all 出口，异常不再 Zone uncaught
    await _runDirectorRoundGuarded(_round!);
  }

  /// 从中断处继续：保留已完成阶段产出，从失败阶段重试（2026-07-22 新增）
  ///
  /// 与 [retry] 的区别：
  /// - retry：清空 _round，从 extracting 重新开始（整轮重做）
  /// - continueFromFailed：保留 _round 中已完成阶段的产出，从失败阶段继续
  ///
  /// 用户决策：所有失败阶段都显示此按钮（包括 extracting）。
  /// extracting 失败时无产出可复用，行为等价于 retry（从 extracting 重新开始）。
  ///
  /// 本方法会重新解析配置（用户可能通过会话设置修改了模型/温度等），
  /// 但保留已完成阶段的产出（generatedText/keywords/scoredMemories 等）。
  /// 配置解析失败时用旧配置兜底，不阻塞继续重试。
  Future<void> continueFromFailed() async {
    if (state.phase != IntermediatePhase.failed) return;
    if (_round == null) return;
    final failureContext = state.failureContext;
    if (failureContext == null) return;

    final oldRound = _round!;
    final failedPhase = failureContext.failedPhase;

    // persist-only 续跑——生成链路已全部成功（产出校验
    // 齐备：eventSummary 非空），仅持久化失败时不重进 agent loop：直奔
    // persist 阶段（内部自带 E018 失败闭环），避免整轮重跑的重复消耗与
    // 重复事件。eventSummary 缺失时回落下方通用路径。
    if (failedPhase == IntermediatePhase.persisting &&
        oldRound.eventSummary != null) {
      state = state.copyWith(
        phase: IntermediatePhase.persisting,
        failureContext: null,
        retryCounts: {},
      );
      await _runPersistPhase(oldRound);
      return;
    }

    // 重新解析配置（用户可能修改过模型/温度等），失败时用旧配置兜底
    _round = await _reloadRoundConfigPreservingOutputs(oldRound) ?? oldRound;

    state = state.copyWith(
      phase: failedPhase,
      failureContext: null,
      retryCounts: {},
    );

    // 导演轮：统一重新进入 agent loop（产出已在 _round 中保留复用，
    // persisting 失败的续跑也经 runner 的持久化出口闭环）。
    // 经 catch-all 出口，异常不再 Zone uncaught
    await _runDirectorRoundGuarded(_round!);
  }

  /// 重新解析轮次配置，保留旧产出字段（供 [continueFromFailed] 使用）
  ///
  /// 返回新的 RoundContext（配置更新 + 产出保留）；解析失败返回 null（调用方用旧 _round 兜底）。
  Future<RoundContext?> _reloadRoundConfigPreservingOutputs(
    RoundContext old,
  ) async {
    try {
      final config = await _getConfig();

      // 导演无六步 phase：模型仅 generating（GM）一条解析链，
      // 其余结构字段保留旧轮值（RoundContext 要求非空）。
      final draftNaming =
          await _configurationResolver.resolveAdvancedGeneratingNamingConfig(
        state.session,
      );
      // 2026-08-04 修复：与主流程一致，从 generating 阶段模型配置解析 contextWindow
      final generatingModelWindow =
          await _configurationResolver.resolveContextWindowForPhase(
        presetId: draftNaming?.presetId,
        modelId: draftNaming?.modelId,
      );
      final embeddingConfig =
          await _configurationResolver.resolveAdvancedEmbeddingConfig();
      final timeouts = await _configurationResolver.resolveTimeouts();
      final resolved = await _configurationResolver.resolveAdvancedSettings(
        state.session,
      );
      // 应用单次请求 token 上限：取 min(配置值, 模型窗口)
      final contextWindow = _resolveContextWindow(
        resolved.settings.effectiveContextLimit,
        generatingModelWindow,
      );

      return RoundContext(
        userInput: old.userInput,
        history: old.history,
        settings: resolved.settings,
        generatingNamingConfig: draftNaming ?? old.generatingNamingConfig,
        extractNamingConfig: old.extractNamingConfig,
        reviewingNamingConfig: old.reviewingNamingConfig,
        summarizeNamingConfig: old.summarizeNamingConfig,
        contextWindow: contextWindow,
        config: config.storyRuntime,
        embeddingConfig: embeddingConfig,
        turnNumber: old.turnNumber,
        connectTimeout: timeouts.connectTimeout,
        readTimeout: timeouts.readTimeout,
        currentNarrativeTime: state.session.currentNarrativeTime,
      )
        ..generatedText = old.generatedText
        ..keywords = old.keywords
        ..scoredMemories = old.scoredMemories
        ..retrievedFacts = old.retrievedFacts
        ..replyText = old.replyText
        ..thinkingContent = old.thinkingContent
        ..eventSummary = old.eventSummary
        ..factsDeltas = old.factsDeltas
        ..skipReview = old.skipReview
        // 审查  修复：保留 compaction 产出，避免从中断处重试时
        // CompactionPoint 不被持久化到数据库
        ..compactionSummary = old.compactionSummary
        ..compactionBoundaryMessageId = old.compactionBoundaryMessageId
        ..compactionSummaryMessage = old.compactionSummaryMessage
        ..segmentMacroSummary = old.segmentMacroSummary;
    } catch (e, stackTrace) {
      _logger.error(
        'Failed to reload round config, using old',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  /// 重试前清理该阶段的流式产物（避免新旧叠加）
  ///
  /// 接收当前 state，返回清理后的新 state（纯变换，不修改入参）。
  /// V2 四步流程：generating 只产出 generatedText（无关键词），extracting 产出
  /// extractedKeywords，reviewing 只产出 replyText（存 RoundContext，state 仅
  /// streamingReply 用于流式显示），summarizing 产出 currentEventSummary。
  /// P2 解耦：从 RetryScheduler 迁回（依赖 AdvancedChatState，故事专属）。
  AdvancedChatState _resetPhaseState(
    AdvancedChatState state,
    IntermediatePhase phase,
  ) {
    switch (phase) {
      case IntermediatePhase.generating:
      case IntermediatePhase.reviewing:
        // 导演轮的直播分块即 liveBlocks（agent loop 写入）
        return state.copyWith(liveBlocks: const []);
      // 其余阶段无 live 流式产物需清理（产物存 RoundContext，非 state）
      case IntermediatePhase.extracting:
      case IntermediatePhase.retrieving:
      case IntermediatePhase.summarizing:
      case IntermediatePhase.compacting:
      case IntermediatePhase.idle:
      case IntermediatePhase.generatingRetry:
      case IntermediatePhase.extractingRetry:
      case IntermediatePhase.retrievingRetry:
      case IntermediatePhase.reviewingRetry:
      case IntermediatePhase.summarizingRetry:
      case IntermediatePhase.persisting:
      case IntermediatePhase.failed:
        return state;
    }
  }
}
