import 'dart:async';

/// Agent 取消异常（用户取消 / 外部中断）
class AgentCancelledException implements Exception {
  const AgentCancelledException([this.reason]);

  final String? reason;

  @override
  String toString() =>
      reason == null ? 'AgentCancelledException' : 'AgentCancelled: $reason';
}

/// Agent 取消令牌（Domain 层，纯 Dart）
///
/// 与 Core 的 `CancellationToken` 解耦：Domain 不依赖网络层；
/// Data 层网关（LlmServiceAgentGateway）负责桥接两者，
/// 使"取消 Agent 轮"能中断进行中的 HTTP 流式请求。
class AgentCancellationToken {
  Completer<void>? _completer;

  bool _cancelled = false;
  String? _reason;

  bool get isCancelled => _cancelled;

  /// 取消原因（诊断/事件展示）
  String? get reason => _reason;

  /// 取消时完成的 Future（网关桥接 HTTP 取消、UI 等待收敛）
  Future<void> get whenCancelled {
    if (_cancelled) return Future.value();
    return (_completer ??= Completer<void>()).future;
  }

  /// 触发取消（幂等；首次生效）
  void cancel([String? reason]) {
    if (_cancelled) return;
    _cancelled = true;
    _reason = reason ?? _reason;
    final completer = _completer;
    if (completer != null && !completer.isCompleted) {
      completer.complete();
    }
  }

  /// 已取消则抛出 [AgentCancelledException]
  void throwIfCancelled([String? context]) {
    if (_cancelled) {
      throw AgentCancelledException(
        context == null ? _reason : '$_reason ($context)',
      );
    }
  }
}
