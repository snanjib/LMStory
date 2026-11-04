import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/pages/general_advanced_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/general_appearance_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/general_language_input_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/general_settings_page.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// GeneralSettingsPage Widget 测试（2026-07-19 子页化重构后）
///
/// 顶层 4 张分类卡片（供应商 / 外观 / 语言与输入 / 高级），具体设置在各子页。
/// 测试聚焦"顶层导航 + 子页 AppBar 标题"——section 自身功能由各 section 测试覆盖。

// ── Stub ────────────────────────────────────────────────────────────

class _StubSettingsRepository implements SettingsRepository {
  _StubSettingsRepository({Map<String, dynamic>? overrides})
      : overrides = Map<String, dynamic>.from(overrides ?? const {});

  final Map<String, dynamic> overrides;

  @override
  Future<Map<String, dynamic>> getUserOverrides() async => overrides;

  @override
  Future<String?> getApiKey(String presetId) async => null;

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
  @override
  Future<int> getCustomPresetCount() async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubTemplateRepository implements TemplateRepository {
  @override
  Future<List<Template>> getAllTemplates() async => const [];

  @override
  Future<void> ensureBuiltInTemplates() async {}

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
    ],
  ),
];

// ── 测试 helper ─────────────────────────────────────────────────────

Future<void> _pumpTopPage(
  WidgetTester tester, {
  List<ApiPreset> presets = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(_StubSettingsRepository()),
        apiPresetRepositoryProvider.overrideWithValue(
          _StubApiPresetRepository(presets),
        ),
        templateRepositoryProvider.overrideWithValue(_StubTemplateRepository()),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: const GeneralSettingsPage(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpSubPage<T extends Widget>(
  WidgetTester tester, {
  required T Function() pageBuilder,
}) async {
  // harness 缺省进阶模式：既有子页用例 = 「进阶=现状全量」回归组。
  SharedPreferences.setMockInitialValues({
    ConfigLevelNotifier.prefKey: 'advanced',
  });
  final configPrefs = Preferences(
    prefs: await SharedPreferences.getInstance(),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(_StubSettingsRepository()),
        apiPresetRepositoryProvider.overrideWithValue(
          _StubApiPresetRepository(const []),
        ),
        templateRepositoryProvider.overrideWithValue(_StubTemplateRepository()),
        configLevelProvider.overrideWith(
          (ref) => ConfigLevelNotifier(
            configPrefs,
            initialValue: ConfigLevel.advanced,
          ),
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

  group('GeneralSettingsPage - 顶层分类卡片', () {
    testWidgets('1. AppBar 标题：通用设置', (tester) async {
      await _pumpTopPage(tester, presets: _testPresets);

      expect(find.byType(AppBar), findsOneWidget);
      expect(find.text('通用设置'), findsOneWidget);
    });

    testWidgets('2. 4 个分类卡片全部显示（模型提供商/外观/语言与输入/高级）', (tester) async {
      await _pumpTopPage(tester, presets: _testPresets);

      expect(find.text('模型提供商'), findsOneWidget);
      expect(find.text('外观'), findsOneWidget);
      expect(find.text('语言与输入'), findsOneWidget);
      expect(find.text('高级'), findsOneWidget);
    });

    testWidgets('3. 模型提供商卡片副标题显示数量', (tester) async {
      await _pumpTopPage(tester, presets: _testPresets);

      // _testPresets 有 1 个供应商，副标题应为 "1 个供应商"
      expect(find.text('1 个供应商'), findsOneWidget);
    });

    testWidgets('4. 点击"外观"卡片 → 进入外观子页', (tester) async {
      await _pumpTopPage(tester, presets: _testPresets);

      await tester.tap(find.text('外观'));
      await tester.pumpAndSettle();

      expect(
        find.byType(GeneralAppearanceSettingsPage),
        findsOneWidget,
      );
      // 子页 AppBar 标题"外观"
      expect(find.text('外观'), findsOneWidget);
    });

    testWidgets('5. 点击"语言与输入"卡片 → 进入子页', (tester) async {
      await _pumpTopPage(tester, presets: _testPresets);

      await tester.tap(find.text('语言与输入'));
      await tester.pumpAndSettle();

      expect(
        find.byType(GeneralLanguageInputSettingsPage),
        findsOneWidget,
      );
      expect(find.text('语言与输入'), findsOneWidget);
    });

    testWidgets('6. 点击"高级"卡片 → 进入高级子页', (tester) async {
      await _pumpTopPage(tester, presets: _testPresets);

      await tester.tap(find.text('高级'));
      await tester.pumpAndSettle();

      expect(find.byType(GeneralAdvancedSettingsPage), findsOneWidget);
      expect(find.text('高级'), findsOneWidget);
    });
  });

  group('GeneralAppearanceSettingsPage - 子页功能', () {
    testWidgets('7. 渲染主题 + 字体大小两个 section 标题', (tester) async {
      await _pumpSubPage(
        tester,
        pageBuilder: () => const GeneralAppearanceSettingsPage(),
      );

      expect(find.text('主题模式'), findsOneWidget);
      // 结构轴注册第三选项（棱角）后选择器多一行，默认视口下
      // ListView 惰性构建未及末尾——滚入后再断言（断言语义不变）。
      await tester.scrollUntilVisible(
        find.text('字体大小'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('字体大小'), findsOneWidget);
    });
  });

  group('GeneralLanguageInputSettingsPage - 子页功能', () {
    testWidgets('8. 渲染语言 + 发送键两个 section 标题', (tester) async {
      await _pumpSubPage(
        tester,
        pageBuilder: () => const GeneralLanguageInputSettingsPage(),
      );

      expect(find.text('语言'), findsOneWidget);
      expect(find.text('发送键'), findsOneWidget);
    });
  });

  group('GeneralAdvancedSettingsPage - 子页功能', () {
    testWidgets('9. 渲染默认思考预算 + 超时设置两个 section 标题', (tester) async {
      await _pumpSubPage(
        tester,
        pageBuilder: () => const GeneralAdvancedSettingsPage(),
      );

      expect(find.text('默认思考预算'), findsOneWidget);
      expect(find.text('超时设置'), findsOneWidget);
    });
  });
}
