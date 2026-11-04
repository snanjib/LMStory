import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_selection_option.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_setting_card.dart';
import 'package:lmstory/core/theme/system/structures/glass/glass_factories.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/pages/general_appearance_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/general_settings_page.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers/load_app_fonts.dart';
import '../../test_helpers/stub_settings_notifier.dart';

///  字号缩放报告：textScaler 1.3 / 1.5 / 2.0 三档，检测**溢出**（框架报
/// `A RenderFlex overflowed by N pixels`）与**截断**（`RenderParagraph.
/// didExceedMaxLines`），并给出被截断段落的文本预览以便定位。
///
/// 口径（对齐任务书 a11y 条「textScaler ≥1.3 不破版」）：
/// - 1.3 档为**硬门槛**：任何溢出即失败（P0）。
/// - 1.5 / 2.0 档记录进报告（`test_screenshots/.../t06_text_scaler_report.md`，
///   gitignore），由报告驱动逐条修；修好的项回收进断言。
///
/// 被测面（画布 360×720，最不利于放大的窄屏）：
/// 1. 两个真实设置页（外观 / 通用）——四组合 × 三档；
/// 2. 玻璃工厂文本承载件画廊（药丸/标签/卡片/列表行/输入/横幅/分段）
///    ——四组合 × 明暗 × 三档；
/// 3. 经典侧文本承载件（四类按钮 + 设置卡 + 选项行）——四组合 × 三档；
/// 4. 真实 `showDialog` 弹窗（标题 + 长正文 + 双动作）——四组合 × 三档
///    （对话框是字号放大最易破版的场景）。
void main() {
  const outDir = 'test_screenshots/night-2026-09-21';
  const scalers = <double>[1.3, 1.5, 2];
  const combos = <(String, String, String)>[
    ('classic_classic', 'classic', 'classic'),
    ('classic_bordeaux', 'classic', 'bordeaux'),
    ('glass_classic', 'glass', 'classic'),
    ('glass_bordeaux', 'glass', 'bordeaux'),
  ];

  final rows = <_Row>[];

  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
    await loadAppFonts(withSystemCjkFallback: true);
  });

  tearDownAll(() {
    final dir = Directory(outDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    File('$outDir/t06_text_scaler_report.md').writeAsStringSync(
      _renderReport(rows, scalers),
    );
  });

  for (final scaler in scalers) {
    void gate(_Row r) {
      if (scaler == 1.3) {
        expect(
          r.overflows,
          isEmpty,
          reason: '${r.label} @1.3 溢出（≥1.3 不破版为 P0）：\n${r.overflowBrief}',
        );
      }
    }

    testWidgets('设置页 @ textScaler=$scaler：无溢出', (tester) async {
      for (final (name, structure, palette) in combos) {
        for (final page in <(String, Widget)>[
          (
            'GeneralAppearanceSettingsPage',
            const GeneralAppearanceSettingsPage()
          ),
          ('GeneralSettingsPage', const GeneralSettingsPage()),
        ]) {
          await _setNarrowSurface(tester);
          final r = await _measure(
            tester,
            label: '$name :: ${page.$1}',
            brightness: Brightness.light,
            scaler: scaler,
            appearance: LmAppearance(
              structureId: structure,
              paletteId: palette,
            ),
            wrapSettings: true,
            content: (theme) => page.$2,
          );
          rows.add(r);
          gate(r);
        }
      }
    });

    testWidgets('玻璃文本件画廊 @ textScaler=$scaler：无溢出', (tester) async {
      for (final (name, structure, palette) in combos) {
        for (final brightness in Brightness.values) {
          await _setNarrowSurface(tester);
          final r = await _measure(
            tester,
            label: '$name/${brightness.name} :: glassGallery',
            brightness: brightness,
            scaler: scaler,
            appearance: LmAppearance(
              structureId: structure,
              paletteId: palette,
            ),
            content: (_) => const _GlassGallery(),
          );
          rows.add(r);
          gate(r);
        }
      }
    });

    testWidgets('经典文本件画廊 @ textScaler=$scaler：无溢出', (tester) async {
      for (final (name, structure, palette) in combos) {
        await _setNarrowSurface(tester);
        final r = await _measure(
          tester,
          label: '$name :: classicGallery',
          brightness: Brightness.light,
          scaler: scaler,
          appearance: LmAppearance(
            structureId: structure,
            paletteId: palette,
          ),
          content: (_) => const _ClassicGallery(),
        );
        rows.add(r);
        gate(r);
      }
    });

    testWidgets('弹窗 @ textScaler=$scaler：无溢出', (tester) async {
      for (final (name, structure, palette) in combos) {
        await _setNarrowSurface(tester);
        final r = await _measure(
          tester,
          label: '$name :: dialog',
          brightness: Brightness.light,
          scaler: scaler,
          appearance: LmAppearance(
            structureId: structure,
            paletteId: palette,
          ),
          content: (_) => const _DialogHost(),
          shell: false,
          act: (tester) async {
            await tester.tap(find.byKey(const ValueKey('open-dialog')));
            await tester.pump();
          },
        );
        rows.add(r);
        gate(r);
      }
    });
  }
}

/// 单次测量的结果行。
class _Row {
  _Row({
    required this.label,
    required this.scaler,
    required this.overflows,
    required this.truncated,
    required this.paintedTexts,
  });

  final String label;
  final double scaler;
  final List<String> overflows;
  final List<String> truncated;
  final int paintedTexts;

  String get overflowBrief =>
      overflows.isEmpty ? '—' : overflows.take(3).join(' / ');
}

Future<void> _setNarrowSurface(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(360, 720);
  addTearDown(tester.view.reset);
}

/// pump 一次并收集框架报出的溢出，同时统计被 maxLines 截断的段落。
Future<_Row> _measure(
  WidgetTester tester, {
  required String label,
  required Brightness brightness,
  required double scaler,
  required Widget Function(ThemeData theme) content,
  required LmAppearance appearance,
  bool wrapSettings = false,
  bool shell = true,
  Future<void> Function(WidgetTester tester)? act,
}) async {
  final theme = ThemeCatalog.assemble(appearance, brightness);
  SharedPreferences.setMockInitialValues({});
  final prefs = Preferences(prefs: await SharedPreferences.getInstance());
  // 先清空旧树：否则上一轮的对话框路由会留在同一个 Navigator 里，
  // 后续 tap 打在 barrier 上（且测到的是旧状态）。
  await tester.pumpWidget(const SizedBox.shrink());
  final errors = <String>[];
  final prev = FlutterError.onError;
  FlutterError.onError = (details) {
    final text = details.exceptionAsString();
    errors.add(
      text.contains('overflowed by')
          ? _firstLine(text)
          : 'OTHER: ${_firstLine(text)}',
    );
  };
  try {
    final child = content(theme);
    final app = MaterialApp(
      theme: theme,
      home: MediaQuery(
        data: const MediaQueryData().copyWith(
          textScaler: TextScaler.linear(scaler),
          size: const Size(360, 720),
        ),
        child: wrapSettings ? child : (shell ? _galleryShell(child) : child),
      ),
    );
    await tester.pumpWidget(
      wrapSettings
          ? ProviderScope(
              overrides: <Override>[
                settingsRepositoryProvider
                    .overrideWithValue(_StubSettingsRepository()),
                apiPresetRepositoryProvider
                    .overrideWithValue(_StubApiPresetRepository()),
                settingsNotifierProvider
                    .overrideWith((ref) => StubSettingsNotifier()),
                configLevelProvider.overrideWith(
                  (ref) => ConfigLevelNotifier(
                    prefs,
                    initialValue: ConfigLevel.simple,
                  ),
                ),
                preferencesProvider.overrideWithValue(prefs),
              ],
              child: TranslationProvider(child: app),
            )
          : app,
    );
    await tester.pump();
    for (final ms in const [80, 320, 800]) {
      await tester.pump(Duration(milliseconds: ms));
    }
    if (act != null) {
      await act(tester);
      for (final ms in const [120, 600, 900]) {
        await tester.pump(Duration(milliseconds: ms));
      }
    }
  } finally {
    FlutterError.onError = prev;
  }

  final truncated = <String>[];
  var painted = 0;
  for (final ro in tester.allRenderObjects) {
    if (ro is RenderParagraph) {
      painted++;
      if (ro.didExceedMaxLines) {
        final plain = ro.text.toPlainText().replaceAll('\n', ' ');
        truncated.add(
          plain.length > 26 ? '${plain.substring(0, 26)}…' : plain,
        );
      }
    }
  }

  return _Row(
    label: label,
    scaler: scaler,
    overflows: errors,
    truncated: truncated,
    paintedTexts: painted,
  );
}

Widget _galleryShell(Widget gallery) => Scaffold(
      body: SingleChildScrollView(child: gallery),
    );

String _firstLine(String s) => s.split('\n').first.trim();

String _renderReport(List<_Row> rows, List<double> scalers) {
  final out = <String>[
    '# T06-6 字号缩放（textScaler）三档报告',
    '',
    '生成：`flutter test test/core/theme/t06_text_scaler_report_test.dart`',
    '画布：360×720（窄屏，最不利于放大的分辨率）',
    '',
    '- **溢出** = 框架报 `A RenderFlex overflowed by N pixels`（真破版）。',
    '- **截断** = `RenderParagraph.didExceedMaxLines` 为真（走 ellipsis/maxLines，多为设计意图，单列不判失败）。',
    '- 门槛：**1.3 档溢出必须为 0**（P0）；1.5 / 2.0 档记录待修。',
    '',
    '| 档位 | 被测面 | 溢出 | 截断 | 绘制文本 | 溢出明细 |',
    '|---|---|---|---|---|---|',
  ];
  for (final r in rows) {
    out.add(
      '| ${r.scaler} | ${r.label} | ${r.overflows.length} | '
      '${r.truncated.length} | ${r.paintedTexts} | ${r.overflowBrief} |',
    );
  }
  out.addAll(<String>['', '## 截断段落明细（非失败项，仅记录）', '']);
  if (rows.every((r) => r.truncated.isEmpty)) {
    out.add('- 无。');
  } else {
    for (final r in rows) {
      if (r.truncated.isEmpty) continue;
      out.add('- ${r.scaler} · ${r.label}：${r.truncated.join(' | ')}');
    }
  }
  for (final s in scalers) {
    final slice = rows.where((r) => r.scaler == s).toList();
    final bad = slice.where((r) => r.overflows.isNotEmpty).toList();
    out.addAll(<String>[
      '',
      '## 档位 $s 小结',
      '',
      '- 被测面 ${slice.length} 个，破版 ${bad.length} 个。',
    ]);
    if (bad.isEmpty) {
      out.add('- 无溢出。');
    } else {
      for (final r in bad) {
        out.add(
          '- ❌ ${r.label}：${r.overflows.length} 处 —— ${r.overflowBrief}',
        );
      }
    }
  }
  return '${out.join('\n')}\n';
}

/// 玻璃工厂里「承载文本」的七个件，全部塞长文本放大压力。
class _GlassGallery extends StatelessWidget {
  const _GlassGallery();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GlassPillButton(
            label: '确认并继续（较长按钮文案）',
            onPressed: () {},
          ),
          const SizedBox(height: 12),
          const Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              GlassChip(label: '已选中的长标签文案'),
              GlassChip(label: '未选中标签'),
            ],
          ),
          const SizedBox(height: 12),
          const GlassCard(
            child: Text('卡片标题行文案，用于观察放大后是否挤压相邻元素'),
          ),
          const SizedBox(height: 12),
          const GlassListRow(
            child: Text('列表行内容文案，尾部通常还有次要说明文字'),
          ),
          const SizedBox(height: 12),
          const GlassInput(
            hint: '输入框提示文案（较长的一段占位说明）',
            child: Text('输入内容'),
          ),
          const SizedBox(height: 12),
          const GlassBanner(
            message: '横幅提示文案：这里是一段相对较长的说明文字，用于观察换行与挤压',
            tone: GlassBannerTone.info,
          ),
          const SizedBox(height: 12),
          GlassSegmented<_DemoSeg>(
            values: _DemoSeg.values,
            selected: _DemoSeg.one,
            onSelected: (_) {},
            labelOf: (v) => v.label,
          ),
        ],
      ),
    );
  }
}

/// 经典侧四个按钮度量 + 设置卡 + 选项行（度量在放大字号下的复核）。
class _ClassicGallery extends StatelessWidget {
  const _ClassicGallery();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton(
            onPressed: () {},
            child: const Text('主要动作按钮（较长文案）'),
          ),
          const SizedBox(height: 8),
          ElevatedButton(onPressed: () {}, child: const Text('次要动作按钮')),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: () {}, child: const Text('描边按钮')),
          const SizedBox(height: 8),
          TextButton(onPressed: () {}, child: const Text('文字按钮')),
          const SizedBox(height: 12),
          SimpleSettingCard(
            icon: Icons.tune,
            title: '设置卡标题文案，可能较长',
            subtitle: '副标题说明文字，用于观察两行截断与右侧箭头是否被挤压',
            onTap: () {},
          ),
          const SizedBox(height: 12),
          SimpleSelectionOption(
            label: '选项行标签文案',
            isSelected: true,
            onTap: () {},
          ),
          const SizedBox(height: 4),
          SimpleSelectionOption(
            label: '禁用的选项行文案',
            isSelected: false,
            isEnabled: false,
            disabledLabel: '暂不可用',
            onTap: () {},
          ),
        ],
      ),
    );
  }
}

/// 触发一个真实 `showDialog`（对话框是字号放大最易破版的场景）。
class _DialogHost extends StatelessWidget {
  const _DialogHost();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: FilledButton(
          key: const ValueKey('open-dialog'),
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => AlertDialog(
              title: const Text('确认删除这条会话吗'),
              content: const Text(
                '删除后本会话及其全部消息将不可恢复。如果你只是想暂时收起它，'
                '可以改为归档；归档后的会话仍可在归档区找回。',
              ),
              actions: [
                TextButton(onPressed: () {}, child: const Text('取消')),
                FilledButton(onPressed: () {}, child: const Text('删除')),
              ],
            ),
          ),
          child: const Text('打开'),
        ),
      ),
    );
  }
}

enum _DemoSeg {
  one('第一段'),
  two('第二段'),
  three('第三段');

  const _DemoSeg(this.label);
  final String label;
}

class _StubSettingsRepository implements SettingsRepository {
  @override
  Future<Map<String, dynamic>> getUserOverrides() async => const {};

  @override
  Future<String?> getApiKey(String presetId) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubApiPresetRepository implements ApiPresetRepository {
  @override
  Future<List<ApiPreset>> getAllPresets() async => const [];

  @override
  Future<int> getCustomPresetCount() async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}
