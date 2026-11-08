import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/demo/data/demo_state_store.dart';

void main() {
  late Directory tmpDir;
  late DemoStateStore store;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('lmstory_demo_state');
    store = DemoStateStore(directory: tmpDir);
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  test('roundtrip：全部字段持久与恢复', () async {
    const state = DemoState(
      inviteStatus: DemoInviteStatus.accepted,
      phase: DemoPhase.running,
      runId: 'run-1',
      sessionId: 'sess-1',
      stepId: 'sessionInput',
      packContentVersion: 'sample-1',
    );
    await store.save(state);
    final loaded = await store.load();
    expect(loaded.inviteStatus, DemoInviteStatus.accepted);
    expect(loaded.phase, DemoPhase.running);
    expect(loaded.runId, 'run-1');
    expect(loaded.sessionId, 'sess-1');
    expect(loaded.stepId, 'sessionInput');
    expect(loaded.localeTag, 'zh-CN');
    expect(loaded.packContentVersion, 'sample-1');
  });

  test('无文件 → idle 全新状态', () async {
    final loaded = await store.load();
    expect(loaded.phase, DemoPhase.idle);
    expect(loaded.inviteStatus, DemoInviteStatus.pending);
  });

  test('损坏文件 → idle + .corrupt 备份', () async {
    File('${tmpDir.path}/state.json').writeAsStringSync('not-json{{{');
    final loaded = await store.load();
    expect(loaded.phase, DemoPhase.idle);
    expect(
      File('${tmpDir.path}/state.json.corrupt').existsSync(),
      isTrue,
      reason: '损坏文件应保留现场供诊断',
    );
    expect(File('${tmpDir.path}/state.json').existsSync(), isFalse);
  });

  test('原子写：写入后无 .tmp 残留', () async {
    await store.save(const DemoState(phase: DemoPhase.invited));
    expect(File('${tmpDir.path}/state.json.tmp').existsSync(), isFalse);
    expect(File('${tmpDir.path}/state.json').existsSync(), isTrue);
  });

  test('delete 清全部衍生文件', () async {
    await store.save(const DemoState());
    File('${tmpDir.path}/state.json.corrupt').writeAsStringSync('x');
    await store.delete();
    expect(File('${tmpDir.path}/state.json').existsSync(), isFalse);
    expect(File('${tmpDir.path}/state.json.corrupt').existsSync(), isFalse);
  });

  test('copyWith clearSessionId 语义', () {
    const base = DemoState(sessionId: 's1');
    expect(base.copyWith(stepId: 'x').sessionId, 's1');
    expect(base.copyWith(clearSessionId: true).sessionId, isNull);
  });
}
