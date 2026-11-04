import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/llm/reasoning_effort.dart';
import 'package:lmstory/core/llm/tool_calling/tool_choice.dart';
import 'package:lmstory/core/network/llm_adapters/anthropic_compat_options.dart';
import 'package:lmstory/features/chat/data/datasources/negotiating_llm_service.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';

class _ScriptedLlmService implements LlmService {
  _ScriptedLlmService({
    this.streamScripts = const [],
    this.chatScripts = const [],
  });

  final List<Stream<LlmStreamEvent> Function(LlmRequest)> streamScripts;
  final List<Future<LlmResponse> Function(LlmRequest)> chatScripts;
  final List<LlmRequest> requests = [];

  @override
  Stream<LlmStreamEvent> streamChat(LlmRequest request) {
    requests.add(request);
    final index = requests.length - 1;
    return streamScripts[index](request);
  }

  @override
  Future<LlmResponse> chat(LlmRequest request) {
    requests.add(request);
    final index = requests.length - 1;
    return chatScripts[index](request);
  }
}

LlmRequest _request({
  LlmProtocol protocol = LlmProtocol.anthropic,
  ToolChoice? toolChoice,
  double? temperature,
  ReasoningEffort? reasoningEffort,
  List<Map<String, dynamic>> messages = const [
    {'role': 'user', 'content': 'hi'},
  ],
}) =>
    LlmRequest(
      baseUrl: 'https://api.anthropic.com',
      apiKey: 'k',
      modelId: 'claude-opus-5-5',
      messages: messages,
      protocol: protocol,
      toolChoice: toolChoice,
      temperature: temperature,
      reasoningEffort: reasoningEffort,
    );

void main() {
  test('工具选择被 400 拒绝 → 一次性降级 auto 后重发', () async {
    final inner = _ScriptedLlmService(
      streamScripts: [
        (_) => Stream.fromIterable(const [
              LlmStreamError(
                'tool_choice: type "tool" and "any" are not supported',
                code: 'BAD_REQUEST',
              ),
            ]),
        (_) => Stream.fromIterable(const [
              LlmTextDelta('ok'),
              LlmStreamDone(),
            ]),
      ],
    );
    final service = NegotiatingLlmService(inner: inner);

    final events = await service
        .streamChat(_request(toolChoice: ToolChoice.required))
        .toList();

    expect(events.whereType<LlmTextDelta>().single.content, 'ok');
    expect(inner.requests, hasLength(2));
    expect(
      inner.requests.last.providerOptions?[kAnthropicToolChoiceAutoInternal],
      isTrue,
    );
  });

  test('已产出内容后不再重试', () async {
    final inner = _ScriptedLlmService(
      streamScripts: [
        (_) => Stream.fromIterable(const [
              LlmTextDelta('partial'),
              LlmStreamError(
                'tool_choice: type "any" is not supported',
                code: 'BAD_REQUEST',
              ),
            ]),
      ],
    );
    final service = NegotiatingLlmService(inner: inner);

    final events = await service
        .streamChat(_request(toolChoice: ToolChoice.required))
        .toList();

    expect(events, hasLength(2));
    expect(events.first, isA<LlmTextDelta>());
    expect(events.last, isA<LlmStreamError>());
    expect(inner.requests, hasLength(1));
  });

  test('非 Anthropic 协议完全直通', () async {
    final inner = _ScriptedLlmService(
      streamScripts: [
        (_) => Stream.fromIterable(const [
              LlmStreamError('temperature invalid', code: 'BAD_REQUEST'),
            ]),
      ],
    );
    final service = NegotiatingLlmService(inner: inner);

    final events = await service
        .streamChat(_request(protocol: LlmProtocol.openaiCompatible))
        .toList();

    expect(events.single, isA<LlmStreamError>());
    expect(inner.requests, hasLength(1));
  });

  test('非流式 400 同样一次性降级', () async {
    final inner = _ScriptedLlmService(
      chatScripts: [
        (_) async => throw const AppHttpException(
              'Chat request failed with status 400',
              statusCode: 400,
              responseBody: 'adaptive thinking is not supported on this model',
            ),
        (_) async => const LlmResponse(content: 'ok'),
      ],
    );
    final service = NegotiatingLlmService(inner: inner);

    final response = await service.chat(
      _request(reasoningEffort: ReasoningEffort.high),
    );

    expect(response.content, 'ok');
    expect(inner.requests, hasLength(2));
    expect(
      inner.requests.last.providerOptions?[kAnthropicDropThinkingInternal],
      isTrue,
    );
  });

  test('thinking block 签名 400 → 剥离历史 thinking 后重发', () async {
    final inner = _ScriptedLlmService(
      chatScripts: [
        (_) async => throw const AppHttpException(
              'Chat request failed with status 400',
              statusCode: 400,
              responseBody: 'Invalid `signature` in `thinking` block. '
                  'The block is bound to a different conversation.',
            ),
        (_) async => const LlmResponse(content: 'ok'),
      ],
    );
    final service = NegotiatingLlmService(inner: inner);

    final response = await service.chat(
      _request(
        messages: const [
          {'role': 'user', 'content': 'u1'},
          {
            'role': 'assistant',
            'content': 'a1',
            'thinkingBlocks': [
              {'thinking': 't1', 'signature': 's1'},
            ],
            'tool_calls': [
              {
                'id': 'call_1',
                'type': 'function',
                'function': {'name': 'echo', 'arguments': '{}'},
              },
            ],
          },
          {'role': 'tool', 'tool_call_id': 'call_1', 'content': 'r1'},
          {
            'role': 'assistant',
            'thinkingBlocks': [
              {'thinking': 't2', 'signature': 's2'},
            ],
          },
          {'role': 'user', 'content': 'u2'},
        ],
      ),
    );

    expect(response.content, 'ok');
    expect(inner.requests, hasLength(2));
    final retried = inner.requests.last.messages;
    expect(retried, hasLength(4));
    final assistant = retried[1];
    expect(assistant.containsKey('thinkingBlocks'), isFalse);
    expect(assistant['tool_calls'], isNotNull);
  });
}
