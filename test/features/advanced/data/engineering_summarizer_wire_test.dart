import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';
import 'package:lmstory/features/advanced/data/engineering_summarizer.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart'
    show NamingConfig;
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// wire 链验收：生产摘要器请求与主对话共享 tools（共享前部式
/// system+tools+区间），响应 usage/finishReason 进输出（成败都落痕的
/// 上游）。桩网关捕获请求、回放固定响应。
void main() {
  test('摘要请求携带 tools（与主请求同源）；响应 usage/finishReason 进输出', () async {
    LlmRequest? captured;
    final summarizer = LlmEngineeringSummarizer(
      llmService: _CapturingLlmService((r) => captured = r),
      namingConfig: const NamingConfig(
        baseUrl: 'http://stub.local',
        apiKey: 'k',
        modelId: 'm1',
        providerOptions: {},
      ),
      frozenPrefix: '【冻结前缀】',
    );
    const tools = [
      ToolDefinition(name: 'probe', description: 'd', parameters: {}),
    ];
    final output = await summarizer.summarize(
      sessionId: 's1',
      intervalMessages: [
        AgentMessage.user('u1'),
        AgentMessage.assistant(text: 'a1'),
      ],
      narrativeBoundaryTurn: 1,
      tools: tools,
      onDelta: null,
    );
    // 请求面：tools 与传入同源；system=冻结前缀；指令为最后一条 user
    expect(captured, isNotNull);
    expect(captured!.tools, tools);
    expect(captured!.messages.first['role'], 'system');
    expect(captured!.messages.first['content'], '【冻结前缀】');
    expect(captured!.messages.last['role'], 'user');
    // 响应面：usage/finishReason 进输出（成功路径落痕的上游）
    expect(output.usage, {
      'inputTokens': 100,
      'promptTokens': 100,
      'completionTokens': 7,
      'totalTokens': 107,
      'finishReason': 'stop',
    });
    expect(output.summary, contains('【已完成剧情梗概】'));
  });

  test('截断响应携带 usage 抛异常（失败路径落痕的上游）', () async {
    final summarizer = LlmEngineeringSummarizer(
      llmService: _CapturingLlmService(
        null,
        response: const LlmResponse(
          content: '半截',
          finishReason: 'length',
          usage: LlmUsage(
            promptTokens: 50,
            completionTokens: 20,
            totalTokens: 70,
          ),
        ),
      ),
      namingConfig: const NamingConfig(
        baseUrl: 'http://stub.local',
        apiKey: 'k',
        modelId: 'm1',
        providerOptions: {},
      ),
      frozenPrefix: '',
    );
    expect(
      () => summarizer.summarize(
        sessionId: 's1',
        intervalMessages: const [],
        narrativeBoundaryTurn: 0,
        tools: const [],
        onDelta: null,
      ),
      throwsA(
        isA<EngineeringSummaryException>()
            .having((e) => e.reason, 'reason', 'summary-response-truncated')
            .having((e) => e.usage, 'usage', {
          'inputTokens': 50,
          'promptTokens': 50,
          'completionTokens': 20,
          'totalTokens': 70,
          'finishReason': 'length',
        }),
      ),
    );
  });
}

class _CapturingLlmService implements LlmService {
  _CapturingLlmService(this.onRequest, {this.response});

  final void Function(LlmRequest request)? onRequest;
  final LlmResponse? response;

  @override
  Future<LlmResponse> chat(LlmRequest request) async {
    onRequest?.call(request);
    return response ??
        const LlmResponse(
          content: '【已完成剧情梗概】第一轮。\n【世界状态演变】无。',
          finishReason: 'stop',
          usage: LlmUsage(
            promptTokens: 100,
            completionTokens: 7,
            totalTokens: 107,
            totalInputTokens: 100,
          ),
        );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
