import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/config_visibility.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 配置显示模式基建单元测试：持久化往返、启动预读、
/// 可见性查询的双态与未登记键失配策略。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<Preferences> fakePrefs([
    Map<String, Object> values = const {},
  ]) async {
    SharedPreferences.setMockInitialValues(values);
    return Preferences(prefs: await SharedPreferences.getInstance());
  }

  group('ConfigLevelNotifier', () {
    test('readInitial：默认 simple，保存 advanced 回读 advanced，未知值回退 simple',
        () async {
      expect(
        await ConfigLevelNotifier.readInitial(await fakePrefs()),
        ConfigLevel.simple,
      );
      expect(
        await ConfigLevelNotifier.readInitial(
          await fakePrefs({ConfigLevelNotifier.prefKey: 'advanced'}),
        ),
        ConfigLevel.advanced,
      );
      expect(
        await ConfigLevelNotifier.readInitial(
          await fakePrefs({ConfigLevelNotifier.prefKey: 'bogus'}),
        ),
        ConfigLevel.simple,
      );
    });

    test('setLevel：状态即时更新并按 prefKey 持久化', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = Preferences(prefs: await SharedPreferences.getInstance());
      final notifier = ConfigLevelNotifier(prefs);

      expect(notifier.state, ConfigLevel.simple);
      await notifier.setLevel(ConfigLevel.advanced);
      expect(notifier.state, ConfigLevel.advanced);
      expect(
        await prefs.getString(ConfigLevelNotifier.prefKey),
        'advanced',
      );
      notifier.dispose();
    });

    test('initialValue 注入：构造即持保存值，_load 兜底重读幂等', () async {
      final notifier = ConfigLevelNotifier(
        await fakePrefs({ConfigLevelNotifier.prefKey: 'advanced'}),
        initialValue: ConfigLevel.advanced,
      );
      expect(notifier.state, ConfigLevel.advanced, reason: '构造即持保存值');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(notifier.state, ConfigLevel.advanced, reason: '_load 回填同值');
      notifier.dispose();
    });
  });

  group('ConfigVisibility.of', () {
    test('simple 键双模式可见，advanced 键仅进阶模式可见', () {
      const simpleKey = ConfigVisibilityKeys.chatDefaultModel;
      const advancedKey = ConfigVisibilityKeys.chatGenerationDefaults;

      expect(ConfigVisibility.of(simpleKey, ConfigLevel.simple), isTrue);
      expect(ConfigVisibility.of(simpleKey, ConfigLevel.advanced), isTrue);
      expect(ConfigVisibility.of(advancedKey, ConfigLevel.simple), isFalse);
      expect(ConfigVisibility.of(advancedKey, ConfigLevel.advanced), isTrue);
    });

    test('未登记键：debug 断言抛错，强制先登记再接线', () {
      expect(
        () => ConfigVisibility.of(
          'panel.story.notRegistered',
          ConfigLevel.simple,
        ),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
