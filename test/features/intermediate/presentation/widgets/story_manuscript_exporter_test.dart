import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/story_manuscript_exporter.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事稿件 Markdown 导出器测试
///
/// 四选组合（范围 × 内容）与轮号口径；「含生成过程」为故事四小窗数据
///（指令/检索关键词与记忆/草稿/摘要），非 agent 时间线。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  ChatSession session() => ChatSession(
        sessionId: 's1',
        title: '夜航试笔',
        mode: 'intermediate',
        createdAt: DateTime(2026),
        lastActiveAt: DateTime(2026),
        messageCount: 4,
      );

  ChatMessage message(String id, String role, String content) => ChatMessage(
        messageId: id,
        sessionId: 's1',
        role: role,
        content: content,
        createdAt: DateTime(2026),
      );

  StoryRoundArtifacts artifacts(
    int turn, {
    bool reviewExecuted = true,
    String? generatedText,
  }) =>
      StoryRoundArtifacts(
        sessionId: 's1',
        turnNumber: turn,
        createdAt: DateTime(2026),
        reviewExecuted: reviewExecuted,
        generatedText: generatedText,
        extractedKeywords: turn == 1 ? const ['灯塔', '风暴'] : const [],
        retrievedMemories: turn == 1
            ? [
                ExperientialMemory(
                  memoryId: 'm1',
                  sessionId: 's1',
                  summary: '他曾在第三夜抵达灯塔',
                  importance: 4,
                  tags: const [],
                  turnNumber: 1,
                  createdAt: DateTime(2026),
                ),
              ]
            : const [],
        eventSummary: turn == 1
            ? const EventSummary(
                summary: '她推开了灯塔的门',
                importance: 4,
                tags: [],
                turnNumber: 1,
                narrativeTime: '第三夜',
              )
            : null,
      );

  final messages = [
    message('u1', 'user', '让她走进灯塔'),
    message('a1', 'assistant', '第一轮正文。'),
    message('u2', 'user', '风暴来了'),
    message('a2', 'assistant', '第二轮正文。'),
  ];

  final artifactsByTurn = <int, StoryRoundArtifacts>{
    1: artifacts(1, generatedText: '第一轮草稿（审查前）'),
    2: artifacts(2, reviewExecuted: false),
  };

  test('纯正文·全部：按轮组织，不含指令与过程数据', () {
    final md = StoryManuscriptExporter.toMarkdown(
      session: session(),
      messages: messages,
      artifactsByTurnNumber: artifactsByTurn,
      compactedTurnBase: 0,
      scope: StoryExportScope.all,
      includeProcess: false,
    );

    expect(md, contains('# 夜航试笔'));
    expect(md, contains('第一轮正文。'));
    expect(md, contains('第二轮正文。'));
    expect(md, contains('共 2 轮'));
    expect(md, isNot(contains('让她走进灯塔')), reason: '纯正文不含指令');
    expect(md, isNot(contains('灯塔、风暴')), reason: '纯正文不含检索关键词');
  });

  test('含过程·全部：指令/关键词/记忆/草稿/摘要随轮输出', () {
    final md = StoryManuscriptExporter.toMarkdown(
      session: session(),
      messages: messages,
      artifactsByTurnNumber: artifactsByTurn,
      compactedTurnBase: 0,
      scope: StoryExportScope.all,
      includeProcess: true,
    );

    expect(md, contains('> 让她走进灯塔'), reason: '指令引文');
    expect(md, contains('灯塔、风暴'), reason: '检索关键词（顿号连接）');
    expect(md, contains('- 他曾在第三夜抵达灯塔'), reason: '检索记忆列表行');
    expect(
      md,
      contains('第一轮草稿（审查前）'),
      reason: '审查轮草稿与正文有对比价值，导出',
    );
    expect(md, contains('她推开了灯塔的门'), reason: '事件摘要');
    expect(md, contains('叙事时间：第三夜'));
    // 第二轮 reviewExecuted=false：草稿=正文，不重复导出
    final secondRoundBlock = md.indexOf('第二轮正文。');
    expect(
      md.indexOf('第二轮草稿'),
      -1,
      reason: '跳过审查的轮次草稿与正文相同，不重复输出',
    );
    expect(secondRoundBlock, greaterThan(0));
  });

  test('仅最新轮：只输出最后一轮并标注轮号', () {
    final md = StoryManuscriptExporter.toMarkdown(
      session: session(),
      messages: messages,
      artifactsByTurnNumber: artifactsByTurn,
      compactedTurnBase: 0,
      scope: StoryExportScope.lastRound,
      includeProcess: false,
    );

    expect(md, contains('第 2 轮'));
    expect(md, contains('第二轮正文。'));
    expect(md, isNot(contains('第一轮正文。')));
  });

  test('空会话：占位文案不抛异常', () {
    final md = StoryManuscriptExporter.toMarkdown(
      session: session(),
      messages: const [],
      artifactsByTurnNumber: null,
      compactedTurnBase: 0,
      scope: StoryExportScope.all,
      includeProcess: false,
    );

    expect(md, contains('暂无可导出的轮次'));
  });

  test('压缩基数叠加：轮号跨压缩保持真实值', () {
    // 可见列表仅 1 轮（2 条消息），但压缩基数 5 → 真实轮号 6
    final compactedMessages = [
      message('u6', 'user', '续写指令'),
      message('a6', 'assistant', '压缩后正文。'),
    ];
    final md = StoryManuscriptExporter.toMarkdown(
      session: session(),
      messages: compactedMessages,
      artifactsByTurnNumber: null,
      compactedTurnBase: 5,
      scope: StoryExportScope.all,
      includeProcess: false,
    );

    expect(md, contains('第 6 轮'), reason: '轮号=压缩基数+可见轮序');
    expect(md, contains('共 1 轮'));
  });
}
