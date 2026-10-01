import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/utils/debug_log_options.dart';
import 'package:lmstory/core/utils/logger.dart';
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
