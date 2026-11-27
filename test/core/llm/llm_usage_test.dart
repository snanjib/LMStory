import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/llm/llm_usage.dart';

void main() {
  group('LlmUsage 完整输入面与命中率口径', () {
    test('OpenAI 形态：prompt 已含缓存，命中率分母用 prompt', () {
      const usage = LlmUsage(
        promptTokens: 10000,
        totalInputTokens: 10000,
        cacheReadTokens: 8000,
        completionTokens: 500,
      );

      expect(usage.fullInputTokens, 10000);
      expect(usage.cacheHitRatio, closeTo(0.8, 1e-9));
      expect(usage.uncachedInputTokens, 2000);
      expect(usage.hasCacheData, isTrue);
    });

    test('Anthropic 形态：完整输入 = input + cache_read + cache_creation', () {
      const usage = LlmUsage(
        promptTokens: 500,
        totalInputTokens: 10500,
        cacheReadTokens: 9000,
        cacheCreationTokens: 1000,
        completionTokens: 400,
      );

      expect(usage.fullInputTokens, 10500);
      expect(usage.cacheHitRatio, closeTo(9000 / 10500, 1e-9));
      expect(usage.uncachedInputTokens, 500);
    });

    test('缺 totalInputTokens 的旧适配器降级到 prompt', () {
      const usage = LlmUsage(promptTokens: 4000, cacheReadTokens: 1000);
      expect(usage.fullInputTokens, 4000);
      expect(usage.cacheHitRatio, closeTo(0.25, 1e-9));
    });

    test('无缓存分项 → 命中率 null（不得当 0 命中）', () {
      const usage = LlmUsage(promptTokens: 3000, totalInputTokens: 3000);
      expect(usage.hasCacheData, isFalse);
      expect(usage.cacheHitRatio, isNull);
      expect(
        LlmUsage.hitRateOf(cacheReadTokens: null, inputTokens: 3000),
        isNull,
      );
    });

    test('无输入面 → 命中率 null', () {
      const usage = LlmUsage(cacheReadTokens: 100);
      expect(usage.fullInputTokens, isNull);
      expect(usage.cacheHitRatio, isNull);
      expect(usage.uncachedInputTokens, isNull);
    });

    test('缓存分项异常大于输入面时未命中输入下限为 0，且命中率置未知', () {
      const usage = LlmUsage(
        totalInputTokens: 1000,
        cacheReadTokens: 1200,
      );
      expect(usage.uncachedInputTokens, 0);
      // 非法样本（cached > input）不得产出 120%
      expect(usage.cacheHitRatio, isNull);
      expect(usage.hasQualifiedCacheSample, isFalse);
    });

    test('hitRateOf 拒绝非正分母（不产生 infinity/NaN）', () {
      expect(LlmUsage.hitRateOf(cacheReadTokens: 10, inputTokens: 0), isNull);
      expect(LlmUsage.hitRateOf(cacheReadTokens: 10, inputTokens: -5), isNull);
      expect(
        LlmUsage.hitRateOf(cacheReadTokens: 10, inputTokens: 40),
        closeTo(0.25, 1e-9),
      );
    });

    test('hitRateOf 拒绝非法样本：负数/超过完整输入', () {
      expect(
        LlmUsage.hitRateOf(cacheReadTokens: 1200, inputTokens: 1000),
        isNull,
        reason: 'cached > input 不得展示 120%',
      );
      expect(
        LlmUsage.hitRateOf(cacheReadTokens: -1, inputTokens: 1000),
        isNull,
      );
    });

    test('计量冲突样本保留原值但命中率置未知', () {
      const usage = LlmUsage(
        totalInputTokens: 1000,
        cacheReadTokens: 800,
        warnings: [
          'prompt_tokens_details.cached_tokens(800) 与 prompt_cache_hit_tokens(700) 冲突',
        ],
      );
      expect(usage.fullInputTokens, 1000);
      expect(usage.cacheReadTokens, 800, reason: '原值保留用于诊断');
      expect(usage.cacheHitRatio, isNull, reason: '冲突样本不得精确成 80%');
      expect(usage.hasQualifiedCacheSample, isFalse);
    });
  });
}
