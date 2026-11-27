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
      expect(acc.lastCacheReadTokens, isNull, reason: '未上报缓存不得按 0 命中');
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

    test('完整输入累计与 last：优先 totalInput，缺失回退 prompt', () {
      final acc = AgentUsageAccumulator()
        ..add(
          const LlmUsage(
            promptTokens: 500,
            totalInputTokens: 2500,
            cacheReadTokens: 1800,
          ),
        )
        ..add(const LlmUsage(promptTokens: 800));

      expect(acc.totalInputTokens, 2500 + 800, reason: '旧适配器回退 prompt');
      expect(acc.lastTotalInputTokens, 0, reason: '原始字段未上报');
      expect(acc.lastCompleteInputTokens, 800, reason: '展示口径回退 fullInput');
    });

    test('cache 分项是否上报：null 不当成 0 命中样本', () {
      final withoutCache = AgentUsageAccumulator()
        ..add(const LlmUsage(promptTokens: 100, totalInputTokens: 100));
      expect(withoutCache.hasCacheReadTokens, isFalse);
      expect(withoutCache.hasCacheCreationTokens, isFalse);

      final withCache = AgentUsageAccumulator()
        ..add(
          const LlmUsage(
            promptTokens: 100,
            totalInputTokens: 100,
            cacheReadTokens: 0,
            cacheCreationTokens: 0,
          ),
        );
      expect(withCache.hasCacheReadTokens, isTrue, reason: '显式 0 也是上报');
      expect(withCache.hasCacheCreationTokens, isTrue);
    });

    test('merge 合并 cache 上报标志（子代理并账不丢覆盖）', () {
      final parent = AgentUsageAccumulator()
        ..add(const LlmUsage(promptTokens: 100, totalInputTokens: 100));
      final subagent = AgentUsageAccumulator()
        ..add(
          const LlmUsage(
            promptTokens: 50,
            totalInputTokens: 50,
            cacheReadTokens: 40,
          ),
        );

      parent.merge(subagent);
      expect(parent.hasCacheReadTokens, isTrue);
    });

    test('部分请求未上报缓存时，可比样本只含已知请求', () {
      final acc = AgentUsageAccumulator()
        ..add(
          const LlmUsage(
            promptTokens: 100,
            totalInputTokens: 100,
            cacheReadTokens: 80,
          ),
        )
        ..add(const LlmUsage(promptTokens: 100, totalInputTokens: 100));

      // 成本口径仍累计全量输入
      expect(acc.totalInputTokens, 200);
      // 命中率口径只累计可比样本（80 / 100 = 80%，不是 80 / 200 = 40%）
      expect(acc.cacheComparableInputTokens, 100);
      expect(acc.cacheComparableReadTokens, 80);
      expect(acc.cacheComparableSteps, 1);
      expect(acc.hasComparableCache, isTrue);
    });

    test('异常样本不进可比缓存样本，但原始值保留', () {
      final acc = AgentUsageAccumulator()
        ..add(
          const LlmUsage(
            promptTokens: 100,
            totalInputTokens: 100,
            cacheReadTokens: 120,
          ),
        )
        ..add(
          const LlmUsage(
            promptTokens: 100,
            totalInputTokens: 100,
            cacheReadTokens: 70,
            warnings: ['字段冲突'],
          ),
        );

      expect(acc.hasComparableCache, isFalse);
      expect(acc.cacheReadTokens, 190, reason: '原始值保留用于诊断');
      expect(acc.usageWarnings, ['字段冲突']);
    });

    test('整轮累计 warnings 不覆盖末次合法请求', () {
      final acc = AgentUsageAccumulator()
        ..add(
          const LlmUsage(
            promptTokens: 1000,
            totalInputTokens: 1000,
            cacheReadTokens: 800,
            warnings: ['首步字段冲突'],
          ),
        )
        ..add(
          const LlmUsage(
            promptTokens: 1000,
            totalInputTokens: 1000,
            cacheReadTokens: 0,
          ),
        );

      // 整轮诊断仍保留首步异常
      expect(acc.usageWarnings, ['首步字段冲突']);
      // 末次请求自身合法：清空前次 warning，0 缓存是有效样本
      expect(acc.lastRequestWarnings, isEmpty);
      expect(acc.lastCacheReadTokens, 0);
      expect(acc.lastCompleteInputTokens, 1000);
    });

    test('子代理并账不污染父轮末次请求的 warnings', () {
      final parent = AgentUsageAccumulator()
        ..add(
          const LlmUsage(
            promptTokens: 1000,
            totalInputTokens: 1000,
            cacheReadTokens: 0,
          ),
        );
      final subagent = AgentUsageAccumulator()
        ..add(
          const LlmUsage(
            promptTokens: 500,
            totalInputTokens: 500,
            cacheReadTokens: 400,
            warnings: ['子代理字段冲突'],
          ),
        );

      parent.merge(subagent, carryLastRequest: false);

      expect(parent.usageWarnings, ['子代理字段冲突'], reason: '整轮诊断保留');
      expect(parent.lastRequestWarnings, isEmpty);
      expect(parent.lastCacheReadTokens, 0);
      expect(parent.lastCompleteInputTokens, 1000);
    });

    test('父子并账 carryLastRequest 时末次请求与 warnings 整体迁移', () {
      final parent = AgentUsageAccumulator()
        ..add(
          const LlmUsage(
            promptTokens: 1000,
            totalInputTokens: 1000,
            cacheReadTokens: 0,
          ),
        );
      final child = AgentUsageAccumulator()
        ..add(
          const LlmUsage(
            promptTokens: 500,
            totalInputTokens: 500,
            cacheReadTokens: 400,
            warnings: ['字段冲突'],
          ),
        );

      parent.merge(child);

      expect(parent.lastRequestWarnings, ['字段冲突']);
      expect(parent.lastCacheReadTokens, 400);
      expect(parent.lastCompleteInputTokens, 500);
    });
  });
}
