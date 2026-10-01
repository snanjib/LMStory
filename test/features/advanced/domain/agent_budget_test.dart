import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_budget.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

void main() {
  group('AgentUsageAccumulator last 分项', () {
    test('add 多次覆盖 last 三项，累加字段照旧累加', () {
      final acc = AgentUsageAccumulator()
        ..add(
          const LlmUsage(
            promptTokens: 100,
            completionTokens: 10,
            cacheReadTokens: 80,
          ),
        )
        ..add(
          const LlmUsage(
            promptTokens: 200,
            completionTokens: 20,
            cacheReadTokens: 150,
          ),
        );

      expect(acc.promptTokens, 300);
      expect(acc.completionTokens, 30);
      expect(acc.cacheReadTokens, 230);
      // last = 最近一次请求（上下文真实占用），非累加
      expect(acc.lastPromptTokens, 200);
      expect(acc.lastCompletionTokens, 20);
      expect(acc.lastCacheReadTokens, 150);
    });

    test('add(null) 不污染 last 值', () {
      final acc = AgentUsageAccumulator()
        ..add(const LlmUsage(promptTokens: 100, completionTokens: 10))
        ..add(null);

      expect(acc.lastPromptTokens, 100);
      expect(acc.lastCompletionTokens, 10);
      expect(acc.lastCacheReadTokens, 0);
    });

    test('merge 取有数据一方的 last 值', () {
      final a = AgentUsageAccumulator()
        ..add(const LlmUsage(promptTokens: 100, completionTokens: 10));
      final b = AgentUsageAccumulator()
        ..add(
          const LlmUsage(
            promptTokens: 500,
            completionTokens: 50,
            cacheReadTokens: 400,
          ),
        );

      a.merge(b);
      expect(a.promptTokens, 600);
      expect(a.lastPromptTokens, 500);
      expect(a.lastCacheReadTokens, 400);
    });

    test('merge 空累计器不覆盖 last 值', () {
      final a = AgentUsageAccumulator()
        ..add(const LlmUsage(promptTokens: 100, completionTokens: 10))
        ..merge(AgentUsageAccumulator());

      expect(a.lastPromptTokens, 100);
    });
  });
}
