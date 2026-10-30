import 'package:lmstory/core/llm/tool_calling/tool_choice.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';

/// 工具调用 ID 的产生方式
enum ToolCallIdStrategy {
  /// 服务端返回 id（OpenAI/Anthropic）
  serverProvided,

  /// 协议无 id 字段，本地按顺序生成（Gemini native：`gemini_<name>__<n>`）
  locallyGenerated,
}

/// 单个供应商在"工具调用 + 流式"维度的能力画像
///
/// v0.3 Agent Loop 的降级依据（设计报告 §4.3 / §7.9）：AgentRunner 不直接
/// 信任端点行为，而是按此注册表的声明决定：
/// - 是否发送 `parallel_tool_calls`
/// - 是否附加非标准参数（GLM `tool_stream`）
/// - `tool_choice` 不受支持时降级为 auto
/// - 流式工具不可靠时整轮回退非流式请求
///
///  为静态注册表雏形：按 protocol + baseUrl/modelId 指纹解析；
/// 后续可扩展为用户可覆盖（存入 ApiPreset.providerOptions）。
class ProviderToolCapabilities {
  const ProviderToolCapabilities({
    required this.supportedToolChoices,
    required this.parallelToolCalls,
    required this.requiresToolStreamFlag,
    required this.streamingToolCallsReliable,
    required this.idStrategy,
    required this.preservesThoughtSignature,
  });

  /// 端点支持的 tool_choice 取值集合
  final Set<ToolChoice> supportedToolChoices;

  /// 是否建议开启并行工具调用（parallel_tool_calls=true）
  ///
  /// false 时 Agent 侧强制串行（故事工具多为有序操作；Qwen 百炼默认关、
  /// DeepSeek 不支持，见设计报告 §4.3 容错要求）。
  final bool parallelToolCalls;

  /// 流式工具调用是否需要非标准参数（GLM 直连：`tool_stream: true`）
  final bool requiresToolStreamFlag;

  /// 流式 tool_calls 是否可靠；false 时工具步回退非流式请求
  final bool streamingToolCallsReliable;

  /// 工具调用 ID 策略
  final ToolCallIdStrategy idStrategy;

  /// 是否需要原样回传 thoughtSignature（Gemini 3 多轮质量依赖）
  final bool preservesThoughtSignature;

  /// 全能力（OpenAI 官方 / Anthropic）
  static const ProviderToolCapabilities full = ProviderToolCapabilities(
    supportedToolChoices: {
      ToolChoice.auto,
      ToolChoice.required,
      ToolChoice.none,
    },
    parallelToolCalls: true,
    requiresToolStreamFlag: false,
    streamingToolCallsReliable: true,
    idStrategy: ToolCallIdStrategy.serverProvided,
    preservesThoughtSignature: false,
  );

  /// Gemini 原生协议：无 tool call id（本地生成）、thoughtSignature 必须回传
  static const ProviderToolCapabilities gemini = ProviderToolCapabilities(
    supportedToolChoices: {
      ToolChoice.auto,
      ToolChoice.required,
      ToolChoice.none,
    },
    parallelToolCalls: false,
    requiresToolStreamFlag: false,
    streamingToolCallsReliable: true,
    idStrategy: ToolCallIdStrategy.locallyGenerated,
    preservesThoughtSignature: true,
    // 说明：无 tool call id，按顺序配对；thoughtSignature 需原样回传
  );

  /// GLM 直连（open.bigmodel.cn / glm- 模型）
  static const ProviderToolCapabilities zhipu = ProviderToolCapabilities(
    supportedToolChoices: {ToolChoice.auto, ToolChoice.none},
    parallelToolCalls: false,
    requiresToolStreamFlag: true,
    streamingToolCallsReliable: true,
    idStrategy: ToolCallIdStrategy.serverProvided,
    preservesThoughtSignature: false,
    // 说明：tool_choice 仅 auto；流式工具需 tool_stream=true
  );

  /// Qwen 百炼（dashscope）：并行默认关
  static const ProviderToolCapabilities alibaba = ProviderToolCapabilities(
    supportedToolChoices: {
      ToolChoice.auto,
      ToolChoice.required,
      ToolChoice.none,
    },
    parallelToolCalls: false,
    requiresToolStreamFlag: false,
    streamingToolCallsReliable: true,
    idStrategy: ToolCallIdStrategy.serverProvided,
    preservesThoughtSignature: false,
    // 说明：parallel_tool_calls 默认关，建议串行
  );

  /// DeepSeek：仅串行、思考模式不支持 required（DeepSeekAdapter 亦做兜底）
  static const ProviderToolCapabilities deepseek = ProviderToolCapabilities(
    supportedToolChoices: {ToolChoice.auto, ToolChoice.none},
    parallelToolCalls: false,
    requiresToolStreamFlag: false,
    streamingToolCallsReliable: true,
    idStrategy: ToolCallIdStrategy.serverProvided,
    preservesThoughtSignature: false,
    // 说明：仅串行工具调用；required 被适配器降级为 auto
  );

  /// 保守档（未知中转站/自建端点）：串行 + 流式工具不可靠
  static const ProviderToolCapabilities conservativeRelay =
      ProviderToolCapabilities(
    supportedToolChoices: {ToolChoice.auto, ToolChoice.none},
    parallelToolCalls: false,
    requiresToolStreamFlag: false,
    streamingToolCallsReliable: false,
    idStrategy: ToolCallIdStrategy.serverProvided,
    preservesThoughtSignature: false,
    // 说明：保守降级（工具步回退非流式请求）
  );

  /// SenseNova（商汤日日新，token.sensenova.cn / api.sensenova.cn）：
  /// 预览版端点，OpenAI 兼容为传输层语义（思考字段用 `reasoning` 而非
  /// `reasoning_content`），官方 6.8 Flash Lite 接入文档未承诺 tools 参数
  /// 的 schema 约束——工具步走非流式保守档，参数校验需应用层容错
  /// （见 AgentFactsDeltaInput.fromRaw）。
  static const ProviderToolCapabilities sensenova = ProviderToolCapabilities(
    supportedToolChoices: {ToolChoice.auto, ToolChoice.none},
    parallelToolCalls: false,
    requiresToolStreamFlag: false,
    streamingToolCallsReliable: false,
    idStrategy: ToolCallIdStrategy.serverProvided,
    preservesThoughtSignature: false,
    // 说明：预览版端点，工具步非流式；参数 schema 无服务端约束
  );

  /// 解析端点能力画像
  ///
  /// 优先级：协议原生（anthropic/gemini）→ baseUrl 域名/模型指纹
  /// （deepseek/zhipu/alibaba）→ 未知 openaiCompatible 端点取保守档。
  /// OpenRouter 作为中间层自行抹平差异，按 full 处理。
  static ProviderToolCapabilities resolve({
    required LlmProtocol protocol,
    required String baseUrl,
    required String modelId,
  }) {
    switch (protocol) {
      case LlmProtocol.anthropic:
        return full;
      case LlmProtocol.geminiNative:
        return gemini;
      case LlmProtocol.openaiCompatible:
      case LlmProtocol.openaiResponses:
        final lowerBase = baseUrl.toLowerCase();
        final lowerModel = modelId.toLowerCase();

        if (lowerBase.contains('open.bigmodel.cn') ||
            lowerBase.contains('bigmodel.cn') ||
            lowerModel.startsWith('glm-')) {
          return zhipu;
        }
        if (lowerBase.contains('dashscope.aliyuncs.com') ||
            lowerModel.startsWith('qwen') && !lowerModel.contains('/')) {
          return alibaba;
        }
        if (lowerBase.contains('deepseek.com') ||
            (lowerModel.startsWith('deepseek-') && !lowerModel.contains('/'))) {
          return deepseek;
        }
        if (lowerBase.contains('sensenova.cn') ||
            lowerModel.startsWith('sensenova-')) {
          return sensenova;
        }
        // 已知主流端点：OpenAI 官方 / OpenRouter（中间层已抹平）
        if (lowerBase.contains('api.openai.com') ||
            lowerBase.contains('openrouter.ai')) {
          return full;
        }
        // 其他自定义/中转站端点：保守档
        return conservativeRelay;
    }
  }

  /// 请求的 tool_choice 是否受支持；不受支持时返回降级值（auto）
  ToolChoice resolveToolChoice(ToolChoice? requested) {
    if (requested == null) return ToolChoice.auto;
    if (supportedToolChoices.contains(requested)) return requested;
    return ToolChoice.auto;
  }
}
