import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/pages/general_appearance_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/general_settings_page.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers/stub_settings_notifier.dart';

///  守卫④：可达性语义缺口审计（快照驱动，不凭感觉加 Semantics）。
///
/// 先用 SemanticsTree 出清单，再只修「真有问题」的项。本用例做两件事：
/// 1. 把若干真实页面的语义树 dump 到
///    `test_screenshots/night-2026-09-21/t06_semantics_audit.txt`（人工评审）；
/// 2. 断言「**不存在**只带 button 角色却既无 label 又无 tooltip 的节点」——
///    这就是清单上最硬的一类（纯图标按钮读屏器只能读「button N」）。
///
/// 浮层角色：另断言弹窗打开后语义树里存在 `scopesRoute` 路由节点
/// （读屏器据此播报「对话框」角色）。
///
/// 只审查、不做大范围包 `Semantics`；修的是 dump 里实际为空名的节点。
void main() {
  const outDir = 'test_screenshots/night-2026-09-21';
  final dumps = <String>[];

  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  tearDownAll(() {
    final dir = Directory(outDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    File('$outDir/t06_semantics_audit.txt').writeAsStringSync(
      'T06 语义缺口审计（SemanticsTree dump）\n'
      '生成方式：flutter test test/core/theme/t06_semantics_audit_test.dart\n'
      '${'=' * 72}\n\n${dumps.join('\n\n')}',
    );
  });

  testWidgets('外观设置页：无空名按钮节点', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpSettings(tester, const GeneralAppearanceSettingsPage());
    await _audit(tester, 'GeneralAppearanceSettingsPage', dumps);
    handle.dispose();
  });

  testWidgets('通用设置页：无空名按钮节点', (tester) async {
    final handle = tester.ensureSemantics();
    await _pumpSettings(tester, const GeneralSettingsPage());
    await _audit(tester, 'GeneralSettingsPage', dumps);
    handle.dispose();
  });

  testWidgets('纯图标按钮样本：无空名按钮节点', (tester) async {
    final handle = tester.ensureSemantics();
    final theme = ThemeCatalog.assemble(
      const LmAppearance(), // classic + classic = 默认组合
      Brightness.light,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          appBar: AppBar(
            title: const Text('语义样本'),
            leading: IconButton(
              icon: const Icon(Icons.menu),
              onPressed: () {},
              tooltip: '菜单',
            ),
            actions: [
              IconButton(
                icon: const Icon(Icons.more_vert),
                onPressed: () {},
                tooltip: '更多',
              ),
            ],
          ),
          body: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: const Text('资源库'),
                subtitle: const Text('本地文件'),
                onTap: () {},
              ),
              const Chip(label: Text('标签')),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _audit(tester, 'IconButton sample', dumps);
    handle.dispose();
  });

  testWidgets('浮层角色：弹窗打开后存在 scopesRoute 路由节点', (tester) async {
    final handle = tester.ensureSemantics();
    final theme = ThemeCatalog.assemble(
      const LmAppearance(), // classic + classic = 默认组合
      Brightness.light,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                key: const ValueKey('open'),
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => const AlertDialog(title: Text('对话框')),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();

    final root =
        // ignore: deprecated_member_use
        tester.binding.pipelineOwner.semanticsOwner!.rootSemanticsNode!;
    var routeNodes = 0;
    void visit(SemanticsNode node) {
      final data = node.getSemanticsData();
      if (data.flagsCollection.scopesRoute) routeNodes++;
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    visit(root);
    expect(
      routeNodes,
      greaterThan(0),
      reason: '弹窗必须暴露路由语义节点，读屏器才能播报「对话框」角色',
    );
    handle.dispose();
  });
}

Future<void> _pumpSettings(WidgetTester tester, Widget page) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = Preferences(prefs: await SharedPreferences.getInstance());
  final theme = ThemeCatalog.assemble(
    const LmAppearance(), // classic + classic = 默认组合
    Brightness.light,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        settingsRepositoryProvider.overrideWithValue(_StubSettingsRepository()),
        apiPresetRepositoryProvider.overrideWithValue(
          _StubApiPresetRepository(),
        ),
        settingsNotifierProvider.overrideWith((ref) => StubSettingsNotifier()),
        configLevelProvider.overrideWith(
          (ref) => ConfigLevelNotifier(prefs, initialValue: ConfigLevel.simple),
        ),
        preferencesProvider.overrideWithValue(prefs),
      ],
      child: TranslationProvider(
        child: MaterialApp(theme: theme, home: page),
      ),
    ),
  );
  await tester.pump();
  for (final ms in const [100, 300, 600]) {
    await tester.pump(Duration(milliseconds: ms));
  }
}

/// 遍历语义树：收集空名按钮、dump 全文。
Future<void> _audit(
  WidgetTester tester,
  String title,
  List<String> dumps,
) async {
  final root =
      // ignore: deprecated_member_use
      tester.binding.pipelineOwner.semanticsOwner?.rootSemanticsNode;
  expect(
    root,
    isNotNull,
    reason: '$title 未取到语义树（ensureSemantics 未生效）——审计会变成空跑，必须修夹具',
  );

  final empties = <String>[];
  final roleless = <String>[];
  final lines = <String>[];
  void visit(SemanticsNode node, int depth) {
    final data = node.getSemanticsData();
    final flags = data.flagsCollection;
    final role = flags.isButton
        ? 'button'
        : flags.isTextField
            ? 'textField'
            : flags.isHeader
                ? 'header'
                : flags.isImage
                    ? 'image'
                    : flags.isLink
                        ? 'link'
                        : flags.isSlider
                            ? 'slider'
                            : '-';
    final label = data.label.trim();
    final tooltip = data.tooltip.trim();
    final labelText = label.isEmpty ? '∅' : label;
    final tooltipText = tooltip.isEmpty ? '∅' : tooltip;
    final tappable = data.hasAction(SemanticsAction.tap);
    final focusable = data.hasAction(SemanticsAction.focus);
    final selected = flags.isSelected == Tristate.none
        ? ''
        : ' isSelected=${flags.isSelected.name}';
    lines.add(
      '${'  ' * depth}[$role${tappable ? '+tap' : ''}${focusable ? '+focus' : ''}$selected] '
      'label="$labelText" tooltip="$tooltipText" '
      'rect=${node.rect.width.toStringAsFixed(0)}x${node.rect.height.toStringAsFixed(0)}',
    );
    if (flags.isButton && label.isEmpty && tooltip.isEmpty) {
      empties.add('rect=${node.rect}');
    }
    // 可点击且有可读名字，却没有任何可交互角色（button / 选项态）——
    // 读屏器只会把它当静态文本，用户不知道「能点」。
    if (tappable &&
        label.isNotEmpty &&
        role == '-' &&
        flags.isSelected == Tristate.none) {
      roleless.add('"$label" rect=${node.rect}');
    }
    node.visitChildren((child) {
      visit(child, depth + 1);
      return true;
    });
  }

  visit(root!, 0);
  dumps.add('### $title\n${lines.join('\n')}');

  expect(
    empties,
    isEmpty,
    reason: '$title 存在只有 button 角色、无 label 也无 tooltip 的语义节点（读屏器只能读「button N」）：'
        '\n${empties.join('\n')}',
  );
  expect(
    roleless,
    isEmpty,
    reason: '$title 存在「可点击但无交互角色」的语义节点（读屏器当静态文本，用户不知道能点）：'
        '\n${roleless.join('\n')}',
  );
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
