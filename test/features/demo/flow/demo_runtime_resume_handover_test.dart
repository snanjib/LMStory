import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/storage/secure_storage.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
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

/// DemoRuntime 生命周期回归：恢复保留数据、重启交接核验（契约 §4/§8）。
///
/// 全部使用注入的内存库与临时状态目录，不触真实路径。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;
  late DemoStateStore store;
  late AppDatabase realDb;
  late File demoFile;
  late Preferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmpDir = Directory.systemTemp.createTempSync('demo_resume_handover');
    store = DemoStateStore(directory: tmpDir);
    realDb = AppDatabase.forTesting(NativeDatabase.memory());
    demoFile = File('${tmpDir.path}/demo.db');
    prefs = Preferences();
  });

  tearDown(() async {
    await realDb.close();
    tmpDir.deleteSync(recursive: true);
  });

  /// 每次调用新连接（镜像生产 openDemoDatabase 语义；文件库数据跨连接存活）
  AppDatabase openDemo() => AppDatabase.forTesting(NativeDatabase(demoFile));

  /// 布置模板并构造「模板哈希与库一致」的合法包（挂载复核用）
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

  /// 在演示库布置一个「已完成一回合」的会话夹具
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
      'INSERT INTO factual_entities (entity_id, session_id, primary_name, '
      "type, created_turn) VALUES (?, ?, '玛尔塔', 'character', 1)",
      ['ent-$sessionId', sessionId],
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

  group('一、resume 不清库（恢复保留会话与回合状态）', () {
    test('继续体验：会话/消息/实体/事件原样保留，密钥重注入不清库', () async {
      const sid = 'kept-run';
      await store.save(
        const DemoState(
          inviteStatus: DemoInviteStatus.accepted,
          phase: DemoPhase.running,
          runId: 'run-1',
          sessionId: sid,
          stepId: 'sessionInput',
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
      // resume 路径：runId 存在且非 fresh
      await r.start();

      expect(r.scopeActive, isTrue);
      expect(r.state.sessionId, sid, reason: '恢复必须保留原会话 id');
      // 数据内容逐项保留（经新连接读，模拟重启后读取）
      final checkDb = openDemo();
      addTearDown(checkDb.close);
      expect(
        await countIn(checkDb, 'SELECT COUNT(*) n FROM chat_sessions'),
        1,
        reason: '恢复不得清库重播种',
      );
      expect(
        await countIn(
          checkDb,
          "SELECT COUNT(*) n FROM chat_messages WHERE session_id='$sid'",
        ),
        2,
      );
      expect(
        await countIn(
          checkDb,
          "SELECT COUNT(*) n FROM factual_entities WHERE session_id='$sid'",
        ),
        1,
      );
      expect(
        await countIn(
          checkDb,
          "SELECT COUNT(*) n FROM agent_events WHERE session_id='$sid'",
        ),
        1,
      );
      // 回合状态不重置（经新连接读，模拟重启后读取）
      final checkDb2 = openDemo();
      addTearDown(checkDb2.close);
      final row = (await checkDb
              .customSelect(
                "SELECT next_turn FROM chat_sessions WHERE session_id='$sid'",
              )
              .get())
          .single;
      expect(row.read<int>('next_turn'), 2, reason: '回合进度必须保留');
    });

    test('显式重新开始（fresh）：清库重建是新 run 语义', () async {
      const sid = 'old-run';
      await store.save(
        const DemoState(
          inviteStatus: DemoInviteStatus.accepted,
          phase: DemoPhase.running,
          runId: 'run-1',
          sessionId: sid,
        ),
      );
      final seedDb = openDemo();
      await seedCompletedSessionOn(seedDb, sid);
      await seedDb.close();

      final pack = await buildValidPack();
      final r = runtime(packLoader: _FakeLoader(pack));
      addTearDown(r.dispose);
      await r.load();
      await r.start(fresh: true);

      expect(
        await countIn(openDemo(), 'SELECT COUNT(*) n FROM chat_sessions'),
        0,
        reason: '显式重新开始允许清库（全新 run）',
      );
      expect(r.state.runId, isNot('run-1'));
    });
  });

  group('二、重启交接（handoverPending 核验后才能完成）', () {
    test('正式提交前终止：重启完成导入并标记完成', () async {
      const sid = 'pending-import';
      await store.save(
        const DemoState(
          inviteStatus: DemoInviteStatus.accepted,
          phase: DemoPhase.handoverPending,
          runId: 'run-1',
          sessionId: sid,
          seedPresetId: 'demo-seed-preset',
        ),
      );
      final seedDb = openDemo();
      await seedCompletedSessionOn(seedDb, sid);
      await seedDb.close();

      final r = runtime();
      addTearDown(r.dispose);
      await r.load();

      expect(
        r.state.phase,
        DemoPhase.handoverDone,
        reason: '源数据完好且正式库未导入 → 重启补跑导入成功',
      );
      // 正式库确实收到会话
      expect(
        await countIn(realDb, 'SELECT COUNT(*) n FROM chat_sessions'),
        1,
      );
    });

    test('正式提交后、状态更新前终止：重启核验已导入 → 完成，无重复', () async {
      const sid = 'already-in-real';
      await store.save(
        const DemoState(
          inviteStatus: DemoInviteStatus.accepted,
          phase: DemoPhase.handoverPending,
          runId: 'run-1',
          sessionId: sid,
          seedPresetId: 'demo-seed-preset',
        ),
      );
      // 正式库已有同 ID 会话（上次提交成功）；源库也还有（清理前崩溃）
      final seedDb = openDemo();
      await seedCompletedSessionOn(seedDb, sid);
      await seedDb.close();
      await realDb.customStatement(
        'INSERT INTO chat_sessions (session_id, title, mode, created_at, '
        'last_active_at, message_count, next_turn) VALUES '
        "(?, '正式', 'advanced', 1000, 1001, 2, 2)",
        [sid],
      );

      final r = runtime();
      addTearDown(r.dispose);
      await r.load();

      expect(r.state.phase, DemoPhase.handoverDone);
      expect(
        await countIn(realDb, 'SELECT COUNT(*) n FROM chat_sessions'),
        1,
        reason: '同 ID IGNORE 幂等，不得重复导入',
      );
    });

    test('源数据缺失且正式库未导入：保持 pending，不得标记完成', () async {
      await store.save(
        const DemoState(
          inviteStatus: DemoInviteStatus.accepted,
          phase: DemoPhase.handoverPending,
          runId: 'run-1',
          sessionId: 'vanished-session',
          seedPresetId: 'demo-seed-preset',
        ),
      );
      // 演示库为空（源缺失）、正式库为空（未导入）

      final r = runtime();
      addTearDown(r.dispose);
      await r.load();

      expect(
        r.state.phase,
        DemoPhase.handoverPending,
        reason: 'sourceMissing 不得无条件当成功——保持可重试/可放弃状态',
      );
      expect(
        await countIn(realDb, 'SELECT COUNT(*) n FROM chat_sessions'),
        0,
      );
    });

    test('交接重试：先失败保留 pending，再成功完成', () async {
      const sid = 'retry-case';
      await store.save(
        const DemoState(
          inviteStatus: DemoInviteStatus.accepted,
          phase: DemoPhase.handoverPending,
          runId: 'run-1',
          sessionId: sid,
          seedPresetId: 'demo-seed-preset',
        ),
      );
      final seedDb = openDemo();
      await seedCompletedSessionOn(seedDb, sid);
      await seedDb.close();

      var failNext = true;
      final r = runtime(
        handoverFactory: () => DemoSessionHandover(
          failBeforeCommit:
              failNext ? () => throw Exception('injected failure') : null,
        ),
      );
      addTearDown(r.dispose);

      await r.load();
      expect(
        r.state.phase,
        DemoPhase.handoverPending,
        reason: '导入失败必须保留 pending（源数据完好可重试）',
      );
      expect(
        await countIn(realDb, 'SELECT COUNT(*) n FROM chat_sessions'),
        0,
        reason: '失败导入不得残留半截数据',
      );

      failNext = false;
      await r.retryHandover();
      expect(r.state.phase, DemoPhase.handoverDone);
      expect(
        await countIn(realDb, 'SELECT COUNT(*) n FROM chat_sessions'),
        1,
      );
    });
  });

  group('持久化重启（发送前/生成中/已提交未看记忆）', () {
    test('发送前（无会话）：恢复后不自动产生首轮提交', () async {
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
        reason: '无物化会话 → 恢复矩阵回向导起点',
      );
      expect(
        await countIn(openDemo(), 'SELECT COUNT(*) n FROM chat_sessions'),
        0,
        reason: '发送前重启不得凭空产生会话/提交',
      );
      expect(r.state.phase, DemoPhase.running);
    });

    test('生成中（会话已物化、回合未提交）：保留会话，恢复到重发，不重复提交', () async {
      const sid = 'inflight-run';
      await store.save(
        const DemoState(
          inviteStatus: DemoInviteStatus.accepted,
          phase: DemoPhase.running,
          runId: 'run-1',
          sessionId: sid,
          stepId: 'roundRunning',
          seedPresetId: 'demo-seed-preset',
        ),
      );
      // 物化会话但 next_turn=1（首轮未提交完成）
      final seedDb = openDemo();
      await seedDb.customStatement(
        'INSERT INTO chat_sessions (session_id, title, mode, created_at, '
        'last_active_at, message_count, next_turn) VALUES '
        "(?, '进行中', 'advanced', 1000, 1001, 1, 1)",
        [sid],
      );
      await seedDb.customStatement(
        'INSERT INTO chat_messages (message_id, session_id, role, content, '
        "created_at) VALUES (?, ?, 'user', '（固定提示词）', 1000)",
        ['m-u-$sid', sid],
      );
      await seedDb.close();

      final pack = await buildValidPack();
      final r = runtime(packLoader: _FakeLoader(pack));
      addTearDown(r.dispose);
      await r.load();
      await r.start();

      expect(
        r.state.stepId,
        'sessionInput',
        reason: '回合未提交 → 恢复到重发步骤',
      );
      expect(r.state.sessionId, sid);
      // 不重复提交：用户消息仍只有一条、next_turn 仍为 1
      final checkDb = openDemo();
      addTearDown(checkDb.close);
      expect(
        await countIn(
          checkDb,
          "SELECT COUNT(*) n FROM chat_messages WHERE session_id='$sid' "
          "AND role='user'",
        ),
        1,
      );
      final row = (await checkDb
              .customSelect(
                "SELECT next_turn FROM chat_sessions WHERE session_id='$sid'",
              )
              .get())
          .single;
      expect(row.read<int>('next_turn'), 1);
    });

    test('已提交未看记忆（next_turn≥2）：恢复到设置步，数据原样', () async {
      const sid = 'committed-run';
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

      expect(
        r.state.stepId,
        'settingsIntro',
        reason: '已提交 → 恢复到看设置/记忆段，不再生成一轮',
      );
      final checkDb = openDemo();
      addTearDown(checkDb.close);
      expect(
        await countIn(
          checkDb,
          "SELECT COUNT(*) n FROM chat_messages WHERE session_id='$sid'",
        ),
        2,
        reason: '恢复前后消息内容一致',
      );
      final row = (await checkDb
              .customSelect(
                "SELECT next_turn FROM chat_sessions WHERE session_id='$sid'",
              )
              .get())
          .single;
      expect(row.read<int>('next_turn'), 2, reason: '不得重复提交首轮');
    });
  });
}

/// 测试用包加载器（返回预构造包；生产对账在 runtime 库层复核）
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
