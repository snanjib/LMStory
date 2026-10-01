import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/theme/theme_controller.dart';
import 'package:lmstory/features/advanced/presentation/advanced_mode_flag.dart';
import 'package:lmstory/features/intermediate/presentation/intermediate_mode_flag.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主题/导演开关启动预读——保存值≠系统值时首帧
/// 不再闪烁。钉住三件事：①readInitial 与 notifier 用同一键名（单源）；
/// ②initialValue 注入后 state 构造即持保存值（不等 _load 异步回填）；
/// ③旧默认路径（无初值）行为不变。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<Preferences> fakePrefs([Map<String, Object> values = const {}]) async {
    SharedPreferences.setMockInitialValues(values);
    return Preferences(prefs: await SharedPreferences.getInstance());
  }

  group('ThemeModeNotifier 启动预读（OH10-2）', () {
    test('readInitial：dark/light/system 三值与未知值回退', () async {
      expect(
        await ThemeModeNotifier.readInitial(
          await fakePrefs({'app_theme_mode': 'dark'}),
        ),
        ThemeMode.dark,
      );
      expect(
        await ThemeModeNotifier.readInitial(
          await fakePrefs({'app_theme_mode': 'light'}),
        ),
        ThemeMode.light,
      );
      expect(
        await ThemeModeNotifier.readInitial(
          await fakePrefs({'app_theme_mode': 'bogus'}),
        ),
        ThemeMode.system,
      );
      expect(
        await ThemeModeNotifier.readInitial(await fakePrefs()),
        ThemeMode.system,
      );
    });

    test('initialValue 注入：构造即持保存值（首帧无 system→dark 闪烁）', () async {
      // 模拟 main：预读值=prefs 存值（同一数据源），注入构造器。
      final notifier = ThemeModeNotifier(
        await fakePrefs({'app_theme_mode': 'dark'}),
        initialValue: ThemeMode.dark,
      );
      expect(notifier.state, ThemeMode.dark, reason: '构造即持保存值，不等 _load');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(notifier.state, ThemeMode.dark, reason: '_load 回填同值，无闪烁');
      notifier.dispose();
    });

    test('构造期 set：_load 结算后不迟到覆盖新值', () async {
      // 无 initialValue（走默认路径）：构造器启动 _load 但尚未结算，
      // 此窗口内用户 set 的值不得被 _load 的回写冲掉。
      final notifier = ThemeModeNotifier(
        await fakePrefs({'app_theme_mode': 'dark'}),
      );
      unawaited(notifier.setThemeMode(ThemeMode.light));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(notifier.state, ThemeMode.light, reason: 'set 在 _load 后结算，胜出');
      notifier.dispose();
    });
  });

  group('AdvancedModeFlagNotifier 启动预读（OH10-2）', () {
    test('readInitial：与 prefKey 单源，未设置回退 true（v0.4.0 默认开）', () async {
      expect(
        await AdvancedModeFlagNotifier.readInitial(
          await fakePrefs({'advanced_mode_enabled': true}),
        ),
        isTrue,
      );
      expect(
        await AdvancedModeFlagNotifier.readInitial(await fakePrefs()),
        isTrue,
        reason: 'v0.4.0 起导演模式默认开启',
      );
    });

    test('无存储值：_load 兜底回退 true（v0.4.0 默认开）', () async {
      final notifier = AdvancedModeFlagNotifier(await fakePrefs());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(notifier.state, isTrue);
      notifier.dispose();
    });

    test('initialValue 注入：构造即持保存值（首帧无 false→true 闪烁）', () async {
      final notifier = AdvancedModeFlagNotifier(
        await fakePrefs({'advanced_mode_enabled': true}),
        initialValue: true,
      );
      expect(notifier.state, isTrue, reason: '构造即持保存值，不等 _load');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(notifier.state, isTrue, reason: '_load 回填同值，无闪烁');
      notifier.dispose();
    });

    test('构造期 set：_load 结算后不迟到覆盖新值', () async {
      // 无 initialValue（走默认路径）：构造器启动 _load 但尚未结算，
      // 此窗口内用户 set 的值不得被 _load 的回写冲掉。
      final notifier = AdvancedModeFlagNotifier(
        await fakePrefs({'advanced_mode_enabled': true}),
      );
      unawaited(notifier.setEnabled(enabled: false));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(notifier.state, isFalse, reason: 'set 在 _load 后结算，胜出');
      notifier.dispose();
    });
  });

  group('IntermediateModeFlagNotifier 启动预读', () {
    test('readInitial：与 prefKey 单源，未设置回退 false（入口默认隐藏）', () async {
      expect(
        await IntermediateModeFlagNotifier.readInitial(
          await fakePrefs({'intermediate_mode_enabled': true}),
        ),
        isTrue,
      );
      expect(
        await IntermediateModeFlagNotifier.readInitial(await fakePrefs()),
        isFalse,
        reason: '故事模式入口默认隐藏',
      );
    });

    test('无存储值：_load 兜底回退 false（入口默认隐藏）', () async {
      final notifier = IntermediateModeFlagNotifier(await fakePrefs());
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(notifier.state, isFalse);
      notifier.dispose();
    });

    test('initialValue 注入：构造即持保存值（首帧无 false→true 闪烁）', () async {
      final notifier = IntermediateModeFlagNotifier(
        await fakePrefs({'intermediate_mode_enabled': true}),
        initialValue: true,
      );
      expect(notifier.state, isTrue, reason: '构造即持保存值，不等 _load');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(notifier.state, isTrue, reason: '_load 回填同值，无闪烁');
      notifier.dispose();
    });

    test('构造期 set：_load 结算后不迟到覆盖新值', () async {
      // 无 initialValue（走默认路径）：构造器启动 _load 但尚未结算，
      // 此窗口内用户 set 的值不得被 _load 的回写冲掉。
      final notifier = IntermediateModeFlagNotifier(
        await fakePrefs({'intermediate_mode_enabled': true}),
      );
      unawaited(notifier.setEnabled(enabled: false));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(notifier.state, isFalse, reason: 'set 在 _load 后结算，胜出');
      notifier.dispose();
    });
  });
}
