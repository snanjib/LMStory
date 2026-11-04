/// 模型能力推断器（基于 modelId 模式匹配）
///
/// 2026-07-27 新增：解决模型 reasoning 能力标记来源过窄的问题。
///
/// **背景**：原 `_inferModelFromApi` 仅识别 OpenRouter 的
/// `pricing.internal_reasoning` 字段；DeepSeek/智谱/Qwen3/Kimi 等供应商的
/// `/models` 响应中无此字段，导致 reasoning 能力永远推断不出，
/// 用户必须手动在模型编辑对话框勾选（极不直观）。
///
/// **本类**：基于 modelId 关键词模式匹配，对主流厂商的思考模型做兜底推断。
/// 调用方应在查 preset.cachedModels.capabilities 失败后调用本类作为兜底。
///
/// **覆盖范围**（2026-07-27 主流思考模型）：
/// - Agnes 2.0 Flash（Sapiens AI，OpenAI 兼容协议 + chat_template_kwargs）
/// - OpenAI o-series（o1/o3/o4）
/// - DeepSeek R1 / V3.1+ / V4
/// - Qwen3 系列（通义千问）
/// - GLM-4.6 / GLM-4.5（智谱）
/// - Kimi K2-thinking / K3（Moonshot）
/// - Claude 3.7+ / 4.x thinking 模型
/// - Gemini 2.5+ / 3 thinking 模型
///
/// **维护**：新模型上线后，需在此处补充关键词。
class ModelCapabilityInferrer {
  ModelCapabilityInferrer._();

  /// 推断 modelId 是否支持 reasoning/thinking 能力
  ///
  /// 匹配规则：modelId 转小写后包含任一关键词即认为支持 reasoning。
  /// 关键词清单基于 2026-07-27 各厂商官方文档，详见类注释。
  static bool infersReasoning(String modelId) {
    if (modelId.isEmpty) return false;
    final id = modelId.toLowerCase();

    // Agnes 2.0 Flash（Sapiens AI，OpenAI 兼容协议，chat_template_kwargs 启用 Thinking）
    // 2026-07-27 实测：https://agnes-ai.com/zh-Hans/docs/agnes-20-flash
    // 不含 agnes-1.5-flash（旧版无 Thinking 模式）
    if (id.contains('agnes-2') || id.contains('agnes2')) return true;

    // OpenAI o-series（o1, o3, o4, o1-mini, o3-mini, o4-mini 等）
    // 注意：需精确匹配前缀，避免误伤如 "gpt-4o" 这类含 o 的模型
    if (_openAiOSeriesRegex.hasMatch(id)) return true;

    // DeepSeek R1 / V3.1+ / V4（thinking 模式）
    if (id.contains('deepseek-r1') ||
        id.contains('deepseek-v3.1') ||
        id.contains('deepseek-v3.2') ||
        id.contains('deepseek-v4') ||
        id.contains('deepseek-reasoner')) {
      return true;
    }

    // Qwen3 系列（通义千问，所有 Qwen3 模型都支持 enable_thinking）
    if (id.contains('qwen3') || id.contains('qwq')) return true;

    // 智谱 GLM-4.6 / GLM-4.5（thinking 模式）
    if (id.contains('glm-4.6') ||
        id.contains('glm-4.5') ||
        id.contains('glm-4-plus-thinking') ||
        id.contains('glm-z1')) {
      return true;
    }

    // 智谱 GLM-5 系（始终思考：5.2/5.3 走 reasoning_effort，5/5.1 走
    // thinking:{type}，参数路径见 ThinkingParamBuilder）
    if (id.contains('glm-5') || id.contains('glm5')) return true;

    // Kimi K2-thinking / K3（Moonshot）
    if (id.contains('kimi-k2-thinking') ||
        id.contains('kimi-k3') ||
        id.contains('moonshot-v1-thinking')) {
      return true;
    }

    // Claude 3.7+ / 4.x thinking 模型（通过 OpenRouter 或原生 API）
    // Claude 4 系列默认支持 extended thinking
    if (id.contains('claude-3-7') ||
        id.contains('claude-4') ||
        id.contains('claude-opus-4') ||
        id.contains('claude-sonnet-4')) {
      return true;
    }

    // Gemini 2.5+ / 3 thinking 模型
    if (id.contains('gemini-2.5') ||
        id.contains('gemini-3') ||
        id.contains('gemini-thinking')) {
      return true;
    }

    // 通用关键词兜底（部分供应商在 modelId 中显式标注）
    if (id.contains('-reasoning') ||
        id.contains('-thinking') ||
        id.contains('-reasoner') ||
        id.contains('-thinker')) {
      return true;
    }

    return false;
  }

  /// OpenAI o-series 正则：匹配 o1/o3/o4 开头 + 可选 -mini/-pro 后缀
  ///
  /// 避免 "gpt-4o" 误匹配（gpt-4o 的 o 在末尾，不在开头）。
  /// 匹配示例：o1, o1-mini, o3, o3-mini, o4, o4-mini, o4-high
  static final RegExp _openAiOSeriesRegex = RegExp(
    r'(^|[-/])o[134](-|$)',
  );
}
