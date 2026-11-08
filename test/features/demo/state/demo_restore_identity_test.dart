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
import 'package:lmstory/features/demo/domain/demo_pack_fingerprint.dart';
import 'package:lmstory/features/demo/domain/demo_replay_profile.dart';
import 'package:lmstory/features/demo/presentation/demo_runtime.dart';
import 'package:lmstory/features/templates/data/repositories/template_repository_impl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shared/demo_pack_factory.dart';

class _StaticLoader implements DemoPackLoader {
  _StaticLoader(this._pack);
  final DemoPack _pack;
  late final _candidate = demoCandidateForPack(_pack);

  @override
  Future<bool> isAvailable(String localeTag) async => true;

  @override
  Future<DemoPack> load(
    String localeTag, {
    String? expectedTemplateHash,
    String? expectedProfileId,
  }) async =>
      _pack;

  @override
  Future<List<DemoCandidate>> loadCatalog() async => [_candidate];

  @override
  Future<DemoPack> loadCandidate(
    DemoCandidate candidate, {
    String? expectedTemplateHash,
  }) async =>
      _pack;

  @override
  Future<List<DemoCandidate>> availableCandidates(String localeTag) async =>
      [_candidate];

  @override
  String assetPathFor(String localeTag) =>
      'assets/demo/first_launch/$localeTag.json';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;
  late DemoStateStore store;
  late AppDatabase realDb;
  late File demoFile;
  late Preferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmpDir = Directory.systemTemp.createTempSync('demo_restore_identity');
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

  Future<DemoPack> createPack({
    int formatVersion = 2,
    String contentVersion = 'v2-official',
    String locale = 'zh-CN',
    DemoReplayProfile? replayProfile,
  }) async {
    final db = openDemo();
    addTearDown(db.close);
    await TemplateRepositoryImpl(db).ensureBuiltInTemplates();
    final tpl =
        await TemplateRepositoryImpl(db).getTemplate('builtin-isekai-narrator');

    final profile = replayProfile ?? DemoReplayProfile.zhipu;
    return DemoPack.parse({
      'manifest': {
        'formatVersion': formatVersion,
        'sceneId': 'first_launch_director',
        'kind': 'official',
        'locale': locale,
        'contentVersion': contentVersion,
        'templateId': 'builtin-isekai-narrator',
        'templateHash': demoContentHash(tpl.content),
        'promptHash': '0123456789abcdef',
        'toolFingerprint': '0123456789abcdef',
        'embeddingDimensions': 4,
        'embeddingModelLabel': 'm',
        'replayProfile': profile.toJson(),
      },
      'prompt': '（固定提示词）',
      'responses': {
        'stream': [
          {
            'purpose': 'agent_step',
            'turn': 1,
            'events': [
              {'type': 'text_delta', 'content': 'ok'},
              {'type': 'done', 'finishReason': 'stop'},
            ],
          },
        ],
        'chat': <dynamic>[],
      },
      'embeddings': <dynamic>[],
      'expectations': {
        'proseContains': <String>[],
        'entityNames': <String>[],
        'eventSummaryContains': <String>[],
        'nextTurn': 2,
        'messageRoles': ['user', 'assistant'],
      },
    });
  }

  DemoRuntime createRuntime(DemoPack pack) {
    return DemoRuntime(
      realDatabase: realDb,
      preferences: prefs,
      secureStorage: SecureStorage(),
      stateStore: store,
      databaseOpener: () async => openDemo(),
      packLoader: _StaticLoader(pack),
    );
  }

  test('一、v1 保存状态遇到 v2 数据包：拒绝恢复，抛出异常且不清库', () async {
    final pack = await createPack();
    // 写入 v1 历史保存状态（formatVersion 为 1 或 null）
    await store.save(
      const DemoState(
        phase: DemoPhase.running,
        runId: 'old-v1-run',
        sessionId: 'old-session-1',
        formatVersion: 1,
        packContentVersion: 'v1-sample',
        replayProfileId: 'conservativeRelay',
      ),
    );

    final r = createRuntime(pack);
    addTearDown(r.dispose);
    await r.load();

    expect(
      r.start,
      throwsA(isA<DemoPackUnavailableException>()),
      reason: 'formatVersion 不一致必须拒绝恢复',
    );
    expect(r.scopeActive, isFalse);

    final saved = await store.load();
    expect(saved.runId, 'old-v1-run', reason: '拒绝恢复不得抹掉旧状态');
  });

  test('二、contentVersion 不符：拒绝恢复', () async {
    final pack = await createPack(contentVersion: 'v2-new-version');
    await store.save(
      DemoState(
        phase: DemoPhase.running,
        runId: 'run-diff-content',
        formatVersion: 2,
        packContentVersion: 'v2-old-version',
        replayProfileId: DemoReplayProfile.zhipuId,
        capabilitiesHash: DemoReplayProfile.zhipu.capabilitiesHash,
      ),
    );

    final r = createRuntime(pack);
    addTearDown(r.dispose);
    await r.load();

    expect(
      r.start,
      throwsA(
        isA<DemoPackUnavailableException>().having(
          (e) => e.message,
          'message',
          contains('contentVersion mismatch'),
        ),
      ),
    );
    expect(r.scopeActive, isFalse);
  });

  test('三、replayProfile / capabilitiesHash 不符：拒绝恢复', () async {
    final pack = await createPack(
      replayProfile: DemoReplayProfile.zhipu,
    );
    await store.save(
      const DemoState(
        phase: DemoPhase.running,
        runId: 'run-diff-profile',
        formatVersion: 2,
        packContentVersion: 'v2-official',
        replayProfileId: 'conservativeRelay',
        capabilitiesHash: 'different-hash',
      ),
    );

    final r = createRuntime(pack);
    addTearDown(r.dispose);
    await r.load();

    expect(
      r.start,
      throwsA(isA<DemoPackUnavailableException>()),
    );
    expect(r.scopeActive, isFalse);
  });

  test('四、完整身份匹配：成功恢复并挂载 Demo 作用域', () async {
    final pack = await createPack(
      replayProfile: DemoReplayProfile.zhipu,
    );

    // 首先执行一次正常全新启动以落盘完整身份
    final r1 = createRuntime(pack);
    await r1.load();
    await r1.start(fresh: true);
    final savedState = r1.state;
    expect(savedState.formatVersion, 2);
    expect(savedState.packContentVersion, 'v2-official');
    expect(savedState.replayProfileId, DemoReplayProfile.zhipuId);
    expect(
      savedState.capabilitiesHash,
      DemoReplayProfile.zhipu.capabilitiesHash,
    );
    r1.dispose();

    // 重新创建 Runtime 执行恢复（resuming）
    final r2 = createRuntime(pack);
    addTearDown(r2.dispose);
    await r2.load();
    await r2.start();

    expect(r2.scopeActive, isTrue, reason: '身份匹配必须顺利挂载');
    expect(r2.state.runId, savedState.runId, reason: '恢复保持原 runId');
  });
}
