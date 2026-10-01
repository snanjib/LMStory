// HTTP 客户端共享类型定义
//
// 将 CancellationToken 和 CancelledException 独立出来，
// 供 http_client.dart（条件导入入口）和 stream_post_native/web.dart
// （平台实现）共同使用，避免循环导入和重复定义。

/// 取消令牌，用于取消正在进行的 SSE 请求
class CancellationToken {
  bool _isCancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _isCancelled;

  /// 取消请求
  void cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    for (final listener in _listeners) {
      listener();
    }
    _listeners.clear();
  }

  /// 绑定取消回调（由 HttpClient 内部调用）
  ///
  /// 公开方法（非下划线前缀），因为需要在 stream_post_native.dart
  /// 和 stream_post_web.dart 中跨文件调用。
  void bind(void Function() onCancel) {
    if (_isCancelled) {
      onCancel();
    } else {
      _listeners.add(onCancel);
    }
  }
}

/// 请求被取消异常
class CancelledException implements Exception {
  const CancelledException(this.message);

  final String message;

  @override
  String toString() => 'CancelledException: $message';
}
