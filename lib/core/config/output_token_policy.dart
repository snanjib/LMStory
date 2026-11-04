/// 统一管理输出 token 配置的语义。
///
/// 用户配置中的 `0` 表示“不设置应用层输出上限”，不能直接透传给供应商。
/// 同时，故事模式仍需要为上下文组装预留输出空间，因此 API 上限与预算预留
/// 必须分别计算。
abstract final class OutputTokenPolicy {
  /// 故事模式新会话的默认输出上限。
  static const int storyDefaultLimit = 8192;

  /// 用户配置中的“不设置应用层上限”哨兵值。
  static const int unlimited = 0;

  /// 配置为 [unlimited] 时，仅供内部上下文预算使用的输出预留。
  ///
  /// 该值不会作为 API 输出上限发送。
  static const int unlimitedContextReserve = 8192;

  /// 关键词提取阶段的保护性输出上限。
  static const int extractingLimit = 2048;

  /// 事件/事实摘要阶段的保护性输出上限。
  static const int summarizingLimit = 4096;

  /// 对话压缩阶段的保护性输出上限。
  static const int compactionLimit = 8192;

  /// 将正数上限约束到模型已知的最大输出能力。
  ///
  /// `null` 和非正数保留原值，由具体协议决定省略或适配。
  static int? clampToModel(int? configured, int? modelMaxOutput) {
    if (configured == null || configured <= 0) return configured;
    if (modelMaxOutput == null || modelMaxOutput <= 0) return configured;
    return configured < modelMaxOutput ? configured : modelMaxOutput;
  }

  /// 计算故事模式上下文组装使用的输出预留。
  ///
  /// 配置为 0 时使用固定 8192 预留，避免把整个模型窗口都塞给输入；正数时
  /// 使用配置值，并在模型最大输出已知时取较小值。
  static int contextReserve({
    required int configured,
    int? modelMaxOutput,
  }) {
    final requested = configured > 0 ? configured : unlimitedContextReserve;
    return clampToModel(requested, modelMaxOutput) ?? unlimitedContextReserve;
  }
}
