import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'durable_surface_opening_scenario.dart';
import 'durable_surface_wire_scenario.dart';

/// 金标准生成器（维护工具，日常测试跳过）：
///
/// `flutter test --dart-define=LMSTORY_GEN_GOLDENS=true <本文件>` 重写
/// `goldens/` 下两个面的请求体：
/// - `opening_mode_<protocol>.json`：开启态投影面（账本投影→wire），
///   以本树生成后锁定，防开启态出站形状回退。
/// - `closed_mode_<protocol>.json`：关闭态代表性请求体。
///   协议修复时提交受影响的快照。
///
/// 原理与范围见 `doc/experiments/director_durable_surface/review_f42a3855/07_FIX-F_执行记录.md`。
Future<void> main() async {
  const generate = bool.fromEnvironment('LMSTORY_GEN_GOLDENS');
  if (!generate) {
    return;
  }
  test('生成 durable surface wire 金标准（LMSTORY_GEN_GOLDENS=true 时）', () async {
    final goldensDir = Directory('test/core/network/llm_adapters/goldens');
    if (!goldensDir.existsSync()) goldensDir.createSync(recursive: true);

    // ── 关闭态：共享场景（与基线提取树同一场景文件） ──────────────
    for (final p in kScenarioProtocols) {
      File(
        'test/core/network/llm_adapters/goldens/closed_mode_${p.name}.json',
      ).writeAsStringSync(scenarioBodyJson(p));
    }

    // ── 开启态：真实账本投影面 → wire ────────────────────────────
    for (final p in kScenarioProtocols) {
      File(
        'test/core/network/llm_adapters/goldens/opening_mode_${p.name}.json',
      ).writeAsStringSync(await openingScenarioBodyJson(p));
    }
  });
}
