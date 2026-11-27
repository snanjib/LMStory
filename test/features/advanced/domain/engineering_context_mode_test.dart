import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/services/engineering_context_mode.dart';

/// 工程上下文模式三态解析与纪元事件构造（纯函数）。
///
/// 判定规则：三态判定与数据保护铁律、备份导入五类场景。
void main() {
  AgentDurableEvent enterPending(String epochId, {int fromTurn = 1}) =>
      modeEpochEnterPendingEvent(epochId: epochId, fromTurn: fromTurn);

  AgentDurableEvent enterComplete(
    String epochId, {
    required int captureCount,
  }) =>
      modeEpochEnterCompleteEvent(
        epochId: epochId,
        captureCount: captureCount,
      );

  AgentDurableEvent capture(String epochId, String content) =>
      AgentDurableEvent(
        type: AgentEventTypes.modeCapture,
        surfaceOp: AgentSurfaceOpKind.append,
        data: {
          'as': 'user',
          'content': content,
          'epochId': epochId,
          'source': 'mode_capture',
        },
      );

  /// 附加轮事件（普通消息，带 seq 模拟落库后形态）
  AgentDurableEvent roundUser(int seq, String content) => AgentDurableEvent(
        seq: seq,
        type: AgentEventTypes.userMessage,
        surfaceOp: AgentSurfaceOpKind.append,
        data: {'content': content, 'turn': 9},
      );

  test('普通旧会话（无纪元证据，任意旧诊断事件）→ 正常关闭（Case 1/2）', () {
    final events = [
      AgentDurableEvent(seq: 0, type: 'turn/begin', data: {'turn': 1}),
      AgentDurableEvent(seq: 1, type: 'turn/end', data: {'turn': 1}),
      AgentDurableEvent(seq: 2, type: 'persist/embedding-degraded', data: {}),
    ];
    expect(
      resolveEngineeringMode(enabled: null, events: events).mode,
      EngineeringRuntimeMode.normalClosed,
    );
    expect(
      resolveEngineeringMode(enabled: false, events: events).mode,
      EngineeringRuntimeMode.normalClosed,
    );
    expect(
      resolveEngineeringMode(enabled: null, events: const []).mode,
      EngineeringRuntimeMode.normalClosed,
    );
  });

  test('列 true 但缺纪元（含旧诊断日志）→ 需要修复（Case 4：不被旧日志覆盖）', () {
    final events = [
      AgentDurableEvent(seq: 0, type: 'turn/begin', data: {'turn': 1}),
      AgentDurableEvent(seq: 1, type: 'turn/end', data: {'turn': 1}),
    ];
    final resolution = resolveEngineeringMode(enabled: true, events: events);
    expect(resolution.mode, EngineeringRuntimeMode.recoveryRequired);
    expect(resolution.reason, 'enabled-without-epoch');
  });

  test('pending 残留（事务中断）→ 需要修复，不猜为可删垃圾', () {
    final events = [enterPending('e1')];
    final resolution = resolveEngineeringMode(enabled: true, events: events);
    expect(resolution.mode, EngineeringRuntimeMode.recoveryRequired);
    expect(resolution.reason, 'pending-epoch');
    // 列 false + pending 残留同样修复（数据保护铁律不挑列值）
    expect(
      resolveEngineeringMode(enabled: false, events: events).reason,
      'pending-epoch',
    );
  });

  test('列 false + complete enter 无 exit → 需要修复', () {
    final events = [
      enterPending('e1'),
      enterComplete('e1', captureCount: 1),
      capture('e1', '旧正文'),
    ];
    final resolution = resolveEngineeringMode(enabled: false, events: events);
    expect(resolution.mode, EngineeringRuntimeMode.recoveryRequired);
    expect(resolution.reason, 'disabled-but-open-epoch');
  });

  test('列 true + complete + 已 exit → 需要修复（enabled-but-exited）', () {
    final events = [
      enterPending('e1'),
      enterComplete('e1', captureCount: 1),
      capture('e1', '旧正文'),
      modeEpochExitEvent(epochId: 'e1'),
    ];
    final resolution = resolveEngineeringMode(enabled: true, events: events);
    expect(resolution.mode, EngineeringRuntimeMode.recoveryRequired);
    expect(resolution.reason, 'enabled-but-exited');
  });

  test('列 false + 已退出纪元 → 正常关闭（用户确认退出的终态）', () {
    final events = [
      enterPending('e1'),
      enterComplete('e1', captureCount: 1),
      capture('e1', '旧正文'),
      modeEpochExitEvent(epochId: 'e1'),
    ];
    expect(
      resolveEngineeringMode(enabled: false, events: events).mode,
      EngineeringRuntimeMode.normalClosed,
    );
  });

  test('列 true + complete + 捕获完好 → 正常开启并携带纪元 id', () {
    final events = [
      enterPending('e1', fromTurn: 5),
      capture('e1', 'u1'),
      capture('e1', 'p1'),
      enterComplete('e1', captureCount: 2),
      roundUser(4, 'u5'),
    ];
    final resolution = resolveEngineeringMode(enabled: true, events: events);
    expect(resolution.mode, EngineeringRuntimeMode.normalOpen);
    expect(resolution.epochId, 'e1');
    expect(resolution.reason, isNull);
  });

  test('complete 声称 captureCount>0 而捕获缺失 → 需要修复', () {
    final events = [
      enterPending('e1'),
      enterComplete('e1', captureCount: 3),
      roundUser(2, 'u5'),
    ];
    final resolution = resolveEngineeringMode(enabled: true, events: events);
    expect(resolution.mode, EngineeringRuntimeMode.recoveryRequired);
    expect(resolution.reason, 'capture-missing');
  });

  test('空历史开启（captureCount=0 且无捕获）→ 正常开启（合法空纪元）', () {
    final events = [enterPending('e1'), enterComplete('e1', captureCount: 0)];
    final resolution = resolveEngineeringMode(enabled: true, events: events);
    expect(resolution.mode, EngineeringRuntimeMode.normalOpen);
  });

  test('活跃纪元窗内未知 surface 事件 → 需要修复；纪元前旧事件不影响', () {
    final unknownInWindow = [
      AgentDurableEvent(
        seq: 0,
        type: 'assistant/message',
        surfaceOp: AgentSurfaceOpKind.append,
        data: {'text': '关闭期旧消息'},
      ),
      AgentDurableEvent(seq: 1, type: 'turn/end', data: {'turn': 4}),
      enterPending('e1'),
      enterComplete('e1', captureCount: 0),
      AgentDurableEvent(
        seq: 4,
        type: 'future/unknown-surface',
        surfaceOp: AgentSurfaceOpKind.append,
        data: {},
      ),
    ];
    final blocked = resolveEngineeringMode(
      enabled: true,
      events: unknownInWindow,
    );
    expect(blocked.mode, EngineeringRuntimeMode.recoveryRequired);
    expect(blocked.reason, 'unknown-surface-event');

    // 同一未知事件出现在纪元之前（关闭期史料）不阻塞开启。
    final unknownBeforeEpoch = [
      AgentDurableEvent(
        seq: 0,
        type: 'future/unknown-surface',
        surfaceOp: AgentSurfaceOpKind.append,
        data: {},
      ),
      enterPending('e1'),
      enterComplete('e1', captureCount: 0),
    ];
    expect(
      resolveEngineeringMode(enabled: true, events: unknownBeforeEpoch).mode,
      EngineeringRuntimeMode.normalOpen,
    );
  });

  test('多次开关：投影严格取最新 complete 纪元', () {
    final events = [
      enterPending('e1'),
      capture('e1', '旧纪元捕获'),
      enterComplete('e1', captureCount: 1),
      modeEpochExitEvent(epochId: 'e1'),
      // 退出后经历关闭期轮次
      roundUser(4, '关闭期消息'),
      // 二次进入：全新捕获
      enterPending('e2'),
      capture('e2', '新纪元捕获'),
      enterComplete('e2', captureCount: 1),
    ];
    final resolution = resolveEngineeringMode(enabled: true, events: events);
    expect(resolution.mode, EngineeringRuntimeMode.normalOpen);
    expect(resolution.epochId, 'e2');

    final window = activeEpochWindow(events);
    // 窗口从 e2 的 pending enter 起：不包含 e1 捕获与关闭期消息，
    // 包含 e2 捕获（complete 之前写入——不从 complete 之后起读）。
    final windowContents =
        window.where((e) => e.type == AgentEventTypes.modeCapture).toList();
    expect(windowContents, hasLength(1));
    expect(windowContents.single.data['epochId'], 'e2');
  });

  test('activeEpochWindow：无未退出 complete 纪元 → 空窗', () {
    expect(activeEpochWindow(const []), isEmpty);
    expect(activeEpochWindow([enterPending('e1')]), isEmpty);
    final exited = [
      enterPending('e1'),
      enterComplete('e1', captureCount: 0),
      modeEpochExitEvent(epochId: 'e1'),
    ];
    expect(activeEpochWindow(exited), isEmpty);
  });

  test('unclosedEpochIdOf：pending 残留/complete 未退/全闭合/无纪元', () {
    expect(unclosedEpochIdOf(const []), isNull);
    expect(unclosedEpochIdOf([enterPending('e1')]), 'e1');
    final open = [
      enterPending('e1'),
      enterComplete('e1', captureCount: 0),
      roundUser(2, 'u'),
    ];
    expect(unclosedEpochIdOf(open), 'e1');
    final closed = [
      enterPending('e1'),
      enterComplete('e1', captureCount: 0),
      modeEpochExitEvent(epochId: 'e1'),
    ];
    expect(unclosedEpochIdOf(closed), isNull);
    // 多纪元：只关心最新未闭合
    final multi = [
      enterPending('e1'),
      enterComplete('e1', captureCount: 0),
      modeEpochExitEvent(epochId: 'e1'),
      enterPending('e2'),
    ];
    expect(unclosedEpochIdOf(multi), 'e2');
  });

  test('捕获构造与投影保真：关闭态可见表面逐条物化为纪元捕获', () {
    final visible = [
      AgentMessage.system('【前情压缩摘要】'),
      AgentMessage.user('第一轮输入'),
      AgentMessage.assistant(text: '第一轮正文'),
      AgentMessage.user('〈round-work n=1〉查记忆×2〈/round-work〉'),
    ];
    final events = buildEngineeringCaptureEvents(
      visibleSurface: visible,
      epochId: 'e1',
    );
    expect(events, hasLength(4));
    for (final e in events) {
      expect(e.type, AgentEventTypes.modeCapture);
      expect(e.surfaceOp, AgentSurfaceOpKind.append);
      expect(e.data['epochId'], 'e1');
      expect(e.data['source'], 'mode_capture');
    }
    expect(events.map((e) => e.data['as']).toList(), [
      'system',
      'user',
      'assistant',
      'user',
    ]);

    // 投影逐条还原：角色与内容保真（含摘要 system 消息）。
    final projection = deriveAgentSurface(events);
    expect(projection.messages, hasLength(4));
    expect(projection.messages[0].role, 'system');
    expect(projection.messages[0].content, '【前情压缩摘要】');
    expect(projection.messages[1].role, 'user');
    expect(projection.messages[1].content, '第一轮输入');
    expect(projection.messages[2].role, 'assistant');
    expect(projection.messages[2].content, '第一轮正文');
    expect(projection.messages[3].content, contains('round-work'));
  });

  test('enter 事件为 log-only（不带 surfaceOp），不进投影', () {
    final events = [
      enterPending('e1'),
      enterComplete('e1', captureCount: 0),
      modeEpochExitEvent(epochId: 'e1'),
    ];
    for (final e in events) {
      expect(e.surfaceOp, isNull);
    }
    expect(deriveAgentSurface(events).messages, isEmpty);
  });
}
