import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_events.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/features/advanced/data/agent_durable_event_sink.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/services/agent_log_recovery.dart';
import 'package:lmstory/features/advanced/domain/services/engineering_context_mode.dart';
import 'package:lmstory/features/advanced/domain/services/trajectory_binding.dart';
import 'package:lmstory/features/advanced/domain/services/variant_trajectory.dart';

/// 变体切换轨迹处置（先身份后内容）+ 绑定留痕 + attemptId 盖戳。
void main() {
  AgentDurableEvent ev(
    String type, {
    Map<String, dynamic> data = const {},
    AgentSurfaceOpKind? op,
    int? replaceStart,
    int? replaceEnd,
  }) =>
      AgentDurableEvent(
        type: type,
        data: data,
        surfaceOp: op,
        replaceStart: replaceStart,
        replaceEnd: replaceEnd,
      );

  /// 轮 1 的账本轨迹（attemptId=a1）：u1 → 播报(带工具调用) → 工具结果 → 正文
  List<AgentDurableEvent> turnLedger({
    String attemptId = 'a1',
    String prose = '夜色渐深',
    String userInput = '写一段夜色',
  }) {
    return [
      ev(
        AgentEventTypes.userMessage,
        op: AgentSurfaceOpKind.append,
        data: {
          'content': userInput,
          'turn': 1,
          'attemptId': attemptId,
        },
      ),
      ev(
        AgentEventTypes.assistantMessage,
        op: AgentSurfaceOpKind.append,
        data: {
          'text': '先核对设定。',
          'toolCalls': [
            {
              'id': 'c1',
              'name': 'query_facts',
              'args': {'q': '林涣'},
            },
          ],
          'turn': 1,
          'attemptId': attemptId,
        },
      ),
      ev(
        AgentEventTypes.toolResult,
        op: AgentSurfaceOpKind.append,
        data: {
          'callId': 'c1',
          'toolName': 'query_facts',
          'output': '命中',
          'turn': 1,
          'attemptId': attemptId,
        },
      ),
      ev(
        AgentEventTypes.assistantMessage,
        op: AgentSurfaceOpKind.append,
        data: {'text': prose, 'turn': 1, 'attemptId': attemptId},
      ),
    ];
  }

  group('planVariantSwitch（先身份后内容）', () {
    test('同文不同 attempt：正文散列相等也不保留（身份优先反例锁定）', () {
      final window = turnLedger(); // 轨迹属 a1
      final binding = TrajectoryBindingRecord(
        turn: 1,
        variantIndex: 1,
        // a2 生成了相同正文——散列相等不证明工作来源
        proseHash: trajectoryBindingHash('夜色渐深'),
        inputHash: trajectoryBindingHash('写一段夜色'),
        attemptId: 'a2',
      );
      final plan = planVariantSwitch(
        windowEvents: window,
        turn: 1,
        targetBinding: binding,
        targetProse: '夜色渐深',
      );
      expect(plan, isNotNull);
      expect(plan!.retainTrajectory, isFalse);
      expect(plan.replacement, hasLength(2)); // 遮蔽行 + 新正文
      expect(plan.replacement.first.content, kVariantMaskLine);
      expect(plan.replacement.last.content, '夜色渐深');
      expect(plan.ledgerAttemptId, 'a1');
    });

    test('切回生成轨迹的原版（①∧②双成立）→ 保留、无 surface 变更', () {
      final window = turnLedger(); // 轨迹属 a1
      final binding = TrajectoryBindingRecord(
        turn: 1,
        variantIndex: 0,
        proseHash: trajectoryBindingHash('夜色渐深'),
        inputHash: trajectoryBindingHash('写一段夜色'),
        attemptId: 'a1',
      );
      final plan = planVariantSwitch(
        windowEvents: window,
        turn: 1,
        targetBinding: binding,
        targetProse: '夜色渐深',
      );
      expect(plan!.retainTrajectory, isTrue);
      expect(plan.needsSurfaceChange, isFalse);
    });

    test('切回原版且此前已遮蔽 → 以原轨迹恢复（restore）', () {
      // 第一次切走留下的遮蔽（区间 [1,4) → [遮蔽行, 另一版正文]）
      final masked = [
        ...turnLedger(),
        variantSwitchRebuildEvent(
          VariantSwitchPlan(
            turn: 1,
            retainTrajectory: false,
            replaceStart: 1,
            replaceEnd: 4,
            replacement: [
              AgentMessage.user(kVariantMaskLine),
              AgentMessage.assistant(text: '另一版正文'),
            ],
          ),
        ),
      ];
      final binding = TrajectoryBindingRecord(
        turn: 1,
        variantIndex: 0,
        proseHash: trajectoryBindingHash('夜色渐深'),
        inputHash: trajectoryBindingHash('写一段夜色'),
        attemptId: 'a1',
      );
      final plan = planVariantSwitch(
        windowEvents: masked,
        turn: 1,
        targetBinding: binding,
        targetProse: '夜色渐深',
      );
      expect(plan!.retainTrajectory, isTrue);
      expect(plan.needsSurfaceChange, isTrue);
      // 恢复数组 = 原轨迹（播报+工具结果+原正文），u_j 保留在区间外
      expect(plan.replacement.map((m) => m.role).toList(), [
        'assistant',
        'tool',
        'assistant',
      ]);
      expect(plan.replacement.last.content, '夜色渐深');
      expect(plan.replaceStart, 1);
      expect(plan.replaceEnd, 3); // 当前遮蔽区 [1,3)
    });

    test('身份缺失（无绑定/绑定无 attemptId）→ 保守遮蔽', () {
      final window = turnLedger();
      final noBinding = planVariantSwitch(
        windowEvents: window,
        turn: 1,
        targetBinding: null,
        targetProse: '任意正文',
      );
      expect(noBinding!.retainTrajectory, isFalse);

      final legacyBinding = TrajectoryBindingRecord(
        turn: 1,
        variantIndex: 0,
        proseHash: trajectoryBindingHash('夜色渐深'),
        inputHash: 'legacy',
        // 显式 null：本用例锁定「早期留痕无 attemptId → 保守遮蔽」分支
        // ignore: avoid_redundant_argument_values
        attemptId: null,
      );
      final legacy = planVariantSwitch(
        windowEvents: window,
        turn: 1,
        targetBinding: legacyBinding,
        targetProse: '夜色渐深',
      );
      expect(legacy!.retainTrajectory, isFalse);
    });

    test('正文散列失配（目标正文与留痕不符）→ 遮蔽', () {
      final window = turnLedger();
      final binding = TrajectoryBindingRecord(
        turn: 1,
        variantIndex: 0,
        proseHash: trajectoryBindingHash('夜色渐深'),
        inputHash: '',
        attemptId: 'a1',
      );
      final plan = planVariantSwitch(
        windowEvents: window,
        turn: 1,
        targetBinding: binding,
        targetProse: '被编辑过的正文', // attemptId 同但内容变 → ②失配
      );
      expect(plan!.retainTrajectory, isFalse);
    });

    test('捕获区史前轮（窗内无该轮事件）→ null（事件面无从处置）', () {
      final window = [
        ev(
          AgentEventTypes.modeCapture,
          op: AgentSurfaceOpKind.append,
          data: {'as': 'user', 'content': '旧输入', 'epochId': 'e1'},
        ),
      ];
      expect(
        planVariantSwitch(
          windowEvents: window,
          turn: 1,
          targetBinding: null,
          targetProse: 'x',
        ),
        isNull,
      );
    });
  });

  group('遮蔽/恢复的投影应用（branch/rebuild replace）', () {
    test('遮蔽后投影：u_j 保留 + 单行遮蔽 + 新正文；contentGeneration 递增', () {
      final window = turnLedger();
      final plan = planVariantSwitch(
        windowEvents: window,
        turn: 1,
        targetBinding: null,
        targetProse: '另一版正文',
      )!;
      final projection = deriveAgentSurface([
        ...window,
        variantSwitchRebuildEvent(plan),
      ]);
      expect(projection.messages.map((m) => m.role).toList(), [
        'user', // u_1
        'user', // 遮蔽行
        'assistant', // 新正文
      ]);
      expect(projection.messages[1].content, kVariantMaskLine);
      expect(projection.messages[2].content, '另一版正文');
      expect(projection.contentGeneration, 1);
      // 播报/工具往返被遮蔽（原文仍在账本——shadowed 不删）
    });

    test('restore 后投影恢复原貌（与遮蔽前逐条相等）', () {
      final window = turnLedger();
      final before = deriveAgentSurface(window).messages;
      final maskPlan = planVariantSwitch(
        windowEvents: window,
        turn: 1,
        targetBinding: null,
        targetProse: '另一版正文',
      )!;
      final maskedWindow = [...window, variantSwitchRebuildEvent(maskPlan)];
      final binding = TrajectoryBindingRecord(
        turn: 1,
        variantIndex: 0,
        proseHash: trajectoryBindingHash('夜色渐深'),
        inputHash: '',
        attemptId: 'a1',
      );
      final restorePlan = planVariantSwitch(
        windowEvents: maskedWindow,
        turn: 1,
        targetBinding: binding,
        targetProse: '夜色渐深',
      )!;
      final restored = deriveAgentSurface(
        [...maskedWindow, variantSwitchRebuildEvent(restorePlan)],
      ).messages;
      expect(restored.length, before.length);
      for (var i = 0; i < before.length; i++) {
        expect(restored[i].role, before[i].role);
        expect(restored[i].content, before[i].content);
      }
    });
  });

  group('replay/binding 留痕', () {
    test('事件往返：构造 → 解析 字段一致', () {
      final event = replayBindingEvent(
        turn: 3,
        attemptId: 'att_3_123',
        variantIndex: 1,
        prose: '中文正文 emoji 🌙',
        userInput: '写',
      );
      final record = trajectoryBindingFromEvent(event);
      expect(record, isNotNull);
      expect(record!.turn, 3);
      expect(record.variantIndex, 1);
      expect(record.attemptId, 'att_3_123');
      expect(record.proseHash, trajectoryBindingHash('中文正文 emoji 🌙'));
      // 编码标记 v1 随事件落账
      expect(event.data[kTrajectoryBindingEncodingKey], 'utf8-v1');
    });

    test('无编码标记的旧留痕 → 按未绑定降级（不回退旧算法匹配）', () {
      final legacy = AgentDurableEvent(
        type: AgentEventTypes.replayBinding,
        data: {
          'turn': 1,
          'proseHash': 'deadbeef',
          'inputHash': 'beefdead',
          'variantIndex': 0,
        },
      );
      expect(trajectoryBindingFromEvent(legacy), isNull);
    });

    test('latestBindingForVariant 取同（轮，变体）最新留痕', () {
      final events = [
        replayBindingEvent(
          turn: 1,
          attemptId: 'a1',
          variantIndex: 0,
          prose: 'v0',
          userInput: 'u',
        ),
        replayBindingEvent(
          turn: 1,
          attemptId: 'a2',
          variantIndex: 1,
          prose: 'v1',
          userInput: 'u',
        ),
      ];
      expect(
        latestBindingForVariant(events: events, turn: 1, variantIndex: 0)
            ?.attemptId,
        'a1',
      );
      expect(
        latestBindingForVariant(events: events, turn: 1, variantIndex: 1)
            ?.attemptId,
        'a2',
      );
      expect(
        latestBindingForVariant(events: events, turn: 2, variantIndex: 0),
        isNull,
      );
    });
  });

  group('attemptId 盖戳（sink）', () {
    test('emit 的事件 data 携带 turn 与 attemptId', () async {
      final store = _MemStore();
      final sink = DurableAgentEventSink(
        repository: store,
        sessionId: 's1',
        turnNumber: 5,
        attemptId: 'att_5_999',
      )..emit(
          AgentStepFinished(
            stepIndex: 0,
            stopKind: AgentStepStopKind.textReply,
            promptTokens: 1,
            completionTokens: 1,
            totalTokens: 2,
          ),
        );
      await sink.flush();
      expect(store.events, hasLength(1));
      expect(store.events.single.data['turn'], 5);
      expect(store.events.single.data['attemptId'], 'att_5_999');
    });
  });
}

class _MemStore implements AgentEventLogStore {
  final events = <AgentDurableEvent>[];

  @override
  Future<List<int>> appendAll(
    String sessionId,
    List<AgentDurableEvent> events,
  ) async {
    final seqs = List.generate(events.length, (i) => this.events.length + i);
    this.events.addAll(events);
    return seqs;
  }

  @override
  Future<List<AgentDurableEvent>> readEvents(String sessionId) async =>
      List.of(events);

  @override
  Future<List<AgentDurableEvent>> readModeEpochEvents(String sessionId) =>
      Future.value(const []);

  @override
  Future<bool> deleteTurnEvents(
    String sessionId,
    int turn, {
    Future<void> Function()? rollbackStory,
    Future<EngineeringEnterCapture> Function(String epochId)? captureHistory,
  }) async =>
      false;

  @override
  Future<int> trimToRecentTurns(String sessionId, int keepTurns) async => 0;

  @override
  Future<void> deleteAtSeqs(String sessionId, List<int> seqs) async {}
}
