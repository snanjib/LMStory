import 'package:lmstory/core/agent/agent_cancellation.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/llm/llm_usage.dart'
    show LlmThinkingBlock, LlmUsage;
import 'package:lmstory/core/llm/reasoning_effort.dart';
import 'package:lmstory/core/llm/tool_calling/tool_choice.dart';
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';

/// 模型端点（由配置解析层产出，Domain 值对象）
class AgentModelEndpoint {
  const AgentModelEndpoint({
    required this.baseUrl,
    required this.modelId,
    required this.protocol,
    this.apiKey,
    this.providerOptions,
    this.maxOutputTokens,
  });

  final String baseUrl;
  final String? apiKey;
  final String modelId;

  /// 协议标识：'openaiCompatible' | 'anthropic' | 'gemini'
  /// （字符串化以避免 Domain 反向依赖 Settings 实体；与 LlmProtocol.name 对齐）
  final String protocol;

  final Map<String, dynamic>? providerOptions;
  final int? maxOutputTokens;
}

/// 单次调用配置（request 钩子可改写，但不能改 messages）
class AgentCallConfig {
  const AgentCallConfig({
    this.temperature,
    this.topP,
    this.maxTokens,
    this.presencePenalty,
    this.frequencyPenalty,
    this.reasoningEffort,
    this.toolChoice,
    this.connectTimeout,
    this.readTimeout,
  });

  final double? temperature;
  final double? topP;
  final int? maxTokens;

  /// 存在/频率惩罚（2026-08-29 审查 ：此前导演 UI 可配但从未进请求）
  final double? presencePenalty;
  final double? frequencyPenalty;

  /// 思考预算档位（2026-08-29 审查 ：null = 不发送参数，跟随模型默认）
  final ReasoningEffort? reasoningEffort;

  final ToolChoice? toolChoice;
  final Duration? connectTimeout;
  final Duration? readTimeout;

  AgentCallConfig copyWith({
    double? temperature,
    double? topP,
    int? maxTokens,
    double? presencePenalty,
    double? frequencyPenalty,
    ReasoningEffort? reasoningEffort,
    ToolChoice? toolChoice,
    Duration? connectTimeout,
    Duration? readTimeout,
  }) {
    return AgentCallConfig(
      temperature: temperature ?? this.temperature,
      topP: topP ?? this.topP,
      maxTokens: maxTokens ?? this.maxTokens,
      presencePenalty: presencePenalty ?? this.presencePenalty,
      frequencyPenalty: frequencyPenalty ?? this.frequencyPenalty,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
      toolChoice: toolChoice ?? this.toolChoice,
      connectTimeout: connectTimeout ?? this.connectTimeout,
      readTimeout: readTimeout ?? this.readTimeout,
    );
  }
}

/// 单个 step 的 LLM 请求
class AgentStepRequest {
  const AgentStepRequest({
    required this.messages,
    required this.tools,
    required this.config,
  });

  /// wire 格式消息（已含协议特有字段）
  final List<Map<String, dynamic>> messages;

  /// 工具定义（空列表 = 本步不带工具）
  final List<ToolDefinition> tools;

  final AgentCallConfig config;
}

/// 单个 step 的 LLM 响应（流式聚合结果）
class AgentStepResponse {
  const AgentStepResponse({
    required this.text,
    required this.toolCalls,
    this.reasoningContent,
    this.thinkingBlocks,
    this.usage,
    this.finishReason,
  });

  final String text;
  final List<AgentToolCall> toolCalls;

  /// DeepSeek / OpenAI 兼容思维链（多轮回传）
  final String? reasoningContent;

  /// Anthropic thinking blocks（含 signature，多轮回传）
  final List<LlmThinkingBlock>? thinkingBlocks;

  final LlmUsage? usage;

  /// 结束原因（推理型模型 `length` + 空 text = 输出预算被思维链耗尽）
  final String? finishReason;

  bool get hasToolCalls => toolCalls.isNotEmpty;
}

/// 网关归一的错误语义码
///
/// 各家 400 文案在 wire 层千差万别，但"上下文超限"是一类**可自愈**错误
/// （压缩后重试），必须与其余参数类 400（不可重试）区分开。
enum AgentLlmErrorSemantic {
  /// 上下文长度超限（prompt 超过模型上下文窗口）
  contextOverflow,
}

/// 网关异常（失败 step 关闭后由 request-error 瀑布决策重试）
class AgentLlmException implements Exception {
  const AgentLlmException(
    this.message, {
    this.code,
    this.retryable = true,
    this.semantic,
    this.statusCode,
    this.retryAfter,
  });

  final String message;
  final String? code;

  /// 网络类错误可重试；鉴权/参数类不重试。
  /// 上下文超限归一后置 true（压缩自愈的前提，见 [semantic]）。
  final bool retryable;

  /// 归一语义码；null = 未识别的常规错误
  final AgentLlmErrorSemantic? semantic;

  /// HTTP 状态码（：连接期错误从 AppHttpException 透传；null=流内/未知）
  final int? statusCode;

  /// Retry-After 冷却时长（：服务端限流指示，重试延迟优先尊重；
  /// null=无指示走本地指数退避）
  final Duration? retryAfter;

  @override
  String toString() => 'AgentLlmException: $message';
}

/// 单步 LLM 调用抽象（Domain；Data 层由 LlmServiceAgentGateway 实现）
///
/// 只管"一次请求"：消息 wire 化、能力降级、流式事件聚合、协议字段保留
/// （reasoning_content / thinkingBlocks / thoughtSignature）都在实现内。
// ignore: one_member_abstracts, 单方法抽象接口为 Clean Architecture 依赖反转所需
abstract class AgentLlmGateway {
  Future<AgentStepResponse> completeStep({
    required AgentModelEndpoint endpoint,
    required AgentStepRequest request,
    required AgentCancellationToken cancellation,
    void Function(String delta)? onTextDelta,
    void Function(String delta)? onThinkingDelta,

    /// 工具参数 JSON 增量转发（正文交付契约 §4.1：prose 参数流直播；
    /// 仅流式协议触发，非流式回退/Gemini 原子到达不产生增量）
    void Function(String toolCallId, String toolName, String delta)?
        onToolArgDelta,
  });
}
