import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/intermediate_setting_card.dart';
import 'package:lmstory/features/intermediate/presentation/intermediate_mode_flag.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_models_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_system_prompt_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_tools_memory_settings_page.dart';
import 'package:lmstory/features/settings/presentation/widgets/intermediate_json_mode_section.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// IntermediateSettingsPage Widget 测试（2026-07-19 子页化重构后）
///
/// 重构后顶层只有 5 个分类卡片，具体设置在各子页。测试分两组：
/// - 顶层：5 个分类卡片 + 点击导航
/// - 子页：模型配置 / 系统提示词 / 工具与记忆（按需单独 pump 子页）
///
/// 旧测试（在顶层页直接查找 section）已废弃，新测试聚焦"顶层导航 +
/// 子页功能"。

// ── Stub ────────────────────────────────────────────────────────────

class _StubSettingsRepository implements SettingsRepository {
  _StubSettingsRepository({Map<String, dynamic>? overrides})
      : overrides = Map<String, dynamic>.from(overrides ?? const {});

  final Map<String, dynamic> overrides;
  final List<String> setKeys = [];
  final List<dynamic> setValues = [];
  final List<String> removedKeys = [];

  String? get lastSetKey => setKeys.isEmpty ? null : setKeys.last;
  dynamic get lastSetValue => setValues.isEmpty ? null : setValues.last;
  String? get lastRemovedKey => removedKeys.isEmpty ? null : removedKeys.last;

  @override
  Future<Map<String, dynamic>> getUserOverrides() async => overrides;

  @override
  Future<void> setUserOverride(String key, dynamic value) async {
    setKeys.add(key);
    setValues.add(value);
    overrides[key] = value;
  }

  @override
  Future<void> removeUserOverride(String key) async {
    removedKeys.add(key);
    overrides.remove(key);
  }

  @override
  Future<AppConfig> getResolvedConfig() async {
    // 2026-07-19 修复：原实现调用 ConfigLoader().load() 会从 assets 加载配置，
    // 在测试环境中可能导致 pumpAndSettle 超时。改为返回 const 默认配置，
    // 测试中 broadcastChat.presetId/modelId 均为空（表示未配置通用聊天默认模型）。
    // intermediate 块由 intermediateConfigProvider.overrideWith 注入，不在此处合并。
    return const AppConfig(
      version: '0.1',
      broadcastChat: BroadcastChatConfig(),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubApiPresetRepository implements ApiPresetRepository {
  _StubApiPresetRepository(this._presets);
  final List<ApiPreset> _presets;

  @override
  Future<List<ApiPreset>> getAllPresets() async => _presets;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

// ── 测试数据 ────────────────────────────────────────────────────────

final _testPresets = [
  ApiPreset(
    presetId: 'openai',
    name: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    createdAt: DateTime(2024),
    updatedAt: DateTime(2024),
    cachedModels: const [
      ModelInfo(modelId: 'gpt-4o', displayName: 'GPT-4o'),
      ModelInfo(modelId: 'gpt-4o-mini', displayName: 'GPT-4o mini'),
    ],
  ),
  ApiPreset(
    presetId: 'deepseek',
    name: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com/v1',
    createdAt: DateTime(2024),
    updatedAt: DateTime(2024),
    cachedModels: const [
      ModelInfo(modelId: 'deepseek-chat'),
    ],
  ),
];

// ── 测试 helper ─────────────────────────────────────────────────────

/// 构造测试 widget 树（顶层 IntermediateSettingsPage）。
///
/// harness 缺省进阶模式：既有用例 = 「进阶=现状全量」回归组；
/// 配置显示模式过滤组显式传 level 验证双态。
Future<ProviderContainer> _pumpTopPage(
  WidgetTester tester, {
  required IntermediateConfig config,
  required _StubSettingsRepository repo,
  List<ApiPreset> presets = const [],
  ConfigLevel level = ConfigLevel.advanced,
}) async {
  SharedPreferences.setMockInitialValues({
    if (level == ConfigLevel.advanced) ConfigLevelNotifier.prefKey: 'advanced',
  });
  final prefs = Preferences(prefs: await SharedPreferences.getInstance());

  final container = ProviderContainer(
    overrides: [
      preferencesProvider.overrideWithValue(prefs),
      intermediateConfigProvider.overrideWith((ref) async => config),
      settingsRepositoryProvider.overrideWithValue(repo),
      apiPresetRepositoryProvider.overrideWithValue(
        _StubApiPresetRepository(presets),
      ),
      configLevelProvider.overrideWith(
        (ref) => ConfigLevelNotifier(prefs, initialValue: level),
      ),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: const IntermediateSettingsPage(),
        ),
      ),
    ),
  );
  // 等 EntryTransition 动画 + config + presets 加载完成
  await tester.pumpAndSettle();
  return container;
}

/// 直接 pump 指定子页（避免顶层导航的复杂度）。
Future<void> _pumpSubPage<T extends Widget>(
  WidgetTester tester, {
  required IntermediateConfig config,
  required _StubSettingsRepository repo,
  required T Function() pageBuilder,
  List<ApiPreset> presets = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        intermediateConfigProvider.overrideWith((ref) async => config),
        settingsRepositoryProvider.overrideWithValue(repo),
        apiPresetRepositoryProvider.overrideWithValue(
          _StubApiPresetRepository(presets),
        ),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: pageBuilder(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  // ── 顶层：5 个分类卡片 + 标题 ────────────────────────────────────
  group('IntermediateSettingsPage - 顶层分类卡片', () {
    testWidgets('1. AppBar 标题：故事模式设置（命名统一）', (tester) async {
      await _pumpTopPage(
        tester,
        config: const IntermediateConfig(),
        repo: _StubSettingsRepository(),
      );

      expect(find.byType(Scaffold), findsOneWidget);
      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('故事模式设置'), findsOneWidget);
    });

    testWidgets('1b. 入口开关卡置顶：恢复入口常显，默认关', (tester) async {
      await _pumpTopPage(
        tester,
        config: const IntermediateConfig(),
        repo: _StubSettingsRepository(),
      );

      expect(find.text('故事模式'), findsOneWidget);
      final toggle = find.byType(Switch);
      expect(toggle, findsOneWidget);
      expect(
        tester.widget<Switch>(toggle).value,
        isFalse,
        reason: '故事模式入口默认隐藏',
      );
    });

    for (final (width, scale) in [(400.0, 1.0), (320.0, 1.5)]) {
      testWidgets('switch row taps toggle once at $width dp ($scale× text)',
          (tester) async {
        tester.view.physicalSize = Size(width, 720);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final container = await _pumpTopPage(
          tester,
          config: const IntermediateConfig(),
          repo: _StubSettingsRepository(),
        );
        addTearDown(container.dispose);

        final toggles = <bool>[];
        container.listen(intermediateModeFlagProvider, (_, value) {
          toggles.add(value);
        });
        await tester.tap(find.text('故事模式'));
        await tester.pumpAndSettle();
        expect(toggles, [true]);

        await tester.tap(find.byIcon(Icons.auto_stories));
        await tester.pumpAndSettle();
        expect(toggles, [true, false]);

        await tester.tap(find.byType(Switch));
        await tester.pumpAndSettle();
        expect(toggles, [true, false, true]);
        expect(
          await IntermediateModeFlagNotifier.readInitial(
            container.read(preferencesProvider),
          ),
          isTrue,
        );
      });
    }

    testWidgets('switch row can be toggled with the keyboard', (tester) async {
      final container = await _pumpTopPage(
        tester,
        config: const IntermediateConfig(),
        repo: _StubSettingsRepository(),
      );
      addTearDown(container.dispose);

      // App bar has no back button on this root route.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    });

    testWidgets('2. 5 个分类卡片全部显示（模型/提示词/工具与记忆/提示词模板/帮助）', (tester) async {
      // 顶部新增入口开关卡后总高度超出默认视口，加高让全部卡片
      // 同时进入懒加载渲染区
      tester.view.physicalSize = const Size(800, 2200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pumpTopPage(
        tester,
        config: const IntermediateConfig(),
        repo: _StubSettingsRepository(),
      );

      // 5 个分类卡片标题
      expect(find.text('模型配置'), findsOneWidget);
      expect(find.text('系统提示词'), findsOneWidget);
      expect(find.text('工具与记忆'), findsOneWidget);
      expect(find.text('提示词模板'), findsOneWidget);
      expect(find.text('使用帮助'), findsOneWidget);
    });

    testWidgets('3. 点击"模型配置"卡片 → 进入模型配置子页', (tester) async {
      await _pumpTopPage(
        tester,
        config: const IntermediateConfig(),
        repo: _StubSettingsRepository(),
        presets: _testPresets,
      );

      // Directly invoke the card callback so this navigation contract does not
      // depend on the host Flutter SDK's Impeller-only InkSparkle shader asset.
      final card = find.widgetWithText(ClassicNarrativeSettingCard, '模型配置');
      final inkWell = find.descendant(of: card, matching: find.byType(InkWell));
      tester.widget<InkWell>(inkWell).onTap!();
      await tester.pumpAndSettle();

      // 进入模型配置子页
      expect(find.byType(IntermediateModelsSettingsPage), findsOneWidget);
      // 子页 AppBar 标题"模型配置"
      expect(find.text('模型配置'), findsOneWidget);
    });

    testWidgets('4. 点击"系统提示词"卡片 → 进入系统提示词子页', (tester) async {
      await _pumpTopPage(
        tester,
        config: const IntermediateConfig(),
        repo: _StubSettingsRepository(),
      );

      final card = find.widgetWithText(ClassicNarrativeSettingCard, '系统提示词');
      final inkWell = find.descendant(of: card, matching: find.byType(InkWell));
      tester.widget<InkWell>(inkWell).onTap!();
      await tester.pumpAndSettle();

      expect(find.byType(IntermediateSystemPromptSettingsPage), findsOneWidget);
    });

    testWidgets('5. 点击"工具与记忆"卡片 → 进入工具与记忆子页', (tester) async {
      await _pumpTopPage(
        tester,
        config: const IntermediateConfig(),
        repo: _StubSettingsRepository(),
      );

      final card = find.widgetWithText(ClassicNarrativeSettingCard, '工具与记忆');
      final inkWell = find.descendant(of: card, matching: find.byType(InkWell));
      tester.widget<InkWell>(inkWell).onTap!();
      await tester.pumpAndSettle();

      expect(
        find.byType(IntermediateToolsMemorySettingsPage),
        findsOneWidget,
      );
      // 工具调用区块可见
      expect(find.byType(IntermediateJsonModeSection), findsOneWidget);
    });
  });

  // ── 配置显示模式过滤（简单模式 7 卡 → 4 卡） ─────────────────────
  group('IntermediateSettingsPage - 配置显示模式过滤', () {
    testWidgets('18. 简单模式：保留模型/系统提示词/生成参数/帮助，其余隐藏', (tester) async {
      await _pumpTopPage(
        tester,
        config: const IntermediateConfig(),
        repo: _StubSettingsRepository(),
        level: ConfigLevel.simple,
      );

      expect(find.text('模型配置'), findsOneWidget);
      expect(find.text('系统提示词'), findsOneWidget);
      expect(find.text('生成参数'), findsOneWidget);
      expect(find.text('使用帮助'), findsOneWidget);
      expect(find.text('工具与记忆'), findsNothing);
      expect(find.text('提示词模板'), findsNothing);
      expect(find.text('推荐回复'), findsNothing);
    });

    testWidgets('19. 简单模式切进阶：provider 更新即时生效（七卡回归）', (tester) async {
      // 同用例 2：加高视口覆盖入口开关卡 + 七张分类卡
      tester.view.physicalSize = const Size(800, 2200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final container = await _pumpTopPage(
        tester,
        config: const IntermediateConfig(),
        repo: _StubSettingsRepository(),
        level: ConfigLevel.simple,
      );

      expect(find.text('工具与记忆'), findsNothing);

      await container
          .read(configLevelProvider.notifier)
          .setLevel(ConfigLevel.advanced);
      await tester.pumpAndSettle();

      expect(find.text('模型配置'), findsOneWidget);
      expect(find.text('系统提示词'), findsOneWidget);
      expect(find.text('工具与记忆'), findsOneWidget);
      expect(find.text('生成参数'), findsOneWidget);
      expect(find.text('提示词模板'), findsOneWidget);
      expect(find.text('推荐回复'), findsOneWidget);
      expect(find.text('使用帮助'), findsOneWidget);
    });
  });

  // ── 系统提示词子页（功能测试从原 #2-#5 迁移） ───────────────────
  group('IntermediateSystemPromptSettingsPage - 系统提示词功能', () {
    testWidgets('6. 配置有 systemPrompt → TextField 回显', (tester) async {
      await _pumpSubPage(
        tester,
        config: const IntermediateConfig(systemPrompt: '你是海盗船长'),
        repo: _StubSettingsRepository(),
        pageBuilder: () => const IntermediateSystemPromptSettingsPage(),
      );

      expect(find.text('你是海盗船长'), findsOneWidget);
    });

    testWidgets('7. 空配置 → hintText 显示内置默认预览', (tester) async {
      await _pumpSubPage(
        tester,
        config: const IntermediateConfig(),
        repo: _StubSettingsRepository(),
        pageBuilder: () => const IntermediateSystemPromptSettingsPage(),
      );

      // 2026-07-19 修订：空配置时 hintText 显示"内置默认：$preview…"，
      // 让用户看到实际生效的内置默认角色设定，而非静态提示文案。
      expect(
        find.textContaining('内置默认：'),
        findsOneWidget,
      );
      // 预览内容应包含 kDefaultRolePrompt 的前缀
      expect(
        find.textContaining('互动故事的第三人称全知叙述者'),
        findsOneWidget,
      );
    });

    testWidgets('8. 输入文本后保存按钮可点 → 写入 repo', (tester) async {
      final repo = _StubSettingsRepository();
      await _pumpSubPage(
        tester,
        config: const IntermediateConfig(),
        repo: repo,
        pageBuilder: () => const IntermediateSystemPromptSettingsPage(),
      );

      // 初始：保存按钮禁用（无改动）
      final saveButton = find.widgetWithText(ElevatedButton, '保存');
      expect(
        tester.widget<ElevatedButton>(saveButton).onPressed,
        isNull,
      );

      // 输入文本
      await tester.enterText(find.byType(TextField), '你是赛博朋克黑客');
      await tester.pumpAndSettle();

      // 保存按钮启用
      expect(
        tester.widget<ElevatedButton>(saveButton).onPressed,
        isNotNull,
      );

      // 点击保存
      await tester.tap(saveButton);
      await tester.pumpAndSettle();

      expect(repo.lastSetKey, 'intermediate.system_prompt');
      expect(repo.lastSetValue, '你是赛博朋克黑客');
      expect(find.text('系统提示词已保存'), findsOneWidget);
    });

    testWidgets('9. 恢复默认 → 确认对话框 → 清除覆盖', (tester) async {
      final repo = _StubSettingsRepository(
        overrides: {'intermediate.system_prompt': '旧设定'},
      );
      await _pumpSubPage(
        tester,
        config: const IntermediateConfig(systemPrompt: '旧设定'),
        repo: repo,
        pageBuilder: () => const IntermediateSystemPromptSettingsPage(),
      );

      // 点击恢复默认
      await tester.tap(find.widgetWithText(TextButton, '恢复默认'));
      await tester.pumpAndSettle();

      // 确认对话框
      expect(
        find.text('确定恢复为内置默认角色设定吗？当前自定义内容将被清除。'),
        findsOneWidget,
      );

      // 确认
      await tester.tap(find.widgetWithText(TextButton, '恢复默认').last);
      await tester.pumpAndSettle();

      expect(repo.lastRemovedKey, 'intermediate.system_prompt');
      expect(find.text('已恢复为默认设定'), findsOneWidget);
    });
  });

  // ── 工具与记忆子页（功能测试从原 #11-#12 迁移） ─────────────────
  group('IntermediateToolsMemorySettingsPage - 工具调用开关', () {
    testWidgets('16. 默认 toolCallingEnabled=true → 开关开启', (tester) async {
      await _pumpSubPage(
        tester,
        config: const IntermediateConfig(),
        repo: _StubSettingsRepository(),
        pageBuilder: () => const IntermediateToolsMemorySettingsPage(),
      );

      // 工具调用区块可能被推到视口外，需滚动到可见
      await tester.scrollUntilVisible(
        find.descendant(
          of: find.byType(IntermediateJsonModeSection),
          matching: find.byType(SwitchListTile),
        ),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      final sw = find.descendant(
        of: find.byType(IntermediateJsonModeSection),
        matching: find.byType(SwitchListTile),
      );
      expect(sw, findsOneWidget);
      expect(tester.widget<SwitchListTile>(sw).value, isTrue);
    });

    testWidgets('17. 关闭开关 → setUserOverride(false)', (tester) async {
      final repo = _StubSettingsRepository();
      await _pumpSubPage(
        tester,
        config: const IntermediateConfig(),
        repo: repo,
        pageBuilder: () => const IntermediateToolsMemorySettingsPage(),
      );

      await tester.scrollUntilVisible(
        find.descendant(
          of: find.byType(IntermediateJsonModeSection),
          matching: find.byType(SwitchListTile),
        ),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.descendant(
          of: find.byType(IntermediateJsonModeSection),
          matching: find.byType(SwitchListTile),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        repo.setKeys,
        contains('intermediate.stream.tool_calling_enabled'),
      );
      final idx =
          repo.setKeys.indexOf('intermediate.stream.tool_calling_enabled');
      expect(repo.setValues[idx], false);
      expect(
        repo.removedKeys,
        isNot(contains('intermediate.stream.tool_calling_enabled')),
      );
    });
  });
}
