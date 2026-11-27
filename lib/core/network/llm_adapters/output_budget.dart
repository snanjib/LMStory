import 'package:lmstory/core/llm/reasoning_effort.dart';
import 'package:lmstory/core/network/llm_adapters/anthropic_compat_options.dart';
import 'package:lmstory/core/network/llm_adapters/gemini_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/openai_adapter.dart';
import 'package:lmstory/core/network/llm_adapters/responses_adapter.dart';

/// 输出预算分发的 Core 中性协议值。
///
/// 仓规（CONTRIBUTING）：新增 Core 代码不得 import features 层。协议枚举
/// 真源在 features/settings（LlmProtocol），本 Core 分发器只接受中性值，
/// 调用方在 feature 侧完成映射（见 DirectorRoundRunner）。
enum WireOutputProtocol {
  anthropic,
  openaiCompatible,
  openaiResponses,
  geminiNative,
}

/// 各协议最终请求面输出预算（wire max_tokens 单源分发）。
///
/// 解析真源在各适配器内部（各适配器 buildRequestBody 与本分发共用同一静态
/// 解析函数，不复制公式——复制规则漂移过：基础公式看不到协议差异与
/// providerOptions 末位覆盖）。返回 null = 该协议本次请求**不携带**
/// 输出上限（API 未指定，OpenAI 系/Gemini 省略字段）——预算面调用方
/// 必须区分「API 未指定」与「保守预留」，不得把 null 冒充实报或实际
/// wire 上限；Anthropic 类强制 max_tokens 的协议恒返回非空（含兜底值，
/// 兜底即真实 wire 值）。
int? resolveWireOutputTokens({
  required WireOutputProtocol protocol,
  required String modelId,
  String? baseUrl,
  int configured = 0,
  int? modelMaxOutput,
  Map<String, dynamic>? providerOptions,
  ReasoningEffort? reasoningEffort,
}) {
  switch (protocol) {
    case WireOutputProtocol.anthropic:
      // 形态判定与 max_tokens 解析与适配器同源（AnthropicCompatOptions
      // 是适配器与 400 降级器共用的唯一形态真源）
      return AnthropicCompatOptions.resolve(
        baseUrl: baseUrl ?? '',
        providerOptions: providerOptions,
        reasoningEffort: reasoningEffort,
        requestedMaxTokens: configured > 0 ? configured : null,
        modelMaxOutputTokens: modelMaxOutput,
      ).maxTokens;
    case WireOutputProtocol.openaiCompatible:
      return OpenAiAdapter.effectiveOutputTokens(
        modelId: modelId,
        configured: configured,
        modelMaxOutputTokens: modelMaxOutput,
        providerOptions: providerOptions,
      );
    case WireOutputProtocol.openaiResponses:
      return ResponsesAdapter.effectiveOutputTokens(
        configured: configured,
        modelMaxOutputTokens: modelMaxOutput,
        providerOptions: providerOptions,
      );
    case WireOutputProtocol.geminiNative:
      return GeminiAdapter.effectiveOutputTokens(
        configured: configured,
        modelMaxOutputTokens: modelMaxOutput,
      );
  }
}
