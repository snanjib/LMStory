import 'package:lmstory/features/advanced/domain/services/agent_story_reader.dart';
import 'package:lmstory/features/advanced/presentation/controllers/director_host.dart';

/// 经宿主读取当前会话保存的原文，避免依赖压缩后的工作上下文。
class DirectorStoryReader implements AgentStoryReader {
  DirectorStoryReader(this._host);

  final DirectorHost _host;

  @override
  Future<int> totalRounds() async {
    final artifacts =
        await _host.loadSessionArtifacts(_host.storyState.session.sessionId);
    return artifacts.isEmpty
        ? 0
        : artifacts.keys.reduce((a, b) => a > b ? a : b);
  }

  @override
  Future<List<AgentStoryRound>> readRounds({
    required int fromTurn,
    required int count,
  }) async =>
      (await readAllRounds())
          .where(
            (round) =>
                round.turnNumber >= fromTurn &&
                round.turnNumber < fromTurn + count,
          )
          .toList();

  @override
  Future<List<AgentStoryRound>> readAllRounds() async {
    final sessionId = _host.storyState.session.sessionId;
    final artifacts = await _host.loadSessionArtifacts(sessionId);
    final messages = await _host.loadSessionMessages(sessionId);
    // 与回读口径一致：按第 N 条真实 user 消息配对，压缩摘要不占轮号。
    final userTexts = messages
        .where((message) => message.role == 'user' && !message.isSummary)
        .map((message) => message.content)
        .toList();
    final userTurnById = <String, int>{};
    final assistantTexts = <int, String>{};
    var currentTurn = 0;
    for (final message in messages) {
      if (message.isSummary) continue;
      if (message.role == 'user') {
        currentTurn++;
        userTurnById[message.messageId] = currentTurn;
      } else if (message.role == 'assistant' && message.content != null) {
        final turn = userTurnById[message.parentUserMsgId] ?? currentTurn;
        if (turn > 0) assistantTexts[turn] = message.content ?? '';
      }
    }
    final turns = artifacts.keys.toList()..sort();
    return [
      for (final turn in turns)
        if (artifacts[turn] case final artifact?)
          AgentStoryRound(
            turnNumber: turn, createdAt: artifact.createdAt,
            userText: turn > 0 && turn <= userTexts.length
                ? userTexts[turn - 1]
                : null,
            // 消息正文随编辑/变体切换更新，产物正文可能仍保留生成时快照。
            narrativeText: assistantTexts[turn] ?? artifact.generatedText,
            replyText: artifact.replyText == artifact.generatedText
                ? assistantTexts[turn] ?? artifact.replyText
                : artifact.replyText,
            eventSummaryText: artifact.eventSummary?.displayText,
          ),
    ];
  }
}
