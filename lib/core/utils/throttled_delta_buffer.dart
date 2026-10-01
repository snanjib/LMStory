import 'dart:async';

/// 流式 UI 增量合帧缓冲（从故事模式 _UiDeltaBuffer 下沉为共享工具）
///
/// 网络解析仍逐 delta 即时到达；仅把 UI 侧的消费（Riverpod state 通知 /
/// Markdown 重建 / DB 写回）按 [interval] 合帧，避免一个显示帧内重建多次。
///
/// 用法：`add` 喂增量；flush 时把合帧后的整段文本回调 [_onFlush]；
/// 流结束（成功/取消/失败）必须调 [flushAndDispose] 保证尾段不丢。
class ThrottledDeltaBuffer {
  ThrottledDeltaBuffer(this._onFlush, {this.interval = _defaultInterval});

// lm-motion-exempt: 增量节流窗口（性能红线区，文件内已具名单源）
  /// 默认合帧间隔 ≈30fps（32ms）
  static const _defaultInterval = Duration(milliseconds: 32);

  /// 合帧间隔（压缩占位写库等场景可放宽到 100ms）
  final Duration interval;

  final void Function(String coalesced) _onFlush;
  final StringBuffer _pending = StringBuffer();
  Timer? _timer;

  /// 喂入一个增量（空串忽略）。
  void add(String delta) {
    if (delta.isEmpty) return;
    _pending.write(delta);
    _timer ??= Timer(interval, _flush);
  }

  void _flush() {
    _timer = null;
    if (_pending.isEmpty) return;
    final value = _pending.toString();
    _pending.clear();
    _onFlush(value);
  }

  /// 立即冲刷待发段并停止计时（流的终点必调，尾段不丢）。
  void flushAndDispose() {
    _timer?.cancel();
    _timer = null;
    _flush();
  }
}
