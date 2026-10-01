import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';

/// 会话内搜索仓库层契约
///
/// - 仅限 `searchMessagesInSession` 指定会话（跨会话消息不泄漏）；
/// - LIKE 通配符转义（\ % _）与跨会话搜索同口径；
/// - 排除摘要消息（is_summary=1）；升序返回（会话内导航按阅读方向）。
void main() {
  late AppDatabase db;
  late ChatRepositoryImpl repo;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    repo = ChatRepositoryImpl(database: db);
  });

  tearDown(() async => db.close());

  Future<void> seedSession(String sessionId) async {
    await db.customStatement(
      'INSERT INTO chat_sessions (session_id, title) VALUES (?, ?)',
      [sessionId, '测试'],
    );
  }

  Future<void> insertMessage(
    ChatMessage m, {
    bool isSummary = false,
  }) async {
    await db.customStatement(
      'INSERT INTO chat_messages (message_id, session_id, role, content, '
      'branch_index, parent_user_msg_id, tokens_used, is_summary) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [
        m.messageId,
        m.sessionId,
        m.role,
        m.content,
        m.branchIndex,
        m.parentUserMsgId,
        m.tokensUsed,
        if (isSummary) 1 else 0,
      ],
    );
  }

  ChatMessage msg(
    String id,
    String sessionId,
    String content, {
    String role = 'user',
  }) =>
      ChatMessage(
        messageId: id,
        sessionId: sessionId,
        role: role,
        content: content,
        createdAt: DateTime(2026),
      );

  test('仅返回指定会话的命中；升序排列', () async {
    await seedSession('s1');
    await seedSession('s2');
    await insertMessage(msg('a1', 's1', '古堡里藏着秘密'));
    await insertMessage(msg('a2', 's2', '古堡里藏着秘密'));
    await insertMessage(msg('a3', 's1', '第二条：古堡的钥匙'));

    final hits = await repo.searchMessagesInSession('s1', '古堡');

    expect(hits, hasLength(2), reason: 's2 的同文消息不得泄漏');
    expect(
      hits.map((h) => h.messageId).toList(),
      ['a1', 'a3'],
      reason: '升序=阅读方向',
    );
  });

  test(r'LIKE 通配符被转义：字面匹配 % _ \', () async {
    await seedSession('s1');
    await insertMessage(msg('m1', 's1', '进度 50% 完成'));
    await insertMessage(msg('m2', 's1', '文件名带下划线_a'));
    await insertMessage(msg('m3', 's1', '任意文本'));

    expect(
      (await repo.searchMessagesInSession('s1', '%')).map((h) => h.messageId),
      ['m1'],
      reason: '% 按字面匹配',
    );
    expect(
      (await repo.searchMessagesInSession('s1', '_a')).map((h) => h.messageId),
      ['m2'],
      reason: '_ 按字面匹配',
    );
    expect(
      await repo.searchMessagesInSession('s1', '___'),
      isEmpty,
      reason: '三个通配符下划线不匹配任意文本',
    );
  });

  test('摘要消息不参与搜索', () async {
    await seedSession('s1');
    await insertMessage(msg('sum', 's1', '摘要里也提到古堡'), isSummary: true);
    await insertMessage(msg('m1', 's1', '古堡'));

    final hits = await repo.searchMessagesInSession('s1', '古堡');
    expect(hits.map((h) => h.messageId), ['m1']);
  });
}
