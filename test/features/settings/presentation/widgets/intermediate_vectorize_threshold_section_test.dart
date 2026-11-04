import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/widgets/intermediate_vectorize_threshold_section.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// IntermediateVectorizeThresholdSection 测试（2026-08-13 恢复的检索门槛设置）。
///
/// 验证：
/// 1. 默认配置渲染标题 + 两个门槛标签 + 默认值（3 分 / 4 分）
/// 2. 自定义阈值正确显示（如纳入 2 分记忆：两个门槛都调到 2）
void main() {
  Future<void> pumpSection(
    WidgetTester tester, {
    required IntermediateConfig config,
    required SettingsRepository repo,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          intermediateConfigProvider.overrideWith((ref) async => config),
          settingsRepositoryProvider.overrideWithValue(repo),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme:
                ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
            home: const Scaffold(
              body: IntermediateVectorizeThresholdSection(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('1. 默认配置：显示标题与两个门槛（默认 3 / 4 分）', (tester) async {
    await pumpSection(
      tester,
      config: const IntermediateConfig(),
      repo: _StubSettingsRepository(),
    );
    expect(find.textContaining('记忆检索门槛'), findsOneWidget);
    expect(find.text('存储索引门槛'), findsOneWidget);
    expect(find.text('向量化门槛'), findsOneWidget);
    expect(find.textContaining('3 分'), findsOneWidget);
    expect(find.textContaining('4 分'), findsOneWidget);
  });

  testWidgets('2. 自定义阈值（纳入 2 分记忆）：两个门槛都显示 2 分', (tester) async {
    const config = IntermediateConfig(
      retrieval: RetrievalConfig(
        importanceStorageThreshold: 2,
        microVectorizeThreshold: 2,
      ),
    );
    await pumpSection(
      tester,
      config: config,
      repo: _StubSettingsRepository(),
    );
    // 两个门槛都调到 2 分
    expect(find.textContaining('2 分'), findsNWidgets(2));
  });
}

/// 仅记录 setUserOverride 调用的 stub（其他方法按需 noSuchMethod）。
class _StubSettingsRepository implements SettingsRepository {
  final List<String> setKeys = [];
  final List<dynamic> setValues = [];

  @override
  Future<void> setUserOverride(String key, dynamic value) async {
    setKeys.add(key);
    setValues.add(value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}
