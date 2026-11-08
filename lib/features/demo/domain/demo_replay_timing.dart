/// 演示播放节奏，与录制数据中的真实耗时和分片大小无关。
class DemoReplayTiming {
  const DemoReplayTiming({
    // lm-motion-exempt: 模型响应仿真等待，非界面过渡动效。
    this.requestDelay = const Duration(milliseconds: 750),
    this.textRunesPerSecond = 240,
    this.thinkingRunesPerSecond = 480,
    // 调度步长 (~40ms，约 25fps)，避免 Android/Windows 亚毫秒定时器调度损耗。
    this.tickInterval = const Duration(milliseconds: 40),
  });

  /// 机制测试可关闭仿真等待，不改变生产节奏。
  static const immediate = DemoReplayTiming(
    requestDelay: Duration.zero,
    textRunesPerSecond: 0,
    thinkingRunesPerSecond: 0,
    tickInterval: Duration.zero,
  );

  final Duration requestDelay;

  /// 正文 Unicode 码点吞吐速率（默认每秒 240 码点）。
  final int textRunesPerSecond;

  /// 思考过程 Unicode 码点吞吐速率（默认每秒 480 码点）。
  final int thinkingRunesPerSecond;

  /// 发射定时器步长。
  final Duration tickInterval;

  /// 兼容只读属性：正文码点理论等效单字间隔。
  Duration get characterInterval => textRunesPerSecond > 0
      ? Duration(microseconds: (1000000 / textRunesPerSecond).round())
      : Duration.zero;
}
