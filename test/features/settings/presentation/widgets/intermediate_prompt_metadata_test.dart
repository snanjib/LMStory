import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/features/settings/presentation/widgets/intermediate_prompt_metadata.dart';

void main() {
  test('10 个提示词元数据 key 均映射到当前 PromptsConfig 字段', () {
    const prompts = PromptsConfig(
      defaultRolePrompt: 'role',
      generatingSuffixV2: 'generating',
      extractKeywordsPrompt: 'keywords',
      reviewSuffixV2: 'review',
      extractSummaryPrompt: 'summary',
      generatedInjectionPrefix: 'generated-prefix',
      memoriesInjectionTitle: 'memories-title',
      consolidationPrompt: 'consolidation',
      extractFactsPrompt: 'facts',
      factInjectionTitle: 'facts-title',
    );

    final values = {
      for (final meta in promptFieldMetas)
        meta.fieldKey: meta.currentValue(prompts),
    };

    expect(values, hasLength(10));
    expect(values, {
      'default_role_prompt': 'role',
      'generating_suffix_v2': 'generating',
      'extract_keywords_prompt': 'keywords',
      'review_suffix_v2': 'review',
      'extract_summary_prompt': 'summary',
      'generated_injection_prefix': 'generated-prefix',
      'memories_injection_title': 'memories-title',
      'consolidation_prompt': 'consolidation',
      'extract_facts_prompt': 'facts',
      'fact_injection_title': 'facts-title',
    });
  });
}
