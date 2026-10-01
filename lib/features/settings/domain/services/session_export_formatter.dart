import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 单会话导出格式化器
///
/// 将会话和消息列表格式化为不同的人类可读或机器可读格式。
/// 独立于 DataManagementService，便于单独测试和扩展格式。
class SessionExportFormatter {
  SessionExportFormatter._();

  /// 格式化为 Markdown
  ///
  /// 人类可读的对话记录，按角色分段，便于分享和复制到笔记软件。
  static String toMarkdown(ChatSession session, List<ChatMessage> messages) {
    final lines = <String>[
      '# ${session.title}',
      '',
      '> ${_formatTimestamp(session.createdAt)}',
      '',
      '---',
      '',
    ];

    for (final msg in messages.where((m) => !m.isSummary)) {
      final roleLabel = _roleLabelMarkdown(msg.role);
      final timestamp = _formatTimestamp(msg.createdAt);
      final text = msg.content?.trim();
      lines
        ..add('### $roleLabel · $timestamp')
        ..add('')
        ..add(text == null || text.isEmpty ? '*(empty)*' : text)
        ..add('');
    }

    return lines.join('\n');
  }

  /// 格式化为纯文本
  ///
  /// 最简格式：每条消息以 `[角色] [时间]` 开头，内容另起一行。
  static String toText(ChatSession session, List<ChatMessage> messages) {
    final lines = <String>[
      session.title,
      '=' * 40,
      '',
    ];

    for (final msg in messages.where((m) => !m.isSummary)) {
      final role = _roleLabelPlain(msg.role);
      final time = _formatTimestamp(msg.createdAt);
      final text = msg.content?.trim();
      lines
        ..add('[$role] [$time]')
        ..add(text == null || text.isEmpty ? '(empty)' : text)
        ..add('');
    }

    return lines.join('\n');
  }

  /// Markdown 角色标签入 slang（写入导出文件的
  /// 用户可见文案；纯文本格式保持英文短标签的终端风格，属既有设计）
  static String _roleLabelMarkdown(String role) {
    switch (role) {
      case 'user':
        return t.settings.data.exportRoleUser;
      case 'assistant':
        return t.settings.data.exportRoleAssistant;
      case 'system':
        return t.settings.data.exportRoleSystem;
      default:
        return role;
    }
  }

  static String _roleLabelPlain(String role) {
    switch (role) {
      case 'user':
        return 'USER';
      case 'assistant':
        return 'ASSISTANT';
      case 'system':
        return 'SYSTEM';
      default:
        return role.toUpperCase();
    }
  }

  static String _formatTimestamp(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }
}
