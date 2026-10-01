import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_budget.dart';
import 'package:lmstory/core/agent/agent_events.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/features/advanced/data/agent_durable_event_sink.dart';
import 'package:lmstory/features/advanced/data/repositories/agent_event_log_repository.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// 捕获 appendAll 的假仓库（sink 映射测试用）
class _CapturingEventLogRepository implements AgentEventLogRepository {
  final List<AgentDurableEvent> appended = [];

  @override
  Future<List<int>> appendAll(
    String sessionId,
    List<AgentDurableEvent> events,
  ) async {
    appended.addAll(events);
    return List.generate(events.length, (i) => i);
  }

  @override
  Future<List<AgentDurableEvent>> readEvents(
    String sessionId, {
    int? fromSeq,
    int? limit,
  }) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  group('T9 注入消息事件映射（user/message + source=注入来源）', () {
    test('AgentInjectedMessageEvent → user/message surface append', () async {
      final repo = _CapturingEventLogRepository();
      final sink = DurableAgentEventSink(repository: repo, sessionId: 's1')
        ..emit(
          AgentInjectedMessageEvent(
            message: AgentMessage.user('〈workbench-reminder〉通牒…'),
            kind: AgentInjectedMessageKinds.budgetFinalNotice,
          ),
        );

      expect(sink.isEmpty, isFalse);
      sink.emit(
        AgentTurnFinished(
          reason: AgentStopReason.completed,
          steps: 1,
          usage: AgentUsageAccumulator(),
          errorMessage: null,
        ),
      );
      unawaited(sink.flush());
      // flush 是异步的：等微任务排空
      await Future<void>.delayed(Duration.zero);
      expect(repo.appended, isNotEmpty);
      final events = repo.appended;
      final userEvent = events.firstWhere(
        (e) => e.type == AgentEventTypes.userMessage,
      );
      expect(userEvent.surfaceOp, AgentSurfaceOpKind.append);
      expect(userEvent.data['source'], 'budget_final_notice');
      expect(userEvent.data['content'], contains('workbench-reminder'));
    });
  });

  group('DurableAgentEventSink stepBegin 的 attempt 字段（契约 §7.1）', () {
    test('attempt>0 落日志字段；attempt=0 省略（旧日志兼容）', () async {
      final repo = _CapturingEventLogRepository();
      final sink = DurableAgentEventSink(repository: repo, sessionId: 's1')
        ..emit(AgentStepStarted(stepIndex: 2))
        ..emit(AgentStepStarted(stepIndex: 2, attempt: 1));

      await sink.flush();
      final begins = repo.appended
          .where((e) => e.type == AgentEventTypes.stepBegin)
          .toList();
      expect(begins, hasLength(2));
      expect(begins[0].data['attempt'], isNull);
      expect(begins[1].data['attempt'], 1);
      expect(begins[1].data['stepIndex'], 2);
    });
  });

  group('B10 cache 分项进 durable（step/end 与 turn/end）', () {
    test('step/end：cache 分项随事件落键；null（端点未上报）不落键', () async {
      final repo = _CapturingEventLogRepository();
      final sink = DurableAgentEventSink(repository: repo, sessionId: 's1')
        ..emit(
          AgentStepFinished(
            stepIndex: 0,
            stopKind: AgentStepStopKind.toolCalls,
            promptTokens: 1000,
            completionTokens: 200,
            totalTokens: 1200,
            cacheReadTokens: 800,
            cacheCreationTokens: 50,
          ),
        )
        ..emit(
          AgentStepFinished(
            stepIndex: 1,
            stopKind: AgentStepStopKind.textReply,
            promptTokens: 500,
            completionTokens: 100,
            totalTokens: 600,
          ),
        );

      await sink.flush();
      final ends = repo.appended
          .where((e) => e.type == AgentEventTypes.stepEnd)
          .toList();
      expect(ends, hasLength(2));
      expect(ends[0].data['cacheReadTokens'], 800);
      expect(ends[0].data['cacheCreationTokens'], 50);
      // 未上报缓存的步不落键（读取侧缺键=null，与旧日志同形态）
      expect(ends[1].data.containsKey('cacheReadTokens'), isFalse);
      expect(ends[1].data.containsKey('cacheCreationTokens'), isFalse);
    });

    test('turn/end：cache 分项随轮累计落键（0 也落——累加器口径恒有值）', () async {
      final repo = _CapturingEventLogRepository();
      final usage = AgentUsageAccumulator()
        ..promptTokens = 1500
        ..completionTokens = 300
        ..totalTokens = 1800
        ..cacheReadTokens = 800
        ..cacheCreationTokens = 50;
      final sink = DurableAgentEventSink(repository: repo, sessionId: 's1')
        ..emit(
          AgentTurnFinished(
            reason: AgentStopReason.completed,
            steps: 2,
            usage: usage,
            errorMessage: null,
          ),
        );

      await sink.flush();
      final end = repo.appended.single;
      expect(end.type, AgentEventTypes.turnEnd);
      expect(end.data['cacheReadTokens'], 800);
      expect(end.data['cacheCreationTokens'], 50);
      expect(end.data['promptTokens'], 1500);
    });
  });

  group('B12 子代理事件中继（log-only，投影不受污染）', () {
    test('relaySubagentEvent：surface 语义剥离 + subagent 标记 + turn 盖章', () async {
      final repo = _CapturingEventLogRepository();
      final relaySink = DurableAgentEventSink(
        repository: repo,
        sessionId: 's1',
        turnNumber: 3,
      )
        ..relaySubagentEvent(
          AgentAssistantMessageEvent(
            stepIndex: 0,
            message: AgentMessage.assistant(text: '子代理输出'),
          ),
        )
        ..relaySubagentEvent(
          AgentToolExecutionFinished(
            callId: 'c1',
            toolName: 'search_story',
            title: '检索',
            output: '命中 2 条',
            isError: false,
            duration: const Duration(milliseconds: 5),
          ),
        );
      await relaySink.flush();

      final events = repo.appended;
      expect(events, hasLength(2));
      for (final event in events) {
        expect(event.surfaceOp, isNull, reason: '子代理事件不进投影');
        expect(event.data['subagent'], isTrue);
        expect(event.data['turn'], 3);
      }
      expect(events[0].type, AgentEventTypes.assistantMessage);
      expect(events[1].type, AgentEventTypes.toolResult);
      // 投影为空（log-only）
      expect(deriveAgentSurface(events).messages, isEmpty);
    });
  });

  group('deriveAgentSurface（surface 投影纯函数）', () {
    test('审查收官 R2-P1-2：frozen 重落账（重启判据失忆）投影只保留最新一条', () {
      final events = [
        AgentDurableEvent(
          type: AgentEventTypes.systemFrozen,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': 'FROZEN-v1'},
        ),
        AgentDurableEvent(
          type: AgentEventTypes.userMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': '旧输入', 'source': 'user'},
        ),
        // 重启后 runner 重落的新前缀（append-only，旧条不删）
        AgentDurableEvent(
          type: AgentEventTypes.systemFrozen,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': 'FROZEN-v2'},
        ),
        AgentDurableEvent(
          type: AgentEventTypes.userMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': '新输入', 'source': 'user'},
        ),
      ];

      final projection = deriveAgentSurface(events);
      // 「前缀当前值」语义：只保留最新 frozen，其余消息不受影响
      expect(
        projection.messages.where((m) => m.role == 'system'),
        hasLength(1),
      );
      expect(projection.messages.first.content, 'FROZEN-v2');
      expect(projection.messages, hasLength(3));
    });

    test('审查收官 R1-P2-1：A 案 core 每轮 append 投影原位替换（不累积过期块）', () {
      final events = [
        AgentDurableEvent(
          type: AgentEventTypes.systemFrozen,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': 'SYS'},
        ),
        AgentDurableEvent(
          type: AgentEventTypes.systemCore,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': 'CORE-v1'},
        ),
        AgentDurableEvent(
          type: AgentEventTypes.userMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': '第一轮', 'source': 'user'},
        ),
        // 第二轮：生产侧 append 新 core（写侧无 replace）
        AgentDurableEvent(
          type: AgentEventTypes.systemCore,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': 'CORE-v2'},
        ),
      ];

      final projection = deriveAgentSurface(events);
      expect(projection.messages, hasLength(3), reason: 'core 原位替换不增条');
      expect(projection.messages[1].content, 'CORE-v2');
      expect(projection.coreIndex, 1, reason: '替换后坐标不漂移');
    });

    test('append 序列：frozen → core → user → assistant → tool', () {
      final events = [
        AgentDurableEvent(
          seq: 0,
          type: AgentEventTypes.systemFrozen,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': 'SYSTEM'},
        ),
        AgentDurableEvent(
          seq: 1,
          type: AgentEventTypes.systemCore,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': 'CORE-1'},
        ),
        AgentDurableEvent(
          seq: 2,
          type: AgentEventTypes.userMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': '开始', 'source': 'user'},
        ),
        AgentDurableEvent(
          seq: 3,
          type: AgentEventTypes.assistantMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: const AgentAssistantMessageData(
            text: '查一下',
            toolCalls: [
              {
                'id': 'c1',
                'name': 'search',
                'args': {'q': 1},
              },
            ],
          ).toJson(),
        ),
        AgentDurableEvent(
          seq: 4,
          type: AgentEventTypes.toolResult,
          surfaceOp: AgentSurfaceOpKind.append,
          data: const AgentToolResultData(
            callId: 'c1',
            toolName: 'search',
            output: 'no hits',
          ).toJson(),
        ),
        // log-only 事件不影响投影
        AgentDurableEvent(
          seq: 5,
          type: AgentEventTypes.stepEnd,
          data: {'stepIndex': 0},
        ),
      ];

      final projection = deriveAgentSurface(events);

      expect(projection.messages, hasLength(5));
      expect(projection.messages[0].role, 'system');
      expect(projection.messages[0].content, 'SYSTEM');
      expect(projection.messages[1].content, 'CORE-1');
      expect(projection.coreIndex, 1);
      expect(projection.messages[2].role, 'user');
      final assistant = projection.messages[3];
      expect(assistant.role, 'assistant');
      expect(assistant.toolCalls!.single.name, 'search');
      expect(assistant.toolCalls!.single.arguments, {'q': 1});
      expect(projection.messages[4].toolCallId, 'c1');
      expect(projection.lastSeq, 5);
    });

    test('system/core replace：替换区间坐标正确', () {
      final events = [
        AgentDurableEvent(
          seq: 0,
          type: AgentEventTypes.systemFrozen,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': 'SYSTEM'},
        ),
        AgentDurableEvent(
          seq: 1,
          type: AgentEventTypes.systemCore,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': 'CORE-v1'},
        ),
        AgentDurableEvent(
          seq: 2,
          type: AgentEventTypes.userMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': '第一轮'},
        ),
        // 第二轮前刷新 core：replace [1,2)
        AgentDurableEvent(
          seq: 3,
          type: AgentEventTypes.systemCore,
          surfaceOp: AgentSurfaceOpKind.replace,
          replaceStart: 1,
          replaceEnd: 2,
          data: {'content': 'CORE-v2'},
        ),
        AgentDurableEvent(
          seq: 4,
          type: AgentEventTypes.userMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': '第二轮'},
        ),
      ];

      final projection = deriveAgentSurface(events);

      expect(projection.messages, hasLength(4));
      expect(projection.messages[1].content, 'CORE-v2');
      expect(projection.messages[2].content, '第一轮');
      expect(projection.messages[3].content, '第二轮');
      expect(projection.coreIndex, 1);
    });

    test('replace 区间失效（防御）：退化为追加', () {
      final events = [
        AgentDurableEvent(
          seq: 0,
          type: AgentEventTypes.userMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': 'hi'},
        ),
        AgentDurableEvent(
          seq: 1,
          type: AgentEventTypes.systemCore,
          surfaceOp: AgentSurfaceOpKind.replace,
          replaceStart: 99,
          replaceEnd: 100,
          data: {'content': 'CORE'},
        ),
      ];

      final projection = deriveAgentSurface(events);
      expect(projection.messages, hasLength(2));
      expect(projection.messages.last.content, 'CORE');
      expect(projection.coreIndex, 1);
    });

    test('assistant 协议字段透传（thoughtSignature / reasoningContent）', () {
      final events = [
        AgentDurableEvent(
          seq: 0,
          type: AgentEventTypes.assistantMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: const AgentAssistantMessageData(
            reasoningContent: '思考链',
            toolCalls: [
              {
                'id': 'g1',
                'name': 'search',
                'args': {'q': 1},
                'thoughtSignature': 'sig-x',
              },
            ],
          ).toJson(),
        ),
      ];

      final assistant = deriveAgentSurface(events).messages.single;
      expect(assistant.reasoningContent, '思考链');
      expect(assistant.toolCalls!.single.thoughtSignature, 'sig-x');
    });

    test('未知 surface 类型跳过（向前兼容）', () {
      final events = [
        AgentDurableEvent(
          seq: 0,
          type: 'future/event',
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'x': 1},
        ),
      ];
      expect(deriveAgentSurface(events).messages, isEmpty);
    });

    test('JSON 往返序列化', () {
      final event = AgentDurableEvent(
        seq: 7,
        type: AgentEventTypes.systemCore,
        surfaceOp: AgentSurfaceOpKind.replace,
        replaceStart: 2,
        replaceEnd: 3,
        data: {'content': 'CORE'},
        sourceEventSeqs: [4, 5, 6],
      );

      final restored = AgentDurableEvent.fromJson(event.toJson());
      expect(restored.seq, 7);
      expect(restored.surfaceOp, AgentSurfaceOpKind.replace);
      expect(restored.replaceStart, 2);
      expect(restored.sourceEventSeqs, [4, 5, 6]);
    });

    test('surface/replace 整面替换（replaceEnd=-1）：投影=替换数组，多轮坐标不再错位', () {
      final events = [
        AgentDurableEvent(
          seq: 0,
          type: AgentEventTypes.systemFrozen,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': 'SYSTEM'},
        ),
        AgentDurableEvent(
          seq: 1,
          type: AgentEventTypes.userMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': 't1-user'},
        ),
        AgentDurableEvent(
          seq: 2,
          type: AgentEventTypes.assistantMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: const AgentAssistantMessageData(text: 't1-a').toJson(),
        ),
        AgentDurableEvent(
          seq: 3,
          type: AgentEventTypes.userMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': 't2-user'},
        ),
        AgentDurableEvent(
          seq: 4,
          type: AgentEventTypes.assistantMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: const AgentAssistantMessageData(text: 't2-a').toJson(),
        ),
        // 溢出整面替换：压缩产物自带 system 前缀（与实际请求面同构）
        AgentDurableEvent(
          seq: 5,
          type: AgentEventTypes.surfaceReplace,
          surfaceOp: AgentSurfaceOpKind.replace,
          replaceStart: 0,
          replaceEnd: kAgentSurfaceReplaceToEnd,
          data: {
            'messages': [
              agentMessageToSurfaceData(AgentMessage.system('SYSTEM')),
              agentMessageToSurfaceData(AgentMessage.user('【前情摘要】')),
              agentMessageToSurfaceData(AgentMessage.user('t2-user')),
            ],
          },
        ),
      ];

      final projection = deriveAgentSurface(events);
      expect(projection.messages, hasLength(3));
      expect(projection.messages[0].role, 'system');
      expect(projection.messages[0].content, 'SYSTEM');
      expect(projection.messages[1].content, '【前情摘要】');
      expect(projection.messages[2].content, 't2-user');
    });

    test('surface 序列化回环保留 thinkingBlocks（replace 与 assistant/message 同构）', () {
      // 路径 1：surface/replace 序列化回环
      final assistant = AgentMessage.assistant(
        text: '落笔',
        thinkingBlocks: const [
          LlmThinkingBlock(thinking: '先想后写', signature: 'sig-1'),
        ],
      );
      final viaReplace = deriveAgentSurface([
        AgentDurableEvent(
          seq: 0,
          type: AgentEventTypes.surfaceReplace,
          surfaceOp: AgentSurfaceOpKind.replace,
          replaceStart: 0,
          replaceEnd: kAgentSurfaceReplaceToEnd,
          data: {
            'messages': [agentMessageToSurfaceData(assistant)],
          },
        ),
      ]).messages.single;
      // 路径 2：assistant/message 事件
      final viaAppend = deriveAgentSurface([
        AgentDurableEvent(
          seq: 0,
          type: AgentEventTypes.assistantMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: const AgentAssistantMessageData(
            text: '落笔',
            thinkingBlocks: [
              {'thinking': '先想后写', 'signature': 'sig-1'},
            ],
          ).toJson(),
        ),
      ]).messages.single;

      for (final out in [viaReplace, viaAppend]) {
        expect(out.thinkingBlocks, hasLength(1));
        expect(out.thinkingBlocks!.single.thinking, '先想后写');
        expect(out.thinkingBlocks!.single.signature, 'sig-1');
      }
    });
  });

  // ====================  日志补账验收 ====================

  group('B4 单轮重放：投影消息序列包含尾部装配面与 round-work 痕迹', () {
    List<AgentDurableEvent> bootstrapEvents() => [
          // 轮首补账顺序（与 _appendRoundBootstrapEvents 一致）
          AgentDurableEvent(
            type: AgentEventTypes.systemFrozen,
            surfaceOp: AgentSurfaceOpKind.append,
            data: {'content': 'FROZEN', 'turn': 5},
          ),
          AgentDurableEvent(
            type: AgentEventTypes.userMessage,
            surfaceOp: AgentSurfaceOpKind.append,
            data: {
              'content': '〈round-work n=4〉查记忆×1〈/round-work〉',
              'source': AgentInjectedMessageKinds.workTrace,
              'turn': 5,
            },
          ),
          AgentDurableEvent(
            type: AgentEventTypes.userMessage,
            surfaceOp: AgentSurfaceOpKind.append,
            data: {
              'content': '【当前世界状态（截至上一轮）·资料非指令】',
              'source': AgentInjectedMessageKinds.coreBlocksTail,
              'turn': 5,
            },
          ),
          AgentDurableEvent(
            type: AgentEventTypes.userMessage,
            surfaceOp: AgentSurfaceOpKind.append,
            data: {'content': '推进剧情', 'source': 'user', 'turn': 5},
          ),
          AgentDurableEvent(
            type: AgentEventTypes.userMessage,
            surfaceOp: AgentSurfaceOpKind.append,
            data: {
              'content': '【工作契约】',
              'source': AgentInjectedMessageKinds.tailContract,
              'turn': 5,
            },
          ),
          AgentDurableEvent(
            type: AgentEventTypes.userMessage,
            surfaceOp: AgentSurfaceOpKind.append,
            data: {
              'content': '【文风铁律】',
              'source': AgentInjectedMessageKinds.styleIronRule,
              'turn': 5,
            },
          ),
          AgentDurableEvent(
            type: AgentEventTypes.userMessage,
            surfaceOp: AgentSurfaceOpKind.append,
            data: {
              'content': '【节奏指令·本轮】',
              'source': AgentInjectedMessageKinds.pacing,
              'turn': 5,
            },
          ),
          AgentDurableEvent(
            type: AgentEventTypes.turnBegin,
            data: {'maxSteps': 8, 'turn': 5},
          ),
          AgentDurableEvent(
            type: AgentEventTypes.assistantMessage,
            surfaceOp: AgentSurfaceOpKind.append,
            data: const AgentAssistantMessageData(text: '夜色沉下来。').toJson(),
          ),
        ];

    test('投影包含 trace / coreBlocks 尾 / 用户输入 / 尾部三件，顺序一致', () {
      final projection = deriveAgentSurface(bootstrapEvents());
      final contents = [
        for (final m in projection.messages)
          if (m.content != null) m.content!,
      ];

      expect(contents, contains('〈round-work n=4〉查记忆×1〈/round-work〉'));
      expect(contents, contains('【当前世界状态（截至上一轮）·资料非指令】'));
      expect(contents, contains('推进剧情'));
      expect(contents, contains('【工作契约】'));
      expect(contents, contains('【文风铁律】'));
      expect(contents, contains('【节奏指令·本轮】'));

      // 顺序：trace < coreBlocks 尾 < 用户输入 < 尾部 < assistant
      int of(String s) => contents.indexOf(s);
      expect(of('〈round-work n=4〉查记忆×1〈/round-work〉'), lessThan(of('推进剧情')));
      expect(of('【当前世界状态（截至上一轮）·资料非指令】'), lessThan(of('推进剧情')));
      expect(of('【工作契约】'), greaterThan(of('推进剧情')));
      expect(of('【节奏指令·本轮】'), greaterThan(of('【文风铁律】')));
      // assistant 正文在尾部之后（本轮输出）
      expect(contents.last, '夜色沉下来。');
    });

    test('AgentSurfaceReplaced → durable surface/replace → 投影反映压缩结果', () async {
      // ① live 事件经 sink 映射为 durable replace
      final repo = _CapturingEventLogRepository();
      final sink = DurableAgentEventSink(repository: repo, sessionId: 's-b4')
        ..emit(
          AgentSurfaceReplaced(
            messages: [
              AgentMessage.system('FROZEN'),
              AgentMessage.user('【前情压缩摘要】'),
              AgentMessage.user('最近输入'),
            ],
            replaceEnd: 6,
          ),
        );
      await sink.flush();
      final durable = repo.appended.single;

      expect(durable.type, AgentEventTypes.surfaceReplace);
      expect(durable.surfaceOp, AgentSurfaceOpKind.replace);
      expect(durable.replaceStart, 0);
      expect(durable.replaceEnd, 6);

      // ② 投影：replace 生效——压缩后序列整体替换此前消息
      final projection = deriveAgentSurface([
        ...bootstrapEvents(),
        durable,
      ]);
      final contents = [
        for (final m in projection.messages)
          if (m.content != null) m.content!,
      ];
      expect(contents, contains('【前情压缩摘要】'));
      expect(contents, contains('最近输入'));
      expect(contents, isNot(contains('推进剧情')));
    });
  });

  group('AgentMessage wire 化回环（投影 → 请求 → 重放等价）', () {
    test('投影出的消息可再次 wire 化（含工具配对）', () {
      final events = [
        AgentDurableEvent(
          seq: 0,
          type: AgentEventTypes.userMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {'content': 'hi'},
        ),
        AgentDurableEvent(
          seq: 1,
          type: AgentEventTypes.assistantMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: const AgentAssistantMessageData(
            text: '查',
            toolCalls: [
              {
                'id': 'c1',
                'name': 'search',
                'args': {'q': 1},
              },
            ],
          ).toJson(),
        ),
        AgentDurableEvent(
          seq: 2,
          type: AgentEventTypes.toolResult,
          surfaceOp: AgentSurfaceOpKind.append,
          data: const AgentToolResultData(
            callId: 'c1',
            toolName: 'search',
            output: 'ok',
          ).toJson(),
        ),
      ];

      final wire = deriveAgentSurface(events)
          .messages
          .map((m) => m.toRequestMap())
          .toList();

      expect(wire[0]['role'], 'user');
      final toolCall =
          (wire[1]['tool_calls'] as List).single as Map<String, dynamic>;
      final function = toolCall['function'] as Map<String, dynamic>;
      expect(function['name'], 'search');
      expect(wire[2]['tool_call_id'], 'c1');
    });
  });
}
