import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/services/engineering_context_mode.dart';

/// 捕获集合完整性：complete 声称的捕获数必须能证明「所指集合
/// 仍完整在场且纯净」——同序号重复顶替丢失条目、他纪元捕获混入活跃
/// 窗口都是集合破损，进入需要修复态；投影只消费合格集合。
void main() {
  test('equal count duplicate must not replace a missing captured message', () {
    final captures = buildEngineeringCaptureEvents(
      visibleSurface: [
        AgentMessage.user('甲'),
        AgentMessage.assistant(text: '乙'),
      ],
      epochId: 'epoch',
    );
    final events = [
      modeEpochEnterPendingEvent(epochId: 'epoch', fromTurn: 1),
      captures.first,
      captures.first, // 同序号重复：乙被甲顶替但计数巧合=2
      modeEpochEnterCompleteEvent(epochId: 'epoch', captureCount: 2),
    ];
    expect(
      resolveEngineeringMode(enabled: true, events: events).mode,
      EngineeringRuntimeMode.recoveryRequired,
    );
  });

  test('wrong epoch capture cannot enter the active projected surface', () {
    final captures = buildEngineeringCaptureEvents(
      visibleSurface: [
        AgentMessage.user('甲'),
        AgentMessage.assistant(text: '乙'),
      ],
      epochId: 'epoch',
    );
    final events = [
      modeEpochEnterPendingEvent(epochId: 'epoch', fromTurn: 1),
      ...captures,
      ...buildEngineeringCaptureEvents(
        visibleSurface: [AgentMessage.user('错误纪元混入')],
        epochId: 'wrong',
      ),
      modeEpochEnterCompleteEvent(epochId: 'epoch', captureCount: 2),
    ];
    // 保护语义：他纪元内容不得到达模型表面（投影只消费合格集合）
    final projected = deriveAgentSurface(activeEpochWindow(events)).messages;
    expect(
      projected.map((m) => m.content),
      isNot(contains('错误纪元混入')),
    );
    expect(
      projected.map((m) => m.content),
      containsAll(['甲', '乙']),
    );
    // 且三态解析停在需要修复（原事件保留，不删不猜）
    expect(
      resolveEngineeringMode(enabled: true, events: events).mode,
      EngineeringRuntimeMode.recoveryRequired,
    );
    expect(
      resolveEngineeringMode(enabled: true, events: events).reason,
      'capture-foreign-epoch',
    );
  });

  test('正常进入（带集合序号）与合法空捕获仍可用（正向保留）', () {
    final captures = buildEngineeringCaptureEvents(
      visibleSurface: [
        AgentMessage.user('甲'),
        AgentMessage.assistant(text: '乙'),
      ],
      epochId: 'epoch',
    );
    final events = [
      modeEpochEnterPendingEvent(epochId: 'epoch', fromTurn: 1),
      ...captures,
      modeEpochEnterCompleteEvent(epochId: 'epoch', captureCount: 2),
    ];
    final resolution = resolveEngineeringMode(enabled: true, events: events);
    expect(resolution.mode, EngineeringRuntimeMode.normalOpen);
    expect(resolution.epochId, 'epoch');
    // 空会话进入：声称 0 条、无捕获 → 正常开启
    final empty = [
      modeEpochEnterPendingEvent(epochId: 'e2', fromTurn: 1),
      modeEpochEnterCompleteEvent(epochId: 'e2', captureCount: 0),
    ];
    expect(
      resolveEngineeringMode(enabled: true, events: empty).mode,
      EngineeringRuntimeMode.normalOpen,
    );
  });

  test('旧格式捕获（无集合序号）按计数口径兼容：合法历史不误伤', () {
    AgentDurableEvent legacyCapture(String content) => AgentDurableEvent(
          type: AgentEventTypes.modeCapture,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {
            'as': 'user',
            'content': content,
            'epochId': 'epoch',
            'source': 'mode_capture',
          },
        );
    final events = [
      modeEpochEnterPendingEvent(epochId: 'epoch', fromTurn: 1),
      legacyCapture('甲'),
      legacyCapture('乙'),
      modeEpochEnterCompleteEvent(epochId: 'epoch', captureCount: 2),
    ];
    expect(
      resolveEngineeringMode(enabled: true, events: events).mode,
      EngineeringRuntimeMode.normalOpen,
    );
    // 旧格式计数不足仍是缺失（原保护不变）
    final missing = [
      modeEpochEnterPendingEvent(epochId: 'epoch', fromTurn: 1),
      legacyCapture('甲'),
      modeEpochEnterCompleteEvent(epochId: 'epoch', captureCount: 4),
    ];
    expect(
      resolveEngineeringMode(enabled: true, events: missing).mode,
      EngineeringRuntimeMode.recoveryRequired,
    );
    expect(
      resolveEngineeringMode(enabled: true, events: missing).reason,
      'capture-missing',
    );
  });
}
