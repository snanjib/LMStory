import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/story_runtime/domain/services/round_history_utils.dart';

void main() {
  ChatMessage msg(String role, String content, String id) => ChatMessage(
        messageId: id,
        sessionId: 's1',
        role: role,
        content: content,
        createdAt: DateTime(2026),
      );

  ExperientialMemory exp(
    String id, {
    int turn = 1,
    String? narrativeTime,
  }) =>
      ExperientialMemory(
        memoryId: id,
        sessionId: 's1',
        summary: 's',
        importance: 3,
        tags: const [],
        turnNumber: turn,
        createdAt: DateTime(2026),
        narrativeTime: narrativeTime,
      );

  group('latestNarrativeTimeOf', () {
    test('同轮并列无时间的 macro 在后 → 仍取到前一条 micro 的时间', () {
      final experiences = [
        exp('m1', turn: 5, narrativeTime: '第三夜'),
        exp('macro', turn: 5), // 手动压缩插入的同轮 macro，无时间
      ];
      expect(latestNarrativeTimeOf(experiences), '第三夜');
    });

    test('全部无 narrativeTime → null（回退初始时间）', () {
      expect(latestNarrativeTimeOf([exp('m1'), exp('m2')]), isNull);
      expect(latestNarrativeTimeOf(const []), isNull);
    });

    test('正常取最后一条非空时间', () {
      final experiences = [
        exp('m1', narrativeTime: '第一日'),
        exp('m2', turn: 2, narrativeTime: '第二日'),
      ];
      expect(latestNarrativeTimeOf(experiences), '第二日');
    });
  });

  test('末尾持久化 user 消息与 userInput 相同 → 剔除', () {
    final history = [
      msg('user', '第一轮输入', 'u1'),
      msg('assistant', '第一轮回复', 'a1'),
      msg('user', '重新生成的输入', 'u2'),
    ];
    final result = stripTrailingDuplicateUserInput(history, '重新生成的输入');
    expect(result, hasLength(2));
    expect(result.last.messageId, 'a1');
    // 不改动原列表
    expect(history, hasLength(3));
  });

  test('末尾是 assistant → 不剔除', () {
    final history = [
      msg('user', '输入', 'u1'),
      msg('assistant', '回复', 'a1'),
    ];
    expect(stripTrailingDuplicateUserInput(history, '输入'), hasLength(2));
  });

  test('末尾 user 内容不同 → 不剔除（编辑重发场景内容已换新）', () {
    final history = [
      msg('user', '旧输入', 'u1'),
      msg('assistant', '回复', 'a1'),
      msg('user', '新输入', 'u2'),
    ];
    expect(stripTrailingDuplicateUserInput(history, '另一条输入'), hasLength(3));
  });

  test('中间的同文消息不动（用户故意重复发送是合法剧情输入）', () {
    final history = [
      msg('user', '同一句话', 'u1'),
      msg('assistant', '回复一', 'a1'),
      msg('user', '同一句话', 'u2'),
      msg('assistant', '回复二', 'a2'),
      msg('user', '同一句话', 'u3'),
    ];
    final result = stripTrailingDuplicateUserInput(history, '同一句话');
    expect(result.map((m) => m.messageId), ['u1', 'a1', 'u2', 'a2']);
  });

  test('连续多条末尾同文 user 消息全部剔除', () {
    final history = [
      msg('assistant', '回复', 'a1'),
      msg('user', '同文', 'u2'),
      msg('user', '同文', 'u3'),
    ];
    final result = stripTrailingDuplicateUserInput(history, '同文');
    expect(result.map((m) => m.messageId), ['a1']);
  });

  test('空历史 / content 为 null 的安全处理', () {
    expect(stripTrailingDuplicateUserInput(const [], '任意'), isEmpty);
    final history = [
      ChatMessage(
        messageId: 'u1',
        sessionId: 's1',
        role: 'user',
        createdAt: DateTime(2026),
      ),
    ];
    expect(stripTrailingDuplicateUserInput(history, '任意'), hasLength(1));
  });

  // ──  turn 单一事实源：轮次号公式统一工具 ────────────────────────────

  ChatMessage dialogueMsg(String id, String role, {bool isSummary = false}) =>
      ChatMessage(
        messageId: id,
        sessionId: 's1',
        role: role,
        content: '$id 内容',
        isSummary: isSummary,
        createdAt: DateTime(2026),
      );

  List<ChatMessage> dialogue({
    required int rounds,
    bool withSummary = false,
    bool withOrphanAssistant = false,
  }) {
    return [
      if (withOrphanAssistant) dialogueMsg('orphan', 'assistant'),
      if (withSummary) dialogueMsg('summary', 'system', isSummary: true),
      for (var i = 0; i < rounds; i++) ...[
        dialogueMsg('u$i', 'user'),
        dialogueMsg('a$i', 'assistant'),
      ],
    ];
  }

  group('countDialogueMessages', () {
    test('排除摘要卡与 system 消息', () {
      expect(countDialogueMessages(dialogue(rounds: 3, withSummary: true)), 6);
    });

    test('空列表返回 0', () {
      expect(countDialogueMessages(const []), 0);
    });
  });

  group('completedTurnCount / formulaNextTurnNumber', () {
    test('压缩基数 + 可见配对轮数（不含摘要卡）', () {
      final messages = dialogue(rounds: 4, withSummary: true);
      expect(completedTurnCount(compactedTurnBase: 5, messages: messages), 9);
      expect(
        formulaNextTurnNumber(compactedTurnBase: 5, messages: messages),
        10,
      );
    });

    test('奇数对话数 floor 掉半轮（孤儿场景不虚高）', () {
      final messages = [
        dialogueMsg('u0', 'user'),
        dialogueMsg('a0', 'assistant'),
        dialogueMsg('u1', 'user'),
      ];
      expect(completedTurnCount(compactedTurnBase: 0, messages: messages), 1);
    });
  });

  group('resolveTurnNumber', () {
    test('计数器优先', () {
      expect(
        resolveTurnNumber(
          nextTurn: 7,
          compactedTurnBase: 2,
          messages: dialogue(rounds: 3),
        ),
        7,
      );
    });

    test('计数器 NULL 惰性回退公式（存量会话兼容）', () {
      expect(
        resolveTurnNumber(
          nextTurn: null,
          compactedTurnBase: 2,
          messages: dialogue(rounds: 3),
        ),
        6,
      );
    });
  });

  group('turnNumberForMessage', () {
    test('干净对话：user 开启轮 / assistant 完成轮', () {
      final messages = dialogue(rounds: 3);
      expect(
        turnNumberForMessage(
          message: messages[4], // u2
          messages: messages,
          compactedTurnBase: 0,
        ),
        3,
      );
      expect(
        turnNumberForMessage(
          message: messages[5], // a2
          messages: messages,
          compactedTurnBase: 0,
        ),
        3,
      );
    });

    test('压缩基数叠加（摘要卡在 index 0 不影响配对）', () {
      final messages = dialogue(rounds: 2, withSummary: true);
      // [summary, u0, a0, u1, a1]：a0 是基数后第 1 轮 → 10+1=11
      expect(
        turnNumberForMessage(
          message: messages[2], // a0
          messages: messages,
          compactedTurnBase: 10,
        ),
        11,
      );
    });

    test('头部孤儿 assistant 不挤占后续轮号（role 感知配对）', () {
      // 旧 index 奇偶公式在头部孤儿 assistant 场景会整体错位；
      // role 感知推导按对话数配对，孤儿归入第 0 轮，u0 仍是第 1 轮。
      final messages = dialogue(rounds: 2, withOrphanAssistant: true);
      expect(
        turnNumberForMessage(
          message: messages[1], // u0
          messages: messages,
          compactedTurnBase: 0,
        ),
        1,
      );
      expect(
        turnNumberForMessage(
          message: messages[4], // a1
          messages: messages,
          compactedTurnBase: 0,
        ),
        2,
      );
    });

    test('消息不在列表中返回 null', () {
      expect(
        turnNumberForMessage(
          message: dialogueMsg('ghost', 'user'),
          messages: dialogue(rounds: 2),
          compactedTurnBase: 0,
        ),
        isNull,
      );
    });
  });
}
