import 'package:flutter_test/flutter_test.dart';

import 'demo_candidate_journey_harness.dart';

/// 真实页面长链·DeepSeek（deepseek 流式画像，非默认候选异画像）：
/// 向导真实 sheet 选定 → 亲自发送 → 异画像回放与真实工具链 → 记忆浏览
/// → 交接串包防线。一文件一进程一旅程（rootBundle 缓存命中停滞规避）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('全链·DeepSeek异画像：选模→发送→记忆→交接全链与串包防线', (tester) async {
    final env = journeySetUp();
    addTearDown(() => journeyTearDown(env.tmpDir, env.realDb));
    await runCandidateJourney(
      tester,
      JourneySpec.deepseek,
      tmpDir: env.tmpDir,
      demoFile: env.demoFile,
      realDb: env.realDb,
      realPrefs: env.realPrefs,
    );
  });
}
