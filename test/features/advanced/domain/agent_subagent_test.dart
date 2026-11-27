import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_budget.dart';
import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_events.dart';
import 'package:lmstory/core/agent/agent_llm_gateway.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/agent/agent_runner.dart' show AgentEventSink;
import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/features/advanced/data/agent_durable_event_sink.dart';
import 'package:lmstory/features/advanced/data/repositories/agent_event_log_repository.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_round_draft.dart';
import 'package:lmstory/features/advanced/domain/services/agent_event_bus.dart';
import 'package:lmstory/features/advanced/domain/services/agent_session_tools.dart'
    show AgentToolDeps;
import 'package:lmstory/features/advanced/domain/services/agent_story_reader.dart';
import 'package:lmstory/features/advanced/domain/services/agent_subagent.dart';
import 'package:lmstory/features/advanced/domain/services/calc_agent_tools.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';

/// 通用子代理测试（P3：SubagentRunner 档位 + SpawnTool 参数/信封）
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
      throw const AgentLlmException('exhausted', retryable: false);
    }
    return script[cursor++];
  }
}

class _StubTool implements AgentTool {
  _StubTool(this.name);

  @override
  final String name;

  @override
  String get description => name;

  @override
  AgentToolPermission get permission => AgentToolPermission.readOnly;

  @override
  Map<String, dynamic> buildParametersSchema() => const {'type': 'object'};

  @override
  Future<AgentToolResult> invoke(
    AgentToolInvocation invocation,
    Map<String, dynamic> arguments,
  ) async =>
      AgentToolResult.success(title: name, output: '$name 结果');
}

AgentToolInvocation spawnInvocation() => AgentToolInvocation(
      callId: 'c',
      toolName: 'spawn',
      stepIndex: 0,
      cancellation: AgentCancellationToken(),
    );

void main() {
  AgentModelEndpoint endpoint() => const AgentModelEndpoint(
        baseUrl: 'https://api.openai.com/v1',
        modelId: 'm',
        protocol: 'openaiCompatible',
      );

  List<AgentTool> researchTools() => [
        for (final name in SubagentRunner.toolsets['research']!)
          _StubTool(name),
      ];

  group('SubagentRunner', () {
    test('子代理继承请求时限并保留独立预算', () async {
      final gateway = _ScriptedGateway([
        const AgentStepResponse(text: 'done', toolCalls: []),
      ]);
      final subagent = SubagentRunner(
        gateway: gateway,
        endpoint: endpoint(),
        availableTools: researchTools(),
        callConfig: const AgentCallConfig(
          responseStartTimeout: Duration(minutes: 10),
          nonStreamingTimeout: Duration(minutes: 10),
          readTimeout: Duration(seconds: 45),
        ),
      );
      await subagent.run(
        brief: 'check',
        toolset: 'research',
        parentCancellation: AgentCancellationToken(),
      );
      expect(
        gateway.requests.single.config.responseStartTimeout,
        const Duration(minutes: 10),
      );
      expect(
        gateway.requests.single.config.nonStreamingTimeout,
        const Duration(minutes: 10),
      );
      expect(
        gateway.requests.single.config.readTimeout,
        const Duration(seconds: 45),
      );
    });

    test('B12 事件多播：外部出口收到全部事件（缓冲行为不变）', () async {
      final gateway = _ScriptedGateway([
        const AgentStepResponse(
          text: '【结论】子代理交付物。',
          toolCalls: [],
        ),
      ]);
      final external = BufferingAgentEventSink();
      final subagent = SubagentRunner(
        gateway: gateway,
        endpoint: endpoint(),
        availableTools: researchTools(),
        externalEventsResolver: (_) => external,
      );

      final result = await subagent.run(
        brief: '一次性任务书。',
        toolset: 'plain',
        parentCancellation: AgentCancellationToken(),
      );

      expect(result.reason, AgentStopReason.completed);
      // 外部出口可观测：turn/begin、step、assistant、turn/end 全事件流
      expect(
        external.events.any((e) => e is AgentTurnStarted),
        isTrue,
      );
      expect(
        external.events.any((e) => e is AgentTurnFinished),
        isTrue,
      );
      expect(
        external.events.whereType<AgentAssistantMessageEvent>(),
        isNotEmpty,
      );
    });

    test('research 档：白名单工具 + 边界壳与 brief 原文进 system', () async {
      final gateway = _ScriptedGateway([
        const AgentStepResponse(
          text: '',
          toolCalls: [
            AgentToolCall(id: 'c1', name: 'search_story', arguments: {}),
          ],
        ),
        const AgentStepResponse(
          text: '【结论】古碑在第 3 轮由苏明远发现，第 7 轮碑文被拓印。',
          toolCalls: [],
        ),
      ]);
      final subagent = SubagentRunner(
        gateway: gateway,
        endpoint: endpoint(),
        availableTools: researchTools(),
      );

      final result = await subagent.run(
        brief: '核对沈青梧从首次出场至今的状态变化，列出轮号出处。',
        toolset: 'research',
        parentCancellation: AgentCancellationToken(),
      );

      expect(result.reason, AgentStopReason.completed);
      expect(result.steps, 2);
      expect(result.lastAssistantText, contains('古碑'));
      // 独立上下文：system（边界壳+任务书）+ 一条 user 起跑消息
      final firstRequest = gateway.requests.first;
      expect(firstRequest.messages, hasLength(2));
      final system = firstRequest.messages.first['content'] as String;
      expect(system, contains('被主编辑派出的子代理'));
      expect(system, contains('【任务书】'));
      expect(system, contains('核对沈青梧'));
      // 工具档位：只暴露 research 白名单
      expect(
        firstRequest.tools.map((t) => t.name),
        containsAll(SubagentRunner.toolsets['research']!),
      );
    });

    test('plain 档：零工具（纯文本任务）', () async {
      final gateway = _ScriptedGateway([
        const AgentStepResponse(text: '【第二意见】这段节奏偏平。', toolCalls: []),
      ]);
      final subagent = SubagentRunner(
        gateway: gateway,
        endpoint: endpoint(),
        availableTools: researchTools(),
      );

      final result = await subagent.run(
        brief: '你是试笔员，写一段 100 字的雨夜开场。',
        toolset: 'plain',
        parentCancellation: AgentCancellationToken(),
      );

      expect(result.reason, AgentStopReason.completed);
      expect(gateway.requests.first.tools, isEmpty);
      expect(result.lastAssistantText, contains('第二意见'));
    });

    test('未知 toolset → ArgumentError（fail-loud）', () {
      final subagent = SubagentRunner(
        gateway: _ScriptedGateway(const []),
        endpoint: endpoint(),
        availableTools: researchTools(),
      );

      expect(
        () => subagent.run(
          brief: 'x',
          toolset: 'write',
          parentCancellation: AgentCancellationToken(),
        ),
        throwsArgumentError,
      );
    });

    test('能力位交集：白名单部分可用时按交集过滤运行', () async {
      final gateway = _ScriptedGateway([
        const AgentStepResponse(text: '【结论】已核对。', toolCalls: []),
      ]);
      final subagent = SubagentRunner(
        gateway: gateway,
        endpoint: endpoint(),
        availableTools: [_StubTool('search_story')], // 缺其余白名单工具
      );

      // 旧实现此处抛 StateError（deny 任一只读工具即 spawn 必败）；
      // 现按设计 §5.1「白名单与主代理 allow 集求交集」过滤后正常运行
      final result = await subagent.run(
        brief: 'x',
        toolset: 'research',
        parentCancellation: AgentCancellationToken(),
      );
      expect(result.errorMessage, isNull);
      expect(result.lastAssistantText, contains('已核对'));
    });

    test('未知档位仍 fail-loud（ArgumentError）', () {
      final subagent = SubagentRunner(
        gateway: _ScriptedGateway(const []),
        endpoint: endpoint(),
        availableTools: const [],
      );

      expect(
        () => subagent.run(
          brief: 'x',
          toolset: 'unknown',
          parentCancellation: AgentCancellationToken(),
        ),
        throwsArgumentError,
      );
    });

    // 以下三组锁定 research 档对幕后 calc 的真实路由与边界。
    const researchCandidates = [
      'search_story',
      'search_story_text',
      'read_story',
      'query_facts',
      'query_memory_changes',
      'read_compact_summary',
      'read_skill',
      'calc_eval',
      'calc_date',
    ];

    test('research 出站含候选集中的两项 calc（真实 run + 桩工具只证路由）', () async {
      final gateway = _ScriptedGateway([
        const AgentStepResponse(text: '【结论】已核对。', toolCalls: []),
      ]);
      final subagent = SubagentRunner(
        gateway: gateway,
        endpoint: endpoint(),
        // 候选集独立于白名单常量构造，防止白名单自我对照空转。
        availableTools: [
          for (final name in researchCandidates) _StubTool(name),
        ],
      );
      await subagent.run(
        brief: '核对数值与日期。',
        toolset: 'research',
        parentCancellation: AgentCancellationToken(),
      );
      final outbound = gateway.requests.single.tools.map((t) => t.name).toSet();
      expect(outbound, containsAll(researchCandidates));
      expect(outbound, isNot(contains('spawn')));
    });

    test('research 子代理真实执行 calc_eval 并把回执送回网关', () async {
      final draft = AgentRoundDraft(turnNumber: 1);
      final gateway = _ScriptedGateway([
        const AgentStepResponse(
          text: '',
          toolCalls: [
            AgentToolCall(
              id: 'cc1',
              name: 'calc_eval',
              arguments: {'expression': '0.1 + 0.2'},
            ),
          ],
        ),
        const AgentStepResponse(text: '【结论】精确值为 3/10。', toolCalls: []),
      ]);
      final subagent = SubagentRunner(
        gateway: gateway,
        endpoint: endpoint(),
        availableTools: [
          // 其余候选给桩，calc_eval 给真实工具（真实 CalcDateTool 同理可换入）。
          for (final name in researchCandidates.where((n) => n != 'calc_eval'))
            _StubTool(name),
          CalcEvalTool(_calcToolDeps(draft)),
        ],
      );

      final result = await subagent.run(
        brief: '用 calc 核对 0.1 + 0.2。',
        toolset: 'research',
        parentCancellation: AgentCancellationToken(),
      );

      // 桩网关脚本驱动，不声称调用真实模型；但 calc_eval 是真实执行。
      expect(result.reason, AgentStopReason.completed);
      expect(draft.calledTools, contains('calc_eval'));
      expect(gateway.requests, hasLength(2));
      final secondRequest = jsonEncode(gateway.requests[1].messages);
      expect(secondRequest, contains('3/10'));
      expect(result.lastAssistantText, contains('3/10'));
    });

    test('候选缺 calc/无关候选/写工具的过滤边界保持', () async {
      // 候选不含 calc：出站不含 calc，其余合法项保留。
      final noCalc = _ScriptedGateway([
        const AgentStepResponse(text: '【结论】', toolCalls: []),
      ]);
      await SubagentRunner(
        gateway: noCalc,
        endpoint: endpoint(),
        availableTools: [
          for (final name in [
            'search_story',
            'read_story',
            'update_facts',
            'finish_round',
            'unrelated_read_only',
          ])
            _StubTool(name),
        ],
      ).run(
        brief: 'x',
        toolset: 'research',
        parentCancellation: AgentCancellationToken(),
      );
      final outbound = noCalc.requests.single.tools.map((t) => t.name).toSet();
      expect(outbound, {'search_story', 'read_story'});
      expect(outbound, isNot(contains('calc_eval')));
      expect(outbound, isNot(contains('calc_date')));
      expect(outbound, isNot(contains('unrelated_read_only')));
      expect(outbound, isNot(contains('spawn')));
      expect(outbound, isNot(contains('update_facts')));
      expect(outbound, isNot(contains('finish_round')));

      // plain 恒为空工具。
      final plain = _ScriptedGateway([
        const AgentStepResponse(text: '【结论】', toolCalls: []),
      ]);
      await SubagentRunner(
        gateway: plain,
        endpoint: endpoint(),
        availableTools: [
          for (final name in researchCandidates) _StubTool(name),
        ],
      ).run(
        brief: 'x',
        toolset: 'plain',
        parentCancellation: AgentCancellationToken(),
      );
      expect(plain.requests.single.tools, isEmpty);
    });
  });

  group('SpawnTool', () {
    SpawnTool buildTool(_ScriptedGateway gateway) => SpawnTool(
          SubagentRunner(
            gateway: gateway,
            endpoint: endpoint(),
            availableTools: researchTools(),
          ),
        );

    test('brief 非空校验：空 brief → 可行动失败信封', () async {
      final result = await buildTool(_ScriptedGateway(const []))
          .invoke(spawnInvocation(), const {});

      expect(result.isError, isTrue);
      expect(result.output, contains('brief 不能为空'));
    });

    test('toolset 非法 → 可行动失败信封（不静默降档）', () async {
      final result = await buildTool(_ScriptedGateway(const []))
          .invoke(spawnInvocation(), {'brief': '任务书', 'toolset': 'writer'});

      expect(result.isError, isTrue);
      expect(result.output, contains('research 或 plain'));
    });

    test('max_steps 越界不再静默 clamp：0 给可行动信封（T7，不落入"0=不限步数"语义）', () async {
      final gateway = _ScriptedGateway([
        const AgentStepResponse(text: '迟到的交付物', toolCalls: []),
      ]);
      final result = await buildTool(gateway).invoke(spawnInvocation(), {
        'brief': '核对时间线',
        'max_steps': 0,
      });

      // 越界/非法参数返回指明字段与范围的可行动信封，子代理不启动
      expect(result.isError, isTrue);
      expect(result.output, contains('max_steps'));
      expect(result.output, contains('1-10'));
      expect(gateway.requests, isEmpty);
    });

    test('交付物回传主对话（research 默认档）', () async {
      final gateway = _ScriptedGateway([
        const AgentStepResponse(text: '【结论】时间线已核对，无矛盾。', toolCalls: []),
      ]);
      final result = await buildTool(gateway).invoke(spawnInvocation(), {
        'brief': '核对时间线',
      });

      expect(result.isError, isFalse);
      expect(result.title, '子代理交付物');
      expect(result.output, contains('时间线已核对'));
      expect(result.metadata?['toolset'], 'research');
    });

    test('子代理无输出 → 无结论信封（引导自行查证）', () async {
      final gateway = _ScriptedGateway([
        const AgentStepResponse(text: '', toolCalls: []),
      ]);
      final result = await buildTool(gateway).invoke(spawnInvocation(), {
        'brief': '核对时间线',
      });

      expect(result.isError, isFalse);
      expect(result.title, '子代理无结论');
      expect(result.output, contains('自行用检索工具查证'));
    });

    test('B5-5：子代理消耗并账进父轮 turnUsage（carryLast 不污染 last 分项）', () async {
      final gateway = _ScriptedGateway([
        const AgentStepResponse(
          text: '【结论】已核对。',
          toolCalls: [],
          usage: LlmUsage(
            promptTokens: 500,
            completionTokens: 100,
            totalTokens: 600,
            cacheReadTokens: 50,
          ),
        ),
      ]);
      final usage = AgentUsageAccumulator()
        ..add(
          const LlmUsage(
            promptTokens: 1000,
            completionTokens: 200,
            totalTokens: 1200,
          ),
        );

      final result = await buildTool(gateway).invoke(
        AgentToolInvocation(
          callId: 'c',
          toolName: 'spawn',
          stepIndex: 0,
          cancellation: AgentCancellationToken(),
          turnUsage: usage,
        ),
        {'brief': '核对时间线'},
      );

      expect(result.isError, isFalse);
      // 父轮累计包含子代理消耗：1200 + 600 = 1800
      expect(usage.totalTokens, 1800);
      expect(usage.promptTokens, 1500);
      expect(usage.cacheReadTokens, 50);
      // last 分项不被子代理污染（仍是父轮自己的最近请求）
      expect(usage.lastPromptTokens, 1000);
      expect(usage.lastCompletionTokens, 200);
    });

    test('B5-5：turnUsage 为 null（旧场景）不炸、明细保留 metadata', () async {
      final gateway = _ScriptedGateway([
        const AgentStepResponse(
          text: '【结论】已核对。',
          toolCalls: [],
          usage: LlmUsage(promptTokens: 1, completionTokens: 1),
        ),
      ]);
      final result = await buildTool(gateway).invoke(spawnInvocation(), {
        'brief': '核对时间线',
      });
      expect(result.isError, isFalse);
      expect(result.metadata?['subagentTokens'], 2);
    });

    test('deny 部分只读工具 → 能力位交集过滤仍可运行', () async {
      // availableTools 只剩 search_story：research 档按交集过滤为单工具，
      // 不再抛"能力位缺失"（旧实现 deny 任一只读工具即整体变砖）
      final gateway = _ScriptedGateway([
        const AgentStepResponse(
          text: '【结论】已用检索工具核对。',
          toolCalls: [],
        ),
      ]);
      final tool = SpawnTool(
        SubagentRunner(
          gateway: gateway,
          endpoint: endpoint(),
          availableTools: [_StubTool('search_story')],
        ),
      );

      final result = await tool.invoke(spawnInvocation(), {'brief': '核对时间线'});

      expect(result.isError, isFalse);
      expect(result.title, '子代理交付物');
    });

    test('交集为空 → 退化为纯思考档仍可运行', () async {
      final gateway = _ScriptedGateway([
        const AgentStepResponse(text: '【结论】基于任务书推断。', toolCalls: []),
      ]);
      final tool = SpawnTool(
        SubagentRunner(
          gateway: gateway,
          endpoint: endpoint(),
          availableTools: [_StubTool('unrelated_tool')],
        ),
      );

      final result = await tool.invoke(spawnInvocation(), {'brief': '核对时间线'});

      expect(result.isError, isFalse);
      expect(result.title, '子代理交付物');
    });
  });

  group('SpawnTool 同任务书防重', () {
    SpawnTool buildTool(
      _ScriptedGateway gateway, {
      SubagentBriefMemo? memo,
    }) =>
        SpawnTool(
          SubagentRunner(
            gateway: gateway,
            endpoint: endpoint(),
            availableTools: researchTools(),
          ),
          briefMemo: memo,
        );

    test('同 brief 二次派发：不真跑，直接回执上次结论', () async {
      final gateway = _ScriptedGateway([
        const AgentStepResponse(text: '【结论】沈青梧状态无矛盾。', toolCalls: []),
      ]);
      final memo = SubagentBriefMemo();
      final tool = buildTool(gateway, memo: memo);

      final first = await tool.invoke(spawnInvocation(), {'brief': '核对沈青梧'});
      expect(first.isError, isFalse);
      expect(gateway.requests, hasLength(1));

      final second = await tool.invoke(spawnInvocation(), {'brief': '核对沈青梧'});
      expect(second.isError, isFalse, reason: '防重回执是正常业务结果非错误');
      expect(second.output, contains('沈青梧状态无矛盾'), reason: '回执上次结论');
      expect(second.output, contains('未重新执行'), reason: '向模型声明是缓存回执');
      expect(
        gateway.requests,
        hasLength(1),
        reason: '同 brief 二次派发不得再烧 6 步子代理',
      );
    });

    test('不同 brief 正常真跑', () async {
      final gateway = _ScriptedGateway([
        const AgentStepResponse(text: '【结论甲】', toolCalls: []),
        const AgentStepResponse(text: '【结论乙】', toolCalls: []),
      ]);
      final memo = SubagentBriefMemo();
      final tool = buildTool(gateway, memo: memo);

      await tool.invoke(spawnInvocation(), {'brief': '任务甲'});
      final second = await tool.invoke(spawnInvocation(), {'brief': '任务乙'});

      expect(second.output, contains('结论乙'));
      expect(gateway.requests, hasLength(2));
    });

    test('无结论/失败不缓存：同 brief 再派发仍真跑', () async {
      final gateway = _ScriptedGateway([
        const AgentStepResponse(text: '', toolCalls: []), // 首次无交付物
        const AgentStepResponse(text: '【结论】第二次拿到了。', toolCalls: []),
      ]);
      final memo = SubagentBriefMemo();
      final tool = buildTool(gateway, memo: memo);

      await tool.invoke(spawnInvocation(), {'brief': '核对时间线'});
      final second = await tool.invoke(spawnInvocation(), {'brief': '核对时间线'});

      expect(gateway.requests, hasLength(2), reason: '首次无结论，重试应真跑');
      expect(second.output, contains('第二次拿到了'));
    });

    test('会话级跨轮：memo 由调用方持有，SpawnTool 重建仍命中', () async {
      final gateway = _ScriptedGateway([
        const AgentStepResponse(text: '【结论】第一轮结论。', toolCalls: []),
      ]);
      final memo = SubagentBriefMemo();
      // 每轮 spawnToolFactory 都新建 SpawnTool——memo 在会话层
      await buildTool(gateway, memo: memo)
          .invoke(spawnInvocation(), {'brief': '核对时间线'});
      await buildTool(gateway, memo: memo)
          .invoke(spawnInvocation(), {'brief': '核对时间线'});

      expect(gateway.requests, hasLength(1), reason: '跨轮同 brief 回执上次结论');
    });

    test('防重回执不并账 turnUsage（子代理未真跑无消耗）', () async {
      final gateway = _ScriptedGateway([
        const AgentStepResponse(
          text: '【结论】已核对。',
          toolCalls: [],
          usage: LlmUsage(promptTokens: 500, completionTokens: 100),
        ),
      ]);
      final memo = SubagentBriefMemo();
      final usage = AgentUsageAccumulator();
      final tool = buildTool(gateway, memo: memo);
      final inv = AgentToolInvocation(
        callId: 'c',
        toolName: 'spawn',
        stepIndex: 0,
        cancellation: AgentCancellationToken(),
        turnUsage: usage,
      );

      await tool.invoke(inv, {'brief': '核对时间线'});
      expect(usage.totalTokens, 600, reason: '首次真跑正常并账');

      await tool.invoke(inv, {'brief': '核对时间线'});
      expect(usage.totalTokens, 600, reason: '防重回执不得重复计入消耗');
    });

    test('briefMemo 为 null（旧接线）行为不变：同 brief 二次也真跑', () async {
      final gateway = _ScriptedGateway([
        const AgentStepResponse(text: '【结论一】', toolCalls: []),
        const AgentStepResponse(text: '【结论二】', toolCalls: []),
      ]);
      final tool = buildTool(gateway);

      await tool.invoke(spawnInvocation(), {'brief': '核对时间线'});
      await tool.invoke(spawnInvocation(), {'brief': '核对时间线'});

      expect(gateway.requests, hasLength(2));
    });
  });

  // HAR-09：子代理中继稳定身份——同轮多次 spawn 的中继事件按
  // subagentCallId（= spawn 的 toolCallId，天然唯一）区分，
  // 既有消费方仍按 data['subagent'] 过滤不受影响。
  group('HAR-09 子代理中继稳定身份', () {
    test('同轮两次 spawn 的中继事件 subagentCallId 可区分且与各自 callId 一致', () async {
      final repo = _CapturingEventLogRepository();
      final durableSink = DurableAgentEventSink(
        repository: repo,
        sessionId: 's-main',
        turnNumber: 4,
      );
      final gateway = _ScriptedGateway([
        const AgentStepResponse(text: '【结论甲】', toolCalls: []),
        const AgentStepResponse(text: '【结论乙】', toolCalls: []),
      ]);
      final tool = SpawnTool(
        SubagentRunner(
          gateway: gateway,
          endpoint: endpoint(),
          availableTools: researchTools(),
          externalEventsResolver: (callId) =>
              _SubagentCallIdRelaySink(durableSink, callId),
        ),
      );

      AgentToolInvocation invocation(String callId, int stepIndex) =>
          AgentToolInvocation(
            callId: callId,
            toolName: 'spawn',
            stepIndex: stepIndex,
            cancellation: AgentCancellationToken(),
          );

      await tool.invoke(invocation('spawn-a', 0), {'brief': '任务甲'});
      await durableSink.flush();
      final firstBatch = List.of(repo.appended);

      await tool.invoke(invocation('spawn-b', 1), {'brief': '任务乙'});
      await durableSink.flush();
      final secondBatch = repo.appended.skip(firstBatch.length).toList();

      expect(firstBatch, isNotEmpty, reason: '第一次 spawn 有中继事件');
      expect(
        firstBatch.every((e) => e.data['subagentCallId'] == 'spawn-a'),
        isTrue,
        reason: '中继事件携带各自 spawn 的 callId',
      );
      expect(secondBatch, isNotEmpty);
      expect(
        secondBatch.every((e) => e.data['subagentCallId'] == 'spawn-b'),
        isTrue,
      );
      // subagent 标记不变（既有消费方按它过滤）
      for (final e in [...firstBatch, ...secondBatch]) {
        expect(e.data['subagent'], isTrue);
      }
    });
  });
}

/// 真实 CalcEvalTool 的最小合成依赖：calc 只触 draft.calledTools，
/// 其余端口不应被调用（noSuchMethod fail-loud 防误用）。
AgentToolDeps _calcToolDeps(AgentRoundDraft draft) => AgentToolDeps(
      sessionId: 'subagent-calc',
      draft: draft,
      factualRepository: _NoopFactualRepository(),
      experienceRepository: _NoopExperienceRepository(),
      storyReader: _NoopStoryReader(),
      latestMacros: () async => [],
      userInteraction: _NoopUserInteractionPort(),
      commitRound: (d) async => d.explicitReply ?? 'committed',
    );

class _NoopFactualRepository implements FactualRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _NoopExperienceRepository implements ExperienceRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _NoopStoryReader implements AgentStoryReader {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _NoopUserInteractionPort implements AgentUserInteractionPort {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// 捕获 appendAll 的假仓库（HAR-09 中继链路测试用）
class _CapturingEventLogRepository implements AgentEventLogRepository {
  final List<AgentDurableEvent> appended = [];

  @override
  Future<List<int>> appendAll(
    String sessionId,
    List<AgentDurableEvent> events,
  ) async {
    appended.addAll(events);
    return List.generate(events.length, (i) => i);
  }

  @override
  Future<List<AgentDurableEvent>> readEvents(
    String sessionId, {
    int? fromSeq,
    int? limit,
  }) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// 把 spawn callId 随中继带入 durable sink（模拟 _SubagentDurableRelay 接线）
class _SubagentCallIdRelaySink implements AgentEventSink {
  _SubagentCallIdRelaySink(this._sink, this._callId);

  final DurableAgentEventSink _sink;
  final String _callId;

  @override
  void emit(AgentRunEvent event) =>
      _sink.relaySubagentEvent(event, subagentCallId: _callId);
}
