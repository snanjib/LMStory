import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/utils/debug_log_options.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/diagnostics/domain/entities/failure_log_entry.dart';
import 'package:lmstory/features/diagnostics/domain/repositories/failure_log_repository.dart';
import 'package:lmstory/features/diagnostics/presentation/controllers/diagnostics_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// DM-4：调试日志五开关跨重启生效。
///
/// 缺陷：Logger.debugOptions 仅诊断页 load() 时装配——启动初始化只恢复
/// log_level。用户开「记录完整提示词」后重启，运行时全关但 UI 仍显示勾选。
/// 修复：抽取共享加载函数（诊断页与启动装配共用，键名单一事实源），
/// main.dart 启动时调用。本组测试钉住加载函数的键名映射与默认值，
/// 以及「控制器切换 → 持久化 → 共享加载函数读回」的闭环。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<Preferences> fakePrefs([Map<String, Object> values = const {}]) async {
    SharedPreferences.setMockInitialValues(values);
    return Preferences(prefs: await SharedPreferences.getInstance());
  }

  test('loadDebugLogOptions：未设置时默认全关（不误开日志膨胀）', () async {
    final prefs = await fakePrefs();
    final options = await DiagnosticsController.loadDebugLogOptions(prefs);
    expect(options.allDisabled, isTrue);
  });

  group('开发者暗门门禁：解锁 ↔ 再上锁往返', () {
    test('unlock → isDevGateUnlocked=true → lock → false（持久 bool 往返）',
        () async {
      final prefs = await fakePrefs();
      final controller = DiagnosticsController(
        failureLogRepository: _StubFailureLogRepository(),
        preferences: prefs,
      );
      addTearDown(controller.dispose);

      expect(await controller.isDevGateUnlocked(), isFalse);

      await controller.unlockDevGate();
      expect(await controller.isDevGateUnlocked(), isTrue);

      await controller.lockDevGate();
      expect(
        await controller.isDevGateUnlocked(),
        isFalse,
        reason: '再上锁后转手设备不再暴露开发者卡（DV14-2）',
      );
    });

    test('未设置/读失败时安全默认为锁定', () async {
      final prefs = await fakePrefs();
      final controller = DiagnosticsController(
        failureLogRepository: _StubFailureLogRepository(),
        preferences: prefs,
      );
      addTearDown(controller.dispose);
      expect(await controller.isDevGateUnlocked(), isFalse);
    });
  });

  group('日志级别缺省：诊断页显示与启动装配同源', () {
    test('未设置 log_level 时 load() 显示 kDefaultLogLevel（与 main 装配单源）', () async {
      final prefs = await fakePrefs();
      final controller = DiagnosticsController(
        failureLogRepository: _EmptyFailureLogRepository(),
        preferences: prefs,
      );
      addTearDown(controller.dispose);

      await controller.load();
      expect(
        controller.state.logLevel,
        kDefaultLogLevel,
        reason: '缺省与启动装配共用 kDefaultLogLevel——release 收敛 info 时'
            ' 诊断页显示须同步（此前兜底 debug，显示与实际生效相反）',
      );
    });
  });

  group('DevGateTapCounter：连点计数与时间窗', () {
    final base = DateTime(2026, 10, 6, 12);

    test('窗内连点 7 次达成解锁并复位', () {
      final counter = DevGateTapCounter();
      for (var i = 1; i <= 6; i++) {
        expect(
          counter.registerTap(base.add(Duration(milliseconds: 100 * i))),
          isFalse,
          reason: '第 $i 次不应达成',
        );
      }
      expect(
        counter.registerTap(base.add(const Duration(milliseconds: 700))),
        isTrue,
      );
      // 达成后复位：再点一次从 1 计起
      expect(
        counter.registerTap(base.add(const Duration(milliseconds: 800))),
        isFalse,
      );
    });

    test('跨 2s 窗口的慢点计数作废（DV14-2 计数无时间窗修复）', () {
      final counter = DevGateTapCounter();
      for (var i = 1; i <= 6; i++) {
        counter.registerTap(base.add(Duration(seconds: 5 * i)));
      }
      // 6 次间隔均 5s > 2s：每次都作废，永远只有 1 次在计
      expect(
        counter.registerTap(base.add(const Duration(seconds: 31))),
        isFalse,
      );
    });

    test('窗口边界：间隔恰为 2s 不作废，超过 2s 作废', () {
      final counter = DevGateTapCounter();
      final firstWithinWindow = counter.registerTap(base);
      expect(
        counter.registerTap(base.add(const Duration(seconds: 2))),
        isFalse,
        reason: '间隔 == 窗口仍属连续（严格大于才作废），此时计数为 2',
      );
      expect(
        counter.registerTap(base.add(const Duration(seconds: 5))),
        isFalse,
        reason: '间隔 3s > 2s 计数作废，重新从 1 计起',
      );
      expect(firstWithinWindow, isFalse);
    });

    test('reset 清空计数与时间戳', () {
      final counter = DevGateTapCounter();
      for (var i = 1; i <= 3; i++) {
        counter.registerTap(base.add(Duration(milliseconds: 50 * i)));
      }
      counter.reset();
      // reset 后无残留：重新连点 7 次才解锁
      for (var i = 1; i <= 6; i++) {
        expect(
          counter.registerTap(base.add(Duration(milliseconds: 100 * i))),
          isFalse,
        );
      }
      expect(
        counter.registerTap(base.add(const Duration(milliseconds: 650))),
        isTrue,
      );
    });
  });

  test('loadDebugLogOptions：读 debug_log_* 五键，未设置项默认 false', () async {
    final prefs = await fakePrefs({
      'debug_log_prompts': true,
      'debug_log_keywords': true,
    });
    final options = await DiagnosticsController.loadDebugLogOptions(prefs);
    expect(options.logPrompts, isTrue);
    expect(options.logKeywords, isTrue);
    expect(options.logResponses, isFalse);
    expect(options.logMemories, isFalse);
    expect(options.logPayloads, isFalse);
  });

  test('控制器切换 → 持久化 → 共享加载函数读回（启动装配同一通道）', () async {
    final prefs = await fakePrefs();
    final controller = DiagnosticsController(
      failureLogRepository: _StubFailureLogRepository(),
      preferences: prefs,
    );
    addTearDown(controller.dispose);

    await controller.setDebugLogOption(DebugLogField.payloads, true);
    // 切换即同步运行时（既有行为）
    expect(Logger.debugOptions.logPayloads, isTrue);

    // 模拟重启后的启动装配：不经诊断页 load()，直接用共享加载函数恢复
    final restored = await DiagnosticsController.loadDebugLogOptions(prefs);
    expect(restored.logPayloads, isTrue, reason: '重启后开关仍生效（DM-4）');
    expect(restored.logPrompts, isFalse);
  });
}

class _StubFailureLogRepository implements FailureLogRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

/// load() 全链路可用的空仓库（getRecentLogs/countAll 返回安全默认值）
class _EmptyFailureLogRepository implements FailureLogRepository {
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
    throw UnimplementedError();
  }

  @override
  Future<List<FailureLogEntry>> getRecentLogs({
    int limit = 50,
    String? mode,
    String? sessionId,
  }) async =>
      const [];

  @override
  Future<int> countAll() async => 0;

  @override
  Future<void> markRecovered(int logId) async {}

  @override
  Future<void> clearAll() async {}

  @override
  Future<int> deleteBySession(String sessionId) async => 0;
}
