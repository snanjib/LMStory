import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_live_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';

/// AdvancedChatState 单元测试（P2 解耦：导演专属 state 拆分）
///
/// 验证：
/// - 初始状态字段（含 session 与 5 个导演字段默认值）
/// - copyWith sentinel 区分"未提供"与"显式 null"
/// - clearAgentSteps 清空 live 步骤列表
/// - clearTemporary 清理临时字段但保留 messages/userInput/session/artifacts
ChatSession _testSession() => ChatSession(
      sessionId: 'dir-1',
      title: '测试导演',
      mode: 'advanced',
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 0,
    );

void main() {
  group('AdvancedChatState', () {
    test('1. initial：phase=idle，导演字段默认值，session 保留', () {
      final session = _testSession();
      final state = AdvancedChatState.initial(session);

      expect(state.phase, IntermediatePhase.idle);
      expect(state.messages, isEmpty);
      expect(state.retryCounts, isEmpty);
      expect(state.liveBlocks, isEmpty);
      expect(state.failureContext, isNull);
      expect(state.agentSteps, isEmpty);
      expect(state.agentWorkSummary, isNull);
      expect(state.agentStoryAnchor, isNull);
      expect(state.agentAskPrompt, isNull);
      expect(state.agentApprovalPrompt, isNull);
      expect(state.session, session);
    });

    test('2. copyWith：未提供保留、显式提供覆盖（liveBlocks/userInput）', () {
      const blocks = [
        AgentLiveBlock(
          kind: AgentLiveBlockKind.text,
          stepIndex: 0,
          text: '流式正文',
        ),
      ];
      final state = AdvancedChatState(
        phase: IntermediatePhase.reviewing,
        messages: [],
        retryCounts: {},
        session: _testSession(),
        liveBlocks: blocks,
        userInput: '用户输入',
      );

      // 未提供 → 保留
      final kept = state.copyWith(phase: IntermediatePhase.idle);
      expect(kept.liveBlocks, blocks);
      expect(kept.userInput, '用户输入');

      // 显式提供 → 覆盖
      final cleared = state.copyWith(
        liveBlocks: const [],
        userInput: null,
      );
      expect(cleared.liveBlocks, isEmpty);
      expect(cleared.userInput, isNull);
    });

    test('3. copyWith(clearAgentSteps: true)：live 步骤清空', () {
      final state = AdvancedChatState.initial(_testSession()).copyWith(
        agentSteps: const [
          AgentWorkStep(
            callId: 'c1',
            toolName: 'query_facts',
            status: AgentStepStatus.running,
          ),
        ],
      );
      expect(state.agentSteps, hasLength(1));

      final cleared = state.copyWith(clearAgentSteps: true);
      expect(cleared.agentSteps, isEmpty);
    });

    test('4. clearTemporary：清临时字段，保留 messages/userInput/session', () {
      final message = ChatMessage(
        messageId: 'm1',
        sessionId: 'dir-1',
        role: 'user',
        content: '推进剧情',
        createdAt: DateTime(2026),
      );
      final state = AdvancedChatState.initial(_testSession()).copyWith(
        messages: [message],
        userInput: '推进剧情',
        liveBlocks: const [
          AgentLiveBlock(
            kind: AgentLiveBlockKind.text,
            stepIndex: 0,
            text: '正文',
          ),
        ],
        failureContext: const FailureContext(
          errorCode: 'EAGENT',
          failedPhase: IntermediatePhase.generating,
          errorMessage: 'x',
          retryable: true,
        ),
        retryCounts: {IntermediatePhase.generating: 2},
      );

      final cleared = state.clearTemporary();

      expect(cleared.phase, IntermediatePhase.idle);
      expect(cleared.liveBlocks, isEmpty);
      expect(cleared.failureContext, isNull);
      expect(cleared.retryCounts, isEmpty);
      // 保留项
      expect(cleared.messages, [message]);
      expect(cleared.userInput, '推进剧情');
      expect(cleared.session, state.session);
    });

    test('clearTemporary 清空 agentSteps（DX-X5：取消后不留孤儿汇总行）', () {
      final state = AdvancedChatState(
        phase: IntermediatePhase.reviewing,
        messages: [],
        retryCounts: {},
        session: _testSession(),
        agentSteps: const [
          AgentWorkStep(toolName: 'search_story'),
        ],
      );
      expect(state.agentSteps, isNotEmpty);
      expect(state.clearTemporary().agentSteps, isEmpty);
    });

    test('clearAgentSteps 同步清空 agentTimeline（对话流 T4：生命周期一致）', () {
      final state = AdvancedChatState(
        phase: IntermediatePhase.reviewing,
        messages: [],
        retryCounts: {},
        session: _testSession(),
        agentSteps: const [AgentWorkStep(toolName: 'search_story')],
        agentTimeline: const [
          AgentTimelineBlock(
            kind: AgentTimelineKind.thinking,
            stepIndex: 0,
            text: '想',
          ),
        ],
      );

      final cleared = state.copyWith(clearAgentSteps: true);

      expect(cleared.agentSteps, isEmpty);
      expect(cleared.agentTimeline, isEmpty);
      expect(cleared.clearTemporary().agentTimeline, isEmpty);
    });
  });

  group('上下文容量字段（上下文用量指示 T4/T5）', () {
    test('initial：容量与回填字段默认 null', () {
      final state = AdvancedChatState.initial(_testSession());
      expect(state.contextWindowTokens, isNull);
      expect(state.compactionTriggerTokens, isNull);
      expect(state.backfilledPromptTokens, isNull);
    });

    test('copyWith：未提供保留、显式 null 可清空', () {
      final state = AdvancedChatState.initial(_testSession()).copyWith(
        contextWindowTokens: 1000000,
        compactionTriggerTokens: 500000,
        backfilledPromptTokens: 152000,
      );
      expect(state.contextWindowTokens, 1000000);
      expect(state.compactionTriggerTokens, 500000);
      expect(state.backfilledPromptTokens, 152000);

      final cleared = state.copyWith(
        contextWindowTokens: null,
        compactionTriggerTokens: null,
        backfilledPromptTokens: null,
      );
      expect(cleared.contextWindowTokens, isNull);
      expect(cleared.compactionTriggerTokens, isNull);
      expect(cleared.backfilledPromptTokens, isNull);
    });
  });

  group('手动压缩字段（上下文用量指示 T9）', () {
    test('默认值与 copyWith 覆盖/清空', () {
      final state = AdvancedChatState.initial(_testSession());
      expect(state.isManualCompacting, isFalse);
      expect(state.manualCompactionDelta, isEmpty);
      expect(state.manualCompactionError, isNull);

      final running = state.copyWith(
        isManualCompacting: true,
        manualCompactionDelta: '部分摘要',
      );
      expect(running.isManualCompacting, isTrue);
      expect(running.manualCompactionDelta, '部分摘要');

      final failed = running.copyWith(manualCompactionError: '超时');
      expect(failed.manualCompactionError, '超时');

      final done = failed.copyWith(
        isManualCompacting: false,
        manualCompactionDelta: '',
        manualCompactionError: null,
      );
      expect(done.isManualCompacting, isFalse);
      expect(done.manualCompactionDelta, isEmpty);
      expect(done.manualCompactionError, isNull);
    });

    test('DN-D1：流式回调只传 delta 不得打穿 busy 标志（sentinel 保留）', () {
      final state = AdvancedChatState.initial(_testSession());
      final running = state.copyWith(isManualCompacting: true);

      // manualCompact 的 onSummaryDelta 回调形态：只传 delta 不传标志
      final streaming = running.copyWith(
        manualCompactionDelta: '${running.manualCompactionDelta}第一段',
      );
      expect(
        streaming.isManualCompacting,
        isTrue,
        reason: '流式增量期间互斥守卫（发送/重生成/重入/UI 置灰）必须仍生效',
      );
      expect(streaming.manualCompactionDelta, '第一段');

      // 任何其他 copyWith（如错误/失败路径）也不得清空 delta
      final errored = streaming.copyWith(manualCompactionError: 'x');
      expect(errored.isManualCompacting, isTrue);
      expect(errored.manualCompactionDelta, '第一段');

      // 显式复位仍生效
      final reset = errored.copyWith(
        isManualCompacting: false,
        manualCompactionDelta: '',
      );
      expect(reset.isManualCompacting, isFalse);
      expect(reset.manualCompactionDelta, isEmpty);
    });
  });
}
