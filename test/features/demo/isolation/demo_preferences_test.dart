import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/features/demo/data/demo_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{
      'theme_mode': 'dark',
      'advanced_mode_enabled': false,
      'user_overrides': '{"broadcast_chat.preset_id":"real-preset"}',
    });
  });

  TestWidgetsFlutterBinding ensureBinding() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    return binding;
  }

  group('DemoPreferences 读穿透 + 写隔离', () {
    test('未命中键读取穿透到真实 Preferences', () async {
      ensureBinding();
      final demo = DemoPreferences(fallback: Preferences());
      expect(await demo.getString('theme_mode'), 'dark');
      expect(await demo.getBool('advanced_mode_enabled'), false);
    });

    test('写入只进 overlay，真实值不受影响', () async {
      ensureBinding();
      final real = Preferences();
      final demo = DemoPreferences(fallback: real);
      await demo.setBool('advanced_mode_enabled', true);
      await demo.setString(
        'user_overrides',
        '{"advanced.embedding_preset_id":"demo"}',
      );

      expect(await demo.getBool('advanced_mode_enabled'), true);
      expect(
        await demo.getString('user_overrides'),
        '{"advanced.embedding_preset_id":"demo"}',
      );

      // 真实侧未被写入
      expect(await real.getBool('advanced_mode_enabled'), false);
      expect(
        await real.getString('user_overrides'),
        '{"broadcast_chat.preset_id":"real-preset"}',
      );
    });

    test('remove 产生删除标记：遮蔽真实值且不删真实值', () async {
      ensureBinding();
      final real = Preferences();
      final demo = DemoPreferences(fallback: real);

      expect(await demo.getString('theme_mode'), 'dark');
      await demo.remove('theme_mode');
      expect(await demo.getString('theme_mode'), isNull);
      expect(await demo.containsKey('theme_mode'), isFalse);
      // 真实侧仍在
      expect(await real.getString('theme_mode'), 'dark');
    });

    test('overlay 类型不符按未命中穿透（与基座语义一致）', () async {
      ensureBinding();
      final demo = DemoPreferences(fallback: Preferences());
      await demo.setInt('fresh_key', 42);
      // 同键以 double 读：overlay 类型不符 → 穿透（真实侧无此键）→ null
      expect(await demo.getDouble('fresh_key'), isNull);
      expect(await demo.getInt('fresh_key'), 42);
    });

    test('clear 只清 overlay，不动真实存储', () async {
      ensureBinding();
      final real = Preferences();
      final demo = DemoPreferences(fallback: real);
      await demo.setString('k1', 'v1');
      await demo.clear();
      expect(await demo.getString('k1'), isNull);
      expect(await real.getString('theme_mode'), 'dark');
    });

    test('各标量类型与字符串列表 roundtrip', () async {
      ensureBinding();
      final demo = DemoPreferences(fallback: Preferences());
      await demo.setInt('i', 42);
      await demo.setDouble('d', 1.5);
      await demo.setStringList('l', <String>['a', 'b']);
      expect(await demo.getInt('i'), 42);
      expect(await demo.getDouble('d'), 1.5);
      expect(await demo.getStringList('l'), <String>['a', 'b']);
      // int 以 double 读：Dart num 世界里 42 is! double → 穿透为 null
      expect(await demo.getDouble('i'), isNull);
    });
  });
}
