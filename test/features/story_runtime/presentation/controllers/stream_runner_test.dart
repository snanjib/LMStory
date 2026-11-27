import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/network/http_client.dart' show CancelledException;
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/story_runtime/presentation/controllers/stream_runner.dart';

/// StreamRunner 单元测试（Phase 6 Step 6.1 新增）
///
/// 验证 `runWithToolCall` 方法的工具调用事件处理：
/// - LlmToolCallComplete 优先采用
/// - 无 Complete 时累积 argsDelta 解析
/// - argsDelta 解析失败返回 fallbackText（让调用方尝试 JSON 降级）
/// - 无工具调用事件返回 null + fallbackText
/// - LlmStreamError 抛 StreamErrorException
/// - onTextDelta 回调
///
/// `run` 方法（标记/JSON 模式）的行为等价由现有集成测试覆盖（63 个测试），
/// 本文件只覆盖新增的 `runWithToolCall`。
void main() {
  group('StreamRunner.runWithToolCall', () {
    test('1. 收到 LlmToolCallComplete → arguments 采用 complete.arguments',
        () async {
      final llmService = _FakeLlmService([
        const LlmToolCallStart('call_1', 'extract_keywords'),
        const LlmToolCallArgs('call_1', '{"entities":'),
        const LlmToolCallArgs('call_1', '["古碑"]}'),
        const LlmToolCallComplete(
          toolCallId: 'call_1',
          name: 'extract_keywords',
          arguments: {
            'entities': ['古碑'],
          },
        ),
        const LlmStreamDone(),
      ]);
      final runner = StreamRunner(llmService: llmService);

      final result = await runner.runWithToolCall(
        request: _dummyRequest(),
      );

      expect(result.hasToolCall, isTrue);
      expect(result.arguments, {
        'entities': ['古碑'],
      });
      expect(result.fallbackText, isNull);
    });

    test('2. 无 Complete 但有累积 argsDelta → 解析为 Map', () async {
      // 部分 SSE 实现不发送 Complete 事件，只有 Start + Args 分片
      final llmService = _FakeLlmService([
        const LlmToolCallStart('call_1', 'extract_keywords'),
        const LlmToolCallArgs('call_1', '{"entities":["古碑"],'),
        const LlmToolCallArgs('call_1', '"events":["查看"]}'),
        const LlmStreamDone(),
      ]);
      final runner = StreamRunner(llmService: llmService);

      final result = await runner.runWithToolCall(request: _dummyRequest());

      expect(result.hasToolCall, isTrue);
      expect(result.arguments?['entities'], ['古碑']);
      expect(result.arguments?['events'], ['查看']);
    });

    test('3. argsDelta 解析失败 → 返回 fallbackText（降级链可处理）', () async {
      // argsDelta 拼接后非法 JSON（如分片乱序/截断）
      final llmService = _FakeLlmService([
        const LlmToolCallStart('call_1', 'extract_keywords'),
        const LlmToolCallArgs('call_1', '{"entities":'), // 缺闭合
        const LlmStreamDone(),
      ]);
      final runner = StreamRunner(llmService: llmService);

      final result = await runner.runWithToolCall(request: _dummyRequest());

      // 解析失败 → hasToolCall=false，原始文本作为 fallbackText 返回
      // 调用方可尝试 parseKeywords(fallbackText) 解析，或降级到 JSON 模式
      expect(result.hasToolCall, isFalse);
      expect(result.arguments, isNull);
      expect(result.fallbackText, '{"entities":');
    });

    test('4. 完全无工具调用事件 → arguments=null + fallbackText=累积文本', () async {
      // LLM 不支持 tools 参数，直接输出文本（JSON 格式）
      final llmService = _FakeLlmService([
        const LlmTextDelta('{"entities":["古碑"]}'),
        const LlmStreamDone(),
      ]);
      final runner = StreamRunner(llmService: llmService);

      final result = await runner.runWithToolCall(request: _dummyRequest());

      expect(result.hasToolCall, isFalse);
      expect(result.arguments, isNull);
      expect(result.fallbackText, '{"entities":["古碑"]}');
    });

    test('5. 收到 LlmStreamError → 抛 StreamErrorException', () async {
      final llmService = _FakeLlmService([
        const LlmToolCallStart('call_1', 'extract_keywords'),
        const LlmStreamError('connection reset'),
      ]);
      final runner = StreamRunner(llmService: llmService);

      expect(
        () => runner.runWithToolCall(request: _dummyRequest()),
        throwsA(isA<StreamErrorException>()),
      );
    });

    test('6. onTextDelta 回调被调用（无工具调用时的文本流式显示）', () async {
      final llmService = _FakeLlmService([
        const LlmTextDelta('{"entities":'),
        const LlmTextDelta('["古碑"]}'),
        const LlmStreamDone(),
      ]);
      final runner = StreamRunner(llmService: llmService);
      final accumulated = StringBuffer();

      await runner.runWithToolCall(
        request: _dummyRequest(),
        onTextDelta: accumulated.write,
      );

      expect(accumulated.toString(), '{"entities":["古碑"]}');
    });

    test('7. 多 toolCallId 场景：采用首个 toolCallId 的累积结果', () async {
      // 理论上 extracting/summarizing 只定义单工具，但 StreamRunner 支持多工具并发。
      // 本测试验证：多个 toolCallId 时，采用首个出现的 toolCallId 的累积 argsDelta。
      final llmService = _FakeLlmService([
        const LlmToolCallStart('call_1', 'extract_keywords'),
        const LlmToolCallArgs('call_1', '{"entities":["古碑"]}'),
        const LlmToolCallStart('call_2', 'other_tool'),
        const LlmToolCallArgs('call_2', '{"x":1}'),
        const LlmStreamDone(),
      ]);
      final runner = StreamRunner(llmService: llmService);

      final result = await runner.runWithToolCall(request: _dummyRequest());

      expect(result.hasToolCall, isTrue);
      expect(result.arguments?['entities'], ['古碑']);
    });

    test('8. 空事件流（仅 LlmStreamDone）→ arguments=null, fallbackText=null',
        () async {
      final llmService = _FakeLlmService([const LlmStreamDone()]);
      final runner = StreamRunner(llmService: llmService);

      final result = await runner.runWithToolCall(request: _dummyRequest());

      expect(result.hasToolCall, isFalse);
      expect(result.arguments, isNull);
      expect(result.fallbackText, isNull);
    });
  });

  group('并发流的资源归属', () {
    test('取消新流后旧工具调用继续接收参数片段', () async {
      final oldStream = _ControlledStream();
      final newStream = _ControlledStream();
      final runner = StreamRunner(
        llmService: _ControlledLlmService([oldStream, newStream]),
      );
      final oldResult = runner.runWithToolCall(request: _dummyRequest());
      oldStream
        ..add(const LlmToolCallStart('call_1', 'extract'))
        ..add(const LlmToolCallArgs('call_1', '{"key":'));
      final newResult = _outcome(_run(_RunKind.plain, runner, StringBuffer()));

      await runner.cancel();
      expect(await newResult, isA<CancelledException>());
      expect(runner.isCancelled, isTrue);
      oldStream
        ..add(const LlmToolCallArgs('call_1', '"value"}'))
        ..add(const LlmStreamDone());
      final result = await oldResult.timeout(const Duration(milliseconds: 300));
      expect(result.arguments, {'key': 'value'});
      expect(result.argumentsFor('extract'), {'key': 'value'});
      expect(runner.isCancelled, isTrue);
    });

    for (final kind in _RunKind.values) {
      for (final nextKind in _RunKind.values) {
        test('${kind.name} → ${nextKind.name}: 取消新流后旧流继续接收并完成', () async {
          final oldStream = _ControlledStream();
          final newStream = _ControlledStream();
          final service = _ControlledLlmService([oldStream, newStream]);
          final runner = StreamRunner(llmService: service);
          final oldDeltas = StringBuffer();
          final oldResult = _outcome(_run(kind, runner, oldDeltas));
          oldStream.add(const LlmTextDelta('before '));
          final newResult = _outcome(_run(nextKind, runner, StringBuffer()));

          await runner.cancel();
          expect(await newResult, isA<CancelledException>());
          expect(runner.isCancelled, isTrue);
          expect(service.requests[0].cancelToken?.isCancelled, isFalse);
          expect(service.requests[1].cancelToken?.isCancelled, isTrue);
          expect(oldStream.cancelCount, 0);
          oldStream
            ..add(const LlmTextDelta('after'))
            ..add(const LlmStreamDone());
          expect(
            await oldResult.timeout(
              const Duration(milliseconds: 300),
              onTimeout: () => TimeoutException('old run did not finish'),
            ),
            'before after',
          );
          expect(oldDeltas.toString(), 'before after');
          expect(oldStream.cancelCount, 1);
          expect(runner.isCancelled, isTrue);
        });

        for (final oldEnd in ['完成', '事件错误', '订阅错误']) {
          test('${kind.name} → ${nextKind.name}: 旧流$oldEnd后新流继续接收并完成',
              () async {
            final oldStream = _ControlledStream();
            final newStream = _ControlledStream();
            final service = _ControlledLlmService([oldStream, newStream]);
            final runner = StreamRunner(llmService: service);
            final newDeltas = StringBuffer();
            final oldResult = _outcome(_run(kind, runner, StringBuffer()));
            final newResult = _outcome(_run(nextKind, runner, newDeltas));

            oldStream.add(const LlmTextDelta('old reply'));
            if (oldEnd == '事件错误') {
              oldStream.add(const LlmStreamError('old failed'));
              expect(await oldResult, isA<StreamErrorException>());
            } else if (oldEnd == '订阅错误') {
              oldStream.controller.addError(StateError('old failed'));
              expect(await oldResult, isA<StateError>());
            } else {
              oldStream.add(const LlmStreamDone());
              expect(await oldResult, 'old reply');
            }

            expect(oldStream.cancelCount, 1);
            expect(newStream.cancelCount, 0);
            expect(runner.isStreaming, isTrue);
            expect(service.requests[1].cancelToken?.isCancelled, isFalse);
            newStream
              ..add(const LlmTextDelta('new reply'))
              ..add(const LlmStreamDone());
            expect(await newResult, 'new reply');
            expect(newDeltas.toString(), 'new reply');
            expect(runner.isStreaming, isFalse);
          });
        }
      }

      test('${kind.name}: 旧流完成后的取消等待中启动新流', () async {
        final oldStream = _ControlledStream(blockCancel: true);
        final newStream = _ControlledStream();
        final service = _ControlledLlmService([oldStream, newStream]);
        final runner = StreamRunner(llmService: service);
        final oldResult = _outcome(_run(kind, runner, StringBuffer()));

        oldStream
          ..add(const LlmTextDelta('old reply'))
          ..add(const LlmStreamDone());
        await oldStream.cancelStarted.future;

        final newDeltas = StringBuffer();
        final newResult = _outcome(_run(kind, runner, newDeltas));
        newStream.add(const LlmTextDelta('new reply'));
        oldStream.allowCancel.complete();
        expect(await oldResult, 'old reply');
        expect(runner.isStreaming, isTrue);
        expect(newStream.cancelCount, 0);
        expect(service.requests[1].cancelToken?.isCancelled, isFalse);
        newStream.add(const LlmStreamDone());
        expect(await newResult, 'new reply');
        expect(newDeltas.toString(), 'new reply');
        expect(runner.isStreaming, isFalse);
      });

      test('${kind.name}: 旧流收到完成事件后停止，新流仍可完成', () async {
        final oldStream = _ControlledStream(blockCancel: true);
        final newStream = _ControlledStream();
        final service = _ControlledLlmService([oldStream, newStream]);
        final runner = StreamRunner(llmService: service);
        final oldResult = _outcome(_run(kind, runner, StringBuffer()));

        oldStream
          ..add(const LlmTextDelta('old reply'))
          ..add(const LlmStreamDone());
        await oldStream.cancelStarted.future;
        final oldCancel = runner.cancel();
        expect(service.requests[0].cancelToken?.isCancelled, isTrue);

        runner.resetCancelled();
        final newResult = _outcome(_run(kind, runner, StringBuffer()));
        oldStream.allowCancel.complete();
        await oldCancel;
        expect(await oldResult, isA<CancelledException>());
        expect(runner.isStreaming, isTrue);
        expect(newStream.cancelCount, 0);
        newStream
          ..add(const LlmTextDelta('new reply'))
          ..add(const LlmStreamDone());
        expect(await newResult, 'new reply');
        expect(runner.isStreaming, isFalse);
      });

      for (final stopNew in [false, true]) {
        test('${kind.name}: 旧流取消等待中启动新流，新流可${stopNew ? '停止' : '完成'}', () async {
          final oldStream = _ControlledStream(blockCancel: true);
          final newStream = _ControlledStream();
          final service = _ControlledLlmService([oldStream, newStream]);
          final runner = StreamRunner(llmService: service);
          final oldResult = _outcome(_run(kind, runner, StringBuffer()));

          final oldCancel = runner.cancel();
          await oldStream.cancelStarted.future;
          expect(service.requests[0].cancelToken?.isCancelled, isTrue);

          runner.resetCancelled();
          final newDeltas = StringBuffer();
          final newResult = _outcome(_run(kind, runner, newDeltas));
          newStream.add(const LlmTextDelta('new reply'));
          expect(newDeltas.toString(), 'new reply');
          expect(service.requests[1].cancelToken?.isCancelled, isFalse);

          oldStream.allowCancel.complete();
          await oldCancel;
          expect(
            await oldResult.timeout(
              const Duration(milliseconds: 300),
              onTimeout: () => TimeoutException('old run did not finish'),
            ),
            isA<CancelledException>(),
          );
          expect(runner.isStreaming, isTrue);
          expect(newStream.cancelCount, 0);

          if (stopNew) {
            await runner.cancel();
            expect(service.requests[1].cancelToken?.isCancelled, isTrue);
            expect(
              await newResult.timeout(
                const Duration(milliseconds: 300),
                onTimeout: () => TimeoutException('new run did not stop'),
              ),
              isA<CancelledException>(),
            );
          } else {
            newStream.add(const LlmStreamDone());
            expect(await newResult, 'new reply');
          }
          expect(newStream.cancelCount, 1);
          expect(runner.isStreaming, isFalse);
        });
      }

      test('${kind.name}: cleanup 后旧调用结束且新流可完成', () async {
        final oldStream = _ControlledStream(blockCancel: true);
        final newStream = _ControlledStream();
        final service = _ControlledLlmService([oldStream, newStream]);
        final runner = StreamRunner(llmService: service);
        final oldResult = _outcome(_run(kind, runner, StringBuffer()));

        runner.cleanup();
        await oldStream.cancelStarted.future;
        expect(service.requests[0].cancelToken?.isCancelled, isTrue);
        final newResult = _outcome(_run(kind, runner, StringBuffer()));
        oldStream.allowCancel.complete();
        expect(
          await oldResult.timeout(
            const Duration(milliseconds: 300),
            onTimeout: () => TimeoutException('old run did not finish'),
          ),
          isA<CancelledException>(),
        );
        expect(runner.isStreaming, isTrue);
        expect(newStream.cancelCount, 0);
        newStream
          ..add(const LlmTextDelta('new reply'))
          ..add(const LlmStreamDone());
        expect(await newResult, 'new reply');
        expect(runner.isStreaming, isFalse);
      });

      if (kind == _RunKind.plain) {
        test('订阅回收失败时停止调用报告错误，旧流收尾不影响新流', () async {
          final oldStream = _ControlledStream(blockCancel: true);
          final newStream = _ControlledStream();
          final service = _ControlledLlmService([oldStream, newStream]);
          final runner = StreamRunner(llmService: service);
          final oldResult = _outcome(_run(kind, runner, StringBuffer()));

          final cancelOutcome = runner.cancel().then<Object>(
                (_) => 'cancelled',
                onError: (Object error, StackTrace stackTrace) => error,
              );
          await oldStream.cancelStarted.future;
          runner.resetCancelled();
          final newResult = _outcome(_run(kind, runner, StringBuffer()));
          oldStream.allowCancel.completeError(StateError('cleanup failed'));
          expect(await cancelOutcome, isA<StateError>());
          expect(await oldResult, isA<CancelledException>());
          expect(runner.isStreaming, isTrue);
          newStream
            ..add(const LlmTextDelta('new reply'))
            ..add(const LlmStreamDone());
          expect(await newResult, 'new reply');
        });
      }

      test('${kind.name}: 创建流同步出错后可启动新流', () async {
        final newStream = _ControlledStream();
        final runner = StreamRunner(llmService: _FailOnceLlmService(newStream));
        expect(
          await _outcome(_run(kind, runner, StringBuffer())),
          isA<StateError>(),
        );
        expect(runner.isStreaming, isFalse);

        final newResult = _outcome(_run(kind, runner, StringBuffer()));
        newStream
          ..add(const LlmTextDelta('new reply'))
          ..add(const LlmStreamDone());
        expect(await newResult, 'new reply');
        expect(runner.isStreaming, isFalse);
      });
    }
  });
}

/// 构造最小可用的 LlmRequest（runWithToolCall 不关心请求体内容，
/// 只用它触发 streamChat 调用）
LlmRequest _dummyRequest() {
  return const LlmRequest(
    baseUrl: 'https://api.example.com',
    modelId: 'test-model',
    messages: <Map<String, dynamic>>[],
  );
}

/// 假 LlmService：按预设事件序列发出 LlmStreamEvent 流
class _FakeLlmService implements LlmService {
  _FakeLlmService(this._events);
  final List<LlmStreamEvent> _events;

  @override
  Stream<LlmStreamEvent> streamChat(LlmRequest request) {
    // 用 async* 生成器模拟 SSE 流（按顺序发出事件）
    return Stream<LlmStreamEvent>.fromIterable(_events);
  }

  @override
  Future<LlmResponse> chat(LlmRequest request) async {
    throw UnimplementedError('runWithToolCall 测试不使用 chat');
  }
}

enum _RunKind { marked, plain, tool }

Future<String> _run(
  _RunKind kind,
  StreamRunner runner,
  StringBuffer deltas,
) async {
  switch (kind) {
    case _RunKind.marked:
      final result = await runner.run(
        request: _dummyRequest(),
        marker: '<<<END>>>',
        onDelta: deltas.write,
      );
      return result.displayText;
    case _RunKind.plain:
      final result = await runner.runPlainText(
        request: _dummyRequest(),
        onDelta: deltas.write,
      );
      return result.displayText;
    case _RunKind.tool:
      final result = await runner.runWithToolCall(
        request: _dummyRequest(),
        onTextDelta: deltas.write,
      );
      return result.fallbackText ?? '';
  }
}

Future<Object> _outcome(Future<String> result) => result.then<Object>(
      (value) => value,
      onError: (Object error, StackTrace stackTrace) => error,
    );

class _ControlledStream {
  _ControlledStream({bool blockCancel = false}) {
    if (!blockCancel) allowCancel.complete();
    controller = StreamController<LlmStreamEvent>(
      sync: true,
      onCancel: () {
        cancelCount++;
        if (!cancelStarted.isCompleted) cancelStarted.complete();
        return allowCancel.future;
      },
    );
  }

  final cancelStarted = Completer<void>();
  final allowCancel = Completer<void>();
  late final StreamController<LlmStreamEvent> controller;
  int cancelCount = 0;

  void add(LlmStreamEvent event) => controller.add(event);
}

class _ControlledLlmService implements LlmService {
  _ControlledLlmService(this.streams);

  final List<_ControlledStream> streams;
  final requests = <LlmRequest>[];

  @override
  Stream<LlmStreamEvent> streamChat(LlmRequest request) {
    requests.add(request);
    return streams[requests.length - 1].controller.stream;
  }

  @override
  Future<LlmResponse> chat(LlmRequest request) async =>
      throw UnimplementedError();
}

class _FailOnceLlmService implements LlmService {
  _FailOnceLlmService(this.stream);

  final _ControlledStream stream;
  var _failed = false;

  @override
  Stream<LlmStreamEvent> streamChat(LlmRequest request) {
    if (!_failed) {
      _failed = true;
      throw StateError('stream creation failed');
    }
    return stream.controller.stream;
  }

  @override
  Future<LlmResponse> chat(LlmRequest request) async =>
      throw UnimplementedError();
}
