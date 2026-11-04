import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/llm/tool_calling/tool_choice.dart';
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';
import 'package:lmstory/core/network/llm_adapters/responses_adapter.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// OpenAI Responses 适配器：URL / 请求体（input items / reasoning / 扁平工具）
/// / 非流式响应解析 / usage 双命名映射
void main() {
  late ResponsesAdapter adapter;

  setUp(() {
    adapter = ResponsesAdapter();
  });

  group('buildUrl / buildModelsUrl', () {
    test('无版本号 baseUrl 自动补 /v1 并拼 /responses', () {
      expect(
        adapter.buildUrl('https://api.openai.com', 'gpt-6-astra', stream: true),
        'https://api.openai.com/v1/responses',
      );
    });

    test('已含版本号原样保留', () {
      expect(
        adapter.buildUrl('https://openrouter.ai/api/v1', 'x', stream: false),
        'https://openrouter.ai/api/v1/responses',
      );
    });

    test('模型列表走 /models（与 CC 共享）', () {
      expect(
        adapter.buildModelsUrl('https://api.openai.com'),
        'https://api.openai.com/v1/models',
      );
    });
  });

  group('buildRequestBody', () {
    test('system → instructions；user/assistant/tool → input items', () {
      final body = adapter.buildRequestBody(
        const LlmRequest(
          baseUrl: 'https://api.openai.com',
          apiKey: 'k',
          modelId: 'gpt-6-astra',
          messages: [
            {'role': 'system', 'content': '你是叙事引擎'},
            {'role': 'user', 'content': '开始'},
            {
              'role': 'assistant',
              'content': '先查资料',
              'tool_calls': [
                {
                  'id': 'call_1',
                  'type': 'function',
                  'function': {
                    'name': 'search',
                    'arguments': '{"q":"a"}',
                  },
                },
              ],
            },
            {
              'role': 'tool',
              'tool_call_id': 'call_1',
              'content': '结果',
            },
          ],
        ),
        stream: true,
      );

      expect(body['model'], 'gpt-6-astra');
      expect(body['instructions'], '你是叙事引擎');
      expect(body['stream'], isTrue);

      final input = body['input'] as List;
      expect(input.length, 4);
      // system 不进 input；assistant 文本与工具调用拆为两个 item
      expect(input[0], {'role': 'user', 'content': '开始'});
      expect(input[1], {'role': 'assistant', 'content': '先查资料'});
      expect(input[2], {
        'type': 'function_call',
        'call_id': 'call_1',
        'name': 'search',
        'arguments': '{"q":"a"}',
      });
      expect(input[3], {
        'type': 'function_call_output',
        'call_id': 'call_1',
        'output': '结果',
      });

      // Responses 无这些 CC 参数
      expect(body.containsKey('messages'), isFalse);
      expect(body.containsKey('max_tokens'), isFalse);
      expect(body.containsKey('stream_options'), isFalse);
    });

    test('推理档位启用：reasoning.effort 下发且采样参数省略（官方规则）', () {
      final body = adapter.buildRequestBody(
        const LlmRequest(
          baseUrl: 'https://api.openai.com',
          modelId: 'gpt-6-sol',
          messages: [
            {'role': 'user', 'content': 'hi'},
          ],
          reasoningEffort: ReasoningEffort.high,
          temperature: 0.8,
          topP: 0.9,
        ),
        stream: false,
      );

      expect(body['reasoning'], {'effort': 'high'});
      expect(body.containsKey('temperature'), isFalse);
      expect(body.containsKey('top_p'), isFalse);
    });

    test('档位未配置：采样参数取整下发', () {
      final body = adapter.buildRequestBody(
        const LlmRequest(
          baseUrl: 'https://api.openai.com',
          modelId: 'gpt-4o',
          messages: [
            {'role': 'user', 'content': 'hi'},
          ],
          temperature: 0.5700000000000001,
          topP: 0.9,
        ),
        stream: false,
      );

      expect(body['temperature'], 0.57);
      expect(body['top_p'], 0.9);
      expect(body.containsKey('reasoning'), isFalse);
    });

    test('GPT-6 模型名单命中：即使未开档位也不发采样参数', () {
      final body = adapter.buildRequestBody(
        const LlmRequest(
          baseUrl: 'https://api.openai.com',
          modelId: 'gpt-6-astra',
          messages: [
            {'role': 'user', 'content': 'hi'},
          ],
          temperature: 0.8,
        ),
        stream: false,
      );

      expect(body.containsKey('temperature'), isFalse);
    });

    test('maxTokens → max_output_tokens；输出上限 0 不发送', () {
      LlmRequest request(int? maxTokens) => LlmRequest(
            baseUrl: 'https://api.openai.com',
            modelId: 'gpt-6-astra',
            messages: [
              {'role': 'user', 'content': 'hi'},
            ],
            maxTokens: maxTokens,
          );

      final withLimit = adapter.buildRequestBody(request(4096), stream: false);
      expect(withLimit['max_output_tokens'], 4096);

      final unlimited = adapter.buildRequestBody(request(0), stream: false);
      expect(unlimited.containsKey('max_output_tokens'), isFalse);
    });

    test('工具定义扁平格式 + tool_choice + parallel_tool_calls', () {
      final body = adapter.buildRequestBody(
        const LlmRequest(
          baseUrl: 'https://api.openai.com',
          modelId: 'gpt-6-astra',
          messages: [
            {'role': 'user', 'content': 'hi'},
          ],
          tools: [
            ToolDefinition(
              name: 'search',
              description: '搜索',
              parameters: {
                'type': 'object',
                'properties': {
                  'q': {'type': 'string'},
                },
                'required': ['q'],
              },
            ),
          ],
          toolChoice: ToolChoice.required,
        ),
        stream: false,
      );

      final tool = (body['tools'] as List).single as Map<String, dynamic>;
      // Responses 扁平结构：无嵌套 function 对象
      expect(tool, {
        'type': 'function',
        'name': 'search',
        'description': '搜索',
        'parameters': {
          'type': 'object',
          'properties': {
            'q': {'type': 'string'},
          },
          'required': ['q'],
        },
      });
      expect(body['tool_choice'], 'required');
      expect(body['parallel_tool_calls'], isTrue);
    });

    test('response_format → text.format（json_schema）', () {
      final body = adapter.buildRequestBody(
        const LlmRequest(
          baseUrl: 'https://api.openai.com',
          modelId: 'gpt-6-astra',
          messages: [
            {'role': 'user', 'content': 'hi'},
          ],
          responseFormat: LlmResponseFormatJsonSchema(
            name: 'out',
            schema: {
              'type': 'object',
              'properties': {
                'v': {'type': 'string'},
              },
            },
          ),
        ),
        stream: false,
      );

      final format = (body['text'] as Map<String, dynamic>)['format']
          as Map<String, dynamic>;
      expect(format['type'], 'json_schema');
      expect(format['name'], 'out');
      expect(format['strict'], isTrue);
    });
  });

  group('parseResponse', () {
    test('message + reasoning 摘要 + function_call + usage 映射', () {
      final parsed = adapter.parseResponse({
        'status': 'completed',
        'output': [
          {
            'type': 'reasoning',
            'summary': [
              {'type': 'summary_text', 'text': '先分析一下'},
            ],
          },
          {
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': '答案是 42'},
            ],
          },
          {
            'type': 'function_call',
            'id': 'fc_1',
            'call_id': 'call_9',
            'name': 'search',
            'arguments': '{"q":"x"}',
          },
        ],
        'usage': {
          'input_tokens': 100,
          'output_tokens': 50,
          'total_tokens': 150,
          'input_tokens_details': {'cached_tokens': 20},
        },
      });

      expect(parsed.content, '答案是 42');
      expect(parsed.reasoningContent, '先分析一下');
      expect(parsed.toolCalls!.length, 1);
      expect(parsed.toolCalls![0].id, 'call_9');
      expect(parsed.toolCalls![0].name, 'search');
      expect(parsed.toolCalls![0].arguments['q'], 'x');
      expect(parsed.usage!.promptTokens, 100);
      expect(parsed.usage!.completionTokens, 50);
      expect(parsed.usage!.totalTokens, 150);
      expect(parsed.usage!.cacheReadTokens, 20);
      expect(parsed.finishReason, isNull);
    });

    test('incomplete → finishReason=length（截断诊断词表统一）', () {
      final parsed = adapter.parseResponse(<String, dynamic>{
        'status': 'incomplete',
        'incomplete_details': <String, dynamic>{'reason': 'max_output_tokens'},
        'output': <dynamic>[],
      });

      expect(parsed.finishReason, 'length');
    });

    test('failed → finishReason=failed 上抛', () {
      final parsed = adapter.parseResponse(<String, dynamic>{
        'status': 'failed',
        'error': <String, dynamic>{'code': 'server_error', 'message': 'boom'},
        'output': <dynamic>[],
      });

      expect(parsed.finishReason, 'failed');
    });
  });

  group('vision 消息转换', () {
    test('image_url（data: 与 https:）→ input_image parts', () {
      final body = adapter.buildRequestBody(
        const LlmRequest(
          baseUrl: 'https://api.openai.com',
          modelId: 'gpt-6-astra',
          messages: [
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': '看图'},
                {
                  'type': 'image_url',
                  'image_url': {'url': 'data:image/png;base64,AAA'},
                },
                {
                  'type': 'image_url',
                  'image_url': {'url': 'https://example.com/a.png'},
                },
              ],
            },
          ],
        ),
        stream: false,
      );

      final content = ((body['input'] as List).single
          as Map<String, dynamic>)['content'] as List;
      expect(content[0], {'type': 'input_text', 'text': '看图'});
      expect(content[1], {
        'type': 'input_image',
        'image_url': 'data:image/png;base64,AAA',
      });
      expect(content[2], {
        'type': 'input_image',
        'image_url': 'https://example.com/a.png',
      });
    });
  });
}
