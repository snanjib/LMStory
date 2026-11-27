import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/config/intermediate_config.dart'
    show ContextBudget;
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/widgets/commit_slider.dart';
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
  int writeAttempts = 0;
  bool rejectWrite = false;

  @override
  Future<AppConfig> getResolvedConfig() async => AppConfig(
        version: '0.1',
        broadcastChat: const BroadcastChatConfig(),
        advanced: AdvancedConfig(
          contextBudget: ContextBudget(
            compactionTriggerRatio:
                written['advanced.contextBudget.compactionTriggerRatio']
                        as double? ??
                    0.5,
          ),
        ),
      );

  @override
  Future<Map<String, dynamic>> getUserOverrides() async => {};

  @override
  Future<void> setUserOverride(String key, dynamic value) async {
    writeAttempts++;
    if (rejectWrite) throw StateError('Fixture rejected the write');
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

  Future<void> pumpSection(
    WidgetTester tester,
    _CapturingSettingsRepository repo,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(repo),
          advancedGlobalContextWindowProvider
              .overrideWith((ref) async => 96000),
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
  }

  testWidgets('单一旋钮双显示，token 输入反推百分比写覆盖', (tester) async {
    final repo = _CapturingSettingsRepository();
    await pumpSection(tester, repo);

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
    expect(find.text('75%'), findsOneWidget);
  });

  testWidgets('全局阈值预览，取消和保存失败回退，成功后重开保留', (tester) async {
    final repo = _CapturingSettingsRepository();
    await pumpSection(tester, repo);

    Future<TestGesture> preview() async {
      final bounds = tester.getRect(find.byType(CommitSlider));
      final thumb = bounds.centerLeft + Offset(bounds.width * 0.4, 0);
      final gesture = await tester.startGesture(thumb);
      await gesture.moveBy(const Offset(60, 0));
      await gesture.moveTo(bounds.centerRight - const Offset(2, 0));
      await tester.pump();
      expect(find.text('≈ 76.8k tokens'), findsOneWidget);
      return gesture;
    }

    final cancelled = await preview();
    await cancelled.cancel();
    await tester.pump();
    expect(repo.writeAttempts, 0);
    expect(find.text('≈ 48k tokens'), findsOneWidget);

    repo.rejectWrite = true;
    final failed = await preview();
    await failed.up();
    await tester.pumpAndSettle();
    expect(repo.writeAttempts, 1);
    expect(find.text(t.advanced.settings.saveFailed), findsOneWidget);
    expect(find.text('≈ 48k tokens'), findsOneWidget);

    repo.rejectWrite = false;
    final saved = await preview();
    await saved.up();
    await tester.pumpAndSettle();
    expect(repo.writeAttempts, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpSection(tester, repo);
    expect(find.text('80%'), findsOneWidget);
    expect(find.text('≈ 76.8k tokens'), findsOneWidget);
  });
}
