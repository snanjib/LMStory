import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/network/sse/sse_parser.dart';

void main() {
  group('SseUsage.fromJson 缓存字段归一化', () {
    test('OpenAI 标准形态：prompt_tokens_details.cached_tokens', () {
      final usage = SseUsage.fromJson({
        'prompt_tokens': 1000,
        'completion_tokens': 200,
        'total_tokens': 1200,
        'prompt_tokens_details': {'cached_tokens': 800},
        'completion_tokens_details': {'reasoning_tokens': 64},
      });

      expect(usage.promptTokens, 1000);
      expect(usage.cacheReadTokens, 800);
      // 标准形态下未命中输入 = prompt - cached
      expect(usage.cacheMissTokens, 200);
      expect(usage.reasoningTokens, 64);
      expect(usage.warnings, isEmpty);
    });

    test('DeepSeek 原生形态：hit/miss 分项归一化为 prompt 与 cacheRead', () {
      final usage = SseUsage.fromJson({
        'prompt_cache_hit_tokens': 700,
        'prompt_cache_miss_tokens': 300,
        'completion_tokens': 120,
        'total_tokens': 1120,
      });

      expect(usage.promptTokens, 1000);
      expect(usage.cacheReadTokens, 700);
      expect(usage.cacheMissTokens, 300);
      expect(usage.warnings, isEmpty);
    });

    test('两套字段同时出现且一致 → 不记 warning', () {
      final usage = SseUsage.fromJson({
        'prompt_tokens': 1000,
        'prompt_tokens_details': {'cached_tokens': 700},
        'prompt_cache_hit_tokens': 700,
        'prompt_cache_miss_tokens': 300,
      });

      expect(usage.cacheReadTokens, 700);
      expect(usage.warnings, isEmpty);
    });

    test('cached_tokens 与 prompt_cache_hit_tokens 冲突 → 保留标准字段并记 warning', () {
      final usage = SseUsage.fromJson({
        'prompt_tokens': 1000,
        'prompt_tokens_details': {'cached_tokens': 800},
        'prompt_cache_hit_tokens': 700,
        'prompt_cache_miss_tokens': 200,
      });

      expect(usage.cacheReadTokens, 800, reason: '标准字段优先');
      expect(usage.cacheMissTokens, 200, reason: 'prompt - cached');
      expect(
        usage.warnings.any((w) => w.contains('cached_tokens(800)')),
        isTrue,
      );
    });

    test('prompt_tokens 与 hit+miss 不一致 → 记 warning 但保留 prompt', () {
      final usage = SseUsage.fromJson({
        'prompt_tokens': 1200,
        'prompt_cache_hit_tokens': 700,
        'prompt_cache_miss_tokens': 300,
      });

      expect(usage.promptTokens, 1200);
      expect(
        usage.warnings.any((w) => w.contains('prompt_tokens(1200)')),
        isTrue,
      );
    });

    test('无缓存分项 → cacheRead 为 null（不当 0）', () {
      final usage = SseUsage.fromJson({
        'prompt_tokens': 500,
        'completion_tokens': 50,
        'total_tokens': 550,
      });

      expect(usage.promptTokens, 500);
      expect(usage.cacheReadTokens, isNull);
      expect(usage.cacheMissTokens, isNull);
      expect(usage.reasoningTokens, isNull);
      expect(usage.warnings, isEmpty);
    });
  });
}
