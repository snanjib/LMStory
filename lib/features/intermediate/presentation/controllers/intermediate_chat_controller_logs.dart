// clang-format off
// coverage:ignore-file
// part of IntermediateChatController，仅拆分用途，不引入新逻辑。
// 详见 intermediate_chat_controller.dart 顶部说明。

part of 'intermediate_chat_controller.dart';

// ── Stage 5 调试日志格式化 ──────────────────────────────────────────

/// 格式化 LLM 请求 messages 供调试日志输出
///
/// 输出格式：每条消息一行 `[role] content`，消息间用换行分隔。
/// 用户主动开启 `logPrompts` 时调用，预期完整记录（含系统提示/历史/用户输入）。
String _formatMessagesForLog(List<Map<String, dynamic>> messages) {
  final parts = <String>[];
  for (var i = 0; i < messages.length; i++) {
    final m = messages[i];
    final role = m['role'] ?? 'unknown';
    final content = m['content'] ?? '';
    parts.add('[$i] $role: $content');
  }
  return 'count=${messages.length}\n${parts.join('\n')}';
}

/// 格式化检索结果供调试日志输出
///
/// 输出格式：每条记忆一行 `[finalScore] turn=N importance=M summary`，
/// 便于人工核对检索命中与分数分布。空列表时输出 `(empty)`。
String _formatMemoriesForLog(List<ScoredMemory> memories) {
  if (memories.isEmpty) return '(empty)';
  final parts = <String>[];
  for (final sm in memories) {
    parts.add(
      '[${sm.finalScore.toStringAsFixed(3)}] '
      'turn=${sm.memory.turnNumber} '
      'importance=${sm.memory.importance} '
      'tags=${sm.memory.tags} '
      '${sm.memory.summary}',
    );
  }
  return 'count=${memories.length}\n${parts.join('\n')}';
}
