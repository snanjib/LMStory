/// 网络配置
class NetworkConfig {
  const NetworkConfig({
    this.connectTimeoutMs = 15000,
    this.receiveTimeoutMs = 30000,
    this.directorResponseStartTimeoutMs = 600000,
    this.directorNonStreamingTimeoutMs = 600000,
    this.autoRetryMaxAttempts = 5,
    this.autoRetryWaitBudgetMs = 90000,
  });

  factory NetworkConfig.fromJson(Map<String, dynamic> json) => NetworkConfig(
        connectTimeoutMs: json['connect_timeout_ms'] as int? ?? 15000,
        receiveTimeoutMs: json['receive_timeout_ms'] as int? ?? 30000,
        directorResponseStartTimeoutMs:
            json['director_response_start_timeout_ms'] as int? ?? 600000,
        directorNonStreamingTimeoutMs:
            json['director_non_streaming_timeout_ms'] as int? ?? 600000,
        autoRetryMaxAttempts: json['auto_retry_max_attempts'] as int? ?? 5,
        autoRetryWaitBudgetMs:
            json['auto_retry_wait_budget_ms'] as int? ?? 90000,
      );

  final int connectTimeoutMs;
  final int receiveTimeoutMs;
  final int directorResponseStartTimeoutMs;
  final int directorNonStreamingTimeoutMs;

  /// 自动重试次数上限（2026-10-15 批 E / P5：三模式共享底座默认 5，
  /// 可见性 advanced；simple 用户无感享受默认，导演/故事各有覆盖项）
  final int autoRetryMaxAttempts;

  /// 自动重试累计纯等待预算毫秒（P6：0 = 不限；防 5 连长冷却纯等）
  final int autoRetryWaitBudgetMs;

  Duration get connectTimeout => Duration(milliseconds: connectTimeoutMs);
  Duration get receiveTimeout => Duration(milliseconds: receiveTimeoutMs);

  /// 预算的 Duration 形态（0 → null = 不限）
  Duration? get autoRetryWaitBudget => autoRetryWaitBudgetMs <= 0
      ? null
      : Duration(milliseconds: autoRetryWaitBudgetMs);
}
