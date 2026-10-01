import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/domain/services/llm_capabilities.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// LlmCapabilities 单元测试（新增）
///
/// 验证供应商能力探测逻辑：
/// - OpenAI 官方域名 → jsonSchemaStrict
/// - DeepSeek/OpenRouter → jsonObject
/// - 未知供应商 → none
/// - buildResponseFormat 根据能力级别构建正确的 LlmResponseFormat 子类
void main() {
  group('LlmCapabilities.detectJsonSupport', () {
    test('OpenAI 官方域名 → jsonSchemaStrict', () {
      expect(
        LlmCapabilities.detectJsonSupport(
          baseUrl: 'https://api.openai.com/v1',
        ),
        JsonSupportLevel.jsonSchemaStrict,
      );
    });

    test('OpenAI Azure 镜像 → jsonSchemaStrict', () {
      expect(
        LlmCapabilities.detectJsonSupport(
          baseUrl: 'https://my-resource.openai.azure.com/',
        ),
        JsonSupportLevel.jsonSchemaStrict,
      );
    });

    test('DeepSeek 官方域名 → jsonObject', () {
      expect(
        LlmCapabilities.detectJsonSupport(
          baseUrl: 'https://api.deepseek.com/v1',
        ),
        JsonSupportLevel.jsonObject,
      );
    });

    test('OpenRouter 聚合平台 → jsonObject', () {
      expect(
        LlmCapabilities.detectJsonSupport(
          baseUrl: 'https://openrouter.ai/api/v1',
        ),
        JsonSupportLevel.jsonObject,
      );
    });

    test('未知供应商（本地部署）→ none', () {
      expect(
        LlmCapabilities.detectJsonSupport(
          baseUrl: 'http://localhost:1234/v1',
        ),
        JsonSupportLevel.none,
      );
    });

    test('自建镜像 → none（保守判定）', () {
      expect(
        LlmCapabilities.detectJsonSupport(
          baseUrl: 'https://my-llm-proxy.example.com/v1',
        ),
        JsonSupportLevel.none,
      );
    });

    test('空 baseUrl → none', () {
      expect(
        LlmCapabilities.detectJsonSupport(baseUrl: ''),
        JsonSupportLevel.none,
      );
    });

    test('大小写不敏感', () {
      expect(
        LlmCapabilities.detectJsonSupport(
          baseUrl: 'HTTPS://API.OPENAI.COM/v1',
        ),
        JsonSupportLevel.jsonSchemaStrict,
      );
    });
  });

  group('LlmCapabilities.buildResponseFormat', () {
    test('jsonSchemaStrict + schema → LlmResponseFormatJsonSchema', () {
      final schema = {
        'type': 'object',
        'properties': {
          'x': {'type': 'string'},
        },
      };
      final format = LlmCapabilities.buildResponseFormat(
        level: JsonSupportLevel.jsonSchemaStrict,
        schema: schema,
        schemaName: 'test_schema',
      );
      expect(format, isA<LlmResponseFormatJsonSchema>());
      final jsonSchema = format! as LlmResponseFormatJsonSchema;
      expect(jsonSchema.name, 'test_schema');
      expect(jsonSchema.schema, schema);
      expect(jsonSchema.strict, isTrue);
    });

    test('jsonSchemaStrict 但未提供 schema → 降级为 JsonObject', () {
      final format = LlmCapabilities.buildResponseFormat(
        level: JsonSupportLevel.jsonSchemaStrict,
      );
      expect(format, isA<LlmResponseFormatJsonObject>());
    });

    test('jsonObject → LlmResponseFormatJsonObject', () {
      final format = LlmCapabilities.buildResponseFormat(
        level: JsonSupportLevel.jsonObject,
        schema: {'type': 'object'}, // jsonObject 模式忽略 schema
      );
      expect(format, isA<LlmResponseFormatJsonObject>());
    });

    test('none → null（不注入 response_format）', () {
      final format = LlmCapabilities.buildResponseFormat(
        level: JsonSupportLevel.none,
        schema: {'type': 'object'},
      );
      expect(format, isNull);
    });
  });
}
