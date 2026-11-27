import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/utils/file_log_sink.dart';
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
  _ConfigurableFailureLogRepo({this.failures = const [], int? totalCount})
      : totalCount = totalCount ?? failures.length;

  List<FailureLogEntry> failures;

  /// 表内真实总数（概览计数用；缺省与列表长度一致，可独立设置模拟
  /// 「表滚动保留 200 条 vs 列表只载 50 条」的截断场景）
  int totalCount;
  int clearAllCalls = 0;

  @override
  @override
  Future<void> markRecovered(int logId) async {}

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
    String? outcome,
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
  Future<int> countAll() async => totalCount;

  @override
  Future<void> clearAll() async {
    clearAllCalls++;
    failures = const [];
    totalCount = 0;
  }

  @override
  Future<int> deleteBySession(String sessionId) async => 0;
}

// ── 测试 helper ─────────────────────────────────────────────────────

Future<void> _pumpPage(
  WidgetTester tester, {
  _ConfigurableFailureLogRepo? repo,
  bool settle = true,
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
  if (settle) await tester.pumpAndSettle();
}

class _SaveLogPicker extends FilePicker {
  _SaveLogPicker(this.path);

  final String path;
  int calls = 0;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async {
    calls++;
    expect(type, FileType.custom);
    expect(allowedExtensions, ['log']);
    return path;
  }
}

Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 160; attempt++) {
    await tester.pump(const Duration(milliseconds: 25));
    if (ready()) return;
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
  }
  expect(ready(), isTrue);
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

  for (final platform in [TargetPlatform.android, TargetPlatform.macOS]) {
    testWidgets(
      'diagnostics export on $platform cleans the actual files',
      (tester) async {
        final dir = Directory.systemTemp.createTempSync('lmstory-log-export-');
        final sink = FileLogSink(directoryPath: dir.path);
        await tester.runAsync(sink.init);
        Logger.addSink(sink);
        addTearDown(() async {
          Logger.removeSink(sink);
          await sink.dispose();
          await dir.delete(recursive: true);
        });
        final logfile =
            sink.currentFilePath ?? fail('Log sink not initialized');
        const oldUrl =
            'raw:https://old-user:old-password@old.invalid/private-v2';
        const newUrl = 'https://new.invalid/private-v4?tenant=new-query';
        final oldSocket = SocketException(
          'Failed host lookup: "old-lookup.invalid"',
          osError: const OSError('No route to host', 65),
          address: InternetAddress('198.51.100.42'),
          port: 7443,
        );
        final oldest = File('$logfile.2')
          ..writeAsStringSync(
            '2026-01-01T08:00:01 [WARN] [Wire] request failed, '
            'HTTP 401 $oldUrl?tenant=old-query | Authorization: Basic old-auth\n',
          );
        final rotated = File('$logfile.1')
          ..writeAsStringSync(
            '2026-01-01T08:00:02 [WARN] [Wire] retry delay=1200ms '
            'https://retry.invalid/private-v3?token=retry-query '
            'headers={"X-API-Key":"retry-auth with spaces"} | $oldSocket\n',
          );
        const Logger('Wire').error(
          'request exhausted',
          detail: 'HTTP 429 elapsed=1200ms $newUrl | apiKey=new-auth',
          error: SocketException(
            'Failed host lookup: "lookup.invalid"',
            osError: const OSError('Connection refused', 61),
            address: InternetAddress('203.0.113.21'),
            port: 8443,
          ),
        );
        const Logger('OptInPrompt').info('他推开院门，雨还在下。');
        final current = File(logfile);
        final newLog = current.readAsStringSync();
        expect(newLog, contains('HTTP 429 elapsed=1200ms https://<endpoint>'));
        expect(newLog, contains('apiKey=***'));
        expect(newLog, contains('Failed host lookup: <host>'));
        expect(newLog, contains('errno = 61), address = <host>, port = 8443'));
        for (final private in [
          'new.invalid',
          'private-v4',
          'new-auth',
          'new-query',
          'lookup.invalid',
          '203.0.113.21',
        ]) {
          expect(newLog, isNot(contains(private)));
        }
        final sources = [oldest, rotated, current];
        final sourceBytes =
            sources.map((file) => file.readAsBytesSync()).toList();

        final saved = File('${dir.path}/saved.log');
        final picker = _SaveLogPicker(saved.path);
        FilePicker.platform = picker;
        final platformMessages = tester.binding.defaultBinaryMessenger;
        const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
        const pathsChannel = MethodChannel('plugins.flutter.io/path_provider');
        List<int>? sharedBytes;
        platformMessages
          ..setMockMethodCallHandler(pathsChannel, (_) async => dir.path)
          ..setMockMethodCallHandler(shareChannel, (call) async {
            expect(call.method, 'shareFiles');
            final arguments = call.arguments as Map<Object?, Object?>;
            if (arguments['paths'] case [final String path]) {
              expect(path, isNot(logfile));
              sharedBytes = File(path).readAsBytesSync();
              return 'test receiver';
            }
            fail('Expected one shared file');
          });
        addTearDown(() {
          platformMessages
            ..setMockMethodCallHandler(pathsChannel, null)
            ..setMockMethodCallHandler(shareChannel, null);
        });

        final logs = t.settings.diagnostics.logs;
        await _pumpPage(tester, settle: false);
        await _waitFor(
          tester,
          () => find.text(logs.share).evaluate().isNotEmpty,
        );
        await tester.tap(find.text(logs.share).first);
        final List<int> outputBytes;
        if (platform == TargetPlatform.android) {
          await tester.pumpAndSettle();
          expect(find.text(logs.shareConfirmBody), findsOneWidget);
          expect(sharedBytes, isNull);
          await tester.tap(find.text(logs.shareConfirmAction).last);
          await _waitFor(tester, () => sharedBytes != null);
          await _waitFor(
            tester,
            () => dir.listSync().every((item) => item is File),
          );
          outputBytes =
              sharedBytes ?? fail('Share platform did not read bytes');
          expect(picker.calls, 0);
        } else {
          await _waitFor(
            tester,
            () => find.text(t.common.fileSaved.title).evaluate().isNotEmpty,
          );
          outputBytes = saved.readAsBytesSync();
          expect(picker.calls, 1);
          expect(sharedBytes, isNull);
        }
        final output = utf8.decode(outputBytes);
        for (final private in [
          'old-user',
          'old-password',
          'old.invalid',
          'private-v2',
          'old-query',
          'old-auth',
          'retry.invalid',
          'private-v3',
          'retry-query',
          'retry-auth',
          'new.invalid',
          'private-v4',
          'new-auth',
          'new-query',
          'lookup.invalid',
          '203.0.113.21',
          'old-lookup.invalid',
          '198.51.100.42',
        ]) {
          expect(output, isNot(contains(private)));
        }
        for (final line in [
          '2026-01-01T08:00:01 [WARN] [Wire]',
          'HTTP 401 https://<endpoint> | Authorization: ***',
          '2026-01-01T08:00:02 [WARN] [Wire]',
          'retry delay=1200ms',
          '"X-API-Key":"***"',
          'SocketException: Failed host lookup: <host>',
          'errno = 65), address = <host>, port = 7443',
          'errno = 61), address = <host>, port = 8443',
          'request exhausted',
          '他推开院门，雨还在下。',
        ]) {
          expect(output, contains(line));
        }
        final oldestIndex = output.indexOf('===== app.log.2 =====');
        final rotatedIndex = output.indexOf('===== app.log.1 =====');
        final latestIndex = output.indexOf('===== app.log =====');
        expect(oldestIndex, 0);
        expect(rotatedIndex, greaterThan(oldestIndex));
        expect(latestIndex, greaterThan(rotatedIndex));
        expect(sources.map((file) => file.readAsBytesSync()), sourceBytes);
      },
      variant: TargetPlatformVariant({platform}),
    );
  }

  group('DiagnosticsPage - 页面骨架', () {
    testWidgets('1. AppBar 显示"诊断信息" + 5 个分组卡片标题', (tester) async {
      await _pumpPage(tester);

      expect(find.text('诊断信息'), findsOneWidget);
      expect(find.text('状态概览'), findsOneWidget);
      // Stage 5 后页面有 5 个卡片，下方卡片在屏幕外，
      // 用 skipOffstage: false 验证骨架渲染（不验证可见性）
      expect(find.text('调试日志开关', skipOffstage: false), findsOneWidget);
      // 轮轨迹入口卡加入后下方卡片被推出布局区（ListView 未布局
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

    testWidgets('6b. 表内总数超列表截断（200 条）时概览显示真实总数', (tester) async {
      final repo = _ConfigurableFailureLogRepo(
        failures: List.generate(
          50,
          (i) => FailureLogEntry(
            id: i,
            sessionId: 's$i',
            mode: 'intermediate',
            errorCategory: 'network',
            createdAt: DateTime(2026),
          ),
        ),
        totalCount: 200,
      );
      await _pumpPage(tester, repo: repo);

      // 概览计数取 countAll 真值，不再被列表 50 条截断失真
      expect(find.textContaining('失败记录: 200 条'), findsOneWidget);
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

  // ── 开发者暗门：连点解锁 / 重新上锁 / 计数时间窗 ────────────────────

  group('DiagnosticsPage - 开发者暗门', () {
    Finder versionLine() => find.textContaining('LMStory v');

    /// 版本行在 ListView 尾部（懒布局，先滚动定位再连点）
    Future<void> scrollToVersion(WidgetTester tester) async {
      await tester.scrollUntilVisible(versionLine(), 200);
      await tester.pumpAndSettle();
    }

    Future<void> tapVersion(WidgetTester tester) async {
      await tester.tap(versionLine(), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 50));
    }

    testWidgets('15. 版本行连点 7 次 → 解锁：持久化 + toast + 两卡出现', (tester) async {
      await _pumpPage(tester);

      // 锁定态：暗门卡不在树上（未解锁时卡片不插入）
      expect(find.text('Agent Loop 自检', skipOffstage: false), findsNothing);

      await scrollToVersion(tester);
      for (var i = 0; i < 7; i++) {
        await tapVersion(tester);
      }
      await tester.pumpAndSettle();

      expect(find.text('开发者工具已解锁'), findsOneWidget);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('diagnostics.dev_gate_unlocked'), isTrue);

      // 两张开发者卡 + 再上锁行插入在上方，向上滚动定位验证
      await tester.scrollUntilVisible(find.text('Agent Loop 自检'), -300);
      expect(find.text('Agent Loop 自检'), findsOneWidget);
      expect(find.text('Director Round Trace'), findsOneWidget);
      expect(find.text('重新上锁开发者工具'), findsOneWidget);
    });

    testWidgets(
        '16. 窗内连点不足 7 次（6 次）不解锁（时间窗逻辑由 DevGateTapCounter 单测钉死——widget 层假时钟不作用于 DateTime.now）',
        (tester) async {
      await _pumpPage(tester);
      await scrollToVersion(tester);

      for (var i = 0; i < 6; i++) {
        await tapVersion(tester);
      }
      await tester.pumpAndSettle();

      expect(find.text('开发者工具已解锁'), findsNothing);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('diagnostics.dev_gate_unlocked'), isNull);
    });

    testWidgets('17. 解锁态点「重新上锁」→ 两卡收回 + 持久化 false + toast', (tester) async {
      SharedPreferences.setMockInitialValues({
        'diagnostics.dev_gate_unlocked': true,
      });
      await _pumpPage(tester);

      // 再上锁行在两张暗门卡之下（懒布局）：从列表顶直滚定位
      // （中转先滚「Agent Loop 自检」会把视口推到列表下部，目标反而在上方未建区）
      final relock = find.text('重新上锁开发者工具');
      await tester.scrollUntilVisible(relock, 200);
      await tester.pumpAndSettle();
      expect(relock, findsOneWidget);
      await tester.tap(relock);
      await tester.pumpAndSettle();

      expect(find.text('开发者工具已上锁'), findsOneWidget);
      expect(find.text('Agent Loop 自检', skipOffstage: false), findsNothing);
      expect(
        find.text('Director Round Trace', skipOffstage: false),
        findsNothing,
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('diagnostics.dev_gate_unlocked'), isFalse);
    });

    testWidgets('18. 版本行显示 LMStory + 版本号形态（连点热区存在）', (tester) async {
      await _pumpPage(tester);

      await scrollToVersion(tester);
      expect(versionLine(), findsOneWidget);
      // 具体数字与 pubspec 的对账由 app_meta 守卫测试负责，
      // 这里只钉「LMStory v」前缀形态。
      expect(
        (tester.widget(versionLine()) as Text).data,
        startsWith('LMStory v'),
      );
    });
  });
}
