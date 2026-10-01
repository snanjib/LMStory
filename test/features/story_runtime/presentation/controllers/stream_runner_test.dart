import 'package:flutter_test/flutter_test.dart';
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
