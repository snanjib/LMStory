import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/presentation/controllers/director_host.dart';
import 'package:lmstory/features/advanced/presentation/controllers/director_story_reader.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';

class _Host implements DirectorHost {
  _Host()
      : storyState = AdvancedChatState.initial(
          ChatSession(
            sessionId: 's1',
            title: 'test',
            mode: 'advanced',
            createdAt: DateTime(2026),
            lastActiveAt: DateTime(2026),
            messageCount: 0,
          ),
        );
  @override
  AdvancedChatState storyState;
  final messages = <String, List<ChatMessage>>{};
  final artifacts = <String, Map<int, StoryRoundArtifacts>>{};
  int messageLoads = 0;
  int artifactLoads = 0;
  @override
  Future<List<ChatMessage>> loadSessionMessages(String sessionId) async {
    messageLoads++;
    return messages[sessionId] ?? [];
  }

  @override
  Future<Map<int, StoryRoundArtifacts>> loadSessionArtifacts(
    String sessionId,
  ) async {
    artifactLoads++;
    return artifacts[sessionId] ?? {};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  ChatMessage message(
    String id,
    String role,
    String content, {
    bool summary = false,
  }) =>
      ChatMessage(
        messageId: id,
        sessionId: 's1',
        role: role,
        content: content,
        createdAt: DateTime(2026),
        isSummary: summary,
      );
  StoryRoundArtifacts artifact(int turn, String text) => StoryRoundArtifacts(
        sessionId: 's1',
        turnNumber: turn,
        createdAt: DateTime(2026),
        generatedText: text,
        replyText: 'reply',
      );

  test('压缩后仍读全部原文且用户消息不因摘要行错位', () async {
    final host = _Host();
    host.messages['s1'] = [
      message('u1', 'user', '旧用户输入'),
      message('a1', 'assistant', '旧正文'),
      message('sum', 'user', '压缩摘要', summary: true),
      message('u2', 'user', '新用户输入'),
      message('pending', 'user', '未提交输入'),
    ];
    host.artifacts['s1'] = {2: artifact(2, '新正文'), 1: artifact(1, '旧正文')};
    final reader = DirectorStoryReader(host);
    final all = await reader.readAllRounds();
    expect(all.map((r) => r.turnNumber), [1, 2]);
    expect(all.map((r) => r.userText), ['旧用户输入', '新用户输入']);
    expect(all.map((r) => r.narrativeText), ['旧正文', '新正文']);
    expect(host.messageLoads, 1);
    expect(host.artifactLoads, 1);
    final back = await reader.readRounds(fromTurn: 2, count: 1);
    expect(back.single.userText, '新用户输入');
    expect(await reader.totalRounds(), 2);
  });

  test('按当前会话隔离并在编辑后重新读取', () async {
    final host = _Host();
    host.artifacts['s1'] = {1: artifact(1, '当前会话')};
    host.artifacts['s2'] = {1: artifact(1, '其他会话')};
    final reader = DirectorStoryReader(host);
    expect((await reader.readAllRounds()).single.narrativeText, '当前会话');
    host.messages['s1'] = [
      message('u1', 'user', '当前输入'),
      message('a1', 'assistant', '编辑后的内容'),
    ];
    expect((await reader.readAllRounds()).single.narrativeText, '编辑后的内容');
    expect(host.messageLoads, 2);
    expect(host.artifactLoads, 2);
  });

  test('空会话和缺失轮次返回空结果', () async {
    final reader = DirectorStoryReader(_Host());
    expect(await reader.readAllRounds(), isEmpty);
    expect(await reader.readRounds(fromTurn: 1, count: 5), isEmpty);
    expect(await reader.totalRounds(), 0);
  });
}
