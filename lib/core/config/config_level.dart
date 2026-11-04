import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';

/// 配置显示模式：简单（默认，只显示常用配置）/ 进阶（全部配置）。
///
/// 级别是全局开关：一个键控制全部设置面与会话内面板，不做每页单独记忆。
enum ConfigLevel { simple, advanced }

/// 配置显示模式的全局状态（独立 Preferences 键，不走 user_overrides——
/// 级别是 UI 元配置不是业务配置，与 `app_theme_mode` 同模式）。
class ConfigLevelNotifier extends StateNotifier<ConfigLevel> {
  ConfigLevelNotifier(this._prefs, {ConfigLevel? initialValue})
      : super(initialValue ?? ConfigLevel.simple) {
    _loading = _load();
  }

  final Preferences _prefs;

  /// 启动加载结算前屏障：setLevel 先等它完成，
  /// 防止构造期异步 _load 的回写在用户切换后迟到覆盖。
  late final Future<void> _loading;

  /// 键名公开——main 启动预读与 notifier 单源，防双写漂移。
  static const prefKey = 'ui_config_level';

  /// main 在 runApp 前预读保存值注入构造器，
  /// 消除「首帧 simple → 保存值」闪烁；_load 兜底重读幂等。
  static Future<ConfigLevel> readInitial(Preferences prefs) async {
    final saved = await prefs.getString(prefKey);
    return saved == ConfigLevel.advanced.name
        ? ConfigLevel.advanced
        : ConfigLevel.simple;
  }

  Future<void> _load() async {
    state = await readInitial(_prefs);
  }

  /// 切换即时生效并持久化，无需重启；provider 驱动全部过滤面重建。
  Future<void> setLevel(ConfigLevel level) async {
    await _loading;
    state = level;
    await _prefs.setString(prefKey, level.name);
  }
}

final configLevelProvider =
    StateNotifierProvider<ConfigLevelNotifier, ConfigLevel>(
  (ref) => ConfigLevelNotifier(ref.read(preferencesProvider)),
);
