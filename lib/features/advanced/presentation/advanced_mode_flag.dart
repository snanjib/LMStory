import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';

/// 导演模式（advanced）功能开关（v0.3 引入；v0.4.0 起默认开，设置页可关）
///
/// 开关只影响入口可见性（首页卡片 + 会话页分发），不影响已有数据；
/// 未开启时不出现任何 advanced 相关 UI（对齐 DOC-03A §6：
/// 未实现能力不出现在可选 UI）。
class AdvancedModeFlagNotifier extends StateNotifier<bool> {
  /// [initialValue]：——main 预读保存值注入，消除
  /// 首帧 false → 保存值 的开关闪烁；_load 兜底重读幂等。
  AdvancedModeFlagNotifier(this._preferences, {bool? initialValue})
      : super(initialValue ?? true) {
    _loading = _load();
  }

  static const String prefKey = 'advanced_mode_enabled';

  final Preferences _preferences;

  /// 启动加载结算前屏障：setEnabled 先等它完成，
  /// 防止构造期异步 _load 的回写在用户切换后迟到覆盖。
  late final Future<void> _loading;

  /// 与 [prefKey] 单源的启动预读（runApp 前调用）
  static Future<bool> readInitial(Preferences preferences) async {
    return (await preferences.getBool(prefKey)) ?? true;
  }

  Future<void> _load() async {
    state = await _preferences.getBool(prefKey) ?? true;
  }

  Future<void> setEnabled({required bool enabled}) async {
    await _loading;
    state = enabled;
    await _preferences.setBool(prefKey, enabled);
  }

  Future<void> toggle() => setEnabled(enabled: !state);
}

final advancedModeFlagProvider =
    StateNotifierProvider<AdvancedModeFlagNotifier, bool>(
  (ref) => AdvancedModeFlagNotifier(ref.watch(preferencesProvider)),
);
