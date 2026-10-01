import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/services/round_history_utils.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事会话稿件导出范围
enum StoryExportScope {
  /// 全部已完成的轮次
  all,

  /// 仅最后一轮
  lastRound,
}

class _ExportRound {
  const _ExportRound({
    required this.turn,
    required this.input,
    required this.manuscript,
    required this.artifacts,
  });

  final int turn;

  /// 该轮的用户输入
  final String? input;

  /// 稿件正文（assistant content，即当前指针变体）
  final String? manuscript;

  final StoryRoundArtifacts? artifacts;
}

/// 故事会话稿件 Markdown 导出器
///
/// 与导演版（DirectorManuscriptExporter）同构的轮次配对与轮号推导；
/// 「含生成过程」输出故事四小窗数据（指令/检索关键词与记忆/生成草稿/
/// 事件摘要），不导出 agent 时间线（导演专属）。纯函数供 sheet 与测试
/// 共用。
class StoryManuscriptExporter {
  StoryManuscriptExporter._();

  static String toMarkdown({
    required ChatSession session,
    required List<ChatMessage> messages,
    required Map<int, StoryRoundArtifacts>? artifactsByTurnNumber,
    required int compactedTurnBase,
    required StoryExportScope scope,
    required bool includeProcess,
  }) {
    final rounds = _roundsOf(
      messages: messages,
      compactedTurnBase: compactedTurnBase,
      artifactsByTurnNumber: artifactsByTurnNumber,
    );
    final selected = scope == StoryExportScope.lastRound && rounds.isNotEmpty
        ? [rounds.last]
        : rounds;

    final exportedAt = _formatTimestamp(DateTime.now());
    final lines = <String>[
      '# ${session.title}',
      '',
    ];
    if (scope == StoryExportScope.lastRound && selected.isNotEmpty) {
      lines
        ..add(
          '> ${t.intermediate.chat.export.roundOf(round: selected.single.turn)}',
        )
        ..add('');
    } else {
      lines
        ..add(
          '> ${t.intermediate.chat.export.roundsCount(count: selected.length)} · '
          '${t.intermediate.chat.export.exportedAt(time: exportedAt)}',
        )
        ..add('');
    }
    lines
      ..add('---')
      ..add('');

    if (selected.isEmpty) {
      lines.add(t.intermediate.chat.export.noRounds);
      return lines.join('\n');
    }

    for (final round in selected) {
      lines
        ..add('## ${t.intermediate.chat.export.roundLabel(turn: round.turn)}')
        ..add('');
      if (includeProcess) {
        _appendProcess(lines, round);
      }
      final manuscript = round.manuscript?.trim();
      lines
        ..add(
          manuscript == null || manuscript.isEmpty ? '*(empty)*' : manuscript,
        )
        ..add('');
    }
    return lines.join('\n');
  }

  /// 从可见消息推导轮次列表（user→assistant 配对，与 body 聚合同口径）
  static List<_ExportRound> _roundsOf({
    required List<ChatMessage> messages,
    required int compactedTurnBase,
    required Map<int, StoryRoundArtifacts>? artifactsByTurnNumber,
  }) {
    final rounds = <_ExportRound>[];
    for (var i = 1; i < messages.length; i++) {
      final assistant = messages[i];
      if (assistant.role != 'assistant' || assistant.isSummary) continue;
      final user = messages[i - 1];
      if (user.role != 'user' || user.isSummary) continue;
      final turn = turnNumberForMessage(
        message: assistant,
        messages: messages,
        compactedTurnBase: compactedTurnBase,
      );
      if (turn == null) continue;
      rounds.add(
        _ExportRound(
          turn: turn,
          input: user.content,
          manuscript: assistant.content,
          artifacts: artifactsByTurnNumber?[turn],
        ),
      );
    }
    return rounds;
  }

  /// 故事四小窗过程数据：指令引文 + 检索关键词/记忆 + 生成草稿 + 事件摘要
  static void _appendProcess(List<String> lines, _ExportRound round) {
    final input = round.input?.trim();
    if (input != null && input.isNotEmpty) {
      lines
        ..add('**${t.intermediate.chat.export.inputLabel}**')
        ..add('')
        ..add('> $input')
        ..add('');
    }
    final artifacts = round.artifacts;
    if (artifacts == null) return;

    if (artifacts.extractedKeywords.isNotEmpty) {
      lines
        ..add('**${t.intermediate.chat.export.keywordsLabel}**')
        ..add('')
        ..add(artifacts.extractedKeywords.join('、'))
        ..add('');
    }
    final memories = artifacts.retrievedMemories
        .map((m) => m.summary?.trim() ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
    if (memories.isNotEmpty) {
      lines
        ..add('**${t.intermediate.chat.export.retrievedLabel}**')
        ..add('');
      for (final memory in memories) {
        lines.add('- $memory');
      }
      lines.add('');
    }
    // 生成草稿仅审查轮有对比价值（reviewExecuted=false 时草稿=正文，跳过）
    final draft = artifacts.generatedText?.trim();
    if (artifacts.reviewExecuted && draft != null && draft.isNotEmpty) {
      lines
        ..add('**${t.intermediate.chat.export.draftLabel}**')
        ..add('')
        ..add(draft)
        ..add('');
    }
    final summary = artifacts.eventSummary?.summary?.trim();
    if (summary != null && summary.isNotEmpty) {
      lines
        ..add('**${t.intermediate.chat.export.summaryLabel}**')
        ..add('')
        ..add(summary);
      final time = artifacts.eventSummary?.narrativeTime?.trim();
      if (time != null && time.isNotEmpty) {
        lines.add('${t.intermediate.chat.export.narrativeTimeLabel}：$time');
      }
      lines.add('');
    }
  }

  static String _formatTimestamp(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }
}
