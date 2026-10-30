import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_budget.dart';
import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_events.dart';
import 'package:lmstory/core/agent/agent_llm_gateway.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/agent/agent_runner.dart';
import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/core/agent/doom_loop_detector.dart';
import 'package:lmstory/features/advanced/domain/services/agent_event_bus.dart';
import 'package:lmstory/features/advanced/domain/services/agent_system_prompt.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// 脚本化假网关：按顺序返回预置响应，记录收到的请求
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
    if (cursor >= script.length) {
      throw const AgentLlmException('script exhausted', retryable: false);
    }
    final response = script[cursor++];
    onTextDelta?.call(response.text);
    return response;
  }
}

/// 失败 N 次后成功的网关（重试验证）
class _FlakyGateway implements AgentLlmGateway {
  _FlakyGateway({required this.failures, required this.thenResponse});
  final int failures;
  final AgentStepResponse thenResponse;
  int attempts = 0;

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
    attempts++;
    if (attempts <= failures) {
      throw const AgentLlmException('network down', code: '503');
    }
    return thenResponse;
  }
}

/// 首次抛 429+Retry-After，之后成功（重试等待可视化验证）
class _RateLimitedGateway implements AgentLlmGateway {
  _RateLimitedGateway({required this.thenResponse});

  final AgentStepResponse thenResponse;
  int attempts = 0;

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
    attempts++;
    if (attempts == 1) {
      throw const AgentLlmException(
        'rate limited',
        code: '429',
        retryAfter: Duration(milliseconds: 800),
      );
    }
    return thenResponse;
  }
}

/// 前N次抛上下文超限，之后成功（溢出自愈验证）
class _OverflowGateway implements AgentLlmGateway {
  _OverflowGateway({required this.overflows, required this.thenResponse});

  final int overflows;
  final AgentStepResponse thenResponse;
  final List<AgentStepRequest> requests = [];
  int attempts = 0;

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
    attempts++;
    if (attempts <= overflows) {
      throw const AgentLlmException(
        "This model's maximum context length is 128000 tokens. "
        'However, you requested 200000 tokens.',
        code: '400',
        retryable: false,
        semantic: AgentLlmErrorSemantic.contextOverflow,
      );
    }
    onTextDelta?.call(thenResponse.text);
    return thenResponse;
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
    return AgentToolResult.success(
      title: 'echo',
      output: 'echoed: ${arguments['text']}',
    );
  }
}

class _FinishTool implements AgentTool {
  const _FinishTool();

  @override
  String get name => 'finish_round';

  @override
  String get description => 'finish';

  @override
  AgentToolPermission get permission => AgentToolPermission.control;

  @override
  Map<String, dynamic> buildParametersSchema() => const {'type': 'object'};

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    return AgentToolResult.terminal(title: 'finish', output: 'done');
  }
}

/// 可编程 finish_round（按序吐结果；模拟闸门连拒/守卫信封/提交失败）
class _ScriptedFinishTool implements AgentTool {
  _ScriptedFinishTool(this.results);

  final List<AgentToolResult> results;
  int _cursor = 0;

  @override
  String get name => 'finish_round';

  @override
  String get description => 'finish';

  @override
  AgentToolPermission get permission => AgentToolPermission.control;

  @override
  Map<String, dynamic> buildParametersSchema() => const {'type': 'object'};

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async =>
      results[_cursor++];
}

AgentStepResponse _text([String text = '好的，这是回复。']) {
  return AgentStepResponse(
    text: text,
    toolCalls: const [],
    usage: const LlmUsage(promptTokens: 100, completionTokens: 20),
  );
}

/// 弱模型弃疗形态：无文本、无工具调用的空响应
AgentStepResponse _emptyResp() {
  return const AgentStepResponse(
    text: '',
    toolCalls: [],
    usage: LlmUsage(promptTokens: 100, completionTokens: 0),
  );
}

/// 推理烧完输出预算的截断形态：无文本、无工具、finish_reason=length
AgentStepResponse _lengthTruncated() {
  return const AgentStepResponse(
    text: '',
    toolCalls: [],
    usage: LlmUsage(promptTokens: 100, completionTokens: 4000),
    finishReason: 'length',
  );
}

/// 正文与工具调用同发（正文已流出但轮次未结束的形态）
AgentStepResponse _textWithCall(
  String text,
  String name,
  Map<String, dynamic> args, {
  String id = 'call_1',
}) {
  return AgentStepResponse(
    text: text,
    toolCalls: [AgentToolCall(id: id, name: name, arguments: args)],
    usage: const LlmUsage(promptTokens: 100, completionTokens: 50),
  );
}

AgentStepResponse _call(
  String name,
  Map<String, dynamic> args, {
  String id = 'call_1',
}) {
  return AgentStepResponse(
    text: '',
    toolCalls: [
      AgentToolCall(id: id, name: name, arguments: args),
    ],
    usage: const LlmUsage(promptTokens: 100, completionTokens: 10),
  );
}

AgentTurnSpec _spec(
  AgentLlmGateway gateway, {
  required List<AgentMessage> surface,
  List<AgentTool> tools = const [_EchoTool()],
  AgentBudget budget = const AgentBudget(maxDuration: null),
  Set<String> deniedTools = const {},
  DoomLoopDetector? doomLoopDetector,
  AgentRunnerHooks hooks = const AgentRunnerHooks.empty(),
  AgentEventSink? events,
  AgentCancellationToken? cancellation,
  String? penReminderText,
  AgentCallConfig callConfig = const AgentCallConfig(),
  AgentOverflowCompactor? overflowCompactor,
  AgentResumeSeed? resumeSeed,
}) {
  return AgentTurnSpec(
    sessionId: 'test',
    surface: surface,
    tools: tools,
    endpoint: const AgentModelEndpoint(
      baseUrl: 'https://api.test.com',
      modelId: 'test-model',
      protocol: 'openaiCompatible',
    ),
    budget: budget,
    deniedTools: deniedTools,
    doomLoopDetector: doomLoopDetector,
    hooks: hooks,
    events: events ?? BufferingAgentEventSink(),
    cancellation: cancellation ?? AgentCancellationToken(),
    penReminderText: penReminderText,
    callConfig: callConfig,
    overflowCompactor: overflowCompactor,
    resumeSeed: resumeSeed,
  );
}

void main() {
  group('AgentRunner 基本循环', () {
    test('直接文本回复：单 step 完成', () async {
      final gateway = _ScriptedGateway([_text('第一幕开始了。')]);
      final runner = AgentRunner(gateway: gateway);
      final sink = BufferingAgentEventSink();

      final result = await runner.runTurn(
        _spec(gateway, surface: [AgentMessage.user('开始')], events: sink),
      );

      expect(result.reason, AgentStopReason.completed);
      expect(result.steps, 1);
      expect(result.lastAssistantText, '第一幕开始了。');
      expect(result.usage.totalTokens, 120);
      expect(gateway.requests, hasLength(1));
      // 请求消息 = surface + wire 化
      expect(gateway.requests.first.messages.first['role'], 'user');
      expect(sink.of<AgentStepFinished>(), hasLength(1));
    });

    test('工具调用 → 结果回传 → 最终回复：两 step 完成', () async {
      final gateway = _ScriptedGateway([
        _call('echo', {'text': 'hi'}),
        _text('我看到了 hi。'),
      ]);
      final runner = AgentRunner(gateway: gateway);
      final sink = BufferingAgentEventSink();

      final result = await runner.runTurn(
        _spec(gateway, surface: [AgentMessage.user('echo hi')], events: sink),
      );

      expect(result.reason, AgentStopReason.completed);
      expect(result.steps, 2);
      expect(
        result.appendedMessages,
        hasLength(3),
      ); // assistant + tool + assistant

      // 第二次请求应包含 tool 结果消息
      final secondRequest = gateway.requests[1];
      final toolMsg = secondRequest.messages.where((m) => m['role'] == 'tool');
      expect(toolMsg, hasLength(1));
      expect(toolMsg.first['tool_call_id'], 'call_1');
      expect(toolMsg.first['content'], 'echoed: hi');

      expect(sink.of<AgentToolExecutionFinished>(), hasLength(1));
    });

    test('控制工具（terminal）终结轮次', () async {
      final gateway = _ScriptedGateway([
        _call('finish_round', {}, id: 'call_f'),
      ]);
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('结束')],
          tools: const [_FinishTool()],
        ),
      );

      expect(result.reason, AgentStopReason.completedByTool);
      expect(result.steps, 1);
    });

    test('未知工具：可操作失败信封，不中断轮次', () async {
      final gateway = _ScriptedGateway([
        _call('nonexistent_tool', {}),
        _text('好吧。'),
      ]);
      final runner = AgentRunner(gateway: gateway);
      final sink = BufferingAgentEventSink();

      final result = await runner.runTurn(
        _spec(gateway, surface: [AgentMessage.user('x')], events: sink),
      );

      expect(result.reason, AgentStopReason.completed);
      final toolMsg =
          gateway.requests[1].messages.where((m) => m['role'] == 'tool').first;
      expect(toolMsg['content'], contains('不存在'));
      final finished = sink.of<AgentToolExecutionFinished>().first;
      expect(finished.isError, isTrue);
    });

    test('B7-1：被 deny 的工具 → 信封报「已被禁用」而非「不存在」', () async {
      final gateway = _ScriptedGateway([
        _call('read_skill', {}),
        _text('好吧。'),
      ]);
      final runner = AgentRunner(gateway: gateway);
      final sink = BufferingAgentEventSink();

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('x')],
          deniedTools: const {'read_skill'},
          events: sink,
        ),
      );

      expect(result.reason, AgentStopReason.completed);
      final toolMsg =
          gateway.requests[1].messages.where((m) => m['role'] == 'tool').first;
      expect(toolMsg['content'], contains('已被导演禁用'));
      expect(toolMsg['content'], isNot(contains('不存在')));
    });
  });

  group('B7-2 repeat-tool 递进提醒', () {
    test('同参连调 3/5 次 → 注入递进提醒；到阈值 8 → doom 停轮', () async {
      final gateway = _ScriptedGateway([
        for (var i = 0; i < 8; i++) _call('echo', {'text': 'same'}, id: 'c$i'),
      ]);
      final sink = BufferingAgentEventSink();
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('x')],
          events: sink,
        ),
      );

      // 阈值 8 停轮；3/5 两次递进提醒
      expect(result.reason, AgentStopReason.doomLoop);
      final reminders = sink
          .of<AgentInjectedMessageEvent>()
          .where((e) => e.kind == AgentInjectedMessageKinds.repeatToolReminder)
          .toList();
      expect(reminders, hasLength(2));
      expect(reminders[0].message.content, contains('连续 3 次'));
      expect(reminders[1].message.content, contains('连续 5 次'));
    });

    test('递进提醒位于本轮工具结果之后（OpenAI tool 消息相邻性）', () async {
      final gateway = _ScriptedGateway([
        _call('echo', {'text': 'same'}, id: 'c0'),
        _call('echo', {'text': 'same'}, id: 'c1'),
        _call('echo', {'text': 'same'}, id: 'c2'),
        _text('收到，改为直接输出。'),
      ]);
      final sink = BufferingAgentEventSink();
      final runner = AgentRunner(gateway: gateway);

      await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('x')],
          events: sink,
        ),
      );

      // 第 4 次请求 = 第 3 次同参调用（streak 3 触发提醒）之后的请求
      final msgs = gateway.requests[3].messages;
      final reminderIdx = msgs.indexWhere(
        (m) => (m['content'] as String?)?.contains('连续 3 次') ?? false,
      );
      expect(reminderIdx, greaterThanOrEqualTo(0));
      final lastAssistantIdx = msgs.lastIndexWhere(
        (m) => m['role'] == 'assistant',
      );
      // OpenAI 兼容端点要求 tool 消息紧跟带 tool_calls 的 assistant 消息，
      // 提醒不得插在两者中间
      expect(msgs[lastAssistantIdx + 1]['role'], 'tool');
      expect(reminderIdx, greaterThan(lastAssistantIdx + 1));
    });
  });

  group('长度截断：直接报错不自动重试', () {
    test('finish_reason=length 且空正文 → 带诊断停止（单请求，不提额）', () async {
      final gateway = _ScriptedGateway([_lengthTruncated()]);
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('开始')],
          callConfig: const AgentCallConfig(maxTokens: 1000),
        ),
      );

      expect(result.reason, AgentStopReason.completed);
      // 不自动重试：只发了一次请求
      expect(gateway.requests, hasLength(1));
      expect(result.errorMessage, contains('finish_reason=length'));
      expect(result.errorMessage, contains('输出上限 1000'));
      expect(result.errorMessage, contains('调大「输出上限」'));
    });

    test('未设置输出上限时也带诊断停止（无「输出上限 X」字样）', () async {
      final gateway = _ScriptedGateway([_lengthTruncated()]);
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(gateway, surface: [AgentMessage.user('开始')]),
      );

      expect(result.reason, AgentStopReason.completed);
      expect(gateway.requests, hasLength(1));
      expect(result.errorMessage, contains('finish_reason=length'));
      expect(result.errorMessage, isNot(contains('输出上限 ')));
    });
  });

  group('空响应救援（弱模型弃疗 nudge）', () {
    test('空响应 → 注入续跑提示 → 模型回正文 → completed', () async {
      final gateway = _ScriptedGateway([_emptyResp(), _text('正文来了。')]);
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(gateway, surface: [AgentMessage.user('开始')]),
      );

      expect(result.reason, AgentStopReason.completed);
      expect(result.steps, 2);
      expect(result.lastAssistantText, '正文来了。');
      // 第二次请求应包含续跑提示：role=user + workbench-reminder 包裹
      final nudgeMsg = gateway.requests[1].messages
          .where((m) => m['role'] == 'user')
          .lastWhere((m) => (m['content'] as String).contains('空回复'));
      expect(nudgeMsg['content'], contains(kWorkbenchReminderOpen));
    });

    test('连续空响应只救一次，二次仍空则停止（completed 交上层判失败）', () async {
      final gateway = _ScriptedGateway([_emptyResp(), _emptyResp()]);
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(gateway, surface: [AgentMessage.user('开始')]),
      );

      expect(result.reason, AgentStopReason.completed);
      expect(gateway.requests, hasLength(2));
    });

    test('正文已流出后的空响应不救援', () async {
      final gateway = _ScriptedGateway([
        _textWithCall('长' * 250, 'echo', {'text': 'hi'}),
        _emptyResp(),
      ]);
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(gateway, surface: [AgentMessage.user('开始')]),
      );

      expect(result.reason, AgentStopReason.completed);
      expect(result.lastAssistantText, '长' * 250);
      // 空响应直接停轮，没有注入续跑提示（无第三次请求）
      expect(gateway.requests, hasLength(2));
      expect(
        gateway.requests[1].messages.where((m) => m['role'] == 'system'),
        isEmpty,
      );
    });
  });

  group('预算与停止条件', () {
    test('maxSteps 耗尽 → 软着陆：注入通牒+纯文本收尾 → completed', () async {
      // 模型前 3 步一直调工具，软着陆后第 4 步用纯文本收尾
      final gateway = _ScriptedGateway([
        ...List.generate(
          3,
          (i) => _call('echo', {'text': 'n$i'}, id: 'call_$i'),
        ),
        _text('他推开院门，雨还在下。'),
      ]);
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('loop')],
          budget: const AgentBudget(maxSteps: 3, maxDuration: null),
        ),
      );

      // 软着陆不判整轮失败：模型用现有材料输出正文，正常完成
      expect(result.reason, AgentStopReason.completed);
      expect(result.steps, 4);
      expect(gateway.requests, hasLength(4));
      // 最后一次请求：工具已停用（空工具列表）+ 尾部有通牒消息
      //（：role=user + workbench-reminder 包裹，不再走裸 system）
      expect(gateway.requests.last.tools, isEmpty);
      final lastMessages = gateway.requests.last.messages;
      expect(
        lastMessages.any(
          (m) =>
              m['role'] == 'user' &&
              (m['content'] as String).contains('工具已停用') &&
              (m['content'] as String).contains(kWorkbenchReminderOpen),
        ),
        isTrue,
      );
      expect(result.lastAssistantText, '他推开院门，雨还在下。');
    });

    test('maxSteps 软着陆后模型仍调工具 → 工具停用信封 → 二次耗尽停止', () async {
      final gateway = _ScriptedGateway(
        List.generate(
          10,
          (i) => _call('echo', {'text': 'n$i'}, id: 'call_$i'),
        ),
      );
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('loop')],
          budget: const AgentBudget(maxSteps: 3, maxDuration: null),
        ),
      );

      // 软着陆给了收尾机会但模型仍不收笔 → 二次到达上限才真正停止
      expect(result.reason, AgentStopReason.maxSteps);
      expect(gateway.requests, hasLength(4));
    });

    test('maxSteps=0（无上限）→ 不触发软着陆，模型自然收尾', () async {
      final gateway = _ScriptedGateway([
        ...List.generate(
          5,
          (i) => _call('echo', {'text': 'n$i'}, id: 'call_$i'),
        ),
        _text('他推开院门，雨还在下。'),
      ]);
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('loop')],
          budget: const AgentBudget(maxSteps: 0, maxDuration: null),
        ),
      );

      // 步数不设限：5 步工具 + 1 步收尾全部执行，不判预算停止
      expect(result.reason, AgentStopReason.completed);
      expect(result.steps, 6);
      expect(gateway.requests, hasLength(6));
      // 无上限不应注入通牒或停用工具（与软着陆路径的区别）
      for (final request in gateway.requests) {
        expect(request.tools, isNotEmpty);
        expect(
          request.messages.any(
            (m) =>
                m['role'] == 'system' &&
                (m['content'] as String).contains('工具已停用'),
          ),
          isFalse,
        );
      }
    });

    test('token 成本到顶 → 软着陆一次收尾机会后停止（B6：不再硬砍正文）', () async {
      final gateway = _ScriptedGateway([
        _call('echo', {'text': '1'}, id: 'c1'), // 110 tokens
        _call('echo', {'text': '2'}, id: 'c2'), // 累计 220 ≥ 200 → 触发
        _text('预算到顶的收尾。'), // 通牒后的纯文本收尾请求（工具已停用）
      ]);
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('x')],
          budget: const AgentBudget(maxTotalTokens: 200, maxDuration: null),
        ),
      );

      // 模型配合收尾 → 正常完成，正文不因预算耗尽蒸发
      expect(result.reason, AgentStopReason.completed);
      expect(result.steps, 3);
      expect(gateway.requests[2].tools, isEmpty);
    });

    test('B6：软着陆后仍不收尾 → budgetTokens 停轮（硬停语义守门）', () async {
      final gateway = _ScriptedGateway([
        _call('echo', {'text': '1'}, id: 'c1'),
        _call('echo', {'text': '2'}, id: 'c2'),
        _call('echo', {'text': '3'}, id: 'c3'), // 停工具后仍幻觉调用
      ]);
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('x')],
          budget: const AgentBudget(maxTotalTokens: 200, maxDuration: null),
        ),
      );

      expect(result.reason, AgentStopReason.budgetTokens);
      expect(result.errorMessage, contains('软着陆后仍未收尾'));
    });

    test('时间预算到顶 → 软着陆一次收尾后停止（B6：不再硬砍正文）', () async {
      final gateway = _ScriptedGateway([
        _call('echo', {'text': 'n0'}, id: 'call_0'), // 通牒后仍幻觉调工具
        _text('不应到达。'),
      ]);
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('x')],
          budget: const AgentBudget(maxDuration: Duration(milliseconds: -1)),
        ),
      );

      // 首个循环顶即触发 → 注入通牒并给出一次纯文本收尾机会（steps=1）；
      // 收尾后仍调工具 → 二次触发以 budgetDuration 停轮
      expect(result.reason, AgentStopReason.budgetDuration);
      expect(result.steps, 1);
      expect(result.errorMessage, contains('软着陆后仍未收尾'));
    });
  });

  group('尾部执笔重述（penReminder）', () {
    test('≥3 步未输出正文 → 注入一次文风铁律 reminder', () async {
      final gateway = _ScriptedGateway([
        _call('echo', {'text': '1'}, id: 'c1'),
        _call('echo', {'text': '2'}, id: 'c2'),
        _call('echo', {'text': '3'}, id: 'c3'),
        _text('正文……'),
      ]);
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('x')],
          penReminderText: '【执笔提醒】禁破折号',
        ),
      );

      expect(result.reason, AgentStopReason.completed);
      // 第 4 次请求（3 步工具后）的尾部应有 reminder（：user+标记）
      final messages = gateway.requests.last.messages;
      expect(
        messages.any(
          (m) =>
              m['role'] == 'user' &&
              (m['content'] as String).contains('执笔提醒') &&
              (m['content'] as String).startsWith(kWorkbenchReminderOpen),
        ),
        isTrue,
      );
    });

    test(
        '≥200 字文本但全程未出现 finish_round → 仍注入 reminder（契约 §7.3：执笔=发起 finish_round）',
        () async {
      final gateway = _ScriptedGateway([
        _textWithCall('风' * 250, 'echo', {'text': '1'}, id: 'c1'),
        _call('echo', {'text': '2'}, id: 'c2'),
        _call('echo', {'text': '3'}, id: 'c3'),
        _text('收尾'),
      ]);
      final runner = AgentRunner(gateway: gateway);

      await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('x')],
          penReminderText: '【执笔提醒】禁破折号',
        ),
      );

      // 第 4 次请求（≥3 步且未出现 finish_round）注入；修复前该判据是
      // "未出 ≥200 字文本"，正文以 content 形式流出后会漏锚
      final fourth = gateway.requests.last;
      expect(
        fourth.messages.any(
          (m) =>
              m['role'] == 'user' &&
              (m['content'] as String).contains('执笔提醒') &&
              (m['content'] as String).startsWith(kWorkbenchReminderOpen),
        ),
        isTrue,
      );
    });

    test('已出现 finish_round 调用 → 后续请求不再注入 reminder', () async {
      final gateway = _ScriptedGateway([
        _call('echo', {'text': '1'}, id: 'c1'),
        _call('echo', {'text': '2'}, id: 'c2'),
        _call('finish_round', {}, id: 'c3'),
        _text('收尾'),
      ]);
      final runner = AgentRunner(gateway: gateway);

      await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('x')],
          penReminderText: '【执笔提醒】禁破折号',
        ),
      );

      for (final request in gateway.requests) {
        expect(
          request.messages.any(
            (m) =>
                m['role'] == 'user' &&
                (m['content'] as String).contains('执笔提醒'),
          ),
          isFalse,
        );
      }
    });

    test('penReminderText=null → 禁用', () async {
      final gateway = _ScriptedGateway([
        _call('echo', {'text': '1'}, id: 'c1'),
        _call('echo', {'text': '2'}, id: 'c2'),
        _call('echo', {'text': '3'}, id: 'c3'),
        _text('正文'),
      ]);
      final runner = AgentRunner(gateway: gateway);

      await runner.runTurn(
        _spec(gateway, surface: [AgentMessage.user('x')]),
      );

      for (final request in gateway.requests) {
        expect(
          request.messages.any(
            (m) =>
                m['role'] == 'user' &&
                (m['content'] as String).contains('执笔提醒'),
          ),
          isFalse,
        );
      }
    });
  });

  group('doom-loop 保护', () {
    test('连续同参调用到阈值 → 拦截并补占位结果（B7-2 默认阈值 8）', () async {
      final gateway = _ScriptedGateway([
        for (var i = 0; i < 8; i++) _call('echo', {'text': 'same'}, id: 'c$i'),
      ]);
      final runner = AgentRunner(gateway: gateway);
      final sink = BufferingAgentEventSink();

      final result = await runner.runTurn(
        // maxSteps=0：隔离步数预算，聚焦 doom 触发（默认步数 8 会抢先软着陆）
        _spec(
          gateway,
          surface: [AgentMessage.user('x')],
          budget: const AgentBudget(maxSteps: 0, maxDuration: null),
          events: sink,
        ),
      );

      expect(result.reason, AgentStopReason.doomLoop);
      expect(result.steps, 8);
      // 第 8 次调用被拦截前补了占位 tool 结果（协议配对合法）
      final toolMessages =
          result.appendedMessages.where((m) => m.role == 'tool').toList();
      expect(toolMessages, hasLength(8));
      expect(toolMessages[7].content, contains('循环保护'));
      expect(sink.of<AgentDoomLoopDetected>(), hasLength(1));
      // 显式阈值仍可覆盖默认（沿用旧 3 次语义的调用方不受影响）；
      // 独立 gateway（上一轮已耗尽脚本）
      final strictGateway = _ScriptedGateway([
        for (var i = 0; i < 3; i++) _call('echo', {'text': 'same'}, id: 's$i'),
      ]);
      final strict = AgentRunner(gateway: strictGateway);
      final strictResult = await strict.runTurn(
        _spec(
          strictGateway,
          surface: [AgentMessage.user('x')],
          doomLoopDetector: DoomLoopDetector(threshold: 3),
        ),
      );
      expect(strictResult.reason, AgentStopReason.doomLoop);
    });

    test('不同参数调用重置连续计数', () async {
      final gateway = _ScriptedGateway([
        _call('echo', {'text': 'a'}, id: 'c1'),
        _call('echo', {'text': 'b'}, id: 'c2'),
        _call('echo', {'text': 'a'}, id: 'c3'),
        _text('done'),
      ]);
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(gateway, surface: [AgentMessage.user('x')]),
      );

      expect(result.reason, AgentStopReason.completed);
    });
  });

  group('finish_round 循环防线（契约 §7.2/§2.5）', () {
    AgentToolResult fail() => AgentToolResult.failure(
          title: '终审未过',
          output: '模拟闸门拒绝',
        );

    test('闸门连拒 + 同参重提 3 连击 → 不触发 doom（豁免），轮照常继续', () async {
      final gateway = _ScriptedGateway([
        _call('finish_round', {'prose': '同一份正文'}, id: 'c1'),
        _call('finish_round', {'prose': '同一份正文'}, id: 'c2'),
        _call('finish_round', {'prose': '同一份正文'}, id: 'c3'),
        _text('收尾'),
      ]);
      final runner = AgentRunner(gateway: gateway);
      final sink = BufferingAgentEventSink();

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('x')],
          tools: [
            _ScriptedFinishTool([fail(), fail(), fail()]),
          ],
          events: sink,
        ),
      );

      // 修复前：同参 3 连击在执行前被 doom 拦截整轮死亡（闸门纠错被误杀）
      expect(result.reason, AgentStopReason.completed);
      expect(sink.of<AgentDoomLoopDetected>(), isEmpty);
    });

    test('连续失败 5 次 → error 停轮（软上限）', () async {
      final gateway = _ScriptedGateway([
        for (var i = 0; i < 5; i++)
          _call('finish_round', {'prose': '修订版 $i'}, id: 'c$i'),
      ]);
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('x')],
          tools: [_ScriptedFinishTool(List.generate(5, (_) => fail()))],
        ),
      );

      expect(result.reason, AgentStopReason.error);
      expect(result.steps, 5);
      expect(result.errorMessage, contains('finish_round'));
    });

    test('计数语义为连续而非累计：成功清零后需重新攒满', () async {
      final gateway = _ScriptedGateway([
        _call('finish_round', {'prose': 'a'}, id: 'c1'),
        _call('finish_round', {'prose': 'b'}, id: 'c2'),
        _call('finish_round', {'prose': 'c'}, id: 'c3'),
        _call('finish_round', {'prose': 'd'}, id: 'c4'),
        _call('finish_round', {'prose': 'e'}, id: 'c5'),
        _call('finish_round', {'prose': 'f'}, id: 'c6'),
        _call('finish_round', {'prose': 'g'}, id: 'c7'),
        _call('finish_round', {'prose': 'h'}, id: 'c8'),
        _text('收尾'),
      ]);
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('x')],
          tools: [
            _ScriptedFinishTool([
              fail(),
              fail(),
              fail(),
              fail(),
              // 一次非 error 结果（如豁免放行的进度型信封）清零计数
              AgentToolResult.success(title: '豁免放行', output: 'ok'),
              fail(),
              fail(),
              fail(),
              fail(),
            ]),
          ],
        ),
      );

      // 4 失败 + 成功清零 + 4 失败 = 任何时刻都未达 5 连击 → 轮照常收尾
      expect(result.reason, AgentStopReason.completed);
    });

    test('未注册的 finish_round（被 deny）照旧进 doom 登记', () async {
      final gateway = _ScriptedGateway([
        _call('finish_round', {}, id: 'c1'),
        _call('finish_round', {}, id: 'c2'),
        _call('finish_round', {}, id: 'c3'),
      ]);
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('x')],
          // 显式阈值 3（默认改 8，此处聚焦登记语义本身）
          doomLoopDetector: DoomLoopDetector(threshold: 3),
        ),
      );

      expect(result.reason, AgentStopReason.doomLoop);
    });
  });

  group('取消语义', () {
    test('运行前取消 → cancelled，0 步', () async {
      final gateway = _ScriptedGateway([_text()]);
      final runner = AgentRunner(gateway: gateway);
      final token = AgentCancellationToken()..cancel('用户取消');

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('hi')],
          cancellation: token,
        ),
      );

      expect(result.reason, AgentStopReason.cancelled);
      expect(result.steps, 0);
      expect(gateway.requests, isEmpty);
    });

    test('工具执行中取消 → 未配对调用补占位结果', () async {
      final gateway = _ScriptedGateway([
        _call('echo', {'text': 'x'}),
      ]);
      final runner = AgentRunner(gateway: gateway);
      final token = AgentCancellationToken();

      // echo 完成后、下一个 step 边界取消
      final result = await runner.runTurn(
        AgentTurnSpec(
          sessionId: 'test',
          surface: [AgentMessage.user('hi')],
          tools: [_CancelAfterFirstToolTool(token: token)],
          endpoint: const AgentModelEndpoint(
            baseUrl: 'https://api.test.com',
            modelId: 'm',
            protocol: 'openaiCompatible',
          ),
          budget: const AgentBudget(maxDuration: null),
          events: BufferingAgentEventSink(),
          cancellation: token,
        ),
      );

      expect(result.reason, AgentStopReason.cancelled);
    });
  });

  group('request-error 瀑布', () {
    test('重试复用 stepIndex 并递增 attempt（契约 §7.1：StepStarted 带 attempt）', () async {
      final gateway = _FlakyGateway(
        failures: 1,
        thenResponse: _text('恢复后的回复。'),
      );
      final runner = AgentRunner(gateway: gateway);
      final sink = BufferingAgentEventSink();

      await runner.runTurn(
        _spec(gateway, surface: [AgentMessage.user('hi')], events: sink),
      );

      final starts = sink.of<AgentStepStarted>().toList();
      expect(starts, hasLength(2));
      expect(starts[0].stepIndex, 0);
      expect(starts[0].attempt, 0);
      expect(starts[1].stepIndex, 0, reason: '重试是同一步的再次尝试');
      expect(starts[1].attempt, 1);
    });

    // 重试等待可视化——429+Retry-After
    // 场景在等待开始前上抛 AgentRetryScheduled（waitMs=服务端指示，
    // 无 jitter），事件先于重试的 StepStarted（倒计时锚点）。
    test('G-02：429+Retry-After → AgentRetryScheduled 先于重试 StepStarted',
        () async {
      final gateway = _RateLimitedGateway(thenResponse: _text('恢复后的回复。'));
      final runner = AgentRunner(gateway: gateway);
      final sink = BufferingAgentEventSink();

      await runner.runTurn(
        _spec(gateway, surface: [AgentMessage.user('hi')], events: sink),
      );

      final scheduled = sink.of<AgentRetryScheduled>().toList();
      expect(scheduled, hasLength(1));
      // Retry-After 优先且无 jitter：waitMs 与服务端指示一致
      expect(scheduled[0].waitMs, 800);
      expect(scheduled[0].attempt, 1);
      // 事件位于重试的 StepStarted 之前（等待开始前发出）
      final starts = sink.of<AgentStepStarted>().toList();
      expect(starts, hasLength(2));
      expect(
        sink.events.indexOf(scheduled[0]) < sink.events.indexOf(starts[1]),
        isTrue,
      );
      // 重试成功收尾
      expect(gateway.attempts, 2);
    });

    test('失败后重试成功（默认 1 次重试）', () async {
      final gateway = _FlakyGateway(
        failures: 1,
        thenResponse: _text('恢复后的回复。'),
      );
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(gateway, surface: [AgentMessage.user('hi')]),
      );

      expect(result.reason, AgentStopReason.completed);
      expect(result.lastAssistantText, '恢复后的回复。');
      expect(gateway.attempts, 2);
    });

    test('重试耗尽 → error 停止', () async {
      final gateway = _FlakyGateway(
        failures: 10,
        thenResponse: _text(),
      );
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        // 显式钉 1 次重试
        _spec(
          gateway,
          surface: [AgentMessage.user('hi')],
          budget: const AgentBudget(
            maxDuration: null,
            maxRequestRetries: 1,
          ),
        ),
      );

      expect(result.reason, AgentStopReason.error);
      expect(result.errorMessage, contains('network down'));
      expect(gateway.attempts, 2); // 初次 + 1 次重试
    });

    test('不可重试错误直接停止', () async {
      final gateway = _ScriptedGateway([]);
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(gateway, surface: [AgentMessage.user('hi')]),
      );

      // script exhausted 是 retryable: false
      expect(result.reason, AgentStopReason.error);
      expect(gateway.requests, hasLength(1));
    });
  });

  group('pre-step / request 瀑布', () {
    test('pre-step 拒绝 → hookRejected', () async {
      final gateway = _ScriptedGateway([_text()]);
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('hi')],
          hooks: AgentRunnerHooks(
            preStep: [
              (current, next) async => const AgentPreStepReject('上下文超限，拒绝执行'),
            ],
          ),
        ),
      );

      expect(result.reason, AgentStopReason.hookRejected);
      expect(result.errorMessage, '上下文超限，拒绝执行');
      expect(gateway.requests, isEmpty);
    });

    test('request 钩子可改调用配置但不改消息', () async {
      final gateway = _ScriptedGateway([_text()]);
      final runner = AgentRunner(gateway: gateway);

      await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('hi')],
          hooks: AgentRunnerHooks(
            request: [
              (current, next) async => current.copyWith(temperature: 0.01),
            ],
          ),
        ),
      );

      expect(gateway.requests.single.config.temperature, 0.01);
    });
  });

  group('协议字段 wire 化', () {
    test('Anthropic 协议：thinkingBlocks + camelCase reasoning', () {
      final msg = AgentMessage.assistant(
        text: 'hi',
        reasoningContent: '思考过程',
      );
      final map = msg.toRequestMap(
        const AgentWireOptions(anthropicExtras: true),
      );
      expect(map['reasoningContent'], '思考过程');
      expect(map.containsKey('reasoning_content'), isFalse);
    });

    test('OpenAI 协议：snake_case reasoning_content', () {
      final msg = AgentMessage.assistant(text: 'hi', reasoningContent: '思考');
      final map = msg.toRequestMap(
        const AgentWireOptions(openaiReasoningContent: true),
      );
      expect(map['reasoning_content'], '思考');
    });

    test('Gemini 协议：tool_calls 携带 thought_signature', () {
      final msg = AgentMessage.assistant(
        toolCalls: [
          const AgentToolCall(
            id: 'gemini_search__1',
            name: 'search',
            arguments: {'q': 1},
            thoughtSignature: 'sig-xyz',
          ),
        ],
      );
      final map = msg.toRequestMap(
        const AgentWireOptions(geminiThoughtSignatures: true),
      );
      final tc = (map['tool_calls'] as List).first as Map<String, dynamic>;
      expect(tc['thought_signature'], 'sig-xyz');
    });
  });

  group('注入消息事件补账', () {
    test('maxSteps 通牒注入 → AgentInjectedMessageEvent(kind=max_steps_notice)',
        () async {
      final gateway = _ScriptedGateway([
        _call('echo', {'text': '1'}, id: 'c1'),
        _call('echo', {'text': '2'}, id: 'c2'),
        _call('echo', {'text': '3'}, id: 'c3'),
        _text('收尾正文。'),
      ]);
      final sink = BufferingAgentEventSink();
      final runner = AgentRunner(gateway: gateway);

      await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('loop')],
          budget: const AgentBudget(maxSteps: 3, maxDuration: null),
          events: sink,
        ),
      );

      final events = sink.of<AgentInjectedMessageEvent>();
      expect(events, hasLength(1));
      expect(events.single.kind, AgentInjectedMessageKinds.budgetFinalNotice);
      expect(events.single.message.role, 'user');
      expect(
        events.single.message.content,
        contains(kWorkbenchReminderOpen),
      );
    });

    // ====================  预算软着陆三态 ====================
    test('B6：token 成本到顶 → 软着陆注入通牒，纯文本收尾正常完成', () async {
      final gateway = _ScriptedGateway([
        _call('echo', {'text': '1'}, id: 'c1'), // 110 tokens
        _call('echo', {'text': '2'}, id: 'c2'), // 累计 220 ≥ 150 → 触发
        _text('预算到顶前的收尾正文。'), // 通牒后纯文本收尾（工具停用）
      ]);
      final sink = BufferingAgentEventSink();
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('开始')],
          budget: const AgentBudget(
            maxTotalTokens: 150,
            maxDuration: null,
          ),
          events: sink,
        ),
      );

      expect(result.reason, AgentStopReason.completed);
      expect(result.lastAssistantText, '预算到顶前的收尾正文。');
      // 第三个请求已停工具（纯文本收尾通道）
      expect(gateway.requests[2].tools, isEmpty);
      expect(
        sink.of<AgentInjectedMessageEvent>().single.kind,
        AgentInjectedMessageKinds.budgetFinalNotice,
      );
    });

    test('B6：软着陆后仍调工具 → 以 budgetTokens 停轮（不再无限让步）', () async {
      final gateway = _ScriptedGateway([
        _call('echo', {'text': '1'}, id: 'c1'),
        _call('echo', {'text': '2'}, id: 'c2'),
        _call('echo', {'text': '3'}, id: 'c3'), // 停工具后仍幻觉调用
      ]);
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('开始')],
          budget: const AgentBudget(maxTotalTokens: 150, maxDuration: null),
        ),
      );

      expect(result.reason, AgentStopReason.budgetTokens);
      expect(result.errorMessage, contains('软着陆后仍未收尾'));
    });

    test('B6：上下文余量越限 → 软着陆收尾（contextHeadroom 触发）', () async {
      final gateway = _ScriptedGateway([
        // 首步 promptTokens=900：窗口 1000 → 触发线 850 被越
        const AgentStepResponse(
          text: '',
          toolCalls: [
            AgentToolCall(id: 'c1', name: 'echo', arguments: {'text': '1'}),
          ],
          usage: LlmUsage(promptTokens: 900, completionTokens: 10),
        ),
        _text('余量触发的收尾正文。'),
      ]);
      final runner = AgentRunner(gateway: gateway);

      // 窗口 1000 → 触发线 850；首步 promptTokens=900 越线
      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('开始')],
          budget: const AgentBudget(
            contextWindowTokens: 1000,
            maxDuration: null,
          ),
        ),
      );

      expect(result.reason, AgentStopReason.completed);
      expect(result.lastAssistantText, '余量触发的收尾正文。');
      // 触发线由窗口推得（900 ≥ 850），注入即发生：第二个请求停工具
      expect(gateway.requests, hasLength(2));
      expect(gateway.requests[1].tools, isEmpty);
    });

    test('审查收官 R1-P1-2：余量守卫含 cache 读（Anthropic 口径 prompt 不含 cache）', () async {
      final gateway = _ScriptedGateway([
        // Anthropic 形态：promptTokens=300 不含 cache_read=700，合计 1000
        // 越过窗口 1000 的触发线 850——修复前只看 300 永不触发
        const AgentStepResponse(
          text: '',
          toolCalls: [
            AgentToolCall(id: 'c1', name: 'echo', arguments: {'text': '1'}),
          ],
          usage: LlmUsage(
            promptTokens: 300,
            completionTokens: 10,
            cacheReadTokens: 700,
          ),
        ),
        _text('缓存重会话的收尾正文。'),
      ]);
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('开始')],
          budget: const AgentBudget(
            contextWindowTokens: 1000,
            maxDuration: null,
          ),
        ),
      );

      expect(result.reason, AgentStopReason.completed);
      expect(result.lastAssistantText, '缓存重会话的收尾正文。');
      expect(gateway.requests, hasLength(2), reason: '软着陆注入发生');
      expect(gateway.requests[1].tools, isEmpty);
    });

    test('B6：无 usage 数据（lastPromptTokens=0）不误触发余量守卫', () async {
      final gateway = _ScriptedGateway([
        // 无 usage 的工具调用步（端点不回 usage 的形态）
        const AgentStepResponse(
          text: '',
          toolCalls: [
            AgentToolCall(id: 'c1', name: 'echo', arguments: {'text': '1'}),
          ],
        ),
        _text('第二段收尾。'),
      ]);
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('开始')],
          budget: const AgentBudget(
            contextWindowTokens: 1000,
            maxDuration: null,
          ),
        ),
      );

      expect(result.reason, AgentStopReason.completed);
      expect(gateway.requests, hasLength(2));
    });

    test('空响应 nudge 注入 → AgentInjectedMessageEvent(kind=empty_stop_nudge)',
        () async {
      final gateway = _ScriptedGateway([_emptyResp(), _text('正文来了。')]);
      final sink = BufferingAgentEventSink();
      final runner = AgentRunner(gateway: gateway);

      await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('开始')],
          events: sink,
        ),
      );

      final events = sink.of<AgentInjectedMessageEvent>();
      expect(events, hasLength(1));
      expect(events.single.kind, AgentInjectedMessageKinds.emptyStopNudge);
    });

    test('penReminder 注入 → AgentInjectedMessageEvent(kind=pen_reminder)',
        () async {
      final gateway = _ScriptedGateway([
        _call('echo', {'text': '1'}, id: 'c1'),
        _call('echo', {'text': '2'}, id: 'c2'),
        _call('echo', {'text': '3'}, id: 'c3'),
        _text('长' * 250),
      ]);
      final sink = BufferingAgentEventSink();
      final runner = AgentRunner(gateway: gateway);

      await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('开始')],
          events: sink,
          penReminderText: '【执笔提醒】…',
        ),
      );

      final events = sink.of<AgentInjectedMessageEvent>();
      expect(events, hasLength(1));
      expect(events.single.kind, AgentInjectedMessageKinds.penReminder);
    });
  });

  group('上下文超限自愈', () {
    test('overflow → 压缩 → 重建消息重试同一 step 一次 → 成功', () async {
      final gateway = _OverflowGateway(
        overflows: 1,
        thenResponse: _text('压缩后继续写。'),
      );
      final runner = AgentRunner(gateway: gateway);
      var compactCalls = 0;

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [
            AgentMessage.system('SYSTEM-FROZEN'),
            AgentMessage.user('第一轮'),
            AgentMessage.user('开始'),
          ],
          overflowCompactor: _FakeCompactor((working) async {
            compactCalls++;
            // 模拟压缩：保留 system + 摘要 + 末条用户消息
            return [
              working.first,
              AgentMessage.user('【前情压缩摘要】略'),
              working.last,
            ];
          }),
        ),
      );

      expect(result.reason, AgentStopReason.completed);
      expect(result.lastAssistantText, '压缩后继续写。');
      expect(compactCalls, 1);
      // 两次请求：第一次原样，第二次为压缩后的消息批
      expect(gateway.requests, hasLength(2));
      final retryMessages = gateway.requests[1].messages;
      expect(retryMessages, hasLength(3));
      expect(retryMessages[0]['role'], 'system');
      expect(
        retryMessages[1]['content'] as String,
        contains('【前情压缩摘要】'),
      );
    });

    test('溢出 replace 落日志为整面替换坐标（kAgentSurfaceReplaceToEnd）', () async {
      final gateway = _OverflowGateway(
        overflows: 1,
        thenResponse: _text('继续。'),
      );
      final sink = BufferingAgentEventSink();
      final runner = AgentRunner(gateway: gateway);

      await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('开始')],
          events: sink,
          overflowCompactor: _FakeCompactor(
            (working) async => [working.last],
          ),
        ),
      );

      // 投影坐标是全会话累积的，轮内 working.length 会错位——必须整面替换
      final replaced = sink.of<AgentSurfaceReplaced>().single;
      expect(replaced.replaceStart, 0);
      expect(replaced.replaceEnd, kAgentSurfaceReplaceToEnd);
    });

    test('DK6-4：自愈重试前回调 selfHealRetry 检查点（request 瀑布不随重跑）', () async {
      final gateway = _OverflowGateway(
        overflows: 1,
        thenResponse: _text('压缩后继续。'),
      );
      final runner = AgentRunner(gateway: gateway);
      final hookRequestCounts = <int>[];

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('开始')],
          overflowCompactor: _FakeCompactor((working) async => [working.last]),
          hooks: AgentRunnerHooks(
            selfHealRetry: [
              () async => hookRequestCounts.add(gateway.requests.length),
            ],
          ),
        ),
      );

      expect(result.reason, AgentStopReason.completed);
      // 检查点恰在首次请求之后、重试请求之前触发一次
      expect(hookRequestCounts, [1]);
      expect(gateway.requests, hasLength(2));
    });

    test('overflow → 压缩重试后仍超限 → 报错停轮（不无限循环）', () async {
      final gateway = _OverflowGateway(
        overflows: 2,
        thenResponse: _text('不会到达'),
      );
      final runner = AgentRunner(gateway: gateway);
      var compactCalls = 0;

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('开始')],
          overflowCompactor: _FakeCompactor((working) async {
            compactCalls++;
            return [working.last];
          }),
        ),
      );

      expect(result.reason, AgentStopReason.error);
      expect(result.errorMessage, contains('上下文超限'));
      // 压缩只做一次；第二次 overflow 直接停轮，不再压缩不再重发
      expect(compactCalls, 1);
      expect(gateway.requests, hasLength(2));
    });

    test('无压缩器：overflow 直接停轮（维持原错误路径，不空转重发）', () async {
      final gateway = _OverflowGateway(overflows: 1, thenResponse: _text());
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(gateway, surface: [AgentMessage.user('开始')]),
      );

      expect(result.reason, AgentStopReason.error);
      expect(result.errorMessage, contains('上下文超限'));
      expect(gateway.requests, hasLength(1));
    });

    test('压缩器抛异常/返回 null → 维持原错误路径', () async {
      final gateway = _OverflowGateway(overflows: 1, thenResponse: _text());
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('开始')],
          overflowCompactor: _FakeCompactor((working) async => null),
        ),
      );

      expect(result.reason, AgentStopReason.error);
      expect(gateway.requests, hasLength(1));
    });
  });

  group('续跑种子（resumeSeed）', () {
    test('步号从种子续起，result.steps 含前序尝试步数，turn 标记 resumed', () async {
      final gateway = _ScriptedGateway([_text('续写完成。')]);
      final runner = AgentRunner(gateway: gateway);
      final sink = BufferingAgentEventSink();

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('hi')],
          events: sink,
          resumeSeed: const AgentResumeSeed(initialSteps: 2),
        ),
      );

      expect(result.reason, AgentStopReason.completed);
      expect(result.steps, 3, reason: '种子 2 + 本次 1 步');
      final starts = sink.of<AgentStepStarted>().toList();
      expect(starts, hasLength(1));
      expect(starts.first.stepIndex, 2, reason: '新步从上次尝试的下一序号起');
      expect(sink.of<AgentTurnStarted>().single.resumed, isTrue);
    });

    test('无种子 → turn 不标记 resumed（既有行为零变化）', () async {
      final gateway = _ScriptedGateway([_text()]);
      final runner = AgentRunner(gateway: gateway);
      final sink = BufferingAgentEventSink();

      await runner.runTurn(
        _spec(gateway, surface: [AgentMessage.user('hi')], events: sink),
      );

      expect(sink.of<AgentTurnStarted>().single.resumed, isFalse);
      expect(sink.of<AgentStepStarted>().single.stepIndex, 0);
    });

    test('maxSteps 余量执法：种子已耗满 → 立即软着陆给一次纯文本收尾', () async {
      final gateway = _ScriptedGateway([_text('用现有材料收尾的正文。')]);
      final runner = AgentRunner(gateway: gateway);
      final sink = BufferingAgentEventSink();

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('hi')],
          events: sink,
          budget: const AgentBudget(maxSteps: 2, maxDuration: null),
          resumeSeed: const AgentResumeSeed(initialSteps: 2),
        ),
      );

      expect(result.reason, AgentStopReason.completed);
      expect(gateway.requests, hasLength(1), reason: '只剩软着陆的收尾请求');
      // 软着陆通牒注入且工具停用（纯文本请求不带工具定义）
      expect(gateway.requests.single.tools, isEmpty);
      expect(
        sink
            .of<AgentInjectedMessageEvent>()
            .any((e) => e.kind == AgentInjectedMessageKinds.budgetFinalNotice),
        isTrue,
      );
    });

    test('priorTotalTokens 余量执法：上次消耗计入 token 预算', () async {
      final gateway = _ScriptedGateway([
        _call('echo', {'text': 'x'}, id: 'c1'),
        _call('echo', {'text': 'y'}, id: 'c2'),
      ]);
      final runner = AgentRunner(gateway: gateway);

      final result = await runner.runTurn(
        _spec(
          gateway,
          surface: [AgentMessage.user('hi')],
          budget: const AgentBudget(maxTotalTokens: 240, maxDuration: null),
          resumeSeed: const AgentResumeSeed(priorTotalTokens: 130),
        ),
      );

      // 首步 110 + 种子 130 = 240 达线 → 软着陆；通牒后仍调工具 → 二次触发停轮
      expect(result.reason, AgentStopReason.budgetTokens);
      expect(result.errorMessage, contains('上次尝试 130'));
      expect(gateway.requests, hasLength(2));
    });
  });
}

/// 可编程溢出压缩器 fake
class _FakeCompactor implements AgentOverflowCompactor {
  _FakeCompactor(this.behavior);

  final Future<List<AgentMessage>?> Function(List<AgentMessage> working)
      behavior;

  @override
  Future<List<AgentMessage>?> compact(List<AgentMessage> working) =>
      behavior(working);
}

/// 第一个工具执行后触发取消的测试工具
class _CancelAfterFirstToolTool implements AgentTool {
  const _CancelAfterFirstToolTool({required this.token});

  final AgentCancellationToken token;

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
    token.cancel('工具执行中取消');
    return AgentToolResult.success(title: 'echo', output: 'ok');
  }
}
