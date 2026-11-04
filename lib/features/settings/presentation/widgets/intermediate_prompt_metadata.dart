import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/config/intermediate_prompts.dart';
import 'package:lmstory/core/config/intermediate_prompts_v2.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式提示词字段元数据（Phase 6 流程重构）。
///
/// 定义 10 段可编辑提示词的元信息：字段 key、默认值、使用场景说明。
/// 被以下组件消费：
/// - IntermediatePromptsSection：渲染 tile 列表
/// - IntermediatePromptEditorPage：渲染编辑器标题 + 使用场景
///
/// 设计：
/// - fieldKey 与 default_config.json 的 `intermediate.prompts.*` 子键一致
/// - overrideKey 是 SettingsRepository 的扁平 key（如 `intermediate.prompts.generating_suffix_v2`）
/// - defaultValue 取自 `intermediate_prompts_v2.dart`（V2 常量）与
///   `intermediate_prompts.dart`（共享常量）
/// - title/desc/usage 通过 i18n 访问，支持本地化
class PromptFieldMeta {
  const PromptFieldMeta({
    required this.fieldKey,
    required this.defaultValue,
  });

  /// 字段 key（snake_case，与 default_config.json 子键一致）
  final String fieldKey;

  /// 内置默认值（取自 intermediate_prompts.dart 常量）
  final String defaultValue;

  /// SettingsRepository 扁平 key（如 `intermediate.prompts.draft_suffix`）
  String get overrideKey => 'intermediate.prompts.$fieldKey';

  /// Resolve this field from the current configuration. Keeping the mapping
  /// beside [fieldKey] prevents the list and editor from drifting apart when
  /// prompt keys are renamed.
  String currentValue(PromptsConfig prompts) {
    switch (fieldKey) {
      case 'default_role_prompt':
        return prompts.defaultRolePrompt;
      case 'generating_suffix_v2':
        return prompts.generatingSuffixV2;
      case 'extract_keywords_prompt':
        return prompts.extractKeywordsPrompt;
      case 'review_suffix_v2':
        return prompts.reviewSuffixV2;
      case 'extract_summary_prompt':
        return prompts.extractSummaryPrompt;
      case 'generated_injection_prefix':
        return prompts.generatedInjectionPrefix;
      case 'memories_injection_title':
        return prompts.memoriesInjectionTitle;
      case 'consolidation_prompt':
        return prompts.consolidationPrompt;
      case 'extract_facts_prompt':
        return prompts.extractFactsPrompt;
      case 'fact_injection_title':
        return prompts.factInjectionTitle;
      default:
        return defaultValue;
    }
  }

  /// i18n 标题
  String title(Translations t) {
    final f = t.settings.intermediate.prompts.fields;
    switch (fieldKey) {
      case 'default_role_prompt':
        return f.defaultRolePrompt.title;
      case 'generating_suffix_v2':
        return f.generatingSuffixV2.title;
      case 'extract_keywords_prompt':
        return f.extractKeywordsPrompt.title;
      case 'review_suffix_v2':
        return f.reviewSuffixV2.title;
      case 'extract_summary_prompt':
        return f.extractSummaryPrompt.title;
      case 'generated_injection_prefix':
        return f.generatedInjectionPrefix.title;
      case 'memories_injection_title':
        return f.memoriesInjectionTitle.title;
      case 'consolidation_prompt':
        return f.consolidationPrompt.title;
      case 'extract_facts_prompt':
        return f.extractFactsPrompt.title;
      case 'fact_injection_title':
        return f.factInjectionTitle.title;
      default:
        return fieldKey;
    }
  }

  /// i18n 描述
  String desc(Translations t) {
    final f = t.settings.intermediate.prompts.fields;
    switch (fieldKey) {
      case 'default_role_prompt':
        return f.defaultRolePrompt.desc;
      case 'generating_suffix_v2':
        return f.generatingSuffixV2.desc;
      case 'extract_keywords_prompt':
        return f.extractKeywordsPrompt.desc;
      case 'review_suffix_v2':
        return f.reviewSuffixV2.desc;
      case 'extract_summary_prompt':
        return f.extractSummaryPrompt.desc;
      case 'generated_injection_prefix':
        return f.generatedInjectionPrefix.desc;
      case 'memories_injection_title':
        return f.memoriesInjectionTitle.desc;
      case 'consolidation_prompt':
        return f.consolidationPrompt.desc;
      case 'extract_facts_prompt':
        return f.extractFactsPrompt.desc;
      case 'fact_injection_title':
        return f.factInjectionTitle.desc;
      default:
        return '';
    }
  }

  /// i18n 使用场景
  String usage(Translations t) {
    final f = t.settings.intermediate.prompts.fields;
    switch (fieldKey) {
      case 'default_role_prompt':
        return f.defaultRolePrompt.usage;
      case 'generating_suffix_v2':
        return f.generatingSuffixV2.usage;
      case 'extract_keywords_prompt':
        return f.extractKeywordsPrompt.usage;
      case 'review_suffix_v2':
        return f.reviewSuffixV2.usage;
      case 'extract_summary_prompt':
        return f.extractSummaryPrompt.usage;
      case 'generated_injection_prefix':
        return f.generatedInjectionPrefix.usage;
      case 'memories_injection_title':
        return f.memoriesInjectionTitle.usage;
      case 'consolidation_prompt':
        return f.consolidationPrompt.usage;
      case 'extract_facts_prompt':
        return f.extractFactsPrompt.usage;
      case 'fact_injection_title':
        return f.factInjectionTitle.usage;
      default:
        return '';
    }
  }
}

/// 10 段提示词的完整元数据列表（顺序固定，按当前生成流程排列）。
///
/// 顺序对应生成流程 + 事实层扩展：
/// 1. default_role_prompt - 共享前缀（角色设定）
/// 2. generating_suffix_v2 - generating 步骤后缀（纯文本生成）
/// 3. extract_keywords_prompt - extracting 步骤（关键词提取）
/// 4. review_suffix_v2 - reviewing 步骤后缀（纯文本审查）
/// 5. extract_summary_prompt - summarizing 步骤（事件摘要）
/// 6. generated_injection_prefix - reviewing 步骤生成内容注入前缀
/// 7. memories_injection_title - reviewing 步骤记忆注入标题
/// 8. consolidation_prompt - 记忆提炼提示词
/// 9. extract_facts_prompt - summarizing 步骤事实层提示（DOC-11 §4.4 双工具并行）
/// 10. fact_injection_title - reviewing 步骤世界设定注入标题（DOC-11 §3.6）
const List<PromptFieldMeta> promptFieldMetas = [
  PromptFieldMeta(
    fieldKey: 'default_role_prompt',
    defaultValue: kDefaultRolePrompt,
  ),
  PromptFieldMeta(
    fieldKey: 'generating_suffix_v2',
    defaultValue: kGeneratingSuffixPromptV2,
  ),
  PromptFieldMeta(
    fieldKey: 'extract_keywords_prompt',
    defaultValue: kExtractKeywordsToolPrompt,
  ),
  PromptFieldMeta(
    fieldKey: 'review_suffix_v2',
    defaultValue: kReviewSuffixPromptV2,
  ),
  PromptFieldMeta(
    fieldKey: 'extract_summary_prompt',
    defaultValue: kExtractSummaryToolPrompt,
  ),
  PromptFieldMeta(
    fieldKey: 'generated_injection_prefix',
    defaultValue: kGeneratedInjectionPrefix,
  ),
  PromptFieldMeta(
    fieldKey: 'memories_injection_title',
    defaultValue: kMemoriesInjectionTitle,
  ),
  PromptFieldMeta(
    fieldKey: 'consolidation_prompt',
    defaultValue: kConsolidationPrompt,
  ),
  PromptFieldMeta(
    fieldKey: 'extract_facts_prompt',
    defaultValue: kExtractFactsToolPrompt,
  ),
  PromptFieldMeta(
    fieldKey: 'fact_injection_title',
    defaultValue: kFactInjectionTitle,
  ),
];
