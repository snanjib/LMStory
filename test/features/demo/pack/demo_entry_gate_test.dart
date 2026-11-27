import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/demo/data/demo_pack_loader.dart';
import 'package:lmstory/features/demo/data/demo_secure_storage.dart';
import 'package:lmstory/features/demo/data/demo_state_store.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';
import 'package:lmstory/features/demo/presentation/demo_runtime.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 体验入口门控回归：入口按「当前 locale 至少一个合法
/// 候选」决定，与启动解析同源——
/// - 默认包缺失/损坏、其余四包有效 → 入口仍可用（真实 runtime 入口
///   `load()` 可触发首次邀请，帮助页独立复用可用性校验），启动落首个合法候选（用户在
///   向导模型步显式确认，不冒充已选择默认）；
/// - 非默认单项损坏 → 默认候选不受影响；
/// - 全部候选不可用 → 入口受控禁用，启动受控拒绝；
/// - en-US 可加载本地样例，未提供资源的语言仍禁用；
/// - 恢复指定候选不可用 → 拒绝恢复且状态原样保留（不静默换包）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmpDir;
  late AppDatabase realDb;
  late Preferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmpDir = Directory.systemTemp.createTempSync('demo_entry_gate');
    realDb = AppDatabase.forTesting(NativeDatabase.memory());
    prefs = Preferences();
  });

  tearDown(() async {
    await realDb.close();
    tmpDir.deleteSync(recursive: true);
  });

  /// 资产拦截 bundle：path→行为（'missing'=抛缺失；其他=替换为损坏 JSON）
  _InterceptBundle bundle(Map<String, String> intercept) =>
      _InterceptBundle(intercept);

  Future<DemoRuntime> newRuntime(
    DemoPackLoader loader, {
    DemoSecureStorage? secure,
  }) async {
    final runtime = DemoRuntime(
      realDatabase: realDb,
      preferences: prefs,
      secureStorage: secure ?? DemoSecureStorage(),
      stateStore: DemoStateStore(directory: tmpDir),
      databaseOpener: () async => AppDatabase.forTesting(
        NativeDatabase(File('${tmpDir.path}/demo.db')),
      ),
      packLoader: loader,
    );
    await runtime.load();
    return runtime;
  }

  test(
      'availability stops at the first valid pack; selection checks every pack',
      () async {
    final assets = bundle({
      'assets/demo/first_launch/zh-CN.json': 'missing',
    });
    final loader = DemoPackLoader(bundle: assets);
    expect(await loader.isAvailable('zh-CN'), isTrue);
    expect(assets.packReads, hasLength(2));
    assets.packReads.clear();
    expect(await loader.availableCandidates('zh-CN'), hasLength(4));
    expect(assets.packReads, hasLength(5));
  });

  test('a declined invitation does not read any demo packs on startup',
      () async {
    await DemoStateStore(directory: tmpDir).save(
      const DemoState(inviteStatus: DemoInviteStatus.declined),
    );
    final assets = bundle({});
    final runtime = await newRuntime(DemoPackLoader(bundle: assets));
    addTearDown(runtime.dispose);
    expect(runtime.inviteEligible, isFalse);
    expect(assets.packReads, isEmpty);
    expect(await runtime.isPackAvailable('zh-CN'), isTrue);
    expect(await runtime.isPackAvailable('zh-CN'), isTrue);
    expect(assets.packReads, hasLength(1));
  });

  test('an already configured preset skips invitation asset checks', () async {
    await realDb.customStatement(
      "INSERT INTO api_presets (preset_id, name) VALUES ('fixture', 'test')",
    );
    final secure = DemoSecureStorage();
    await secure.write('api_key_fixture', 'fixture-value');
    final assets = bundle({});
    final runtime =
        await newRuntime(DemoPackLoader(bundle: assets), secure: secure);
    addTearDown(runtime.dispose);
    expect(runtime.inviteEligible, isFalse);
    expect(assets.packReads, isEmpty);
  });

  test('默认包缺失但其余四候选有效：真实 runtime 入口可用，启动落首个合法候选', () async {
    final loader = DemoPackLoader(
      bundle: bundle({
        'assets/demo/first_launch/zh-CN.json': 'missing',
      }),
    );

    expect(
      await loader.isAvailable('zh-CN'),
      isTrue,
      reason: '默认缺失不应整体隐藏入口（其余四包合法）',
    );
    final candidates = await loader.availableCandidates('zh-CN');
    expect(candidates, hasLength(4));
    expect(
      candidates.map((c) => c.id),
      isNot(contains('glm-5.3')),
      reason: '坏候选被剔除，不得冒充可用',
    );

    final runtime = await newRuntime(loader);
    addTearDown(runtime.dispose);
    // 邀请门与手动入口应共享同一语言的可用性校验
    expect(await runtime.isPackAvailable('zh-CN'), isTrue);
    expect(
      runtime.inviteEligible,
      isTrue,
      reason: '默认包缺失而其余候选有效时，首次邀请照常出现',
    );

    await runtime.start(fresh: true);
    expect(runtime.scopeActive, isTrue);
    expect(
      runtime.state.candidateId,
      'deepseek-v4.1-flash',
      reason: '目录序首个合法候选作为初始绑定；用户在向导模型步显式确认或改选',
    );
  });

  test('非默认候选损坏：默认候选与入口不受影响', () async {
    final loader = DemoPackLoader(
      bundle: bundle({
        'assets/demo/first_launch/zh-CN/kimi-k3.1-pro.json': 'corrupt',
      }),
    );

    expect(await loader.isAvailable('zh-CN'), isTrue);
    final candidates = await loader.availableCandidates('zh-CN');
    expect(candidates, hasLength(4));
    expect(candidates.first.id, 'glm-5.3', reason: '默认候选仍排首位');

    final runtime = await newRuntime(loader);
    addTearDown(runtime.dispose);
    await runtime.start(fresh: true);
    expect(runtime.state.candidateId, 'glm-5.3');
  });

  test('全部候选不可用：入口受控禁用，启动受控拒绝', () async {
    final loader = DemoPackLoader(
      bundle: bundle({
        for (final p in const [
          'assets/demo/first_launch/zh-CN.json',
          'assets/demo/first_launch/zh-CN/deepseek-v4.1-flash.json',
          'assets/demo/first_launch/zh-CN/glm-5.3-flash.json',
          'assets/demo/first_launch/zh-CN/kimi-k3.1-pro.json',
          'assets/demo/first_launch/zh-CN/mimo-v2.6-flash.json',
        ])
          p: 'missing',
      }),
    );

    expect(
      await loader.isAvailable('zh-CN'),
      isFalse,
      reason: '目录内全部候选不可用 → 受控禁用（不再按旧默认路径误报可用）',
    );

    final runtime = await newRuntime(loader);
    addTearDown(runtime.dispose);
    expect(await runtime.isPackAvailable('zh-CN'), isFalse);
    expect(runtime.inviteEligible, isFalse, reason: '入口隐藏（邀请不弹）');
    await expectLater(
      runtime.start(fresh: true),
      throwsA(isA<DemoPackUnavailableException>()),
    );
    expect(runtime.scopeActive, isFalse);
  });

  test('English first launch can open the authored offline story', () async {
    const loader = DemoPackLoader();
    await LocaleSettings.setLocaleRaw('en-US');
    addTearDown(() => LocaleSettings.setLocaleRaw('zh-CN'));

    final runtime = await newRuntime(loader);
    addTearDown(runtime.dispose);
    expect(runtime.inviteEligible, isTrue);
    expect(await runtime.isPackAvailable('en-US'), isTrue);
    expect(await loader.isAvailable('fr-FR'), isFalse);

    await runtime.start(fresh: true);
    expect(runtime.scopeActive, isTrue);
    expect(runtime.state.candidateId, 'en-us-story-sample');
  });

  test('恢复指定候选不可用：拒绝恢复且状态原样保留', () async {
    // 先写一份「候选=Kimi」的可恢复状态（字段与挂载对账要求一致）
    final store = DemoStateStore(directory: tmpDir);
    await store.save(
      const DemoState(
        phase: DemoPhase.running,
        inviteStatus: DemoInviteStatus.accepted,
        runId: 'resume-gate-run',
        candidateId: 'kimi-k3.1-pro',
        virtualModelId: 'demo-narrator-kimi-k3.1-pro',
      ),
    );

    final loader = DemoPackLoader(
      bundle: bundle({
        'assets/demo/first_launch/zh-CN/kimi-k3.1-pro.json': 'corrupt',
      }),
    );
    final runtime = await newRuntime(loader);
    addTearDown(runtime.dispose);
    // 入口照常可用（其余候选合法），但恢复项不可用必须拒绝
    expect(await runtime.isPackAvailable('zh-CN'), isTrue);
    await expectLater(
      runtime.start(),
      throwsA(isA<DemoPackUnavailableException>()),
    );
    // 状态原样保留：不清库、不静默换另一候选
    expect(runtime.state.candidateId, 'kimi-k3.1-pro');
    expect(runtime.state.phase, DemoPhase.running);
    expect(runtime.scopeActive, isFalse);
  });
}

/// 拦截式资产 bundle：真实资产走 rootBundle，被拦截路径按指令返回
/// 「缺失」或损坏 JSON（字节级坏包语义，指纹/解析对账真实拒绝）。
class _InterceptBundle extends CachingAssetBundle {
  _InterceptBundle(this._intercept);

  final Map<String, String> _intercept;
  final packReads = <String>[];

  @override
  Future<ByteData> load(String key) => rootBundle.load(key);

  @override
  Future<String> loadString(String key, {bool cache = true}) {
    if (key != DemoPackLoader.catalogAssetPath) packReads.add(key);
    final mode = _intercept[key];
    if (mode == null) return rootBundle.loadString(key, cache: cache);
    if (mode == 'missing') {
      // 同步抛：由 loadCandidate 的 loadString try 即时包裹捕获（与主控
      // 探针 MissingDefaultBundle 同型）
      throw FlutterError('synthetic missing asset: $key');
    }
    // 损坏字节走真实异步完成——SynchronousFuture 的同步续体会绕过
    // async/await 错误管线（sha 抛错逃出逐候选 catch，已实测复现）
    return Future<String>.value('{"broken":');
  }
}
