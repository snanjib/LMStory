import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';

/// copySession 复制完整性测试
///
/// - OH-2：v0.3 导演会话列（maxSteps/watchMode/toolPermissions/
///   maxDurationMinutes/narrativePacing/nextTurn）必须随会话复制。
/// - OH-3：复制全程单事务，中途失败不得残留「有会话行、缺消息」的半份副本。
/// - CH-3a：压缩点与分支快照随会话复制，消息 id 重映射后副本自洽。
/// - CH-3b：副本 sortOrder 同 createSession 取 min-1000，不与现有会话撞值。
void main() {
  // OH-3 用例会在同一测试内开启第二个内存库（注入拦截器），关闭漂移的
  // 「多实例」调试告警（两库 executor 各自独立，无共享）。
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

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

  var msgCounter = 0;

  setUp(() => msgCounter = 0);

  ChatMessage msg(
    String id,
    String role,
    String content, {
    String sessionId = 's1',
    String? parent,
    bool isSummary = false,
  }) =>
      ChatMessage(
        messageId: id,
        sessionId: sessionId,
        role: role,
        content: content,
        parentUserMsgId: parent,
        isSummary: isSummary,
        createdAt: DateTime(2026, 1, 1, 0, 0, msgCounter++),
      );

  test('OH-2: 复制会话携带 v0.3 导演设置列与轮次计数器', () async {
    await db.customStatement(
      'INSERT INTO chat_sessions (session_id, title, mode, max_steps, '
      'watch_mode, tool_permissions, max_duration_minutes, narrative_pacing, '
      "next_turn) VALUES ('s1', '导演局', 'advanced', 9, 1, "
      "'{\"web_search\":\"ask\"}', 25, 'aggressive', 7)",
    );
    await repo.addMessage(msg('u1', 'user', '开局'));

    final copy = await repo.copySession('s1');
    expect(copy.maxSteps, 9);
    expect(copy.watchMode, isTrue);
    expect(copy.toolPermissions, '{"web_search":"ask"}');
    expect(copy.maxDurationMinutes, 25);
    expect(copy.narrativePacing, 'aggressive');
    expect(copy.nextTurn, 7);

    // 落库字段同样完整（getSession 走 _sessionFromRow）
    final stored = await repo.getSession(copy.sessionId);
    expect(stored.maxSteps, 9);
    expect(stored.watchMode, isTrue);
    expect(stored.toolPermissions, '{"web_search":"ask"}');
    expect(stored.maxDurationMinutes, 25);
    expect(stored.narrativePacing, 'aggressive');
    expect(stored.nextTurn, 7);
  });

  test('OH-3: 复制中途失败不留半份副本（事务回滚）', () async {
    final flaky = _FailChatMessagesInsert();
    final flakyDb = AppDatabase.forTesting(
      NativeDatabase.memory().interceptWith(flaky),
    );
    await flakyDb.customSelect('SELECT 1').get();
    addTearDown(flakyDb.close);
    final flakyRepo = ChatRepositoryImpl(database: flakyDb);

    await flakyDb.customStatement(
      "INSERT INTO chat_sessions (session_id, title) VALUES ('s1', '源')",
    );
    await flakyRepo.addMessage(msg('u1', 'user', '问题一'));
    await flakyRepo.addMessage(msg('a1', 'assistant', '回答一', parent: 'u1'));

    // 布防：此后第一条针对 chat_messages 的插入抛错（模拟进程/DB 中断）
    flaky.armed = true;

    await expectLater(
      flakyRepo.copySession('s1'),
      throwsA(isA<Exception>()),
    );

    final sessions = await flakyDb
        .customSelect('SELECT COUNT(*) AS c FROM chat_sessions')
        .get();
    expect(
      sessions.first.read<int>('c'),
      1,
      reason: '失败后只应有源会话一行，不得残留半份副本会话行',
    );
    final copiedMessages = await flakyDb
        .customSelect(
          "SELECT COUNT(*) AS c FROM chat_messages WHERE session_id != 's1'",
        )
        .get();
    expect(copiedMessages.first.read<int>('c'), 0);
    final points = await flakyDb
        .customSelect('SELECT COUNT(*) AS c FROM compaction_points')
        .get();
    expect(points.first.read<int>('c'), 0);
    final branches = await flakyDb
        .customSelect('SELECT COUNT(*) AS c FROM chat_session_branches')
        .get();
    expect(branches.first.read<int>('c'), 0);
  });

  test('CH-3a: 复制会话连同压缩点（消息 id 重映射后仍指向副本内消息）', () async {
    await db.customStatement(
      "INSERT INTO chat_sessions (session_id, title) VALUES ('s1', '源')",
    );
    await repo.addMessage(msg('u1', 'user', '问题'));
    await repo.addMessage(
      msg('a1', 'assistant', '回答', parent: 'u1'),
    );
    await repo.addMessage(msg('sum1', 'assistant', '前情摘要', isSummary: true));
    await db.customStatement(
      'INSERT INTO compaction_points (session_id, summary_message_id, '
      "boundary_message_id) VALUES ('s1', 'sum1', 'a1')",
    );

    final copy = await repo.copySession('s1');
    final points = await repo.getCompactionPoints(copy.sessionId);
    expect(points, hasLength(1), reason: '压缩点必须随会话复制，否则副本退化为全量注入上下文');

    final newMessages = await repo.getMessages(copy.sessionId);
    final byId = {for (final m in newMessages) m.messageId: m};
    final summaryId = points.single['summaryMessageId'] as String;
    final boundaryId = points.single['boundaryMessageId'] as String;
    expect(byId[summaryId]?.isSummary, isTrue, reason: '摘要侧应指向副本内摘要消息');
    expect(byId[boundaryId]?.content, '回答', reason: '边界侧应指向副本内边界消息');
  });

  test('CH-3a: 副本消息引用自洽——parentUserMsgId 指向副本内消息', () async {
    await db.customStatement(
      "INSERT INTO chat_sessions (session_id, title) VALUES ('s1', '源')",
    );
    await repo.addMessage(msg('u1', 'user', '问题'));
    await repo.addMessage(msg('a1', 'assistant', '回答', parent: 'u1'));

    final copy = await repo.copySession('s1');
    final messages = await repo.getMessages(copy.sessionId);
    // 内容按原顺序保留
    expect(messages.map((m) => m.content).toList(), ['问题', '回答']);

    final user = messages.firstWhere((m) => m.role == 'user');
    final assistant = messages.firstWhere((m) => m.role == 'assistant');
    expect(
      assistant.parentUserMsgId,
      user.messageId,
      reason: '副本消息不得跨会话引用源消息 id',
    );
    expect(assistant.parentUserMsgId, isNot('u1'));
  });

  test('CH-3a: 复制会话连同分支快照结构（锚点/快照重映射，切分支可用）', () async {
    await db.customStatement(
      "INSERT INTO chat_sessions (session_id, title) VALUES ('s1', '源')",
    );
    await repo.addMessage(msg('u1', 'user', '开局'));
    // 建 Fork：旧回复 a0 进分支 0 快照，活跃分支 1
    await repo.addAssistantBranchAndSnapshot(
      sessionId: 's1',
      anchorUserMsgId: 'u1',
      tailMessages: [
        msg('a0', 'assistant', '分支0回复', parent: 'u1'),
      ],
    );
    await repo.addMessage(msg('a1', 'assistant', '分支1回复', parent: 'u1'));

    final copy = await repo.copySession('s1');

    final anchors = await repo.getForkAnchors(copy.sessionId);
    expect(anchors, hasLength(1), reason: 'Fork 结构必须随会话复制');
    expect(anchors.single.branchCount, 2);

    final copyMessages = await repo.getMessages(copy.sessionId);
    final copyUser = copyMessages.firstWhere((m) => m.role == 'user');
    expect(
      anchors.single.parentUserMsgId,
      copyUser.messageId,
      reason: '锚点必须指向副本内的用户消息，不得跨会话引用',
    );

    // 快照 JSON 重映射干净：不残留源消息 id / 源会话 id
    final rows = await db.customSelect(
      'SELECT branch_snapshots FROM chat_session_branches WHERE session_id = ?',
      variables: [Variable.withString(copy.sessionId)],
    ).get();
    expect(rows, hasLength(1));
    final snapshots = jsonDecode(rows.first.read<String>('branch_snapshots'))
        as List<dynamic>;
    final snap = snapshots.single as Map<String, dynamic>;
    expect(snap['index'], 0);
    final snapMsg =
        (snap['messages'] as List<dynamic>).single as Map<String, dynamic>;
    expect(snapMsg['messageId'], isNot(anyOf('u1', 'a0', 'a1')));
    expect(snapMsg['sessionId'], copy.sessionId);
    expect(snapMsg['content'], '分支0回复');

    // 行为级：在副本上切回分支 0 应当可用
    final copyTail =
        copyMessages.where((m) => m.messageId != copyUser.messageId).toList();
    final switched = await repo.switchForkBranchWithSnapshot(
      sessionId: copy.sessionId,
      anchorUserMsgId: anchors.single.parentUserMsgId,
      newActiveIndex: 0,
      currentTailMessages: copyTail,
    );
    expect(switched.map((m) => m.content), contains('分支0回复'));
  });

  test('CH-3b: 复制会话 sortOrder 取 min-1000，不与现有会话撞值', () async {
    await db.customStatement(
      'INSERT INTO chat_sessions (session_id, title, sort_order) '
      "VALUES ('s1', '甲', 0)",
    );
    await db.customStatement(
      'INSERT INTO chat_sessions (session_id, title, sort_order) '
      "VALUES ('s2', '乙', 1000)",
    );
    await repo.addMessage(msg('u1', 'user', '问题'));

    final copy = await repo.copySession('s1');
    expect(copy.sortOrder, -1000.0);

    final stored = await repo.getSession(copy.sessionId);
    expect(stored.sortOrder, -1000.0);
    expect(
      stored.sortOrder,
      isNot(anyOf(0.0, 1000.0)),
      reason: '默认 0 会与列表首项撞值导致排序错乱',
    );
  });

  // 复制会话补齐轮产物——此前
  // intermediate_round_artifacts 不随复制，副本幕后时间线/Recap 小窗丢失；
  //  后 message_variants 也不随复制，副本变体悬空。
  test('UIUX: 复制导演会话连同轮产物与稿件变体（指针一致，副本独立）', () async {
    await db.customStatement(
      'INSERT INTO chat_sessions (session_id, title, mode) '
      "VALUES ('s1', '导演局', 'advanced')",
    );
    await repo.addMessage(msg('u1', 'user', '第一幕'));
    await repo.addMessage(msg('a1', 'assistant', '稿件 v1', parent: 'u1'));
    await db.customStatement(
      'INSERT INTO intermediate_round_artifacts '
      '(session_id, turn_number, agent_timeline, agent_summary, '
      'current_variant_index, created_at) '
      "VALUES ('s1', 1, '[{\"kind\":\"action\"}]', "
      "'{\"steps\":2}', 1, 1000)",
    );
    await db.customStatement(
      'INSERT INTO message_variants (session_id, turn_number, variant_index, '
      "content, created_at) VALUES ('s1', 1, 0, '稿件 v1', 1000)",
    );
    await db.customStatement(
      'INSERT INTO message_variants (session_id, turn_number, variant_index, '
      'content, source_input, created_at) '
      "VALUES ('s1', 1, 1, '稿件 v2', '改一下', 1100)",
    );

    final copy = await repo.copySession('s1');

    // 轮产物随复制：session_id 改写、turn/指针/过程 JSON 原样
    final artifacts = await db.customSelect(
      'SELECT turn_number, agent_timeline, agent_summary, '
      'current_variant_index FROM intermediate_round_artifacts '
      'WHERE session_id = ?',
      variables: [Variable.withString(copy.sessionId)],
    ).get();
    expect(artifacts, hasLength(1), reason: '副本必须携带轮产物（幕后回放/Recap）');
    final artifact = artifacts.single;
    expect(artifact.read<int>('turn_number'), 1);
    expect(artifact.read<String>('agent_timeline'), '[{"kind":"action"}]');
    expect(artifact.read<String>('agent_summary'), '{"steps":2}');
    expect(
      artifact.readNullable<int>('current_variant_index'),
      1,
      reason: '当前变体指针必须原值保留，否则副本变体切换悬空',
    );

    // 变体行随复制：turn 键不变、内容/来源指令原样
    final variants = await db.customSelect(
      'SELECT variant_index, content, source_input FROM message_variants '
      'WHERE session_id = ? ORDER BY variant_index',
      variables: [Variable.withString(copy.sessionId)],
    ).get();
    expect(variants, hasLength(2));
    expect(variants[0].read<int>('variant_index'), 0);
    expect(variants[0].read<String>('content'), '稿件 v1');
    expect(variants[1].read<int>('variant_index'), 1);
    expect(variants[1].read<String>('content'), '稿件 v2');
    expect(variants[1].readNullable<String>('source_input'), '改一下');

    // 指针指向的变体在副本内可解析（一致性）
    final copyIds = await db.customSelect(
      'SELECT id FROM intermediate_round_artifacts WHERE session_id = ?',
      variables: [Variable.withString(copy.sessionId)],
    ).get();
    final sourceIds = await db.customSelect(
      'SELECT id FROM intermediate_round_artifacts WHERE session_id = ?',
      variables: [Variable.withString('s1')],
    ).get();
    expect(
      copyIds.single.read<int>('id'),
      isNot(sourceIds.single.read<int>('id')),
      reason: '副本行必须获得新自增 id，不得与源行主键冲突',
    );

    // 删除源会话不影响副本（副本独立推进互不影响）
    await repo.deleteSession('s1');
    final afterDelete = await db.customSelect(
      'SELECT COUNT(*) AS c FROM intermediate_round_artifacts '
      'WHERE session_id = ?',
      variables: [Variable.withString(copy.sessionId)],
    ).get();
    expect(afterDelete.single.read<int>('c'), 1);
    final variantsAfterDelete = await db.customSelect(
      'SELECT COUNT(*) AS c FROM message_variants WHERE session_id = ?',
      variables: [Variable.withString(copy.sessionId)],
    ).get();
    expect(variantsAfterDelete.single.read<int>('c'), 2);
  });
}

/// 在第一条 chat_messages 插入语句上抛错的拦截器（OH-3 注入点）。
///
/// 同时拦截 runInsert（逐条 insert 形态）与 runBatched（batch 形态），
/// 保证对两种实现形态都能模拟「复制中途 DB 失败」。
class _FailChatMessagesInsert extends QueryInterceptor {
  bool armed = false;

  final _pattern = RegExp(
    r'INSERT\s+INTO\s+"?chat_messages"?',
  );

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (armed && _pattern.hasMatch(statement)) {
      armed = false;
      throw Exception('注入失败：chat_messages 插入中断');
    }
    return executor.runInsert(statement, args);
  }

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) async {
    if (armed && statements.statements.any(_pattern.hasMatch)) {
      armed = false;
      throw Exception('注入失败：chat_messages 插入中断');
    }
    return executor.runBatched(statements);
  }
}
