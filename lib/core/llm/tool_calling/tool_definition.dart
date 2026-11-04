/// 工具定义值对象（Core 层，工具调用模块）
///
/// 描述一个可供 LLM 调用的工具（function），对应 OpenAI 兼容 API 的
/// `tools` 数组元素。由调用方（中级模式 extracting/summarizing、
/// v0.3 高级模式 Agent Loop）构造，注入 `LlmRequest.tools`。
///
/// 纯 Dart 值对象，不依赖 Flutter / Domain 业务实体，可在任意层复用。
///
/// OpenAI tools 格式：
/// ```json
/// {
///   "type": "function",
///   "function": {
///     "name": "extract_keywords",
///     "description": "...",
///     "parameters": { "type": "object", "properties": {...}, "required": [...] }
///   }
/// }
/// ```
class ToolDefinition {
  const ToolDefinition({
    required this.name,
    required this.description,
    required this.parameters,
  });

  /// 工具名称（LLM 调用时使用的标识符，需唯一）
  final String name;

  /// 工具描述（引导 LLM 何时/如何调用此工具）
  final String description;

  /// 参数 JSON Schema（OpenAI 兼容 Draft 07 子集）
  ///
  /// 形如 `{"type":"object","properties":{...},"required":[...]}`。
  final Map<String, dynamic> parameters;

  /// 序列化为 OpenAI API `tools` 数组元素
  Map<String, dynamic> toRequestBody() {
    return {
      'type': 'function',
      'function': {
        'name': name,
        'description': description,
        'parameters': parameters,
      },
    };
  }
}
