import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_llm_gateway.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/llm/tool_calling/provider_tool_capabilities.dart';
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';
import 'package:lmstory/core/network/llm_adapters/anthropic_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/openai_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/responses_adapter.dart';
import 'package:lmstory/features/advanced/domain/services/compaction_planning.dart';
import 'package:lmstory/features/chat/data/agent/llm_service_agent_gateway.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';

/// 真实链预算保护：本地假 transport（无网络）→ 生产解析器（适配器
/// parseStream/parseResponse）→ 生产网关（LlmServiceAgentGateway，三表示
/// 聚合）→ AgentMessage（runner 字段映射同形）→ 真实适配器最终 body 与
/// wire-map 估算对拍。同一思考 payload 在最终 body 的出现次数必须与
/// 估算口径一致：Anthropic 结构化块计一次、Responses 明文不计、
/// OpenAI 兼容明文计一次。
class _LocalParsedService implements LlmService {
  _LocalParsedService(this.payload);
  final String payload;
  bool usedStreaming = false;
  bool usedComplete = false;

  @override
  Stream<LlmStreamEvent> streamChat(LlmRequest request) {
    usedStreaming = true;
    return AnthropicAdapter().parseStream(
      Stream.fromIterable([
        _event('content_block_start', {
          'type': 'content_block_start',
          'index': 0,
          'content_block': {
            'type': 'thinking',
            'thinking': payload,
            'signature': 'synthetic-sig',
          },
        }),
        _event('content_block_stop', {
          'type': 'content_block_stop',
          'index': 0,
        }),
        _event('content_block_start', {
          'type': 'content_block_start',
          'index': 1,
          'content_block': {'type': 'text', 'text': 'ok'},
        }),
        _event('content_block_stop', {
          'type': 'content_block_stop',
          'index': 1,
        }),
        _event('message_stop', {'type': 'message_stop'}),
      ]),
    );
  }

  @override
  Future<LlmResponse> chat(LlmRequest request) async {
    usedComplete = true;
    return AnthropicAdapter().parseResponse({
      'content': [
        {'type': 'thinking', 'thinking': payload, 'signature': 'synthetic-sig'},
        {'type': 'text', 'text': 'ok'},
      ],
      'stop_reason': 'end_turn',
    });
  }
}

String _event(String name, Map<String, dynamic> value) =>
    'event: $name\ndata: ${jsonEncode(value)}\n\n';

/// runner 的 response→AgentMessage 字段映射（agent_runner 同形：三表示
/// 一并构造，聚合 reasoningContent 与结构化块并存）
AgentMessage _asRunnerAssistant(AgentStepResponse response) =>
    AgentMessage.assistant(
      text: response.text,
      toolCalls: response.toolCalls.isEmpty ? null : response.toolCalls,
      reasoningContent: response.reasoningContent,
      thinkingBlocks: response.thinkingBlocks,
      contentBlocks: response.contentBlocks,
    );

LlmRequest _request(AgentMessage message, LlmProtocol protocol) => LlmRequest(
      baseUrl: 'https://synthetic.invalid',
      apiKey: 'unused',
      modelId: 'synthetic-model',
      protocol: protocol,
      maxTokens: 1000,
      messages: [
        message.toRequestMap(AgentWireOptions.forProtocolName(protocol.name)),
      ],
    );

void main() {
  for (final streaming in [true, false]) {
    test(
      'Anthropic parsed ${streaming ? "SSE" : "JSON"} gateway thinking counted once',
      () async {
        final payload = 'p' * 20000;
        final service = _LocalParsedService(payload);
        final response = await LlmServiceAgentGateway(
          llmService: service,
          capabilitiesOverride: streaming
              ? ProviderToolCapabilities.full
              : ProviderToolCapabilities.conservativeRelay,
        ).completeStep(
          endpoint: const AgentModelEndpoint(
            baseUrl: 'https://synthetic.invalid',
            modelId: 'synthetic-model',
            protocol: 'anthropic',
          ),
          request: const AgentStepRequest(
            messages: [],
            tools: [
              ToolDefinition(
                name: 'synthetic_tool',
                description: 'synthetic',
                parameters: {'type': 'object'},
              ),
            ],
            config: AgentCallConfig(),
          ),
          cancellation: AgentCancellationToken(),
        );
        expect(service.usedStreaming, streaming);
        expect(service.usedComplete, !streaming);
        // 网关三表示并存（生产形态）：聚合明文 + 结构化块 + 有序块
        expect(response.reasoningContent, payload);
        expect(response.thinkingBlocks!.single.thinking, payload);
        expect(response.contentBlocks, hasLength(2));
        final message = _asRunnerAssistant(response);
        final body = AnthropicAdapter().buildRequestBody(
          _request(message, LlmProtocol.anthropic),
          stream: false,
        );
        // 最终 body 同一 payload 恰一次（结构化块），聚合明文被丢弃
        expect(jsonEncode(body).split(payload).length - 1, 1);
        final chars = surfaceInputChars(
          [message],
          options: AgentWireOptions.forProtocolName('anthropic'),
        );
        // 估算与 body 同源：payload 计入（保留的合法签名思考）且只计一次
        expect(chars, greaterThanOrEqualTo(payload.length));
        expect(chars, lessThan(payload.length + 2000));
      },
    );
  }

  test('Responses discarded plaintext reasoning adds no input material', () {
    final payload = 'r' * 20000;
    final response = ResponsesAdapter().parseResponse({
      'output': [
        {
          'type': 'reasoning',
          'summary': [
            {'type': 'summary_text', 'text': payload},
          ],
        },
        {
          'type': 'message',
          'content': [
            {'type': 'output_text', 'text': 'ok'},
          ],
        },
      ],
    });
    expect(response.reasoningContent, payload);
    final message = AgentMessage.assistant(
      text: response.content,
      reasoningContent: response.reasoningContent,
    );
    final body = ResponsesAdapter().buildRequestBody(
      _request(message, LlmProtocol.openaiResponses),
      stream: false,
    );
    // 最终 body 不含明文 reasoning（Responses 不回放）
    expect(jsonEncode(body), isNot(contains(payload)));
    final chars = surfaceInputChars(
      [message],
      options: AgentWireOptions.forProtocolName('openaiResponses'),
    );
    expect(chars, lessThan(2000));
  });

  test('OpenAI Chat actually sent plaintext reasoning remains counted', () {
    final payload = 'c' * 20000;
    final message =
        AgentMessage.assistant(text: 'ok', reasoningContent: payload);
    final body = OpenAiAdapter().buildRequestBody(
      _request(message, LlmProtocol.openaiCompatible),
      stream: false,
    );
    // OpenAI 兼容端点原样透传 reasoning_content：body 恰一次、估算计入
    expect(jsonEncode(body).split(payload).length - 1, 1);
    final chars = surfaceInputChars(
      [message],
      options: AgentWireOptions.forProtocolName('openaiCompatible'),
    );
    expect(chars, greaterThanOrEqualTo(payload.length));
    expect(chars, lessThan(payload.length + 2000));
  });
}
