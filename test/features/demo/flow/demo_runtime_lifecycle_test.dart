import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/storage/secure_storage.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/demo/data/demo_state_store.dart';
import 'package:lmstory/features/demo/presentation/demo_runtime.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// T-ST-2：DemoRuntime 生命周期状态机（邀请门控/恢复矩阵/放弃）。
/// 交接幂等本体由 demo_session_handover_test 覆盖；此处在运行时层验证
/// 阶段流转与持久化。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler('flutter/assets', (message) async => null);

  late Directory tmpDir;
  late DemoStateStore store;
  late AppDatabase realDb;
  late Preferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'onboarding_completed': false,
    });
    tmpDir = Directory.systemTemp.createTempSync('lmstory_demo_runtime');
    store = DemoStateStore(directory: tmpDir);
    realDb = AppDatabase.forTesting(NativeDatabase.memory());
    prefs = Preferences();
  });

  tearDown(() async {
    await realDb.close();
    tmpDir.deleteSync(recursive: true);
  });

  DemoRuntime build() => DemoRuntime(
        realDatabase: realDb,
        preferences: prefs,
        secureStorage: SecureStorage(),
        stateStore: store,
      );

  test('load：全新状态 → 邀请门控按包可用性判定', () async {
    final runtime = build();
    addTearDown(runtime.dispose);
    await runtime.load();

    expect(runtime.state.inviteStatus, DemoInviteStatus.pending);
    expect(runtime.state.phase, DemoPhase.idle);
    expect(runtime.loaded, isTrue);
    // 测试环境资产经 mock handler 不可载 → 包不可用 → 不弹邀请
    expect(runtime.packAvailable, isFalse);
    expect(runtime.inviteEligible, isFalse, reason: '无可用包时绝不进入半兼容体验');
  });

  test('declineInvite 持久化；重载后不再弹', () async {
    final runtime = build();
    await runtime.declineInvite();
    expect(runtime.state.inviteStatus, DemoInviteStatus.declined);

    final reloaded = build();
    addTearDown(reloaded.dispose);
    await reloaded.load();
    expect(reloaded.state.inviteStatus, DemoInviteStatus.declined);
    expect(reloaded.inviteEligible, isFalse);
  });

  test('abandon：清状态为 idle（已 accepted）且可再 start', () async {
    final runtime = build();
    addTearDown(runtime.dispose);
    await runtime.abandon();
    expect(runtime.state.phase, DemoPhase.idle);
    expect(runtime.state.inviteStatus, DemoInviteStatus.accepted);
    expect(runtime.scopeActive, isFalse);
  });

  test('状态 roundtrip：running 检查点重载保持', () async {
    await store.save(
      const DemoState(
        inviteStatus: DemoInviteStatus.accepted,
        phase: DemoPhase.running,
        runId: 'r1',
        sessionId: 's1',
        stepId: 'settingsIntro',
      ),
    );
    final runtime = build();
    addTearDown(runtime.dispose);
    await runtime.load();
    expect(runtime.state.phase, DemoPhase.running);
    expect(runtime.state.stepId, 'settingsIntro');
  });
}
