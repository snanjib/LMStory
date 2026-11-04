import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_events.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/services/agent_log_recovery.dart';

/// 真续跑前的 surface 尾部归一：协议配对 + 禁止 model 轮收尾。
void main() {
  AgentSurfaceProjection projectionOf(List<AgentMessage> messages) =>
      AgentSurfaceProjection(
        messages: messages,
        coreIndex: -1,
        lastSeq: 0,
      );

  AgentMessage assistantToolCall({String id = 'call_1'}) =>
      AgentMessage.assistant(
        toolCalls: [
          AgentToolCall(id: id, name: 'search_story', arguments: const {}),
        ],
      );

  group('resumeRepairEvents', () {
    test('末尾 assistant 文本 → 追加 user 续跑指令', () {
      final events = resumeRepairEvents(
        projection: projectionOf([
          AgentMessage.system('system'),
          AgentMessage.user('用户输入'),
          AgentMessage.assistant(text: '半截正文'),
        ]),
        textRepair: null,
        turn: 3,
        toolPlaceholderTitle: '中断占位',
      );

      expect(events, hasLength(1));
      final event = events.single;
      expect(event.type, AgentEventTypes.userMessage);
      expect(event.surfaceOp, AgentSurfaceOpKind.append);
      expect(
        event.data['source'],
        AgentInjectedMessageKinds.resumeContinuation,
      );
      expect(event.data['turn'], 3);
      expect(event.data['content'], contains('【续跑】'));
      expect(event.data['content'], contains('finish_round'));
    });

    test('末尾未配对 assistant tool call → 只补占位 tool/result', () {
      final events = resumeRepairEvents(
        projection: projectionOf([
          AgentMessage.user('用户输入'),
          assistantToolCall(),
        ]),
        textRepair: null,
        turn: 2,
        toolPlaceholderTitle: '中断占位',
      );

      expect(events, hasLength(1));
      final event = events.single;
      expect(event.type, AgentEventTypes.toolResult);
      expect(event.data['callId'], 'call_1');
      expect(event.data['toolName'], 'search_story');
      expect(event.data['isError'], true);
      expect(event.data['title'], '中断占位');
      expect(event.data['turn'], 2);
    });

    test('多个未配对调用 → 每个都补占位，且不追加续跑指令', () {
      final events = resumeRepairEvents(
        projection: projectionOf([
          AgentMessage.user('用户输入'),
          AgentMessage.assistant(
            toolCalls: [
              const AgentToolCall(id: 'call_1', name: 'a', arguments: {}),
              const AgentToolCall(id: 'call_2', name: 'b', arguments: {}),
            ],
          ),
        ]),
        textRepair: null,
        turn: 2,
        toolPlaceholderTitle: '中断占位',
      );

      expect(events, hasLength(2));
      expect(events.map((e) => e.data['callId']), ['call_1', 'call_2']);
      expect(
        events.any((e) => e.type == AgentEventTypes.userMessage),
        isFalse,
      );
    });

    test('tool call 已有结果 → 不补占位也不追加续跑指令', () {
      final events = resumeRepairEvents(
        projection: projectionOf([
          AgentMessage.user('用户输入'),
          assistantToolCall(),
          AgentMessage.toolResult(toolCallId: 'call_1', content: 'ok'),
        ]),
        textRepair: null,
        turn: 2,
        toolPlaceholderTitle: '中断占位',
      );

      expect(events, isEmpty);
    });

    test('末尾是 user → 不追加', () {
      final events = resumeRepairEvents(
        projection: projectionOf([
          AgentMessage.system('system'),
          AgentMessage.assistant(text: '正文'),
          AgentMessage.user('新指令'),
        ]),
        textRepair: null,
        turn: 2,
        toolPlaceholderTitle: '中断占位',
      );

      expect(events, isEmpty);
    });

    test('末尾 system 包在 assistant 之后 → 仍按最后非 system 的 assistant 追加', () {
      final events = resumeRepairEvents(
        projection: projectionOf([
          AgentMessage.user('用户输入'),
          AgentMessage.assistant(text: '半截正文'),
          AgentMessage.system('尾部系统块'),
        ]),
        textRepair: null,
        turn: 2,
        toolPlaceholderTitle: '中断占位',
      );

      expect(events, hasLength(1));
      expect(events.single.type, AgentEventTypes.userMessage);
    });

    test('中断正文补账与续跑指令同批、顺序在补账之后', () {
      final textRepair = AgentDurableEvent(
        type: AgentEventTypes.assistantMessage,
        surfaceOp: AgentSurfaceOpKind.append,
        data: const AgentAssistantMessageData(text: '半截正文').toJson(),
      );

      final events = resumeRepairEvents(
        projection: projectionOf([AgentMessage.user('用户输入')]),
        textRepair: textRepair,
        turn: 2,
        toolPlaceholderTitle: '中断占位',
      );

      expect(events, hasLength(2));
      expect(events[0].type, AgentEventTypes.assistantMessage);
      expect(events[1].type, AgentEventTypes.userMessage);
    });
  });
}
