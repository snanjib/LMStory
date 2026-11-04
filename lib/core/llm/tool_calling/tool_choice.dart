/// 工具选择策略（Core 层，工具调用模块）
///
/// 对应 OpenAI API 的 `tool_choice` 参数，控制 LLM 是否/如何调用工具。
///
/// - [auto]：LLM 自行决定是否调用（默认）
/// - [required]：强制调用至少一个工具（用于必须输出结构化数据的步骤）
/// - [none]：禁止调用工具
///
/// 纯 Dart 枚举，不依赖 Flutter / Domain 业务实体。
enum ToolChoice {
  auto,
  required,
  none;

  /// 序列化为 OpenAI API `tool_choice` 字段值
  ///
  /// 返回字符串（"auto"/"required"/"none"）。
  /// 高级模式若需指定具体工具，可扩展为 sealed class 支持
  /// `{"type":"function","function":{"name":"..."}}` 形式，v0.3 再做。
  String toRequestBody() {
    return name;
  }
}
