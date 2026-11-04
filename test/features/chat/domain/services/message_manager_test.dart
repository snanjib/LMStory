import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/fork_anchor.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/domain/services/message_manager.dart';

/// MessageManager 落库链路回归
///
/// - ：前台流式消息完成前从不 INSERT，断流错误的 UPDATE 0 行命中时
///   须走 INSERT 兜底（半截内容+错误痕迹整条落库，否则刷新即丢）。
/// - ：删除续写气泡（与分支首条共享锚点的后续消息）不再触发
///   "删尾+插快照+拆锚点"的分支移除语义（会把分支结构坍塌）。
void main() {
  late _RecordingRepo repo;
  late MessageManager manager;

  setUp(() {
    repo = _RecordingRepo();
    manager = MessageManager(
      chatRepository: repo,
      logger: const Logger('test'),
    );
  });

  ChatMessage msg(
    String id,
    String role, {
    String? content,
    String? parent,
    DateTime? at,
  }) =>
      ChatMessage(
        messageId: id,
        sessionId: 's1',
        role: role,
        content: content,
        parentUserMsgId: parent,
        createdAt: at ?? DateTime(2026),
      );

  group('persistErrorToMessage 断流落库', () {
    test('消息未 INSERT（前台流式）→ UPDATE 0 行命中，INSERT 兜底整条落库', () async {
      final partial = msg('a1', 'assistant', content: '半截内容');
      final result = await manager.persistErrorToMessage(
        sessionId: 's1',
        errorText: '网络中断',
        currentMessages: [partial],
        currentAssistantMessageId: 'a1',
        parentUserMsgId: 'u1',
        branchIndex: 0,
        modelName: null,
      );

      expect(repo.updatedErrors, isEmpty, reason: '未 INSERT 的行 UPDATE 0 行');
      expect(repo.addedMessages, hasLength(1));
      expect(repo.addedMessages.single.error, '网络中断');
      expect(repo.addedMessages.single.content, '半截内容');
      expect(result.messages.single.error, '网络中断');
    });

    test('消息已 INSERT（后台/续写路径）→ 仅 UPDATE error，不重复插入', () async {
      repo.messages.add(msg('a1', 'assistant', content: '已有内容'));
      await manager.persistErrorToMessage(
        sessionId: 's1',
        errorText: '网络中断',
        currentMessages: [msg('a1', 'assistant', content: '已有内容')],
        currentAssistantMessageId: 'a1',
        parentUserMsgId: 'u1',
        branchIndex: 0,
        modelName: null,
      );

      expect(repo.updatedErrors, containsPair('a1', '网络中断'));
      expect(repo.addedMessages, isEmpty);
    });
  });

  group('deleteMessage 续写气泡降级', () {
    test('删除锚点下的续写气泡 → 普通删除，不动锚点/快照', () async {
      // user_N → （旧分支快照，不在当前列表）→ （活跃分支首条）
      //   → （续写气泡，与  共享锚点）
      repo.forkAnchors = [
        const ForkAnchor(
          parentUserMsgId: 'u1',
          activeIndex: 1,
          branchCount: 2,
        ),
      ];
      final messages = [
        msg('u1', 'user', content: '开头', at: DateTime(2026)),
        msg(
          'a1',
          'assistant',
          content: '第一段回复',
          parent: 'u1',
          at: DateTime(2026, 1, 1, 0, 0, 1),
        ),
        msg(
          'a2',
          'assistant',
          content: '续写段',
          parent: 'u1',
          at: DateTime(2026, 1, 1, 0, 0, 2),
        ),
      ];

      final result = await manager.deleteMessage(
        sessionId: 's1',
        messageId: 'a2',
        currentMessages: messages,
        forkAnchors: repo.forkAnchors,
      );

      expect(result.deleted, isTrue);
      expect(
        repo.removedBranchCalls,
        isEmpty,
        reason: '续写气泡不得触发"删尾+插快照+拆锚点"的分支移除语义',
      );
      expect(repo.deletedMessageIds, ['a2'], reason: '只删该条');
    });

    test('删除活跃分支首条回复 → 仍走分支移除（回旧版本语义保持）', () async {
      repo.forkAnchors = [
        const ForkAnchor(
          parentUserMsgId: 'u1',
          activeIndex: 1,
          branchCount: 2,
        ),
      ];
      final messages = [
        msg('u1', 'user', content: '开头', at: DateTime(2026)),
        msg(
          'a1',
          'assistant',
          content: '第一段回复',
          parent: 'u1',
          at: DateTime(2026, 1, 1, 0, 0, 1),
        ),
      ];

      await manager.deleteMessage(
        sessionId: 's1',
        messageId: 'a1',
        currentMessages: messages,
        forkAnchors: repo.forkAnchors,
      );

      expect(
        repo.removedBranchCalls,
        hasLength(1),
        reason: '分支首条删除=移除当前分支，快照语义保持',
      );
    });

    // 删除作为 Fork 锚点的用户消息
    // 时，分支记录行（含非活跃分支快照）一并清除——否则成不可达幽灵
    // 数据（隐私残留）。
    test('删除 Fork 锚点用户消息 → 连带清除该锚点分支记录', () async {
      repo.forkAnchors = [
        const ForkAnchor(
          parentUserMsgId: 'u1',
          activeIndex: 1,
          branchCount: 2,
        ),
      ];
      final messages = [
        msg('u0', 'user', content: '更早', at: DateTime(2025, 12, 31)),
        msg('u1', 'user', content: '锚点提问', at: DateTime(2026)),
        msg(
          'a1',
          'assistant',
          content: '回复',
          parent: 'u1',
          at: DateTime(2026, 1, 1, 0, 0, 1),
        ),
      ];

      final result = await manager.deleteMessage(
        sessionId: 's1',
        messageId: 'u1',
        currentMessages: messages,
        forkAnchors: repo.forkAnchors,
      );

      expect(result.deleted, isTrue);
      expect(repo.deletedMessageIds, ['u1', 'a1'], reason: '删尾语义：锚点及其后全部消息删除');
      expect(
        repo.deletedBranchAnchors,
        ['u1'],
        reason: '锚点分支行（含非活跃分支快照）必须一并清除',
      );
    });

    test('删除非锚点用户消息但删尾覆盖下游锚点 → 下游锚点分支行也清除', () async {
      repo.forkAnchors = [
        const ForkAnchor(
          parentUserMsgId: 'u2',
          activeIndex: 1,
          branchCount: 2,
        ),
      ];
      final messages = [
        msg('u1', 'user', content: '更早提问', at: DateTime(2025, 12, 31)),
        msg('u2', 'user', content: '锚点提问', at: DateTime(2026)),
        msg(
          'a1',
          'assistant',
          content: '回复',
          parent: 'u2',
          at: DateTime(2026, 1, 1, 0, 0, 1),
        ),
      ];

      await manager.deleteMessage(
        sessionId: 's1',
        messageId: 'u1',
        currentMessages: messages,
        forkAnchors: repo.forkAnchors,
      );

      expect(repo.deletedMessageIds, ['u1', 'u2', 'a1']);
      expect(
        repo.deletedBranchAnchors,
        ['u2'],
        reason: '删尾把锚点 u2 一并删掉，其分支快照行不可达，须清除',
      );
    });
  });
}

class _RecordingRepo implements ChatRepository {
  List<ChatMessage> messages = [];
  List<ForkAnchor> forkAnchors = [];
  final List<ChatMessage> addedMessages = [];
  final List<String> deletedMessageIds = [];
  final Map<String, String> updatedErrors = {};
  final List<({String anchorId, int removedIndex})> removedBranchCalls = [];
  final List<String> deletedBranchAnchors = [];

  @override
  Future<void> deleteForkBranchesByAnchor(
    String sessionId,
    String anchorUserMsgId,
  ) async {
    deletedBranchAnchors.add(anchorUserMsgId);
  }

  @override
  Future<ChatMessage> addMessage(ChatMessage message) async {
    addedMessages.add(message);
    return message;
  }

  @override
  Future<void> deleteMessage(String messageId) async {
    deletedMessageIds.add(messageId);
  }

  @override
  Future<int> updateMessageError(String messageId, String? error) async {
    if (!messages.any((m) => m.messageId == messageId)) return 0;
    updatedErrors[messageId] = error ?? '';
    return 1;
  }

  @override
  Future<List<ChatMessage>?> removeForkBranchWithSnapshot({
    required String sessionId,
    required String anchorUserMsgId,
    required int removedBranchIndex,
    required List<ChatMessage> currentTailMessages,
  }) async {
    removedBranchCalls.add(
      (anchorId: anchorUserMsgId, removedIndex: removedBranchIndex),
    );
    return null;
  }

  @override
  Future<void> pruneInvalidCompactionPoints(String sessionId) async {}

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async => messages;

  @override
  Future<List<ForkAnchor>> getForkAnchors(String sessionId) async =>
      forkAnchors;

  @override
  Never noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
