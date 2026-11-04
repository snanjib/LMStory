/// 模型类型枚举
///
/// 对标 ChatBox 的 `type` 字段，区分模型用途。
/// Simple 模式默认全部为 [chat]；Advanced 模式会用到 [embedding] 做向量嵌入。
enum ModelType {
  /// 对话模型（默认）
  chat,

  /// 嵌入式模型（向量化，Advanced 模式记忆子系统使用）
  embedding,

  /// 重排序模型（检索结果重排，Advanced 模式可选）
  rerank;

  /// 从字符串解析，未知值回退到 [chat]
  static ModelType fromString(String? value) {
    switch (value) {
      case 'chat':
        return chat;
      case 'embedding':
        return embedding;
      case 'rerank':
        return rerank;
      default:
        return chat;
    }
  }

  /// 序列化为字符串（用于 JSON 存储）
  String toJson() => name;
}

/// 模型能力枚举
///
/// 对标 ChatBox 的 `capabilities` 字段。能力与类型正交：
/// [vision]/[reasoning]/[toolUse]/[webSearch] 仅对 [ModelType.chat] 有意义。
enum ModelCapability {
  /// 支持视觉/图像输入
  vision,

  /// 支持思考/推理模式（reasoning）
  reasoning,

  /// 支持工具调用（function calling）
  toolUse,

  /// 支持网络搜索
  webSearch;

  /// 从字符串解析，未知值忽略
  static ModelCapability? fromString(String? value) {
    switch (value) {
      case 'vision':
        return vision;
      case 'reasoning':
        return reasoning;
      case 'tool_use':
      case 'toolUse':
        return toolUse;
      case 'web_search':
      case 'webSearch':
        return webSearch;
      default:
        return null;
    }
  }

  /// 序列化为字符串（对齐 ChatBox 的 snake_case 存储）
  String toJson() {
    switch (this) {
      case vision:
        return 'vision';
      case reasoning:
        return 'reasoning';
      case toolUse:
        return 'tool_use';
      case webSearch:
        return 'web_search';
    }
  }
}
