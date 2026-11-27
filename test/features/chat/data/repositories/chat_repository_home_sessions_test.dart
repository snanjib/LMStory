import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';

class _Selects extends QueryInterceptor {
  String sql = '';
  List<Map<String, Object?>> rows = [];

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    sql = statement;
    return rows = await executor.runSelect(statement, args);
  }
}

void main() {
  late _Selects selects;
  late AppDatabase db;
  late ChatRepositoryImpl repo;
  setUp(() async {
    selects = _Selects();
    db = AppDatabase.forTesting(NativeDatabase.memory().interceptWith(selects));
    repo = ChatRepositoryImpl(database: db);
    await db.customSelect('SELECT 1').get();
  });
  tearDown(() => db.close());

  const indexes = [
    'idx_session_recent',
    'idx_session_latest_story',
    'idx_msg_session_latest',
  ];

  Future<void> session(String id, String mode, String date) =>
      db.customStatement(
        'INSERT INTO chat_sessions (session_id, title, mode, last_active_at) '
        'VALUES (?,?,?,?)',
        [id, id, mode, date],
      );
  Future<void> message(String id, String sessionId, String? text) =>
      db.customStatement(
        'INSERT INTO chat_messages (message_id, session_id, role, content) '
        "VALUES (?, ?, 'assistant', ?)",
        [id, sessionId, text],
      );

  test('reads at most six sessions and bounded last-message previews',
      () async {
    for (var n = 0; n < 8; n++) {
      await session('c$n', 'chat', '2026-02-0${n + 1}T00:00:00Z');
    }
    await session('old', 'advanced', '2026-01-01T09:00:00.000001 +01:00');
    await session('new', 'intermediate', '2026-01-01T08:00:00.000002Z');
    final content = '中\u0000${'甲' * 47}😊${'乙' * 300}';
    await message('a', 'new', 'superseded');
    await message('b', 'new', content);
    await message('c', 'c7', '');
    await message('d', 'c6', null);

    final result = await repo.getHomeSessions();
    final sql = selects.sql;
    expect(selects.rows, hasLength(6));
    expect(
      result.recent.map((s) => s.sessionId),
      ['c7', 'c6', 'c5', 'c4', 'c3'],
    );
    expect(result.recent.first.lastMessagePreview, '');
    expect(result.recent[1].lastMessagePreview, isNull);
    expect(result.latestStory?.sessionId, 'new');
    expect(result.latestStory?.lastMessagePreview, content.substring(0, 50));
    for (final row in selects.rows) {
      final bytes = row['preview_bytes'] as Uint8List?;
      expect(bytes?.length ?? 0, lessThanOrEqualTo(150));
    }

    final plan = (await db.customSelect('EXPLAIN QUERY PLAN $sql').get())
        .map((r) => r.read<String>('detail'))
        .join('\n');
    for (final index in indexes) {
      expect(plan, contains(index));
    }
  });

  test('an existing database gains the indexes without changing its story',
      () async {
    await session('existing', 'advanced', '2026-01-01T12:00:00Z');
    await message('draft', 'existing', '已有稿件');
    for (final name in indexes) {
      await db.customStatement('DROP INDEX $name');
    }
    await db.repairSchema();
    final restored = (await db
            .customSelect(
              "SELECT name FROM sqlite_master WHERE type = 'index'",
            )
            .get())
        .map((row) => row.read<String>('name'));
    expect(restored, containsAll(indexes));
    final home = await repo.getHomeSessions();
    expect(home.latestStory?.lastMessagePreview, '已有稿件');
    expect(home.recent.single.sessionId, 'existing');
  });

  test('empty, chat-only, and featured story already in the recent list',
      () async {
    var result = await repo.getHomeSessions();
    expect(result.recent, isEmpty);
    expect(result.latestStory, isNull);
    await session('chat', 'chat', '2026-01-01T11:00:00Z');
    expect((await repo.getHomeSessions()).latestStory, isNull);
    await session('story', 'advanced', '2026-01-02T11:00:00Z');
    result = await repo.getHomeSessions();
    expect(selects.rows, hasLength(2));
    expect(result.recent.map((s) => s.sessionId), ['story', 'chat']);
    expect(result.latestStory, same(result.recent.first));
  });

  test('an unsent director composer draft supplies no message preview',
      () async {
    final director = await repo.createSession(title: '导演设置', mode: 'advanced');
    await repo.setSessionDraft(director.sessionId, '尚未发送的编辑框文字');

    final home = await repo.getHomeSessions();
    expect(home.recent.single.sessionId, director.sessionId);
    expect(home.recent.single.lastMessagePreview, isNull);
    expect(home.latestStory?.lastMessagePreview, isNull);
    expect(await repo.getSessionDraft(director.sessionId), '尚未发送的编辑框文字');
  });
}
