import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/features/advanced/domain/services/agent_system_prompt.dart';
import 'package:lmstory/features/advanced/presentation/controllers/director_round_runner.dart';

/// coreBlocks 两态 surface 组装
///
/// false（A 案）= coreBlocks 是 system 第 1 条；
/// true（B 案，默认）= coreBlocks 以 workbench-reminder user 消息挪到
/// 本轮用户输入之前、尾部提醒之前，system 区只剩冻结前缀。
void main() {
  const frozenPrefix = '【项目规则】…冻结前缀…';
  const coreBlocks = '【当前世界状态（关键实体）】\n· 沈青梧';
  final history = [
    AgentMessage.user('第 1 轮输入'),
    AgentMessage.assistant(text: '第 1 轮正文'),
  ];
  final tail = [
    AgentMessage.user(
      wrapWorkbenchReminder(
        workbenchContractText(const {'search_story', 'finish_round'}),
      ),
    ),
    AgentMessage.user(wrapWorkbenchReminder(kStyleIronRuleLine)),
  ];

  List<AgentMessage> build({required bool coreBlocksInTail}) =>
      buildDirectorSurface(
        frozenPrefix: frozenPrefix,
        historyMessages: history,
        coreBlocks: coreBlocks,
        coreBlocksInTail: coreBlocksInTail,
        userInput: '本轮输入',
        tailMessages: tail,
      );

  group('T2 关闭（A 案）', () {
    test('coreBlocks 是 system 第 1 条，位于历史之前（既有布局不变）', () {
      final surface = build(coreBlocksInTail: false);

      expect(surface[0].role, 'system');
      expect(surface[0].content, frozenPrefix);
      expect(surface[1].role, 'system');
      expect(surface[1].content, coreBlocks);
      expect(surface[2].content, '第 1 轮输入');
      expect(surface[3].content, '第 1 轮正文');
      // 本轮输入在尾部指令之前
      expect(surface[4].content, '本轮输入');
      expect(surface[5].content, contains(kWorkbenchReminderOpen));
    });

    test('coreBlocks 为 null（首轮无记忆）时不产生空位', () {
      final surface = buildDirectorSurface(
        frozenPrefix: frozenPrefix,
        historyMessages: history,
        coreBlocks: null,
        coreBlocksInTail: false,
        userInput: '本轮输入',
        tailMessages: tail,
      );
      expect(surface, hasLength(1 + history.length + 1 + tail.length));
      expect(surface[1].content, '第 1 轮输入');
    });
  });

  group('T2 开启（B 案，默认）', () {
    test('system 区只剩冻结前缀；coreBlocks 挪到本轮输入之前且带包裹与标题', () {
      final surface = build(coreBlocksInTail: true);

      // system 区唯一：冻结前缀
      final systemMessages = surface.where((m) => m.role == 'system').toList();
      expect(systemMessages, hasLength(1));
      expect(systemMessages.single.content, frozenPrefix);

      // coreBlocks 为 user 消息，位于历史之后、本轮输入之前
      final coreIndex = surface.indexWhere(
        (m) => m.role == 'user' && m.content!.contains(kCoreBlocksTailTitle),
      );
      expect(coreIndex, 3); // frozen + 2 history
      expect(
        surface[coreIndex].content,
        wrapCoreBlocksForTail(coreBlocks),
      );
      expect(surface[coreIndex + 1].content, '本轮输入');
      // 标题锚点
      expect(surface[coreIndex].content, contains('截至上一轮'));
      expect(surface[coreIndex].content, contains('资料非指令'));
    });

    test('挪尾块在尾部提醒之前（recency 顺序：历史 → 世界状态 → 输入 → 契约）', () {
      final surface = build(coreBlocksInTail: true);
      final coreIndex = surface.indexWhere(
        (m) => m.role == 'user' && m.content!.contains(kCoreBlocksTailTitle),
      );
      final contractIndex = surface.lastIndexWhere(
        (m) => m.content!.contains('【工作契约】'),
      );
      expect(coreIndex, lessThan(contractIndex));
    });

    test('coreBlocks 为 null 时挪尾路径不产生注入', () {
      final surface = buildDirectorSurface(
        frozenPrefix: frozenPrefix,
        historyMessages: history,
        coreBlocks: null,
        coreBlocksInTail: true,
        userInput: '本轮输入',
        tailMessages: tail,
      );
      expect(
        surface.any((m) => m.content!.contains(kCoreBlocksTailTitle)),
        isFalse,
      );
    });
  });

  group('历史尾索引', () {
    test('A 案 core blocks 在 system 区时前缀多一条', () {
      expect(
        directorStablePrefixEndIndex(
          historyLength: 4,
          hasCoreBlocks: true,
          coreBlocksInTail: false,
        ),
        5,
      );
    });

    test('B 案 core blocks 在尾部时只计冻结前缀', () {
      expect(
        directorStablePrefixEndIndex(
          historyLength: 4,
          hasCoreBlocks: true,
          coreBlocksInTail: true,
        ),
        4,
      );
    });

    test('无 core blocks 时只计冻结前缀', () {
      expect(
        directorStablePrefixEndIndex(
          historyLength: 4,
          hasCoreBlocks: false,
          coreBlocksInTail: false,
        ),
        4,
      );
    });

    test('空历史返回 null', () {
      expect(
        directorStablePrefixEndIndex(
          historyLength: 0,
          hasCoreBlocks: true,
          coreBlocksInTail: true,
        ),
        isNull,
      );
    });
  });
}
