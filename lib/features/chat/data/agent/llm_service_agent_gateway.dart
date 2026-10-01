import 'dart:async';

import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_llm_gateway.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/llm/context_overflow.dart';
import 'package:lmstory/core/llm/tool_calling/provider_tool_capabilities.dart';
import 'package:lmstory/core/llm/tool_calling/tool_call.dart';
import 'package:lmstory/core/network/http_client.dart' show CancellationToken;
import 'package:lmstory/core/network/retry_after.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';

/// LlmService → AgentLlmGateway 桥接（Data 层）
///
/// 职责（设计报告 §7.2 llm 层 + §7.9 协议抹平）：
/// - 按 [ProviderToolCapabilities] 做能力降级：
///   tool_choice 不受支持 → auto；GLM 直连注入 `tool_stream: true`；
///   并行工具按端点画像开/关；流式工具不可靠 → 回退非流式请求。
/// - 流式事件聚合为 [AgentStepResponse]：文本/思维链/thinking blocks/
///   多工具调用（含 Gemini thoughtSignature），保留全部多轮回传字段。
/// - Agent 取消令牌桥接 HTTP CancellationToken（中断进行中的流式请求）。
class LlmServiceAgentGateway implements AgentLlmGateway {
  LlmServiceAgentGateway({required LlmService llmService})
      : _llmService = llmService;

  final LlmService _llmService;

  ///  请求级轨迹：logPayloads 开启时记录每步完整请求/响应负载
  /// （与故事模式 stream_runner 同款通道与做法，2000 字符预览）
  static const Logger _payloadLogger = Logger('AgentStep');

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
    // 已取消的轮不再发出请求（runner 在 step 边界也检查，此为防御短路）
    cancellation.throwIfCancelled('LLM 请求前');

    final protocol = _parseProtocol(endpoint.protocol);
    final capabilities = ProviderToolCapabilities.resolve(
      protocol: protocol,
      baseUrl: endpoint.baseUrl,
      modelId: endpoint.modelId,
    );

    final toolChoice =
        capabilities.resolveToolChoice(request.config.toolChoice);
    final providerOptions = <String, dynamic>{
      ...?endpoint.providerOptions,
      // 并行工具开关（OpenAiAdapter 识别；DeepSeek 适配器自行移除）
      if (protocol == LlmProtocol.openaiCompatible)
        'parallel_tool_calls': capabilities.parallelToolCalls,
      // GLM 直连流式工具必需的非标准参数（经 extra_body 进入请求体）
      if (capabilities.requiresToolStreamFlag)
        'extra_body': {'tool_stream': true},
    };

    final baseRequest = LlmRequest(
      baseUrl: endpoint.baseUrl,
      apiKey: endpoint.apiKey,
      modelId: endpoint.modelId,
      messages: request.messages,
      temperature: request.config.temperature,
      topP: request.config.topP,
      maxTokens: request.config.maxTokens,
      presencePenalty: request.config.presencePenalty,
      frequencyPenalty: request.config.frequencyPenalty,
      reasoningEffort: request.config.reasoningEffort,
      modelMaxOutputTokens: endpoint.maxOutputTokens,
      includeUsage: true,
      stream: request.tools.isEmpty || capabilities.streamingToolCallsReliable,
      tools: request.tools.isEmpty ? null : request.tools,
      toolChoice: request.tools.isEmpty ? null : toolChoice,
      protocol: protocol,
      providerOptions: providerOptions,
      connectTimeout: request.config.connectTimeout,
      readTimeout: request.config.readTimeout,
    );

    _logRequestPayload(endpoint.modelId, request);

    // 取消桥接：Agent 令牌 → HTTP 令牌（请求完成后回调再触发也无害）
    final httpCancelToken = CancellationToken();
    if (cancellation.isCancelled) {
      httpCancelToken.cancel();
    } else {
      unawaited(
        cancellation.whenCancelled.then((_) {
          httpCancelToken.cancel();
        }),
      );
    }

    try {
      // 流式工具不可靠的端点（未知中转站）→ 工具步回退非流式请求
      if (request.tools.isNotEmpty &&
          !capabilities.streamingToolCallsReliable) {
        return await _completeNonStreaming(baseRequest);
      }
      return await _completeStreaming(
        baseRequest.copyWith(cancelToken: httpCancelToken),
        onTextDelta: onTextDelta,
        onThinkingDelta: onThinkingDelta,
        onToolArgDelta: onToolArgDelta,
      );
    } finally {
      // 无需清理：取消桥接的 future 回调幂等
    }
  }

  Future<AgentStepResponse> _completeStreaming(
    LlmRequest request, {
    void Function(String delta)? onTextDelta,
    void Function(String delta)? onThinkingDelta,
    void Function(String toolCallId, String toolName, String delta)?
        onToolArgDelta,
  }) async {
    final textBuffer = StringBuffer();
    final thinkingBuffer = StringBuffer();
    final thinkingBlocks = <LlmThinkingBlock>[];
    final toolCalls = <AgentToolCall>[];
    final toolNamesById = <String, String>{};
    LlmUsage? usage;
    String? finishReason;
    AgentLlmException? streamError;
    var hasError = false;

    final completer = Completer<void>();
    late final StreamSubscription<LlmStreamEvent> subscription;
    subscription = _llmService.streamChat(request).listen(
      (event) {
        switch (event) {
          case LlmTextDelta(:final content):
            if (content.isNotEmpty) {
              textBuffer.write(content);
              onTextDelta?.call(content);
            }
          case LlmThinkingDelta(:final content):
            if (content.isNotEmpty) {
              thinkingBuffer.write(content);
              onThinkingDelta?.call(content);
            }
          case LlmThinkingBlockComplete(:final thinking, :final signature):
            thinkingBlocks.add(
              LlmThinkingBlock(thinking: thinking, signature: signature),
            );
          case LlmToolCallComplete(
              :final toolCallId,
              :final name,
              :final arguments,
              :final thoughtSignature,
            ):
            toolCalls.add(
              AgentToolCall(
                id: toolCallId,
                name: name,
                arguments: arguments,
                thoughtSignature: thoughtSignature,
              ),
            );
          case LlmStreamDone():
            usage = event.usage;
            finishReason = event.finishReason;
            if (!completer.isCompleted) completer.complete();
          case LlmStreamError(:final message, :final code, :final retryAfter):
            hasError = true;
            streamError = _normalizeStreamError(
              message,
              code,
              retryAfter: retryAfter,
            );
            if (!completer.isCompleted) completer.complete();
          case LlmToolCallStart(:final toolCallId, :final name):
            // Args 增量不带工具名，从 Start 事件登记（契约 §4.1 转发用）
            toolNamesById[toolCallId] = name;
          case LlmToolCallArgs(:final toolCallId, :final argsDelta):
            // 参数增量转发（正文交付契约 §4.1：此前丢弃，现交提取器直播）
            if (argsDelta.isNotEmpty) {
              onToolArgDelta?.call(
                toolCallId,
                toolNamesById[toolCallId] ?? '',
                argsDelta,
              );
            }
        }
      },
      onError: (Object e, StackTrace st) {
        hasError = true;
        streamError = _wrapTransportError(e);
        if (!completer.isCompleted) completer.complete();
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
    );

    try {
      await completer.future;
    } finally {
      await subscription.cancel();
    }

    if (hasError) {
      throw streamError ?? const AgentLlmException('未知流错误');
    }

    _logResponsePayload(
      text: textBuffer.toString(),
      toolCallNames: toolCalls.map((c) => c.name).toList(),
      usage: usage,
      finishReason: finishReason,
    );

    return AgentStepResponse(
      text: textBuffer.toString(),
      toolCalls: toolCalls,
      reasoningContent:
          thinkingBuffer.isEmpty ? null : thinkingBuffer.toString(),
      thinkingBlocks: thinkingBlocks.isEmpty ? null : thinkingBlocks,
      usage: usage,
      finishReason: finishReason,
    );
  }

  Future<AgentStepResponse> _completeNonStreaming(
    LlmRequest baseRequest,
  ) async {
    // 非流式端点无法用流取消令牌中断，靠 readTimeout 兜底
    final request = LlmRequest(
      baseUrl: baseRequest.baseUrl,
      apiKey: baseRequest.apiKey,
      modelId: baseRequest.modelId,
      messages: baseRequest.messages,
      temperature: baseRequest.temperature,
      topP: baseRequest.topP,
      maxTokens: baseRequest.maxTokens,
      presencePenalty: baseRequest.presencePenalty,
      frequencyPenalty: baseRequest.frequencyPenalty,
      reasoningEffort: baseRequest.reasoningEffort,
      modelMaxOutputTokens: baseRequest.modelMaxOutputTokens,
      includeUsage: true,
      stream: false,
      tools: baseRequest.tools,
      toolChoice: baseRequest.toolChoice,
      protocol: baseRequest.protocol,
      providerOptions: baseRequest.providerOptions,
      connectTimeout: baseRequest.connectTimeout,
      readTimeout: baseRequest.readTimeout,
    );
    final LlmResponse response;
    try {
      response = await _llmService.chat(request);
    } on AppHttpException catch (e) {
      throw _wrapTransportError(e);
    } catch (e) {
      // 非流式回退路径的未知异常同样包装为网关异常（runner 统一重试决策），
      // 并走 overflow 归一（中转站 400 多在此路径抛出）
      throw _normalizeError('非流式请求失败：$e', fallbackRetryable: true);
    }

    _logResponsePayload(
      text: response.content,
      toolCallNames: (response.toolCalls ?? const <ToolCall>[])
          .map((tc) => tc.name)
          .toList(),
      usage: response.usage,
      finishReason: response.finishReason,
    );

    return AgentStepResponse(
      text: response.content,
      toolCalls: (response.toolCalls ?? const <ToolCall>[])
          .map(
            (tc) => AgentToolCall(
              id: tc.id,
              name: tc.name,
              arguments: tc.arguments,
              thoughtSignature: tc.thoughtSignature,
            ),
          )
          .toList(),
      reasoningContent: response.reasoningContent,
      thinkingBlocks: response.thinkingBlocks,
      usage: response.usage,
      finishReason: response.finishReason,
    );
  }

  void _logRequestPayload(String modelId, AgentStepRequest request) {
    if (!Logger.debugOptions.logPayloads) return;
    _payloadLogger.info(
      '[AgentStep] request started',
      detail: 'model=$modelId, '
          'messageCount=${request.messages.length}, '
          'toolCount=${request.tools.length}',
    );
    for (var i = 0; i < request.messages.length; i++) {
      final msg = request.messages[i];
      final content = msg['content']?.toString() ?? '';
      final preview = content.length > 2000
          ? '${content.substring(0, 2000)}...[truncated ${content.length - 2000} chars]'
          : content;
      _payloadLogger.info(
        '[AgentStep] request message[$i]',
        // ignore: missing_whitespace_between_adjacent_strings, 中文日志换行拼接
        detail: 'role=${msg['role']}, len=${content.length}\n$preview',
      );
    }
  }

  void _logResponsePayload({
    required String text,
    required List<String> toolCallNames,
    LlmUsage? usage,
    String? finishReason,
  }) {
    if (!Logger.debugOptions.logPayloads) return;
    final preview = text.length > 2000
        ? '${text.substring(0, 2000)}...[truncated ${text.length - 2000} chars]'
        : text;
    _payloadLogger.info(
      '[AgentStep] response completed',
      detail: 'textLen=${text.length}, '
          'toolCalls=${toolCallNames.isEmpty ? '-' : toolCallNames.join('、')}, '
          'usage=${usage == null ? '-' : '${usage.promptTokens}/${usage.completionTokens}'}'
          '${finishReason == null ? '' : ', finishReason=$finishReason'}\n$preview',
    );
  }

  LlmProtocol _parseProtocol(String name) {
    return LlmProtocol.values.firstWhere(
      (p) => p.name == name,
      orElse: () => LlmProtocol.openaiCompatible,
    );
  }

  AgentLlmException _wrapTransportError(Object e) {
    if (e is AgentCancelledException) return const AgentLlmException('已取消');
    if (e is AppHttpException) {
      final status = e.statusCode;
      final retryable = status == null || status >= 500 || status == 429;
      // 状态码与 Retry-After 结构化透传（重试延迟尊重服务端冷却指示）。
      // 审查收官 ：message 并入 responseBody——非流式路径的 message
      // 是「Chat request failed with status 400」类通用文案，超限详情
      //（含中文中转变体）全在 body；不带 body 时  溢出自愈对非流式
      // 400 永不触发（与故事分类器 failure_classifier 同口径）
      return _normalizeError(
        '${e.message}${e.responseBody ?? ''}',
        code: status?.toString(),
        fallbackRetryable: retryable,
        statusCode: status,
        retryAfter: parseRetryAfter(headers: e.headers),
      );
    }
    if (e is TimeoutException) {
      return const AgentLlmException('请求超时', code: 'timeout');
    }
    return _normalizeError(e.toString(), fallbackRetryable: true);
  }

  /// 流内错误归一（：overflow 识别优先于状态码分类；
  /// 流内 LlmStreamError 携带的语义码与 Retry-After 一并归一）
  AgentLlmException _normalizeStreamError(
    String message,
    String? code, {
    Duration? retryAfter,
  }) {
    return _normalizeError(
      message,
      code: code,
      fallbackRetryable: _isRetryableCode(code),
      retryAfter: retryAfter,
    );
  }

  /// 各家 context-length 类 400 文案归一为 CONTEXT_OVERFLOW 语义码并置
  /// retryable（差距剖析 ：此前 400 一律不可重试直接停轮）。
  AgentLlmException _normalizeError(
    String message, {
    required bool fallbackRetryable,
    String? code,
    int? statusCode,
    Duration? retryAfter,
  }) {
    final isOverflow = _isContextOverflow(message, code);
    return AgentLlmException(
      message,
      code: code,
      retryable: isOverflow || fallbackRetryable,
      semantic: isOverflow ? AgentLlmErrorSemantic.contextOverflow : null,
      statusCode: statusCode,
      retryAfter: retryAfter,
    );
  }

  /// 上下文超限文案识别（：口径提取至 core/llm/context_overflow.dart，
  /// 与故事路失败分类器共享同一份模式表）
  static bool _isContextOverflow(String message, String? code) =>
      isContextOverflowText(message, code);

  bool _isRetryableCode(String? code) {
    if (code == null) return true;
    switch (code) {
      case 'STREAM_ERROR':
      case 'timeout':
      //  语义码：限流（尊重 retryAfter 冷却）与服务端错误可重试
      case 'RATE_LIMIT':
      case 'SERVER':
      case '429':
      case '500':
      case '502':
      case '503':
      case '504':
        return true;
      //  语义码：鉴权失败/参数类 400 重发必然再败，不重试
      case 'AUTH':
      case 'BAD_REQUEST':
        return false;
      default:
        // 4xx 参数/鉴权类不重试
        final asInt = int.tryParse(code);
        return asInt == null || asInt >= 500;
    }
  }
}
