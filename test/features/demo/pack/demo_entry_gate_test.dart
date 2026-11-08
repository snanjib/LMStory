import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/storage/secure_storage.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/demo/data/demo_pack_loader.dart';
import 'package:lmstory/features/demo/data/demo_state_store.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';
import 'package:lmstory/features/demo/presentation/demo_runtime.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 体验入口门控回归：入口按「当前 locale 至少一个合法
/// 候选」决定，与启动解析同源——
/// - 默认包缺失/损坏、其余四包有效 → 入口仍可用（真实 runtime 入口
///   `load()` 的 packAvailable/inviteEligible 为真，invite 弹窗与
///   帮助页手动入口均消费这两个字段），启动落首个合法候选（用户在
///   向导模型步显式确认，不冒充已选择默认）；
/// - 非默认单项损坏 → 默认候选不受影响；
/// - 全部候选不可用 → 入口受控禁用（packAvailable=false），启动受控拒绝；
/// - locale 无候选（en-US）→ 入口禁用；
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

  Future<DemoRuntime> newRuntime(DemoPackLoader loader) async {
    final runtime = DemoRuntime(
      realDatabase: realDb,
      preferences: prefs,
      secureStorage: SecureStorage(),
      stateStore: DemoStateStore(directory: tmpDir),
      databaseOpener: () async => AppDatabase.forTesting(
        NativeDatabase(File('${tmpDir.path}/demo.db')),
      ),
      packLoader: loader,
    );
    await runtime.load();
    return runtime;
  }

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
    // 真实入口字段（invite 弹窗/帮助页手动入口共同消费）
    expect(runtime.packAvailable, isTrue);
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
    expect(runtime.packAvailable, isFalse);
    expect(runtime.inviteEligible, isFalse, reason: '入口隐藏（邀请不弹）');
    await expectLater(
      runtime.start(fresh: true),
      throwsA(isA<DemoPackUnavailableException>()),
    );
    expect(runtime.scopeActive, isFalse);
  });

  test('locale 无候选（en-US）：入口禁用', () async {
    const loader = DemoPackLoader();
    expect(
      await loader.isAvailable('en-US'),
      isFalse,
      reason: '英文无录制包：不把中文包冒充英文候选',
    );

    // 真实入口按当前 locale 门控：切英文后 runtime.load 必须禁用
    await LocaleSettings.setLocaleRaw('en-US');
    addTearDown(
      () => LocaleSettings.setLocaleRaw('zh-CN'),
    );
    final runtime = await newRuntime(loader);
    addTearDown(runtime.dispose);
    expect(runtime.packAvailable, isFalse);
    expect(runtime.inviteEligible, isFalse);
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
    expect(runtime.packAvailable, isTrue);
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

  @override
  Future<ByteData> load(String key) => rootBundle.load(key);

  @override
  Future<String> loadString(String key, {bool cache = true}) {
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
