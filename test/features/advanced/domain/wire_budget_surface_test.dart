import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/llm/llm_content_block.dart';
import 'package:lmstory/core/network/llm_adapters/anthropic_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/gemini_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/openai_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/output_budget.dart';
import 'package:lmstory/core/network/llm_adapters/responses_adapter.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_event_source.dart';
import 'package:lmstory/features/advanced/domain/services/compaction_planning.dart';
import 'package:lmstory/features/advanced/domain/services/surface_representations.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';

/// 完整预算面 wire-map 口径：预算与当前协议真实可回传表面同源——
/// 保留的 signed thinking / redacted data 经真实适配器确实在 body 中，
/// 估算必须计入；双表示归一不双计；剥离后不计。压缩输出预留与适配器
/// 解析后的有效请求输出上限同源。

/// Core 预算分发器只接受中性协议值（仓规）；映射与生产调用方同形。
WireOutputProtocol wireOf(LlmProtocol protocol) => switch (protocol) {
      LlmProtocol.anthropic => WireOutputProtocol.anthropic,
      LlmProtocol.openaiCompatible => WireOutputProtocol.openaiCompatible,
      LlmProtocol.openaiResponses => WireOutputProtocol.openaiResponses,
      LlmProtocol.geminiNative => WireOutputProtocol.geminiNative,
    };

void main() {
  for (final redacted in [false, true]) {
    test(
      'retained ${redacted ? "redacted data" : "signed thinking"} counts in '
      'actual surface budget',
      () {
        final payload = 'x' * 20000;
        final block = redacted
            ? LlmRedactedThinkingContentBlock(data: payload)
            : LlmThinkingContentBlock(
                thinking: payload,
                signature: 'valid-signature',
              );
        final event = AgentDurableEvent(
          type: AgentEventTypes.assistantMessage,
          surfaceOp: AgentSurfaceOpKind.append,
          data: {
            'text': 'ok',
            'contentBlocks': [
              block.toAnthropicJson(),
              {'type': 'text', 'text': 'ok'},
            ],
            'source': {
              'protocol': 'anthropic',
              'modelId': 'claude-test',
              'endpoint': 'fp-test',
              'encoding': 'utf8-v1',
            },
          },
        );
        final safe = stripUnreplayableRepresentations(
          events: [event],
          currentSource: AgentEventSourceMeta.fromData(event.data),
          thinkingReplayAllowed: true,
        );
        final projected = deriveAgentSurface(safe).messages;
        final request = LlmRequest(
          baseUrl: 'https://stub.invalid',
          apiKey: 'unused',
          modelId: 'claude-test',
          protocol: LlmProtocol.anthropic,
          messages: [
            for (final m in projected)
              m.toRequestMap(const AgentWireOptions(anthropicExtras: true)),
          ],
          maxTokens: 1000,
        );
        final body =
            AnthropicAdapter().buildRequestBody(request, stream: false);
        expect(
          jsonEncode(body),
          contains(payload),
          reason: 'actual adapter retains payload',
        );
        expect(
          surfaceInputChars(
            projected,
            options: const AgentWireOptions(anthropicExtras: true),
          ),
          greaterThanOrEqualTo(payload.length),
          reason: 'retained request material must not disappear from '
              'compaction and delta estimates',
        );
      },
    );
  }

  test('剥离后不计：thinkingReplayAllowed=false 的思考块不进估算', () {
    final payload = 'y' * 20000;
    final event = AgentDurableEvent(
      type: AgentEventTypes.assistantMessage,
      surfaceOp: AgentSurfaceOpKind.append,
      data: {
        'text': 'ok',
        'contentBlocks': [
          LlmThinkingContentBlock(thinking: payload, signature: 'sig')
              .toAnthropicJson(),
        ],
        'source': {
          'protocol': 'anthropic',
          'modelId': 'claude-test',
          'endpoint': 'fp-test',
          'encoding': 'utf8-v1',
        },
      },
    );
    final stripped = stripUnreplayableRepresentations(
      events: [event],
      currentSource: AgentEventSourceMeta.fromData(event.data),
      thinkingReplayAllowed: false,
    );
    final projected = deriveAgentSurface(stripped).messages;
    expect(
      surfaceInputChars(
        projected,
        options: const AgentWireOptions(anthropicExtras: true),
      ),
      lessThan(1000),
      reason: '剥离后的思考内容不会随请求发出，估算不得计入',
    );
  });

  // 适配器会丢弃的表示不得计价：无签名 thinking 无论走有序块还是平行
  // 字段，真实 Anthropic body 都不含它——估算与最终序列化表示一致，
  // 否则多余压缩/净差分失真。
  for (final ordered in [true, false]) {
    test(
      '适配器丢弃的无签名思考不计价（${ordered ? "有序块" : "平行字段"}形态）',
      () {
        final payload = 'x' * 20000;
        final message = AgentMessage.assistant(
          text: 'ok',
          contentBlocks: ordered
              ? [
                  LlmThinkingContentBlock(thinking: payload, signature: ''),
                  const LlmTextContentBlock(text: 'ok'),
                ]
              : null,
          thinkingBlocks: ordered
              ? null
              : [LlmThinkingBlock(thinking: payload, signature: '')],
        );
        const options = AgentWireOptions(anthropicExtras: true);
        final body = AnthropicAdapter().buildRequestBody(
          LlmRequest(
            baseUrl: 'https://stub.invalid',
            apiKey: 'unused',
            modelId: 'claude-test',
            protocol: LlmProtocol.anthropic,
            maxTokens: 1000,
            messages: [message.toRequestMap(options)],
          ),
          stream: false,
        );
        expect(
          jsonEncode(body),
          isNot(contains(payload)),
          reason: '真实适配器丢弃无签名块',
        );
        expect(
          surfaceInputChars([message], options: options),
          lessThan(1000),
          reason: '最终序列化已丢弃的材料不得触发压缩或抬高差分',
        );
      },
    );
  }

  test('双表示不双计：anthropicBlocks 可用时取代 content/thinkingBlocks', () {
    final payload = 'z' * 20000;
    // 同一思考内容同时落在 thinkingBlocks 与 anthropicBlocks（合法存量
    // 形态）——raw map 双键双计，估算 map 按适配器实际发送形态归一
    final m = AgentMessage.assistant(
      text: 'ok',
      thinkingBlocks: [
        LlmThinkingBlock(thinking: payload, signature: 'sig'),
      ],
      contentBlocks: [
        LlmThinkingContentBlock(thinking: payload, signature: 'sig'),
        const LlmTextContentBlock(text: 'ok'),
      ],
    );
    const anthropic = AgentWireOptions(anthropicExtras: true);
    final chars = messageSurfaceChars(m, anthropic);
    // 计入（blocks 是真实发送材料）……
    expect(chars, greaterThanOrEqualTo(payload.length));
    // ……且只计一次（raw map 会双计 ≥2×payload）
    final rawMap = m.toRequestMap(anthropic);
    expect(
      chars,
      lessThan(jsonEncode(rawMap).length),
      reason: '双表示归一后不得双计同一思考内容',
    );
    // 归一后的 map 不含被取代键
    final rawKeys = rawMap.keys.toSet();
    expect(
      rawKeys,
      containsAll(['content', 'thinkingBlocks', 'anthropicBlocks']),
    );
  });

  // 网关（llm_service_agent_gateway）会把同一思考内容同时放进聚合字段
  // 与结构化块，但各适配器最终 body 形态不同：Anthropic 只发结构化块
  // （有序块与回退重建都不读聚合 reasoningContent）、Responses 不回放
  // 明文 reasoning（reasoning item 为服务端加密内容）、OpenAI 兼容端点
  // 原样透传 reasoning_content、Gemini 只发 thought Part。估算逐协议与
  // 最终 body 对拍：同一 payload 不双计、被丢弃的不计。
  test('Anthropic：聚合 reasoningContent 不计价，结构化思考计一次', () {
    final payload = 'x' * 20000;
    final message = AgentMessage.assistant(
      text: 'ok',
      reasoningContent: payload,
      thinkingBlocks: [LlmThinkingBlock(thinking: payload, signature: 'sig')],
      contentBlocks: [
        LlmThinkingContentBlock(thinking: payload, signature: 'sig'),
        const LlmTextContentBlock(text: 'ok'),
      ],
    );
    const options = AgentWireOptions(anthropicExtras: true);
    final body = AnthropicAdapter().buildRequestBody(
      LlmRequest(
        baseUrl: 'https://stub.invalid',
        apiKey: 'unused',
        modelId: 'claude-test',
        protocol: LlmProtocol.anthropic,
        maxTokens: 1000,
        messages: [message.toRequestMap(options)],
      ),
      stream: false,
    );
    expect(jsonEncode(body).split(payload).length - 1, 1);
    final chars = surfaceInputChars([message], options: options);
    // 保留的结构化思考必须计入（正向半条）……
    expect(chars, greaterThanOrEqualTo(payload.length));
    // ……且只计一次：聚合 reasoningContent 被适配器丢弃，不得双计
    expect(
      chars,
      lessThan(payload.length + 2000),
      reason: '适配器有序块与回退重建都不读聚合 reasoningContent，'
          ' 同一思考不得双计',
    );
  });

  test('Responses：明文 reasoning 不回放不计价', () {
    final payload = 'r' * 20000;
    final message = AgentMessage.assistant(
      text: 'ok',
      reasoningContent: payload,
    );
    final body = ResponsesAdapter().buildRequestBody(
      LlmRequest(
        baseUrl: 'https://stub.invalid/v1',
        apiKey: 'unused',
        modelId: 'responses-test',
        protocol: LlmProtocol.openaiResponses,
        maxTokens: 1000,
        messages: [
          message.toRequestMap(
            AgentWireOptions.forProtocolName('openaiResponses'),
          ),
        ],
      ),
      stream: false,
    );
    expect(jsonEncode(body), isNot(contains(payload)));
    expect(
      surfaceInputChars(
        [message],
        options: AgentWireOptions.forProtocolName('openaiResponses'),
      ),
      lessThan(2000),
      reason: 'Responses 最终 input 只含正文与 function_call items，'
          ' 明文 reasoning 不计',
    );
  });

  test('OpenAI Chat：reasoning_content 确实随消息发送，计一次', () {
    final payload = 'c' * 20000;
    final message = AgentMessage.assistant(
      text: 'ok',
      reasoningContent: payload,
    );
    const options = AgentWireOptions(openaiReasoningContent: true);
    final body = OpenAiAdapter().buildRequestBody(
      LlmRequest(
        baseUrl: 'https://stub.invalid/v1',
        apiKey: 'unused',
        modelId: 'chat-test',
        maxTokens: 1000,
        messages: [message.toRequestMap(options)],
      ),
      stream: false,
    );
    expect(jsonEncode(body).split(payload).length - 1, 1);
    expect(
      surfaceInputChars([message], options: options),
      greaterThanOrEqualTo(payload.length),
      reason: 'OpenAI 兼容端点原样透传 reasoning_content，不得漏计',
    );
  });

  test('Gemini：thought Part 按最终请求计一次（签名与正文计入）', () {
    final payload = 'g' * 20000;
    // reasoningContent 是网关聚合字段；geminiNative 请求 map 不注入它
    //（openaiReasoningContent=false），适配器优先 thinkingBlocks 结构化块
    final message = AgentMessage.assistant(
      text: 'ok',
      reasoningContent: payload,
      thinkingBlocks: [LlmThinkingBlock(thinking: payload, signature: 'sig')],
    );
    final options = AgentWireOptions.forProtocolName('geminiNative');
    final body = GeminiAdapter().buildRequestBody(
      LlmRequest(
        baseUrl: 'https://stub.invalid',
        apiKey: 'unused',
        modelId: 'gemini-test',
        protocol: LlmProtocol.geminiNative,
        maxTokens: 1000,
        messages: [message.toRequestMap(options)],
      ),
      stream: false,
    );
    expect(jsonEncode(body).split(payload).length - 1, 1);
    final chars = surfaceInputChars([message], options: options);
    expect(chars, greaterThanOrEqualTo(payload.length));
    expect(chars, lessThan(payload.length + 2000));
  });

  test('anthropicBlocks 全部滤光（空 signature thinking）回退重建口径', () {
    // 适配器逐块过滤空 signature；全滤光→回退重建（同  边缘）
    final m = AgentMessage.assistant(
      text: '正文',
      contentBlocks: [
        const LlmThinkingContentBlock(thinking: '思考', signature: ''),
        const LlmTextContentBlock(text: '正文'),
      ],
    );
    const anthropic = AgentWireOptions(anthropicExtras: true);
    final rawMap = m.toRequestMap(anthropic);
    expect(rawMap['anthropicBlocks'], hasLength(2));
    final chars = messageSurfaceChars(m, anthropic);
    // 归一后丢 content 走块口径，且空 signature 块被滤掉：
    // chars < raw（content+双块），差值至少含 content 键
    expect(chars, lessThan(jsonEncode(rawMap).length));
  });

  test('anthropicBlocks 不可用（缺 tool_use 而有 tool_calls）回退重建口径', () {
    final m = AgentMessage.assistant(
      text: '正文',
      toolCalls: [
        const AgentToolCall(id: 'c1', name: 'search_story', arguments: {}),
      ],
      contentBlocks: [
        const LlmTextContentBlock(text: '正文'),
      ],
    );
    const anthropic = AgentWireOptions(anthropicExtras: true);
    // 适配器回退旧重建（thinking→text→tool_use）：估算丢块、按重建面计
    final chars = messageSurfaceChars(m, anthropic);
    final rawMap = m.toRequestMap(anthropic);
    expect(chars, lessThan(jsonEncode(rawMap).length));
    expect(chars, greaterThan(0));
  });

  test('选材/触发口径同源：固定不可压面抬高窗口估算并收窄可压区间', () {
    List<AgentDurableEvent> window() => [
          for (var t = 1; t <= 3; t++) ...[
            AgentDurableEvent(
              type: AgentEventTypes.userMessage,
              surfaceOp: AgentSurfaceOpKind.append,
              data: {'content': 'u' * 3000, 'turn': t},
            ),
            AgentDurableEvent(
              type: AgentEventTypes.assistantMessage,
              surfaceOp: AgentSurfaceOpKind.append,
              data: {'text': 'w' * 3000, 'turn': t},
            ),
          ],
        ];
    const tuning = EngineeringCompactionTuning(
      outputReserveTokens: 1000,
      headroomTokens: 500,
      retainMinTokens: 100,
      retainMaxTokens: 2000,
    );
    AgentSurfaceProjectionWithSpans fold(List<AgentDurableEvent> events) =>
        deriveAgentSurfaceSpans(events);
    // 不含固定面：窗口估算小 → 保尾少 → 可压区间宽
    final bare = selectCompactionInterval(
      windowEvents: window(),
      spans: fold(window()).spans,
      projectionMessages: fold(window()).projection.messages,
      contextWindowTokens: 32000,
      tuning: tuning,
    );
    // 含冻结前缀固定面（真实请求会发出）：窗口估算变大 → 保尾变多 →
    // 可压区间收窄（漏计会高估可压空间、过度压缩）
    final withFrozen = selectCompactionInterval(
      windowEvents: window(),
      spans: fold(window()).spans,
      projectionMessages: fold(window()).projection.messages,
      contextWindowTokens: 32000,
      tuning: tuning,
      extraFixedChars: 60000,
    );
    expect(bare, isNotNull);
    expect(withFrozen, isNotNull);
    final bareWidth = bare!.projectionEnd - bare.projectionStart;
    final frozenWidth = withFrozen!.projectionEnd - withFrozen.projectionStart;
    expect(
      frozenWidth,
      lessThan(bareWidth),
      reason: '冻结前缀计入窗口估算后保尾比例基数变大，可压区间收窄',
    );
  });

  // 压缩输出预留与「当前协议最终请求面」单源：resolveWireOutputTokens
  // 分发到各适配器自身的解析（基础钳制 + providerOptions 末位覆盖），
  // 组合逐一与真实 body 相等——预算面不再复制某一协议的基础公式。
  test('输出预算与各协议真实 body 单源（自动/钳制/回退/o 系字段名）', () {
    for (final (protocol, modelId, maxKey) in [
      (LlmProtocol.anthropic, 'm', 'max_tokens'),
      (LlmProtocol.openaiCompatible, 'm', 'max_tokens'),
      (LlmProtocol.openaiCompatible, 'o3-mini', 'max_completion_tokens'),
      (LlmProtocol.openaiResponses, 'm', 'max_output_tokens'),
    ]) {
      for (final (configured, modelMax) in [
        (0, 65536),
        (32768, 4096),
        (4096, 0),
        (0, 0),
        (1234, null),
      ]) {
        final request = LlmRequest(
          baseUrl: 'https://stub.invalid/v1',
          modelId: modelId,
          protocol: protocol,
          messages: const [
            {'role': 'user', 'content': 'p'},
          ],
          maxTokens: configured,
          modelMaxOutputTokens: modelMax,
        );
        final body = switch (protocol) {
          LlmProtocol.anthropic =>
            AnthropicAdapter().buildRequestBody(request, stream: false),
          LlmProtocol.openaiCompatible =>
            OpenAiAdapter().buildRequestBody(request, stream: false),
          LlmProtocol.openaiResponses =>
            ResponsesAdapter().buildRequestBody(request, stream: false),
          LlmProtocol.geminiNative => throw StateError('unreachable'),
        };
        // 独立期望=真实最终 body（未指定组合字段省略，两边同为 null）；
        // 不手写公式对拍（协议语义差异见下一测试的单测断言）
        expect(
          resolveWireOutputTokens(
            protocol: wireOf(protocol),
            modelId: modelId,
            baseUrl: request.baseUrl,
            configured: configured,
            modelMaxOutput: modelMax,
          ),
          body[maxKey],
          reason: 'protocol=${protocol.name} model=$modelId '
              'configured=$configured modelMax=$modelMax：预算须与真实 body 相等',
        );
      }
    }
  });

  test('API 未指定输出上限：OpenAI 系返回 null（body 省略字段），Anthropic 恒非空', () {
    expect(
      resolveWireOutputTokens(
        protocol: WireOutputProtocol.openaiCompatible,
        modelId: 'm',
        baseUrl: 'https://stub.invalid/v1',
      ),
      isNull,
      reason: 'OpenAI 兼容协议不携带输出上限时 body 也不发该字段；null'
          ' 是「API 未指定」，预算面不得冒充实报',
    );
    expect(
      OpenAiAdapter()
          .buildRequestBody(
            const LlmRequest(
              baseUrl: 'https://stub.invalid/v1',
              modelId: 'm',
              messages: [
                {'role': 'user', 'content': 'p'},
              ],
            ),
            stream: false,
          )
          .containsKey('max_tokens'),
      isFalse,
    );
    expect(
      resolveWireOutputTokens(
        protocol: WireOutputProtocol.anthropic,
        modelId: 'm',
        baseUrl: 'https://api.anthropic.com',
      ),
      isNotNull,
      reason: 'Anthropic 强制 max_tokens（兜底值即真实 wire 值）',
    );
  });

  // providerOptions.extra_body 在适配器末位展开、合法覆盖输出上限：
  // 压缩输出预留必须与「当前协议最终请求面」同源——配置 4096、模型上限
  // 65536、extra_body 指定 65536 时，真实 body 发 65536，预算若仍 4096
  // 会少预留 61440。
  for (final protocol in [
    LlmProtocol.openaiCompatible,
    LlmProtocol.openaiResponses,
  ]) {
    test(
      '${protocol.name} extra_body 覆盖后的实际输出须与预算同源',
      () {
        final key = protocol == LlmProtocol.openaiCompatible
            ? 'max_tokens'
            : 'max_output_tokens';
        final request = LlmRequest(
          baseUrl: 'https://stub.invalid/v1',
          modelId: 'synthetic-model',
          protocol: protocol,
          messages: const [
            {'role': 'user', 'content': 'synthetic probe'},
          ],
          maxTokens: 4096,
          modelMaxOutputTokens: 65536,
          providerOptions: {
            'extra_body': {key: 65536},
          },
        );
        final body = protocol == LlmProtocol.openaiCompatible
            ? OpenAiAdapter().buildRequestBody(request, stream: false)
            : ResponsesAdapter().buildRequestBody(request, stream: false);
        expect(body[key], 65536, reason: '适配器末位覆盖真实生效');
        expect(
          resolveWireOutputTokens(
            protocol: wireOf(protocol),
            modelId: request.modelId,
            baseUrl: request.baseUrl,
            configured: 4096,
            modelMaxOutput: 65536,
            providerOptions: request.providerOptions,
          ),
          body[key],
          reason: '输出预留须识别协议与 providerOptions 最终覆盖',
        );
      },
    );
  }
}
