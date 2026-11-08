import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/storage/secure_storage.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/demo/data/demo_pack_loader.dart';
import 'package:lmstory/features/demo/data/demo_session_handover.dart';
import 'package:lmstory/features/demo/data/demo_state_store.dart';
import 'package:lmstory/features/demo/domain/demo_candidate.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';
import 'package:lmstory/features/demo/domain/demo_pack_fingerprint.dart';
import 'package:lmstory/features/demo/presentation/demo_runtime.dart';
import 'package:lmstory/features/templates/data/repositories/template_repository_impl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shared/demo_pack_factory.dart';

Variable<String> driftVar(String v) => Variable.withString(v);

/// r3 修复回归（主控复核二/三）：
/// 二、真实首次物化会话 next_turn 可为 NULL——按业务轮次语义识别
///    未提交首轮，恢复到原会话与重发步骤；
/// 三、状态缺 sessionId 但源库已有成果——恢复时回填并持久化，完成
///    时实际交接，重复操作不重复导入。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;
  late DemoStateStore store;
  late AppDatabase realDb;
  late File demoFile;
  late Preferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmpDir = Directory.systemTemp.createTempSync('demo_r3_recovery');
    store = DemoStateStore(directory: tmpDir);
    realDb = AppDatabase.forTesting(NativeDatabase.memory());
    demoFile = File('${tmpDir.path}/demo.db');
    prefs = Preferences();
  });

  tearDown(() async {
    await realDb.close();
    tmpDir.deleteSync(recursive: true);
  });

  AppDatabase openDemo() => AppDatabase.forTesting(NativeDatabase(demoFile));

  Future<DemoPack> buildValidPack() async {
    final db = openDemo();
    addTearDown(db.close);
    await TemplateRepositoryImpl(db).ensureBuiltInTemplates();
    final tpl = await TemplateRepositoryImpl(
      db,
    ).getTemplate('builtin-isekai-narrator');
    return DemoPack.parse(<String, dynamic>{
      'manifest': {
        'formatVersion': 1,
        'sceneId': 'first_launch_director',
        'kind': 'sample',
        'locale': 'zh-CN',
        'contentVersion': 'test',
        'templateId': 'builtin-isekai-narrator',
        'templateHash': demoContentHash(tpl.content),
        'promptHash': '0123456789abcdef',
        'toolFingerprint': '0123456789abcdef',
        'embeddingDimensions': 4,
        'embeddingModelLabel': 'test',
      },
      'prompt': '（固定提示词）',
      'responses': <String, dynamic>{
        'stream': <dynamic>[],
        'chat': <dynamic>[],
      },
      'embeddings': <dynamic>[],
      'expectations': <String, dynamic>{
        'proseContains': <String>[],
        'entityNames': <String>[],
        'eventSummaryContains': <String>[],
        'nextTurn': 2,
        'messageRoles': <String>['user', 'assistant'],
      },
    });
  }

  DemoRuntime runtime({
    DemoSessionHandover Function()? handoverFactory,
    DemoPackLoader? packLoader,
  }) {
    return DemoRuntime(
      realDatabase: realDb,
      preferences: prefs,
      secureStorage: SecureStorage(),
      stateStore: store,
      databaseOpener: () async => openDemo(),
      handoverFactory: handoverFactory,
      packLoader: packLoader,
    );
  }

  /// 真实 repository 物化会话（不提交任何回合 → next_turn 为 NULL）
  Future<String> materializeSessionViaRepository() async {
    final db = openDemo();
    addTearDown(db.close);
    await TemplateRepositoryImpl(db).ensureBuiltInTemplates();
    final repo = ChatRepositoryImpl(database: db);
    final session = await repo.createSession(
      title: '新导演会话',
      mode: 'advanced',
    );
    await db.close();
    return session.sessionId;
  }

  /// 在演示库布置一个「已完成一回合」的会话夹具（next_turn=2）
  Future<void> seedCompletedSessionOn(
    AppDatabase demoDb,
    String sessionId,
  ) async {
    await demoDb.customStatement(
      'INSERT INTO chat_sessions (session_id, title, mode, created_at, '
      'last_active_at, message_count, next_turn) VALUES '
      "(?, '演示会话', 'advanced', 1000, 1001, 2, 2)",
      [sessionId],
    );
    await demoDb.customStatement(
      'INSERT INTO chat_messages (message_id, session_id, role, content, '
      "created_at) VALUES (?, ?, 'user', '（固定提示词）', 1000)",
      ['m-u-$sessionId', sessionId],
    );
    await demoDb.customStatement(
      'INSERT INTO chat_messages (message_id, session_id, role, content, '
      "created_at) VALUES (?, ?, 'assistant', '正文', 1001)",
      ['m-a-$sessionId', sessionId],
    );
    await demoDb.customStatement(
      'INSERT INTO agent_events (session_id, seq, type, time, data) VALUES '
      "(?, 1, 'round_started', 1000, '{}')",
      [sessionId],
    );
  }

  Future<int> countIn(
    AppDatabase db,
    String sql, [
    List<String> vars = const [],
  ]) async {
    final rows = await db.customSelect(sql).get();
    return rows.first.read<int>('n');
  }

  group('二、NULL next_turn（真实未提交首轮）', () {
    test('repository 物化（next_turn=NULL）→ 恢复到原会话与重发步骤', () async {
      // 用真实 repository 创建会话（镜像生产物化路径；无回合提交）
      final sid = await materializeSessionViaRepository();
      await store.save(
        DemoState(
          inviteStatus: DemoInviteStatus.accepted,
          phase: DemoPhase.running,
          runId: 'run-1',
          sessionId: sid,
          stepId: 'roundRunning',
          seedPresetId: 'demo-seed-preset',
        ),
      );

      final pack = await buildValidPack();
      final r = runtime(packLoader: _FakeLoader(pack));
      addTearDown(r.dispose);
      await r.load();
      await r.start();

      expect(
        r.state.stepId,
        'sessionInput',
        reason: 'NULL next_turn=未提交首轮 → 恢复到重发步骤',
      );
      expect(r.state.sessionId, sid, reason: '原会话保留');

      // 原数据保留（回合进度不重置）
      final checkDb = openDemo();
      addTearDown(checkDb.close);
      final row = (await checkDb.customSelect(
        'SELECT next_turn FROM chat_sessions WHERE session_id = ?',
        variables: [driftVar(sid)],
      ).get())
          .single;
      expect(row.data['next_turn'], isNull, reason: '恢复不写回合进度');
      expect(
        await countIn(
          checkDb,
          "SELECT COUNT(*) n FROM chat_sessions WHERE session_id = '$sid'",
        ),
        1,
      );
    });

    test('NULL 与 NULL（无会话）区分：无物化会话仍回向导起点', () async {
      await store.save(
        const DemoState(
          inviteStatus: DemoInviteStatus.accepted,
          phase: DemoPhase.running,
          runId: 'run-1',
          stepId: 'sessionInput',
          seedPresetId: 'demo-seed-preset',
        ),
      );

      final pack = await buildValidPack();
      final r = runtime(packLoader: _FakeLoader(pack));
      addTearDown(r.dispose);
      await r.load();
      await r.start();

      expect(
        r.state.stepId,
        'homeWizardEntry',
        reason: '库内无会话与「会话未提交」是两种状态，不得混淆',
      );
    });

    test('已提交 next_turn=2 回归：恢复到设置步（不受 NULL 修复影响）', () async {
      const sid = 'committed-regression';
      await store.save(
        const DemoState(
          inviteStatus: DemoInviteStatus.accepted,
          phase: DemoPhase.running,
          runId: 'run-1',
          sessionId: sid,
          stepId: 'memoryView',
          seedPresetId: 'demo-seed-preset',
        ),
      );
      final seedDb = openDemo();
      await seedCompletedSessionOn(seedDb, sid);
      await seedDb.close();

      final r = runtime();
      addTearDown(r.dispose);
      await r.load();
      await r.start();

      expect(r.state.stepId, 'settingsIntro');
      expect(r.state.sessionId, sid);
    });
  });

  group('三、状态缺 sessionId 的恢复回填与交接', () {
    test('状态 sessionId 空＋源库已有已提交回合 → 恢复回填 → 完成交接 → 正式库可查', () async {
      const sid = 'id-backfill-run';
      // 状态文件 sessionId 为空（物化后、状态回写前崩溃的窗口）
      await store.save(
        const DemoState(
          inviteStatus: DemoInviteStatus.accepted,
          phase: DemoPhase.running,
          runId: 'run-1',
          stepId: 'settingsIntro',
          seedPresetId: 'demo-seed-preset',
        ),
      );
      final seedDb = openDemo();
      await seedCompletedSessionOn(seedDb, sid);
      await seedDb.close();

      final pack = await buildValidPack();
      final r = runtime(packLoader: _FakeLoader(pack));
      addTearDown(r.dispose);
      await r.load();
      await r.start();

      // 恢复即回填（持久化）
      expect(r.state.sessionId, sid, reason: '数据库核验后的会话 id 必须写回状态，不能等同「没有成果」');
      final reloaded = DemoRuntime(
        realDatabase: realDb,
        preferences: prefs,
        secureStorage: SecureStorage(),
        stateStore: store,
        databaseOpener: () async => openDemo(),
        packLoader: _FakeLoader(pack),
      );
      await reloaded.load();
      expect(reloaded.state.sessionId, sid, reason: '回填已持久化（重启后仍在）');
      reloaded.dispose();

      // 完成 → 实际交接（不再跳过导入）
      await r.completeForTest();
      expect(r.state.phase, DemoPhase.handoverDone);
      expect(
        await countIn(realDb, 'SELECT COUNT(*) n FROM chat_sessions'),
        1,
        reason: '正式库收到完整会话',
      );
      expect(
        await countIn(realDb, 'SELECT COUNT(*) n FROM chat_messages'),
        2,
      );
    });

    test('重复完成（同 ID）→ alreadyImported，正式库无重复', () async {
      const sid = 'id-backfill-dup';
      await store.save(
        const DemoState(
          inviteStatus: DemoInviteStatus.accepted,
          phase: DemoPhase.running,
          runId: 'run-1',
          stepId: 'settingsIntro',
          seedPresetId: 'demo-seed-preset',
        ),
      );
      final seedDb = openDemo();
      await seedCompletedSessionOn(seedDb, sid);
      await seedDb.close();

      final pack = await buildValidPack();
      final r = runtime(packLoader: _FakeLoader(pack));
      addTearDown(r.dispose);
      await r.load();
      await r.start();
      expect(r.state.sessionId, sid);

      await r.completeForTest();
      expect(r.state.phase, DemoPhase.handoverDone);
      final firstCount =
          await countIn(realDb, 'SELECT COUNT(*) n FROM chat_sessions');
      expect(firstCount, 1);

      // 二次完成（同状态重入）→ 同 ID IGNORE，无重复
      await r.completeForTest();
      expect(
        await countIn(realDb, 'SELECT COUNT(*) n FROM chat_sessions'),
        1,
        reason: '重复操作不重复导入',
      );
    });
  });
}

class _FakeLoader implements DemoPackLoader {
  _FakeLoader(this.pack);

  final DemoPack pack;

  late final _candidate = demoCandidateForPack(pack);

  @override
  Future<DemoPack> load(
    String localeTag, {
    String? expectedTemplateHash,
    String? expectedProfileId,
  }) async =>
      pack;

  @override
  Future<List<DemoCandidate>> loadCatalog() async => [_candidate];

  @override
  Future<DemoPack> loadCandidate(
    DemoCandidate candidate, {
    String? expectedTemplateHash,
  }) async =>
      pack;

  @override
  Future<List<DemoCandidate>> availableCandidates(String localeTag) async =>
      [_candidate];

  @override
  Future<bool> isAvailable(String localeTag) async => true;

  @override
  String assetPathFor(String localeTag) =>
      r'assets/demo/first_launch/$localeTag.json';
}
