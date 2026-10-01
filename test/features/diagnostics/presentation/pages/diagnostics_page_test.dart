import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/diagnostics/domain/entities/failure_log_entry.dart';
import 'package:lmstory/features/diagnostics/domain/repositories/failure_log_repository.dart';
import 'package:lmstory/features/diagnostics/presentation/pages/diagnostics_page.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// DiagnosticsPage Widget 测试（.6）
///
/// 验证：
/// - 页面骨架：AppBar + 5 个分组卡片标题（含 Stage 5 调试日志开关卡）
/// - 空状态：无失败记录显示"全部正常"，无日志显示"暂无日志"
/// - 失败列表：传入 failures → 显示错误码 + 消息 + 时间 + 概览计数
/// - 清空确认：点击清空 → 弹对话框 → 确认/取消 → clearAll 调用次数
/// - 日志级别切换：点击 ChoiceChip → 持久化 + 立即生效
/// - 调试日志开关：勾选 CheckboxListTile → 持久化 + Logger.debugOptions 同步（Stage 5）

// ── 可配置 Stub ─────────────────────────────────────────────────────

class _ConfigurableFailureLogRepo implements FailureLogRepository {
  _ConfigurableFailureLogRepo({this.failures = const []});

  List<FailureLogEntry> failures;
  int clearAllCalls = 0;

  @override
  Future<FailureLogEntry> insertLog({
    required String sessionId,
    required String mode,
    required String errorCategory,
    String? errorCode,
    String? failedPhase,
    int? httpStatus,
    String? errorMessage,
    String? rawError,
  }) async {
    return FailureLogEntry(
      id: 1,
      sessionId: sessionId,
      mode: mode,
      errorCategory: errorCategory,
      errorCode: errorCode,
      failedPhase: failedPhase,
      httpStatus: httpStatus,
      errorMessage: errorMessage,
      rawError: rawError,
      createdAt: DateTime(2026),
    );
  }

  @override
  Future<List<FailureLogEntry>> getRecentLogs({
    int limit = 50,
    String? mode,
    String? sessionId,
  }) async =>
      failures;

  @override
  Future<void> clearAll() async {
    clearAllCalls++;
    failures = const [];
  }

  @override
  Future<int> deleteBySession(String sessionId) async => 0;
}

// ── 测试 helper ─────────────────────────────────────────────────────

Future<void> _pumpPage(
  WidgetTester tester, {
  _ConfigurableFailureLogRepo? repo,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        failureLogRepositoryProvider.overrideWithValue(
          repo ?? _ConfigurableFailureLogRepo(),
        ),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          // Avoid relying on the host Flutter SDK's Impeller-only InkSparkle
          // shader asset in widget tests.
          theme: ThemeData(splashFactory: InkRipple.splashFactory),
          home: const DiagnosticsPage(),
        ),
      ),
    ),
  );
  // 等 addPostFrameCallback + load() 完成
  await tester.pumpAndSettle();
}

// ── 测试 ────────────────────────────────────────────────────────────

void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 重置 Logger 全局静态状态，避免测试间污染
    Logger.globalMinLevel = LogLevel.debug;
    Logger.clearSinks();
  });

  group('DiagnosticsPage - 页面骨架', () {
    testWidgets('1. AppBar 显示"诊断信息" + 5 个分组卡片标题', (tester) async {
      await _pumpPage(tester);

      expect(find.text('诊断信息'), findsOneWidget);
      expect(find.text('状态概览'), findsOneWidget);
      // Stage 5 后页面有 5 个卡片，下方卡片在屏幕外，
      // 用 skipOffstage: false 验证骨架渲染（不验证可见性）
      expect(find.text('调试日志开关', skipOffstage: false), findsOneWidget);
      //  轮轨迹入口卡加入后下方卡片被推出布局区（ListView 未布局
      // ≠ offstage），改用滚动定位（与测试 2/3 同款做法）
      await tester.scrollUntilVisible(find.text('运行日志'), 200);
      expect(find.text('运行日志'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('失败历史'), 200);
      expect(find.text('失败历史'), findsOneWidget);
    });
  });

  group('DiagnosticsPage - 空状态', () {
    testWidgets('2. 无失败记录 → 失败历史卡显示"全部正常"', (tester) async {
      await _pumpPage(tester);

      // 失败历史卡在 ListView 底部，需滚动到可见
      await tester.scrollUntilVisible(find.text('全部正常'), 200);
      expect(find.text('全部正常'), findsOneWidget);
      expect(find.text('没有失败记录'), findsOneWidget);
    });

    testWidgets('3. 无日志文件 → 运行日志显示"暂无日志"', (tester) async {
      await _pumpPage(tester);

      // Stage 5 后 LogViewer 在屏幕外，需滚动到可见
      await tester.scrollUntilVisible(find.text('暂无日志'), 200);
      expect(find.text('暂无日志'), findsOneWidget);
    });

    testWidgets('4. 概览卡显示"暂无失败记录" + 默认 Debug 级别', (tester) async {
      await _pumpPage(tester);

      expect(find.text('暂无失败记录'), findsOneWidget);
      // 默认 Debug 级别
      final debugChip = find.widgetWithText(ChoiceChip, 'Debug');
      expect(debugChip, findsOneWidget);
      expect(
        (tester.widget(debugChip) as ChoiceChip).selected,
        isTrue,
      );
    });
  });

  group('DiagnosticsPage - 失败列表', () {
    testWidgets('5. 有失败记录 → 显示错误码 + 消息 + 时间 + 概览计数', (tester) async {
      final repo = _ConfigurableFailureLogRepo(
        failures: [
          FailureLogEntry(
            id: 1,
            sessionId: 'session-1',
            mode: 'intermediate',
            errorCategory: 'network',
            errorCode: 'E016',
            errorMessage: '网络中断',
            createdAt: DateTime(2026, 7, 3, 10, 30),
          ),
        ],
      );
      await _pumpPage(tester, repo: repo);

      // 概览卡在顶部可见，先断言概览计数
      expect(find.textContaining('失败记录: 1 条'), findsOneWidget);

      // 滚动到失败历史卡可见
      await tester.scrollUntilVisible(find.text('E016'), 200);

      // 错误码
      expect(find.text('E016'), findsOneWidget);
      // 消息
      expect(find.text('网络中断'), findsOneWidget);
      // 时间（等宽格式）
      expect(find.textContaining('2026-07-03 10:30:00'), findsOneWidget);
      // 不再显示空状态
      expect(find.text('全部正常'), findsNothing);
    });

    testWidgets('6. 多条失败记录 → 概览显示总数', (tester) async {
      final repo = _ConfigurableFailureLogRepo(
        failures: [
          FailureLogEntry(
            id: 1,
            sessionId: 's1',
            mode: 'intermediate',
            errorCategory: 'network',
            errorCode: 'E016',
            createdAt: DateTime(2026),
          ),
          FailureLogEntry(
            id: 2,
            sessionId: 's2',
            mode: 'simple',
            errorCategory: 'config',
            errorCode: 'S001',
            createdAt: DateTime(2026),
          ),
        ],
      );
      await _pumpPage(tester, repo: repo);

      expect(find.textContaining('失败记录: 2 条'), findsOneWidget);
    });
  });

  group('DiagnosticsPage - 清空确认', () {
    testWidgets('7. 点击清空 → 显示确认对话框 → 确认 → 调 clearAll + SnackBar',
        (tester) async {
      final repo = _ConfigurableFailureLogRepo(
        failures: [
          FailureLogEntry(
            id: 1,
            sessionId: 'session-1',
            mode: 'intermediate',
            errorCategory: 'network',
            errorCode: 'E016',
            createdAt: DateTime(2026),
          ),
        ],
      );
      await _pumpPage(tester, repo: repo);

      // 点击清空按钮（用 icon 定位，避免与对话框标题文本冲突）
      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      // 显示确认对话框
      expect(
        find.text('确定清空所有日志文件和失败记录吗？此操作不可恢复。'),
        findsOneWidget,
      );

      // 点击确认
      await tester.tap(find.widgetWithText(TextButton, '确认'));
      await tester.pumpAndSettle();

      // 验证 clearAll 被调用
      expect(repo.clearAllCalls, 1);
      // SnackBar 显示成功
      expect(find.text('诊断数据已清空'), findsOneWidget);
      // 滚动到底部，验证失败历史卡清空后显示空状态
      await tester.scrollUntilVisible(find.text('全部正常'), 200);
      expect(find.text('全部正常'), findsOneWidget);
    });

    testWidgets('8. 点击清空 → 取消 → 不调 clearAll', (tester) async {
      final repo = _ConfigurableFailureLogRepo();
      await _pumpPage(tester, repo: repo);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();

      expect(repo.clearAllCalls, 0);
      // 对话框关闭
      expect(
        find.text('确定清空所有日志文件和失败记录吗？此操作不可恢复。'),
        findsNothing,
      );
    });
  });

  group('DiagnosticsPage - 日志级别切换', () {
    testWidgets('9. 点击 Warn ChoiceChip → 持久化 + 立即生效 + UI 更新', (tester) async {
      await _pumpPage(tester);

      // 默认 Debug 选中
      final debugChip = find.widgetWithText(ChoiceChip, 'Debug');
      expect((tester.widget(debugChip) as ChoiceChip).selected, isTrue);

      // 点击 Warn
      await tester.tap(find.widgetWithText(ChoiceChip, 'Warn'));
      await tester.pumpAndSettle();

      // Warn 选中
      final warnChip = find.widgetWithText(ChoiceChip, 'Warn');
      expect((tester.widget(warnChip) as ChoiceChip).selected, isTrue);
      // Debug 取消选中
      expect((tester.widget(debugChip) as ChoiceChip).selected, isFalse);

      // 验证持久化到 Preferences
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('log_level'), 'warn');
      // 验证 Logger 全局级别立即生效
      expect(Logger.globalMinLevel, LogLevel.warn);
    });

    testWidgets('10. 概览卡显示当前日志级别', (tester) async {
      await _pumpPage(tester);

      // 概览卡的 _InfoRow 显示"日志级别: Debug"
      // _InfoRow label="日志级别" value="Debug"
      // 由于 _InfoRow 用 Row(label + value)，find.text 分别找
      expect(find.text('日志级别'), findsWidgets);
      // 概览卡里的级别值（可能与其他"Debug"文本重复，用 findsWidgets）
      expect(find.text('Debug'), findsWidgets);
    });
  });

  // ── Stage 5：调试日志开关 ──────────────────────────────────────────

  group('DiagnosticsPage - 调试日志开关（Stage 5）', () {
    testWidgets('11. 默认 5 个开关全关 + 标题渲染', (tester) async {
      await _pumpPage(tester);

      // 卡片标题渲染
      expect(find.text('调试日志开关', skipOffstage: false), findsOneWidget);
      // 5 个 checkbox 默认未选中
      final checkboxes = find.byType(Checkbox);
      expect(checkboxes, findsNWidgets(5));
      for (final cb in tester.widgetList<Checkbox>(checkboxes)) {
        expect(cb.value, isFalse);
      }
      // Logger.debugOptions 同步为全关
      expect(Logger.debugOptions.allDisabled, isTrue);
    });

    testWidgets('12. 勾选"记录提示词" → 持久化 + Logger.debugOptions 同步', (tester) async {
      await _pumpPage(tester);

      // 向上拖动 ListView 让调试日志开关卡可见（ensureVisible 在嵌套
      // Container+Material 中未能可靠滚动，改用 drag 手动控制）
      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();

      // 勾选"记录提示词"
      await tester.tap(find.widgetWithText(CheckboxListTile, '记录提示词'));
      await tester.pumpAndSettle();

      // Logger.debugOptions.logPrompts 立即生效，其他保持 false
      expect(Logger.debugOptions.logPrompts, isTrue);
      expect(Logger.debugOptions.logResponses, isFalse);
      expect(Logger.debugOptions.logMemories, isFalse);
      expect(Logger.debugOptions.logKeywords, isFalse);
      expect(Logger.debugOptions.logPayloads, isFalse);

      // 持久化到 Preferences
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('debug_log_prompts'), isTrue);
      expect(prefs.getBool('debug_log_responses'), isNull);
    });

    testWidgets('13. 重启后从 Preferences 加载已保存的开关', (tester) async {
      // 模拟之前已保存 logMemories=true（覆盖 setUp 的空设置）
      SharedPreferences.setMockInitialValues({'debug_log_memories': true});

      await _pumpPage(tester);

      // Logger.debugOptions 加载已保存的值
      expect(Logger.debugOptions.logMemories, isTrue);
      expect(Logger.debugOptions.logPrompts, isFalse);
      expect(Logger.debugOptions.allDisabled, isFalse);
    });

    testWidgets('14. 再次点击取消勾选 → Preferences 更新为 false', (tester) async {
      await _pumpPage(tester);

      // 滚动更多让关键词 tile 完全可见
      await tester.drag(find.byType(ListView), const Offset(0, -500));
      await tester.pumpAndSettle();

      final tileFinder = find.widgetWithText(CheckboxListTile, '提取关键词');

      // 勾选
      await tester.tap(tileFinder);
      await tester.pumpAndSettle();
      expect(Logger.debugOptions.logKeywords, isTrue);

      // 取消勾选
      await tester.tap(tileFinder);
      await tester.pumpAndSettle();
      expect(Logger.debugOptions.logKeywords, isFalse);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('debug_log_keywords'), isFalse);
    });
  });
}
