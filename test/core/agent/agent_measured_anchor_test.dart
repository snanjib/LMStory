import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_budget.dart';
import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_events.dart';
import 'package:lmstory/core/agent/agent_llm_gateway.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/agent/agent_runner.dart';
import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/core/llm/llm_usage.dart';

/// 可靠实报输入锚点：usage 与锚点材料必须属于同一请求。
/// 末步缺 usage/计量异常（warnings）不得把旧请求的实报配到新表面上；
/// lastOutgoing 语义保持不变（末次请求出站面，不论计量）。
void main() {
  test('completion-only usage must preserve previous reliable input anchor',
      () async {
    final gateway = _ScriptedGateway([
      const AgentStepResponse(
        text: 'lookup',
        toolCalls: [AgentToolCall(id: 'c1', name: 'echo', arguments: {})],
        usage: LlmUsage(promptTokens: 1000, totalInputTokens: 1000),
      ),
      // 末步仅输出 usage（无输入字段）：本请求没有有效输入实报，不得
      // 把原可靠配对覆盖成 input=0（累计器归零不是可靠输入）
      const AgentStepResponse(
        text: 'done',
        toolCalls: [],
        usage: LlmUsage(completionTokens: 50),
      ),
    ]);
    final result = await AgentRunner(gateway: gateway).runTurn(
      AgentTurnSpec(
        sessionId: 's',
        surface: [AgentMessage.user('continue')],
        tools: const [_EchoTool()],
        endpoint: _endpoint,
        budget: const AgentBudget(contextWindowTokens: 100000),
        events: _Sink(),
        cancellation: AgentCancellationToken(),
      ),
    );
    expect(gateway.requests, hasLength(2));
    expect(result.lastOutgoingMessages, hasLength(3));
    expect(result.usage.lastCompleteInputTokens, 0);
    final anchor = result.measuredInputAnchor;
    expect(anchor, isNotNull);
    expect(anchor!.inputTokens, 1000, reason: '仅输出 usage 不得覆盖原配对');
    expect(
      anchor.outgoingMessages,
      hasLength(gateway.requests.first.messages.length),
      reason: 'input 0 不得配到未计量请求 2 的表面',
    );
  });

  test('usable input anchor must belong to the paired outgoing surface',
      () async {
    final gateway = _ScriptedGateway([
      const AgentStepResponse(
        text: 'lookup',
        toolCalls: [AgentToolCall(id: 'c1', name: 'echo', arguments: {})],
        usage: LlmUsage(promptTokens: 1000, totalInputTokens: 1000),
      ),
      const AgentStepResponse(text: 'done', toolCalls: []),
    ]);
    final result = await AgentRunner(gateway: gateway).runTurn(
      AgentTurnSpec(
        sessionId: 's',
        surface: [AgentMessage.user('continue')],
        tools: const [_EchoTool()],
        endpoint: _endpoint,
        budget: const AgentBudget(contextWindowTokens: 100000),
        events: _Sink(),
        cancellation: AgentCancellationToken(),
      ),
    );
    expect(gateway.requests, hasLength(2));
    // lastOutgoing 语义不变：末次请求出站面（3 条=1 输入+工具往返+正文）
    expect(result.lastOutgoingMessages, hasLength(3));
    expect(result.usage.lastCompleteInputTokens, 1000);
    // 可靠锚点=请求 1 的成对快照：实报 1000 只配请求 1 自己的表面
    final anchor = result.measuredInputAnchor;
    expect(anchor, isNotNull);
    expect(anchor!.inputTokens, 1000);
    expect(
      anchor.outgoingMessages,
      hasLength(gateway.requests.first.messages.length),
      reason:
          'positive anchor 1000 must not be paired with unmeasured request 2',
    );
  });

  test('合法连续 usage：锚点随步覆盖为最后一次可靠配对', () async {
    final gateway = _ScriptedGateway([
      const AgentStepResponse(
        text: 'step1',
        toolCalls: [AgentToolCall(id: 'c1', name: 'echo', arguments: {})],
        usage: LlmUsage(promptTokens: 1000, totalInputTokens: 1000),
      ),
      const AgentStepResponse(
        text: 'done',
        toolCalls: [],
        usage: LlmUsage(promptTokens: 2000, totalInputTokens: 2000),
      ),
    ]);
    final result = await AgentRunner(gateway: gateway).runTurn(
      AgentTurnSpec(
        sessionId: 's',
        surface: [AgentMessage.user('continue')],
        tools: const [_EchoTool()],
        endpoint: _endpoint,
        budget: const AgentBudget(contextWindowTokens: 100000),
        events: _Sink(),
        cancellation: AgentCancellationToken(),
      ),
    );
    final anchor = result.measuredInputAnchor!;
    expect(anchor.inputTokens, 2000);
    // 成对面=最后一次请求自己的出站面（结构变化后配对跟着走）
    expect(
      anchor.outgoingMessages,
      hasLength(gateway.requests.last.messages.length),
    );
    expect(anchor.outgoingMessages.length, greaterThan(1));
  });

  test('计量异常（warnings）不更新锚点：保留上一个可靠配对', () async {
    final gateway = _ScriptedGateway([
      const AgentStepResponse(
        text: 'step1',
        toolCalls: [AgentToolCall(id: 'c1', name: 'echo', arguments: {})],
        usage: LlmUsage(promptTokens: 1000, totalInputTokens: 1000),
      ),
      // 冲突 usage：字段异常（input < cache read 等 warnings 生成路径）
      const AgentStepResponse(
        text: 'done',
        toolCalls: [],
        usage: LlmUsage(
          promptTokens: 500,
          totalInputTokens: 2000,
          cacheReadTokens: 3000,
          warnings: ['cache_read > input'],
        ),
      ),
    ]);
    final result = await AgentRunner(gateway: gateway).runTurn(
      AgentTurnSpec(
        sessionId: 's',
        surface: [AgentMessage.user('continue')],
        tools: const [_EchoTool()],
        endpoint: _endpoint,
        budget: const AgentBudget(contextWindowTokens: 100000),
        events: _Sink(),
        cancellation: AgentCancellationToken(),
      ),
    );
    final anchor = result.measuredInputAnchor;
    expect(anchor, isNotNull);
    expect(anchor!.inputTokens, 1000, reason: '异常计量的请求不更新配对');
    expect(
      anchor.outgoingMessages,
      hasLength(gateway.requests.first.messages.length),
      reason: '锚点表面仍是上一次可靠请求的出站面',
    );
  });

  test('子代理并账不污染父轮锚点口径（last* 不随 merge 覆盖）', () {
    final parent = AgentUsageAccumulator()
      ..add(const LlmUsage(promptTokens: 1000, totalInputTokens: 1000));
    final child = AgentUsageAccumulator()
      ..add(const LlmUsage(promptTokens: 5000, totalInputTokens: 5000));
    // 子代理并账：last* 分项语义是父轮最后一次请求看到的上下文
    parent.merge(child, carryLastRequest: false);
    expect(parent.lastCompleteInputTokens, 1000);
    // 父轮自己的后续请求仍可覆盖（合法路径不回退）
    parent.add(const LlmUsage(promptTokens: 1200, totalInputTokens: 1200));
    expect(parent.lastCompleteInputTokens, 1200);
  });
}

class _Sink implements AgentEventSink {
  @override
  void emit(AgentRunEvent event) {}
}

const _endpoint = AgentModelEndpoint(
  baseUrl: 'https://api.onward/v1',
  apiKey: 'k',
  modelId: 'm',
  protocol: 'openaiCompatible',
);

class _ScriptedGateway implements AgentLlmGateway {
  _ScriptedGateway(this.script);

  final List<AgentStepResponse> script;
  final List<AgentStepRequest> requests = [];
  int cursor = 0;

  @override
  Future<AgentStepResponse> completeStep({
    required AgentModelEndpoint endpoint,
    required AgentStepRequest request,
    required AgentCancellationToken cancellation,
    void Function(String delta)? onTextDelta,
    void Function(String delta)? onThinkingDelta,
    void Function(String toolCallId, String toolName, String delta)?
        onToolArgDelta,
  }) async {
    requests.add(request);
    return script[cursor++];
  }
}

class _EchoTool implements AgentTool {
  const _EchoTool();

  @override
  String get name => 'echo';

  @override
  String get description => 'echo';

  @override
  AgentToolPermission get permission => AgentToolPermission.readOnly;

  @override
  Map<String, dynamic> buildParametersSchema() => const {'type': 'object'};

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    return AgentToolResult.success(title: 'echo', output: '回声');
  }
}
