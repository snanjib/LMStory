import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';

/// AgentTimelineBlock 实体与序列化单元测试（2026-08-28 对话流计划）
///
/// 验证：
/// - JSON 往返（三类块、缺省字段、内嵌 AgentWorkStep）
/// - 坏数据容错（整体坏 → 空列表回退；单条坏 → 跳过）
/// - 空列表与 null 输入
void main() {
  group('AgentTimelineBlock 序列化', () {
    test('思考块 JSON 往返', () {
      const block = AgentTimelineBlock(
        kind: AgentTimelineKind.thinking,
        stepIndex: 0,
        text: '先查前情',
        startMs: 0,
        endMs: 6000,
      );

      final restored = AgentTimelineBlock.listFromJsonString(
        AgentTimelineBlock.listToJsonString([block]),
      );

      expect(restored, hasLength(1));
      expect(restored.single.kind, AgentTimelineKind.thinking);
      expect(restored.single.stepIndex, 0);
      expect(restored.single.text, '先查前情');
      expect(restored.single.startMs, 0);
      expect(restored.single.endMs, 6000);
      expect(restored.single.duration, const Duration(seconds: 6));
    });

    test('动作块内嵌 AgentWorkStep 往返（复用现有 JSON 结构）', () {
      const block = AgentTimelineBlock(
        kind: AgentTimelineKind.action,
        stepIndex: 1,
        action: AgentWorkStep(
          toolName: 'search_memories',
          callId: 'call-1',
          title: '「庄园」· 12 处命中',
          durationMs: 800,
        ),
        startMs: 6100,
        endMs: 6900,
      );

      final restored = AgentTimelineBlock.listFromJsonString(
        AgentTimelineBlock.listToJsonString([block]),
      );

      expect(restored, hasLength(1));
      final action = restored.single.action;
      expect(action, isNotNull);
      expect(action!.toolName, 'search_memories');
      expect(action.callId, 'call-1');
      expect(action.title, '「庄园」· 12 处命中');
      expect(action.durationMs, 800);
      expect(restored.single.isAction, isTrue);
      expect(restored.single.isEmpty, isFalse);
    });

    test('播报块缺省起止时刻往返为 null', () {
      const block = AgentTimelineBlock(
        kind: AgentTimelineKind.narration,
        stepIndex: 2,
        text: '前情里没查到这个人，这轮让她自己出场。',
      );

      final restored = AgentTimelineBlock.listFromJsonString(
        AgentTimelineBlock.listToJsonString([block]),
      );

      expect(restored.single.startMs, isNull);
      expect(restored.single.endMs, isNull);
      expect(restored.single.duration, isNull);
    });

    test('纯空白文本块 isEmpty 为 true', () {
      const block = AgentTimelineBlock(
        kind: AgentTimelineKind.narration,
        stepIndex: 2,
        text: '  \n',
      );

      expect(block.isEmpty, isTrue);
    });

    test('endMs 早于 startMs 时 duration 为 null（防御脏数据）', () {
      const block = AgentTimelineBlock(
        kind: AgentTimelineKind.thinking,
        stepIndex: 0,
        text: 'x',
        startMs: 5000,
        endMs: 1000,
      );

      expect(block.duration, isNull);
    });
  });

  group('listFromJsonString 容错', () {
    test('null 与空串 → 空列表（旧数据缺列回退路径）', () {
      expect(AgentTimelineBlock.listFromJsonString(null), isEmpty);
      expect(AgentTimelineBlock.listFromJsonString(''), isEmpty);
    });

    test('空数组往返', () {
      expect(
        AgentTimelineBlock.listFromJsonString(
          AgentTimelineBlock.listToJsonString(const []),
        ),
        isEmpty,
      );
    });

    test('整体非 JSON → 空列表', () {
      expect(AgentTimelineBlock.listFromJsonString('not-json'), isEmpty);
      expect(
        AgentTimelineBlock.listFromJsonString('{"kind":"thinking"}'),
        isEmpty,
      );
    });

    test('单条坏数据跳过，好条目保留', () {
      // 条目本身是合法 JSON 但形状错误（非对象 / 缺 kind）
      const json = '["oops",{"stepIndex":0},{"kind":"narration",'
          '"stepIndex":1,"text":"播报"}]';

      final restored = AgentTimelineBlock.listFromJsonString(json);

      expect(restored, hasLength(1));
      expect(restored.single.text, '播报');
    });

    test('未知 kind 跳过不抛异常', () {
      const json =
          '[{"kind":"future","stepIndex":0},{"kind":"thinking","stepIndex":1,'
          '"text":"思考"}]';

      final restored = AgentTimelineBlock.listFromJsonString(json);

      expect(restored, hasLength(1));
      expect(restored.single.kind, AgentTimelineKind.thinking);
    });
  });

  group('DD1 终态归一（running 不得落库）', () {
    const runningStep = AgentWorkStep(
      toolName: 'finish_round',
      callId: 'call-fin',
      title: '正在执笔…',
      status: AgentStepStatus.running,
      stepIndex: 3,
      startedAtMs: 1000,
    );

    test('toTerminal：running → done，字段原样保留', () {
      final terminal = runningStep.toTerminal();

      expect(terminal.status, AgentStepStatus.done);
      expect(terminal.toolName, 'finish_round');
      expect(terminal.callId, 'call-fin');
      expect(terminal.title, '正在执笔…');
      expect(terminal.stepIndex, 3);
      expect(terminal.startedAtMs, 1000);
    });

    test('toTerminal：非 running 返回自身（零拷贝）', () {
      const done = AgentWorkStep(toolName: 'read_story');
      expect(identical(done.toTerminal(), done), isTrue);
    });

    test('normalizeTerminal：无 running 时返回原列表实例', () {
      const steps = [AgentWorkStep(toolName: 'read_story')];
      expect(identical(AgentWorkStep.normalizeTerminal(steps), steps), isTrue);
    });

    test('normalizeTerminal：混合列表只改 running', () {
      const errorStep = AgentWorkStep(
        toolName: 'query_facts',
        status: AgentStepStatus.error,
      );

      final normalized = AgentWorkStep.normalizeTerminal([
        errorStep,
        runningStep,
      ]);

      expect(normalized[0].status, AgentStepStatus.error);
      expect(normalized[1].status, AgentStepStatus.done);
    });

    test('copyWithAction：只换动作，块字段不变', () {
      const block = AgentTimelineBlock(
        kind: AgentTimelineKind.action,
        stepIndex: 3,
        action: runningStep,
        startMs: 900,
        endMs: 1900,
      );

      final patched = block.copyWithAction(runningStep.toTerminal());

      expect(patched.kind, AgentTimelineKind.action);
      expect(patched.stepIndex, 3);
      expect(patched.startMs, 900);
      expect(patched.endMs, 1900);
      expect(patched.action!.status, AgentStepStatus.done);
      expect(patched.action!.callId, 'call-fin');
    });

    test('normalizeTerminalActions：只归一动作块，文本块不受影响', () {
      const timeline = [
        AgentTimelineBlock(
          kind: AgentTimelineKind.thinking,
          stepIndex: 3,
          text: '该收尾了',
        ),
        AgentTimelineBlock(
          kind: AgentTimelineKind.action,
          stepIndex: 3,
          action: runningStep,
        ),
      ];

      final normalized = AgentTimelineBlock.normalizeTerminalActions(timeline);

      expect(normalized[0].kind, AgentTimelineKind.thinking);
      expect(normalized[0].text, '该收尾了');
      expect(normalized[1].action!.status, AgentStepStatus.done);
    });

    test('normalizeTerminalActions：无 running 时返回原列表实例', () {
      const timeline = [
        AgentTimelineBlock(
          kind: AgentTimelineKind.action,
          stepIndex: 0,
          action: AgentWorkStep(toolName: 'read_story'),
        ),
      ];

      expect(
        identical(
          AgentTimelineBlock.normalizeTerminalActions(timeline),
          timeline,
        ),
        isTrue,
      );
    });
  });
}
