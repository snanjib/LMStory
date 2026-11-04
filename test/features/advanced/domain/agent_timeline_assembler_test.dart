import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_live_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/domain/services/agent_timeline_assembler.dart';

/// AgentTimelineAssembler 纯函数单元测试（2026-08-28 对话流计划）
///
/// 验证：
/// - 交错归并：跨 step 的思考/文本/动作按 stepIndex 归并，同 step 内
///   思考 → 动作 → 文本
/// - 同 step 多块（同优先级保持到达序）
/// - 末段升格正文（promoteLastTextAsReply）/ explicitReply 全播报
/// - 无思考退化（思考档位关）、失败中断半截
/// - 起止时刻相对轮起点换算；无时刻信息为 null
void main() {
  test('同一步内发言在工具之前，明确正文不进入幕后', () {
    final timeline = AgentTimelineAssembler.assemble(
      liveBlocks: const [
        AgentLiveBlock(
          kind: AgentLiveBlockKind.thinking,
          stepIndex: 0,
          text: '想',
          order: 0,
        ),
        AgentLiveBlock(
          kind: AgentLiveBlockKind.text,
          stepIndex: 0,
          text: '先查前情',
          order: 1,
        ),
        AgentLiveBlock(
          kind: AgentLiveBlockKind.thinking,
          stepIndex: 1,
          text: '再想',
          order: 3,
        ),
        AgentLiveBlock(
          kind: AgentLiveBlockKind.text,
          stepIndex: 1,
          text: '查完了',
          order: 4,
        ),
        AgentLiveBlock(
          kind: AgentLiveBlockKind.text,
          stepIndex: 1,
          text: '正文',
          order: 5,
          source: AgentTextSource.finishRoundProse,
        ),
      ],
      agentSteps: const [
        AgentWorkStep(toolName: 'search_story', order: 2),
      ],
    );
    expect(timeline.map((b) => b.order), [0, 1, 2, 3, 4]);
    expect(timeline.map((b) => b.kind), [
      AgentTimelineKind.thinking,
      AgentTimelineKind.narration,
      AgentTimelineKind.action,
      AgentTimelineKind.thinking,
      AgentTimelineKind.narration,
    ]);
  });

  group('交错归并', () {
    test('跨 step 归并 + 同 step 思考→动作→文本', () {
      // step0：思考 + 动作 + 文本；step1：思考 + 动作；step2：正文（升格）
      var blocks = AgentLiveTranscript.appendThinking(const [], 0, '查一下');
      blocks = AgentLiveTranscript.appendText(blocks, 0, '先看前情');
      blocks = AgentLiveTranscript.appendThinking(blocks, 1, '该动笔了');
      blocks = AgentLiveTranscript.appendText(blocks, 2, '正文全文');
      final steps = [
        const AgentWorkStep(toolName: 'search'),
        const AgentWorkStep(toolName: 'update_facts', stepIndex: 1),
      ];

      final timeline = AgentTimelineAssembler.assemble(
        liveBlocks: blocks,
        agentSteps: steps,
        promotedIndex: 3,
      );

      expect(timeline.map((b) => b.kind), [
        AgentTimelineKind.thinking, // step0 思考
        AgentTimelineKind.action, // step0 动作
        AgentTimelineKind.narration, // step0 文本（思考→动作→文本）
        AgentTimelineKind.thinking, // step1 思考
        AgentTimelineKind.action, // step1 动作
      ]);
      expect(timeline[1].action!.toolName, 'search');
      expect(timeline[2].text, '先看前情');
    });

    test('同 step 同优先级多块保持到达序', () {
      var blocks = AgentLiveTranscript.appendText(const [], 0, '第一段播报');
      blocks = AgentLiveTranscript.appendThinking(blocks, 0, '想一想');
      blocks = AgentLiveTranscript.appendText(blocks, 0, '第二段播报');

      // 不升格（模拟 explicitReply 已交付）：全部文本进时间线
      final timeline = AgentTimelineAssembler.assemble(
        liveBlocks: blocks,
        agentSteps: const [],
      );

      expect(timeline.map((b) => b.text), ['想一想', '第一段播报', '第二段播报']);
    });

    test('无思考（思考档位关）退化：仅动作与播报', () {
      var blocks = AgentLiveTranscript.appendText(const [], 0, '开工');
      blocks = AgentLiveTranscript.appendText(blocks, 1, '正文');
      final steps = [
        const AgentWorkStep(toolName: 'search'),
        const AgentWorkStep(toolName: 'finish_round', stepIndex: 1),
      ];

      final timeline = AgentTimelineAssembler.assemble(
        liveBlocks: blocks,
        agentSteps: steps,
        promotedIndex: 1,
      );

      expect(timeline.map((b) => b.kind), [
        AgentTimelineKind.action,
        AgentTimelineKind.narration,
        AgentTimelineKind.action,
      ]);
    });

    test('失败中断半截：按现状装配不补块', () {
      var blocks = AgentLiveTranscript.appendThinking(const [], 0, '半截思考');
      blocks = AgentLiveTranscript.appendText(blocks, 1, '半截正');
      final steps = [
        const AgentWorkStep(toolName: 'search'),
        const AgentWorkStep(
          toolName: 'update_facts',
          stepIndex: 1,
          status: AgentStepStatus.running,
        ),
      ];

      final timeline = AgentTimelineAssembler.assemble(
        liveBlocks: blocks,
        agentSteps: steps,
        promotedIndex: 1,
      );

      // 半截正文为末个非空文本段 → 升格稿件卡位，不进时间线
      expect(timeline.map((b) => b.kind), [
        AgentTimelineKind.thinking,
        AgentTimelineKind.action, // search
        AgentTimelineKind.action, // update_facts（running 态原样保留）
      ]);
    });
  });

  group('正文升格与播报', () {
    test('promotedIndex 指定的文本块升格正文，不进时间线（与 pickReplyBlock 同源）', () {
      var blocks = AgentLiveTranscript.appendText(const [], 0, '过渡播报');
      blocks = AgentLiveTranscript.appendText(blocks, 1, '正文全文');

      final timeline = AgentTimelineAssembler.assemble(
        liveBlocks: blocks,
        agentSteps: const [],
        promotedIndex: 1,
      );

      expect(timeline, hasLength(1));
      expect(timeline.single.kind, AgentTimelineKind.narration);
      expect(timeline.single.text, '过渡播报');
    });

    test('explicitReply 已交付（promotedIndex=null）：全部文本进播报', () {
      var blocks = AgentLiveTranscript.appendText(const [], 0, '开工播报');
      blocks = AgentLiveTranscript.appendText(blocks, 1, '收尾播报');

      final timeline = AgentTimelineAssembler.assemble(
        liveBlocks: blocks,
        agentSteps: const [],
      );

      expect(timeline, hasLength(2));
      expect(
        timeline.map((b) => b.kind),
        everyElement(AgentTimelineKind.narration),
      );
    });

    test('promotedIndex 指向倒数首个非空段（pickReplyBlock 同源跳过空白）', () {
      var blocks = AgentLiveTranscript.appendText(const [], 0, '播报');
      blocks = AgentLiveTranscript.appendText(blocks, 1, '正文全文');
      blocks = AgentLiveTranscript.appendText(blocks, 2, '  \n');

      final timeline = AgentTimelineAssembler.assemble(
        liveBlocks: blocks,
        agentSteps: const [],
        promotedIndex: 1,
      );

      expect(timeline, hasLength(1));
      expect(timeline.single.text, '播报');
    });
  });

  group('起止时刻', () {
    test('相对轮起点换算：origin = 最早绝对时刻', () {
      const t0 = 1700000000000;
      var blocks = AgentLiveTranscript.appendThinking(
        const [],
        0,
        '想',
        atMs: t0 + 1000,
      );
      blocks = AgentLiveTranscript.appendThinking(
        blocks,
        0,
        '完了',
        atMs: t0 + 7000,
      );
      blocks = AgentLiveTranscript.appendText(blocks, 1, '正文', atMs: t0);
      const steps = [
        AgentWorkStep(
          toolName: 'search',
          startedAtMs: t0 + 2000,
          durationMs: 800,
        ),
      ];

      final timeline = AgentTimelineAssembler.assemble(
        liveBlocks: blocks,
        agentSteps: steps,
      );

      // origin = t0（step1 文本块最早）
      final thinking = timeline[0];
      expect(thinking.kind, AgentTimelineKind.thinking);
      expect(thinking.startMs, 1000);
      expect(thinking.endMs, 7000);
      expect(thinking.duration, const Duration(seconds: 6));
      final action = timeline[1];
      expect(action.startMs, 2000);
      expect(action.endMs, 2800);
    });

    test('无任何时刻信息：起止为 null（UI 回退字数口径）', () {
      final timeline = AgentTimelineAssembler.assemble(
        liveBlocks: AgentLiveTranscript.appendThinking(const [], 0, '想'),
        agentSteps: const [AgentWorkStep(toolName: 'search')],
      );

      expect(
        timeline.every((b) => b.startMs == null && b.endMs == null),
        isTrue,
      );
    });
  });

  group('空输入', () {
    test('双空 → 空时间线', () {
      expect(
        AgentTimelineAssembler.assemble(
          liveBlocks: const [],
          agentSteps: const [],
        ),
        isEmpty,
      );
    });
  });
}
