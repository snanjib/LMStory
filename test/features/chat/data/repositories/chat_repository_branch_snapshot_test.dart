import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';

/// appendMessageToBranchSnapshot 分支快照追加测试
///
/// 后台分支生成（流式中切看其他分支）完成/失败/停止时，产物消息必须
/// 落进生成分支的快照，而不是当前查看分支的表尾（跨分支污染）。
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
      'branch_index, parent_user_msg_id) VALUES (?, ?, ?, ?, ?, ?)',
      [
        m.messageId,
        m.sessionId,
        m.role,
        m.content,
        m.branchIndex,
        m.parentUserMsgId,
      ],
    );
  }

  ChatMessage msg(
    String id,
    String role,
    String content, {
    String? parent,
  }) =>
      ChatMessage(
        messageId: id,
        sessionId: 's1',
        role: role,
        content: content,
        parentUserMsgId: parent,
        createdAt: DateTime(2026),
      );

  test('追加到非活跃分支快照：切回该分支可见追加消息（CH-D2 主语义）', () async {
    await seedSession('s1');
    // u1 锚点：分支 0 的旧回复 + 分支 1（活跃）的新回复
    await insertMessage(msg('u1', 'user', '开头'));

    // 创建锚点：旧尾部（a0）进分支 0 快照，活跃分支 1
    final newBranch = await repo.addAssistantBranchAndSnapshot(
      sessionId: 's1',
      anchorUserMsgId: 'u1',
      tailMessages: [msg('a0', 'assistant', '分支0旧回复', parent: 'u1')],
    );
    expect(newBranch, 1);

    // 后台生成产物：属于分支 0（生成分支），此刻非活跃
    final product = msg('bg1', 'assistant', '后台生成的回复', parent: 'u1')
        .copyWith(branchIndex: 0);
    final stored = await repo.appendMessageToBranchSnapshot(
      sessionId: 's1',
      anchorUserMsgId: 'u1',
      branchIndex: 0,
      message: product,
    );
    expect(stored, isTrue, reason: '非活跃分支快照存在，应可安全追加');

    // 切回分支 0：快照消息（含追加产物）应回到表内
    final switched = await repo.switchForkBranchWithSnapshot(
      sessionId: 's1',
      anchorUserMsgId: 'u1',
      newActiveIndex: 0,
      currentTailMessages: [
        msg('a1', 'assistant', '分支1回复', parent: 'u1'),
      ],
    );
    expect(
      switched.map((m) => m.messageId).toList(),
      containsAll(<String>['a0', 'bg1']),
      reason: '后台完成消息必须随生成分支快照出现，而非当前查看分支表尾',
    );
  });

  test('活跃分支/快照缺失/锚点不存在 → 返回 false（调用方回退保数据）', () async {
    await seedSession('s1');
    await insertMessage(msg('u1', 'user', '开头'));

    // 锚点不存在
    expect(
      await repo.appendMessageToBranchSnapshot(
        sessionId: 's1',
        anchorUserMsgId: 'u1',
        branchIndex: 0,
        message: msg('x', 'assistant', 'x'),
      ),
      isFalse,
    );

    // 建锚点（活跃=1，快照只有分支 0）
    await repo.addAssistantBranchAndSnapshot(
      sessionId: 's1',
      anchorUserMsgId: 'u1',
      tailMessages: [msg('a0', 'assistant', '旧', parent: 'u1')],
    );

    // 活跃分支本身不可追加（表内即真相）
    expect(
      await repo.appendMessageToBranchSnapshot(
        sessionId: 's1',
        anchorUserMsgId: 'u1',
        branchIndex: 1,
        message: msg('x', 'assistant', 'x'),
      ),
      isFalse,
    );

    // 快照缺失的分支索引
    expect(
      await repo.appendMessageToBranchSnapshot(
        sessionId: 's1',
        anchorUserMsgId: 'u1',
        branchIndex: 5,
        message: msg('x', 'assistant', 'x'),
      ),
      isFalse,
    );
  });

  // updateSession 全列回写不再倒灌
  // 陈旧 lastActiveAt——发送走 updateSessionLastActive 推进库值后，
  // 设置面板保存（updateSession 用打开时的内存拷贝）不得把排序键回拨。
  test('updateSession 不回写 lastActiveAt（CH12-2）', () async {
    await seedSession('s1');
    final opened = await repo.getSession('s1'); // 打开时的内存拷贝

    // 会话活跃：库值推进到 opened.lastActiveAt + 1h（drift dateTime 列
    // 存 ISO-8601 字符串）
    final activeAt = opened.lastActiveAt.add(const Duration(hours: 1));
    await db.customStatement(
      'UPDATE chat_sessions SET last_active_at = ? WHERE session_id = ?',
      [activeAt.toIso8601String(), 's1'],
    );

    // 会话设置保存（旧内存拷贝全列回写）
    await repo.updateSession(opened.copyWith(temperature: 0.9));

    final reloaded = await repo.getSession('s1');
    expect(reloaded.temperature, 0.9, reason: '设置列正常写入');
    expect(
      reloaded.lastActiveAt.isAfter(opened.lastActiveAt),
      isTrue,
      reason: 'lastActiveAt 不得被打开时的旧值倒灌（最近会话排序键）',
    );
  });
}
