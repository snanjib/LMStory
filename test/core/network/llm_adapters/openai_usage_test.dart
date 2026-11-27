import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/network/llm_adapters/openai_adapter.dart';

void main() {
  group('OpenAiAdapter 计量异常降级', () {
    test('标准 cached 与 DeepSeek hit 冲突：保留原值、warnings 非空、比例未知', () {
      final adapter = OpenAiAdapter();
      final response = adapter.parseResponse({
        'choices': [
          {
            'message': {'content': 'ok'},
            'finish_reason': 'stop',
          },
        ],
        'usage': {
          'prompt_tokens': 1000,
          'completion_tokens': 100,
          'total_tokens': 1100,
          'prompt_tokens_details': {'cached_tokens': 800},
          'prompt_cache_hit_tokens': 700,
        },
      });

      final usage = response.usage!;
      expect(usage.warnings, isNotEmpty, reason: '冲突必须留痕，不得静默');
      expect(usage.cacheReadTokens, 800, reason: '标准字段优先，原值保留诊断');
      expect(usage.cacheHitRatio, isNull, reason: '冲突样本不得展示精确 80%');
      expect(usage.hasQualifiedCacheSample, isFalse);
    });

    test('合法样本仍给出精确命中率', () {
      final adapter = OpenAiAdapter();
      final response = adapter.parseResponse({
        'choices': [
          {
            'message': {'content': 'ok'},
            'finish_reason': 'stop',
          },
        ],
        'usage': {
          'prompt_tokens': 1000,
          'completion_tokens': 100,
          'total_tokens': 1100,
          'prompt_tokens_details': {'cached_tokens': 800},
        },
      });

      expect(response.usage!.warnings, isEmpty);
      expect(response.usage!.cacheHitRatio, closeTo(0.8, 1e-9));
    });
  });
}
