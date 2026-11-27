/// durable surface wire goldens 的共享场景构造（纯 Dart，无 flutter 依赖）。
///
/// 两个用途：
/// 1. `dart run` 独立执行（`main`），按协议名打印请求体 JSON——
///    在基线 46afedd9 提取树与本树上运行，产出**关闭态 byte 对照**
///    金标准（证明本分支未改变关闭态出站 wire 字节）。
/// 2. 被 golden 比对测试（durable_surface_wire_golden_test.dart）导入，与金标准文件
///    逐字节比对（关闭态=基线字节；开启态=本树生成后锁定）。
///
/// 场景为代表性导演请求：系统规则 + 用户输入 + assistant（思考块+
/// 结构化签名+工具调用）+ 工具回执 + assistant 收尾 + 继续指令，
/// 带 tools 与 tool_choice=auto（回执/闸门 wire 形态一并锁定）。
/// 思考回传按协议分歧：anthropic/gemini 携带 thinkingBlocks 与
/// thought_signature，openai 系带 reasoning_content（空=不出键）。
library;

import 'dart:convert';

import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/llm/reasoning_effort.dart';
import 'package:lmstory/core/llm/tool_calling/tool_choice.dart';
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';
import 'package:lmstory/core/network/llm_adapters/anthropic_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/gemini_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/llm_protocol_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/openai_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/responses_adapter.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';

/// 四协议适配器（构造均无必选参数；非 const 构造，按需取用）
Map<String, LlmProtocolAdapter> scenarioAdapters() => {
      'openaiCompatible': OpenAiAdapter(),
      'openaiResponses': ResponsesAdapter(),
      'anthropic': AnthropicAdapter(),
      'geminiNative': GeminiAdapter(),
    };

const List<LlmProtocol> kScenarioProtocols = [
  LlmProtocol.openaiCompatible,
  LlmProtocol.openaiResponses,
  LlmProtocol.anthropic,
  LlmProtocol.geminiNative,
];

/// 场景工具定义（与导演真实工具形状同构：对象参数+必填键）
List<ToolDefinition> scenarioTools() => const [
      ToolDefinition(
        name: 'search_story',
        description: '按关键词搜索历史剧情与用户输入。',
        parameters: {
          'type': 'object',
          'properties': {
            'query': {'type': 'string'},
          },
          'required': ['query'],
        },
      ),
      ToolDefinition(
        name: 'query_facts',
        description: '按名称查询设定卡当前事实。',
        parameters: {
          'type': 'object',
          'properties': {
            'name': {'type': 'string'},
          },
          'required': ['name'],
        },
      ),
    ];

/// 关闭态代表性消息序列
List<AgentMessage> closedModeScenarioMessages() => [
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

/// 按协议构造场景请求（wire 映射经 AgentMessage.toRequestMap——
/// 与生产 runner 同一序列化函数）
LlmRequest scenarioRequest(LlmProtocol protocol) {
  final options = AgentWireOptions.forProtocolName(protocol.name);
  return LlmRequest(
    baseUrl: 'https://api.example.com/v1',
    apiKey: 'test-key',
    modelId: 'test-model',
    messages: [
      for (final m in closedModeScenarioMessages()) m.toRequestMap(options),
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
}

/// 构造请求体并序列化为金标准字节（插入序确定，逐字节比对）
String jsonBodyOf(LlmRequest request, LlmProtocol protocol) => jsonEncode(
      scenarioAdapters()[protocol.name]!
          .buildRequestBody(request, stream: false),
    );

String scenarioBodyJson(LlmProtocol protocol) =>
    jsonBodyOf(scenarioRequest(protocol), protocol);

/// 独立执行入口：`dart run <本文件> <protocol>` 打印单个请求体 JSON
void main(List<String> args) {
  if (args.isEmpty) {
    for (final p in kScenarioProtocols) {
      // ignore: avoid_print
      print('${p.name}\t${scenarioBodyJson(p)}');
    }
    return;
  }
  final protocol = LlmProtocol.values.firstWhere((p) => p.name == args.first);
  // ignore: avoid_print
  print(scenarioBodyJson(protocol));
}
