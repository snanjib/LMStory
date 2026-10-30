import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/config/intermediate_prompts.dart';
import 'package:lmstory/core/config/intermediate_prompts_v2.dart';

void main() {
  group('IntermediateConfig', () {
    test('fromJson 正确解析完整配置', () {
      final json = <String, dynamic>{
        'system_prompt': '你是海盗船长',
        'retrieval': {
          'top_k': 10,
          'fts5_weight': 0.3,
          'vector_weight': 0.7,
          'key_event_threshold': 3,
          'key_event_boost': 2.0,
          'normalization_epsilon': 0.05,
        },
        'retry': {
          'generating_max_retries': 3,
          'extracting_max_retries': 3,
          'retrieval_max_retries': 2,
          'reviewing_max_retries': 3,
          'summarizing_max_retries': 3,
          'stream_interrupt_retry': 2,
        },
        'embedding': {
          'timeout_ms': 10000,
          'fallback_on_failure': false,
        },
        'stream': {
          'tool_calling_enabled': false,
          'generating_separator': '<<<GENERATING>>>',
          'event_summary_separator': '<<<SUMMARY>>>',
          'json_fallback': true,
          'inject_response_format': true,
          'skip_review_when_empty_retrieval': false,
          'generating_fold_delay_ms': 3000,
          'retrieval_fold_delay_ms': 500,
        },
        'fork': {
          'regenerate_window_rounds': 10,
        },
      };

      final config = IntermediateConfig.fromJson(json);

      // 2026-07-21 配置架构重构：删除 modelId/presetId 字段
      // （故事模式不再有"默认模型"中间层，改由 phase_models 分步骤配置）
      //  systemPrompt
      expect(config.systemPrompt, '你是海盗船长');

      // retrieval
      expect(config.retrieval.topK, 10);
      expect(config.retrieval.fts5Weight, 0.3);
      expect(config.retrieval.vectorWeight, 0.7);
      expect(config.retrieval.keyEventThreshold, 3);
      expect(config.retrieval.keyEventBoost, 2.0);
      expect(config.retrieval.normalizationEpsilon, 0.05);

      // context

      // retry
      expect(config.retry.generatingMaxRetries, 3);
      expect(config.retry.extractingMaxRetries, 3);
      expect(config.retry.retrievalMaxRetries, 2);
      expect(config.retry.reviewingMaxRetries, 3);
      expect(config.retry.summarizingMaxRetries, 3);
      expect(config.retry.streamInterruptRetry, 2);

      // embedding
      expect(config.embedding.timeoutMs, 10000);
      expect(config.embedding.fallbackOnFailure, false);
      expect(config.embedding.timeout, const Duration(milliseconds: 10000));

      // stream
      expect(config.stream.toolCallingEnabled, false);
      expect(config.stream.generatingSeparator, '<<<GENERATING>>>');
      expect(config.stream.eventSummarySeparator, '<<<SUMMARY>>>');
      expect(config.stream.jsonFallback, true);
      expect(config.stream.injectResponseFormat, true);
      expect(config.stream.skipReviewWhenEmptyRetrieval, false);
      expect(config.stream.generatingFoldDelayMs, 3000);
      expect(config.stream.retrievalFoldDelayMs, 500);

      //  fork
      expect(config.fork.regenerateWindowRounds, 10);
    });

    test('fromJson 空对象使用全部默认值', () {
      final config = IntermediateConfig.fromJson({});

      // 2026-07-21 配置架构重构：删除 modelId/presetId 字段
      //  systemPrompt 默认空串
      expect(config.systemPrompt, '');

      // retrieval 默认值（五路召回合并后统一截取 topK）
      expect(config.retrieval.topK, 12);
      expect(config.retrieval.fts5Weight, 0.5);
      expect(config.retrieval.vectorWeight, 0.5);
      // 2026-07-16 优化项6/7：keyEventThreshold 默认 999（永不触发），
      // keyEventBoost 默认 1.0（不加权），避免与 importanceWeight 功能重叠。
      expect(config.retrieval.keyEventThreshold, 999);
      expect(config.retrieval.keyEventBoost, 1.0);
      expect(config.retrieval.normalizationEpsilon, 0.01);

      // context 默认值
      expect(config.generation.maxTokens, 8192);

      // retry 默认值
      expect(config.retry.generatingMaxRetries, 5); // P5 上调后默认
      expect(config.retry.extractingMaxRetries, 5);
      expect(config.retry.retrievalMaxRetries, 5);
      expect(config.retry.reviewingMaxRetries, 5);
      expect(config.retry.summarizingMaxRetries, 5);
      expect(config.retry.streamInterruptRetry, 5);

      // embedding 默认值
      expect(config.embedding.timeoutMs, 5000);
      expect(config.embedding.fallbackOnFailure, false);

      // stream 默认值
      expect(config.stream.toolCallingEnabled, true); // 四步重构：默认启用工具调用
      expect(config.stream.generatingSeparator, '<<<KEYWORDS>>>');
      expect(config.stream.eventSummarySeparator, '<<<EVENT_SUMMARY>>>');
      expect(config.stream.jsonFallback, true); // 默认 true（JSON 稳定性）
      expect(config.stream.injectResponseFormat, true); // 默认 true
      expect(config.stream.skipReviewWhenEmptyRetrieval, true); // 兼容字段默认开启
      expect(config.stream.generatingFoldDelayMs, 2000);
      expect(config.stream.retrievalFoldDelayMs, 1000);

      //  fork 默认值
      expect(config.fork.regenerateWindowRounds, 5);
    });

    test('fromJson 部分缺失子组使用默认值', () {
      final json = <String, dynamic>{
        'retrieval': {
          'top_k': 8,
        },
        // context/retry/embedding/stream/fork 全缺
      };

      final config = IntermediateConfig.fromJson(json);

      expect(config.retrieval.topK, 8);
      expect(config.retrieval.fts5Weight, 0.5); // 默认
      expect(config.retry.generatingMaxRetries, 5); // 默认（P5 上调）
      expect(config.embedding.timeoutMs, 5000); // 默认
      expect(config.stream.jsonFallback, true); // 默认 true
      expect(config.stream.injectResponseFormat, true); // 默认 true
      expect(config.stream.skipReviewWhenEmptyRetrieval, true); // 兼容字段默认值
      expect(config.fork.regenerateWindowRounds, 5); //  默认
    });

    test('fromJson 处理 num 类型的 double 字段', () {
      final json = <String, dynamic>{
        'retrieval': {
          'fts5_weight': 1, // int 而非 double
          'vector_weight': 0,
        },
      };

      final config = IntermediateConfig.fromJson(json);

      expect(config.retrieval.fts5Weight, 1.0);
      expect(config.retrieval.vectorWeight, 0.0);
    });
  });

  group('EmbeddingConfig', () {
    test('timeout 便捷访问返回正确 Duration', () {
      const config = EmbeddingConfig(timeoutMs: 8000);
      expect(config.timeout, const Duration(milliseconds: 8000));
    });

    test('默认 timeout 为 5 秒', () {
      const config = EmbeddingConfig();
      expect(config.timeout, const Duration(seconds: 5));
    });
  });

  group('ForkConfig', () {
    test('默认 regenerateWindowRounds 为 5', () {
      const config = ForkConfig();
      expect(config.regenerateWindowRounds, 5);
    });

    test('fromJson 正确解析自定义窗口值', () {
      final config = ForkConfig.fromJson({'regenerate_window_rounds': 10});
      expect(config.regenerateWindowRounds, 10);
    });

    test('fromJson 空对象使用默认值 5', () {
      final config = ForkConfig.fromJson({});
      expect(config.regenerateWindowRounds, 5);
    });
  });

  group('PromptsConfig', () {
    test('V2 四步字段默认值取自 intermediate_prompts_v2 常量', () {
      const config = PromptsConfig();
      expect(config.generatingSuffixV2, kGeneratingSuffixPromptV2);
      expect(config.reviewSuffixV2, kReviewSuffixPromptV2);
      expect(config.extractKeywordsPrompt, kExtractKeywordsToolPrompt);
      expect(config.extractSummaryPrompt, kExtractSummaryToolPrompt);
    });

    test('fromJson 正确解析 V2 字段覆盖', () {
      final config = PromptsConfig.fromJson({
        'generating_suffix_v2': '自定义生成',
        'review_suffix_v2': '自定义审查',
        'extract_keywords_prompt': '自定义关键词',
        'extract_summary_prompt': '自定义摘要',
      });
      expect(config.generatingSuffixV2, '自定义生成');
      expect(config.reviewSuffixV2, '自定义审查');
      expect(config.extractKeywordsPrompt, '自定义关键词');
      expect(config.extractSummaryPrompt, '自定义摘要');
    });

    test('fromJson 空对象 V2 字段回落到常量默认值', () {
      final config = PromptsConfig.fromJson({});
      expect(config.generatingSuffixV2, kGeneratingSuffixPromptV2);
      expect(config.reviewSuffixV2, kReviewSuffixPromptV2);
      expect(config.extractKeywordsPrompt, kExtractKeywordsToolPrompt);
      expect(config.extractSummaryPrompt, kExtractSummaryToolPrompt);
    });

    test('旧版字段向后兼容（仍可解析，默认值取自旧常量）', () {
      final config = PromptsConfig.fromJson({});
      // 旧字段保留供控制器过渡期使用，Phase 6 标记 @Deprecated 后移除
      expect(config.draftSuffix, kDraftSuffixPrompt);
      expect(config.reviewSuffix, kReviseSuffixPrompt);
      expect(config.defaultRolePrompt, kDefaultRolePrompt);
      expect(config.generatedInjectionPrefix, kGeneratedInjectionPrefix);
      expect(config.memoriesInjectionTitle, kMemoriesInjectionTitle);
      expect(config.consolidationPrompt, kConsolidationPrompt);
    });

    test('default_config.json prompts 空对象回落到常量', () {
      // default_config.json 中 prompts 节点为 {} 时，所有字段缺失→null→常量默认值
      final config = PromptsConfig.fromJson({});
      expect(config.generatingSuffixV2, kGeneratingSuffixPromptV2);
      expect(config.reviewSuffixV2, kReviewSuffixPromptV2);
      expect(config.extractKeywordsPrompt, kExtractKeywordsToolPrompt);
      expect(config.extractSummaryPrompt, kExtractSummaryToolPrompt);
      expect(config.defaultRolePrompt, kDefaultRolePrompt);
    });
  });

  group('RetryConfig', () {
    test('默认 extractingMaxRetries/summarizingMaxRetries 为 2（四步重构）', () {
      const config = RetryConfig();
      expect(config.generatingMaxRetries, 5); // P5 上调后默认
      expect(config.extractingMaxRetries, 5);
      expect(config.retrievalMaxRetries, 5);
      expect(config.reviewingMaxRetries, 5);
      expect(config.summarizingMaxRetries, 5);
      expect(config.streamInterruptRetry, 5);
    });

    test('fromJson 正确解析 extracting/summarizing 重试覆盖', () {
      final config = RetryConfig.fromJson({
        'extracting_max_retries': 5,
        'summarizing_max_retries': 4,
      });
      expect(config.extractingMaxRetries, 5);
      expect(config.summarizingMaxRetries, 4);
      // 未提供的字段回落默认（P5 上调后 5）
      expect(config.generatingMaxRetries, 5);
      expect(config.reviewingMaxRetries, 5);
    });

    test('fromJson 空对象全部回落默认', () {
      final config = RetryConfig.fromJson({});
      expect(config.extractingMaxRetries, 5); // P5 上调后默认
      expect(config.summarizingMaxRetries, 5);
    });
  });

  group('StreamConfig', () {
    test('默认 toolCallingEnabled 为 true（四步重构）', () {
      const config = StreamConfig();
      expect(config.toolCallingEnabled, true);
      expect(config.jsonFallback, true);
      expect(config.injectResponseFormat, true);
      expect(config.skipReviewWhenEmptyRetrieval, true);
    });

    test('fromJson 正确解析 tool_calling_enabled 覆盖', () {
      final config = StreamConfig.fromJson({
        'tool_calling_enabled': false,
      });
      expect(config.toolCallingEnabled, false);
      // 未提供的字段回落默认
      expect(config.jsonFallback, true);
      expect(config.generatingFoldDelayMs, 2000);
    });

    test('fromJson 空对象 toolCallingEnabled 回落默认 true', () {
      final config = StreamConfig.fromJson({});
      expect(config.toolCallingEnabled, true);
    });
  });
  group('ContextBudget.fromJson 触发线病态防御', () {
    test('≤0 或 ≥1 的手改值回落默认 0.5（≤0 会静默禁用轮前压缩）', () {
      expect(
        ContextBudget.fromJson({'compactionTriggerRatio': 0})
            .compactionTriggerRatio,
        0.5,
      );
      expect(
        ContextBudget.fromJson({'compactionTriggerRatio': -0.2})
            .compactionTriggerRatio,
        0.5,
      );
      expect(
        ContextBudget.fromJson({'compactionTriggerRatio': 1.0})
            .compactionTriggerRatio,
        0.5,
      );
    });

    test('合法域内值（含 <0.30 存量值）原样保留，故事侧合法域不受钳制', () {
      expect(
        ContextBudget.fromJson({'compactionTriggerRatio': 0.2})
            .compactionTriggerRatio,
        0.2,
      );
      expect(
        ContextBudget.fromJson({'compactionTriggerRatio': 0.55})
            .compactionTriggerRatio,
        0.55,
      );
      expect(
        ContextBudget.fromJson({}).compactionTriggerRatio,
        0.5,
        reason: '缺键回落默认',
      );
    });
  });
}
