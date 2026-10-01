import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/theme/intermediate/components/intermediate_markdown_body.dart';
import 'package:lmstory/core/theme/intermediate/components/intermediate_setting_card.dart';
import 'package:lmstory/core/theme/simple/components/simple_markdown_body.dart';
import 'package:lmstory/core/theme/simple/components/simple_setting_card.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';

import '../../test_helpers/load_app_fonts.dart';

/// 四组合 × 明暗 渲染基线（外观双轴的组件面快照）。
///
/// 前身 `classic_visual_parity_test.dart` 绑在 `SimpleTheme`（已退役的
/// 旧主题）上，golden 文本还是测试占位字形——基线校验的是错误对象。
/// 本文件迁移到 `ThemeCatalog.assemble`（唯一装配入口），并注册打包
/// 字体让文本有真实字形。夹具文本为英文：无需系统中文字体兜底。
///
/// golden 重录窗口：外观系统层组件配方变化（结构/配色/材质）时按
/// 组合逐张重录，并在提交信息里显式记录原因。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => Directory.systemTemp.path,
    );
    await loadAppFonts();
  });

  const combos = <(String, String)>[
    ('classic', 'classic'),
    ('classic', 'bordeaux'),
    ('glass', 'classic'),
    ('glass', 'bordeaux'),
  ];

  for (final (structureId, paletteId) in combos) {
    for (final brightness in Brightness.values) {
      final brightnessName = brightness == Brightness.light ? 'light' : 'dark';
      testWidgets(
        '$structureId+$paletteId $brightnessName preserves rendered surfaces',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(1000, 900));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeCatalog.assemble(
                LmAppearance(
                  structureId: structureId,
                  paletteId: paletteId,
                ),
                brightness,
              ),
              home: RepaintBoundary(
                key: const ValueKey('surface'),
                child: Scaffold(
                  appBar: AppBar(title: const Text('LMStory')),
                  body: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SimpleSettingCard(
                          icon: Icons.book,
                          title: 'Conversation',
                          subtitle: 'Settings and resources',
                          onTap: () {},
                        ),
                        const SizedBox(height: 16),
                        IntermediateSettingCard(
                          icon: Icons.auto_stories,
                          title: 'Story',
                          subtitle: 'Reading preferences',
                          onTap: () {},
                        ),
                        const SizedBox(height: 16),
                        const SimpleMarkdownBody(
                          data:
                              '## Conversation\nA **strong** voice with [a link](https://example.com).\n\n> A quiet quotation.',
                        ),
                        const IntermediateMarkdownBody(
                          data:
                              'A **story** with *emphasis* and a [reference](https://example.com).',
                          isUser: true,
                        ),
                        const SizedBox(height: 16),
                        const TextField(
                          decoration: InputDecoration(
                            hintText: 'Write a message',
                          ),
                        ),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 12,
                          children: [
                            ElevatedButton(
                              onPressed: () {},
                              child: const Text('Continue'),
                            ),
                            const ElevatedButton(
                              onPressed: null,
                              child: Text('Unavailable'),
                            ),
                            OutlinedButton(
                              onPressed: () {},
                              child: const Text('Details'),
                            ),
                            TextButton(
                              onPressed: () {},
                              child: const Text('Cancel'),
                            ),
                            const Chip(label: Text('Selected')),
                            Switch(value: true, onChanged: (_) {}),
                          ],
                        ),
                        const Divider(),
                        const LinearProgressIndicator(value: 0.4),
                        const Card(
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: Text('Saved conversation'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  bottomNavigationBar: NavigationBar(
                    destinations: const [
                      NavigationDestination(
                        icon: Icon(Icons.chat),
                        label: 'Conversations',
                      ),
                      NavigationDestination(
                        icon: Icon(Icons.settings),
                        label: 'Settings',
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await expectLater(
            find.byKey(const ValueKey('surface')),
            matchesGoldenFile(
              'goldens/parity_${structureId}_${paletteId}_$brightnessName.png',
            ),
          );
        },
      );
    }
  }
}
