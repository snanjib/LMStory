/// 消息布局模式
///
/// - [bubble]: 气泡模式 — 用户消息右对齐带主色背景，助手消息左对齐
/// - [standard]: 标准模式 — 所有消息左对齐，头像在左，内容在右
enum MessageLayoutMode {
  /// 气泡模式：用户消息右对齐带主色背景
  bubble,

  /// 标准模式：所有消息左对齐，头像在左，内容在右
  standard,
}

/// 显示偏好设置实体
///
/// 控制聊天消息的显示选项，如时间戳、模型名称、头像等。
/// 通过 SettingsRepository.setUserOverride 持久化到 SharedPreferences。
///
/// 对标 ChatBox 显示设置（6 个开关）：
/// - showModelName（默认 true）
/// - showTokenUsed（默认 true）
/// - showWordCount（默认 false）
/// - showFirstTokenLatency（默认 false）
/// - showTimestamp（默认 true）
/// - showAvatar（默认 true）
class DisplayPreferences {
  const DisplayPreferences({
    this.showTimestamp = true,
    this.showModelName = true,
    this.showAvatar = true,
    this.showTokenUsed = true,
    this.showWordCount = false,
    this.showFirstTokenLatency = false,
    this.messageLayoutMode = MessageLayoutMode.bubble,
  });

  /// 从用户覆盖配置映射创建
  factory DisplayPreferences.fromOverrides(Map<String, dynamic> overrides) {
    final layoutStr =
        overrides['display.message_layout_mode'] as String? ?? 'bubble';
    final messageLayoutMode = layoutStr == 'standard'
        ? MessageLayoutMode.standard
        : MessageLayoutMode.bubble;

    return DisplayPreferences(
      showTimestamp: overrides['display.show_timestamp'] as bool? ?? true,
      showModelName: overrides['display.show_model_name'] as bool? ?? true,
      showAvatar: overrides['display.show_avatar'] as bool? ?? true,
      showTokenUsed: overrides['display.show_token_used'] as bool? ?? true,
      showWordCount: overrides['display.show_word_count'] as bool? ?? false,
      showFirstTokenLatency:
          overrides['display.show_first_token_latency'] as bool? ?? false,
      messageLayoutMode: messageLayoutMode,
    );
  }

  /// 是否显示消息时间戳
  final bool showTimestamp;

  /// 是否显示助手消息的模型名称
  final bool showModelName;

  /// 是否显示消息头像
  final bool showAvatar;

  /// 是否显示 Tokens 使用量（仅助手消息）
  final bool showTokenUsed;

  /// 是否显示字符统计（仅助手消息）
  final bool showWordCount;

  /// 是否显示首字延迟（仅助手消息，单位毫秒）
  final bool showFirstTokenLatency;

  /// 消息布局模式
  final MessageLayoutMode messageLayoutMode;

  DisplayPreferences copyWith({
    bool? showTimestamp,
    bool? showModelName,
    bool? showAvatar,
    bool? showTokenUsed,
    bool? showWordCount,
    bool? showFirstTokenLatency,
    MessageLayoutMode? messageLayoutMode,
  }) {
    return DisplayPreferences(
      showTimestamp: showTimestamp ?? this.showTimestamp,
      showModelName: showModelName ?? this.showModelName,
      showAvatar: showAvatar ?? this.showAvatar,
      showTokenUsed: showTokenUsed ?? this.showTokenUsed,
      showWordCount: showWordCount ?? this.showWordCount,
      showFirstTokenLatency:
          showFirstTokenLatency ?? this.showFirstTokenLatency,
      messageLayoutMode: messageLayoutMode ?? this.messageLayoutMode,
    );
  }
}
