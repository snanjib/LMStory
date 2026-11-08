import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
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
import 'package:lmstory/features/demo/presentation/demo_selection_controller.dart';
import 'package:lmstory/features/templates/data/repositories/template_repository_impl.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 多仿真候选持久身份回归：
/// - 全新 run 写入候选身份（candidateId/virtualModelId/packSha256）；
/// - 恢复按上次候选定位同一包，不按默认 GLM 重挑；
/// - 所选候选不可用 → 拒绝恢复（不静默换另一模型）；
/// - 旧单包状态（无 candidateId）映射默认候选；
/// - 回合已开始的恢复直接锁定候选绑定。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;
  late DemoStateStore store;
  late AppDatabase realDb;
  late File demoFile;
  late Preferences prefs;
  late String templateHash;

  AppDatabase openDemo() => AppDatabase.forTesting(NativeDatabase(demoFile));

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmpDir = Directory.systemTemp.createTempSync('demo_candidate_resume');
    store = DemoStateStore(directory: tmpDir);
    realDb = AppDatabase.forTesting(NativeDatabase.memory());
    demoFile = File('${tmpDir.path}/demo.db');
    prefs = Preferences();
    // 与库内实际模板行对账的真实哈希（挂载期第三重复核要求）
    final db = openDemo();
    await TemplateRepositoryImpl(db).ensureBuiltInTemplates();
    final tpl =
        await TemplateRepositoryImpl(db).getTemplate('builtin-isekai-narrator');
    templateHash = demoContentHash(tpl.content);
    await db.close();
  });

  tearDown(() async {
    await realDb.close();
    tmpDir.deleteSync(recursive: true);
  });

  DemoPack buildPack({String contentVersion = 'v2-cand'}) {
    return DemoPack.parse(<String, dynamic>{
      'manifest': <String, dynamic>{
        'formatVersion': 2,
        'sceneId': 'first_launch_director',
        'kind': 'official',
        'locale': 'zh-CN',
        'contentVersion': contentVersion,
        'templateId': 'builtin-isekai-narrator',
        'templateHash': templateHash,
        'promptHash': '0123456789abcdef',
        'toolFingerprint': '0123456789abcdef',
        'embeddingDimensions': 4,
        'embeddingModelLabel': 'm',
        'replayProfile': DemoReplayProfile.zhipu.toJson(),
        'source': <String, dynamic>{'textModel': 'glm-5.3'},
      },
      'prompt': '（固定提示词）',
      'responses': <String, dynamic>{
        'stream': <dynamic>[
          <String, dynamic>{
            'purpose': 'agent_step',
            'turn': 1,
            'events': <dynamic>[
              <String, dynamic>{'type': 'text_delta', 'content': 'ok'},
              <String, dynamic>{'type': 'done', 'finishReason': 'stop'},
            ],
          },
        ],
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

  /// 多候选桩加载器：id → 包 的确定映射（loadCandidate 按候选返回对应包）
  late _MultiCandidateLoader loader;
  late DemoRuntime runtime;

  Future<DemoRuntime> createRuntime(
    _MultiCandidateLoader loader, {
    bool reuseState = false,
  }) async {
    final r = DemoRuntime(
      realDatabase: realDb,
      preferences: prefs,
      secureStorage: SecureStorage(),
      stateStore: store,
      databaseOpener: () async => openDemo(),
      packLoader: loader,
    );
    await r.load();
    return r;
  }

  test('全新 run 写入默认候选身份与包身份，候选清单进播种', () async {
    loader = _MultiCandidateLoader(<String, DemoPack>{
      'glm-5.3': buildPack(contentVersion: 'v2-glm5.3-official'),
      'kimi-k3.1-pro': buildPack(contentVersion: 'v2-kimi'),
    });
    runtime = await createRuntime(loader);
    addTearDown(runtime.dispose);
    await runtime.start(fresh: true);

    expect(runtime.state.candidateId, 'glm-5.3');
    expect(runtime.state.virtualModelId, 'demo-narrator-glm-5.3');
    expect(runtime.state.packContentVersion, 'v2-glm5.3-official');
    expect(runtime.state.packSha256, isNull, reason: '测试桩无字节锚，缺省合法');
    expect(runtime.state.replayProfileId, DemoReplayProfile.zhipuId);
    // 演示库播种了候选清单（两个对话模型都在缓存列表）
    final demoDb = runtime.container!.read(appDatabaseProvider);
    final models = await demoDb
        .customSelect(
          'SELECT cached_models FROM api_presets',
        )
        .get();
    expect(
      models.single.read<String>('cached_models'),
      contains('demo-narrator-kimi-k3.1-pro'),
    );
  });

  test('恢复定位上次所选候选，而非默认 GLM', () async {
    loader = _MultiCandidateLoader(<String, DemoPack>{
      'glm-5.3': buildPack(contentVersion: 'v2-glm5.3-official'),
      'kimi-k3.1-pro': buildPack(contentVersion: 'v2-kimi'),
    });
    runtime = await createRuntime(loader);
    addTearDown(runtime.dispose);
    await runtime.start(fresh: true);
    // 用户在向导模型步绑定 Kimi（经协调点持久身份）
    await runtime.container!.read(demoSelectionProvider).bindByVirtualModelId(
          'demo-narrator-kimi-k3.1-pro',
        );
    expect(runtime.state.candidateId, 'kimi-k3.1-pro');
    await runtime.exitKeepData();

    final r2 = DemoRuntime(
      realDatabase: realDb,
      preferences: prefs,
      secureStorage: SecureStorage(),
      stateStore: store,
      databaseOpener: () async => openDemo(),
      packLoader: loader,
    );
    addTearDown(r2.dispose);
    await r2.load();
    await r2.start();
    // 恢复挂载的是 Kimi 包（contentVersion 对账通过即证明不是默认 GLM）
    expect(r2.state.packContentVersion, 'v2-kimi');
    expect(r2.state.candidateId, 'kimi-k3.1-pro');
  });

  test('所选候选不可用：拒绝恢复，不静默换另一模型', () async {
    loader = _MultiCandidateLoader(<String, DemoPack>{
      'glm-5.3': buildPack(contentVersion: 'v2-glm5.3-official'),
      'kimi-k3.1-pro': buildPack(contentVersion: 'v2-kimi'),
    });
    runtime = await createRuntime(loader);
    addTearDown(runtime.dispose);
    await runtime.start(fresh: true);
    await runtime.container!.read(demoSelectionProvider).bindByVirtualModelId(
          'demo-narrator-kimi-k3.1-pro',
        );
    await runtime.exitKeepData();

    // 恢复时 Kimi 候选从目录消失（如资产缺失被剔除）
    final shrunken = _MultiCandidateLoader(<String, DemoPack>{
      'glm-5.3': buildPack(contentVersion: 'v2-glm5.3-official'),
    });
    final r2 = DemoRuntime(
      realDatabase: realDb,
      preferences: prefs,
      secureStorage: SecureStorage(),
      stateStore: store,
      databaseOpener: () async => openDemo(),
      packLoader: shrunken,
    );
    addTearDown(r2.dispose);
    await r2.load();
    await expectLater(
      r2.start(),
      throwsA(isA<DemoPackUnavailableException>()),
      reason: '保存的候选不可用必须拒绝恢复',
    );
  });

  test('旧单包状态（无 candidateId）映射默认候选正常恢复', () async {
    loader = _MultiCandidateLoader(<String, DemoPack>{
      'glm-5.3': buildPack(contentVersion: 'v2-official'),
    });
    runtime = await createRuntime(loader);
    addTearDown(runtime.dispose);
    // 先正常全新 run 落库播种（虚拟供应商/模板），再覆写为旧形态状态
    await runtime.start(fresh: true);
    final legacySeedPresetId = runtime.state.seedPresetId;
    await runtime.exitKeepData();
    await store.save(
      DemoState(
        phase: DemoPhase.running,
        inviteStatus: DemoInviteStatus.accepted,
        runId: 'legacy-run',
        seedPresetId: legacySeedPresetId,
        packContentVersion: 'v2-official',
        formatVersion: 2,
        replayProfileId: DemoReplayProfile.zhipuId,
        capabilitiesHash: DemoReplayProfile.zhipu.capabilitiesHash,
      ),
    );

    await runtime.start();

    expect(runtime.state.packContentVersion, 'v2-official');
    expect(runtime.state.candidateId, 'glm-5.3', reason: '映射默认候选并回填身份');
  });

  test('回合已开始的恢复：候选绑定直接锁定', () async {
    loader = _MultiCandidateLoader(<String, DemoPack>{
      'glm-5.3': buildPack(contentVersion: 'v2-official'),
    });
    runtime = await createRuntime(loader);
    addTearDown(runtime.dispose);
    await runtime.start(fresh: true);
    // 模拟首轮已发送：物化会话行 + agent_events 落库
    final demoDb = runtime.container!.read(appDatabaseProvider);
    await demoDb.customStatement(
      'INSERT INTO chat_sessions (session_id, title, mode, created_at, '
      "last_active_at, message_count, next_turn) VALUES ('s-resume', "
      "'r', 'advanced', datetime('now'), datetime('now'), 2, 2)",
    );
    await demoDb.customStatement(
      'INSERT INTO agent_events (session_id, seq, type, time, data) VALUES '
      "(?, 1, 'round_started', 1000, '{}')",
      ['s-resume'],
    );
    await runtime.exitKeepData();

    final r2 = DemoRuntime(
      realDatabase: realDb,
      preferences: prefs,
      secureStorage: SecureStorage(),
      stateStore: store,
      databaseOpener: () async => openDemo(),
      packLoader: loader,
    );
    addTearDown(r2.dispose);
    await r2.load();
    await r2.start();
    final selection = r2.container!.read(demoSelectionProvider);
    expect(selection.locked, isTrue, reason: '回合已开始的恢复禁止再换候选');
    await expectLater(
      selection.bindByVirtualModelId('demo-narrator-glm-5.3'),
      throwsA(isA<DemoCandidateLockedException>()),
    );
  });
}

/// 多候选桩：id → 包 确定映射；loadCandidate 按候选返回对应包
class _MultiCandidateLoader implements DemoPackLoader {
  _MultiCandidateLoader(this.packById);

  final Map<String, DemoPack> packById;

  late final List<DemoCandidate> candidates = <DemoCandidate>[
    for (final id in packById.keys)
      DemoCandidate(
        id: id,
        sourceModelId: 'model-$id',
        virtualModelId: 'demo-narrator-$id',
        locale: 'zh-CN',
        assetPath: 'test://$id.json',
        isDefault: id == packById.keys.first,
        displayNameZh: '仿真 · $id',
        displayNameEn: 'Sim · $id',
      ),
  ];

  @override
  Future<bool> isAvailable(String localeTag) async => true;

  @override
  Future<DemoPack> load(
    String localeTag, {
    String? expectedTemplateHash,
    String? expectedProfileId,
  }) async =>
      packById.values.first;

  @override
  Future<List<DemoCandidate>> loadCatalog() async => candidates;

  @override
  Future<DemoPack> loadCandidate(
    DemoCandidate candidate, {
    String? expectedTemplateHash,
  }) async =>
      packById[candidate.id]!;

  @override
  Future<List<DemoCandidate>> availableCandidates(String localeTag) async =>
      candidates;

  @override
  String assetPathFor(String localeTag) =>
      'assets/demo/first_launch/$localeTag.json';
}
