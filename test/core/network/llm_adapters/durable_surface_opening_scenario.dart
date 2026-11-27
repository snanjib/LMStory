/// 开启态 wire 金标准的账本场景（仅本树：依赖开启态投影源）。
///
/// 构造一个真实开启态纪元账本（frozen 前缀 + 捕获 + 本轮工具轮轨迹），
/// 经 [DirectorStepSurfaceSource] 投影（与生产每步出站同一管线），按
/// 协议转 wire 并构造 [LlmRequest]——锁定「投影面→请求体」的序列化
/// 形状（正常追加面）。
library;

import 'package:drift/native.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/llm/reasoning_effort.dart';
import 'package:lmstory/core/llm/tool_calling/tool_choice.dart';
import 'package:lmstory/features/advanced/data/agent_durable_event_sink.dart';
import 'package:lmstory/features/advanced/data/director_step_surface_source.dart';
import 'package:lmstory/features/advanced/data/repositories/agent_event_log_repository.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_event_source.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';

import 'durable_surface_wire_scenario.dart';

/// 构造开启态场景请求。
///
/// 返回的 [AppDatabase] 由调用方负责 close（内存库）。
Future<(AppDatabase, LlmRequest)> buildOpeningScenarioRequest(
  LlmProtocol protocol,
) async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final repo = AgentEventLogRepository(database: db);

  AgentDurableEvent ev(
    String type, {
    Map<String, dynamic> data = const {},
    AgentSurfaceOpKind? op,
  }) =>
      AgentDurableEvent(type: type, data: data, surfaceOp: op);

  // 纪元开启面：frozen 前缀 + 捕获（u1/p1，带同源三元组与思考块）+
  // 本轮 u2 + 工具轮轨迹（assistant 思考块/结构化签名 + 回执）+ 继续指令
  await repo.appendAll('s1', [
    ev(
      AgentEventTypes.systemFrozen,
      op: AgentSurfaceOpKind.append,
      data: {'content': '【冻结前缀】世界规则与已固化的工作约定。', 'turn': 1},
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
      data: {'as': 'user', 'content': '第一轮输入', 'epochId': 'e1'},
    ),
    ev(
      AgentEventTypes.modeCapture,
      op: AgentSurfaceOpKind.append,
      data: {
        'as': 'assistant',
        'content': '第一轮正文',
        'epochId': 'e1',
        'source': {
          'protocol': 'openaiCompatible',
          'modelId': 'test-model',
          'endpointFingerprint': 'fp-test-0000',
        },
        'thinkingBlocks': [
          {'thinking': '第一轮的思考。', 'signature': 'sig-capture-1'},
        ],
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
    ev(
      AgentEventTypes.userMessage,
      op: AgentSurfaceOpKind.append,
      data: {'content': '查看一下铁匠铺的存货。', 'turn': 2},
    ),
    ev(
      AgentEventTypes.assistantMessage,
      op: AgentSurfaceOpKind.append,
      data: {
        'text': '先查一下。',
        'turn': 2,
        'attemptId': 'att-1',
        'source': {
          'protocol': 'openaiCompatible',
          'modelId': 'test-model',
          'endpointFingerprint': 'fp-test-0000',
        },
        'toolCalls': [
          {
            'id': 'c1',
            'name': 'search_story',
            'args': {'query': '铁匠铺 存货'},
            'thoughtSignature': 'sig-tool-t1',
          },
        ],
        'thinkingBlocks': [
          {'thinking': '需要先检索库存记录。', 'signature': 'sig-thinking-a1'},
        ],
      },
    ),
    ev(
      AgentEventTypes.toolResult,
      op: AgentSurfaceOpKind.append,
      data: {
        'callId': 'c1',
        'toolName': 'search_story',
        'output': '找到 3 条库存记录：铁剑×2、皮甲×1、铁锭×10。',
        'isError': false,
        'turn': 2,
      },
    ),
    ev(
      AgentEventTypes.userMessage,
      op: AgentSurfaceOpKind.append,
      data: {'content': '继续，把清单整理成表格。', 'turn': 2},
    ),
  ]);

  final source = DirectorStepSurfaceSource(
    durableSink: DurableAgentEventSink(
      repository: repo,
      sessionId: 's1',
      turnNumber: 2,
    ),
    repository: repo,
    sessionId: 's1',
    currentSource: const AgentEventSourceMeta(
      protocol: 'openaiCompatible',
      modelId: 'test-model',
      endpointFingerprint: 'fp-test-0000',
    ),
  );
  final surface = await source.project();
  assert(surface.messages.isNotEmpty, '开启态投影面不得为空');

  final options = AgentWireOptions.forProtocolName(protocol.name);
  final request = LlmRequest(
    baseUrl: 'https://api.example.com/v1',
    apiKey: 'test-key',
    modelId: 'test-model',
    messages: [
      for (final m in surface.messages) m.toRequestMap(options),
    ],
    temperature: 0.8,
    topP: 0.95,
    maxTokens: 8192,
    reasoningEffort: ReasoningEffort.medium,
    tools: scenarioTools(),
    toolChoice: ToolChoice.auto,
    protocol: protocol,
    providerOptions: const {},
    stream: false,
  );
  return (db, request);
}

/// 构造开启态请求体 JSON（生成器与比对测试共用；db 由本函数关闭）
Future<String> openingScenarioBodyJson(LlmProtocol protocol) async {
  final (db, request) = await buildOpeningScenarioRequest(protocol);
  try {
    return jsonBodyOf(request, protocol);
  } finally {
    await db.close();
  }
}
