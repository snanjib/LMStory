import 'dart:async';

import 'package:lmstory/core/agent/agent_events.dart';
import 'package:lmstory/core/agent/agent_runner.dart';

/// 广播事件出口（live 事件流驱动 UI； 与持久事件日志并联）
class BroadcastAgentEventSink implements AgentEventSink {
  BroadcastAgentEventSink() {
    _controller = StreamController<AgentRunEvent>.broadcast();
  }

  late final StreamController<AgentRunEvent> _controller;

  /// 事件流（broadcast，多处可同时订阅）
  Stream<AgentRunEvent> get stream => _controller.stream;

  @override
  void emit(AgentRunEvent event) {
    if (!_controller.isClosed) {
      _controller.add(event);
    }
  }

  Future<void> dispose() => _controller.close();
}

/// 缓冲事件出口（测试/一次性收集）
class BufferingAgentEventSink implements AgentEventSink {
  final List<AgentRunEvent> events = <AgentRunEvent>[];

  @override
  void emit(AgentRunEvent event) {
    events.add(event);
  }

  /// 按类型过滤（测试断言用）
  Iterable<T> of<T extends AgentRunEvent>() {
    return events.whereType<T>();
  }
}

/// 组合出口（同时广播 + 缓冲 + 持久化 sink）
class CompositeAgentEventSink implements AgentEventSink {
  CompositeAgentEventSink(this.sinks);

  final List<AgentEventSink> sinks;

  @override
  void emit(AgentRunEvent event) {
    for (final sink in sinks) {
      sink.emit(event);
    }
  }
}
