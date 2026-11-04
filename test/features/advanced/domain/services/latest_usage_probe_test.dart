import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/advanced/domain/services/latest_usage_probe.dart';

AgentDurableEvent _event(String type, Map<String, dynamic> data) {
  return AgentDurableEvent(type: type, data: data, time: DateTime(2026));
}

void main() {
  group('latestStepEndPromptTokens', () {
    test('取最后一条带 promptTokens 的 step/end', () {
      final tokens = latestStepEndPromptTokens([
        _event(AgentEventTypes.turnBegin, {'maxSteps': 8}),
        _event(AgentEventTypes.stepEnd, {'promptTokens': 100}),
        _event(AgentEventTypes.stepEnd, {'promptTokens': 300}),
        _event(AgentEventTypes.turnEnd, {'promptTokens': 400}),
      ]);
      expect(tokens, 300);
    });

    test('跳过 promptTokens 为空的 step/end', () {
      final tokens = latestStepEndPromptTokens([
        _event(AgentEventTypes.stepEnd, {'promptTokens': 100}),
        _event(AgentEventTypes.stepEnd, {}),
      ]);
      expect(tokens, 100);
    });

    test('无 step/end 或全空 → null', () {
      expect(latestStepEndPromptTokens([]), isNull);
      expect(
        latestStepEndPromptTokens([
          _event(AgentEventTypes.turnBegin, {}),
        ]),
        isNull,
      );
    });
  });

  group('latestStepEndUsage（B10：cache 分项随探针回填）', () {
    test('最新 step 的 prompt 与 cacheRead 一并返回（崩溃恢复后旧轮可回填）', () {
      final usage = latestStepEndUsage([
        _event(AgentEventTypes.stepEnd, {
          'promptTokens': 1000,
          'cacheReadTokens': 800,
        }),
        _event(AgentEventTypes.stepEnd, {
          'promptTokens': 3000,
          'cacheReadTokens': 2500,
          'cacheCreationTokens': 100,
        }),
        _event(AgentEventTypes.turnEnd, {'promptTokens': 4000}),
      ]);
      expect(usage, isNotNull);
      expect(usage!.promptTokens, 3000);
      expect(usage.cacheReadTokens, 2500);
    });

    test('审查收官 R1-P2-5：子代理 stepEnd 被跳过（独立小上下文不回填）', () {
      final usage = latestStepEndUsage([
        _event(AgentEventTypes.stepEnd, {'promptTokens': 5000}),
        _event(
          AgentEventTypes.stepEnd,
          {'promptTokens': 300, 'subagent': true},
        ),
      ]);
      expect(usage!.promptTokens, 5000);
    });

    test('旧日志缺 cache 键 → prompt 正常、cacheRead 为 null', () {
      final usage = latestStepEndUsage([
        _event(AgentEventTypes.stepEnd, {'promptTokens': 500}),
      ]);
      expect(usage!.promptTokens, 500);
      expect(usage.cacheReadTokens, isNull);
    });
  });
}
