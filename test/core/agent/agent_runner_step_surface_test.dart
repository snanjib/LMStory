import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_budget.dart';
import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_events.dart';
import 'package:lmstory/core/agent/agent_llm_gateway.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/agent/agent_runner.dart';
import 'package:lmstory/core/agent/agent_step_surface_source.dart';
import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/features/advanced/data/agent_durable_event_sink.dart';
import 'package:lmstory/features/advanced/data/director_step_surface_source.dart';
import 'package:lmstory/features/advanced/data/repositories/agent_event_log_repository.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_event_source.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';

/// stepSurfaceSource 接线：每步出站=账本投影（等值守卫通过）+ 相邻请求
/// 内容前缀延长 + 漂移 fail-closed 停轮。
///
/// 对齐 dsh request-reconstruction.spec（append-extends 不变量）与
/// pi prepareRequest 覆写式「出站=投影」的 LMStory 落地验证。
void main() {
  late AppDatabase db;
  late AgentEventLogRepository repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = AgentEventLogRepository(database: db);
  });

  tearDown(() async => db.close());

  AgentDurableEvent ev(
    String type, {
    Map<String, dynamic> data = const {},
    AgentSurfaceOpKind? op,
  }) =>
      AgentDurableEvent(type: type, data: data, surfaceOp: op);

  /// 预置账本：frozen + 完整纪元（捕获 u1/p1）+ 本轮 u2 + 尾部指令
  Future<void> seedOpenEpochLedger() async {
    await repo.appendAll('s1', [
      ev(
        AgentEventTypes.systemFrozen,
        op: AgentSurfaceOpKind.append,
        data: {'content': 'FROZEN-PREFIX', 'turn': 1},
      ),
      ev(
        AgentEventTypes.modeEpoch,
        data: {
          'phase': 'enter',
          'epochId': 'e1',
          'status': 'pending',
          'fromTurn': 2,
        },
      ),
      ev(
        AgentEventTypes.modeCapture,
        op: AgentSurfaceOpKind.append,
        data: {
          'as': 'user',
          'content': '第一轮输入',
          'epochId': 'e1',
        },
      ),
      ev(
        AgentEventTypes.modeCapture,
        op: AgentSurfaceOpKind.append,
        data: {
          'as': 'assistant',
          'content': '第一轮正文',
          'epochId': 'e1',
        },
      ),
      ev(
        AgentEventTypes.modeEpoch,
        data: {
          'phase': 'enter',
          'epochId': 'e1',
          'status': 'complete',
          'captureCount': 2,
        },
      ),
      // 本轮 bootstrap（轮首已落账）
      ev(
        AgentEventTypes.userMessage,
        op: AgentSurfaceOpKind.append,
        data: {'content': '第二轮输入', 'turn': 2},
      ),
      ev(
        AgentEventTypes.userMessage,
        op: AgentSurfaceOpKind.append,
        data: {'content': '【工作契约】', 'source': 'tail_contract', 'turn': 2},
      ),
    ]);
  }

  test('两步工具轮：每步出站=账本投影，相邻请求内容前缀延长', () async {
    await seedOpenEpochLedger();
    final gateway = _ScriptedGateway([
      const AgentStepResponse(
        text: '先查一下。',
        toolCalls: [
          AgentToolCall(id: 'c1', name: 'echo', arguments: {'x': 1}),
        ],
      ),
      const AgentStepResponse(text: '正文完成。', toolCalls: []),
    ]);
    final durableSink = DurableAgentEventSink(
      repository: repo,
      sessionId: 's1',
      turnNumber: 2,
    );
    final source = DirectorStepSurfaceSource(
      durableSink: durableSink,
      repository: repo,
      sessionId: 's1',
    );
    // 轮入口 surface = 首次投影（与 runner 侧装配同源）
    final initial = await source.project();

    final recorder = _RecordingSink();
    final runner = AgentRunner(gateway: gateway);
    final result = await runner.runTurn(
      AgentTurnSpec(
        sessionId: 's1',
        surface: initial.messages,
        tools: const [_EchoTool()],
        endpoint: _endpoint,
        budget: const AgentBudget(
          maxSteps: 0,
          contextWindowTokens: 32000,
        ),
        // 生产接线同构：live 多播 + durable 落库（守卫投影读的就是它）
        events: _MultiSink([recorder, durableSink]),
        cancellation: AgentCancellationToken(),
        stepSurfaceSource: source,
      ),
    );
    // ignore: avoid_print
    expect(result.reason, AgentStopReason.completed);
    expect(gateway.requests, hasLength(2));

    // 步 1 出站 = [frozen, 捕获×2, u2, 契约]（账本投影原样）
    final r1 = gateway.requests[0].messages;
    expect(r1.map((m) => m['content']).toList(), [
      'FROZEN-PREFIX',
      '第一轮输入',
      '第一轮正文',
      '第二轮输入',
      '【工作契约】',
    ]);

    // 步 2 出站 = 步 1 前缀 + assistant(播报+tool_call) + tool 结果
    final r2 = gateway.requests[1].messages;
    expect(r2.length, r1.length + 2);
    for (var i = 0; i < r1.length; i++) {
      expect(r2[i], r1[i]); // 逐条 map 相等（内容前缀延长）
    }
    expect(r2[r1.length]['role'], 'assistant');
    expect(r2[r1.length]['content'], '先查一下。');
    expect(r2[r1.length + 1]['role'], 'tool');

    // 守卫未触发（无 surface/guard 事件）
    expect(recorder.guardEvents, isEmpty);
  });

  test('逐请求分叉度量：每步落 request/metric（前缀分叉位置+断点策略摘要）', () async {
    await seedOpenEpochLedger();
    final gateway = _ScriptedGateway([
      const AgentStepResponse(
        text: '先查一下。',
        toolCalls: [
          AgentToolCall(id: 'c1', name: 'echo', arguments: {'x': 1}),
        ],
      ),
      const AgentStepResponse(text: '正文完成。', toolCalls: []),
    ]);
    final durableSink = DurableAgentEventSink(
      repository: repo,
      sessionId: 's1',
      turnNumber: 2,
    );
    final source = DirectorStepSurfaceSource(
      durableSink: durableSink,
      repository: repo,
      sessionId: 's1',
    );
    final initial = await source.project();
    final recorder = _RecordingSink();
    final runner = AgentRunner(gateway: gateway);
    await runner.runTurn(
      AgentTurnSpec(
        sessionId: 's1',
        surface: initial.messages,
        tools: const [_EchoTool()],
        endpoint: _endpoint,
        budget: const AgentBudget(
          maxSteps: 0,
          contextWindowTokens: 32000,
        ),
        events: _MultiSink([recorder, durableSink]),
        cancellation: AgentCancellationToken(),
        stepSurfaceSource: source,
      ),
    );

    final metrics = (await repo.readEvents('s1'))
        .where((e) => e.type == AgentEventTypes.requestMetric)
        .toList();
    expect(metrics, hasLength(3), reason: '轮入口投影+两步=3 次出站度量');
    // 首次出站：全新面（无前缀可比）
    expect(metrics[0].data['stepIndex'], 0);
    expect(metrics[0].data['divergedAtIndex'], isNull);
    expect(metrics[0].data['frozenPrefixChars'], 'FROZEN-PREFIX'.length);
    // 步 1：与轮入口投影同面（无新事件）→ 无分叉（-1 且等长）
    expect(metrics[1].data['stepIndex'], 1);
    expect(metrics[1].data['divergedAtIndex'], -1);
    // 步 2：前缀延长——分叉位置=上一面末尾（新 assistant/tool 消息追加处）
    expect(metrics[2].data['stepIndex'], 2);
    final diverged = metrics[2].data['divergedAtIndex'] as int;
    final prevCount = metrics[2].data['prevMessageCount'] as int;
    expect(diverged, prevCount, reason: '纯追加型分叉=上一面末尾下标');
    expect(metrics[2].data['prefixChars'], greaterThan(0));
    expect(metrics[2].data['digest'], isNotNull);
  });

  test('漂移守卫：投影与内存工作面失配 → fail-closed 停轮并留痕', () async {
    await seedOpenEpochLedger();
    final gateway = _ScriptedGateway([
      const AgentStepResponse(text: 'x', toolCalls: []),
    ]);
    final durableSink = DurableAgentEventSink(
      repository: repo,
      sessionId: 's1',
      turnNumber: 2,
    );
    final source = DirectorStepSurfaceSource(
      durableSink: durableSink,
      repository: repo,
      sessionId: 's1',
    );
    final initial = await source.project();
    // 篡改源：投影返回缺尾消息的表面（模拟事件漏账/坐标损坏）
    final drifting = _DriftingSource(initial.messages);

    final recorder = _RecordingSink();
    final runner = AgentRunner(gateway: gateway);
    final result = await runner.runTurn(
      AgentTurnSpec(
        sessionId: 's1',
        surface: initial.messages,
        tools: const [],
        endpoint: _endpoint,
        budget: const AgentBudget(
          maxSteps: 0,
          contextWindowTokens: 32000,
        ),
        events: _MultiSink([recorder, durableSink]),
        cancellation: AgentCancellationToken(),
        stepSurfaceSource: drifting,
      ),
    );

    expect(result.reason, AgentStopReason.error);
    expect(result.errorMessage, contains('projection'));
    // 留痕事件已发射（surface/guard，kind=projection-drift）
    expect(recorder.guardEvents, hasLength(1));
    expect(recorder.guardEvents.single.kind, 'projection-drift');
    // 请求未发出（守卫在序列化之前拦截）
    expect(gateway.requests, isEmpty);
  });

  test('续跑形账本（含前序尝试事件）：每步出站=投影，续跑首请求含前序轨迹', () async {
    await seedOpenEpochLedger();
    // 前序尝试已在账：assistant 播报+工具调用+结果（失败残留，真续跑
    // 不重放不重写——resume 分支构造同源投影源，首步出站必须含它们）
    await repo.appendAll('s1', [
      ev(
        AgentEventTypes.assistantMessage,
        op: AgentSurfaceOpKind.append,
        data: {
          'text': '先查一下。',
          'toolCalls': [
            {
              'id': 'c1',
              'name': 'echo',
              'args': {'x': 1},
            },
          ],
          'turn': 2,
          'attemptId': 'att-old',
        },
      ),
      ev(
        AgentEventTypes.toolResult,
        op: AgentSurfaceOpKind.append,
        data: {
          'callId': 'c1',
          'output': '回声',
          'turn': 2,
          'attemptId': 'att-old',
        },
      ),
    ]);
    final gateway = _ScriptedGateway([
      const AgentStepResponse(text: '续跑正文完成。', toolCalls: []),
    ]);
    final durableSink = DurableAgentEventSink(
      repository: repo,
      sessionId: 's1',
      turnNumber: 2,
    );
    // resume 分支同构：全新 source 对象（flush→投影→守卫），无轮首补账
    final source = DirectorStepSurfaceSource(
      durableSink: durableSink,
      repository: repo,
      sessionId: 's1',
    );
    final recorder = _RecordingSink();
    final runner = AgentRunner(gateway: gateway);
    final result = await runner.runTurn(
      AgentTurnSpec(
        sessionId: 's1',
        // resume.surface = 续跑时点投影（含前序尝试事件）
        surface: (await DirectorStepSurfaceSource(
          durableSink: DurableAgentEventSink(
            repository: repo,
            sessionId: 's1',
            turnNumber: 2,
          ),
          repository: repo,
          sessionId: 's1',
        ).project())
            .messages,
        tools: const [],
        endpoint: _endpoint,
        budget: const AgentBudget(maxSteps: 0, contextWindowTokens: 32000),
        events: _MultiSink([recorder, durableSink]),
        cancellation: AgentCancellationToken(),
        stepSurfaceSource: source,
      ),
    );
    expect(result.reason, AgentStopReason.completed);
    final r1 = gateway.requests.single.messages;
    expect(r1.map((m) => m['content']).toList(), [
      'FROZEN-PREFIX',
      '第一轮输入',
      '第一轮正文',
      '第二轮输入',
      '【工作契约】',
      '先查一下。',
      '回声',
    ]);
    // 守卫未触发（投影与内存工作面一致）
    expect(recorder.guardEvents, isEmpty);
  });

  test('续跑跨端点/思考禁用：投影清不可回传表示（续跑同口径）', () async {
    await seedOpenEpochLedger();
    final oldSource = AgentEventSourceMeta(
      protocol: 'openaiCompatible',
      modelId: 'm',
      endpointFingerprint: AgentEventSourceMeta.fingerprintEndpoint(
        'https://old.example/v1',
      ),
    );
    // 真实续跑形态：resumeRepairEvents 先为未配对调用补占位结果
    //（两模式共用修复步），再以同源投影源出站。
    await repo.appendAll('s1', [
      ev(
        AgentEventTypes.assistantMessage,
        op: AgentSurfaceOpKind.append,
        data: {
          'text': '带思考的播报。',
          'reasoningContent': '内部推理链',
          'thinkingBlocks': [
            {'thinking': '内部推理链', 'signature': 'sig1'},
          ],
          'toolCalls': [
            {
              'id': 'c9',
              'name': 'echo',
              'args': {'x': 1},
              'thoughtSignature': 'ts1',
            },
          ],
          'turn': 2,
          'attemptId': 'att-old',
          'source': oldSource.toJson(),
        },
      ),
      ev(
        AgentEventTypes.toolResult,
        op: AgentSurfaceOpKind.append,
        data: {'callId': 'c9', 'output': '占位（中断）', 'turn': 2},
      ),
    ]);
    final gateway = _ScriptedGateway([
      const AgentStepResponse(text: '续跑完成。', toolCalls: []),
    ]);
    final durableSink = DurableAgentEventSink(
      repository: repo,
      sessionId: 's1',
      turnNumber: 2,
    );
    // 续跑切换当前来源/端点 + 本轮思考禁用：投影清思考/签名表示
    final source = DirectorStepSurfaceSource(
      durableSink: durableSink,
      repository: repo,
      sessionId: 's1',
      currentSource: AgentEventSourceMeta(
        protocol: 'openaiCompatible',
        modelId: 'm2',
        endpointFingerprint: AgentEventSourceMeta.fingerprintEndpoint(
          'https://new.example/v1',
        ),
      ),
      thinkingReplayAllowed: false,
    );
    final initial = await source.project();
    final runner = AgentRunner(gateway: gateway);
    final result = await runner.runTurn(
      AgentTurnSpec(
        sessionId: 's1',
        surface: initial.messages,
        tools: const [],
        endpoint: _endpoint,
        budget: const AgentBudget(maxSteps: 0, contextWindowTokens: 32000),
        events: _MultiSink([_RecordingSink(), durableSink]),
        cancellation: AgentCancellationToken(),
        stepSurfaceSource: source,
      ),
    );
    expect(result.reason, AgentStopReason.completed);
    final body = gateway.requests.single;
    final contents = body.messages.map((m) => m['content']).join('\n');
    expect(contents.contains('内部推理链'), isFalse, reason: '跨端点思考链不得回传');
    expect(contents.contains('sig1'), isFalse);
    expect(contents.contains('ts1'), isFalse, reason: '跨端点签名不得回传');
    expect(contents, contains('带思考的播报。'));
  });

  test('关闭态（无 stepSurfaceSource）：outgoing 仍来自内存工作面', () async {
    await seedOpenEpochLedger();
    final gateway = _ScriptedGateway([
      const AgentStepResponse(text: '直答。', toolCalls: []),
    ]);
    final runner = AgentRunner(gateway: gateway);
    final result = await runner.runTurn(
      AgentTurnSpec(
        sessionId: 's1',
        surface: [
          AgentMessage.system('SYS'),
          AgentMessage.user('问'),
        ],
        tools: const [],
        endpoint: _endpoint,
        budget: const AgentBudget(
          maxSteps: 0,
          contextWindowTokens: 32000,
        ),
        events: _RecordingSink(),
        cancellation: AgentCancellationToken(),
      ),
    );
    expect(result.reason, AgentStopReason.completed);
    expect(
      gateway.requests.single.messages.map((m) => m['content']).toList(),
      ['SYS', '问'],
    );
  });

  group('toolResult isError 投影保真与等值守卫', () {
    for (final protocol in ['openaiCompatible', 'anthropic', 'geminiNative']) {
      test('失败工具在 $protocol 协议下经账本投影后通过等值守卫且保留错误态', () async {
        await seedOpenEpochLedger();
        final gateway = _ScriptedGateway([
          const AgentStepResponse(
            text: '',
            toolCalls: [
              AgentToolCall(id: 'c_err', name: 'fail_write', arguments: {}),
            ],
          ),
          const AgentStepResponse(text: '收到错误并结束。', toolCalls: []),
        ]);
        final durableSink = DurableAgentEventSink(
          repository: repo,
          sessionId: 's1',
          turnNumber: 2,
        );
        final source = DirectorStepSurfaceSource(
          durableSink: durableSink,
          repository: repo,
          sessionId: 's1',
        );
        final initial = await source.project();
        final recorder = _RecordingSink();
        final runner = AgentRunner(gateway: gateway);

        final result = await runner.runTurn(
          AgentTurnSpec(
            sessionId: 's1',
            surface: initial.messages,
            tools: const [_FailingWriteTool()],
            endpoint: AgentModelEndpoint(
              baseUrl: 'https://api.onward/v1',
              apiKey: 'k',
              modelId: 'm',
              protocol: protocol,
            ),
            budget: const AgentBudget(
              maxSteps: 0,
              contextWindowTokens: 32000,
            ),
            events: _MultiSink([recorder, durableSink]),
            cancellation: AgentCancellationToken(),
            stepSurfaceSource: source,
          ),
        );

        expect(result.reason, AgentStopReason.completed);
        expect(recorder.guardEvents, isEmpty);
        final toolMsg = gateway.requests[1].messages.last;
        expect(toolMsg['role'], 'tool');
        if (protocol == 'openaiCompatible') {
          expect(toolMsg['content'], startsWith('[TOOL_ERROR] '));
          expect(toolMsg.containsKey('is_error'), isFalse);
        } else {
          expect(toolMsg['is_error'], isTrue);
        }
      });
    }

    test('agentMessageToSurfaceData 与 surfaceReplace 往返保留 isToolError', () {
      final errMsg = AgentMessage.toolResult(
        toolCallId: 'c1',
        content: '写入参数非法',
        isError: true,
      );
      final okMsg = AgentMessage.toolResult(
        toolCallId: 'c2',
        content: '写入成功',
      );
      final errData = agentMessageToSurfaceData(errMsg);
      final okData = agentMessageToSurfaceData(okMsg);
      expect(errData['isError'], isTrue);
      expect(okData.containsKey('isError'), isFalse);

      final projection = deriveAgentSurface([
        ev(
          AgentEventTypes.userMessage,
          op: AgentSurfaceOpKind.append,
          data: {'content': '占位'},
        ),
        AgentDurableEvent(
          type: AgentEventTypes.surfaceReplace,
          surfaceOp: AgentSurfaceOpKind.replace,
          replaceStart: 0,
          replaceEnd: 1,
          data: {
            'messages': [errData, okData],
          },
        ),
      ]);
      expect(projection.messages, hasLength(2));
      expect(projection.messages[0].isToolError, isTrue);
      expect(projection.messages[0].content, '写入参数非法');
      expect(projection.messages[1].isToolError, isFalse);
      expect(projection.messages[1].content, '写入成功');
    });
  });
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

class _MultiSink implements AgentEventSink {
  _MultiSink(this.sinks);

  final List<AgentEventSink> sinks;

  @override
  void emit(AgentRunEvent event) {
    for (final sink in sinks) {
      sink.emit(event);
    }
  }
}

class _RecordingSink implements AgentEventSink {
  final List<AgentSurfaceGuardTripped> guardEvents = [];

  @override
  void emit(AgentRunEvent event) {
    if (event is AgentSurfaceGuardTripped) guardEvents.add(event);
  }
}

/// 恒定返回缺尾表面的漂移源（守卫反例注入）
class _DriftingSource implements AgentStepSurfaceSource {
  _DriftingSource(List<AgentMessage> base)
      : _drifted = List<AgentMessage>.of(base)..removeLast();

  final List<AgentMessage> _drifted;

  @override
  Future<AgentStepSurface> project() async {
    return AgentStepSurface(
      messages: List.unmodifiable(_drifted),
      contentGeneration: 0,
      digest: 'drift',
    );
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

class _FailingWriteTool implements AgentTool {
  const _FailingWriteTool();

  @override
  String get name => 'fail_write';

  @override
  String get description => 'fail_write';

  @override
  AgentToolPermission get permission => AgentToolPermission.write;

  @override
  Map<String, dynamic> buildParametersSchema() => const {'type': 'object'};

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async {
    return AgentToolResult.failure(title: '参数缺失', output: '缺少 confidence');
  }
}
