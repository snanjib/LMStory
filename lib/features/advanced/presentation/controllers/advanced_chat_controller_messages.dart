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

/// 拆分到本 part 文件的消息操作 / Fork 重写方法（拆分）
///
/// 通过 extension 机制让方法仍属于 [AdvancedChatController] 类成员，
/// 可访问主文件中的私有字段（_persistenceService / _experienceRepository 等）。
extension AdvancedChatControllerMessages on AdvancedChatController {
  // ====================  简化 Fork：覆盖式重写 ====================
  //
  // advanced 侧的 canOperateMessage 死方法已删——
  // 导演 UI 的窗口判定在 director_chat_body._canOperateMessage 复刻公式
  // （零调用双实现漂移风险；故事侧 intermediate.canOperateMessage 仍在役）。

  /// 重新生成：保留 user_N，删 assistant_N + 下游 + turn≥N 事件摘要，重写 assistant_N
  ///
  /// 支持从 assistant 消息或 user 消息触发：
  /// - assistant 消息：直接作为目标，保留前一条 user_N
  /// - user 消息：自动找到下一条 assistant 作为目标，效果一致
  ///
  /// 流程：
  /// 1. 守卫：phase=idle + 推导 assistantTarget
  /// 2. 推导 targetTurn 和 messageIdsToDelete（含 assistant_N + 下游所有消息，不含 user_N）
  /// 3. 调 [_rollbackRound] 原子保存旧稿并清理下游
  /// 4. 更新 state.messages（移除删除部分）+ state.userInput = user_N 内容
  /// 5. state.regenerateTurnNumber = targetTurn（标识走 persistRegeneratedRound 分支）
  /// 6. 调 [_prepareAndRunRound] 启动导演生成
  Future<void> regenerateMessage(ChatMessage targetMessage) =>
      _runSessionOperation<void>(
        null,
        () => _regenerateMessage(targetMessage),
      );

  Future<void> _regenerateMessage(ChatMessage targetMessage) async {
    if (!_canRollbackDirectorStory) return;

    // 如果是 user 消息，找到下一条 assistant 作为重新生成的目标。
    // 效果与点击 assistant 回复的"重新生成"一致：保留 user_N，删 assistant_N + 下游。
    var assistantTarget = targetMessage;
    if (targetMessage.role == 'user') {
      final userIndex = state.messages.indexWhere(
        (m) => m.messageId == targetMessage.messageId,
      );
      if (userIndex < 0 || userIndex + 1 >= state.messages.length) return;
      assistantTarget = state.messages[userIndex + 1];
      if (assistantTarget.role != 'assistant') return;
    } else if (targetMessage.role != 'assistant') {
      return;
    }

    final targetTurn = _computeTurnNumber(assistantTarget);
    if (targetTurn == null) return;

    // 删除范围：assistant_N + 下游所有消息（不含 user_N）
    final targetIndex = state.messages.indexWhere(
      (m) => m.messageId == assistantTarget.messageId,
    );
    if (targetIndex < 0) return;
    // user_N 是 assistant_N 的前一条
    if (targetIndex == 0) return;
    final userMessage = state.messages[targetIndex - 1];
    if (userMessage.role != 'user') return;

    // 立即置"准备中"标识：DB 删除 await 期间 UI 显示遮罩，避免下游消息残留
    _historyRevision++;
    state = state.copyWith(isPreparingRegenerate: true);

    final updatedSession = await _rollbackRound(
      targetTurn: targetTurn,
      firstMessageIndex: targetIndex,
      rebuildReason: 'rerun',
      replacedAssistant: assistantTarget,
      sourceInput: userMessage.content,
      regeneratingUserInput: userMessage.content,
      keepVariantsAtFromTurn: true,
    );
    if (updatedSession == null) return;

    // 更新 state：移除删除部分，保留 user_N 作为本轮输入
    final remainingMessages = state.messages.sublist(0, targetIndex);
    // 清理 turn >= targetTurn 的历史 artifacts（与数据库 DELETE 同步）
    final updatedArtifacts = _removeArtifactsFromTurn(targetTurn);
    // 同步清理内存变体表——删轮后新轮复用轮号时
    // variantsByTurn 残留旧内容（幽灵内存面）。
    final updatedVariants = _removeVariantsFromTurn(targetTurn);
    state = state.copyWith(
      messages: remainingMessages,
      session: updatedSession,
      agentStoryAnchor: null,
      userInput: userMessage.content,
      regenerateTurnNumber: targetTurn,
      artifactsByTurnNumber: updatedArtifacts,
      variantsByTurn: updatedVariants,
      usageSummariesByTurn: _removeUsageSummariesFromTurn(targetTurn),
      backfilledPromptTokens: null,
      backfilledCacheReadTokens: null,
      backfilledTotalInputTokens: null,
      backfilledUsageWarnings: null,
      // 下游消息已截断，关闭遮罩；后续由生成阶段接管 UI 反馈
      isPreparingRegenerate: false,
    );

    await _prepareAndRunRound(cleanupAttemptEvents: false);
  }

  /// 编辑重发：删 user_N + assistant_N + 下游 + turn≥N 事件摘要，重写整轮
  ///
  /// 与 [regenerateMessage] 的差异：user_N 也删除（用新内容重写），走 persistRound 分支。
  Future<void> editAndResend(
    ChatMessage targetMessage,
    String newContent,
  ) =>
      _runSessionOperation<void>(
        null,
        () => _editAndResend(targetMessage, newContent),
      );

  Future<void> _editAndResend(
    ChatMessage targetMessage,
    String newContent,
  ) async {
    if (!_canRollbackDirectorStory) return;
    if (targetMessage.role != 'user') return;

    final targetTurn = _computeTurnNumber(targetMessage);
    if (targetTurn == null) return;

    // 删除范围：user_N + assistant_N + 下游所有消息
    final targetIndex = state.messages.indexWhere(
      (m) => m.messageId == targetMessage.messageId,
    );
    if (targetIndex < 0) return;
    // 立即置"准备中"标识：DB 删除 await 期间 UI 显示遮罩，避免下游消息残留
    _historyRevision++;
    state = state.copyWith(isPreparingRegenerate: true);

    final followingMessage = state.messages.elementAtOrNull(targetIndex + 1);
    final updatedSession = await _rollbackRound(
      targetTurn: targetTurn,
      firstMessageIndex: targetIndex,
      rebuildReason: 'edit',
      replacedAssistant:
          followingMessage?.role == 'assistant' ? followingMessage : null,
      sourceInput: targetMessage.content,
      keepVariantsAtFromTurn: true,
    );
    if (updatedSession == null) return;

    final remainingMessages = state.messages.sublist(0, targetIndex);
    // 清理 turn >= targetTurn 的历史 artifacts（与数据库 DELETE 同步）
    final updatedArtifacts = _removeArtifactsFromTurn(targetTurn);
    // 同步清理内存变体表——删轮后新轮复用轮号时
    // variantsByTurn 残留旧内容（幽灵内存面）。
    final updatedVariants = _removeVariantsFromTurn(targetTurn);
    // 立即创建 pendingUserMessage，UI 即时显示新用户消息气泡（对齐 sendMessage）
    // 修复「编辑重发期间用户消息消失」问题：原实现删除旧 user_N 后直接调
    // _prepareAndRunRound，UI 在生成完成前看不到用户消息。补齐 pendingUserMessage
    // 后，与 sendMessage 行为一致——立即显示，persist 成功后清空（已落入 messages）。
    final pendingMsg = ChatMessage(
      messageId: AdvancedChatController._uuid.v4(),
      sessionId: state.session.sessionId,
      role: 'user',
      content: newContent,
      createdAt: DateTime.now(),
    );
    state = state.copyWith(
      messages: remainingMessages,
      session: updatedSession,
      agentStoryAnchor: null,
      userInput: newContent,
      regenerateTurnNumber: null, // 走 persistRound 分支
      artifactsByTurnNumber: updatedArtifacts,
      variantsByTurn: updatedVariants,
      usageSummariesByTurn: _removeUsageSummariesFromTurn(targetTurn),
      backfilledPromptTokens: null,
      backfilledCacheReadTokens: null,
      backfilledTotalInputTokens: null,
      backfilledUsageWarnings: null,
      pendingUserMessage: pendingMsg,
      // 下游消息已截断，关闭遮罩；后续由生成阶段接管 UI 反馈
      isPreparingRegenerate: false,
      // 2026-07-29 推荐回复：编辑重发 → 本轮结束，清空候选气泡
      suggestReplies: [],
      isGeneratingSuggest: false,
      suggestExpanded: false,
      suggestFailure: null,
    );

    await _prepareAndRunRound(cleanupAttemptEvents: false);
  }

  /// 编辑消息内容（仅保存，不重新生成）
  ///
  /// 更新数据库中该消息的文本内容，不清理记忆、不删除下游消息。
  /// 适用于修正错别字等小修改。如果需要基于新内容重新生成，请用 [editAndResend]。
  ///
  /// 仅针对已持久化的消息。pendingUserMessage 的编辑请用 [editPendingUserMessage]。
  /// 返回是否保存成功（与故事侧  同批改签名；导演侧页面暂不弹提示）。
  Future<bool> editMessageContent(
    ChatMessage targetMessage,
    String newContent,
  ) =>
      _runSessionOperation<bool>(
        false,
        () async {
          if (!_canRollbackDirectorStory) return false;
          return _withHistoryMutation(
            () => _editMessageContent(targetMessage, newContent),
          );
        },
      );

  Future<bool> _editMessageContent(
    ChatMessage targetMessage,
    String newContent,
  ) async {
    // 编辑助手消息=直接改写该消息当前内容并持久化：message 行与
    // 当前变体行同事务更新（所见=所存，切换器往返不回退用户编辑）；
    // 用户消息无变体，只改 message 行。
    final editedTurn = targetMessage.role == 'assistant'
        ? _computeTurnNumber(targetMessage)
        : null;
    StoryHistoryTurnDetails? details;
    try {
      if (editedTurn != null) {
        final sessionId = state.session.sessionId;
        details = await _runHistoryTransaction(() async {
          final saved =
              await _persistenceService.updateAssistantContentAndCurrentVariant(
            sessionId: sessionId,
            turnNumber: editedTurn,
            assistantMessageId: targetMessage.messageId,
            newContent: newContent,
          );
          return saved ? _readHistoryDetails(sessionId, {editedTurn}) : null;
        });
        if (details == null) return false;
      } else {
        await _chatRepository.updateMessageContent(
          targetMessage.messageId,
          newContent,
        );
      }
    } catch (e, stackTrace) {
      _logger.error(
        'EditMessageContent failed',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }

    if (!mounted) return true;
    final newMessages = state.messages.map((m) {
      if (m.messageId == targetMessage.messageId) {
        return m.copyWith(content: newContent);
      }
      return m;
    }).toList();
    if (details != null && editedTurn != null) {
      final turns = {editedTurn};
      _loadedHistoryTurns.add(editedTurn);
      state = state.copyWith(
        messages: newMessages,
        artifactsByTurnNumber: _replaceHistoryRows(
          state.artifactsByTurnNumber,
          turns,
          details.artifacts,
        ),
        variantsByTurn:
            _replaceHistoryRows(state.variantsByTurn, turns, details.variants),
      );
    } else {
      state = state.copyWith(messages: newMessages);
    }
    return true;
  }

  /// 删除整轮：删 user_N + assistant_N + 下游 + turn≥N 事件摘要，不重新生成
  ///
  /// [targetMessage] 可以是轮次中的 user 或 assistant，均删除整轮 + 下游。
  /// 删除后保持 idle。
  Future<void> deleteRound(ChatMessage targetMessage) =>
      _runSessionOperation<void>(
        null,
        () async {
          if (!_canRollbackDirectorStory) return;
          await _withHistoryMutation(() => _deleteRound(targetMessage));
        },
      );

  Future<void> _deleteRound(ChatMessage targetMessage) async {
    final targetTurn = _computeTurnNumber(targetMessage);
    if (targetTurn == null) return;

    // 删除范围：从 user_N 开始（若 targetMessage 是 assistant，回退一位到 user_N）
    final targetIndex = state.messages.indexWhere(
      (m) => m.messageId == targetMessage.messageId,
    );
    if (targetIndex < 0) return;
    final startIndex = targetMessage.role == 'user'
        ? targetIndex
        : (targetIndex > 0 ? targetIndex - 1 : targetIndex);
    final updatedSession = await _rollbackRound(
      targetTurn: targetTurn,
      firstMessageIndex: startIndex,
      rebuildReason: 'delete-round',
    );
    if (updatedSession == null) return;

    final remainingMessages = state.messages.sublist(0, startIndex);
    // 清理 turn >= targetTurn 的历史 artifacts（与数据库 DELETE 同步）
    final updatedArtifacts = _removeArtifactsFromTurn(targetTurn);
    // 同步清理内存变体表——删轮后新轮复用轮号时
    // variantsByTurn 残留旧内容（幽灵内存面）。
    final updatedVariants = _removeVariantsFromTurn(targetTurn);
    state = state.copyWith(
      messages: remainingMessages,
      session: updatedSession,
      agentStoryAnchor: null,
      artifactsByTurnNumber: updatedArtifacts,
      variantsByTurn: updatedVariants,
      usageSummariesByTurn: _removeUsageSummariesFromTurn(targetTurn),
      backfilledPromptTokens: null,
      backfilledCacheReadTokens: null,
      backfilledTotalInputTokens: null,
      backfilledUsageWarnings: null,
      // 删轮改变请求材料且无法可靠量化 → 主数字失效（显示「—」，
      // 不得继续显示删除前的旧值；下一次请求落地后恢复实报）
      contextEstimate: const ContextUsageEstimate.unknown(),
      // 不进入 generating，保持 idle
    );

    // v0.2.3：独立宏摘要重建逻辑已移除。
    // 宏摘要现在由压缩服务在压缩时生成，删除轮次不会影响已有的分段宏摘要。
  }

  bool get _canRollbackDirectorStory =>
      state.phase == IntermediatePhase.idle &&
      !state.isManualCompacting &&
      !state.isPreparingRegenerate &&
      !state.loadingHistory &&
      !_historyMutationInFlight;

  /// 在同一事务内保存旧稿、回退正文和记忆、截断账本及重建跨越的纪元捕获。
  Future<ChatSession?> _rollbackRound({
    required int targetTurn,
    required int firstMessageIndex,
    required String rebuildReason,
    bool keepVariantsAtFromTurn = false,
    ChatMessage? replacedAssistant,
    String? sourceInput,
    String? regeneratingUserInput,
  }) async {
    final sessionId = state.session.sessionId;
    final messageIdsToDelete = state.messages
        .skip(firstMessageIndex)
        .map((message) => message.messageId)
        .toList();
    final eventLog = _agentEventLogRepository;
    final engineeringOpen =
        state.engineeringMode == EngineeringRuntimeMode.normalOpen;

    try {
      final rollback = await _runHistoryTransaction(() async {
        final history = replacedAssistant == null
            ? null
            : await _readHistoryDetails(sessionId, {targetTurn});
        return _persistenceService.rollbackRoundAndDownstream(
          sessionId: sessionId,
          fromTurnNumber: targetTurn,
          messageIdsToDelete: messageIdsToDelete,
          keepVariantsAtFromTurn: keepVariantsAtFromTurn,
          variantSnapshot: replacedAssistant == null
              ? null
              : (
                  assistant: replacedAssistant,
                  sourceInput: sourceInput,
                  process: history?.artifacts[targetTurn],
                ),
          truncateEvents: eventLog == null
              ? null
              : (id, turn) => _truncateDirectorTurnEvents(
                    id,
                    turn,
                    regeneratingUserInput: regeneratingUserInput,
                  ),
        );
      });
      if (rollback.deletedFrozenPrefix) {
        _directorRunner.invalidateFrozenPrefixMemo();
      }
      if (engineeringOpen) {
        try {
          await _engineeringCompaction?.invalidateActive(
            sessionId,
            'round-deleted',
          );
          await eventLog?.appendAll(sessionId, [
            branchRebuildMarkerEvent(reason: rebuildReason, turn: targetTurn),
          ]);
        } catch (error) {
          _logger.warn(
            'Record director branch rebuild failed',
            detail: 'errorType=${error.runtimeType}',
          );
        }
      }
      if (!mounted) return null;
      return state.session.copyWith(
        messageCount: rollback.messageCount,
        nextTurn: targetTurn,
        storyAnchor: rollback.storyAnchor,
        currentNarrativeTime: rollback.narrativeTime,
      );
    } catch (error, stackTrace) {
      _logger.error(
        'Director round rollback failed',
        detail: 'turn=$targetTurn',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted && state.isPreparingRegenerate) {
        state = state.copyWith(isPreparingRegenerate: false);
      }
      return null;
    }
  }

  /// 更新 pendingUserMessage 的文本。本轮未收稿的首句同步到可恢复草稿。
  ///
  /// 适用于失败/取消后保留的临时用户消息，用户编辑后只想保存修改不立即发送。
  Future<bool> updatePendingUserMessageContent(String newContent) =>
      _runSessionOperation(false, () async {
        final pending = state.pendingUserMessage;
        if (pending == null) return false;
        final retained = hasRetainedInput;
        if (retained && !await _saveRetainedInput(newContent)) return false;
        if (!mounted) return false;
        if (retained) _round = null;
        state = state.copyWith(
          pendingUserMessage: pending.copyWith(content: newContent),
          userInput: retained ? newContent : state.userInput,
        );
        return true;
      });

  /// 编辑重发 pendingUserMessage（未持久化的临时用户消息）
  ///
  /// 与 [editAndResend] 的差异：pendingUserMessage 未持久化，无需删除数据库记录。
  /// 用新内容走发送链路，首句保存成功后替换原失败气泡。
  ///
  /// 适用场景（DOC-09A-2 §6.5 修订）：失败/取消后保留的临时用户消息，
  /// 用户编辑后重发。支持 phase=idle（取消后）和 phase=failed（失败后）两种状态。
  Future<void> editPendingUserMessage(String newContent) =>
      _runSessionOperation<void>(
        null,
        () => _editPendingUserMessage(newContent),
      );

  Future<void> _editPendingUserMessage(String newContent) async {
    // 守卫：仅 idle/failed 可操作（与 body 中 actionsEnabled 判断一致）
    if (state.phase != IntermediatePhase.idle &&
        state.phase != IntermediatePhase.failed) {
      return;
    }
    if (state.pendingUserMessage == null) return;

    await _sendMessage(newContent);
  }

  /// 重发未持久化的临时用户消息（失败/中断轮的「重新生成」入口）
  ///
  /// 与 [editPendingUserMessage] 的差异：内容不变直接重发，等价于失败横幅的
  /// 「重试」，但额外覆盖 idle（历史遗留的静默中断轮）——pendingUserMessage
  /// 未落库，无需 DB 删除。守卫与 [editPendingUserMessage] 一致。
  Future<void> retryPendingUserMessage() async {
    if (state.phase != IntermediatePhase.idle &&
        state.phase != IntermediatePhase.failed) {
      return;
    }
    final pending = state.pendingUserMessage;
    if (pending == null) return;
    final content = pending.content ?? '';
    if (content.isEmpty) return;

    await editPendingUserMessage(content);
  }

  /// 删除 pendingUserMessage（未持久化的临时用户消息）
  ///
  /// 若为首句，先移除与气泡对应的可恢复草稿，再退出失败状态。
  ///
  /// 适用场景（DOC-09A-2 §6.5 修订）：失败/取消后保留的临时用户消息，
  /// 用户主动删除。支持 phase=idle（取消后）和 phase=failed（失败后）两种状态。
  Future<void> deletePendingUserMessage() =>
      _runSessionOperation<void>(null, _deletePendingUserMessage);

  Future<void> _deletePendingUserMessage() async {
    // 守卫：仅 idle/failed 可操作
    if (state.phase != IntermediatePhase.idle &&
        state.phase != IntermediatePhase.failed) {
      return;
    }
    final pending = state.pendingUserMessage;
    if (pending == null) return;
    final content = _retainedInput;
    if (content != null) {
      try {
        await _chatRepository.clearDirectorPendingInputIfMatches(
          pending.sessionId,
          content,
        );
        _retainedInput = null;
      } catch (e) {
        _logger.warn(
          'Clear director first input failed',
          detail: e.runtimeType.toString(),
        );
        return;
      }
      if (!mounted) return;
    }

    _streamRunner.cleanup();
    _round = null;
    state = state.clearTemporary().copyWith(
          pendingUserMessage: null,
          userInput: null,
        );
  }

  // ── ：稿件变体切换/删除 ──────────

  /// 切换该轮稿件到指定变体，并从同一事务读回该轮过程和版本。
  ///
  /// 切换即改变后续叙事走向：上下文组装读 chat_messages.content（已物化
  /// 为所选变体）；幕后回放随 artifacts 过程列改写；记忆层随所选正文
  /// 同步交换（正文=事实真源）。
  ///
  /// 拒绝切换的安全边界（记忆无法交换时不切换，正文保持原版本）：
  /// - 该轮之后还有后续轮：后续轮及其派生记忆基于当前版本生成；
  /// - 该轮已进入压缩归档区：压缩摘要已并入历史，无法安全拆出交换。
  Future<void> switchMessageVariant(
    ChatMessage assistantMessage,
    int variantIndex,
  ) =>
      _runSessionOperation<void>(
        null,
        () async {
          if (!_canRollbackDirectorStory) return;
          await _withHistoryMutation(
            () => _switchMessageVariant(assistantMessage, variantIndex),
          );
        },
      );

  Future<void> _switchMessageVariant(
    ChatMessage assistantMessage,
    int variantIndex,
  ) async {
    final turn = _computeTurnNumber(assistantMessage);
    if (turn == null) return;

    if (turn <= state.compactedTurnBase) {
      _notifyVariantSwitchBlocked('compacted');
      return;
    }
    final history = state.usageSummariesByTurn ?? state.artifactsByTurnNumber;
    if (history == null) {
      // 轮产物未装载（异常态）：无法核实是否存在后续轮，拒绝切换保数据
      _notifyVariantSwitchBlocked('downstream');
      return;
    }
    if (history.keys.any((t) => t > turn)) {
      _notifyVariantSwitchBlocked('downstream');
      return;
    }

    final sessionId = state.session.sessionId;
    final turns = {turn};
    ({
      StoryHistoryTurnDetails details,
      MessageVariantRecord selected,
      StoryAnchor? anchor,
    })? result;
    try {
      final config = await _getConfig();
      result = await _runHistoryTransaction(() async {
        final switched = await _persistenceService.switchMessageVariant(
          sessionId: sessionId,
          turnNumber: turn,
          variantIndex: variantIndex,
          assistantMessageId: assistantMessage.messageId,
          factualConfig: config.memory.factual,
        );
        if (!switched) return null;
        final details = await _readHistoryDetails(sessionId, turns);
        final selected = details.variants[turn]?.firstWhereOrNull(
          (variant) => variant.variantIndex == variantIndex,
        );
        if (selected == null) {
          throw StateError('Selected manuscript missing after switch');
        }
        final persisted = await _loadSessionQuietly(sessionId);
        return (
          details: details,
          selected: selected,
          anchor: persisted?.storyAnchor
        );
      });
    } catch (e, stackTrace) {
      _logger.error(
        'SwitchMessageVariant failed',
        detail: e.runtimeType.toString(),
        stackTrace: stackTrace,
      );
      if (mounted) _notifyVariantSwitchBlocked('restore');
      return;
    }
    if (!mounted) return;
    if (result == null) {
      _notifyVariantSwitchBlocked('restore');
      return;
    }

    final selected = result.selected;
    final newMessages = state.messages.map((m) {
      if (m.messageId == assistantMessage.messageId) {
        return m.copyWith(
          content: selected.content,
          thinkingContent: selected.thinkingContent,
        );
      }
      return m;
    }).toList();
    final summaries = state.usageSummariesByTurn;
    _loadedHistoryTurns.add(turn);
    state = state.copyWith(
      messages: newMessages,
      artifactsByTurnNumber: _replaceHistoryRows(
        state.artifactsByTurnNumber,
        turns,
        result.details.artifacts,
      ),
      variantsByTurn: _replaceHistoryRows(
        state.variantsByTurn,
        turns,
        result.details.variants,
      ),
      usageSummariesByTurn: summaries == null
          ? null
          : {
              ...summaries,
              turn: result.details.artifacts[turn]?.agentWorkSummary,
            },
      session: state.session.copyWith(storyAnchor: result.anchor),
      backfilledPromptTokens: null,
      backfilledCacheReadTokens: null,
      backfilledTotalInputTokens: null,
      backfilledUsageWarnings: null,
      // 用户已手动选版，新变体高亮信号随之消费
      variantFlashTurn: null,
      variantFlashStartedAtMs: null,
    );

    // 工程上下文模式（开启态）：事件面同步处置该轮轨迹——「先身份
    // （attemptId）后内容（proseHash）」双成立才保留，其余（含同文不同
    /// attempt）遮蔽为单行；绑定留痕不重算（生成事实）。chat 侧已交换
    // 指针；事件面与 chat 侧分两笔提交，中断窗口由下一步投影守卫兜
    //（漂移即 fail-closed 停轮，重新切换可收敛）。
    if (state.engineeringMode == EngineeringRuntimeMode.normalOpen) {
      await _applyVariantSwitchToLedger(
        turn: turn,
        variantIndex: variantIndex,
        targetContent: selected.content ?? '',
      );
    }
  }

  /// 变体切换的事件面处置（开启态）：规划遮蔽/保留并落 branch/rebuild。
  Future<void> _applyVariantSwitchToLedger({
    required int turn,
    required int variantIndex,
    required String targetContent,
  }) async {
    final repo = agentEventLogRepository;
    if (repo == null) return;
    try {
      final events = await repo.readEvents(state.session.sessionId);
      final window = DirectorSurfaceV2.epochWindowEvents(events);
      final binding = latestBindingForVariant(
        events: events,
        turn: turn,
        variantIndex: variantIndex,
      );
      final plan = planVariantSwitch(
        windowEvents: window,
        turn: turn,
        targetBinding: binding,
        targetProse: targetContent,
      );
      await repo.appendAll(state.session.sessionId, [
        branchRebuildMarkerEvent(
          reason: 'variant-switch',
          turn: turn,
          variantIndex: variantIndex,
        ),
        if (plan != null && plan.needsSurfaceChange)
          variantSwitchRebuildEvent(plan),
      ]);
      _logger.info(
        'Variant switch ledger op applied',
        detail: 'turn=$turn, variantIndex=$variantIndex, '
            'retain=${plan?.retainTrajectory}, '
            'range=${plan == null ? 'n/a' : '${plan.replaceStart}-${plan.replaceEnd}'}',
      );
    } catch (e, stackTrace) {
      _logger.error(
        'Variant switch ledger op failed',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// 删除非当前变体（当前指针所指变体不可删——那是正在使用的版本）
  Future<void> deleteMessageVariant(
    ChatMessage assistantMessage,
    int variantIndex,
  ) =>
      _runSessionOperation<void>(
        null,
        () async {
          if (!_canRollbackDirectorStory) return;
          await _withHistoryMutation(
            () => _deleteMessageVariant(assistantMessage, variantIndex),
          );
        },
      );

  Future<void> _deleteMessageVariant(
    ChatMessage assistantMessage,
    int variantIndex,
  ) async {
    final turn = _computeTurnNumber(assistantMessage);
    if (turn == null) return;
    final sessionId = state.session.sessionId;
    final turns = {turn};
    StoryHistoryTurnDetails? detail;
    try {
      detail = await _runHistoryTransaction(() async {
        final current = await _readHistoryDetails(sessionId, turns);
        final pointer = current.artifacts[turn]?.currentVariantIndex;
        if (pointer == variantIndex) return null;
        await _persistenceService.deleteMessageVariant(
          sessionId: sessionId,
          turnNumber: turn,
          variantIndex: variantIndex,
        );
        return (
          artifacts: current.artifacts,
          variants: {
            turn: (current.variants[turn] ?? const <MessageVariantRecord>[])
                .where((variant) => variant.variantIndex != variantIndex)
                .toList(),
          },
        );
      });
    } catch (e, stackTrace) {
      _logger.error(
        'DeleteMessageVariant failed',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      return;
    }
    if (!mounted || detail == null) return;
    _loadedHistoryTurns.add(turn);
    state = state.copyWith(
      artifactsByTurnNumber: _replaceHistoryRows(
        state.artifactsByTurnNumber,
        turns,
        detail.artifacts,
      ),
      variantsByTurn:
          _replaceHistoryRows(state.variantsByTurn, turns, detail.variants),
    );
  }

  /// 切换器高亮信号消费完毕（UI 2s 高亮后回调清除）
  void clearVariantFlash() {
    if (state.variantFlashTurn != null) {
      state = state.copyWith(
        variantFlashTurn: null,
        variantFlashStartedAtMs: null,
      );
    }
  }

  /// 变体切换被拒的用户提示（页面监听 tick 弹 toast，原因见
  /// AdvancedChatState.variantSwitchBlockedReason）
  void _notifyVariantSwitchBlocked(String reason) {
    state = state.copyWith(
      variantSwitchBlockedTick: state.variantSwitchBlockedTick + 1,
      variantSwitchBlockedReason: reason,
    );
  }

  /// 推导消息所在轮次号（简化 Fork）
  ///
  /// chat_messages 表无 turn_number 列，由消息在 messages 列表中的位置推导。
  ///
  ///  修复：叠加压缩基数，保证删除范围（turn≥N 的记忆/事实/
  /// artifacts）与持久化时写入的真实轮次号一致——否则压缩后从可见列表推导的
  /// N 会远小于库中真实轮次，误删大量旧记忆。
  /// 旧 index 奇偶公式改走共享工具的 role 感知配对推导
  /// （round_history_utils.turnNumberForMessage），与故事模式同一实现。
  int? _computeTurnNumber(ChatMessage message) {
    return turnNumberForMessage(
      message: message,
      messages: state.messages,
      compactedTurnBase: state.compactedTurnBase,
    );
  }

  /// 从 [AdvancedChatState.artifactsByTurnNumber] 移除 turn >= [fromTurn] 的 entry
  ///
  ///  辅助方法：在 deleteRound/regenerateMessage/editAndResend 删除轮次时
  /// 同步清理 state 中的历史 artifacts，与数据库 DELETE 保持一致。
  /// 返回清理后的新 Map（不修改原 Map）。
  Map<int, StoryRoundArtifacts>? _removeArtifactsFromTurn(
    int fromTurn,
  ) {
    _loadedHistoryTurns.removeWhere((turn) => turn >= fromTurn);
    if (state.artifactsByTurnNumber == null) return null;
    return Map<int, StoryRoundArtifacts>.from(
      state.artifactsByTurnNumber!,
    )..removeWhere((key, _) => key >= fromTurn);
  }

  Map<int, AgentWorkSummary?>? _removeUsageSummariesFromTurn(int fromTurn) {
    final summaries = state.usageSummariesByTurn;
    if (summaries == null) return null;
    return {...summaries}..removeWhere((turn, _) => turn >= fromTurn);
  }

  /// [_removeArtifactsFromTurn] 的变体表孪生——
  /// deleteRound/regenerateMessage/editAndResend 删除轮次时同步清理
  /// state.variantsByTurn（与 message_variants 的 DB 删除/保留语义一致：
  /// 起始轮变体由 keepVariantsAtFromTurn 保留时，DB 侧仍存活——本表
  /// 同步收缩到 < fromTurn，切换器数据以重载/收稿路径重建）。
  Map<int, List<MessageVariantRecord>>? _removeVariantsFromTurn(
    int fromTurn,
  ) {
    if (state.variantsByTurn == null) return null;
    return Map<int, List<MessageVariantRecord>>.from(
      state.variantsByTurn!,
    )..removeWhere((key, _) => key >= fromTurn);
  }

  /// 清空本轮：移除中间产物 + 清空 pendingUserMessage，回 idle
  ///
  /// pendingUserMessage 清空后气泡消失，userInput 保留供页面层回写到输入框。
  Future<void> clearRound() async {
    if (!hasRetainedInput) {
      _clearRoundState();
      return;
    }
    await _runSessionOperation<void>(null, () async {
      final input = _retainedInput;
      if (input == null) return;
      final id = state.session.sessionId;
      try {
        await _inputWrites;
        await _runHistoryTransaction(() async {
          await _chatRepository.setSessionDraft(id, input);
          await _chatRepository.clearDirectorPendingInputIfMatches(id, input);
        });
      } catch (e) {
        _logger.warn(
          'Return director input to draft failed',
          detail: e.runtimeType.toString(),
        );
        return;
      }
      _retainedInput = null;
      if (mounted) _clearRoundState();
    });
  }

  void _clearRoundState() {
    _streamRunner.cleanup();
    _round = null;
    state = state.clearTemporary().copyWith(
          pendingUserMessage: null,
          isStopping: false,
        );
  }
}
