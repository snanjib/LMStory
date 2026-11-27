import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/llm/llm_content_block.dart';
import 'package:lmstory/features/advanced/data/agent_durable_event_sink.dart';
import 'package:lmstory/features/advanced/data/director_step_surface_source.dart';
import 'package:lmstory/features/advanced/data/repositories/agent_event_log_repository.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_event_source.dart';
import 'package:lmstory/features/advanced/domain/services/surface_representations.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';

/// 跨脑清表示 + 完整性守卫（surface_representations）。
void main() {
  AgentDurableEvent assistantEvent({
    Map<String, dynamic>? source,
    String text = '播报',
  }) =>
      AgentDurableEvent(
        type: AgentEventTypes.assistantMessage,
        surfaceOp: AgentSurfaceOpKind.append,
        data: {
          'text': text,
          'reasoningContent': '思考串',
          'toolCalls': [
            {
              'id': 'c1',
              'name': 'query_facts',
              'args': {'q': 'x'},
              'thoughtSignature': 'SIG',
            },
          ],
          'thinkingBlocks': [
            {'thinking': 't', 'signature': 's'},
          ],
          'contentBlocks': [
            {'type': 'thinking', 'thinking': 't', 'signature': 's'},
            {'type': 'text', 'text': '播报'},
            {
              'type': 'tool_use',
              'id': 'c1',
              'name': 'query_facts',
              'input': {'q': 'x'},
            },
          ],
          'turn': 1,
          if (source != null) 'source': source,
        },
      );

  const sourceA = {
    'protocol': 'anthropic',
    'modelId': 'claude-x',
    'endpoint': 'fp-aaaaaaaaaaaaaaaa',
    'encoding': 'utf8-v1',
  };
  const sourceB = {
    'protocol': 'geminiNative',
    'modelId': 'gemini-y',
    'endpoint': 'fp-bbbbbbbbbbbbbbbb',
    'encoding': 'utf8-v1',
  };

  group('stripUnreplayableRepresentations', () {
    test('跨脑：思考/签名两种表示同步清除，正文与调用参数保留', () {
      final stripped = stripUnreplayableRepresentations(
        events: [assistantEvent(source: sourceA)],
        currentSource: AgentEventSourceMeta.fromData({
          'source': sourceB,
        }),
        thinkingReplayAllowed: true,
      );
      final data = stripped.single.data;
      expect(data['reasoningContent'], isNull);
      expect(data.containsKey('thinkingBlocks'), isFalse);
      // contentBlocks 滤掉 thinking 块后保留 text/tool_use（块序不重排）
      final blocks =
          (data['contentBlocks'] as List).cast<Map<String, dynamic>>();
      expect(blocks, hasLength(2));
      expect(blocks.any((b) => b['type'] == 'thinking'), isFalse);
      final toolCall =
          (data['toolCalls'] as List).cast<Map<String, dynamic>>().single;
      expect(toolCall['thoughtSignature'], isNull);
      // 正文与调用事实保留
      expect(data['text'], '播报');
      expect(toolCall['id'], 'c1');
      expect(toolCall['args'], {'q': 'x'});
    });

    test('同源且思考回传允许：原样保留（含签名与思考块）', () {
      final events = [assistantEvent(source: sourceA)];
      final stripped = stripUnreplayableRepresentations(
        events: events,
        currentSource: AgentEventSourceMeta.fromData({
          'source': sourceA,
        }),
        thinkingReplayAllowed: true,
      );
      final kept = stripped.single.data;
      expect(kept['thinkingBlocks'], isNotNull);
      final keptCall =
          (kept['toolCalls'] as List).cast<Map<String, dynamic>>().single;
      expect(keptCall['thoughtSignature'], 'SIG');
      // 入参不被改写（纯函数）
      expect(events.single.data['thinkingBlocks'], isNotNull);
    });

    test('同源但当前轮思考关闭：同样清除（思考不跨设置回传）', () {
      final stripped = stripUnreplayableRepresentations(
        events: [assistantEvent(source: sourceA)],
        currentSource: AgentEventSourceMeta.fromData({
          'source': sourceA,
        }),
        thinkingReplayAllowed: false,
      );
      final data = stripped.single.data;
      expect(data.containsKey('thinkingBlocks'), isFalse);
      final call =
          (data['toolCalls'] as List).cast<Map<String, dynamic>>().single;
      expect(call['thoughtSignature'], isNull);
    });

    test('事件来源未知（无 source 键/旧编码）→ 清除（不冒充同源）', () {
      final stripped = stripUnreplayableRepresentations(
        events: [assistantEvent(source: const {})],
        currentSource: AgentEventSourceMeta.fromData({
          'source': sourceA,
        }),
        thinkingReplayAllowed: true,
      );
      expect(stripped.single.data.containsKey('thinkingBlocks'), isFalse);
    });

    test('当前来源未知 → 全部按跨脑处理', () {
      final stripped = stripUnreplayableRepresentations(
        events: [assistantEvent(source: sourceA)],
        currentSource: null,
        thinkingReplayAllowed: true,
      );
      expect(stripped.single.data.containsKey('thinkingBlocks'), isFalse);
    });

    test('非 assistant 事件原样保留', () {
      final user = AgentDurableEvent(
        type: AgentEventTypes.userMessage,
        surfaceOp: AgentSurfaceOpKind.append,
        data: {'content': 'u', 'turn': 1},
      );
      final stripped = stripUnreplayableRepresentations(
        events: [user],
        currentSource: null,
        thinkingReplayAllowed: true,
      );
      expect(stripped.single, same(user));
    });
  });

  group('validateSurfaceIntegrity', () {
    test('完整配对通过', () {
      final violation = validateSurfaceIntegrity([
        AgentMessage.user('u'),
        AgentMessage.assistant(
          text: '查',
          toolCalls: [
            const AgentToolCall(id: 'c1', name: 'q', arguments: {}),
          ],
        ),
        AgentMessage.toolResult(toolCallId: 'c1', content: 'ok'),
        AgentMessage.assistant(text: '正文'),
      ]);
      expect(violation, isNull);
    });

    test('孤儿 tool 结果（无先前声明）违例', () {
      expect(
        validateSurfaceIntegrity([
          AgentMessage.user('u'),
          AgentMessage.toolResult(toolCallId: 'c9', content: 'x'),
        ]),
        contains('orphan-tool-result'),
      );
    });

    test('悬空 tool 调用（无后续结果）违例', () {
      expect(
        validateSurfaceIntegrity([
          AgentMessage.assistant(
            toolCalls: [
              const AgentToolCall(id: 'c1', name: 'q', arguments: {}),
            ],
          ),
        ]),
        contains('dangling-tool-call'),
      );
    });

    test('重复 callId 违例（不猜配对）', () {
      expect(
        validateSurfaceIntegrity([
          AgentMessage.assistant(
            toolCalls: [
              const AgentToolCall(id: 'c1', name: 'q', arguments: {}),
            ],
          ),
          AgentMessage.toolResult(toolCallId: 'c1', content: 'ok'),
          AgentMessage.assistant(
            toolCalls: [
              const AgentToolCall(id: 'c1', name: 'q', arguments: {}),
            ],
          ),
        ]),
        contains('duplicate-call-id'),
      );
    });

    test('双表示不一致违例（平行调用与块 tool_use 不齐）', () {
      expect(
        validateSurfaceIntegrity([
          AgentMessage.assistant(
            text: '查',
            toolCalls: [
              const AgentToolCall(id: 'c1', name: 'q', arguments: {}),
            ],
            contentBlocks: [
              const LlmTextContentBlock(text: '查'),
              const LlmToolUseContentBlock(
                toolCallId: 'c1',
                name: 'q',
                arguments: {},
              ),
              const LlmToolUseContentBlock(
                toolCallId: 'c2',
                name: 'q',
                arguments: {},
              ),
            ],
          ),
          AgentMessage.toolResult(toolCallId: 'c1', content: 'ok'),
          AgentMessage.toolResult(toolCallId: 'c2', content: 'ok'),
        ]),
        contains('representation-mismatch'),
      );
    });
  });

  group('投影源守卫集成（违例 fail-closed + 留痕）', () {
    late AppDatabase db;
    late AgentEventLogRepository repo;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repo = AgentEventLogRepository(database: db);
    });

    tearDown(() async => db.close());

    test('账本含悬空调用 → project 抛违例并落 surface/guard', () async {
      // 无占位结果的悬空调用（模拟取消未配对且恢复器未跑的账本）
      await repo.appendAll('s1', [
        AgentDurableEvent(
          type: AgentEventTypes.modeEpoch,
          data: {'phase': 'enter', 'epochId': 'e1', 'status': 'pending'},
        ),
        AgentDurableEvent(
          type: AgentEventTypes.modeEpoch,
          data: {
            'phase': 'enter',
            'epochId': 'e1',
            'status': 'complete',
            'captureCount': 0,
          },
        ),
        AgentDurableEvent(
          type: AgentEventTypes.userMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': 'u', 'turn': 1, 'attemptId': 'a1'},
        ),
        AgentDurableEvent(
          type: AgentEventTypes.assistantMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: <String, dynamic>{
            'text': null,
            'toolCalls': [
              <String, dynamic>{
                'id': 'c1',
                'name': 'query_facts',
                'args': <String, dynamic>{},
              },
            ],
            'turn': 1,
            'attemptId': 'a1',
          },
        ),
      ]);
      final sink = DurableAgentEventSink(
        repository: repo,
        sessionId: 's1',
        turnNumber: 1,
      );
      final source = DirectorStepSurfaceSource(
        durableSink: sink,
        repository: repo,
        sessionId: 's1',
      );
      await expectLater(
        source.project(),
        throwsA(isA<AgentSurfaceIntegrityException>()),
      );
      final events = await repo.readEvents('s1');
      final guard = events.where((e) => e.type == AgentEventTypes.surfaceGuard);
      expect(guard, isNotEmpty);
      expect(guard.single.data['kind'], 'surface-integrity');
      expect(guard.single.data['detail'], contains('dangling-tool-call'));
    });
  });
}
