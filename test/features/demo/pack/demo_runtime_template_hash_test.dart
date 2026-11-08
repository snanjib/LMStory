import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/storage/secure_storage.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/demo/data/demo_pack_loader.dart';
import 'package:lmstory/features/demo/data/demo_state_store.dart';
import 'package:lmstory/features/demo/domain/demo_candidate.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';
import 'package:lmstory/features/demo/presentation/demo_runtime.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shared/demo_pack_factory.dart';

/// 运行时模板哈希复核（契约 §7.2 第三重对账在生产路径生效）：
/// 包内 templateHash 与演示库种子后的模板行 content 不符时，挂载必须
/// 本地拒绝（不进入半兼容体验），且已有可恢复数据保留。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;
  late DemoStateStore store;
  late AppDatabase realDb;
  late File demoFile;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmpDir = Directory.systemTemp.createTempSync('demo_tpl_hash');
    store = DemoStateStore(directory: tmpDir);
    realDb = AppDatabase.forTesting(NativeDatabase.memory());
    demoFile = File('${tmpDir.path}/demo.db');
  });

  tearDown(() async {
    await realDb.close();
    tmpDir.deleteSync(recursive: true);
  });

  AppDatabase openDemo() => AppDatabase.forTesting(NativeDatabase(demoFile));

  DemoRuntime runtime(DemoPack pack) => DemoRuntime(
        realDatabase: realDb,
        preferences: Preferences(),
        secureStorage: SecureStorage(),
        stateStore: store,
        databaseOpener: () async => openDemo(),
        packLoader: _FakeLoader(pack),
      );

  test('包模板哈希与库内模板不符 → start 拒绝挂载', () async {
    final pack = tamperedTemplateHashPack();
    final r = runtime(pack);
    addTearDown(r.dispose);
    await r.load();

    await expectLater(
      r.start(),
      throwsA(isA<DemoPackUnavailableException>()),
      reason: '模板已变而包未更新 → 本地拒绝不兼容体验',
    );
    expect(r.scopeActive, isFalse, reason: '拒绝挂载——不得进入半兼容运行');
  });

  test('resume 场景复核失败：已有可恢复数据保留', () async {
    await store.save(
      const DemoState(
        inviteStatus: DemoInviteStatus.accepted,
        phase: DemoPhase.running,
        runId: 'run-1',
        sessionId: 's1',
        seedPresetId: 'demo-seed-preset',
      ),
    );
    final seedDb = openDemo();
    await seedDb.customStatement(
      'INSERT INTO chat_sessions (session_id, title, mode, created_at, '
      'last_active_at, message_count, next_turn) VALUES '
      "('s1', 't', 'advanced', 1, 2, 2, 2)",
    );
    await seedDb.close();

    final r = runtime(tamperedTemplateHashPack());
    addTearDown(r.dispose);
    await r.load();
    await expectLater(r.start(), throwsA(isA<DemoPackUnavailableException>()));

    // 可恢复数据保留（经新连接读）
    final checkDb = openDemo();
    addTearDown(checkDb.close);
    final rows = await checkDb
        .customSelect(
          "SELECT COUNT(*) n FROM chat_sessions WHERE session_id='s1'",
        )
        .get();
    expect(rows.first.read<int>('n'), 1, reason: '拒绝挂载不得破坏演示数据');
    expect(r.state.phase, DemoPhase.running, reason: '状态保持可恢复');
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
  }) async {
    // 运行时库层复核在 start 内做——加载器不做模板对账（模拟生产装配
    // 只带 asset 校验的形态）
    return pack;
  }

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
      'assets/demo/first_launch/$localeTag.json';
}

/// 构造 templateHash 被篡改的最小包（模拟「模板变了而包未重采」）
DemoPack tamperedTemplateHashPack() {
  final pack = DemoPack.parse(const <String, dynamic>{
    'manifest': {
      'formatVersion': 1,
      'sceneId': 'first_launch_director',
      'kind': 'sample',
      'locale': 'zh-CN',
      'contentVersion': 'stale-template',
      'templateId': 'builtin-isekai-narrator',
      'templateHash': '0000000000000000',
      'promptHash': '0123456789abcdef',
      'toolFingerprint': '0123456789abcdef',
      'embeddingDimensions': 4,
      'embeddingModelLabel': 't',
    },
    'prompt': '（推进门）',
    'responses': {'stream': <dynamic>[], 'chat': <dynamic>[]},
    'embeddings': <dynamic>[],
    'expectations': {
      'proseContains': <String>[],
      'entityNames': <String>[],
      'eventSummaryContains': <String>[],
      'nextTurn': 2,
      'messageRoles': ['user', 'assistant'],
    },
  });
  return pack;
}
