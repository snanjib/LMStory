import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/services/agent_session_stats.dart';

AgentDurableEvent _event(
  String type,
  Map<String, dynamic> data, {
  int? turn,
}) {
  return AgentDurableEvent(
    type: type,
    data: turn == null ? data : {...data, 'turn': turn},
    time: DateTime(2026),
  );
}

void main() {
  group('agentSessionStatsFrom（B10 会话级聚合）', () {
    test('聚合数值与单轮明细一致：步数分布/工具失败率/token 分项/命中率', () {
      final events = [
        // 轮 1：2 步、2 工具（1 失败）
        _event(AgentEventTypes.turnBegin, {'maxSteps': 8}, turn: 1),
        _event(
          AgentEventTypes.stepEnd,
          {
            'stepIndex': 0,
            'promptTokens': 1000,
            'completionTokens': 100,
            'totalTokens': 1100,
            'cacheReadTokens': 800,
            'cacheCreationTokens': 50,
          },
          turn: 1,
        ),
        _event(
          AgentEventTypes.toolResult,
          {'toolName': 'search_story', 'isError': false},
          turn: 1,
        ),
        _event(
          AgentEventTypes.stepEnd,
          {
            'stepIndex': 1,
            'promptTokens': 1200,
            'completionTokens': 300,
            'totalTokens': 1500,
            'cacheReadTokens': 1000,
          },
          turn: 1,
        ),
        _event(
          AgentEventTypes.toolResult,
          {'toolName': 'update_facts', 'isError': true},
          turn: 1,
        ),
        _event(
          AgentEventTypes.turnEnd,
          {
            'reason': 'completed',
            'steps': 2,
            'promptTokens': 2200,
            'completionTokens': 400,
            'totalTokens': 2600,
            'cacheReadTokens': 1800,
            'cacheCreationTokens': 50,
          },
          turn: 1,
        ),
        // 轮 2：1 步、1 工具成功、无 cache 上报（旧日志/无缓存端点形态）
        _event(AgentEventTypes.turnBegin, {'maxSteps': 8}, turn: 2),
        _event(
          AgentEventTypes.stepEnd,
          {
            'stepIndex': 0,
            'promptTokens': 600,
            'completionTokens': 200,
            'totalTokens': 800,
          },
          turn: 2,
        ),
        _event(
          AgentEventTypes.toolResult,
          {'toolName': 'search_story', 'isError': false},
          turn: 2,
        ),
        _event(
          AgentEventTypes.turnEnd,
          {
            'reason': 'completed',
            'steps': 1,
            'promptTokens': 600,
            'completionTokens': 200,
            'totalTokens': 800,
          },
          turn: 2,
        ),
      ];

      final stats = agentSessionStatsFrom(events);

      // 轮数与步数分布
      expect(stats.turns, 2);
      expect(stats.steps, 3);
      expect(stats.stepsByTurn, {1: 2, 2: 1});

      // 工具失败率（按工具分）
      expect(stats.toolStats['search_story']!.calls, 2);
      expect(stats.toolStats['search_story']!.errors, 0);
      expect(stats.toolStats['update_facts']!.calls, 1);
      expect(stats.toolStats['update_facts']!.errors, 1);
      expect(stats.toolStats['update_facts']!.failureRate, 1.0);

      // token 分布（与 turn/end 分项合计一致）
      expect(stats.promptTokens, 2800);
      expect(stats.completionTokens, 600);
      expect(stats.cacheReadTokens, 1800);
      expect(stats.cacheCreationTokens, 50);

      // 命中率趋势：轮 1 有 cache（1800/(1800+2200)），轮 2 无上报
      expect(stats.cacheTrend, hasLength(2));
      expect(stats.cacheTrend[0].turn, 1);
      expect(stats.cacheTrend[0].hitRate, closeTo(1800 / 4000, 1e-9));
      expect(
        stats.cacheTrend[1].hitRate,
        closeTo(0 / 600, 1e-9),
        reason: '轮 2 turn/end 缺 cache 键按 0 计，base=600>0 → 0%',
      );
      // 会话加权命中率 = 1800 / (1800+2200+600)
      expect(
        stats.weightedCacheHitRate,
        closeTo(1800 / 4600, 1e-9),
      );
    });

    test('旧日志兼容：step/end 与 turn/end 全缺 cache 键 → 分项为 0、趋势点 0%', () {
      final events = [
        _event(AgentEventTypes.stepEnd, {'stepIndex': 0}, turn: 1),
        _event(
          AgentEventTypes.turnEnd,
          {
            'reason': 'completed',
            'steps': 1,
            'promptTokens': 100,
          },
          turn: 1,
        ),
      ];

      final stats = agentSessionStatsFrom(events);
      expect(stats.cacheReadTokens, 0);
      expect(stats.cacheCreationTokens, 0);
      expect(stats.cacheTrend.single.hitRate, 0.0);
      expect(stats.weightedCacheHitRate, 0.0);
    });

    test('崩溃恢复形态：有 step 无 turn/end 的残轮也计入步数分布', () {
      final events = [
        _event(AgentEventTypes.stepEnd, {'stepIndex': 0}, turn: 1),
        _event(AgentEventTypes.turnEnd, {'steps': 1}, turn: 1),
        // 轮 2 崩溃：step/end 已 flush 但 turn/end 缺失（恢复器补账前的原始形态）
        _event(AgentEventTypes.stepEnd, {'stepIndex': 0}, turn: 2),
        _event(AgentEventTypes.stepEnd, {'stepIndex': 1}, turn: 2),
      ];

      final stats = agentSessionStatsFrom(events);
      expect(stats.stepsByTurn, {1: 1, 2: 2});
      expect(stats.turns, 1, reason: 'turns 按 turn/end 计（恢复器会补齐）');
      expect(stats.steps, 3);
    });

    test('synthetic 占位工具结果计入失败（中断形态也是失败形态）', () {
      final events = [
        _event(
          AgentEventTypes.toolResult,
          {'toolName': 'finish_round', 'isError': true, 'synthetic': true},
          turn: 1,
        ),
      ];
      final stats = agentSessionStatsFrom(events);
      expect(stats.toolStats['finish_round']!.errors, 1);
    });

    test('审查收官 R1-P1-1：子代理中继事件不双计（usage 已由 spawn 并账）', () {
      final events = [
        _event(
          AgentEventTypes.turnEnd,
          {
            'reason': 'completed',
            'steps': 2,
            'promptTokens': 1000,
            'completionTokens': 200,
          },
          turn: 1,
        ),
        // 子代理中继事件（起 log-only 落账）
        _event(
          AgentEventTypes.turnEnd,
          {
            'reason': 'completed',
            'steps': 3,
            'promptTokens': 500,
            'completionTokens': 100,
            'subagent': true,
          },
          turn: 1,
        ),
        _event(AgentEventTypes.stepEnd, {'stepIndex': 0}, turn: 1),
        _event(
          AgentEventTypes.stepEnd,
          {'stepIndex': 0, 'subagent': true},
          turn: 1,
        ),
        _event(
          AgentEventTypes.stepEnd,
          {'stepIndex': 1, 'subagent': true},
          turn: 1,
        ),
        _event(
          AgentEventTypes.toolResult,
          {'toolName': 'search_story', 'isError': false, 'subagent': true},
          turn: 1,
        ),
      ];

      final stats = agentSessionStatsFrom(events);
      // 主轮口径：token 只算主轮 turn/end，步数只算主轮 step/end
      expect(stats.promptTokens, 1000);
      expect(stats.completionTokens, 200);
      expect(stats.steps, 1);
      expect(stats.stepsByTurn, {1: 1});
      expect(stats.toolStats, isEmpty, reason: '子代理工具调用不进主轮统计');
    });

    test('空事件流 → 零值聚合不炸', () {
      final stats = agentSessionStatsFrom(const []);
      expect(stats.turns, 0);
      expect(stats.steps, 0);
      expect(stats.toolStats, isEmpty);
      expect(stats.weightedCacheHitRate, isNull);
    });
  });
}
