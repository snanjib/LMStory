import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';

/// 故事模式（intermediate）入口开关
///
/// 开关只影响入口可见性（首页卡片 + 侧边栏按钮 + 新建故事快捷键），
/// 不影响已有数据：故事会话、模板与配置一律保留。默认关（入口隐藏），
/// 可在故事模式设置页打开；显式开启过的用户保持开启。
class IntermediateModeFlagNotifier extends StateNotifier<bool> {
  /// [initialValue]：main 预读保存值注入，消除
  /// 首帧 false → 保存值 的开关闪烁；_load 兜底重读幂等。
  IntermediateModeFlagNotifier(this._preferences, {bool? initialValue})
      : super(initialValue ?? false) {
    _loading = _load();
  }

  static const String prefKey = 'intermediate_mode_enabled';

  final Preferences _preferences;

  /// 启动加载结算前屏障：setEnabled 先等它完成，
  /// 防止构造期异步 _load 的回写在用户切换后迟到覆盖。
  late final Future<void> _loading;

  /// 与 [prefKey] 单源的启动预读（runApp 前调用）
  static Future<bool> readInitial(Preferences preferences) async {
    return (await preferences.getBool(prefKey)) ?? false;
  }

  Future<void> _load() async {
    state = await _preferences.getBool(prefKey) ?? false;
  }

  Future<void> setEnabled({required bool enabled}) async {
    await _loading;
    state = enabled;
    await _preferences.setBool(prefKey, enabled);
  }

  Future<void> toggle() => setEnabled(enabled: !state);
}

final intermediateModeFlagProvider =
    StateNotifierProvider<IntermediateModeFlagNotifier, bool>(
  (ref) => IntermediateModeFlagNotifier(ref.watch(preferencesProvider)),
);
