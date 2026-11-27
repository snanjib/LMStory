import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/network/llm_adapters/openai_adapter.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

void main() {
  group('OpenAiAdapter toolResult 错误信号编码', () {
    test('isError=true 时消息内容前置 [TOOL_ERROR] 且不附加额外键，isError=false 保持原样', () {
      final options = AgentWireOptions.forProtocolName('openaiCompatible');
      final errorMsg = AgentMessage.toolResult(
        toolCallId: 'call_err',
        content: '缺少必填字段 confidence',
        isError: true,
      ).toRequestMap(options);
      final okMsg = AgentMessage.toolResult(
        toolCallId: 'call_ok',
        content: '已查询',
      ).toRequestMap(options);

      final body = OpenAiAdapter().buildRequestBody(
        LlmRequest(
          baseUrl: 'https://api.openai.com',
          apiKey: 'k',
          modelId: 'gpt-4o',
          messages: [
            const {'role': 'user', 'content': '更新'},
            errorMsg,
            okMsg,
          ],
        ),
        stream: false,
      );

      final messages = (body['messages'] as List).cast<Map<String, dynamic>>();
      expect(messages[1], {
        'role': 'tool',
        'tool_call_id': 'call_err',
        'content': '[TOOL_ERROR] 缺少必填字段 confidence',
      });
      expect(messages[2], {
        'role': 'tool',
        'tool_call_id': 'call_ok',
        'content': '已查询',
      });
    });
  });
}
