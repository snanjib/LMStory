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

/// 拆分到本 part 文件的消息操作 / Fork 重写方法（拆分）
///
/// 通过 extension 机制让方法仍属于 [IntermediateChatController] 类成员，
/// 可访问主文件中的私有字段（_persistenceService / _experienceRepository 等）。
extension IntermediateChatControllerMessages on IntermediateChatController {
  // ====================  简化 Fork：覆盖式重写 ====================

  /// 判断目标消息是否在可操作窗口内（DOC-09A-1 §2.7）
  ///
  /// 公式：canOperate = targetTurn >= totalRounds - windowRounds + 1
  /// - totalRounds = messageCount ~/ 2（每轮 = user + assistant 两条消息）
  /// - targetTurn 由消息在 [IntermediateChatState.messages] 中的索引推导：
  ///   assistant at index i → turn = (i+1)~/2；user at index i → turn = (i+2)~/2
  /// - [windowRounds] 由 UI 层从 [IntermediateConfig.fork].regenerateWindowRounds 传入
  ///
  /// 不在窗口内的消息不显示动作菜单。
  bool canOperateMessage(ChatMessage message, {required int windowRounds}) {
    final targetTurn = _computeTurnNumber(message);
    if (targetTurn == null) return false;
    //  修复：最新完成轮次 = 压缩基数 + 可见真实对话轮数
    // （messageCount 含摘要卡与未持久化消息，压缩后会高估总轮数）
    // 公式收编 story_runtime 共享工具（round_history_utils），
    // 与 round_panels_builder / chat_body 同一实现。
    final totalRounds = completedTurnCount(
      compactedTurnBase: state.compactedTurnBase,
      messages: state.messages,
    );
    return targetTurn >= totalRounds - windowRounds + 1;
  }

  /// 重新生成：保留 user_N，删 assistant_N + 下游 + turn≥N 事件摘要，重写 assistant_N
  ///
  /// 支持从 assistant 消息或 user 消息触发：
  /// - assistant 消息：直接作为目标，保留前一条 user_N
  /// - user 消息：自动找到下一条 assistant 作为目标，效果一致
  ///
  /// 流程：
  /// 1. 守卫：phase=idle + 推导 assistantTarget
  /// 2. 推导 targetTurn 和 messageIdsToDelete（含 assistant_N + 下游所有消息，不含 user_N）
  /// 3. 调 [StoryPersistenceService.rollbackRoundAndDownstream] 保存旧稿并回退。
  /// 4. 更新 state.messages（移除删除部分）+ state.userInput = user_N 内容
  /// 5. state.regenerateTurnNumber = targetTurn（标识走 persistRegeneratedRound 分支）
  /// 6. 调 [_prepareAndRunRound] 启动故事模式生成
  Future<void> regenerateMessage(ChatMessage targetMessage) =>
      _runSessionOperation<void>(
        null,
        () => _regenerateMessage(targetMessage),
      );

  Future<void> _regenerateMessage(ChatMessage targetMessage) async {
    if (state.phase != IntermediatePhase.idle) return;
    // 手动压缩期间 phase 仍为 idle，但 boundary 消息若被删，
    // persistManualCompaction 会插入引用已删 boundary 的悬空压缩点。
    if (state.isManualCompacting) return;

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
    final messageIdsToDelete =
        state.messages.sublist(targetIndex).map((m) => m.messageId).toList();

    // user_N 是 assistant_N 的前一条
    if (targetIndex == 0) return;
    final userMessage = state.messages[targetIndex - 1];
    if (userMessage.role != 'user') return;

    // 立即置"准备中"标识：DB 删除 await 期间 UI 显示遮罩，避免下游消息残留
    state = state.copyWith(isPreparingRegenerate: true);

    final RoundRollbackResult rollback;
    try {
      rollback = await _persistenceService.rollbackRoundAndDownstream(
        sessionId: state.session.sessionId,
        fromTurnNumber: targetTurn,
        messageIdsToDelete: messageIdsToDelete,
        variantSnapshot: (
          assistant: assistantTarget,
          sourceInput: userMessage.content,
          process: state.artifactsByTurnNumber?[targetTurn],
        ),
      );
    } catch (e, stackTrace) {
      _logger.error(
        'Regenerate rollback failed',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      // 删除失败不进入 failed（无 LLM 调用），仅记录日志并返回
      // 回退"准备中"标识，避免 UI 永久遮罩
      if (mounted) state = state.copyWith(isPreparingRegenerate: false);
      return;
    }

    if (!mounted) return;

    // 更新 state：移除删除部分，保留 user_N 作为本轮输入
    final remainingMessages = state.messages.sublist(0, targetIndex);
    // 清理 turn >= targetTurn 的历史 artifacts（与数据库 DELETE 同步）
    final updatedArtifacts = _removeArtifactsFromTurn(targetTurn);
    // 同步收缩内存变体表（与 DB 删除/保留语义一致：起始轮变体
    // 由 keepVariantsAtFromTurn 保留在 DB，切换器数据以收稿路径重载重建）
    final updatedVariants = _removeVariantsFromTurn(targetTurn);
    state = state.copyWith(
      messages: remainingMessages,
      session: state.session.copyWith(
        messageCount: remainingMessages.length,
        currentNarrativeTime: rollback.narrativeTime,
        storyAnchor: rollback.storyAnchor,
        nextTurn: targetTurn,
      ),
      userInput: userMessage.content,
      regenerateTurnNumber: targetTurn,
      artifactsByTurnNumber: updatedArtifacts,
      variantsByTurn: updatedVariants,
      // 下游消息已截断，关闭遮罩；后续由故事模式生成小窗接管 UI 反馈
      isPreparingRegenerate: false,
    );

    await _prepareAndRunRound();
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
    if (state.phase != IntermediatePhase.idle) return;
    if (state.isManualCompacting) return; // 与手动压缩互斥
    if (targetMessage.role != 'user') return;

    final targetTurn = _computeTurnNumber(targetMessage);
    if (targetTurn == null) return;

    // 删除范围：user_N + assistant_N + 下游所有消息
    final targetIndex = state.messages.indexWhere(
      (m) => m.messageId == targetMessage.messageId,
    );
    if (targetIndex < 0) return;
    final messageIdsToDelete =
        state.messages.sublist(targetIndex).map((m) => m.messageId).toList();

    // 立即置"准备中"标识：DB 删除 await 期间 UI 显示遮罩，避免下游消息残留
    state = state.copyWith(isPreparingRegenerate: true);

    final assistantIndex = targetIndex + 1;
    final assistant = assistantIndex < state.messages.length
        ? state.messages[assistantIndex]
        : null;
    final RoundRollbackResult rollback;
    try {
      rollback = await _persistenceService.rollbackRoundAndDownstream(
        sessionId: state.session.sessionId,
        fromTurnNumber: targetTurn,
        messageIdsToDelete: messageIdsToDelete,
        keepVariantsAtFromTurn: true,
        variantSnapshot: assistant != null && assistant.role == 'assistant'
            ? (
                assistant: assistant,
                sourceInput: targetMessage.content,
                process: state.artifactsByTurnNumber?[targetTurn],
              )
            : null,
      );
    } catch (e, stackTrace) {
      _logger.error(
        'EditAndResend rollback failed',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      // 回退"准备中"标识，避免 UI 永久遮罩
      if (mounted) state = state.copyWith(isPreparingRegenerate: false);
      return;
    }

    if (!mounted) return;

    final remainingMessages = state.messages.sublist(0, targetIndex);
    // 清理 turn >= targetTurn 的历史 artifacts（与数据库 DELETE 同步）
    final updatedArtifacts = _removeArtifactsFromTurn(targetTurn);
    // 同步收缩内存变体表（同 regenerate 口径）
    final updatedVariants = _removeVariantsFromTurn(targetTurn);
    // 立即创建 pendingUserMessage，UI 即时显示新用户消息气泡（对齐 sendMessage）
    // 修复「编辑重发期间用户消息消失」问题：原实现删除旧 user_N 后直接调
    // _prepareAndRunRound，UI 在生成完成前看不到用户消息。补齐 pendingUserMessage
    // 后，与 sendMessage 行为一致——立即显示，persist 成功后清空（已落入 messages）。
    final pendingMsg = ChatMessage(
      messageId: IntermediateChatController._uuid.v4(),
      sessionId: state.session.sessionId,
      role: 'user',
      content: newContent,
      createdAt: DateTime.now(),
    );
    state = state.copyWith(
      messages: remainingMessages,
      session: state.session.copyWith(
        messageCount: remainingMessages.length,
        currentNarrativeTime: rollback.narrativeTime,
        storyAnchor: rollback.storyAnchor,
        nextTurn: targetTurn,
      ),
      userInput: newContent,
      regenerateTurnNumber: null, // 走 persistRound 分支
      artifactsByTurnNumber: updatedArtifacts,
      variantsByTurn: updatedVariants,
      pendingUserMessage: pendingMsg,
      // 下游消息已截断，关闭遮罩；后续由故事模式生成小窗接管 UI 反馈
      isPreparingRegenerate: false,
      // 2026-07-29 推荐回复：编辑重发 → 本轮结束，清空候选气泡
      suggestReplies: [],
      isGeneratingSuggest: false,
      suggestExpanded: false,
      suggestFailed: false,
    );

    await _prepareAndRunRound();
  }

  /// 编辑消息内容（仅保存，不重新生成）
  ///
  /// 更新数据库中该消息的文本内容，不清理记忆、不删除下游消息。
  /// 适用于修正错别字等小修改。如果需要基于新内容重新生成，请用 [editAndResend]。
  ///
  /// 仅针对已持久化的消息。pendingUserMessage 的编辑请用 [editPendingUserMessage]。
  /// 返回是否保存成功（页面据此弹保存反馈）。
  Future<bool> editMessageContent(
    ChatMessage targetMessage,
    String newContent,
  ) =>
      _runSessionOperation<bool>(
        false,
        () => _editMessageContent(targetMessage, newContent),
      );

  Future<bool> _editMessageContent(
    ChatMessage targetMessage,
    String newContent,
  ) async {
    if (state.phase != IntermediatePhase.idle) return false;
    if (state.isManualCompacting) return false; // 与手动压缩互斥

    // 编辑助手消息=直接改写该消息当前内容并持久化：message 行与
    // 当前变体行同事务更新（所见=所存，切换器往返不回退用户编辑）；
    // 用户消息无变体，只改 message 行。
    final editedTurn = targetMessage.role == 'assistant'
        ? _computeTurnNumber(targetMessage)
        : null;
    if (targetMessage.role == 'assistant' && editedTurn == null) return false;
    try {
      var saved = false;
      if (editedTurn != null) {
        saved =
            await _persistenceService.updateAssistantContentAndCurrentVariant(
          sessionId: state.session.sessionId,
          turnNumber: editedTurn,
          assistantMessageId: targetMessage.messageId,
          newContent: newContent,
        );
      } else if (targetMessage.role == 'user') {
        saved =
            await _persistenceService.updateUserContentAndInvalidateSourceTurn(
          sessionId: state.session.sessionId,
          turnNumber: _computeTurnNumber(targetMessage),
          userMessageId: targetMessage.messageId,
          newContent: newContent,
        );
      } else {
        await _chatRepository.updateMessageContent(
          targetMessage.messageId,
          newContent,
        );
        saved = true;
      }
      if (!saved) return false;
    } catch (e, stackTrace) {
      _logger.error(
        'EditMessageContent failed',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      return false;
    }

    // 更新 state.messages 中对应消息的 content；助手消息同步当前变体
    // 记录（切换器徽标/预览数据源），保持与持久层同口径。
    final newMessages = state.messages.map((m) {
      if (m.messageId == targetMessage.messageId) {
        return m.copyWith(content: newContent);
      }
      return m;
    }).toList();
    Map<int, List<MessageVariantRecord>>? newVariants;
    if (editedTurn != null && state.variantsByTurn != null) {
      final records = state.variantsByTurn![editedTurn];
      if (records != null && records.isNotEmpty) {
        final currentIndex =
            state.artifactsByTurnNumber?[editedTurn]?.currentVariantIndex ?? 0;
        newVariants = Map<int, List<MessageVariantRecord>>.of(
          state.variantsByTurn!,
        );
        newVariants[editedTurn] = [
          for (var i = 0; i < records.length; i++)
            if (i == currentIndex)
              MessageVariantRecord(
                variantIndex: records[i].variantIndex,
                createdAtMs: records[i].createdAtMs,
                content: newContent,
                thinkingContent: records[i].thinkingContent,
                sourceInput: records[i].sourceInput,
              )
            else
              records[i],
        ];
      }
    }
    state = state.copyWith(
      messages: newMessages,
      variantsByTurn: newVariants,
    );
    return true;
  }

  /// 删除整轮：删 user_N + assistant_N + 下游 + turn≥N 事件摘要，不重新生成
  ///
  /// [targetMessage] 可以是轮次中的 user 或 assistant，均删除整轮 + 下游。
  /// 删除后保持 idle，不启动故事模式生成。
  Future<void> deleteRound(ChatMessage targetMessage) =>
      _runSessionOperation<void>(
        null,
        () => _deleteRound(targetMessage),
      );

  Future<void> _deleteRound(ChatMessage targetMessage) async {
    if (state.phase != IntermediatePhase.idle) return;
    // 手动压缩期间删轮 = 压缩点引用已删 boundary → 压缩静默失效。
    if (state.isManualCompacting) return;

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
    final messageIdsToDelete =
        state.messages.sublist(startIndex).map((m) => m.messageId).toList();

    final RoundRollbackResult rollback;
    try {
      rollback = await _persistenceService.rollbackRoundAndDownstream(
        sessionId: state.session.sessionId,
        fromTurnNumber: targetTurn,
        messageIdsToDelete: messageIdsToDelete,
      );
    } catch (e, stackTrace) {
      _logger.error(
        'DeleteRound failed',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      return;
    }

    if (!mounted) return;

    final remainingMessages = state.messages.sublist(0, startIndex);
    // 清理 turn >= targetTurn 的历史 artifacts（与数据库 DELETE 同步）
    final updatedArtifacts = _removeArtifactsFromTurn(targetTurn);
    // 删轮不传 keepVariants（起始轮变体一并物理删除），内存表同步收缩
    final updatedVariants = _removeVariantsFromTurn(targetTurn);
    state = state.copyWith(
      messages: remainingMessages,
      session: state.session.copyWith(
        messageCount: remainingMessages.length,
        currentNarrativeTime: rollback.narrativeTime,
        storyAnchor: rollback.storyAnchor,
        nextTurn: targetTurn,
      ),
      artifactsByTurnNumber: updatedArtifacts,
      variantsByTurn: updatedVariants,
      // 删轮改变请求材料且无法可靠量化 → 主数字失效（显示「—」）
      contextEstimate: const ContextUsageEstimate.unknown(),
      // 不进入 generating，保持 idle
    );

    // v0.2.3：独立宏摘要重建逻辑已移除。
    // 宏摘要现在由压缩服务在压缩时生成，删除轮次不会影响已有的分段宏摘要。
  }

  /// 更新 pendingUserMessage 的文本内容（仅内存，不持久化、不发送）
  ///
  /// 适用于失败/取消后保留的临时用户消息，用户编辑后只想保存修改不立即发送。
  void updatePendingUserMessageContent(String newContent) {
    if (_sessionOperations.isBusy) return;
    if (state.pendingUserMessage == null) return;
    state = state.copyWith(
      pendingUserMessage:
          state.pendingUserMessage!.copyWith(content: newContent),
    );
  }

  /// 编辑重发 pendingUserMessage（未持久化的临时用户消息）
  ///
  /// 与 [editAndResend] 的差异：pendingUserMessage 未持久化，无需删除数据库记录。
  /// 仅清空临时状态 + pendingUserMessage，然后用新内容走 [sendMessage]。
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

    // 清空临时状态 + pendingUserMessage（未持久化，无需 DB 操作）
    state = state.clearTemporary().copyWith(
          pendingUserMessage: null,
          userInput: null,
        );
    _round = null;

    // 用新内容走 sendMessage（会创建新的 pendingUserMessage + 启动状态机）
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
  /// 与 [deleteRound] 的差异：pendingUserMessage 未持久化，无需删除数据库记录。
  /// 仅清空临时状态 + pendingUserMessage，回到干净 idle 状态。
  ///
  /// 适用场景（DOC-09A-2 §6.5 修订）：失败/取消后保留的临时用户消息，
  /// 用户主动删除。支持 phase=idle（取消后）和 phase=failed（失败后）两种状态。
  void deletePendingUserMessage() {
    if (_sessionOperations.isBusy) return;
    // 守卫：仅 idle/failed 可操作
    if (state.phase != IntermediatePhase.idle &&
        state.phase != IntermediatePhase.failed) {
      return;
    }
    if (state.pendingUserMessage == null) return;

    _streamRunner.cleanup();
    _round = null;
    state = state.clearTemporary().copyWith(
          pendingUserMessage: null,
          userInput: null,
        );
  }

  /// 推导消息所在轮次号（简化 Fork）
  ///
  /// chat_messages 表无 turn_number 列，由消息在 messages 列表中的位置推导。
  ///
  ///  修复：叠加压缩基数，保证删除范围（turn≥N 的记忆/事实/
  /// artifacts）与持久化时写入的真实轮次号一致——否则压缩后从可见列表推导的
  /// N 会远小于库中真实轮次，误删大量旧记忆。
  /// 旧 index 奇偶公式（assistant `(i+1)~/2` / user `(i+2)~/2`）
  /// 在孤儿 assistant / 摘要卡错位时分裂，改走共享工具的 role 感知配对推导
  /// （round_history_utils.turnNumberForMessage），公式侧唯一实现。
  int? _computeTurnNumber(ChatMessage message) {
    return turnNumberForMessage(
      message: message,
      messages: state.messages,
      compactedTurnBase: state.compactedTurnBase,
    );
  }

  /// 从 [IntermediateChatState.artifactsByTurnNumber] 移除 turn >= [fromTurn] 的 entry
  ///
  ///  辅助方法：在 deleteRound/regenerateMessage/editAndResend 删除轮次时
  /// 同步清理 state 中的历史 artifacts，与数据库 DELETE 保持一致。
  /// 返回清理后的新 Map（不修改原 Map）。
  Map<int, StoryRoundArtifacts>? _removeArtifactsFromTurn(
    int fromTurn,
  ) {
    if (state.artifactsByTurnNumber == null) return null;
    return Map<int, StoryRoundArtifacts>.from(
      state.artifactsByTurnNumber!,
    )..removeWhere((key, _) => key >= fromTurn);
  }

  /// [_removeArtifactsFromTurn] 的变体表孪生——
  /// deleteRound/regenerateMessage/editAndResend 删除轮次时同步清理
  /// state.variantsByTurn（与 message_variants 的 DB 删除/保留语义一致：
  /// 起始轮变体由 keepVariantsAtFromTurn 保留时，DB 侧仍存活——本表
  /// 同步收缩到 < fromTurn，切换器数据以收稿路径重建）。
  Map<int, List<MessageVariantRecord>>? _removeVariantsFromTurn(
    int fromTurn,
  ) {
    if (state.variantsByTurn == null) return null;
    return Map<int, List<MessageVariantRecord>>.from(
      state.variantsByTurn!,
    )..removeWhere((key, _) => key >= fromTurn);
  }

  // ── ：稿件变体切换/删除（照抄导演）──────

  /// 切换该轮稿件到指定变体（同事务改写 DB；随后整面重载 artifacts+变体）
  ///
  /// 切换即改变后续叙事走向：上下文组装读 chat_messages.content（已物化
  /// 为所选变体）。记忆层随所选正文同步交换（正文=事实真源）。
  ///
  /// 拒绝切换的安全边界（记忆无法交换时不切换，正文保持原版本）：
  /// - 该轮之后还有后续轮：后续轮及其派生记忆基于当前版本生成，切换
  ///   早期版本会造成记忆与正文混线；先删除后续轮再切换。
  /// - 该轮已进入压缩归档区：压缩摘要已并入历史，无法安全拆出交换。
  Future<void> switchMessageVariant(
    ChatMessage assistantMessage,
    int variantIndex,
  ) =>
      _runSessionOperation<void>(
        null,
        () => _switchMessageVariant(assistantMessage, variantIndex),
      );

  Future<void> _switchMessageVariant(
    ChatMessage assistantMessage,
    int variantIndex,
  ) async {
    if (state.phase != IntermediatePhase.idle) return;
    if (state.isManualCompacting) return;
    final turn = _computeTurnNumber(assistantMessage);
    if (turn == null) return;

    if (turn <= state.compactedTurnBase) {
      _notifyVariantSwitchBlocked('compacted');
      return;
    }
    final artifacts = state.artifactsByTurnNumber;
    if (artifacts == null) {
      // 轮产物未装载（异常态）：无法核实是否存在后续轮，拒绝切换保数据
      _notifyVariantSwitchBlocked('downstream');
      return;
    }
    if (artifacts.keys.any((t) => t > turn)) {
      _notifyVariantSwitchBlocked('downstream');
      return;
    }

    final config = await _getConfig();
    bool switched;
    try {
      switched = await _persistenceService.switchMessageVariant(
        sessionId: state.session.sessionId,
        turnNumber: turn,
        variantIndex: variantIndex,
        assistantMessageId: assistantMessage.messageId,
        factualConfig: config.memory.factual,
      );
    } catch (e, stackTrace) {
      _logger.error(
        'SwitchMessageVariant failed',
        detail: e.runtimeType.toString(),
        stackTrace: stackTrace,
      );
      _notifyVariantSwitchBlocked('restore');
      return;
    }
    if (!switched) {
      _notifyVariantSwitchBlocked('restore');
      return;
    }

    // 整面重载（artifacts 过程列/指针 + 变体列表 + 消息 content）——
    // 单次用户动作两查可接受，避免在内存里二次拼装变体过程数据
    final artifactsMap = await _persistenceService.loadArtifactsBySession(
      state.session.sessionId,
    );
    final variants = await _persistenceService.loadMessageVariants(
      state.session.sessionId,
    );
    final turnVariants = variants[turn] ?? const <MessageVariantRecord>[];
    final selected =
        turnVariants.where((v) => v.variantIndex == variantIndex).firstOrNull;

    final newMessages = state.messages.map((m) {
      if (m.messageId == assistantMessage.messageId) {
        return m.copyWith(
          content: selected?.content ?? m.content,
          thinkingContent: selected?.thinkingContent ?? m.thinkingContent,
        );
      }
      return m;
    }).toList();
    // 会话当前锚随变体切换回拨——service
    // 事务内已把 chat_sessions.story_anchor 同步为变体锚（NULL 时按
    // 05aaa3fb 语义回退存活轮最近锚），此处读回同步内存态，保持锚与
    // 正文版本一致。读失败不阻断切换（仅内存态滞后到下次 loadHistory
    // 收敛）。
    StoryAnchor? syncedAnchor;
    try {
      syncedAnchor = (await _chatRepository.getSession(state.session.sessionId))
          .storyAnchor;
    } catch (e) {
      _logger.warn(
        'Reload session anchor after variant switch failed',
        detail: '$e',
      );
    }
    state = state.copyWith(
      messages: newMessages,
      artifactsByTurnNumber: artifactsMap,
      variantsByTurn: variants,
      session: state.session.copyWith(storyAnchor: syncedAnchor),
      // 用户已手动选版，新变体高亮信号随之消费
      variantFlashTurn: null,
      variantFlashStartedAtMs: null,
    );
  }

  /// 删除非当前变体（当前指针所指变体不可删——那是正在使用的版本）
  Future<void> deleteMessageVariant(
    ChatMessage assistantMessage,
    int variantIndex,
  ) =>
      _runSessionOperation<void>(
        null,
        () => _deleteMessageVariant(assistantMessage, variantIndex),
      );

  Future<void> _deleteMessageVariant(
    ChatMessage assistantMessage,
    int variantIndex,
  ) async {
    if (state.phase != IntermediatePhase.idle) return;
    final turn = _computeTurnNumber(assistantMessage);
    if (turn == null) return;
    final pointer = state.artifactsByTurnNumber?[turn]?.currentVariantIndex;
    if (pointer == variantIndex) return;

    try {
      await _persistenceService.deleteMessageVariant(
        sessionId: state.session.sessionId,
        turnNumber: turn,
        variantIndex: variantIndex,
      );
    } catch (e, stackTrace) {
      _logger.error(
        'DeleteMessageVariant failed',
        detail: '$e',
        error: e,
        stackTrace: stackTrace,
      );
      return;
    }
    final updated = Map<int, List<MessageVariantRecord>>.from(
      state.variantsByTurn ?? const {},
    );
    updated[turn] = (updated[turn] ?? const [])
        .where((v) => v.variantIndex != variantIndex)
        .toList();
    state = state.copyWith(variantsByTurn: updated);
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
  /// IntermediateChatState.variantSwitchBlockedReason）
  void _notifyVariantSwitchBlocked(String reason) {
    state = state.copyWith(
      variantSwitchBlockedTick: state.variantSwitchBlockedTick + 1,
      variantSwitchBlockedReason: reason,
    );
  }

  /// 清空本轮：移除中间产物 + 清空 pendingUserMessage，回 idle
  ///
  /// pendingUserMessage 清空后气泡消失，userInput 保留供页面层回写到输入框。
  void clearRound() {
    _streamRunner.cleanup();
    _round = null;
    state = state.clearTemporary().copyWith(
          pendingUserMessage: null,
          isStopping: false,
        );
  }
}
