import 'dart:convert';

import 'package:lmstory/core/agent/agent_message.dart';

/// doom-loop 检测器（opencode 同款，设计报告 §6.3）
///
/// 连续 [threshold] 次同工具同参调用 → 判定循环。任何一个"不同"的调用
/// （不同工具或不同参数）都会重置连续计数。
class DoomLoopDetector {
  /// 默认阈值 3→8——阈值前 3/5 次同参连调先注入递进提醒
  /// （触发点见 agent_runner _repeatReminderStreaks）
  DoomLoopDetector({this.threshold = 8});

  final int threshold;

  String? _lastKey;
  int _streak = 0;

  /// 登记一次调用；返回 true 表示 doom-loop 触发（本次调用不再执行）
  bool register(AgentToolCall call) {
    final key = _canonicalKey(call);
    if (key == _lastKey) {
      _streak++;
    } else {
      _lastKey = key;
      _streak = 1;
    }
    return _streak >= threshold;
  }

  /// 当前连续同参调用次数（触发后不清零，供事件展示）
  int get currentStreak => _streak;

  /// 最近一次登记的工具名
  String? get lastToolName {
    final key = _lastKey;
    if (key == null) return null;
    return key.split('|').first;
  }

  void reset() {
    _lastKey = null;
    _streak = 0;
  }

  /// 规范化 key：工具名 + 递归按键排序的参数 JSON
  ///
  /// 排序保证 `{"a":1,"b":2}` 与 `{"b":2,"a":1}` 视为同参。
  String _canonicalKey(AgentToolCall call) {
    return '${call.name}|${jsonEncode(_sortDeep(call.arguments))}';
  }

  static Object? _sortDeep(Object? value) {
    if (value is Map<String, dynamic>) {
      final sorted = <String, dynamic>{};
      for (final key in value.keys.toList()..sort()) {
        sorted[key] = _sortDeep(value[key]);
      }
      return sorted;
    }
    if (value is List) {
      return value.map(_sortDeep).toList();
    }
    return value;
  }
}
