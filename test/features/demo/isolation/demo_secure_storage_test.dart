import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/demo/data/demo_secure_storage.dart';

void main() {
  group('DemoSecureStorage 纯内存隔离', () {
    test('write/read/containsKey/delete/deleteAll 全内存 roundtrip', () async {
      final storage = DemoSecureStorage();
      await storage.write('api_key_demo-preset-v1', 'demo-local-replay');
      expect(await storage.read('api_key_demo-preset-v1'), 'demo-local-replay');
      expect(await storage.containsKey('api_key_demo-preset-v1'), isTrue);
      expect(await storage.read('api_key_real'), isNull);

      await storage.delete('api_key_demo-preset-v1');
      expect(await storage.read('api_key_demo-preset-v1'), isNull);

      await storage.write('a', '1');
      await storage.write('b', '2');
      await storage.deleteAll();
      expect(await storage.read('a'), isNull);
      expect(await storage.read('b'), isNull);
    });

    test('读永不穿透：真实钥匙串键在演示存储中恒为 null', () async {
      final storage = DemoSecureStorage();
      // 即使真实环境存在某键（测试环境无真实钥匙串），本类无任何
      // 通往 FlutterSecureStorage 的调用路径——全部方法覆写为内存 map。
      expect(await storage.read('api_key_anything'), isNull);
      expect(await storage.containsKey('api_key_anything'), isFalse);
    });
  });
}
