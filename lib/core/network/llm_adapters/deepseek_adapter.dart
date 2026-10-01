import 'package:lmstory/core/llm/tool_calling/tool_choice.dart';
import 'package:lmstory/core/network/llm_adapters/openai_adapter.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// DeepSeek 协议适配器（继承 [OpenAiAdapter]，处理 DeepSeek 专属兼容性差异）
///
/// **设计动机**（2026-07-28 新增）：
/// DeepSeek 虽然使用 OpenAI 兼容协议，但存在两项与 OpenAI 标准不兼容的限制：
///   1. 不支持 `tool_choice: "required"`（思考模式下返回 400：
///      "Thinking mode does not support this tool_choice"）
///   2. 不支持 `parallel_tool_calls: true`（DeepSeek 仅支持串行调用，一次一个工具）
///
/// 把这些特化逻辑集中在 DeepSeekAdapter 中，而非散落在 OpenAiAdapter 里，
/// 避免通用适配器被供应商特化逻辑污染。其他厂商（OpenAI/Anthropic/Gemini）
/// 的兼容性差异未来也按此模式新增各自适配器。
///
/// **路由入口**：`LlmAdapterFactory.getAdapter` 在 `protocol=openaiCompatible` 时
/// 调用 [isDeepSeekEndpoint] 判定是否路由到本适配器。
///
/// **降级策略**：
///   - `tool_choice=required` → 删除字段（用默认 `auto`，配合强提示词约束保证工具被调用）
///   - `parallel_tool_calls=true` → 删除字段（走串行调用，由
///     `SummarizePhaseHandler._runSingleToolCall` 兜底补调缺失工具）
///
/// **保留能力**：
///   - `tool_choice=auto` / `tool_choice=none` → 正常发送（DeepSeek 支持）
///   - 思考参数（thinking/reasoning_effort）→ 由 ThinkingParamBuilder 正常构建
///     （DeepSeek-V3.2+ 是首个支持思考+工具调用的模型）
///
/// **参考**：https://api-docs.deepseek.com/zh-cn/guides/tool_calls
class DeepSeekAdapter extends OpenAiAdapter {
  /// 继承每流一实例的解析器工厂（XC-3，见 [OpenAiAdapter] 构造函数）。
  DeepSeekAdapter({super.sseParserFactory});

  @override
  Map<String, dynamic> buildRequestBody(
    LlmRequest request, {
    required bool stream,
  }) {
    // 1. 先由父类 OpenAiAdapter 构建标准 OpenAI 兼容请求体
    final body = super.buildRequestBody(request, stream: stream);

    // 2. DeepSeek 兼容性降级：删除不支持的字段

    // 2.1 tool_choice:"required" 降级为不传（用默认 auto）
    //     DeepSeek 思考模式下传 required 会返回 400：
    //     "Thinking mode does not support this tool_choice"
    //     其他值（auto/none）DeepSeek 支持，保留不变
    if (request.toolChoice == ToolChoice.required) {
      body.remove('tool_choice');
    }

    // 2.2 parallel_tool_calls 删除（DeepSeek 不支持，强制串行调用）
    //     串行只调用一个工具时，由调用方 _runSingleToolCall 兜底补调
    body.remove('parallel_tool_calls');

    return body;
  }

  /// DeepSeek 端点检测（用于 LlmAdapterFactory 路由判定）
  ///
  /// 判定规则（满足任一即认定为 DeepSeek 端点）：
  /// - baseUrl 含 `deepseek.com`（官方端点 api.deepseek.com / beta 端点）
  /// - modelId 以 `deepseek-` 开头且不含 `/`（排除 OpenRouter 的 `deepseek/xxx`
  ///   形式，OpenRouter 作为中间层会自行处理兼容性）
  ///
  /// 大小写不敏感判定。
  static bool isDeepSeekEndpoint(String baseUrl, String modelId) {
    final lowerBaseUrl = baseUrl.toLowerCase();
    final lowerModelId = modelId.toLowerCase();
    return lowerBaseUrl.contains('deepseek.com') ||
        (lowerModelId.startsWith('deepseek-') && !lowerModelId.contains('/'));
  }
}
