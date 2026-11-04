import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';

/// 自动命名条件写标题（CAS）仓库测试
///
/// 消灭「命名 LLM 在途期间用户手动重命名被静默覆盖」的竞态：
/// 当前标题仍属草稿标题集合（含空串）时写入并返回 true；用户已改名
/// （当前标题不在集合）时放弃写入并返回 false。
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

  Future<String> titleOf(String sessionId) async =>
      (await repo.getSession(sessionId)).title;

  test('当前标题为草稿标题时 CAS 写入成功', () async {
    await db.customStatement(
      "INSERT INTO chat_sessions (session_id, title) VALUES ('s1', '新对话')",
    );

    final written = await repo.updateSessionTitleIfCurrentTitleIn(
      's1',
      '灯塔守夜人',
      const {'新对话', ''},
    );

    expect(written, isTrue);
    expect(await titleOf('s1'), '灯塔守夜人');
  });

  test('当前标题为空串时 CAS 写入成功（空标题视为未命名）', () async {
    await db.customStatement(
      "INSERT INTO chat_sessions (session_id, title) VALUES ('s1', '')",
    );

    final written = await repo.updateSessionTitleIfCurrentTitleIn(
      's1',
      '雨夜灯塔',
      const {'新故事', ''},
    );

    expect(written, isTrue);
    expect(await titleOf('s1'), '雨夜灯塔');
  });

  test('命名在途期间用户已重命名 → CAS 放弃写入，用户标题保全', () async {
    await db.customStatement(
      "INSERT INTO chat_sessions (session_id, title) VALUES ('s1', '我的自定义标题')",
    );

    final written = await repo.updateSessionTitleIfCurrentTitleIn(
      's1',
      'AI 起的标题',
      const {'新故事', ''},
    );

    expect(written, isFalse);
    expect(await titleOf('s1'), '我的自定义标题');
  });

  test('force 语义：入口快照标题在允许集合时自定义标题也可被覆盖', () async {
    // 对应 chat 控制器 updateTitleFromSummary(force: true)：
    // 用户主动触发重命名时，把入口快照标题也放进允许集合。
    await db.customStatement(
      "INSERT INTO chat_sessions (session_id, title) VALUES ('s1', '旧摘要标题')",
    );

    final written = await repo.updateSessionTitleIfCurrentTitleIn(
      's1',
      '新摘要标题',
      const {'新对话', '', '旧摘要标题'},
    );

    expect(written, isTrue);
    expect(await titleOf('s1'), '新摘要标题');
  });

  test('会话不存在 → 返回 false 不抛异常', () async {
    final written = await repo.updateSessionTitleIfCurrentTitleIn(
      'ghost',
      '任意',
      const {'新对话', ''},
    );
    expect(written, isFalse);
  });
}
