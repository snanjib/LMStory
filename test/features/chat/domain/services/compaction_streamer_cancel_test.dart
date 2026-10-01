import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/network/http_client_types.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/services/compaction_streamer.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// 压缩流取消竞态——取消必须静默中止（既不算成功
/// 也不算失败），onComplete 在收尾前还有最后一道检查（计划 §4 风险4）。
void main() {
  group('CompactionStreamer 取消', () {
    final messages = [
      ChatMessage(
        messageId: 'm1',
        sessionId: 's1',
        role: 'user',
        content: '你好',
        createdAt: DateTime(2026),
      ),
      ChatMessage(
        messageId: 'm2',
        sessionId: 's1',
        role: 'assistant',
        content: '你好！',
        createdAt: DateTime(2026),
      ),
    ];

    const config = SummaryConfig(
      baseUrl: 'http://localhost',
      apiKey: 'k',
      modelId: 'm',
    );

    test('事件间取消：后续事件与 onComplete/onError 全部静默', () async {
      final deltas = <String>[];
      var completed = false;
      var errored = false;
      final token = CancellationToken();

      final streamer = CompactionStreamer(
        llmService: _ScriptedLlmService((request) async* {
          yield const LlmTextDelta('a');
          // 在两个事件之间取消（模拟用户点停止键）
          token.cancel();
          yield const LlmTextDelta('b');
          yield const LlmStreamDone();
        }),
        logger: const Logger('test'),
      );

      await streamer.stream(
        config: config,
        messages: messages,
        cancelToken: token,
        onTextDelta: (d) async => deltas.add(d),
        onComplete: (_, __) async => completed = true,
        onError: (_) async => errored = true,
      );

      expect(deltas, ['a'], reason: '取消后不应再处理后续事件');
      expect(completed, isFalse, reason: '取消≠成功：不得落摘要/压缩点');
      expect(errored, isFalse, reason: '取消≠失败：不得标错误/触发冷却');
    });

    test('进入前已取消：零回调直接返回', () async {
      final deltas = <String>[];
      var completed = false;
      var errored = false;
      final token = CancellationToken()..cancel();

      final streamer = CompactionStreamer(
        llmService: _ScriptedLlmService((request) async* {
          yield const LlmTextDelta('a');
          yield const LlmStreamDone();
        }),
        logger: const Logger('test'),
      );

      await streamer.stream(
        config: config,
        messages: messages,
        cancelToken: token,
        onTextDelta: (d) async => deltas.add(d),
        onComplete: (_, __) async => completed = true,
        onError: (_) async => errored = true,
      );

      expect(deltas, isEmpty);
      expect(completed, isFalse);
      expect(errored, isFalse);
    });

    test('未取消路径不受影响：正常 onComplete', () async {
      var completed = false;
      final streamer = CompactionStreamer(
        llmService: _ScriptedLlmService((request) async* {
          yield const LlmTextDelta('摘要');
          yield const LlmStreamDone();
        }),
        logger: const Logger('test'),
      );

      await streamer.stream(
        config: config,
        messages: messages,
        onTextDelta: (_) async {},
        onComplete: (summary, __) async {
          completed = summary == '摘要';
        },
        onError: (_) async => fail('不应报错'),
      );

      expect(completed, isTrue);
    });
  });
}

/// 脚本化 LlmService：仅实现 streamChat（本测试面）
class _ScriptedLlmService implements LlmService {
  _ScriptedLlmService(this._script);

  final Stream<LlmStreamEvent> Function(LlmRequest) _script;

  @override
  Stream<LlmStreamEvent> streamChat(LlmRequest request) => _script(request);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}
