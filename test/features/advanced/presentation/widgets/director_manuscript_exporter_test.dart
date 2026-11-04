import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_timeline_block.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/presentation/widgets/director_manuscript_exporter.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 导演稿件 Markdown 导出器测试
///
/// 四选组合（范围 × 内容）与幕号口径（压缩基数叠加）、Recap/幕后段落。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  ChatSession session() => ChatSession(
        sessionId: 's1',
        title: '夜航试笔',
        mode: 'advanced',
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
    List<AgentTimelineBlock>? timeline,
    List<AgentWorkStep>? steps,
    StoryAnchor? anchor,
    AgentWorkSummary? summary,
  }) =>
      StoryRoundArtifacts(
        sessionId: 's1',
        turnNumber: turn,
        createdAt: DateTime(2026),
        agentTimeline: timeline ?? const [],
        agentSteps: steps ?? const [],
        storyAnchor: anchor,
        agentWorkSummary: summary,
      );

  final messages = [
    message('u1', 'user', '让她走进灯塔'),
    message('a1', 'assistant', '第一幕正文。'),
    message('u2', 'user', '风暴来了'),
    message('a2', 'assistant', '第二幕正文。'),
  ];

  final artifactsByTurn = <int, StoryRoundArtifacts>{
    1: artifacts(
      1,
      anchor: const StoryAnchor(
        updatedTurn: 1,
        arc: '抵达灯塔',
        foreshadows: [
          AnchorForeshadow(text: '灯塔里有人'),
          AnchorForeshadow(text: '旧怀表', resolved: true),
        ],
        narrativeTime: '第三夜',
      ),
      summary: const AgentWorkSummary(
        steps: 2,
        totalTokens: 100,
        durationMs: 12000,
      ),
      timeline: const [
        AgentTimelineBlock(
          kind: AgentTimelineKind.action,
          stepIndex: 0,
          action: AgentWorkStep(
            toolName: 'search_story',
            callId: 'c1',
            title: '「灯塔」· 3 处命中',
            durationMs: 1200,
          ),
        ),
        AgentTimelineBlock(
          kind: AgentTimelineKind.narration,
          stepIndex: 1,
          text: '风暴是天然的幕启。',
        ),
      ],
    ),
    2: artifacts(2),
  };

  test('纯稿件·全部：按幕组织，含幕间场记，不含指令与幕后', () {
    final md = DirectorManuscriptExporter.toMarkdown(
      session: session(),
      messages: messages,
      artifactsByTurnNumber: artifactsByTurn,
      compactedTurnBase: 0,
      scope: DirectorExportScope.all,
      includeBackstage: false,
    );

    expect(md, contains('# 夜航试笔'));
    expect(md, contains('共 2 幕'));
    expect(md, contains('## 第 1 幕'));
    expect(md, contains('第一幕正文。'));
    expect(md, contains('## 第 2 幕'));
    expect(md, contains('第二幕正文。'));
    // 幕间场记（第 1 幕有锚）
    expect(md, contains('### 幕间场记'));
    expect(md, contains('- 当前弧线：抵达灯塔'));
    expect(md, contains('- 待兑现伏笔：灯塔里有人'));
    expect(md, contains('- 已兑现：旧怀表'));
    expect(md, contains('- 叙事时间：第三夜'));
    // 不含幕后
    expect(md, isNot(contains('导演指令')));
    expect(md, isNot(contains('幕后过程')));
    expect(md, isNot(contains('风暴是天然的幕启')));
  });

  test('含幕后过程·全部：指令引文 + 步骤行 + 播报行', () {
    final md = DirectorManuscriptExporter.toMarkdown(
      session: session(),
      messages: messages,
      artifactsByTurnNumber: artifactsByTurn,
      compactedTurnBase: 0,
      scope: DirectorExportScope.all,
      includeBackstage: true,
    );

    expect(md, contains('**导演指令**'));
    expect(md, contains('> 让她走进灯塔'));
    expect(md, contains('**幕后过程 · 2 步 · 12s**'));
    expect(md, contains('- 翻阅前情 · 「灯塔」· 3 处命中（1.2s）'));
    expect(md, contains('- 播报：风暴是天然的幕启。'));
  });

  test('当前幕：仅最后一幕，头部标注幕号', () {
    final md = DirectorManuscriptExporter.toMarkdown(
      session: session(),
      messages: messages,
      artifactsByTurnNumber: artifactsByTurn,
      compactedTurnBase: 0,
      scope: DirectorExportScope.currentAct,
      includeBackstage: false,
    );

    expect(md, contains('> 第 2 幕'));
    expect(md, contains('第二幕正文。'));
    expect(md, isNot(contains('第一幕正文。')));
    expect(md, isNot(contains('## 第 1 幕')));
  });

  test('压缩基数叠加：base=3 时幕号顺延', () {
    final md = DirectorManuscriptExporter.toMarkdown(
      session: session(),
      messages: messages,
      artifactsByTurnNumber: const {},
      compactedTurnBase: 3,
      scope: DirectorExportScope.all,
      includeBackstage: false,
    );

    expect(md, contains('## 第 4 幕'));
    expect(md, contains('## 第 5 幕'));
  });

  test('无已完成幕：输出空态说明', () {
    final md = DirectorManuscriptExporter.toMarkdown(
      session: session(),
      messages: [message('u1', 'user', '尚未开始')],
      artifactsByTurnNumber: null,
      compactedTurnBase: 0,
      scope: DirectorExportScope.all,
      includeBackstage: false,
    );

    expect(md, contains('共 0 幕'));
    expect(md, contains('尚无完成的幕'));
  });

  test('旧数据回退：无 timeline 时导出 agentSteps 步骤行', () {
    final md = DirectorManuscriptExporter.toMarkdown(
      session: session(),
      messages: messages,
      artifactsByTurnNumber: {
        1: artifacts(
          1,
          steps: const [
            AgentWorkStep(
              toolName: 'update_story_anchor',
              callId: 'c1',
              title: '补记伏笔',
              durationMs: 900,
            ),
          ],
        ),
      },
      compactedTurnBase: 0,
      scope: DirectorExportScope.all,
      includeBackstage: true,
    );

    expect(md, contains('- 记场记 · 补记伏笔'));
  });
}
