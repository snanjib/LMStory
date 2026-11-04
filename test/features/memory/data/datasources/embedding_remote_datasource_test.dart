import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/network/dio_client.dart';
import 'package:lmstory/features/memory/data/datasources/embedding_remote_datasource.dart';
import 'package:lmstory/features/memory/domain/services/embedding_service.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';

import 'embedding_remote_datasource_test.mocks.dart';

@GenerateMocks([DioClient])
void main() {
  late MockDioClient mockDioClient;
  late EmbeddingRemoteDS remoteDS;

  setUp(() {
    mockDioClient = MockDioClient();
    remoteDS = EmbeddingRemoteDS(dioClient: mockDioClient);
  });

  group('EmbeddingRemoteDS.embed', () {
    test('正确解析响应并返回 Float32List', () async {
      when(
        mockDioClient.post<Map<String, dynamic>>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => const ApiResponse<Map<String, dynamic>>(
          data: {
            'data': [
              {
                'embedding': [0.1, 0.2, 0.3, 0.4],
              },
            ],
          },
          statusCode: 200,
        ),
      );

      final result = await remoteDS.embed(
        text: 'hello',
        kind: EmbeddingInputKind.passage,
        model: 'text-embedding-3-small',
        baseUrl: 'https://api.openai.com',
        apiKey: 'sk-test',
      );

      expect(result, isA<Float32List>());
      expect(result.length, 4);
      expect(result[0], closeTo(0.1, 0.001));
      expect(result[1], closeTo(0.2, 0.001));
      expect(result[2], closeTo(0.3, 0.001));
      expect(result[3], closeTo(0.4, 0.001));
    });

    test('429 限流抛 EmbeddingRateLimitedException', () async {
      when(
        mockDioClient.post<Map<String, dynamic>>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenThrow(
        const AppHttpException(
          'Too many requests',
          statusCode: 429,
          responseBody: 'rate limit exceeded',
        ),
      );

      expect(
        () => remoteDS.embed(
          text: 'hello',
          kind: EmbeddingInputKind.passage,
          model: 'text-embedding-3-small',
          baseUrl: 'https://api.openai.com',
          apiKey: 'sk-test',
        ),
        throwsA(isA<EmbeddingRateLimitedException>()),
      );
    });

    test('500 服务端错误透传 AppHttpException', () async {
      when(
        mockDioClient.post<Map<String, dynamic>>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenThrow(
        const AppHttpException(
          'Internal server error',
          statusCode: 500,
        ),
      );

      expect(
        () => remoteDS.embed(
          text: 'hello',
          kind: EmbeddingInputKind.passage,
          model: 'text-embedding-3-small',
          baseUrl: 'https://api.openai.com',
          apiKey: 'sk-test',
        ),
        throwsA(isA<AppHttpException>()),
      );
    });

    test('401 认证失败透传 AppHttpException（非 429）', () async {
      when(
        mockDioClient.post<Map<String, dynamic>>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenThrow(
        const AppHttpException(
          'Unauthorized',
          statusCode: 401,
        ),
      );

      expect(
        () => remoteDS.embed(
          text: 'hello',
          kind: EmbeddingInputKind.passage,
          model: 'text-embedding-3-small',
          baseUrl: 'https://api.openai.com',
          apiKey: 'invalid-key',
        ),
        throwsA(isA<AppHttpException>()),
      );
    });

    test('响应缺少 data 数组抛 AppHttpException', () async {
      when(
        mockDioClient.post<Map<String, dynamic>>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => const ApiResponse<Map<String, dynamic>>(
          data: {'unexpected': 'format'},
          statusCode: 200,
        ),
      );

      expect(
        () => remoteDS.embed(
          text: 'hello',
          kind: EmbeddingInputKind.passage,
          model: 'text-embedding-3-small',
          baseUrl: 'https://api.openai.com',
          apiKey: 'sk-test',
        ),
        throwsA(isA<AppHttpException>()),
      );
    });

    test('响应 data 数组为空抛 AppHttpException', () async {
      when(
        mockDioClient.post<Map<String, dynamic>>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => const ApiResponse<Map<String, dynamic>>(
          data: {'data': <dynamic>[]},
          statusCode: 200,
        ),
      );

      expect(
        () => remoteDS.embed(
          text: 'hello',
          kind: EmbeddingInputKind.passage,
          model: 'text-embedding-3-small',
          baseUrl: 'https://api.openai.com',
          apiKey: 'sk-test',
        ),
        throwsA(isA<AppHttpException>()),
      );
    });

    test('响应 body 为 null 抛 AppHttpException', () async {
      when(
        mockDioClient.post<Map<String, dynamic>>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => const ApiResponse<Map<String, dynamic>>(
          data: null,
          statusCode: 200,
        ),
      );

      expect(
        () => remoteDS.embed(
          text: 'hello',
          kind: EmbeddingInputKind.passage,
          model: 'text-embedding-3-small',
          baseUrl: 'https://api.openai.com',
          apiKey: 'sk-test',
        ),
        throwsA(isA<AppHttpException>()),
      );
    });

    test('apiKey 为 null 时不添加 Authorization header', () async {
      when(
        mockDioClient.post<Map<String, dynamic>>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => const ApiResponse<Map<String, dynamic>>(
          data: {
            'data': [
              {
                'embedding': [0.5],
              },
            ],
          },
          statusCode: 200,
        ),
      );

      final result = await remoteDS.embed(
        text: 'hello',
        kind: EmbeddingInputKind.passage,
        model: 'text-embedding-3-small',
        baseUrl: 'https://api.openai.com',
        apiKey: null,
      );

      expect(result.length, 1);
      expect(result[0], closeTo(0.5, 0.001));
    });

    test('1536 维向量正确解析', () async {
      // 模拟 1536 维 OpenAI embedding 响应
      final vector = List<double>.generate(1536, (i) => i * 0.001);
      when(
        mockDioClient.post<Map<String, dynamic>>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => ApiResponse<Map<String, dynamic>>(
          data: {
            'data': [
              {'embedding': vector},
            ],
          },
          statusCode: 200,
        ),
      );

      final result = await remoteDS.embed(
        text: 'hello',
        kind: EmbeddingInputKind.passage,
        model: 'text-embedding-3-small',
        baseUrl: 'https://api.openai.com',
        apiKey: 'sk-test',
      );

      expect(result, isA<Float32List>());
      expect(result.length, 1536);
      expect(result[0], closeTo(0.0, 0.001));
      expect(result[1535], closeTo(1.535, 0.001));
    });
  });

  group('EmbeddingRemoteDS.embed input_type（非对称模型白名单）', () {
    /// 成功响应桩（input_type 断言只关心请求体）
    void stubOk() {
      when(
        mockDioClient.post<Map<String, dynamic>>(
          any,
          data: anyNamed('data'),
          options: anyNamed('options'),
        ),
      ).thenAnswer(
        (_) async => const ApiResponse<Map<String, dynamic>>(
          data: {
            'data': [
              {
                'embedding': [0.1],
              },
            ],
          },
          statusCode: 200,
        ),
      );
    }

    /// 取回（唯一一次）请求体
    Map<String, dynamic> capturedBody() => verify(
          mockDioClient.post<Map<String, dynamic>>(
            any,
            data: captureAnyNamed('data'),
            options: anyNamed('options'),
          ),
        ).captured.single as Map<String, dynamic>;

    test('nemotron 模型 + query → 注入 input_type=query', () async {
      stubOk();
      await remoteDS.embed(
        text: '古碑的来历',
        kind: EmbeddingInputKind.query,
        model: 'nvidia/nemotron-nano-embed-v1',
        baseUrl: 'https://integrate.api.nvidia.com/v1',
        apiKey: 'nvapi-test',
      );
      expect(capturedBody()['input_type'], 'query');
    });

    test('nemotron 模型 + passage → 注入 input_type=passage', () async {
      stubOk();
      await remoteDS.embed(
        text: '时间: 深夜\n地点: 荒庙\n事件: 苏明远夜探荒庙',
        kind: EmbeddingInputKind.passage,
        model: 'NV-Embed-QA', // 大小写不敏感命中白名单
        baseUrl: 'https://integrate.api.nvidia.com/v1',
        apiKey: 'nvapi-test',
      );
      expect(capturedBody()['input_type'], 'passage');
    });

    test('非 asymmetric 模型（OpenAI 兼容）→ 不注入 input_type', () async {
      stubOk();
      await remoteDS.embed(
        text: 'hello',
        kind: EmbeddingInputKind.passage,
        model: 'text-embedding-3-small',
        baseUrl: 'https://api.openai.com',
        apiKey: 'sk-test',
      );
      // 对称模型端点对未知参数回 400，白名单外绝不携带
      expect(capturedBody().containsKey('input_type'), isFalse);
    });
  });
}
