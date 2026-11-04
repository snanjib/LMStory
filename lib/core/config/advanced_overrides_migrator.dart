import 'dart:convert';

import 'package:lmstory/core/storage/preferences.dart';

/// 分家一次性迁移：把导演此前寄生消费的 intermediate.* overrides 复制为
/// advanced.*（原键保留给故事模式），保证解耦零行为变化（设计文档 §8.1）。
///
/// 迁移标记存 SharedPreferences（advanced_overrides_migrated），仅首次启动
/// 执行；复制不覆盖已存在的 advanced.* 键（用户已自行配置的优先）。
///
/// 上下文配置收敛：另带一次性 stale 键清理
/// （[cleanupStaleContextBudgetKeys]）——advanced.contextBudget 的
/// recentMinRatio/retrievalRatio 两键已从产品面与默认配置移除（组装侧
/// 定死），全局 override 存储里的存量值不再有消费点，随迁移一并清除。
class AdvancedOverridesMigrator {
  AdvancedOverridesMigrator(this._prefs);

  static const _flagKey = 'advanced_overrides_migrated';
  static const _overridesKey = 'user_overrides';
  static const _staleContextBudgetFlagKey =
      'advanced_context_budget_stale_keys_cleaned';

  /// 精确键映射：intermediate 键 → advanced 键（设计文档第 4 节键表）。
  ///
  /// 上下文配置收敛：contextBudget.recentMinRatio/retrievalRatio 两映射
  /// 摘除——advanced 侧两键已死，复制只会再生成 stale 键。
  static const Map<String, String> _keyMapping = {
    'intermediate.system_prompt': 'advanced.system_prompt',
    'intermediate.generation.temperature': 'advanced.generation.temperature',
    'intermediate.generation.top_p': 'advanced.generation.top_p',
    'intermediate.generation.max_tokens': 'advanced.generation.max_tokens',
    'intermediate.generation.presence_penalty':
        'advanced.generation.presence_penalty',
    'intermediate.generation.frequency_penalty':
        'advanced.generation.frequency_penalty',
    'intermediate.generation.reasoning_effort':
        'advanced.generation.reasoning_effort',
    'intermediate.phase_models.generating_preset_id':
        'advanced.phase_models.generating_preset_id',
    'intermediate.phase_models.generating_model_id':
        'advanced.phase_models.generating_model_id',
    'intermediate.contextBudget.compactionTriggerRatio':
        'advanced.contextBudget.compactionTriggerRatio',
    'intermediate.context.effective_context_limit':
        'advanced.context.effective_context_limit',
    'intermediate.stream.tool_calling_enabled':
        'advanced.stream.tool_calling_enabled',
    'intermediate.embedding_preset_id': 'advanced.embedding_preset_id',
    'intermediate.embedding_model_id': 'advanced.embedding_model_id',
    'intermediate.embedding.timeout_ms': 'advanced.embedding.timeout_ms',
    'intermediate.embedding.fallback_on_failure':
        'advanced.embedding.fallback_on_failure',
    'intermediate.reviewEnabled': 'advanced.review_enabled',
    'intermediate.suggest_reply.preset_id': 'advanced.suggest_reply.preset_id',
    'intermediate.suggest_reply.model_id': 'advanced.suggest_reply.model_id',
    'intermediate.suggest_reply.prompt': 'advanced.suggest_reply.prompt',
    'intermediate.suggest_reply.temperature':
        'advanced.suggest_reply.temperature',
    'intermediate.suggest_reply.max_tokens':
        'advanced.suggest_reply.max_tokens',
    'intermediate.suggest_reply.candidate_count':
        'advanced.suggest_reply.candidate_count',
    'intermediate.suggest_reply.max_reply_length':
        'advanced.suggest_reply.max_reply_length',
  };

  /// 前缀级映射：命中前缀即复制（advanced 侧子段名相同，仅换顶层段前缀
  /// intermediate. → advanced.）
  static const List<String> _prefixMapping = [
    'intermediate.memory.',
    'intermediate.consolidation.',
    'intermediate.retrieval.',
    'intermediate.prompts.',
  ];

  final Preferences _prefs;

  /// 执行迁移。返回是否实际执行了本次检查（false = 已迁移过，跳过）。
  Future<bool> runIfNeeded() async {
    final flag = await _prefs.getString(_flagKey);
    if (flag != null && flag.isNotEmpty) return false;
    final raw = await _prefs.getString(_overridesKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          final next = Map<String, dynamic>.from(decoded);
          var changed = false;
          decoded.forEach((key, value) {
            if (value is Map) return; // SP 覆盖均为标量叶子
            final mapped = _mappedKey(key);
            if (mapped != null && !next.containsKey(mapped)) {
              next[mapped] = value;
              changed = true;
            }
          });
          if (changed) {
            await _prefs.setString(_overridesKey, jsonEncode(next));
          }
        }
      } on FormatException {
        // user_overrides 损坏：跳过复制，只落迁移标记（原值不覆盖）
      }
    }
    await _prefs.setString(_flagKey, '1');
    return true;
  }

  /// 一次性清理全局 override 存储中的 stale 上下文预算键
  ///（advanced.contextBudget.recentMinRatio / retrievalRatio）。
  ///
  /// 上下文配置收敛：两键已无消费点（组装侧定死、UI 移除、
  /// 默认配置摘除）。仅清全局 override 存储；会话列对应 override 不动库
  ///（无 schema 变更原则，存量值 inert）。独立标记保证已迁移过的老安装
  /// 也能补清。
  Future<void> cleanupStaleContextBudgetKeys() async {
    final flag = await _prefs.getString(_staleContextBudgetFlagKey);
    if (flag != null && flag.isNotEmpty) return;
    final raw = await _prefs.getString(_overridesKey);
    if (raw != null && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          final removed =
              _staleContextBudgetKeys.where(decoded.containsKey).toList();
          if (removed.isNotEmpty) {
            final next = Map<String, dynamic>.from(decoded)
              ..removeWhere((key, _) => _staleContextBudgetKeys.contains(key));
            await _prefs.setString(_overridesKey, jsonEncode(next));
          }
        }
      } on FormatException {
        // user_overrides 损坏：跳过清理，只落标记（原值不覆盖）
      }
    }
    await _prefs.setString(_staleContextBudgetFlagKey, '1');
  }

  static const Set<String> _staleContextBudgetKeys = {
    'advanced.contextBudget.recentMinRatio',
    'advanced.contextBudget.retrievalRatio',
  };

  static String? _mappedKey(String key) {
    final exact = _keyMapping[key];
    if (exact != null) return exact;
    for (final prefix in _prefixMapping) {
      if (key.startsWith(prefix)) {
        // 整段前缀替换：intermediate.memory.factual.enabled
        //   → advanced.memory.factual.enabled（子段名保留）
        return 'advanced.${key.substring('intermediate.'.length)}';
      }
    }
    return null;
  }
}
