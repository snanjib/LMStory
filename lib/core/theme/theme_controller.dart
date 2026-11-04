import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';

/// App-wide theme mode (light / dark / system).
final themeModeProvider = StateNotifierProvider<ThemeModeNotifier, ThemeMode>(
  (ref) => ThemeModeNotifier(ref.read(preferencesProvider)),
);

class ThemeModeNotifier extends StateNotifier<ThemeMode> {
  ThemeModeNotifier(this._prefs, {ThemeMode? initialValue})
      : super(initialValue ?? ThemeMode.system) {
    _loading = _load();
  }

  final Preferences _prefs;

  /// 启动加载结算前屏障：setThemeMode 先等它完成，
  /// 防止构造期异步 _load 的回写在用户切换后迟到覆盖。
  late final Future<void> _loading;

  /// 键名公开——main 启动预读与 notifier 单源，
  /// 防双写漂移。
  static const prefKey = 'app_theme_mode';

  /// main 在 runApp 前预读保存值注入构造器，
  /// 消除「首帧 system → 保存值」的冷启动闪烁；_load 兜底重读幂等。
  static Future<ThemeMode> readInitial(Preferences prefs) async {
    final saved = await prefs.getString(prefKey);
    return switch (saved) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> _load() async {
    final saved = await _prefs.getString(prefKey);
    if (saved == 'light') {
      state = ThemeMode.light;
    } else if (saved == 'dark') {
      state = ThemeMode.dark;
    } else {
      state = ThemeMode.system;
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    await _loading;
    state = mode;
    final value = mode == ThemeMode.light
        ? 'light'
        : mode == ThemeMode.dark
            ? 'dark'
            : 'system';
    await _prefs.setString(prefKey, value);
  }
}
