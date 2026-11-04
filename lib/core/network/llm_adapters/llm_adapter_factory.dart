import 'package:lmstory/core/network/llm_adapters/anthropic_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/deepseek_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/gemini_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/llm_protocol_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/openai_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/responses_adapter.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';

/// LLM 协议适配器工厂
///
/// 按 [LlmProtocol] + 端点信息（baseUrl + modelId）分发到对应的适配器实例。
/// LlmRemoteDataSource 持有本工厂，运行时按 `preset.protocol` + 端点信息
/// 获取适配器。
///
/// 已实现协议：
/// - [LlmProtocol.openaiCompatible] → [OpenAiAdapter] 或 [DeepSeekAdapter]
///   （DeepSeek 端点自动路由到 DeepSeekAdapter，处理 DeepSeek 专属兼容性差异）
/// - [LlmProtocol.openaiResponses] → [ResponsesAdapter]
/// - [LlmProtocol.anthropic] → [AnthropicAdapter]
/// - [LlmProtocol.geminiNative] → [GeminiAdapter]
///
/// 实现依据：DOC-12 §5.3 + §5.4.2（DeepSeek 路由）。
class LlmAdapterFactory {
  LlmAdapterFactory({
    OpenAiAdapter? openaiAdapter,
    DeepSeekAdapter? deepSeekAdapter,
    ResponsesAdapter? responsesAdapter,
    AnthropicAdapter? anthropicAdapter,
    GeminiAdapter? geminiAdapter,
  })  : _openaiAdapter = openaiAdapter ?? OpenAiAdapter(),
        _deepSeekAdapter = deepSeekAdapter ?? DeepSeekAdapter(),
        _responsesAdapter = responsesAdapter ?? ResponsesAdapter(),
        _anthropicAdapter = anthropicAdapter ?? AnthropicAdapter(),
        _geminiAdapter = geminiAdapter ?? GeminiAdapter();

  final OpenAiAdapter _openaiAdapter;
  final DeepSeekAdapter _deepSeekAdapter;
  final ResponsesAdapter _responsesAdapter;
  final AnthropicAdapter _anthropicAdapter;
  final GeminiAdapter _geminiAdapter;

  /// 按协议类型 + 端点信息获取适配器
  ///
  /// **路由规则**：
  /// - `openaiCompatible` 协议下，若 [DeepSeekAdapter.isDeepSeekEndpoint]
  ///   判定为 DeepSeek 端点，返回 [DeepSeekAdapter]（处理 DeepSeek 专属
  ///   兼容性差异：tool_choice=required 降级、跳过 parallel_tool_calls）；
  ///   否则返回 [OpenAiAdapter]
  /// - 其他协议直接返回对应适配器
  ///
  /// `openaiResponses` 返回 [ResponsesAdapter]（/responses 端点）。
  LlmProtocolAdapter getAdapter({
    required LlmProtocol protocol,
    required String baseUrl,
    required String modelId,
  }) {
    switch (protocol) {
      case LlmProtocol.openaiCompatible:
        // DeepSeek 端点路由：处理 tool_choice/parallel_tool_calls 兼容性差异
        if (DeepSeekAdapter.isDeepSeekEndpoint(baseUrl, modelId)) {
          return _deepSeekAdapter;
        }
        return _openaiAdapter;
      case LlmProtocol.anthropic:
        return _anthropicAdapter;
      case LlmProtocol.geminiNative:
        return _geminiAdapter;
      case LlmProtocol.openaiResponses:
        return _responsesAdapter;
    }
  }
}
