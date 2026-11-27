/// 关闭态四协议生产链捕获 harness（R5 对照用）。
///
/// 目的：以**真实生产主装配**（`buildAgentTools` + `agentToolsToDefinitions`）
/// 生成工具目录（含幕后 calc），配合等价合成会话与各协议适配器，捕获
/// OpenAI Chat / OpenAI Responses / Anthropic / Gemini 四种关闭态请求体。
/// 不用手写工具数组代替生产装配，也不把当前输出录成自己的期望。
///
/// 运行方式：设置环境变量 `R5_CAPTURE_OUT=/abs/path.json` 后执行本测试，
/// 捕获结果（工具定义原文 + 四协议 body）写入该 JSON；未设置时仅运行
/// 冒烟断言。该文件同时被复制到 259b62c4 基线快照中执行，两臂产物由
/// 仓外比对脚本逐字段对照（证据见
/// doc/experiments/v0_5_0_exp_integration/evidence/r5_protocol_compare/）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/agent/agent_tool.dart';
import 'package:lmstory/core/llm/reasoning_effort.dart';
import 'package:lmstory/core/llm/tool_calling/tool_choice.dart';
import 'package:lmstory/core/network/llm_adapters/anthropic_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/gemini_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/llm_protocol_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/openai_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/responses_adapter.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_round_draft.dart';
import 'package:lmstory/features/advanced/domain/services/agent_session_tools.dart';
import 'package:lmstory/features/advanced/domain/services/agent_story_reader.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';

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

/// 关闭态合成会话（与 durable_surface_wire_scenario 同构的代表性序列）。
List<AgentMessage> _closedModeMessages() => [
      AgentMessage.system('你是导演。项目规则：正文是唯一成果；工具调用用于检索与核对。'),
      AgentMessage.user('查看一下铁匠铺的存货。'),
      AgentMessage.assistant(
        text: '先查一下。',
        thinkingBlocks: [
          const LlmThinkingBlock(
            thinking: '需要先检索库存记录，再整理清单。',
            signature: 'sig-thinking-a1',
          ),
        ],
        toolCalls: [
          const AgentToolCall(
            id: 'c1',
            name: 'search_story',
            arguments: {'query': '铁匠铺 存货'},
            thoughtSignature: 'sig-tool-t1',
          ),
        ],
      ),
      AgentMessage.toolResult(
        toolCallId: 'c1',
        content: '找到 3 条库存记录：铁剑×2、皮甲×1、铁锭×10。',
      ),
      AgentMessage.assistant(text: '铁匠铺现有三件物品，清单如下。'),
      AgentMessage.user('继续，把清单整理成表格。'),
    ];

void main() {
  test('关闭态四协议生产链捕获（真实装配含 calc；env 门控落盘）', () {
    // 真实生产装配：与 DirectorRoundRunner 同源的 buildAgentTools。
    final deps = AgentToolDeps(
      sessionId: 'r5-capture',
      draft: AgentRoundDraft(turnNumber: 1),
      factualRepository: _NoopFactualRepository(),
      experienceRepository: _NoopExperienceRepository(),
      storyReader: _NoopStoryReader(),
      latestMacros: () async => <ExperientialMemory>[],
      userInteraction: _NoopUserInteractionPort(),
      commitRound: (d) async => 'committed',
    );
    final tools = buildAgentTools(deps);
    final defs = agentToolsToDefinitions(tools);
    final toolNames = [for (final t in tools) t.name];

    // 冒烟断言（两臂都必须成立）：幕后 calc 在真实注册集中。
    expect(toolNames, containsAll(['calc_eval', 'calc_date']));

    final adapters = <String, LlmProtocolAdapter>{
      'openaiCompatible': OpenAiAdapter(),
      'openaiResponses': ResponsesAdapter(),
      'anthropic': AnthropicAdapter(),
      'geminiNative': GeminiAdapter(),
    };

    final bodies = <String, dynamic>{};
    for (final entry in adapters.entries) {
      final protocol = LlmProtocol.values.firstWhere(
        (p) => p.name == entry.key,
      );
      final options = AgentWireOptions.forProtocolName(protocol.name);
      final request = LlmRequest(
        baseUrl: 'https://api.example.com/v1',
        apiKey: 'test-key',
        modelId: 'test-model',
        messages: [
          for (final m in _closedModeMessages()) m.toRequestMap(options),
        ],
        temperature: 0.8,
        topP: 0.95,
        maxTokens: 8192,
        reasoningEffort: ReasoningEffort.medium,
        tools: defs,
        toolChoice: ToolChoice.auto,
        protocol: protocol,
        providerOptions: const {},
        stream: false,
      );
      final body = entry.value.buildRequestBody(request, stream: false);
      final encoded = jsonEncode(body);
      // 四协议均按名称序列化工具目录：calc 必须真实进入出站 body。
      expect(encoded, contains('calc_eval'));
      expect(encoded, contains('calc_date'));
      bodies[entry.key] = jsonDecode(encoded);
    }

    final out = Platform.environment['R5_CAPTURE_OUT'];
    if (out != null && out.isNotEmpty) {
      final payload = <String, dynamic>{
        'toolNames': toolNames,
        'tools': [
          for (final d in defs)
            {
              'name': d.name,
              'description': d.description,
              'parameters': d.parameters,
            },
        ],
        'bodies': bodies,
      };
      File(out).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(payload),
      );
    }
  });
}
