import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_llm_gateway.dart';
import 'package:lmstory/core/llm/llm_content_block.dart';
import 'package:lmstory/core/llm/tool_calling/tool_choice.dart';
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';
import 'package:lmstory/features/chat/data/agent/llm_service_agent_gateway.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// 记录请求并回放事件脚本的假 LlmService
class _FakeLlmService implements LlmService {
  _FakeLlmService(this.events, {this.response});

  final LlmResponse? response;

  final List<LlmStreamEvent> events;
  final List<LlmRequest> requests = [];

  @override
  Stream<LlmStreamEvent> streamChat(LlmRequest request) async* {
    requests.add(request);
    for (final event in events) {
      yield event;
    }
  }

  @override
  Future<LlmResponse> chat(LlmRequest request) async {
    requests.add(request);
    if (response case final value?) return value;
    throw UnimplementedError('chat not scripted');
  }
}

const _testTools = [
  ToolDefinition(
    name: 'echo',
    description: 'echo',
    parameters: {'type': 'object'},
  ),
];

AgentModelEndpoint _endpoint({
  String baseUrl = 'https://api.test.com',
  String protocol = 'openaiCompatible',
  Map<String, dynamic>? providerOptions,
}) {
  return AgentModelEndpoint(
    baseUrl: baseUrl,
    modelId: 'test-model',
    protocol: protocol,
    providerOptions: providerOptions,
  );
}

void main() {
  group('LlmServiceAgentGateway', () {
    test('非流式 Anthropic 思考块提供可见思考且保留原始签名', () async {
      final service = _FakeLlmService(
        const [],
        response: const LlmResponse(
          content: '先查前情。',
          thinkingBlocks: [
            LlmThinkingBlock(thinking: '核对人物关系。', signature: 'sig'),
          ],
        ),
      );
      final response =
          await LlmServiceAgentGateway(llmService: service).completeStep(
        endpoint: _endpoint(),
        request: const AgentStepRequest(
          messages: [],
          tools: _testTools,
          config: AgentCallConfig(),
        ),
        cancellation: AgentCancellationToken(),
      );
      expect(response.reasoningContent, '核对人物关系。');
      expect(response.thinkingBlocks!.single.signature, 'sig');
    });

    test('中转站文本思考标签跨增量分离为思考与发言', () async {
      final service = _FakeLlmService(const [
        LlmTextDelta('<thi'),
        LlmTextDelta('nk>先核对'),
        LlmTextDelta('前情。</th'),
        LlmTextDelta('ink>现在查阅。'),
        LlmStreamDone(),
      ]);
      final text = <String>[];
      final thinking = <String>[];
      final response =
          await LlmServiceAgentGateway(llmService: service).completeStep(
        endpoint: _endpoint(protocol: 'anthropic'),
        request: const AgentStepRequest(
          messages: [],
          tools: [],
          config: AgentCallConfig(),
        ),
        cancellation: AgentCancellationToken(),
        onTextDelta: text.add,
        onThinkingDelta: thinking.add,
      );
      expect(text.join(), '现在查阅。');
      expect(thinking.join(), '先核对前情。');
      expect(response.text, '现在查阅。');
      expect(response.reasoningContent, '先核对前情。');
    });

    test('每个标签分片位置都保持通道和顺序，普通文本原样保留', () async {
      const reply = '<think>先想中文。</think>查看人物。<think>再想。</think>执行。';
      for (var split = 1; split < reply.length; split++) {
        final service = _FakeLlmService([
          LlmTextDelta(reply.substring(0, split)),
          LlmTextDelta(reply.substring(split)),
          const LlmStreamDone(),
        ]);
        final thinking = <String>[];
        final text = <String>[];
        final response =
            await LlmServiceAgentGateway(llmService: service).completeStep(
          endpoint: _endpoint(protocol: 'anthropic'),
          request: const AgentStepRequest(
            messages: [],
            tools: [],
            config: AgentCallConfig(),
          ),
          cancellation: AgentCancellationToken(),
          onTextDelta: text.add,
          onThinkingDelta: thinking.add,
        );
        expect(response.text, '查看人物。执行。', reason: 'split=$split');
        expect(text.join(), response.text);
        expect(thinking.join(), '先想中文。再想。');
      }
      final response = await LlmServiceAgentGateway(
        llmService: _FakeLlmService(const [
          LlmTextDelta('小于 3 < 5，'),
          LlmTextDelta('普通 <thing> 和末尾 <th'),
          LlmStreamDone(),
        ]),
      ).completeStep(
        endpoint: _endpoint(),
        request: const AgentStepRequest(
          messages: [],
          tools: [],
          config: AgentCallConfig(),
        ),
        cancellation: AgentCancellationToken(),
      );
      expect(response.text, '小于 3 < 5，普通 <thing> 和末尾 <th');
    });

    test('结构化思考的显示去除包装，签名原文保真且不重复', () async {
      const raw = '<think>核对人物。</think>';
      final response = await LlmServiceAgentGateway(
        llmService: _FakeLlmService(const [
          LlmThinkingDelta('<thi'),
          LlmThinkingDelta('nk>核对人物。</think>'),
          LlmThinkingBlockComplete(
            thinking: raw,
            signature: 'opaque-signature',
          ),
          LlmContentBlockComplete(
            LlmThinkingContentBlock(
              thinking: raw,
              signature: 'opaque-signature',
            ),
          ),
          LlmTextDelta('查阅前情。'),
          LlmStreamDone(),
        ]),
      ).completeStep(
        endpoint: _endpoint(protocol: 'anthropic'),
        request: const AgentStepRequest(
          messages: [],
          tools: [],
          config: AgentCallConfig(),
        ),
        cancellation: AgentCancellationToken(),
      );
      expect(response.reasoningContent, '核对人物。');
      expect(response.thinkingBlocks!.single.thinking, raw);
      expect(
        (response.contentBlocks!.single as LlmThinkingContentBlock).thinking,
        raw,
      );
      expect(response.thinkingBlocks!.single.signature, 'opaque-signature');
    });

    test('流式聚合：文本 + 多工具调用 + usage', () async {
      final service = _FakeLlmService([
        const LlmTextDelta('我来'),
        const LlmTextDelta('查一下。'),
        const LlmToolCallStart('call_1', 'echo'),
        const LlmToolCallArgs('call_1', '{"text":'),
        const LlmToolCallComplete(
          toolCallId: 'call_1',
          name: 'echo',
          arguments: {'text': 'hi'},
        ),
        const LlmStreamDone(
          usage: LlmUsage(promptTokens: 50, completionTokens: 10),
        ),
      ]);
      final gateway = LlmServiceAgentGateway(llmService: service);

      final textDeltas = <String>[];
      final response = await gateway.completeStep(
        endpoint: _endpoint(baseUrl: 'https://api.openai.com/v1'),
        request: const AgentStepRequest(
          messages: [
            {'role': 'user', 'content': 'hi'},
          ],
          tools: _testTools,
          config: AgentCallConfig(toolChoice: ToolChoice.auto),
        ),
        cancellation: AgentCancellationToken(),
        onTextDelta: textDeltas.add,
      );

      expect(response.text, '我来查一下。');
      expect(textDeltas, ['我来', '查一下。']);
      expect(response.toolCalls, hasLength(1));
      expect(response.toolCalls.first.arguments, {'text': 'hi'});
      expect(response.usage?.promptTokens, 50);
      expect(response.usage?.completionTokens, 10);
    });

    test('工具参数增量转发：onToolArgDelta 收到分片（含 Start 登记的工具名）', () async {
      final service = _FakeLlmService([
        const LlmTextDelta('过场播报。'),
        const LlmToolCallStart('call_1', 'finish_round'),
        const LlmToolCallArgs('call_1', '{"prose":"第一'),
        const LlmToolCallArgs('call_1', '段\n第二段"}'),
        const LlmToolCallComplete(
          toolCallId: 'call_1',
          name: 'finish_round',
          arguments: {'prose': '第一段\n第二段'},
        ),
        const LlmStreamDone(),
      ]);
      final gateway = LlmServiceAgentGateway(llmService: service);

      final argDeltas = <(String, String, String)>[];
      await gateway.completeStep(
        endpoint: _endpoint(baseUrl: 'https://api.openai.com/v1'),
        request: const AgentStepRequest(
          messages: [
            {'role': 'user', 'content': 'hi'},
          ],
          tools: _testTools,
          config: AgentCallConfig(),
        ),
        cancellation: AgentCancellationToken(),
        onToolArgDelta: (id, name, delta) => argDeltas.add((id, name, delta)),
      );

      expect(argDeltas, [
        ('call_1', 'finish_round', '{"prose":"第一'),
        ('call_1', 'finish_round', '段\n第二段"}'),
      ]);
    });

    test('空 args 增量不转发（噪音过滤）', () async {
      final service = _FakeLlmService([
        const LlmToolCallStart('call_1', 'echo'),
        const LlmToolCallArgs('call_1', ''),
        const LlmToolCallComplete(
          toolCallId: 'call_1',
          name: 'echo',
          arguments: {},
        ),
        const LlmStreamDone(),
      ]);
      final gateway = LlmServiceAgentGateway(llmService: service);

      final argDeltas = <String>[];
      await gateway.completeStep(
        endpoint: _endpoint(baseUrl: 'https://api.openai.com/v1'),
        request: const AgentStepRequest(
          messages: [
            {'role': 'user', 'content': 'hi'},
          ],
          tools: _testTools,
          config: AgentCallConfig(),
        ),
        cancellation: AgentCancellationToken(),
        onToolArgDelta: (_, __, delta) => argDeltas.add(delta),
      );

      expect(argDeltas, isEmpty);
    });

    test('协议字段保留：thinking block + 思维链 + thoughtSignature', () async {
      final service = _FakeLlmService([
        const LlmThinkingDelta('思考中'),
        const LlmThinkingBlockComplete(
          thinking: '完整思考',
          signature: 'sig-abc',
        ),
        const LlmToolCallComplete(
          toolCallId: 'gemini_search',
          name: 'search',
          arguments: {'q': 1},
          thoughtSignature: 'thought-sig',
        ),
        const LlmStreamDone(),
      ]);
      final gateway = LlmServiceAgentGateway(llmService: service);

      final response = await gateway.completeStep(
        endpoint: _endpoint(baseUrl: 'https://api.openai.com/v1'),
        request: const AgentStepRequest(
          messages: [
            {'role': 'user', 'content': 'hi'},
          ],
          tools: _testTools,
          config: AgentCallConfig(),
        ),
        cancellation: AgentCancellationToken(),
      );

      expect(response.reasoningContent, '思考中');
      expect(response.thinkingBlocks!.single.signature, 'sig-abc');
      expect(response.toolCalls.single.thoughtSignature, 'thought-sig');
    });

    test('GLM 直连：注入 tool_stream 与串行 parallel', () async {
      final service = _FakeLlmService(
        const [LlmTextDelta('ok'), LlmStreamDone()],
      );
      final gateway = LlmServiceAgentGateway(llmService: service);

      await gateway.completeStep(
        endpoint: _endpoint(baseUrl: 'https://open.bigmodel.cn/api/paas/v4'),
        request: const AgentStepRequest(
          messages: [
            {'role': 'user', 'content': 'hi'},
          ],
          tools: _testTools,
          config: AgentCallConfig(toolChoice: ToolChoice.required),
        ),
        cancellation: AgentCancellationToken(),
      );

      final request = service.requests.single;
      // tool_choice required 不受支持 → 降级 auto
      expect(request.toolChoice, ToolChoice.auto);
      expect(request.providerOptions!['parallel_tool_calls'], isFalse);
      expect(
        (request.providerOptions!['extra_body'] as Map)['tool_stream'],
        isTrue,
      );
    });

    test('未知中转站：工具步回退非流式请求', () async {
      final service = _FakeLlmService(const []);
      final gateway = LlmServiceAgentGateway(llmService: service);

      await expectLater(
        gateway.completeStep(
          endpoint: _endpoint(baseUrl: 'https://relay.unknown.io/v1'),
          request: const AgentStepRequest(
            messages: [
              {'role': 'user', 'content': 'hi'},
            ],
            tools: _testTools,
            config: AgentCallConfig(),
          ),
          cancellation: AgentCancellationToken(),
        ),
        throwsA(isA<AgentLlmException>()), // 假 service 的 chat 未脚本化 → 包装为网关异常
      );

      // 请求以非流式发出（FakeLlmService.chat 收到后再抛错）
      final request = service.requests.single;
      expect(request.stream, isFalse);
      expect(request.providerOptions!['parallel_tool_calls'], isFalse);
    });

    test('流错误 → AgentLlmException（可重试分类）', () async {
      final service = _FakeLlmService(const [
        LlmStreamError('rate limited', code: '429'),
      ]);
      final gateway = LlmServiceAgentGateway(llmService: service);

      await expectLater(
        gateway.completeStep(
          endpoint: _endpoint(baseUrl: 'https://api.openai.com/v1'),
          request: const AgentStepRequest(
            messages: [
              {'role': 'user', 'content': 'hi'},
            ],
            tools: _testTools,
            config: AgentCallConfig(),
          ),
          cancellation: AgentCancellationToken(),
        ),
        throwsA(
          isA<AgentLlmException>()
              .having((e) => e.retryable, 'retryable', isTrue),
        ),
      );
    });

    // 流内语义码归一——AUTH/参数类 400 不重试，限流带冷却
    group('B3 语义码归一', () {
      Future<AgentLlmException> runOnce(List<LlmStreamEvent> events) async {
        final service = _FakeLlmService(events);
        final gateway = LlmServiceAgentGateway(llmService: service);
        try {
          await gateway.completeStep(
            endpoint: _endpoint(baseUrl: 'https://api.openai.com/v1'),
            request: const AgentStepRequest(
              messages: [
                {'role': 'user', 'content': 'hi'},
              ],
              tools: _testTools,
              config: AgentCallConfig(),
            ),
            cancellation: AgentCancellationToken(),
          );
        } on AgentLlmException catch (e) {
          return e;
        }
        fail('未抛出 AgentLlmException');
      }

      test('AUTH 语义码 → 不可重试', () async {
        final e = await runOnce(const [
          LlmStreamError('invalid api key', code: 'AUTH'),
        ]);
        expect(e.retryable, isFalse);
      });

      test('RATE_LIMIT 语义码 → 可重试且携带 Retry-After 冷却', () async {
        final e = await runOnce(const [
          LlmStreamError(
            'rate limited',
            code: 'RATE_LIMIT',
            retryAfter: Duration(seconds: 12),
          ),
        ]);
        expect(e.retryable, isTrue);
        expect(e.retryAfter, const Duration(seconds: 12));
      });

      test('SERVER 语义码 → 可重试；BAD_REQUEST 语义码 → 不可重试', () async {
        final server = await runOnce(const [
          LlmStreamError('upstream error', code: 'SERVER'),
        ]);
        expect(server.retryable, isTrue);
        final badRequest = await runOnce(const [
          LlmStreamError('invalid request', code: 'BAD_REQUEST'),
        ]);
        expect(badRequest.retryable, isFalse);
      });
    });

    group('T5 上下文超限归一（CONTEXT_OVERFLOW 语义码）', () {
      Future<Object?> runOnce(List<LlmStreamEvent> events) async {
        final service = _FakeLlmService(events);
        final gateway = LlmServiceAgentGateway(llmService: service);
        try {
          await gateway.completeStep(
            endpoint: _endpoint(baseUrl: 'https://api.openai.com/v1'),
            request: const AgentStepRequest(
              messages: [
                {'role': 'user', 'content': 'hi'},
              ],
              tools: _testTools,
              config: AgentCallConfig(),
            ),
            cancellation: AgentCancellationToken(),
          );
          return null;
        } on AgentLlmException catch (e) {
          return e;
        }
      }

      test('OpenAI 文案：maximum context length → overflow + retryable', () async {
        final e = (await runOnce(const [
          LlmStreamError(
            "This model's maximum context length is 128000 tokens. "
            'However, you requested 200000 tokens.',
            code: '400',
          ),
        ]))! as AgentLlmException;
        expect(e.semantic, AgentLlmErrorSemantic.contextOverflow);
        expect(e.retryable, isTrue);
      });

      test('OpenAI 错误码：context_length_exceeded → overflow', () async {
        final e = (await runOnce(
          const [LlmStreamError('too long', code: 'context_length_exceeded')],
        ))! as AgentLlmException;
        expect(e.semantic, AgentLlmErrorSemantic.contextOverflow);
        expect(e.retryable, isTrue);
      });

      test('Anthropic 文案：prompt is too long → overflow', () async {
        final e = (await runOnce(const [
          LlmStreamError(
            'prompt is too long: 205845 tokens > 200000 maximum',
            code: '400',
          ),
        ]))! as AgentLlmException;
        expect(e.semantic, AgentLlmErrorSemantic.contextOverflow);
      });

      test('Gemini 文案：exceeds the maximum number of tokens → overflow',
          () async {
        final e = (await runOnce(const [
          LlmStreamError(
            'The input token count (123456) exceeds the maximum number of '
            'tokens allowed (100000)',
          ),
        ]))! as AgentLlmException;
        expect(e.semantic, AgentLlmErrorSemantic.contextOverflow);
      });

      test('中转站中文文案：上下文长度 → overflow', () async {
        final e = (await runOnce(
          const [LlmStreamError('请求失败：输入超过模型上下文长度限制')],
        ))! as AgentLlmException;
        expect(e.semantic, AgentLlmErrorSemantic.contextOverflow);
      });

      test('普通 400 参数错误不误判为 overflow', () async {
        final e = (await runOnce(
          const [LlmStreamError('invalid request: unknown field', code: '400')],
        ))! as AgentLlmException;
        expect(e.semantic, isNull);
        expect(e.retryable, isFalse);
      });
    });

    // HAR-05 软着陆保形：step 级 toolChoice=none 透传，tools 保留——
    // 软着陆步不清空 tools（空数组经网关转 null 省略 tools 键，该步
    // 全前缀缓存 miss），改以 tool_choice=none 停用工具。
    test('HAR-05：step toolChoice=none 透传且 tools 保留（软着陆保形）', () async {
      final service = _FakeLlmService(
        const [LlmTextDelta('收尾。'), LlmStreamDone()],
      );
      final gateway = LlmServiceAgentGateway(llmService: service);

      await gateway.completeStep(
        endpoint: _endpoint(baseUrl: 'https://api.openai.com/v1'),
        request: const AgentStepRequest(
          messages: [
            {'role': 'user', 'content': 'hi'},
          ],
          tools: _testTools,
          toolChoice: ToolChoice.none,
          config: AgentCallConfig(),
        ),
        cancellation: AgentCancellationToken(),
      );

      final request = service.requests.single;
      expect(request.tools, isNotNull, reason: 'tools 键不因软着陆被省略');
      expect(request.toolChoice, ToolChoice.none);
      expect(request.stream, isTrue);
    });

    test('HAR-05：toolChoice=none 的工具步在未知中转站仍走流式（无工具调用预期）', () async {
      final service = _FakeLlmService(
        const [LlmTextDelta('收尾。'), LlmStreamDone()],
      );
      final gateway = LlmServiceAgentGateway(llmService: service);

      await gateway.completeStep(
        endpoint: _endpoint(baseUrl: 'https://relay.unknown.io/v1'),
        request: const AgentStepRequest(
          messages: [
            {'role': 'user', 'content': 'hi'},
          ],
          tools: _testTools,
          toolChoice: ToolChoice.none,
          config: AgentCallConfig(),
        ),
        cancellation: AgentCancellationToken(),
      );

      // 中转站「流式工具不可靠」回退非流式只针对工具步；toolChoice=none
      // 无工具调用预期，保流式（软着陆收尾正文的流式交付不因保形回退）
      expect(service.requests.single.stream, isTrue);
    });

    test('取消令牌已触发 → 请求携带已取消的 HTTP 令牌', () async {
      final service = _FakeLlmService(const []);
      final gateway = LlmServiceAgentGateway(llmService: service);
      final token = AgentCancellationToken()..cancel('用户取消');

      // 已取消时网关短路：抛取消异常且不发出请求
      await expectLater(
        gateway.completeStep(
          endpoint: _endpoint(),
          request: const AgentStepRequest(
            messages: [
              {'role': 'user', 'content': 'hi'},
            ],
            tools: [],
            config: AgentCallConfig(),
          ),
          cancellation: token,
        ),
        throwsA(isA<AgentCancelledException>()),
      );
      expect(service.requests, isEmpty);
    });

    test('D3/D4 修复：双惩罚与思考档位透传进流式 LlmRequest', () async {
      final service = _FakeLlmService(
        const [LlmTextDelta('ok'), LlmStreamDone()],
      );
      final gateway = LlmServiceAgentGateway(llmService: service);

      await gateway.completeStep(
        endpoint: _endpoint(baseUrl: 'https://api.openai.com/v1'),
        request: const AgentStepRequest(
          messages: [
            {'role': 'user', 'content': 'hi'},
          ],
          tools: [],
          config: AgentCallConfig(
            temperature: 0.8,
            presencePenalty: 0.6,
            frequencyPenalty: 0.3,
            reasoningEffort: ReasoningEffort.high,
          ),
        ),
        cancellation: AgentCancellationToken(),
      );

      final request = service.requests.single;
      expect(request.presencePenalty, 0.6);
      expect(request.frequencyPenalty, 0.3);
      expect(request.reasoningEffort, ReasoningEffort.high);
    });

    test('D3/D4 修复：非流式回退路径同样透传双惩罚与思考档位', () async {
      final service = _FakeLlmService(const []);
      final gateway = LlmServiceAgentGateway(llmService: service);

      // 未知中转站：工具步回退非流式（chat 未脚本化会抛错，只验证请求形状）
      await expectLater(
        gateway.completeStep(
          endpoint: _endpoint(baseUrl: 'https://relay.unknown.io/v1'),
          request: const AgentStepRequest(
            messages: [
              {'role': 'user', 'content': 'hi'},
            ],
            tools: _testTools,
            config: AgentCallConfig(
              presencePenalty: -0.5,
              frequencyPenalty: 0.2,
              reasoningEffort: ReasoningEffort.low,
            ),
          ),
          cancellation: AgentCancellationToken(),
        ),
        throwsA(isA<AgentLlmException>()),
      );

      final request = service.requests.single;
      expect(request.presencePenalty, -0.5);
      expect(request.frequencyPenalty, 0.2);
      expect(request.reasoningEffort, ReasoningEffort.low);
    });

    test('stablePrefixEndIndex 透传为 cacheBreakpointIndex', () async {
      final service = _FakeLlmService([
        const LlmTextDelta('ok'),
        const LlmStreamDone(),
      ]);
      final gateway = LlmServiceAgentGateway(llmService: service);

      await gateway.completeStep(
        endpoint: _endpoint(baseUrl: 'https://api.openai.com/v1'),
        request: const AgentStepRequest(
          messages: [
            {'role': 'user', 'content': 'hi'},
          ],
          tools: _testTools,
          config: AgentCallConfig(),
          stablePrefixEndIndex: 3,
        ),
        cancellation: AgentCancellationToken(),
      );

      expect(service.requests.single.cacheBreakpointIndex, 3);

      final nullService = _FakeLlmService([
        const LlmTextDelta('ok'),
        const LlmStreamDone(),
      ]);
      await LlmServiceAgentGateway(llmService: nullService).completeStep(
        endpoint: _endpoint(baseUrl: 'https://api.openai.com/v1'),
        request: const AgentStepRequest(
          messages: [
            {'role': 'user', 'content': 'hi'},
          ],
          tools: _testTools,
          config: AgentCallConfig(),
        ),
        cancellation: AgentCancellationToken(),
      );
      expect(nullService.requests.single.cacheBreakpointIndex, isNull);
    });

    test('聚合有序内容块（含 redacted_thinking）', () async {
      final service = _FakeLlmService([
        const LlmContentBlockComplete(
          LlmThinkingContentBlock(thinking: 't', signature: 's'),
        ),
        const LlmContentBlockComplete(
          LlmRedactedThinkingContentBlock(data: 'redacted'),
        ),
        const LlmTextDelta('ok'),
        const LlmContentBlockComplete(LlmTextContentBlock(text: 'ok')),
        const LlmStreamDone(),
      ]);
      final gateway = LlmServiceAgentGateway(llmService: service);

      final response = await gateway.completeStep(
        endpoint: _endpoint(
          protocol: 'anthropic',
          baseUrl: 'https://api.anthropic.com',
        ),
        request: const AgentStepRequest(
          messages: [
            {'role': 'user', 'content': 'hi'},
          ],
          tools: _testTools,
          config: AgentCallConfig(),
        ),
        cancellation: AgentCancellationToken(),
      );

      expect(response.contentBlocks, hasLength(3));
      expect(response.contentBlocks![0], isA<LlmThinkingContentBlock>());
      expect(
        response.contentBlocks![1],
        isA<LlmRedactedThinkingContentBlock>(),
      );
      expect(response.contentBlocks![2], isA<LlmTextContentBlock>());
    });

    test('context_window_exceeded 空响应 → 上下文超限语义', () async {
      final service = _FakeLlmService([
        const LlmStreamDone(finishReason: 'context_window_exceeded'),
      ]);
      final gateway = LlmServiceAgentGateway(llmService: service);

      await expectLater(
        gateway.completeStep(
          endpoint: _endpoint(
            protocol: 'anthropic',
            baseUrl: 'https://api.anthropic.com',
          ),
          request: const AgentStepRequest(
            messages: [
              {'role': 'user', 'content': 'hi'},
            ],
            tools: _testTools,
            config: AgentCallConfig(),
          ),
          cancellation: AgentCancellationToken(),
        ),
        throwsA(
          isA<AgentLlmException>()
              .having(
                (e) => e.semantic,
                'semantic',
                AgentLlmErrorSemantic.contextOverflow,
              )
              .having((e) => e.retryable, 'retryable', isTrue),
        ),
      );
    });

    test('pause_turn → 非重试协议错误', () async {
      final service = _FakeLlmService([
        const LlmStreamDone(finishReason: 'pause_turn'),
      ]);
      final gateway = LlmServiceAgentGateway(llmService: service);

      await expectLater(
        gateway.completeStep(
          endpoint: _endpoint(
            protocol: 'anthropic',
            baseUrl: 'https://api.anthropic.com',
          ),
          request: const AgentStepRequest(
            messages: [
              {'role': 'user', 'content': 'hi'},
            ],
            tools: _testTools,
            config: AgentCallConfig(),
          ),
          cancellation: AgentCancellationToken(),
        ),
        throwsA(
          isA<AgentLlmException>()
              .having((e) => e.code, 'code', 'PAUSE_TURN')
              .having((e) => e.retryable, 'retryable', isFalse),
        ),
      );
    });
  });
}
