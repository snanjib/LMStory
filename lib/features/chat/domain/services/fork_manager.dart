import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/fork_anchor.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';

/// Fork 操作回滚信息
///
/// 在 `regenerateInNewFork`/`editAndResendInNewFork` 中创建，
/// 流式成功完成时清除，失败时由 [ForkManager.rollbackForkIfNeeded] 消费。
class ForkRollbackInfo {
  const ForkRollbackInfo({
    required this.anchorUserMsgId,
    required this.branchIndex,
    required this.originalContent,
  });

  /// Fork 锚点用户消息 ID
  final String anchorUserMsgId;

  /// 本次创建的分支索引
  final int branchIndex;

  /// 用户消息原始内容（仅 editAndResend 需要，regenerate 为 null）
  final String? originalContent;
}

/// Fork 分支切换方向
enum ForkSwitchDirection { prev, next }

/// Fork 分支管理器
///
/// 从 ChatModeController 中抽离的 Fork 分支管理职责，包括：
/// - 重新生成（在新分支中生成，旧分支保存为快照）
/// - 编辑重发（在新分支中生成）
/// - 分支切换（循环切换，快照模型下交换 DB 与快照中的消息）
/// - 分支回滚（API 失败或用户取消时回滚分支记录）
///
/// 快照模型说明：
/// - chat_messages 表仅存储当前活跃分支的消息
/// - 非活跃分支的消息以 JSON 快照存储在 chat_session_branches.branch_snapshots
/// - 重新生成 = 保存当前尾部消息为快照 + 删除 + 生成新分支
/// - 切换分支 = 在 DB 与快照之间交换消息
class ForkManager {
  ForkManager({
    required ChatRepository chatRepository,
    required Logger logger,
  })  : _chatRepository = chatRepository,
        _logger = logger;

  final ChatRepository _chatRepository;
  final Logger _logger;

  /// 当前待回滚的 Fork 操作信息（API 失败或用户取消时使用）
  ForkRollbackInfo? pendingForkRollback;

  /// 重新生成指定助手消息（在新分支中生成，旧分支保存为快照）
  ///
  /// 对标 ChatBox regenerateInNewFork：
  /// 1. 找到助手消息的锚点用户消息
  /// 2. 收集尾部消息（旧助手回复 + 后续对话）
  /// 3. 调用 addAssistantBranchAndSnapshot 保存快照并创建新分支
  /// 4. 返回新分支索引和截断后的消息列表
  ///
  /// 返回 null 表示操作失败（消息不存在、锚点缺失等）。
  Future<RegenerateResult?> regenerateInNewFork({
    required String sessionId,
    required String assistantMessageId,
    required List<ChatMessage> currentMessages,
  }) async {
    final assistantMessage = currentMessages.firstWhere(
      (m) => m.messageId == assistantMessageId,
      orElse: () => ChatMessage(
        messageId: '',
        sessionId: '',
        role: 'assistant',
        createdAt: DateTime.now(),
      ),
    );
    if (assistantMessage.messageId.isEmpty) return null;

    final anchorUserMsgId = assistantMessage.parentUserMsgId;
    if (anchorUserMsgId == null) return null;

    final userMessage = currentMessages.firstWhere(
      (m) => m.messageId == anchorUserMsgId,
      orElse: () => ChatMessage(
        messageId: '',
        sessionId: '',
        role: 'user',
        createdAt: DateTime.now(),
      ),
    );
    if (userMessage.messageId.isEmpty) return null;

    // 收集尾部消息（旧助手回复 + 后续所有对话）
    final tailMessages = getTailMessages(currentMessages, anchorUserMsgId);

    // 创建新分支并保存旧分支快照
    final newBranchIndex = await _chatRepository.addAssistantBranchAndSnapshot(
      sessionId: sessionId,
      anchorUserMsgId: anchorUserMsgId,
      tailMessages: tailMessages,
    );

    // 截断消息列表到锚点用户消息（含），新助手消息将由流式响应添加
    final anchorIndex = currentMessages.indexWhere(
      (m) => m.messageId == anchorUserMsgId,
    );
    final truncated = anchorIndex >= 0
        ? currentMessages.sublist(0, anchorIndex + 1)
        : currentMessages;

    // 记录回滚信息
    pendingForkRollback = ForkRollbackInfo(
      anchorUserMsgId: anchorUserMsgId,
      branchIndex: newBranchIndex,
      originalContent: null,
    );

    return RegenerateResult(
      newBranchIndex: newBranchIndex,
      userMessage: userMessage,
      truncatedMessages: truncated,
      anchorUserMsgId: anchorUserMsgId,
    );
  }

  /// 编辑用户消息并重新发送（在新分支中生成）
  ///
  /// 对标 ChatBox 的 "Save & Resend"：
  /// 1. 原地更新用户消息内容
  /// 2. 收集尾部消息，调用 addAssistantBranchAndSnapshot 保存快照
  /// 3. 返回新分支索引和截断后的消息列表
  Future<RegenerateResult?> editAndResendInNewFork({
    required String sessionId,
    required String userMessageId,
    required String newContent,
    required List<ChatMessage> currentMessages,
  }) async {
    final userMessage = currentMessages.firstWhere(
      (m) => m.messageId == userMessageId,
      orElse: () => ChatMessage(
        messageId: '',
        sessionId: '',
        role: 'user',
        createdAt: DateTime.now(),
      ),
    );
    if (userMessage.messageId.isEmpty) return null;

    // 1. 原地更新用户消息内容（记录原文以便失败时回滚）
    final originalContent = userMessage.content ?? '';
    await _chatRepository.updateMessageContent(userMessageId, newContent);
    final editedUserMessage = userMessage.copyWith(content: newContent);

    // 2. 收集尾部消息并创建新分支快照
    final tailMessages = getTailMessages(currentMessages, userMessageId);
    final branchIndex = await _chatRepository.addAssistantBranchAndSnapshot(
      sessionId: sessionId,
      anchorUserMsgId: userMessageId,
      tailMessages: tailMessages,
    );

    // 记录回滚信息
    pendingForkRollback = ForkRollbackInfo(
      anchorUserMsgId: userMessageId,
      branchIndex: branchIndex,
      originalContent: originalContent,
    );

    // 3. 截断消息列表到编辑后的用户消息（含），更新内容
    final anchorIndex = currentMessages.indexWhere(
      (m) => m.messageId == userMessageId,
    );
    final truncated = anchorIndex >= 0
        ? currentMessages.sublist(0, anchorIndex + 1).map((m) {
            if (m.messageId == userMessageId) return editedUserMessage;
            return m;
          }).toList()
        : currentMessages;

    return RegenerateResult(
      newBranchIndex: branchIndex,
      userMessage: editedUserMessage,
      truncatedMessages: truncated,
      anchorUserMsgId: userMessageId,
    );
  }

  /// 切换 Fork 分支（循环切换）
  ///
  /// 对标 ChatBox switchFork：在 prev/next 间循环切换。
  /// 快照模型：交换 DB 与快照中的消息。
  ///
  /// 返回切换后的新消息列表，null 表示无法切换（锚点不存在等）。
  Future<List<ChatMessage>?> switchFork({
    required String sessionId,
    required String anchorUserMsgId,
    required ForkSwitchDirection direction,
    required List<ChatMessage> currentMessages,
    required List<ForkAnchor> forkAnchors,
  }) async {
    final anchor = forkAnchors.firstWhere(
      (a) => a.parentUserMsgId == anchorUserMsgId,
      orElse: () => const ForkAnchor(
        parentUserMsgId: '',
        activeIndex: 0,
        branchCount: 0,
      ),
    );
    if (anchor.parentUserMsgId.isEmpty) return null;

    final total = anchor.branchCount;
    if (total == 0) return null;
    final newIndex = direction == ForkSwitchDirection.next
        ? (anchor.activeIndex + 1) % total
        : (anchor.activeIndex - 1 + total) % total;

    // 收集当前尾部消息
    final currentTail = getTailMessages(currentMessages, anchorUserMsgId);

    // 交换快照
    final newMessages = await _chatRepository.switchForkBranchWithSnapshot(
      sessionId: sessionId,
      anchorUserMsgId: anchorUserMsgId,
      newActiveIndex: newIndex,
      currentTailMessages: currentTail,
    );

    // 截断到锚点 + 新分支消息
    final anchorIndex = currentMessages.indexWhere(
      (m) => m.messageId == anchorUserMsgId,
    );
    final truncated = anchorIndex >= 0
        ? currentMessages.sublist(0, anchorIndex + 1)
        : currentMessages;
    final updated = [...truncated, ...newMessages];

    return updated;
  }

  /// 切换到生成分支（用户切换回生成分支时调用）
  ///
  /// 在 DB 中将生成分支设为活跃分支（交换快照）。
  /// 生成分支在 DB 中还没有消息（流式未完成），返回值应为空。
  Future<void> switchToGeneratingBranch({
    required String sessionId,
    required String anchorUserMsgId,
    required int branchIndex,
    required List<ChatMessage> currentMessages,
  }) async {
    final currentTail = getTailMessages(currentMessages, anchorUserMsgId);
    await _chatRepository.switchForkBranchWithSnapshot(
      sessionId: sessionId,
      anchorUserMsgId: anchorUserMsgId,
      newActiveIndex: branchIndex,
      currentTailMessages: currentTail,
    );
  }

  /// 回滚 Fork 操作（API 失败或用户取消时调用）
  ///
  /// 快照模型下回滚逻辑：
  /// 1. 调用 removeForkBranchWithSnapshot 删除新创建的分支
  /// 2. 该方法会自动从快照恢复旧分支消息到 DB
  /// 3. 若有原文备份（editAndResend），恢复用户消息原文
  Future<bool> rollbackForkIfNeeded(String sessionId) async {
    final rollback = pendingForkRollback;
    if (rollback == null) return false;
    pendingForkRollback = null;

    try {
      // 删除新创建的分支（活跃分支），自动恢复旧分支
      await _chatRepository.removeForkBranchWithSnapshot(
        sessionId: sessionId,
        anchorUserMsgId: rollback.anchorUserMsgId,
        removedBranchIndex: rollback.branchIndex,
        currentTailMessages: const [],
      );

      // 恢复用户消息原文（仅 editAndResend 需要）
      if (rollback.originalContent != null) {
        await _chatRepository.updateMessageContent(
          rollback.anchorUserMsgId,
          rollback.originalContent!,
        );
      }

      return true;
    } catch (e) {
      _logger.error('Fork rollback failed', detail: '$e');
      return false;
    }
  }

  /// 清除待回滚信息（流式成功完成时调用）
  void clearPendingRollback() {
    pendingForkRollback = null;
  }

  /// 获取锚点用户消息之后的尾部消息（助手回复 + 后续所有消息）
  List<ChatMessage> getTailMessages(
    List<ChatMessage> messages,
    String anchorUserMsgId,
  ) {
    final anchorIndex = messages.indexWhere(
      (m) => m.messageId == anchorUserMsgId,
    );
    if (anchorIndex < 0 || anchorIndex + 1 >= messages.length) {
      return [];
    }
    return messages.sublist(anchorIndex + 1);
  }
}

/// 重新生成/编辑重发的结果
class RegenerateResult {
  const RegenerateResult({
    required this.newBranchIndex,
    required this.userMessage,
    required this.truncatedMessages,
    required this.anchorUserMsgId,
  });

  /// 新创建的分支索引
  final int newBranchIndex;

  /// 锚点用户消息（编辑重发时为编辑后的消息）
  final ChatMessage userMessage;

  /// 截断后的消息列表（到锚点用户消息含）
  final List<ChatMessage> truncatedMessages;

  /// 锚点用户消息 ID
  final String anchorUserMsgId;
}
