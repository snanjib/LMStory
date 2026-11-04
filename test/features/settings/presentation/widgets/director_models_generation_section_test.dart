import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/config/intermediate_config.dart'
    show SuggestReplyConfig;
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/director_models_generation_section.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 导演设置·模型与生成区「推荐回复轻量组」候选数量/单条字数入口测试
///（收口：08-29 审查 ——candidate_count/
/// max_reply_length 配置键存在但全仓无 UI 入口）。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  /// harness 缺省进阶模式：既有用例 = 「进阶=现状全量」回归组；
  /// 配置显示模式过滤组显式传 level 验证双态。
  Future<_RecorderRepo> pumpSection(
    WidgetTester tester, {
    AdvancedConfig config = const AdvancedConfig(),
    ConfigLevel level = ConfigLevel.advanced,
  }) async {
    SharedPreferences.setMockInitialValues({
      if (level == ConfigLevel.advanced)
        ConfigLevelNotifier.prefKey: 'advanced',
    });
    final prefs = Preferences(prefs: await SharedPreferences.getInstance());
    final repo = _RecorderRepo();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          advancedConfigProvider.overrideWith((ref) async => config),
          settingsRepositoryProvider.overrideWithValue(repo),
          configLevelProvider.overrideWith(
            (ref) => ConfigLevelNotifier(prefs, initialValue: level),
          ),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme:
                ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
            home: const Scaffold(
              body: SingleChildScrollView(
                child: DirectorModelsGenerationSection(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    return repo;
  }

  testWidgets('渲染候选数量与单条最大字数两行（默认 3 / 150）', (tester) async {
    await pumpSection(tester);

    expect(find.text('候选数量'), findsOneWidget);
    expect(find.text('单条最大字数'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('150'), findsOneWidget);
  });

  testWidgets('渲染会话配置的自定义值（2 / 100）', (tester) async {
    await pumpSection(
      tester,
      config: const AdvancedConfig(
        suggestReply: SuggestReplyConfig(
          candidateCount: 2,
          maxReplyLength: 100,
        ),
      ),
    );

    expect(find.text('2'), findsOneWidget);
    expect(find.text('100'), findsOneWidget);
  });

  testWidgets('点 + 步进候选数量 → 写 advanced.suggest_reply.candidate_count',
      (tester) async {
    final repo = await pumpSection(tester);

    // 页面仅两处 + 步进（候选数量在前、单条字数在后），first 即候选数量
    final addBtn = find.byIcon(Icons.add, skipOffstage: false).first;
    await tester.ensureVisible(addBtn);
    await tester.pump();
    await tester.tap(addBtn);
    await tester.pump();

    expect(repo.setKeys, contains('advanced.suggest_reply.candidate_count'));
    final idx = repo.setKeys.indexOf('advanced.suggest_reply.candidate_count');
    expect(repo.setValues[idx], 4);
  });

  testWidgets('点 − 步进单条最大字数 → 写 advanced.suggest_reply.max_reply_length',
      (tester) async {
    final repo = await pumpSection(tester);

    final removeBtn = find.byIcon(Icons.remove, skipOffstage: false).last;
    await tester.ensureVisible(removeBtn);
    await tester.pump();
    await tester.tap(removeBtn);
    await tester.pump();

    expect(
      repo.setKeys,
      contains('advanced.suggest_reply.max_reply_length'),
    );
    final idx = repo.setKeys.indexOf('advanced.suggest_reply.max_reply_length');
    expect(repo.setValues[idx], 149);
  });
}

/// 记录 setUserOverride 调用的 stub。
class _RecorderRepo implements SettingsRepository {
  final List<String> setKeys = [];
  final List<dynamic> setValues = [];

  @override
  Future<void> setUserOverride(String key, dynamic value) async {
    setKeys.add(key);
    setValues.add(value);
  }

  @override
  Future<void> removeUserOverride(String key) async {}

  @override
  Future<AppConfig> getResolvedConfig() async => const AppConfig(
        version: '0.1',
        broadcastChat: BroadcastChatConfig(),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
