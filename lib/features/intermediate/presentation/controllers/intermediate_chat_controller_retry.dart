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

/// 拆分到本 part 文件的失败处理 / 自动重试 / 手动续跑方法（拆分）
///
/// 通过 extension 机制让方法仍属于 [IntermediateChatController] 类成员，
/// 可访问主文件中的私有字段（_streamRunner / _retryScheduler / _round 等）。
/// 从原始异常提取 Retry-After 冷却指示
///
/// 非流式路径（AppHttpException）读响应头；流式路径（StreamErrorException）
/// 读 wire 层透传字段。均无则 null（走默认延迟）。
Duration? _retryAfterFromError(Object? error) {
  if (error is AppHttpException) {
    return parseRetryAfter(headers: error.headers);
  }
  if (error is StreamErrorException) {
    return error.retryAfter;
  }
  return null;
}

extension IntermediateChatControllerRetry on IntermediateChatController {
  // ==================== 失败 / 重试 ====================

  /// 第一个非空字符串（快照取值用），全空返回 null。
  String? _firstNonEmpty(String? a, String? b) {
    if (a != null && a.isNotEmpty) return a;
    if (b != null && b.isNotEmpty) return b;
    return null;
  }

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
  }) async {
    if (!mounted || error is CancelledException || _streamRunner.isCancelled) {
      return;
    }

    // MEM-06：检索链路失败（E104 / 检索异常）时附带记忆索引体检
    //（fire-and-forget 记日志——不阻塞失败处理，不弹 UI；体检异常
    // 在 _logMemoryIndexHealth 内全吞；与导演侧 _fail 同构）
    if (errorCode == 'E104' || error is MemoryRetrievalUnavailableException) {
      unawaited(_logMemoryIndexHealth('round-failed:$errorCode'));
    }

    // 审查收官 /：上下文超限不进自动重试——超限重发同一
    // 载荷必然再超限（导演侧同款口径），且自动重试会复位  自愈旗标
    // 造成「二次压缩+必败重发」循环。直进 failed 终态（用户重试时历史
    // 已被自愈压缩过，有真实成功面）
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

    // persisting 阶段一律走 failed 终态，不进自动重试。
    // toRetryPhase(persisting)=failed 且重跑 switch 无 persisting 分支——
    // 进 _scheduleRetry 只会空转：phase=failed 但 failureContext=null，
    // 无 FailureBar/无提示/无失败日志，regenerate 场景会话死锁到重启。
    // E104 的"临时降级"出口（continueWithFts5Only）也依赖 failed 终态可达。
    // P6 预算闸（2026-10-15 批 E）：累计纯等待超 90s 提前放弃——
    // 防连续长冷却（单次 Retry-After 封顶 60s）纯等约 5 分钟。
    final retryAfter = _retryAfterFromError(error);
    final nextDelay = _retryScheduler.retryDelay(
      errorCode,
      retryAfter: retryAfter,
    );
    final budgetExceeded = const RetryPolicy().exceedsBudget(
      _retryWaitTotal,
      nextDelay,
    );
    if (currentCount < maxRetries &&
        !budgetExceeded &&
        _round != null &&
        phase != IntermediatePhase.persisting) {
      // 可重试：进入 *Retry 状态，延迟后重跑。
      // 限流场景提取 Retry-After 冷却指示（Retry-After 头/流语义码
      // 透传），调度器按指示冷却而非固定 1s。
      _retryWaitTotal += nextDelay;
      await _scheduleRetry(
        phase: phase,
        errorCode: errorCode,
        retryCount: currentCount + 1,
        retryAfter: retryAfter,
        delay: nextDelay,
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

      // 失败时把流式缓冲里的非空正文快照进
      // partialReplySnapshot（failed 态半截稿件卡的数据源）。优先
      // streamingGenerated（review-on 生成草稿——中断时即正文最完整形态），
      // 回退 streamingReply（review-off 直写/审查修正稿）。无可快照时保留
      // 旧值：同轮续跑秒败（续写指令发出即断网）时流式缓冲为空，保留上一
      // 次快照才不丢「以此收稿」出口；跨轮陈旧由 clearTemporary 清理。
      final partial = _firstNonEmpty(
        state.streamingGenerated,
        state.streamingReply,
      );
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
        ),
        partialReplySnapshot: partial ?? state.partialReplySnapshot,
      );

      //  诊断包：持久化失败上下文到 failure_logs 表（unawaited 不阻塞状态机）
      // 日志写入失败由 Repository 静默降级，不影响主流程
      unawaited(
        _sessionOperations.runBackgroundWrite(
          () => _failureLogRepository.insertLog(
            sessionId: state.session.sessionId,
            mode: state.session.mode,
            errorCategory: category.name,
            errorCode: errorCode,
            failedPhase: phase.name,
            httpStatus: httpStatus,
            errorMessage: message,
            rawError: rawError,
          ),
        ),
      );
      // 2026-07-22 修复（问题 1-A）：不再清空 _round。
      // 保留 _round 让"从中断处继续"（continueFromFailed）能复用已完成阶段的产出。
      // 用户主动 clearRound / retry / cancel 时仍会清空 _round。
    }
  }

  /// 调度自动重试：进入 *Retry 状态，延迟后重跑该阶段
  ///
  /// [retryAfter] = 服务端冷却指示（：Retry-After 头解析产物，
  /// null 时调度器用默认延迟）。
  Future<void> _scheduleRetry({
    required IntermediatePhase phase,
    required String errorCode,
    required int retryCount,
    required Duration delay,
    Duration? retryAfter,
  }) async {
    final retryPhase = _retryScheduler.toRetryPhase(phase);
    state = state.copyWith(
      phase: retryPhase,
      retryCounts: {...state.retryCounts, phase: retryCount},
    );

    if (delay > Duration.zero && !_streamRunner.isCancelled) {
      await _sessionOperations.waitForRetry(delay);
    }

    // 取消或状态已变（用户操作）则放弃重试
    if (!mounted ||
        _streamRunner.isCancelled ||
        state.phase != retryPhase ||
        _round == null) {
      return;
    }

    // 2026-10-15 批 G：generating 流中断自动重试改**续写式**——
    // 半截正文快照后作 continuationPrefix 注入重跑（等价自动执行
    // 「从中断处继续」，与手动续跑同链路：prefix 进续写指令块，模型从
    // 断点自然续写不重复）；零输出（首字节前失败）= 无前缀退化普通重跑。
    // 重试粒度是断点而非整轮——「自动重试=整轮重跑本身就是一种错误」。
    // E016 之外的阶段错误（关键词/摘要失败无正文概念）维持整阶段重跑。
    if (phase == IntermediatePhase.generating) {
      final partial = _firstNonEmpty(
        state.streamingGenerated,
        state.streamingReply,
      );
      if (partial != null && partial.isNotEmpty) {
        _round!.continuationPrefix = partial;
      }
    }

    // 清理该阶段流式产物，避免新旧叠加（快照已先行取走注入前缀）
    state = _resetPhaseState(state, phase);

    // 重跑该阶段（V2 六步流程：6 个阶段均支持重试重跑）
    // compacting 失败映射 E018（0 次重试），不会走到此处重跑逻辑，
    // 与不可重试阶段一起 break（逻辑上不可达，仅为 switch 完备性）。
    switch (phase) {
      case IntermediatePhase.generating:
        await _runGeneratePhase(_round!);
      case IntermediatePhase.extracting:
        await _runExtractPhase(_round!);
      case IntermediatePhase.retrieving:
        await _runRetrievePhase(_round!);
      case IntermediatePhase.reviewing:
        await _runReviewPhase(_round!);
      case IntermediatePhase.summarizing:
        await _runSummarizePhase(_round!);
      case IntermediatePhase.compacting:
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

  /// 整轮重试：清中间产物，保留 userInput 和 regenerateTurnNumber，从 extracting 重新开始
  ///
  /// 若当前为"重新生成"流程（regenerateTurnNumber != null），重试时保留该标识，
  /// 重新走 persistRegeneratedRound 分支。普通发送场景重试走 persistRound 分支。
  ///
  /// 草稿预检 E010（轮前失败）后会话仍为
  /// 草稿——重试时与 [sendMessage] 同口径复检配置：可用才物化并继续；
  /// 仍不可用则再次进 failed（fresh E010），不静默 no-op。
  ///
  /// userInput 已被状态回写清空时，依次从本轮用户气泡
  /// （pendingUserMessage，轮前失败场景保留）与消息列表尾部用户消息恢复
  /// 输入，不再静默 return（表现为失败横幅下「整轮重试」点击无响应）；
  /// 确实无可恢复输入时复位 idle 并记录日志。
  Future<void> retry() => _runSessionOperation<void>(null, _retry);

  Future<void> _retry() async {
    if (state.phase != IntermediatePhase.failed) return;
    final input = state.userInput ?? _recoverRoundInput();
    if (input == null || input.isEmpty) {
      _logger.warn(
        'Retry requested but no input recoverable; resetting to idle',
      );
      state = state.copyWith(
        phase: IntermediatePhase.idle,
        failureContext: null,
        pendingUserMessage: null,
      );
      return;
    }

    // 保留跨重试的轮次标识（clearTemporary 会清空，这里恢复）
    final regenerateTurnNumber = state.regenerateTurnNumber;

    // 轮前失败（_round=null）不可能是重生成流程，regenerateTurnNumber 恒 null
    if (isDraftSession) {
      if (!await _precheckAndMaterializeDraft()) {
        await _fail(
          IntermediatePhase.extracting,
          'E010',
          errorCategory: ErrorCategory.config,
        );
        return;
      }
    }

    _round = null;
    state = state.clearTemporary().copyWith(
          userInput: input,
          regenerateTurnNumber: regenerateTurnNumber,
        );
    await _prepareAndRunRound();
  }

  /// 从本轮用户气泡 / 消息列表尾部用户消息恢复整轮重试的输入
  /// （：failed 态 userInput 被状态回写清空时的兜底）。
  String? _recoverRoundInput() {
    final pending = state.pendingUserMessage;
    final pendingContent = pending?.content;
    if (pending != null &&
        pending.role == 'user' &&
        pendingContent != null &&
        pendingContent.isNotEmpty) {
      return pendingContent;
    }
    // 第二序仅在重生成流程启用——普通发送场景
    // 列表尾部用户消息是「上一轮」的输入，捞来当本轮内容重发会产生
    // 重复轮次；双空时直接走「复位 idle」分支。
    if (state.regenerateTurnNumber == null) return null;
    for (final message in state.messages.reversed) {
      if (message.role != 'user') continue;
      final content = message.content;
      if (content != null && content.isNotEmpty) return content;
    }
    return null;
  }

  /// 用户选择"临时降级继续本轮"（E104 错误时调用）
  ///
  /// 2026-07-21 新增。重跑 retrieving 阶段但跳过 embedding 调用，仅用 FTS5 检索。
  /// 本轮生成的记忆 has_embedding=false（后续可通过"重建向量索引"补全）。
  /// 本轮的检索小窗会显示「临时降级」标签。
  ///
  /// 实现要点：
  /// - 守卫：phase=failed + errorCode=E104（其他错误码不展示该按钮）
  /// - 标记 [IntermediateChatState.embeddingDegradedForRound] = true，
  ///   后续 [_resolveQueryVector] / [_resolveEmbedding] 检查该标记直接返回 null
  /// - 清空 failureContext 和 retryCounts，phase 切回 retrieving
  /// - 重跑 [_runRetrievePhase]：embedding 跳过 → 纯 FTS5 检索 → 后续阶段正常推进
  ///
  /// 与 [retry] 的区别：retry 完全重跑全流程（含 extracting）；本方法从 retrieving
  /// 阶段续跑（keywords 已存在，复用）。
  Future<void> continueWithFts5Only() =>
      _runSessionOperation<void>(null, _continueWithFts5Only);

  Future<void> _continueWithFts5Only() async {
    if (_round == null) return;
    if (state.phase != IntermediatePhase.failed) return;
    if (state.failureContext?.errorCode != 'E104') return;

    final failedPhase = state.failureContext?.failedPhase;
    state = state.copyWith(
      embeddingDegradedForRound: true,
      phase: IntermediatePhase.retrieving,
      failureContext: null,
      retryCounts: {},
    );

    // E104 发生在 persisting 时轮次产出已齐
    //（失败点=固化的 embedding 调用），置降级后直接续跑固化即可；此前一律
    // 从 retrieving 重跑会把 generating/reviewing/summarizing 共 2-3 次
    // LLM 调用全部重做，回复内容还会被换掉（用户视角："点了降级，
    // 刚写好的稿子被换掉了"）。
    if (failedPhase == IntermediatePhase.persisting) {
      await _runPersistPhase(_round!);
      return;
    }

    // 重跑 retrieving 阶段
    // _resolveQueryVector 会在开头检查 state.embeddingDegradedForRound
    // 并返回 null（跳过 embedding 调用），仅走 FTS5 检索
    await _runRetrievePhase(_round!);
  }

  /// 以未完成正文收稿——「以此收稿」按钮回调。
  ///
  /// generating/reviewing 失败且快照非空时可用：replyText=快照，跳过
  /// 剩余生成/审查，直奔 summarizing→persist（照 continueWithFts5Only 的
  /// persisting 短路样板）。eventSummary 由 summarize handler 正常产出
  /// （persistRound 的 eventSummary required 不绕过）。
  ///
  /// 流式字段不在此时清空：summarizing 阶段不写流式缓冲，正文保持可见；
  /// 若 summarize/persist 再失败，_fail 仍能从流式缓冲重建快照（收稿
  /// 出口不丢）。
  Future<void> acceptPartialReplyAsFinal() =>
      _runSessionOperation<void>(null, _acceptPartialReplyAsFinal);

  Future<void> _acceptPartialReplyAsFinal() async {
    if (state.phase != IntermediatePhase.failed) return;
    if (_round == null) return;
    final failedPhase = state.failureContext?.failedPhase;
    if (failedPhase != IntermediatePhase.generating &&
        failedPhase != IntermediatePhase.reviewing) {
      return;
    }
    final snapshot = state.partialReplySnapshot;
    if (snapshot == null || snapshot.isEmpty) return;

    _round!.replyText = snapshot;
    state = state.copyWith(
      phase: IntermediatePhase.summarizing,
      failureContext: null,
      retryCounts: {},
      // 快照落到回复位（streamingReply 是正文显示位；streamingGenerated
      // 保持原值——review-on 时生成面板仍展示草稿，与正常收稿同构）
      streamingReply: snapshot,
    );
    await _runSummarizePhase(_round!);
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
  Future<void> continueFromFailed() =>
      _runSessionOperation<void>(null, _continueFromFailed);

  Future<void> _continueFromFailed() async {
    if (state.phase != IntermediatePhase.failed) return;
    // 轮前失败（草稿预检/配置加载/轮内
    // E010 发生在 _round 创建之前）无产出可续——按本方法文档语义
    // （extracting 失败等价于整轮重试）委托 [retry]，从 extracting
    // 重新开始，避免按钮静默 no-op。
    if (_round == null) {
      await _retry();
      return;
    }
    final failureContext = state.failureContext;
    if (failureContext == null) return;

    final oldRound = _round!;
    final failedPhase = failureContext.failedPhase;

    // 重新解析配置（用户可能修改过模型/温度等），失败时用旧配置兜底
    _round = await _reloadRoundConfigPreservingOutputs(oldRound) ?? oldRound;

    // 续跑前清失败阶段的流式缓冲（_scheduleRetry
    // _resetPhaseState 清场此前只覆盖自动重试路径——手动续跑不清场时
    // 追加式缓冲会把新旧正文拼接重复）。快照先取走再清场。
    final snapshot = state.partialReplySnapshot;
    state = _resetPhaseState(state, failedPhase).copyWith(
      phase: failedPhase,
      failureContext: null,
      retryCounts: {},
      // 审查开关随重解析同步——失败
      // 期间用户翻转审查开关后，UI 的 GeneratePanel 显隐判据
      // （state.isReviewEnabled）仍停留旧值，与实际流向短暂错位。
      isReviewEnabled: _shouldReview(_round!),
    );

    // 续写注入：generating 失败且有半截正文 →
    // 把快照作为前缀上下文注入重跑的生成请求（「从中断处自然继续，
    // 不重复」）。reviewing 失败时草稿已完整，重跑审查无需注入。
    if (failedPhase == IntermediatePhase.generating &&
        snapshot != null &&
        snapshot.isNotEmpty) {
      _round!.continuationPrefix = snapshot;
    }

    // 从失败阶段继续（导演模式已拆分至 AdvancedChatController）
    switch (failedPhase) {
      case IntermediatePhase.generating:
        // generating 失败：无产出可复用，从 generating 重新开始
        // _runGeneratePhase 内部会根据 _shouldReview 决定是否跳过 reviewing
        await _runGeneratePhase(_round!);
      case IntermediatePhase.compacting:
        // compacting 失败后用户点"继续"，重新检测阈值并压缩
        // （_runCompactionPhase 内部判断是否需要压缩，无论是否压缩都调用 _runExtractPhase）
        await _runCompactionPhase(_round!);
      case IntermediatePhase.extracting:
        await _runExtractPhase(_round!);
      case IntermediatePhase.retrieving:
        await _runRetrievePhase(_round!);
      case IntermediatePhase.reviewing:
        // 用户可能在 failed 期间修改了 reviewEnabled 配置。
        // 若新配置为 false（跳过 reviewing），用生成内容作为最终回复直接进入 summarizing，
        // 而非强行重跑 reviewing（否则会与用户意图冲突）。
        if (_shouldReview(_round!)) {
          await _runReviewPhase(_round!);
        } else {
          // 生成即最终：复用已有 generatedText，跳过 reviewing
          _round!.replyText = _round!.generatedText ?? '';
          state = state.copyWith(
            streamingReply: _round!.generatedText,
            phase: IntermediatePhase.summarizing,
          );
          await _runSummarizePhase(_round!);
        }
      case IntermediatePhase.summarizing:
        await _runSummarizePhase(_round!);
      case IntermediatePhase.persisting:
        await _runPersistPhase(_round!);
      case IntermediatePhase.idle:
      case IntermediatePhase.generatingRetry:
      case IntermediatePhase.extractingRetry:
      case IntermediatePhase.retrievingRetry:
      case IntermediatePhase.reviewingRetry:
      case IntermediatePhase.summarizingRetry:
      case IntermediatePhase.failed:
        // *Retry 不应出现在 failedPhase
        state = state.copyWith(phase: IntermediatePhase.idle);
    }
  }

  /// 重新解析轮次配置，保留旧产出字段（供 [continueFromFailed] 使用）
  ///
  /// 返回新的 RoundContext（配置更新 + 产出保留）；解析失败返回 null（调用方用旧 _round 兜底）。
  Future<RoundContext?> _reloadRoundConfigPreservingOutputs(
    RoundContext old,
  ) async {
    try {
      var config = await _getConfig();
      final jsonOverride = state.session.jsonModeOverride;
      if (jsonOverride != null) {
        config = _applyToolCallingOverride(config, jsonOverride);
      }

      final draftNaming =
          await _configurationResolver.resolveIntermediatePhaseNamingConfig(
        state.session,
        'generating',
      );
      final extractNaming =
          await _configurationResolver.resolveIntermediatePhaseNamingConfig(
        state.session,
        'extracting',
      );
      final reviewingNaming =
          await _configurationResolver.resolveIntermediatePhaseNamingConfig(
        state.session,
        'reviewing',
      );
      final summarizeNaming =
          await _configurationResolver.resolveIntermediatePhaseNamingConfig(
        state.session,
        'summarizing',
      );
      // 2026-08-04 修复：与主流程一致，从 generating 阶段模型配置解析 contextWindow
      final generatingModelWindow =
          await _configurationResolver.resolveContextWindowForPhase(
        presetId: draftNaming?.presetId,
        modelId: draftNaming?.modelId,
      );
      final embeddingConfig =
          await _configurationResolver.resolveEmbeddingConfig();
      final timeouts = await _configurationResolver.resolveTimeouts();
      final resolved = await _configurationResolver.resolveIntermediateSettings(
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
        extractNamingConfig: extractNaming ?? old.extractNamingConfig,
        reviewingNamingConfig: reviewingNaming ?? old.reviewingNamingConfig,
        summarizeNamingConfig: summarizeNaming ?? old.summarizeNamingConfig,
        contextWindow: contextWindow,
        config: config.storyRuntime,
        embeddingConfig: embeddingConfig,
        turnNumber: old.turnNumber,
        connectTimeout: timeouts.connectTimeout,
        readTimeout: timeouts.readTimeout,
        currentNarrativeTime: state.session.currentNarrativeTime,
      )
        ..generatedText = old.generatedText
        // 续写前缀同属跨重载保留的产出
        ..continuationPrefix = old.continuationPrefix
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
  /// P2 解耦：从 RetryScheduler 迁回（依赖 IntermediateChatState，故事专属）。
  IntermediateChatState _resetPhaseState(
    IntermediateChatState state,
    IntermediatePhase phase,
  ) {
    switch (phase) {
      case IntermediatePhase.generating:
        // review-off（默认）时 generating 增量写
        // streamingReply，只清 streamingGenerated 会漏掉真正的
        // 追加式缓冲——自动重试/续跑会拼接重复正文，两个缓冲都清。
        return state.copyWith(
          streamingGenerated: '',
          streamingReply: '',
          generatedText: null,
        );
      case IntermediatePhase.extracting:
        return state.copyWith(extractedKeywords: null);
      case IntermediatePhase.retrieving:
        return state.copyWith(retrievedMemories: null);
      case IntermediatePhase.reviewing:
        return state.copyWith(streamingReply: '');
      case IntermediatePhase.summarizing:
        return state.copyWith(currentEventSummary: null);
      // compacting 无流式产物需清理（摘要存 RoundContext，非 state）
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
