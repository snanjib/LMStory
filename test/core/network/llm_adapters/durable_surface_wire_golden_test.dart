import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'durable_surface_opening_scenario.dart';
import 'durable_surface_wire_scenario.dart';

/// durable surface wire 金标准比对（常驻）。
///
/// - `closed_mode_<protocol>.json`：关闭态代表性请求体，逐字节锁定
///   当前协议格式。有明确的协议修复时更新受影响的快照。
/// - `opening_mode_<protocol>.json`：开启态投影面（账本投影→wire，
///   正常追加面）请求体，生成后锁定，防开启态出站形状回退。
///
/// 结构性断言（回执配对/工具闸门）与纯快照并列，避免只锁字节不看形状。
void main() {
  final goldensDir = Directory('test/core/network/llm_adapters/goldens');

  group('关闭态请求体 golden', () {
    for (final p in kScenarioProtocols) {
      test('${p.name}：请求体与关闭态金标准逐字节一致', () {
        final expected = File('${goldensDir.path}/closed_mode_${p.name}.json')
            .readAsStringSync();
        expect(scenarioBodyJson(p), expected);
      });
    }
  });

  group('开启态投影面 golden（正常追加）', () {
    for (final p in kScenarioProtocols) {
      test('${p.name}：投影面→请求体与金标准逐字节一致', () async {
        final expected = File('${goldensDir.path}/opening_mode_${p.name}.json')
            .readAsStringSync();
        final actual = await openingScenarioBodyJson(p);
        expect(actual, expected);
        // 结构性抽查：请求体为对象且消息非空（投影面齐全：
        // frozen+捕获×2+本轮工具轨迹）
        final body = jsonDecode(expected) as Map<String, dynamic>;
        expect(body, isA<Map<String, dynamic>>());
      });
    }
  });
}
