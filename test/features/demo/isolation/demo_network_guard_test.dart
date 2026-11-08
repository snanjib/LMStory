import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/demo/data/demo_network_guard.dart';

void main() {
  group('DemoNetworkGuard + 守卫客户端', () {
    test('GuardedDioClient 全部方法记录企图并抛错', () async {
      final guard = DemoNetworkGuard();
      final client = GuardedDioClient(guard);

      await Future.wait(<Future<void>>[
        expectLater(
          client.get<String>('/models'),
          throwsA(isA<DemoNetworkBlockedException>()),
        ),
        expectLater(
          client.post<Map<String, dynamic>>('/embeddings', data: {}),
          throwsA(isA<DemoNetworkBlockedException>()),
        ),
        expectLater(
          client.put<Map<String, dynamic>>('/x', data: {}),
          throwsA(isA<DemoNetworkBlockedException>()),
        ),
        expectLater(
          client.patch<Map<String, dynamic>>('/x', data: {}),
          throwsA(isA<DemoNetworkBlockedException>()),
        ),
        expectLater(
          client.delete<Map<String, dynamic>>('/x'),
          throwsA(isA<DemoNetworkBlockedException>()),
        ),
      ]);

      expect(guard.attemptCount, 5);
      expect(guard.attempts.every((a) => a.via == 'guardedDio'), isTrue);
      expect(guard.attempts.first.detail, startsWith('GET'));
    });

    test('GuardedHttpClient.streamPost 记录企图并以流错误交付', () async {
      final guard = DemoNetworkGuard();
      final client = GuardedHttpClient(guard);

      final stream = client.streamPost(
        'https://demo.invalid/v1/chat/completions',
        <String, String>{},
      );
      await expectLater(
        stream,
        emitsInOrder(<dynamic>[
          emitsError(isA<DemoNetworkBlockedException>()),
        ]),
      );
      expect(guard.attemptCount, 1);
      expect(guard.attempts.single.via, 'guardedHttp');
      expect(
        guard.attempts.single.detail,
        contains('demo.invalid'),
      );
    });

    test('守卫不建连接：拦截先于任何底层调用（无网络依赖即可证）', () async {
      final guard = DemoNetworkGuard();
      final dio = GuardedDioClient(guard);
      // 测试环境无真实网络配置；若守卫未先拦截，底层 Dio 将以真实
      // 网络栈执行——此处断言守卫错误先于任何连接发生。
      await expectLater(
        dio.get<String>('https://demo.invalid/v1/models'),
        throwsA(
          isA<DemoNetworkBlockedException>().having(
            (e) => e.via,
            'via',
            'guardedDio',
          ),
        ),
      );
    });
  });
}
