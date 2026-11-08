import 'package:flutter_test/flutter_test.dart';

import 'demo_candidate_journey_harness.dart';

/// 真实页面长链·默认 GLM（zhipu 流式画像；多候选基线）。
/// 本文件只跑一条旅程——rootBundle 缓存命中的 SynchronousFuture 在同
/// 进程第二个 testWidgets 的 FakeAsync 区会停滞（实测复现），候选长链
/// 按「一文件一进程一旅程」组织，见 demo_candidate_journey_harness.dart。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('全链·默认GLM：邀请→选模→发送→记忆→交接→正式库可查', (tester) async {
    final env = journeySetUp();
    addTearDown(() => journeyTearDown(env.tmpDir, env.realDb));
    await runCandidateJourney(
      tester,
      JourneySpec.glm53,
      tmpDir: env.tmpDir,
      demoFile: env.demoFile,
      realDb: env.realDb,
      realPrefs: env.realPrefs,
    );
  });
}
