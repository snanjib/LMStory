import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/llm/tool_schema_rejection.dart';

/// 工具 schema 拒收报文的共享识别口径。
void main() {
  group('isToolSchemaRejectionText', () {
    test('Gemini 原始报文（additionalProperties + function_declarations）→ true', () {
      expect(
        isToolSchemaRejectionText(
          '''Invalid JSON payload received. Unknown name "additionalProperties" at 'tools.function_declarations[0].parameters': Cannot find field.''',
        ),
        isTrue,
      );
    });

    test('Gemini 流包装后的完整报文 → true', () {
      expect(
        isToolSchemaRejectionText(
          r'''Gemini stream interrupted: AppHttpException: SSE request failed with status 400 | Response: {"error":{"code":400,"message":"Invalid JSON payload received. Unknown name \"additionalProperties\" at 'tools.function_declarations[0].parameters': Cannot find field."}}''',
        ),
        isTrue,
      );
    });

    test('OpenAI schema 拒收文案 → true', () {
      expect(
        isToolSchemaRejectionText(
          "Invalid schema for function 'extract_keywords': In context=(), "
          "'additionalProperties' is not permitted.",
        ),
        isTrue,
      );
    });

    test('普通错误不误伤（限流 / 上下文超限 / 连接中断）', () {
      expect(isToolSchemaRejectionText('rate limited'), isFalse);
      expect(
        isToolSchemaRejectionText(
          "This model's maximum context length is 128000 tokens",
        ),
        isFalse,
      );
      expect(isToolSchemaRejectionText('connection reset'), isFalse);
    });
  });
}
