import 'package:flutter_test/flutter_test.dart';

import 'demo_candidate_journey_harness.dart';

/// 真实页面长链·GLM-Flash（zhipu 流式画像 + 零实体，包真实形态）：
/// 向导真实 sheet 选定 → 亲自发送 → 回放与真实工具链 → 记忆引导走经历分区
/// → 交接不虚构事实实体。一文件一进程一旅程（缓存命中停滞规避）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('全链·GLM-Flash零实体保守档：经历分区引导→交接不虚构实体', (tester) async {
    final env = journeySetUp();
    addTearDown(() => journeyTearDown(env.tmpDir, env.realDb));
    await runCandidateJourney(
      tester,
      JourneySpec.glmFlash,
      tmpDir: env.tmpDir,
      demoFile: env.demoFile,
      realDb: env.realDb,
      realPrefs: env.realPrefs,
    );
  });
}
