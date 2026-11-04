import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/director_context_section.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 上下文配置收敛全局设置面守门：
///
/// - 主面单一旋钮「上下文压缩阈值」：百分比 + token 双显示
///   （默认窗口 96000 兜底，50% → ≈ 48k tokens）。
/// - 故事三段式遗产键（原文区下限/检索区比例）不再出现。
/// - 窗口上限降级进高级子折叠，展开可见且披露当前生效窗口。
/// - token 直接输入反推百分比并写
///   advanced.contextBudget.compactionTriggerRatio 覆盖。
class _CapturingSettingsRepository implements SettingsRepository {
  final Map<String, Object?> written = {};

  @override
  Future<AppConfig> getResolvedConfig() async => const AppConfig(
        version: '0.1',
        broadcastChat: BroadcastChatConfig(),
      );

  @override
  Future<Map<String, dynamic>> getUserOverrides() async => {};

  @override
  Future<void> setUserOverride(String key, dynamic value) async {
    written[key] = value;
  }

  @override
  Future<void> removeUserOverride(String key) async {
    written.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  testWidgets('单一旋钮双显示；token 输入反推百分比写覆盖', (tester) async {
    final repo = _CapturingSettingsRepository();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(repo),
          advancedConfigProvider
              .overrideWith((ref) async => const AdvancedConfig()),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: ListView(children: const [DirectorContextSection()]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 主面：唯一旋钮 + 双显示（默认 50%，回退窗口 96000 → 48k）
    expect(find.text('上下文压缩阈值'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('≈ 48k tokens'), findsOneWidget);

    // 故事三段式遗产键不再出现在导演面
    expect(find.text('原文区下限'), findsNothing);
    expect(find.text('检索区比例'), findsNothing);

    // 窗口上限在高级子折叠内（折叠态不可见），展开后可见 + 生效窗口披露
    expect(find.text('单次请求 Token 上限'), findsNothing);
    await tester.tap(find.text('高级：窗口上限'));
    await tester.pumpAndSettle();
    expect(find.text('单次请求 Token 上限'), findsOneWidget);
    expect(
      find.text('当前生效窗口 96k（模型窗口与上限取小）'),
      findsOneWidget,
    );

    // token 直接输入 72000（/96000 = 0.75）反推百分比写覆盖
    await tester.tap(find.text('≈ 48k tokens'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '72000');
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(
      repo.written['advanced.contextBudget.compactionTriggerRatio'],
      0.75,
    );
  });
}
