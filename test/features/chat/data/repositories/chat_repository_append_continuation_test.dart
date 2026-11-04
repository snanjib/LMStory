import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';

/// appendContinuation / appendContinuationToBranchSnapshot 测试
///
///
/// - 续写段并入时 tokens_used 一并写入（重载后上下文用量不回退）；
///   tokensUsed 为 null 时保留旧值（停止的半截续写无 usage）。
/// - 续写在后台分支完成时，接写合并的目标半截消息随生成分支存在
///   快照中（活跃表无此行，普通 UPDATE 会 0 行命中）——快照内按 messageId
///   合并，切回生成分支可见单气泡接写结果。
void main() {
  late AppDatabase db;
  late ChatRepositoryImpl repo;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    repo = ChatRepositoryImpl(database: db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seedSession(String sessionId) async {
    await db.customStatement(
      'INSERT INTO chat_sessions (session_id, title) VALUES (?, ?)',
      [sessionId, '测试'],
    );
  }

  Future<void> insertMessage(ChatMessage m) async {
    await db.customStatement(
      'INSERT INTO chat_messages (message_id, session_id, role, content, '
      'branch_index, parent_user_msg_id, tokens_used) '
      'VALUES (?, ?, ?, ?, ?, ?, ?)',
      [
        m.messageId,
        m.sessionId,
        m.role,
        m.content,
        m.branchIndex,
        m.parentUserMsgId,
        m.tokensUsed,
      ],
    );
  }

  ChatMessage msg(
    String id,
    String role,
    String content, {
    String? parent,
    int? tokensUsed,
  }) =>
      ChatMessage(
        messageId: id,
        sessionId: 's1',
        role: role,
        content: content,
        parentUserMsgId: parent,
        tokensUsed: tokensUsed,
        createdAt: DateTime(2026),
      );

  group('appendContinuation（活跃表合并）', () {
    test('续写 usage 写入 tokens_used，内容原子拼接 + is_continued 置位', () async {
      await seedSession('s1');
      await insertMessage(msg('u1', 'user', '写个故事'));
      await insertMessage(
        msg('a1', 'assistant', '从前有座山，', parent: 'u1', tokensUsed: 100),
      );

      await repo.appendContinuation(
        'a1',
        '山里有个庙。',
        tokensUsed: 777,
      );

      final messages = await repo.getMessages('s1');
      final merged = messages.firstWhere((m) => m.messageId == 'a1');
      expect(merged.content, '从前有座山，山里有个庙。');
      expect(merged.isContinued, isTrue);
      expect(merged.tokensUsed, 777, reason: '续写 usage 必须落库');
    });

    test('tokensUsed 为 null 时保留旧值（停止的半截续写无 usage）', () async {
      await seedSession('s1');
      await insertMessage(msg('u1', 'user', '写个故事'));
      await insertMessage(
        msg('a1', 'assistant', '从前有座山，', parent: 'u1', tokensUsed: 100),
      );

      // tokensUsed 缺省（null）：停止的半截续写无 usage 形态
      await repo.appendContinuation('a1', '山里有个');

      final merged =
          (await repo.getMessages('s1')).firstWhere((m) => m.messageId == 'a1');
      expect(merged.tokensUsed, 100, reason: '无 usage 不清空已有 tokens_used');
      expect(merged.isContinued, isTrue);
    });
  });

  group('appendContinuationToBranchSnapshot（快照内合并）', () {
    test('并入非活跃分支快照中的半截消息：切回生成分支可见单气泡接写结果', () async {
      await seedSession('s1');
      await insertMessage(msg('u1', 'user', '写个故事'));
      // 创建锚点：半截 a0（含 usage）进分支 0 快照，活跃分支 1
      final newBranch = await repo.addAssistantBranchAndSnapshot(
        sessionId: 's1',
        anchorUserMsgId: 'u1',
        tailMessages: [
          msg('a0', 'assistant', '从前有座山，', parent: 'u1', tokensUsed: 100),
        ],
      );
      expect(newBranch, 1);
      await insertMessage(msg('a1', 'assistant', '分支1回复', parent: 'u1'));

      final merged = await repo.appendContinuationToBranchSnapshot(
        sessionId: 's1',
        anchorUserMsgId: 'u1',
        branchIndex: 0,
        messageId: 'a0',
        continuation: '山里有个庙。',
        tokensUsed: 777,
      );
      expect(merged, isTrue, reason: '非活跃分支快照存在，应可合并');

      // 切回生成分支 0：快照消息回到表内，接写结果完整可见
      final switched = await repo.switchForkBranchWithSnapshot(
        sessionId: 's1',
        anchorUserMsgId: 'u1',
        newActiveIndex: 0,
        currentTailMessages: [msg('a1', 'assistant', '分支1回复', parent: 'u1')],
      );
      final a0 = switched.firstWhere((m) => m.messageId == 'a0');
      expect(a0.content, '从前有座山，山里有个庙。', reason: '快照内接写合并');
      expect(a0.isContinued, isTrue);
      expect(a0.tokensUsed, 777, reason: 'usage 随合并写入');
      expect(
        switched.where((m) => m.role == 'assistant').length,
        1,
        reason: '不产生独立新消息（单气泡语义）',
      );
    });

    test('锚点不存在 / 目标消息不在快照中 → 返回 false（调用方回退保数据）', () async {
      await seedSession('s1');
      await insertMessage(msg('u1', 'user', '开头'));

      // 锚点不存在
      expect(
        await repo.appendContinuationToBranchSnapshot(
          sessionId: 's1',
          anchorUserMsgId: 'u1',
          branchIndex: 0,
          messageId: 'a0',
          continuation: 'x',
        ),
        isFalse,
      );

      // 建锚点（活跃=1，快照只有分支 0 的 a0）
      await repo.addAssistantBranchAndSnapshot(
        sessionId: 's1',
        anchorUserMsgId: 'u1',
        tailMessages: [msg('a0', 'assistant', '半截', parent: 'u1')],
      );

      // 目标消息不在该快照中
      expect(
        await repo.appendContinuationToBranchSnapshot(
          sessionId: 's1',
          anchorUserMsgId: 'u1',
          branchIndex: 0,
          messageId: 'not-exist',
          continuation: 'x',
        ),
        isFalse,
      );

      // 该分支即当前活跃分支（消息应在活跃表，走普通 appendContinuation）
      expect(
        await repo.appendContinuationToBranchSnapshot(
          sessionId: 's1',
          anchorUserMsgId: 'u1',
          branchIndex: 1,
          messageId: 'whatever',
          continuation: 'x',
        ),
        isFalse,
      );
    });
  });
}
