import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/director_budget_section.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 帮助文案承诺的 harness 写点落地
///
/// foreshadow_check_interval / event_log_retention_turns 此前只有配置
/// 文件入口（帮助文案却承诺「可在导演设置调整」）——预算分区高级子折叠
/// 暴露两行 stepper，写入走 advanced.harness.* 用户覆盖。
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

  testWidgets('高级子折叠移除旧伏笔清点步进器，保留轮日志保留写点', (tester) async {
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
              body: ListView(children: const [DirectorBudgetSection()]),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 展开「高级」子折叠（本组件树内唯一）
    await tester.tap(find.text('高级'));
    await tester.pumpAndSettle();

    // 旧伏笔清点间隔步进器已移除；轮日志保留行仍在且默认回显 20
    expect(find.text('伏笔清点间隔（轮）'), findsNothing);
    final retentionRow = find.text('轮日志保留（轮）');
    expect(retentionRow, findsOneWidget);
    expect(
      find.descendant(
        of: find.ancestor(of: retentionRow, matching: find.byType(Column)),
        matching: find.text('20'),
      ),
      findsWidgets,
    );

    // 点「轮日志保留」- 步进 → 写 advanced.harness.event_log_retention_turns=19
    await tester.ensureVisible(retentionRow);
    await tester.pumpAndSettle();
    final retentionTile =
        find.ancestor(of: retentionRow, matching: find.byType(Column)).first;
    await tester.tap(
      find.descendant(of: retentionTile, matching: find.byIcon(Icons.remove)),
    );
    await tester.pumpAndSettle();
    expect(repo.written['advanced.harness.event_log_retention_turns'], 19);
  });
}
