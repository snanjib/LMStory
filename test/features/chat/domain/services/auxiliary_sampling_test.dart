import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/services/compaction_streamer.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

void main() {
  test('压缩流：温度统一键普通模型 0.3，禁发名单模型 null', () async {
    final llm = _StreamStub();
    final streamer = CompactionStreamer(llmService: llm);
    final messages = <ChatMessage>[
      ChatMessage(
        messageId: 'm1',
        sessionId: 's1',
        role: 'user',
        content: 'hi',
        createdAt: DateTime(2026),
      ),
    ];

    await streamer.stream(
      config: const SummaryConfig(
        baseUrl: 'https://a.com',
        apiKey: 'k',
        modelId: 'deepseek-chat',
      ),
      messages: messages,
      onTextDelta: (_) async {},
      onComplete: (_, __) async {},
      onError: (_) async {},
    );
    expect(llm.lastRequest!.temperature, 0.3);

    await streamer.stream(
      config: const SummaryConfig(
        baseUrl: 'https://a.com',
        apiKey: 'k',
        modelId: 'kimi-k2.6',
      ),
      messages: messages,
      onTextDelta: (_) async {},
      onComplete: (_, __) async {},
      onError: (_) async {},
    );
    expect(llm.lastRequest!.temperature, isNull);
  });
}

class _StreamStub implements LlmService {
  LlmRequest? lastRequest;

  @override
  Future<LlmResponse> chat(LlmRequest request) async {
    lastRequest = request;
    return const LlmResponse(content: 'summary');
  }

  @override
  Stream<LlmStreamEvent> streamChat(LlmRequest request) {
    lastRequest = request;
    return const Stream<LlmStreamEvent>.empty();
  }
}
