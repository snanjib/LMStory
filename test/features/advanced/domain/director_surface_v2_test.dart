import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/services/director_surface_v2.dart';

/// DirectorSurfaceV2 纯函数：纪元窗投影 + 冻结前缀前置 + replace 折叠
/// + contentGeneration + 幂等（对齐 dsh derived-cache/surface.spec 思路）。
void main() {
  AgentDurableEvent ev(
    int seq,
    String type, {
    Map<String, dynamic> data = const {},
    AgentSurfaceOpKind? op,
    int? replaceStart,
    int? replaceEnd,
  }) =>
      AgentDurableEvent(
        seq: seq,
        type: type,
        data: data,
        surfaceOp: op,
        replaceStart: replaceStart,
        replaceEnd: replaceEnd,
      );

  List<AgentDurableEvent> openLedger({
    List<AgentDurableEvent> extra = const [],
    String frozen = 'FROZEN',
  }) {
    return [
      ev(
        0,
        AgentEventTypes.systemFrozen,
        op: AgentSurfaceOpKind.append,
        data: {'content': frozen, 'turn': 1},
      ),
      ev(
        1,
        AgentEventTypes.modeEpoch,
        data: {
          'phase': 'enter',
          'epochId': 'e1',
          'status': 'pending',
          'fromTurn': 2,
        },
      ),
      ev(
        2,
        AgentEventTypes.modeCapture,
        op: AgentSurfaceOpKind.append,
        data: {'as': 'user', 'content': '旧输入', 'epochId': 'e1'},
      ),
      ev(
        3,
        AgentEventTypes.modeCapture,
        op: AgentSurfaceOpKind.append,
        data: {
          'as': 'assistant',
          'content': '旧正文',
          'epochId': 'e1',
        },
      ),
      ev(
        4,
        AgentEventTypes.modeEpoch,
        data: {
          'phase': 'enter',
          'epochId': 'e1',
          'status': 'complete',
          'captureCount': 2,
        },
      ),
      ...extra,
    ];
  }

  test('纪元窗投影 + 冻结前缀前置：捕获按角色还原，frozen 恒为节点 0', () {
    final events = openLedger(
      extra: [
        ev(
          5,
          AgentEventTypes.userMessage,
          op: AgentSurfaceOpKind.append,
          data: {'content': 'u2', 'turn': 2},
        ),
      ],
    );
    final frozen = DirectorSurfaceV2.latestFrozenPrefixOf(events);
    expect(frozen, 'FROZEN');
    final projection = DirectorSurfaceV2.epochWindowProjection(events);
    final assembled = DirectorSurfaceV2.assemble(
      epochWindowMessages: projection.messages,
      frozenPrefix: frozen,
    );
    expect(assembled.map((m) => m.role).toList(), [
      'system', // frozen（前置）
      'user', // 捕获：旧输入
      'assistant', // 捕获：旧正文
      'user', // 本轮 u2
    ]);
    expect(assembled.first.content, 'FROZEN');
    expect(assembled[1].content, '旧输入');
    expect(assembled[3].content, 'u2');
  });

  test('窗内 system/frozen 事件被滤除：冻结前缀变更换新 frozen 事件不产生重复节点', () {
    final events = openLedger(
      extra: [
        ev(
          5,
          AgentEventTypes.systemFrozen,
          op: AgentSurfaceOpKind.append,
          data: {'content': 'FROZEN-V2', 'turn': 3},
        ),
        ev(
          6,
          AgentEventTypes.userMessage,
          op: AgentSurfaceOpKind.append,
          data: {'content': 'u3', 'turn': 3},
        ),
      ],
    );
    // 最新 frozen 生效（全账本取值）
    expect(DirectorSurfaceV2.latestFrozenPrefixOf(events), 'FROZEN-V2');
    // 窗投影不含任何 frozen 节点（组装器单点前置）
    final projection = DirectorSurfaceV2.epochWindowProjection(events);
    expect(
      projection.messages.any((m) => m.content == 'FROZEN-V2'),
      isFalse,
    );
  });

  test('捕获 system 摘要不被 frozen 原位替换逻辑 clobber', () {
    final events = [
      ev(
        0,
        AgentEventTypes.systemFrozen,
        op: AgentSurfaceOpKind.append,
        data: {'content': 'FROZEN', 'turn': 1},
      ),
      ev(
        1,
        AgentEventTypes.modeEpoch,
        data: {'phase': 'enter', 'epochId': 'e1', 'status': 'pending'},
      ),
      ev(
        2,
        AgentEventTypes.modeCapture,
        op: AgentSurfaceOpKind.append,
        data: {'as': 'system', 'content': '【前情压缩摘要】', 'epochId': 'e1'},
      ),
      ev(
        3,
        AgentEventTypes.modeEpoch,
        data: {
          'phase': 'enter',
          'epochId': 'e1',
          'status': 'complete',
          'captureCount': 1,
        },
      ),
      // 开启后又换了 frozen（落在窗内）
      ev(
        4,
        AgentEventTypes.systemFrozen,
        op: AgentSurfaceOpKind.append,
        data: {'content': 'FROZEN-NEW', 'turn': 2},
      ),
    ];
    final assembled = DirectorSurfaceV2.assemble(
      epochWindowMessages: DirectorSurfaceV2.epochWindowProjection(
        events,
      ).messages,
      frozenPrefix: DirectorSurfaceV2.latestFrozenPrefixOf(events),
    );
    // 两个 system 并存：frozen 节点 0 + 捕获的摘要（不被顶掉）
    expect(assembled[0].content, 'FROZEN-NEW');
    expect(assembled[1].role, 'system');
    expect(assembled[1].content, '【前情压缩摘要】');
  });

  test('user/message replace：合法区间原位替换；非法区间忽略', () {
    final events = [
      ev(
        0,
        AgentEventTypes.userMessage,
        op: AgentSurfaceOpKind.append,
        data: {'content': 'a'},
      ),
      ev(
        1,
        AgentEventTypes.userMessage,
        op: AgentSurfaceOpKind.append,
        data: {'content': 'b'},
      ),
      ev(
        2,
        AgentEventTypes.userMessage,
        op: AgentSurfaceOpKind.append,
        data: {'content': 'c'},
      ),
      // 区间 [1,3) 替换为单条 X：b、c → X
      ev(
        3,
        AgentEventTypes.userMessage,
        op: AgentSurfaceOpKind.replace,
        replaceStart: 1,
        replaceEnd: 3,
        data: {'content': 'X'},
      ),
      // 越界区间（end=99）忽略
      ev(
        4,
        AgentEventTypes.assistantMessage,
        op: AgentSurfaceOpKind.replace,
        replaceStart: 0,
        replaceEnd: 99,
        data: {'text': 'BAD'},
      ),
    ];
    final projection = deriveAgentSurface(events);
    expect(projection.messages.map((m) => m.content).toList(), ['a', 'X']);
    // 两个 replace 事件都计入代数（无论应用与否——代数=账本失效次数）
    expect(projection.contentGeneration, 2);
  });

  test('assistant/toolResult replace：工具调用/思考字段随替换消息还原', () {
    final events = [
      ev(
        0,
        AgentEventTypes.assistantMessage,
        op: AgentSurfaceOpKind.append,
        data: {
          'text': '旧播报',
          'toolCalls': [
            {
              'id': 'c1',
              'name': 'echo',
              'args': {'x': 1},
            },
          ],
        },
      ),
      ev(
        1,
        AgentEventTypes.assistantMessage,
        op: AgentSurfaceOpKind.replace,
        replaceStart: 0,
        replaceEnd: 1,
        data: {
          'text': '新播报',
          'toolCalls': [
            {
              'id': 'c2',
              'name': 'echo',
              'args': {'x': 2},
            },
          ],
        },
      ),
    ];
    final projection = deriveAgentSurface(events);
    expect(projection.messages, hasLength(1));
    expect(projection.messages.single.content, '新播报');
    expect(projection.messages.single.toolCalls!.single.id, 'c2');
  });

  test('投影幂等：同一账本两次投影逐条相等（内容层）', () {
    final events = openLedger(
      extra: [
        ev(
          5,
          AgentEventTypes.userMessage,
          op: AgentSurfaceOpKind.append,
          data: {'content': 'u2', 'turn': 2},
        ),
        ev(
          6,
          AgentEventTypes.assistantMessage,
          op: AgentSurfaceOpKind.append,
          data: {
            'text': '播报',
            'toolCalls': [
              {
                'id': 't1',
                'name': 'query_facts',
                'args': {'q': '林涣'},
              },
            ],
          },
        ),
        ev(
          7,
          AgentEventTypes.toolResult,
          op: AgentSurfaceOpKind.append,
          data: {'callId': 't1', 'toolName': 'query_facts', 'output': '命中'},
        ),
      ],
    );
    final a = DirectorSurfaceV2.epochWindowProjection(events);
    final b = DirectorSurfaceV2.epochWindowProjection(events);
    expect(a.messages.length, b.messages.length);
    for (var i = 0; i < a.messages.length; i++) {
      expect(a.messages[i].role, b.messages[i].role);
      expect(a.messages[i].content, b.messages[i].content);
      expect(a.messages[i].toolCallId, b.messages[i].toolCallId);
    }
    expect(a.contentGeneration, b.contentGeneration);
    expect(a.lastSeq, b.lastSeq);
  });

  test('追加延长（append-extends）：追加事件只增长尾部，前缀逐条不变', () {
    final base = openLedger();
    final extended = openLedger(
      extra: [
        ev(
          5,
          AgentEventTypes.userMessage,
          op: AgentSurfaceOpKind.append,
          data: {'content': 'u2', 'turn': 2},
        ),
      ],
    );
    final baseMessages = DirectorSurfaceV2.epochWindowProjection(base).messages;
    final extMessages =
        DirectorSurfaceV2.epochWindowProjection(extended).messages;
    expect(extMessages.length, baseMessages.length + 1);
    for (var i = 0; i < baseMessages.length; i++) {
      expect(extMessages[i].content, baseMessages[i].content);
    }
  });

  test('contentGeneration：无 replace 为 0', () {
    final events = openLedger();
    expect(
      DirectorSurfaceV2.epochWindowProjection(events).contentGeneration,
      0,
    );
  });
}
