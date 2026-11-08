import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/demo/data/demo_tool_fingerprint.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';
import 'package:lmstory/features/demo/domain/demo_pack_fingerprint.dart';
import 'package:lmstory/features/templates/data/repositories/template_repository_impl.dart';

/// 仓库内全部数据包（assets/demo/first_launch/**.json，含多仿真候选
/// 子目录）对当前源码的有效性对账：结构 + promptHash + toolFingerprint +
/// builtin 模板 content 哈希。catalog.json 是候选目录不是数据包，跳过。
///
/// 这是采集侧替换正式包后的第一道门禁（另一道为应用内
/// DemoPackLoader 加载期复核）。
void main() {
  final dir = Directory('assets/demo/first_launch');
  final files = dir.existsSync()
      ? dir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .where((f) => !f.path.endsWith('catalog.json'))
          .toList()
      : <File>[];

  test('数据包目录非空（至少存在样本包）', () {
    expect(files, isNotEmpty, reason: 'assets/demo/first_launch 应含至少一个包');
  });

  for (final file in files) {
    group('包 ${file.path}', () {
      late DemoPack pack;
      late AppDatabase db;

      setUpAll(() async {
        final decoded = jsonDecode(file.readAsStringSync());
        pack = DemoPack.parse(decoded as Map<String, dynamic>);
        db = AppDatabase.forTesting(NativeDatabase.memory());
        await TemplateRepositoryImpl(db).ensureBuiltInTemplates();
      });

      tearDownAll(() => db.close());

      test('manifest 哈希对账当前源码', () async {
        expect(
          pack.manifest.promptHash,
          demoContentHash(pack.prompt),
          reason: 'promptHash 与包内 prompt 不符',
        );
        expect(
          pack.manifest.toolFingerprint,
          computeDemoToolFingerprint(),
          reason: '工具 schema 已变化——包需按当前源码重采或重算指纹',
        );
        final tpl = await TemplateRepositoryImpl(
          db,
        ).getTemplate(pack.manifest.templateId);
        expect(tpl, isNotNull, reason: '模板 ${pack.manifest.templateId} 缺失');
        expect(
          pack.manifest.templateHash,
          demoContentHash(tpl.content),
          reason: '内置模板内容已变化——包需重采',
        );
      });

      test('数据包必须显式标注合法 kind（sample 或 official）', () {
        expect(
          pack.manifest.kind,
          isIn(['sample', 'official']),
          reason: '数据包必须为 sample 或由正式采集产出的 official',
        );
      });

      test('期望断言自洽（正文包含样本 prose、实体在工具调用参数中）', () {
        // 双通道收集工具调用参数：stream 事件 + chat toolCalls
        final toolArgs = <Map<String, dynamic>>[
          ...pack.streamSteps
              .expand((s) => s.events)
              .where((e) => e['type'] == 'tool_call_complete')
              .map((e) => e['arguments'] as Map<String, dynamic>),
          ...pack.chatEntries
              .map((c) => c.response['toolCalls'])
              .whereType<List<dynamic>>()
              .expand((calls) => calls)
              .map(
                (tc) => Map<String, dynamic>.from(
                  (tc as Map)['arguments'] as Map,
                ),
              ),
        ];
        final proseArgs = toolArgs
            .where((a) => a.containsKey('prose'))
            .map((a) => a['prose'] as String)
            .join('\n');
        for (final needle in pack.expectations.proseContains) {
          expect(proseArgs, contains(needle), reason: '期望正文子串未出现在 prose');
        }

        final createdNames = toolArgs
            .where((a) => a['deltas'] is List)
            .expand((a) => a['deltas'] as List)
            .map((d) => (d as Map<String, dynamic>)['primary_name'])
            .whereType<String>()
            .toSet();
        for (final name in pack.expectations.entityNames) {
          expect(createdNames, contains(name), reason: '期望实体未由工具调用创建');
        }
      });
    });
  }
}
