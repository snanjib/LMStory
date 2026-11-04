import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_tool_card.dart'
    show stageVerbOf;
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/services/round_history_utils.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 导演会话稿件导出范围
enum DirectorExportScope {
  /// 全部已完成的幕
  all,

  /// 仅最后一幕（当前幕）
  currentAct,
}

class _ExportRound {
  const _ExportRound({
    required this.turn,
    required this.directive,
    required this.manuscript,
    required this.artifacts,
  });

  final int turn;

  /// 该幕的导演指令（user 消息内容）
  final String? directive;

  /// 稿件正文（assistant content，即当前指针变体）
  final String? manuscript;

  final StoryRoundArtifacts? artifacts;
}

/// 导演会话稿件 Markdown 导出器
///
/// 与设置页的对话式导出（SessionExportFormatter）不同：导演会话的资产是
/// **稿件流**（每幕 = 导演指令 → 幕后执行 → 稿件正文 → 幕间场记），导出
/// 按幕组织。幕号/配对推导与 body 渲染同口径（[turnNumberForMessage]）；
/// 稿件取 chat_messages.content（即当前指针变体——变体切换后导出所选版本）。
///
/// 含幕后过程时输出：指令引文 + 幕后摘要行 + 动作步骤与播报列表；
/// 思考块全文不导出（体量与噪声考虑，幕后时间线在应用内可查）。
class DirectorManuscriptExporter {
  DirectorManuscriptExporter._();

  static String toMarkdown({
    required ChatSession session,
    required List<ChatMessage> messages,
    required Map<int, StoryRoundArtifacts>? artifactsByTurnNumber,
    required int compactedTurnBase,
    required DirectorExportScope scope,
    required bool includeBackstage,
  }) {
    final rounds = _roundsOf(
      messages: messages,
      compactedTurnBase: compactedTurnBase,
      artifactsByTurnNumber: artifactsByTurnNumber,
    );
    final selected =
        scope == DirectorExportScope.currentAct && rounds.isNotEmpty
            ? [rounds.last]
            : rounds;

    final exportedAt = _formatTimestamp(DateTime.now());
    final lines = <String>[
      '# ${session.title}',
      '',
    ];
    if (scope == DirectorExportScope.currentAct && selected.isNotEmpty) {
      lines
        ..add('> ${t.advanced.export.actOf(act: selected.single.turn)}')
        ..add('');
    } else {
      lines
        ..add(
          '> ${t.advanced.export.actsCount(count: selected.length)} · '
          '${t.advanced.export.exportedAt(time: exportedAt)}',
        )
        ..add('');
    }
    lines
      ..add('---')
      ..add('');

    if (selected.isEmpty) {
      lines.add(t.advanced.export.noRounds);
      return lines.join('\n');
    }

    for (final round in selected) {
      lines
        ..add('## ${t.advanced.recap.actLabel(act: round.turn)}')
        ..add('');
      if (includeBackstage) {
        _appendBackstage(lines, round);
      }
      final manuscript = round.manuscript?.trim();
      lines
        ..add(
          manuscript == null || manuscript.isEmpty ? '*(empty)*' : manuscript,
        )
        ..add('');
      _appendRecap(lines, round.artifacts?.storyAnchor);
      lines.add('');
    }
    return lines.join('\n');
  }

  /// 从可见消息推导幕列表（user→assistant 配对，与 body 聚合同口径）
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
          directive: user.content,
          manuscript: assistant.content,
          artifacts: artifactsByTurnNumber?[turn],
        ),
      );
    }
    return rounds;
  }

  static void _appendBackstage(List<String> lines, _ExportRound round) {
    final directive = round.directive?.trim();
    if (directive != null && directive.isNotEmpty) {
      lines
        ..add('**${t.advanced.export.directiveLabel}**')
        ..add('')
        ..add('> $directive')
        ..add('');
    }
    final artifacts = round.artifacts;
    final summary = artifacts?.agentWorkSummary;
    final seconds = summary != null && summary.durationMs >= 1000
        ? (summary.durationMs / 1000).round()
        : null;
    final steps = summary?.steps;
    final backstageTitle = steps == null
        ? t.advanced.export.backstageLabel
        : seconds == null
            ? t.advanced.export.backstageWithSteps(steps: steps)
            : t.advanced.export.backstageWithStepsAndSeconds(
                steps: steps,
                seconds: seconds,
              );
    lines
      ..add('**$backstageTitle**')
      ..add('');
    final timeline = artifacts?.agentTimeline ?? const <AgentTimelineBlock>[];
    if (timeline.isNotEmpty) {
      for (final block in timeline) {
        if (block.isAction) {
          lines.add('- ${_stepLine(block.action!)}');
        } else if (block.kind == AgentTimelineKind.narration &&
            block.text.trim().isNotEmpty) {
          lines.add(
            '- ${t.advanced.export.narrationPrefix}：${block.text.trim()}',
          );
        }
      }
    } else {
      for (final step in artifacts?.agentSteps ?? const <AgentWorkStep>[]) {
        lines.add('- ${_stepLine(step)}');
      }
    }
    lines.add('');
  }

  static String _stepLine(AgentWorkStep step) {
    final verb = stageVerbOf(step.toolName, t);
    final title = step.title.trim();
    final duration = step.durationMs >= 1000
        ? '（${(step.durationMs / 1000).toStringAsFixed(1)}s）'
        : '';
    return title.isEmpty ? '$verb$duration' : '$verb · $title$duration';
  }

  static void _appendRecap(List<String> lines, StoryAnchor? anchor) {
    if (anchor == null || anchor.isEmpty) return;
    lines
      ..add('### ${t.advanced.export.recapTitle}')
      ..add('');
    final arc = anchor.arc?.trim();
    if (arc != null && arc.isNotEmpty) {
      lines.add('- ${t.advanced.recap.arc}：$arc');
    }
    if (anchor.foreshadows.isNotEmpty) {
      final open = <String>[];
      final resolved = <String>[];
      for (final f in anchor.foreshadows) {
        (f.resolved ? resolved : open).add(f.text);
      }
      if (open.isNotEmpty) {
        lines.add('- ${t.advanced.recap.foreshadowsOpen}：${open.join('；')}');
      }
      if (resolved.isNotEmpty) {
        lines.add(
          '- ${t.advanced.recap.foreshadowsResolved}：${resolved.join('；')}',
        );
      }
    }
    final time = anchor.narrativeTime?.trim();
    if (time != null && time.isNotEmpty) {
      lines.add('- ${t.advanced.export.narrativeTimeLabel}：$time');
    }
  }

  static String _formatTimestamp(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}';
  }
}
