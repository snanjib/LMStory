import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_message.dart';

/// HAR-02：出站空 assistant 保形——toRequestMap 恒携带 content 键，
/// 不再整体省略（省略键会让 Anthropic 空 content 数组、Gemini 空 parts，
/// 消息形状被吞）。
void main() {
  group('HAR-02 出站空 assistant：toRequestMap 恒携带 content 键', () {
    test('空正文无工具调用的 assistant → content 为空串（不省略键）', () {
      final map = AgentMessage.assistant().toRequestMap();

      expect(map['role'], 'assistant');
      expect(map.containsKey('content'), isTrue);
      expect(map['content'], '');
    });

    test('有工具调用无正文的 assistant → content 同样为空串', () {
      final map = AgentMessage.assistant(
        toolCalls: const [
          AgentToolCall(id: 'c1', name: 'echo', arguments: {}),
        ],
      ).toRequestMap();

      expect(map['content'], '');
      expect(map['tool_calls'] as List, hasLength(1));
    });

    test('有正文的 assistant → content 原样（行为不变）', () {
      final map = AgentMessage.assistant(text: 'hi').toRequestMap();

      expect(map['content'], 'hi');
    });
  });

  group('toolResult 协议级 isError 映射', () {
    test('isError=false 时四协议与默认输出不含额外键且无前缀', () {
      final msg = AgentMessage.toolResult(toolCallId: 'c1', content: 'ok');
      expect(msg.isToolError, isFalse);

      for (final options in [
        const AgentWireOptions(),
        AgentWireOptions.forProtocolName('openaiCompatible'),
        AgentWireOptions.forProtocolName('openaiResponses'),
        AgentWireOptions.forProtocolName('anthropic'),
        AgentWireOptions.forProtocolName('geminiNative'),
      ]) {
        final map = msg.toRequestMap(options);
        expect(map, {'role': 'tool', 'tool_call_id': 'c1', 'content': 'ok'});
        expect(map.containsKey('is_error'), isFalse);
      }
    });

    test('isError=true 时 Anthropic/Gemini 附带 is_error 标记，文本保持原样', () {
      final msg = AgentMessage.toolResult(
        toolCallId: 'c1',
        content: '缺少参数',
        isError: true,
      );
      expect(msg.isToolError, isTrue);

      for (final protocol in ['anthropic', 'geminiNative']) {
        final map =
            msg.toRequestMap(AgentWireOptions.forProtocolName(protocol));
        expect(map, {
          'role': 'tool',
          'tool_call_id': 'c1',
          'content': '缺少参数',
          'is_error': true,
        });
      }
    });

    test('isError=true 时 OpenAI Chat/Responses/默认前置 [TOOL_ERROR] 且不加多余键', () {
      final msg = AgentMessage.toolResult(
        toolCallId: 'c1',
        content: '缺少参数',
        isError: true,
      );

      for (final options in [
        const AgentWireOptions(),
        AgentWireOptions.forProtocolName('openaiCompatible'),
        AgentWireOptions.forProtocolName('openaiResponses'),
      ]) {
        final map = msg.toRequestMap(options);
        expect(map, {
          'role': 'tool',
          'tool_call_id': 'c1',
          'content': '[TOOL_ERROR] 缺少参数',
        });
        expect(map.containsKey('is_error'), isFalse);
      }
    });
  });
}
