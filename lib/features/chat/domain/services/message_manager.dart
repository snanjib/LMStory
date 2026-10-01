import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/fork_anchor.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:uuid/uuid.dart';

/// 消息管理器
///
/// 从 ChatModeController 中抽离的消息管理职责，包括：
/// - 消息加载
/// - 消息持久化（助手消息、错误消息）
/// - 消息删除
/// - 消息内容编辑
/// - 消息计数更新
/// - Fork 锚点刷新
///
/// 通过回调接口通知 Controller 状态变化，保持 Controller 对 state 的控制权。
class MessageManager {
  MessageManager({
    required ChatRepository chatRepository,
    required Logger logger,
    Uuid? uuid,
  })  : _chatRepository = chatRepository,
        _logger = logger,
        _uuid = uuid ?? const Uuid();

  final ChatRepository _chatRepository;
  final Logger _logger;
  final Uuid _uuid;

  /// 加载会话消息和 Fork 锚点
  ///
  /// 对标 ChatBox getAllMessageList：UI 显示全部消息（含已被 CompactionPoint
  /// 压缩的旧消息），摘要横幅按 createdAt 自然插入消息流。
  /// API 请求时的过滤在 Controller 中通过 getCompressedMessages 完成。
  ///
  /// 抛出异常时由调用方处理错误状态。
  Future<({List<ChatMessage> messages, List<ForkAnchor> anchors})> loadMessages(
    String sessionId,
  ) async {
    final messages = await _chatRepository.getMessages(sessionId);
    final anchors = await _chatRepository.getForkAnchors(sessionId);
    return (messages: messages, anchors: anchors);
  }

  /// 刷新 Fork 锚点（快照模型下消息无需过滤）
  Future<List<ForkAnchor>> refreshForkAnchors(String sessionId) async {
    return _chatRepository.getForkAnchors(sessionId);
  }

  /// 持久化助手消息
  ///
  /// 将流式生成的助手消息写入数据库，并更新会话最后活跃时间。
  Future<void> persistAssistantMessage(ChatMessage message) async {
    if (message.messageId.isEmpty) return;

    try {
      await _chatRepository.addMessage(message);
      await _chatRepository.updateSessionLastActive(message.sessionId);
    } catch (e) {
      _logger.error('Failed to persist assistant message', detail: '$e');
    }
  }

  /// 持久化错误到助手消息（对标 ChatBox 错误持久化）
  ///
  /// - 已有助手消息（流式中途失败）：更新该消息的 error 字段
  /// - 无助手消息（首个 token 前失败）：创建带 error 的助手消息并入库
  ///
  /// 返回更新后的消息列表和需要更新的状态信息。
  Future<PersistErrorResult> persistErrorToMessage({
    required String sessionId,
    required String errorText,
    required List<ChatMessage> currentMessages,
    required String? currentAssistantMessageId,
    required String? parentUserMsgId,
    required int branchIndex,
    required String? modelName,
  }) async {
    final messages = List<ChatMessage>.from(currentMessages);

    if (currentAssistantMessageId != null) {
      // 流式中途失败：更新现有助手消息的 error 字段
      final index = messages.indexWhere(
        (m) => m.messageId == currentAssistantMessageId,
      );
      if (index != -1) {
        messages[index] = messages[index].copyWith(error: errorText);
        try {
          // 前台流式消息完成前从不 INSERT
          //（完成才落库），UPDATE 可能 0 行命中——0 行时改走 INSERT 兜底
          //（半截内容 + 错误痕迹整条落库），否则断流后刷新即整条消失。
          final updated = await _chatRepository.updateMessageError(
            currentAssistantMessageId,
            errorText,
          );
          if (updated == 0) {
            await _chatRepository.addMessage(messages[index]);
          }
        } catch (e) {
          _logger.error('Failed to persist error to message', detail: '$e');
        }
        return PersistErrorResult(
          messages: messages,
          newMessageId: null,
        );
      }
    }

    // 首个 token 前失败：创建带 error 的助手消息
    final errorMessage = ChatMessage(
      messageId: _uuid.v4(),
      sessionId: sessionId,
      role: 'assistant',
      error: errorText,
      parentUserMsgId: parentUserMsgId,
      branchIndex: branchIndex,
      createdAt: DateTime.now(),
      modelName: modelName,
    );
    messages.add(errorMessage);

    try {
      await _chatRepository.addMessage(errorMessage);
      await _chatRepository.updateSessionLastActive(sessionId);
    } catch (e) {
      _logger.error('Failed to persist error message', detail: '$e');
    }

    return PersistErrorResult(
      messages: messages,
      newMessageId: errorMessage.messageId,
    );
  }

  /// 删除消息（含分支记录维护）
  ///
  /// 快照模型下，删除助手消息会同时删除其尾部消息，
  /// 并通过 removeForkBranchWithSnapshot 维护分支记录。
  Future<DeleteMessageResult> deleteMessage({
    required String sessionId,
    required String messageId,
    required List<ChatMessage> currentMessages,
    required List<ForkAnchor> forkAnchors,
  }) async {
    final message = currentMessages.firstWhere(
      (m) => m.messageId == messageId,
      orElse: () => ChatMessage(
        messageId: '',
        sessionId: '',
        role: 'user',
        createdAt: DateTime.now(),
      ),
    );
    if (message.messageId.isEmpty) {
      return const DeleteMessageResult(deleted: false, needReload: false);
    }

    // 收集要删除的消息（含尾部）
    final msgIndex =
        currentMessages.indexWhere((m) => m.messageId == messageId);
    final toDelete = msgIndex >= 0
        ? currentMessages.sublist(msgIndex)
        : <ChatMessage>[message];

    // 若是助手消息且有锚点，维护分支记录
    if (message.role == 'assistant' && message.parentUserMsgId != null) {
      final anchor = forkAnchors.firstWhere(
        (a) => a.parentUserMsgId == message.parentUserMsgId,
        orElse: () => const ForkAnchor(
          parentUserMsgId: '',
          activeIndex: 0,
          branchCount: 0,
        ),
      );
      // 仅当待删消息是该锚点活跃分支的
      // 首条回复时才走"删尾 + 插回快照 + 拆锚点"的分支移除语义；续写气泡
      //（与首条回复共享 parentUserMsgId 的后续消息）走该语义会把分支结构
      // 坍塌——活跃分支残段与插回的旧分支并陈、锚点被删导致导航消失。
      final isBranchHead = msgIndex >= 0 &&
          !currentMessages.take(msgIndex).any(
                (m) =>
                    m.role == 'assistant' &&
                    m.parentUserMsgId == message.parentUserMsgId,
              );
      if (anchor.parentUserMsgId.isNotEmpty && isBranchHead) {
        // 删除活跃分支：toDelete 即为 currentTailMessages
        await _chatRepository.removeForkBranchWithSnapshot(
          sessionId: sessionId,
          anchorUserMsgId: message.parentUserMsgId!,
          removedBranchIndex: anchor.activeIndex,
          currentTailMessages: toDelete,
        );
      } else {
        // 无锚点（branchCount=1）或非分支首条（续写气泡）：直接删除消息
        for (final m in toDelete) {
          await _chatRepository.deleteMessage(m.messageId);
        }
        await _chatRepository.pruneInvalidCompactionPoints(sessionId);
      }
    } else {
      // 非助手消息：直接删除（toDelete 含该消息起的全部尾部消息）
      for (final m in toDelete) {
        await _chatRepository.deleteMessage(m.messageId);
      }
      // 被删的任何消息若是 Fork 锚点
      // （含删尾连带删掉的下游锚点），其分支记录行（含全部非活跃分支的
      // 快照内容）一并清除——快照行不随消息删除消失，会残留不可达的
      // 历史分支内容（隐私残留）。
      final deletedIds = toDelete.map((m) => m.messageId).toSet();
      for (final anchor in forkAnchors) {
        if (deletedIds.contains(anchor.parentUserMsgId)) {
          await _chatRepository.deleteForkBranchesByAnchor(
            sessionId,
            anchor.parentUserMsgId,
          );
        }
      }
      // 删除早于摘要的消息会留下孤儿压缩点，
      // 失配后下次请求静默退回全量上下文（超窗风险），删除后统一清理
      await _chatRepository.pruneInvalidCompactionPoints(sessionId);
    }

    return const DeleteMessageResult(deleted: true, needReload: true);
  }

  /// 删除摘要消息（对标 ChatBox removeMessage 删除 isSummary 消息）
  ///
  /// 删除摘要消息 + 关联的 CompactionPoint，使原始消息恢复到上下文中。
  Future<bool> deleteSummary({
    required String sessionId,
    required String messageId,
  }) async {
    try {
      await _chatRepository.deleteMessage(messageId);
      await _chatRepository.deleteCompactionPointBySummaryId(
        sessionId,
        messageId,
      );
      return true;
    } catch (e) {
      _logger.error('Failed to delete summary', detail: '$e');
      return false;
    }
  }

  /// 编辑消息内容（不重新发送，对标 ChatBox "Save"）
  ///
  /// 原地更新消息内容，不创建新分支。
  Future<bool> editMessageContent(String messageId, String newContent) async {
    try {
      await _chatRepository.updateMessageContent(messageId, newContent);
      return true;
    } catch (e) {
      _logger.error('Failed to edit message', detail: '$e');
      return false;
    }
  }

  /// 编辑摘要内容（对标 ChatBox SummaryMessage handleEdit）
  ///
  /// 用户可手动修正摘要内容。仅更新消息文本，不影响 CompactionPoint。
  Future<bool> editSummaryContent(String messageId, String newContent) async {
    try {
      await _chatRepository.updateMessageContent(messageId, newContent);
      return true;
    } catch (e) {
      _logger.error('Failed to edit summary', detail: '$e');
      return false;
    }
  }

  /// 清空当前会话的所有消息（对标 ChatBox Clear Messages）
  Future<bool> clearMessages(String sessionId) async {
    try {
      await _chatRepository.deleteMessages(sessionId);
      return true;
    } catch (e) {
      _logger.error('Failed to clear messages', detail: '$e');
      return false;
    }
  }

  /// 更新消息计数
  Future<int> updateMessageCount(String sessionId) async {
    final count = await _chatRepository.getMessageCount(sessionId);
    await _chatRepository.updateSessionMessageCount(sessionId, count);
    return count;
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

/// 持久化错误的结果
class PersistErrorResult {
  const PersistErrorResult({
    required this.messages,
    required this.newMessageId,
  });

  /// 更新后的消息列表
  final List<ChatMessage> messages;

  /// 新创建的错误消息 ID（首个 token 前失败时非 null）
  final String? newMessageId;
}

/// 删除消息的结果
class DeleteMessageResult {
  const DeleteMessageResult({
    required this.deleted,
    required this.needReload,
  });

  /// 是否删除成功
  final bool deleted;

  /// 是否需要重新加载消息
  final bool needReload;
}
