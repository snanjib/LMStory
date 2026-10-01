import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// LLM 供应商 JSON 输出能力探测（新增）
///
/// 根据供应商 `baseUrl` 判断其对 OpenAI `response_format` 的支持级别，
/// 用于 IntermediateChatController 选择最优的 JSON 输出策略：
///
/// - `JsonSupportLevel.jsonSchemaStrict`：支持 `response_format: {type: 'json_schema', strict: true}`，
///   100% 保证字段结构合规（OpenAI 官方 API）。优先使用此模式。
/// - `JsonSupportLevel.jsonObject`：仅支持 `response_format: {type: 'json_object'}`，
///   保证返回合法 JSON 但不保证字段结构（DeepSeek、OpenRouter 等）。
///   需配合 JsonSchemaValidator 客户端验证 + 智能修复。
/// - `JsonSupportLevel.none`：不支持 response_format，纯提示词约束 + 解析容错。
///
/// **探测策略**：基于 `baseUrl` 域名匹配，保守判定。
/// - OpenAI 官方域名 → jsonSchemaStrict
/// - DeepSeek / OpenRouter 已知支持 json_object → jsonObject
/// - 其他（含本地部署、自建镜像）→ none，避免误判导致请求被拒
///
/// **设计权衡**：未做运行时探测（发测试请求），因为：
/// 1. 增加首次请求延迟
/// 2. 部分供应商测试请求与正式请求行为不一致
/// 3. 用户可手动通过 default_config.json 的 `stream.inject_response_format` 关闭注入
///
/// 关联设计：DOC-09B §8.6（JSON 兜底）` §3.1
class LlmCapabilities {
  const LlmCapabilities._();

  /// 根据 `baseUrl` 判断 JSON 输出支持级别
  ///
  /// `baseUrl` 为空或无法识别时返回 `JsonSupportLevel.none`，
  /// 调用方应回退到纯提示词模式。
  static JsonSupportLevel detectJsonSupport({required String baseUrl}) {
    final lower = baseUrl.toLowerCase();
    // OpenAI 官方域名（含 api.openai.com 与 cdn 镜像）
    if (lower.contains('api.openai.com') ||
        lower.contains('openai.azure.com')) {
      return JsonSupportLevel.jsonSchemaStrict;
    }
    // DeepSeek 官方域名
    if (lower.contains('deepseek.com')) {
      return JsonSupportLevel.jsonObject;
    }
    // OpenRouter 聚合平台
    if (lower.contains('openrouter.ai')) {
      return JsonSupportLevel.jsonObject;
    }
    // 其他（本地部署、自建镜像、未知供应商）保守判定为不支持
    return JsonSupportLevel.none;
  }

  /// 根据能力级别构建 [LlmResponseFormat]
  ///
  /// 返回 null 表示该能力级别不应注入 response_format（调用方走纯提示词路径）。
  static LlmResponseFormat? buildResponseFormat({
    required JsonSupportLevel level,
    Map<String, dynamic>? schema,
    String schemaName = 'intermediate_response',
  }) {
    return switch (level) {
      JsonSupportLevel.jsonSchemaStrict => schema != null
          ? LlmResponseFormatJsonSchema(
              name: schemaName,
              schema: schema,
            )
          : const LlmResponseFormatJsonObject(),
      JsonSupportLevel.jsonObject => const LlmResponseFormatJsonObject(),
      JsonSupportLevel.none => null,
    };
  }

  /// 根据 `baseUrl` 判断工具调用（Tool Calling）支持级别
  ///
  /// 用于中级模式四步生成的 extracting/summarizing 步骤选择结构化输出策略：
  /// 支持工具调用时优先使用 `tools` + `tool_choice=required`，比 JSON mode
  /// 对国产模型覆盖更广且为 v0.3 Agent Loop 预置。
  ///
  /// **探测策略**：基于 `baseUrl` 域名匹配，保守判定。
  /// - OpenAI 官方 / DeepSeek / OpenRouter → standard（已知支持 tools 参数）
  /// - 其他（本地部署、自建镜像、未知供应商）→ none，首次请求实测降级
  ///
  /// `none` 不代表一定不支持——调用方应先尝试工具调用，若服务端返回明确
  /// "不支持 tools 参数"错误（HTTP 400 + 特定错误码），则 100% 确定不支持，
  /// 弹窗提示用户并降级为 JSON 模式（见 StreamRunner 降级链）。
  static ToolCallingLevel detectToolCallingSupport({required String baseUrl}) {
    final lower = baseUrl.toLowerCase();
    // OpenAI 官方域名（含 Azure OpenAI）
    if (lower.contains('api.openai.com') ||
        lower.contains('openai.azure.com')) {
      return ToolCallingLevel.standard;
    }
    // DeepSeek 官方域名（支持 function calling）
    if (lower.contains('deepseek.com')) {
      return ToolCallingLevel.standard;
    }
    // OpenRouter 聚合平台（透传底层模型的工具调用能力）
    if (lower.contains('openrouter.ai')) {
      return ToolCallingLevel.standard;
    }
    // 其他（本地部署、自建镜像、未知供应商）保守判定为不支持
    // 实际可能支持，由首次请求实测降级
    return ToolCallingLevel.none;
  }
}

/// JSON 输出能力级别
enum JsonSupportLevel {
  /// 不支持 response_format（纯提示词约束）
  none,

  /// 支持 response_format: {type: 'json_object'}（DeepSeek/OpenRouter）
  jsonObject,

  /// 支持 response_format: {type: 'json_schema', strict: true}（OpenAI 官方）
  jsonSchemaStrict,
}

/// 工具调用（Tool Calling）能力级别
///
/// 用于中级模式四步生成结构化输出步骤（extracting/summarizing）的策略选择。
enum ToolCallingLevel {
  /// 不支持或未知（本地部署、自建镜像、未知供应商）
  ///
  /// 调用方应先尝试工具调用，首次请求实测降级：
  /// 服务端返回明确"不支持 tools 参数"错误 → 弹窗提示 + 降级为 JSON 模式。
  none,

  /// 支持标准 OpenAI 兼容 tools 参数（OpenAI/DeepSeek/OpenRouter）
  standard,
}
