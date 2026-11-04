import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_work_step.dart';
import 'package:lmstory/features/advanced/domain/services/agent_system_prompt.dart';
import 'package:lmstory/features/advanced/presentation/controllers/director_work_trace.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/memory/domain/entities/facts_change_record.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';

///  跨轮工作痕迹测试（长会话退化治理设计 §3-S1）
///
/// 覆盖：trace 文案生成（有工具/无工具/全失败）、装配顺序与角色、
///  折叠锚点（纪元内全保留+纯追加不变量）、老会话 artifacts 缺失
/// 回退、压缩基数偏移。
/// 期望值包装器（：round-work 标签统一经 workbench-reminder 包裹）
String w(String inner) => wrapWorkbenchReminder(inner);

void main() {
  AgentWorkStep step(
    String toolName, {
    String argsPreview = '',
    AgentStepStatus status = AgentStepStatus.done,
  }) =>
      AgentWorkStep(
        toolName: toolName,
        argsPreview: argsPreview,
        status: status,
      );

  StoryRoundArtifacts artifact(
    int turn, {
    List<AgentWorkStep> steps = const [],
    List<FactsChangeRecord> factsChanges = const [],
  }) =>
      StoryRoundArtifacts(
        sessionId: 's1',
        turnNumber: turn,
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
        factsChanges: factsChanges,
        agentSteps: steps,
      );

  FactsChangeRecord change() => const FactsChangeRecord(
        action: FactAction.updateAttr,
        confidence: 4,
        primaryName: '沈青梧',
        attrKey: '状态',
        newValue: '负伤',
      );

  ChatMessage msg(String role, String content, {bool isSummary = false}) =>
      ChatMessage(
        messageId: '$role-${isSummary ? 'sum' : content.hashCode}',
        sessionId: 's1',
        role: role,
        content: content,
        createdAt: DateTime.fromMillisecondsSinceEpoch(0),
        isSummary: isSummary,
      );

  group('roundWorkTraceFor 文案', () {
    test('有工具轮：分段聚合 · 连接，读技能取 argsPreview 名字', () {
      final a = artifact(
        12,
        steps: [
          step('search_story_text'),
          step('query_facts'),
          step('read_skill', argsPreview: '{"name":"战斗场面"}'),
          step('update_story_anchor'),
        ],
        factsChanges: [change(), change(), change()],
      );
      expect(
        roundWorkTraceFor(a),
        w('〈round-work n=12〉查记忆×2 · 事实+3 · 读技能:战斗场面 · 锚点更新〈/round-work〉'),
      );
    });

    test('无工具轮：诚实标注直写正文（finish_round/system 不算工具）', () {
      final a = artifact(
        13,
        steps: [step('finish_round'), step('system')],
      );
      expect(
        roundWorkTraceFor(a),
        w('〈round-work n=13〉本轮无工具调用，直写正文〈/round-work〉'),
      );
    });

    test('有调用但全部失败：如实记调用数，不美化', () {
      final a = artifact(
        14,
        steps: [
          step('query_facts', status: AgentStepStatus.error),
          step('search_story', status: AgentStepStatus.error),
        ],
      );
      expect(
        roundWorkTraceFor(a),
        w('〈round-work n=14〉工具调用2 次（未见成效）〈/round-work〉'),
      );
    });

    test('DD2：warning（失败但本轮继续）不计入成功工具数', () {
      final a = artifact(
        16,
        steps: [
          // 一次失败后重试成功：失败那条不得被算成"查记忆"
          step('query_facts', status: AgentStepStatus.warning),
          step('query_facts'),
        ],
      );
      expect(
        roundWorkTraceFor(a),
        w('〈round-work n=16〉查记忆×1〈/round-work〉'),
      );
    });

    test('DD2：仅 warning 无成功 → 如实记"未见成效"', () {
      final a = artifact(
        17,
        steps: [
          step('search_story', status: AgentStepStatus.warning),
        ],
      );
      expect(
        roundWorkTraceFor(a),
        w('〈round-work n=17〉工具调用1 次（未见成效）〈/round-work〉'),
      );
    });

    test('record_event_memory / merge_entities / spawn 各有专属段', () {
      final a = artifact(
        15,
        steps: [
          step('record_event_memory'),
          step('merge_entities'),
          step('spawn'),
        ],
      );
      final trace = roundWorkTraceFor(a)!;
      expect(trace, contains('记事件×1'));
      expect(trace, contains('归并×1'));
      expect(trace, contains('派子代理×1'));
    });

    test('读技能 argsPreview 畸形 JSON：跳过名字不炸', () {
      final a = artifact(
        16,
        steps: [step('read_skill', argsPreview: '{trunc')],
      );
      expect(roundWorkTraceFor(a), contains('工具调用1 次'));
    });
  });

  group('mapHistoryWithWorkTraces 装配', () {
    test('trace 以 user 消息插在对应 assistant 正文之后', () {
      final artifacts = {
        1: artifact(1, steps: [step('query_facts')]),
        2: artifact(2, steps: [step('finish_round')]),
      };
      final history = [
        msg('user', '第一轮输入'),
        msg('assistant', '第一轮正文。'),
        msg('user', '第二轮输入'),
        msg('assistant', '第二轮正文。'),
      ];

      final result = mapHistoryWithWorkTraces(
        history: history,
        artifacts: artifacts,
        compactedTurnBase: 0,
      );

      // user, assistant, trace, user, assistant, trace
      expect(result, hasLength(6));
      expect(result[2].role, 'user');
      expect(result[2].content, contains('〈round-work n=1〉'));
      expect(result[5].content, contains('本轮无工具调用'));
      // assistant 正文仍在 trace 之前
      expect(result[1].content, '第一轮正文。');
    });

    test('B1 折叠锚点：压缩纪元内各轮 trace 全保留（不再按 8 轮滑窗截断）', () {
      final artifacts = <int, StoryRoundArtifacts>{
        for (var t = 1; t <= 12; t++)
          t: artifact(t, steps: [step('query_facts')]),
      };
      final history = <ChatMessage>[
        for (var t = 1; t <= 12; t++) ...[
          msg('user', '输入$t'),
          msg('assistant', '正文$t。'),
        ],
      ];

      final result = mapHistoryWithWorkTraces(
        history: history,
        artifacts: artifacts,
        compactedTurnBase: 0,
      );

      final traceTurns = result
          .where((m) => m.content?.contains('round-work') ?? false)
          .map((m) => RegExp(r'n=(\d+)').firstMatch(m.content!)!.group(1))
          .toList();
      // 纪元内 1..12 轮全部保留——跨轮缓存前缀覆盖整个历史区
      expect(traceTurns, [
        '1',
        '2',
        '3',
        '4',
        '5',
        '6',
        '7',
        '8',
        '9',
        '10',
        '11',
        '12',
      ]);
    });

    test('B1 跨轮前缀稳定：追加一轮后既有 trace 序列字节不变（纯追加）', () {
      List<ChatMessage> history(int n) => <ChatMessage>[
            for (var t = 1; t <= n; t++) ...[
              msg('user', '输入$t'),
              msg('assistant', '正文$t。'),
            ],
          ];
      final artifacts = <int, StoryRoundArtifacts>{
        for (var t = 1; t <= 12; t++)
          t: artifact(t, steps: [step('query_facts')]),
      };

      final before = mapHistoryWithWorkTraces(
        history: history(11),
        artifacts: artifacts,
        compactedTurnBase: 0,
      );
      final after = mapHistoryWithWorkTraces(
        history: history(12),
        artifacts: artifacts,
        compactedTurnBase: 0,
      );

      // 第 12 轮追加后，此前序列逐条字节恒定（滑窗时代此处会删除第 4 轮 trace）
      expect(after.take(before.length).length, before.length);
      for (var i = 0; i < before.length; i++) {
        expect(after[i].content, before[i].content, reason: 'index=$i');
        expect(after[i].role, before[i].role, reason: 'index=$i');
      }
    });

    test('老会话 artifacts 缺失：该轮跳过不伪造', () {
      final history = [
        msg('user', '第一轮输入'),
        msg('assistant', '第一轮正文。'),
        msg('user', '第二轮输入'),
        msg('assistant', '第二轮正文。'),
      ];
      final result = mapHistoryWithWorkTraces(
        history: history,
        artifacts: {
          2: artifact(2, steps: [step('query_facts')]),
        },
        compactedTurnBase: 0,
      );
      expect(result, hasLength(5));
      expect(result[2].content, '第二轮输入'); // 第一轮无 trace，直接是下一轮输入
      expect(result[4].content, contains('n=2'));
    });

    test('压缩基数偏移：摘要行不计数，绝对轮号 = base + k', () {
      final artifacts = {
        4: artifact(4, steps: [step('query_facts')]),
      };
      final history = [
        // 压缩摘要行（role=system, isSummary）不应参与轮号计数
        msg('system', '前情摘要……', isSummary: true),
        msg('user', '第四轮输入'),
        msg('assistant', '第四轮正文。'),
      ];
      final result = mapHistoryWithWorkTraces(
        history: history,
        artifacts: artifacts,
        compactedTurnBase: 3,
      );
      expect(result[0].role, 'system');
      expect(result[3].content, contains('〈round-work n=4〉'));
    });

    test('S5 计数口径：zeroMemoryRoundStreak 连续/清零/旧数据回退', () {
      StoryRoundArtifacts round(
        int turn,
        List<String> tools,
      ) =>
          StoryRoundArtifacts(
            sessionId: 's1',
            turnNumber: turn,
            createdAt: DateTime.fromMillisecondsSinceEpoch(0),
            agentSteps: [
              for (final t in tools)
                AgentWorkStep(
                  toolName: t,
                ),
            ],
          );

      // 空会话 / 空 artifacts → 0
      expect(zeroMemoryRoundStreak({}), 0);

      // 连续 3 轮零记忆（有工具但非记忆类）→ 3
      expect(
        zeroMemoryRoundStreak({
          1: round(1, ['query_facts']),
          2: round(2, ['search_story']),
          3: round(3, ['finish_round']),
        }),
        3,
      );

      // 最近轮用过 update_facts → 清零
      expect(
        zeroMemoryRoundStreak({
          1: round(1, ['query_facts']),
          2: round(2, ['update_facts']),
          3: round(3, ['finish_round']),
        }),
        1,
      );

      // 中间轮用过 record_event_memory（调用即清零，与成败无关）
      expect(
        zeroMemoryRoundStreak({
          1: round(1, ['record_event_memory']),
          2: round(2, ['finish_round']),
          3: round(3, ['query_facts']),
        }),
        2,
      );

      // 旧轮无 agentSteps（story 模式轮/早期数据）→ fail-open 终止计数
      expect(
        zeroMemoryRoundStreak({
          1: StoryRoundArtifacts(
            sessionId: 's1',
            turnNumber: 1,
            createdAt: DateTime.fromMillisecondsSinceEpoch(0),
          ),
          2: round(2, ['finish_round']),
          3: round(3, ['finish_round']),
        }),
        2,
      );
      expect(
        zeroMemoryRoundStreak({
          1: StoryRoundArtifacts(
            sessionId: 's1',
            turnNumber: 1,
            createdAt: DateTime.fromMillisecondsSinceEpoch(0),
          ),
        }),
        0,
      );
    });

    test('S4 窗口与触发：styleDriftReminderFor 判定口径', () {
      AgentWorkSummary summary(int? hits) => AgentWorkSummary(
            steps: 3,
            totalTokens: 100,
            durationMs: 500,
            styleLintHits: hits,
          );

      StoryRoundArtifacts round(
        int turn, {
        int? hits,
        List<AgentWorkStep> steps = const [],
      }) =>
          StoryRoundArtifacts(
            sessionId: 's1',
            turnNumber: turn,
            createdAt: DateTime.fromMillisecondsSinceEpoch(0),
            agentSteps: steps,
            agentWorkSummary: summary(hits),
          );

      // 触发：窗口内 2 轮非零 + 未读 deai-flavor
      final drifted = {
        1: round(1, hits: 0),
        2: round(2, hits: 3),
        3: round(3, hits: 0),
        4: round(4, hits: 2),
        5: round(5, hits: 0),
      };
      final line = styleDriftReminderFor(drifted);
      expect(line, contains('共 5 处'));
      expect(line, contains('read_skill'));
      expect(line, contains('deai-flavor'));

      // 未达阈值：仅 1 轮非零 → 不触发
      expect(
        styleDriftReminderFor({1: round(1, hits: 4), 2: round(2)}),
        isNull,
      );

      // 抑制：窗口内读过 deai-flavor → 不触发（argsPreview 取名）
      final suppressed = {
        1: round(1, hits: 3),
        2: round(2, hits: 2),
        3: round(
          3,
          steps: [
            const AgentWorkStep(
              toolName: 'read_skill',
              argsPreview: '{"name":"deai-flavor"}',
            ),
          ],
        ),
      };
      expect(styleDriftReminderFor(suppressed), isNull);

      // 旧数据回退：styleLintHits=null 不参与统计
      expect(
        styleDriftReminderFor({1: round(1), 2: round(2)}),
        isNull,
      );

      // 窗口=最近 5 轮：第 6 轮前的命中不计入
      final oldOnly = {
        1: round(1, hits: 5),
        2: round(2, hits: 5),
        3: round(3),
        4: round(4),
        5: round(5),
        6: round(6),
      };
      expect(styleDriftReminderFor(oldOnly), isNull);

      // 空 artifacts（新会话）不触发
      expect(styleDriftReminderFor({}), isNull);
    });

    test('缓存前缀不变量：trace 只在历史区，不追加到前缀/尾部', () {
      final result = mapHistoryWithWorkTraces(
        history: [msg('user', 'u'), msg('assistant', 'a。')],
        artifacts: {
          1: artifact(1, steps: [step('query_facts')]),
        },
        compactedTurnBase: 0,
      );
      // 首条仍是历史第一条 user（冻结前缀在此之前的组装不变）
      expect(result.first.content, 'u');
      // 末条是 trace（尾部指令由调用方追加，与本模块无关）
      expect(result.last.content, contains('round-work'));
    });
  });
}
