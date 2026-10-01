/// 思考预算档位枚举（core 值对象）。
///
/// 自 chat feature
/// domain/entities 下沉——core 的网关配置与网络适配层共用，不得反向
/// 依赖 feature。原位置 re-export 维持消费面零改动。
///
/// 对标 ChatBox 的 reasoning effort 配置。统一为 4 档：
/// - [disabled]：禁用思考
/// - [low]：低预算
/// - [medium]：中预算
/// - [high]：高预算
///
/// 不同模型对思考参数的支持不同（OpenAI o-series 用 `reasoning_effort`，
/// Claude 用 `thinking.budget_tokens`，DeepSeek 仅支持启用/禁用）。
/// 本枚举作为统一的用户侧档位，由请求构造层映射到各模型的具体参数。
///
/// 存储约定：
/// - chat_sessions.reasoning_effort 列存储枚举 name
///   （'disabled'/'low'/'medium'/'high'）
/// - NULL 表示使用全局默认（对标其他会话级可空设置字段）
enum ReasoningEffort {
  /// 禁用思考
  disabled,

  /// 低预算思考
  low,

  /// 中预算思考
  medium,

  /// 高预算思考
  high;

  /// 从字符串解析，未知值返回 null（保留 NULL 语义给全局默认回退）
  static ReasoningEffort? fromString(String? value) {
    switch (value) {
      case 'disabled':
        return disabled;
      case 'low':
        return low;
      case 'medium':
        return medium;
      case 'high':
        return high;
      default:
        return null;
    }
  }

  /// 序列化为字符串（用于数据库存储和 JSON 序列化）
  String toJson() => name;

  /// 是否启用思考（非 disabled 即启用）
  bool get isEnabled => this != disabled;
}
