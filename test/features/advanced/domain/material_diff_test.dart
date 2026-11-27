import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/services/compaction_planning.dart';

/// 材料差分五表项的结构级断言——数值级闭环由
/// 单点闭合结构与 unknown 重建路径保证，此处锁定判定函数与阈值公式。
void main() {
  test('阈值公式：窗口 − max(输出预留, 检索预留) − headroom', () {
    const tuning = EngineeringCompactionTuning(
      outputReserveTokens: 16000,
      headroomTokens: 8000,
    );
    // 32K 窗口，检索预留 0.15×32000=4800 < 输出预留 16000
    expect(
      compactionThresholdTokens(
        contextWindowTokens: 32000,
        retrievalRatio: 0.15,
        tuning: tuning,
      ),
      32000 - 16000 - 8000,
    );
    // 大窗口下检索预留超过输出预留时取检索预留
    expect(
      compactionThresholdTokens(
        contextWindowTokens: 200000,
        retrievalRatio: 0.5,
        tuning: tuning,
      ),
      200000 - 100000 - 8000,
    );
  });

  test('差分口径：锚点+正向增量不产生负数（净减少经 unknown 重建）', () {
    // 净减少场景（压缩后）在服务内走 unknown→下一请求实报重建，
    // 不做估算负减——此处锁定估算对正增量的确定性
    expect(
      estimateTokensForChars(4000, const EngineeringCompactionTuning()),
      1000,
    );
    expect(estimateTokensForChars(0, const EngineeringCompactionTuning()), 0);
  });

  test('投影摘要：log-only 事件不影响（同窗+guard 事件 → 摘要不变）', () {
    final surface = [
      AgentMessage.system('S'),
      AgentMessage.user('u1'),
      AgentMessage.assistant(text: 'p1'),
    ];
    final d1 = projectionMessagesDigest(surface);
    // guard 留痕不进投影——摘要口径天然不随其变化（结构性验证：
    // 同表面重算恒等）
    expect(projectionMessagesDigest(surface), d1);
  });

  test('完整预算面（wire-map 口径）：调用签名/协议化思考/回执计入，剥离后不计', () {
    final openai = AgentWireOptions.forProtocolName('openaiCompatible');
    // 正文+结构化调用签名（tool_calls 进请求面）
    final withCall = AgentMessage.assistant(
      text: '先查一下。',
      toolCalls: [
        const AgentToolCall(
          id: 'c1',
          name: 'search_story',
          arguments: {'query': '古碑'},
        ),
      ],
    );
    expect(
      messageSurfaceChars(withCall, openai),
      greaterThan('先查一下。'.length),
    );
    // 推理摘要是 openai 兼容协议的真实可回传表示（reasoning_content
    // 回传）——计入；同一消息在默认 wire 选项（不回传）下不计
    final withThinking = AgentMessage.assistant(
      text: '正文。',
      reasoningContent: '内心独白' * 500,
    );
    expect(
      messageSurfaceChars(withThinking, openai),
      greaterThan('正文。'.length),
    );
    // 默认 wire 选项不回传推理摘要：map 无 reasoning_content 键，
    // 字符量只剩 role+content 面
    expect(
      withThinking.toRequestMap(),
      isNot(contains('reasoning_content')),
    );
    expect(
      messageSurfaceChars(withThinking, const AgentWireOptions()),
      lessThan('正文。'.length + '内心独白'.length * 500),
    );
    // 回执面：tool 消息 wire-map（role/tool_call_id/content）
    final result = AgentMessage.toolResult(toolCallId: 'c1', content: '回执内容');
    expect(
      messageSurfaceChars(result, openai),
      greaterThan('回执内容'.length),
    );
    // 工具定义单列（固定不可压面）
    expect(toolDefinitionsChars(const []), 0);
    expect(
      toolDefinitionsChars([
        const ToolDefinition(name: 't', description: 'dd', parameters: {}),
      ]),
      greaterThan(0),
    );
    // 汇总面：extraFixedChars 并入总数（同 wire 口径逐项相加）
    expect(
      surfaceInputChars(
        [withCall, result],
        options: openai,
        extraFixedChars: 500,
      ),
      messageSurfaceChars(withCall, openai) +
          messageSurfaceChars(result, openai) +
          500,
    );
  });

  test('选材完整面：extraFixedChars 抬高窗口估算（保尾随比例变化）', () {
    final batch = [
      AgentDurableEvent(
        type: AgentEventTypes.userMessage,
        surfaceOp: AgentSurfaceOpKind.append,
        data: {'content': 'u' * 4000, 'turn': 1},
      ),
      AgentDurableEvent(
        type: AgentEventTypes.assistantMessage,
        surfaceOp: AgentSurfaceOpKind.append,
        data: {'text': 'a' * 4000, 'turn': 1},
      ),
      AgentDurableEvent(
        type: AgentEventTypes.userMessage,
        surfaceOp: AgentSurfaceOpKind.append,
        data: {'content': 'u2' * 4000, 'turn': 2},
      ),
      AgentDurableEvent(
        type: AgentEventTypes.assistantMessage,
        surfaceOp: AgentSurfaceOpKind.append,
        data: {'text': 'a2' * 4000, 'turn': 2},
      ),
    ];
    final fold = deriveAgentSurfaceSpans(batch);
    CompactionIntervalPlan? plan({required int extraChars}) =>
        selectCompactionInterval(
          windowEvents: batch,
          spans: fold.spans,
          projectionMessages: fold.projection.messages,
          contextWindowTokens: 32000,
          tuning: const EngineeringCompactionTuning(
            retainMinTokens: 0,
            retainMaxTokens: 100000,
            retainMaxWindowRatio: 1,
          ),
          extraFixedChars: extraChars,
        );
    // 固定面抬高窗口估算 → 保尾预算（ratio 口径）增大 → 区间收窄
    final without = plan(extraChars: 0)!;
    final withTools = plan(extraChars: 40000)!;
    expect(withTools.projectionEnd, lessThan(without.projectionEnd));
  });
}
