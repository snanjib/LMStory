/// 剧情节奏三档（设计文档：doc/design/v0.3.0/导演模式剧情节奏档位设计.md）。
///
/// 统一轴：本轮生成的内容允许超出用户输入的语义多远。档位改变的是
/// "语义景别"（覆盖多大一段故事时间、可替主角做多少决定），不是字数。
/// - [conservative]：只执行已声明动作 + 世界直接回应，下一步选择交还主角
/// - [balanced]：输入强暗示的直接延续可代写（默认，最接近现状）
/// - [aggressive]：允许输入之外的新进展与转折
enum NarrativePacing {
  conservative,
  balanced,
  aggressive;

  /// 配置值字符串 → 枚举（advanced.narrative_pacing 与
  /// chat_sessions.narrative_pacing 同一取值域）。
  /// 非法值抛 [FormatException]；调用方需要"损坏回退全局"语义
  /// （会话列，仿 tool_permissions 列容错）时用 [tryFromConfigValue]。
  static NarrativePacing fromConfigValue(String raw) => switch (raw) {
        'conservative' => conservative,
        'balanced' => balanced,
        'aggressive' => aggressive,
        _ => throw FormatException('narrative_pacing 非法值: $raw'),
      };

  /// 会话列语义：null/非法值 = 跟随全局（仿 sessionToolPermissions 列容错）
  static NarrativePacing? tryFromConfigValue(String? raw) => switch (raw) {
        'conservative' => conservative,
        'balanced' => balanced,
        'aggressive' => aggressive,
        _ => null,
      };

  /// 写回配置/会话列的字符串值
  String get configValue => name;
}
