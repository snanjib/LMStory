import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/llm/tool_calling/tool_choice.dart';
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';
import 'package:lmstory/core/network/llm_adapters/deepseek_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/openai_adapter.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// DeepSeekAdapter 兼容性降级测试
///
/// **背景**：DeepSeek 官方 API 不支持以下两个 OpenAI 协议参数：
///   1. `tool_choice: "required"`（思考模式下返回 400：
///      "Thinking mode does not support this tool_choice"）
///   2. `parallel_tool_calls: true`（DeepSeek 仅支持串行调用，一次一个工具）
///
/// **适配策略**：[DeepSeekAdapter] 继承 [OpenAiAdapter]，重写
/// `buildRequestBody` 调用 super 后修正：
///   - 跳过发送 `tool_choice`（降级为默认 `auto`，配合强提示词约束保证工具被调用）
///   - 跳过发送 `parallel_tool_calls: true`（走串行调用，由
///     `SummarizePhaseHandler._runSingleToolCall` 兜底补调缺失工具）
///
/// **参考**：https://api-docs.deepseek.com/zh-cn/guides/tool_calls
void main() {
  late DeepSeekAdapter adapter;

  /// 构造最小可用的工具定义
  ToolDefinition dummyTool() {
    return const ToolDefinition(
      name: 'extract_event_summary',
      description: '提取事件摘要',
      parameters: {
        'type': 'object',
        'properties': {
          'summary': {'type': 'string'},
        },
        'required': ['summary'],
      },
    );
  }

  /// 构造最小可用的 LlmRequest
  LlmRequest buildRequest({
    required String baseUrl,
    required String modelId,
    ToolChoice? toolChoice,
    List<ToolDefinition>? tools,
    ReasoningEffort? reasoningEffort,
  }) {
    return LlmRequest(
      baseUrl: baseUrl,
      apiKey: 'sk-test',
      modelId: modelId,
      messages: const [
        {'role': 'user', 'content': 'hi'},
      ],
      tools: tools,
      toolChoice: toolChoice,
      reasoningEffort: reasoningEffort,
    );
  }

  setUp(() {
    adapter = DeepSeekAdapter();
  });

  group('isDeepSeekEndpoint 端点识别', () {
    test('DeepSeek 官方端点 → 识别为 true', () {
      expect(
        DeepSeekAdapter.isDeepSeekEndpoint(
          'https://api.deepseek.com',
          'deepseek-v4-pro',
        ),
        isTrue,
      );
    });

    test('DeepSeek beta 端点 → 识别为 true', () {
      expect(
        DeepSeekAdapter.isDeepSeekEndpoint(
          'https://api.deepseek.com/beta',
          'deepseek-chat',
        ),
        isTrue,
      );
    });

    test('第三方中转 + deepseek- 前缀 modelId → 识别为 true', () {
      expect(
        DeepSeekAdapter.isDeepSeekEndpoint(
          'https://some-relay.example.com',
          'deepseek-v4-pro',
        ),
        isTrue,
      );
    });

    test('OpenRouter 路由的 deepseek/xxx → 识别为 false', () {
      // OpenRouter 作为中间层会自行处理兼容性
      expect(
        DeepSeekAdapter.isDeepSeekEndpoint(
          'https://openrouter.ai/api/v1',
          'deepseek/deepseek-v4-pro',
        ),
        isFalse,
      );
    });

    test('大小写不敏感判定', () {
      expect(
        DeepSeekAdapter.isDeepSeekEndpoint(
          'https://API.DEEPSEEK.COM',
          'DeepSeek-V4-Pro',
        ),
        isTrue,
      );
    });

    test('非 DeepSeek 端点和模型 → 识别为 false', () {
      expect(
        DeepSeekAdapter.isDeepSeekEndpoint(
          'https://api.agnes-ai.com',
          'agnes-2.0-flash',
        ),
        isFalse,
      );
      expect(
        DeepSeekAdapter.isDeepSeekEndpoint(
          'https://api.openai.com',
          'gpt-5',
        ),
        isFalse,
      );
    });
  });

  group('tool_choice 兼容性降级', () {
    test('tool_choice=required → 不发送 tool_choice（降级为默认 auto）', () {
      final body = adapter.buildRequestBody(
        buildRequest(
          baseUrl: 'https://api.deepseek.com',
          modelId: 'deepseek-v4-pro',
          tools: [dummyTool()],
          toolChoice: ToolChoice.required,
        ),
        stream: false,
      );

      // 关键断言：tool_choice 字段不存在（降级为默认 auto）
      expect(
        body.containsKey('tool_choice'),
        isFalse,
        reason: 'DeepSeek 不支持 tool_choice:"required"，应降级为不发送',
      );
      // tools 字段仍应正常发送
      expect(body.containsKey('tools'), isTrue);
      expect(body['tools'], isA<List<dynamic>>());
    });

    test('tool_choice=auto → 仍发送 tool_choice=auto', () {
      final body = adapter.buildRequestBody(
        buildRequest(
          baseUrl: 'https://api.deepseek.com',
          modelId: 'deepseek-v4-pro',
          tools: [dummyTool()],
          toolChoice: ToolChoice.auto,
        ),
        stream: false,
      );

      // auto 是 DeepSeek 支持的值，应正常发送
      expect(body['tool_choice'], 'auto');
    });

    test('tool_choice=none → 仍发送 tool_choice=none', () {
      final body = adapter.buildRequestBody(
        buildRequest(
          baseUrl: 'https://api.deepseek.com',
          modelId: 'deepseek-v4-pro',
          toolChoice: ToolChoice.none,
        ),
        stream: false,
      );

      expect(body['tool_choice'], 'none');
    });
  });

  group('parallel_tool_calls 兼容性降级', () {
    test('tools + tool_choice=required → 不发送 parallel_tool_calls', () {
      final body = adapter.buildRequestBody(
        buildRequest(
          baseUrl: 'https://api.deepseek.com',
          modelId: 'deepseek-v4-pro',
          tools: [dummyTool()],
          toolChoice: ToolChoice.required,
        ),
        stream: false,
      );

      expect(
        body.containsKey('parallel_tool_calls'),
        isFalse,
        reason: 'DeepSeek 不支持 parallel_tool_calls，应跳过发送',
      );
    });

    test('tools + tool_choice=auto → 不发送 parallel_tool_calls', () {
      final body = adapter.buildRequestBody(
        buildRequest(
          baseUrl: 'https://api.deepseek.com',
          modelId: 'deepseek-v4-pro',
          tools: [dummyTool()],
          toolChoice: ToolChoice.auto,
        ),
        stream: false,
      );

      expect(
        body.containsKey('parallel_tool_calls'),
        isFalse,
        reason: 'DeepSeek 即使 tool_choice=auto 也应跳过 parallel_tool_calls',
      );
    });
  });

  group('保留能力（不应被降级）', () {
    test('thinking 参数应正常发送（DeepSeek-V3.2+ 支持思考+工具调用）', () {
      final body = adapter.buildRequestBody(
        buildRequest(
          baseUrl: 'https://api.deepseek.com',
          modelId: 'deepseek-v4-pro',
          reasoningEffort: ReasoningEffort.high,
        ),
        stream: true,
      );

      expect(
        body.containsKey('thinking'),
        isTrue,
        reason: 'DeepSeek-V3.2+ 支持思考+工具调用，思考参数不应被降级',
      );
      expect((body['thinking'] as Map<String, dynamic>)['type'], 'enabled');
      expect(body['reasoning_effort'], 'high');
    });

    test('tools 字段仍应正常发送', () {
      final body = adapter.buildRequestBody(
        buildRequest(
          baseUrl: 'https://api.deepseek.com',
          modelId: 'deepseek-v4-pro',
          tools: [dummyTool()],
          toolChoice: ToolChoice.required,
        ),
        stream: false,
      );

      expect(body.containsKey('tools'), isTrue);
      expect(body['tools'], isA<List<dynamic>>());
      expect((body['tools'] as List<dynamic>).length, 1);
    });

    test('messages/model/stream 等基础字段正常发送', () {
      final body = adapter.buildRequestBody(
        buildRequest(
          baseUrl: 'https://api.deepseek.com',
          modelId: 'deepseek-v4-pro',
        ),
        stream: false,
      );

      expect(body['model'], 'deepseek-v4-pro');
      expect(body['stream'], false);
      expect(body['messages'], isA<List<dynamic>>());
    });
  });

  group('核心场景：思考+工具调用同时启用（用户报错的精确场景）', () {
    test('DeepSeek-V4-Pro + thinking + tools + tool_choice=required → 仅降级工具参数',
        () {
      // 这是用户报错的精确场景：DeepSeek 思考模式 + 工具调用
      final body = adapter.buildRequestBody(
        buildRequest(
          baseUrl: 'https://api.deepseek.com',
          modelId: 'deepseek-v4-pro',
          tools: [dummyTool()],
          toolChoice: ToolChoice.required,
          reasoningEffort: ReasoningEffort.high,
        ),
        stream: true,
      );

      // 1. tool_choice 不应发送（降级为默认 auto）
      expect(body.containsKey('tool_choice'), isFalse);
      // 2. parallel_tool_calls 不应发送
      expect(body.containsKey('parallel_tool_calls'), isFalse);
      // 3. thinking 参数应正常发送（DeepSeek 思考模式支持工具调用）
      expect(body.containsKey('thinking'), isTrue);
      expect((body['thinking'] as Map<String, dynamic>)['type'], 'enabled');
      // 4. reasoning_effort 应正常发送
      expect(body['reasoning_effort'], 'high');
      // 5. tools 仍应正常发送
      expect(body.containsKey('tools'), isTrue);
    });
  });
}
