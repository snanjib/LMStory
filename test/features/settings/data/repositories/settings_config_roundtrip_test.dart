import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/settings/data/datasources/api_key_datasource.dart';
import 'package:lmstory/features/settings/data/repositories/settings_repository_impl.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 配置合并基底守门测试
///
/// _configToMap 是"用户覆盖 × 默认配置"的合并基底：任何在
/// default_config.json 中存在、但 _configToMap 不再产出的键，会在
/// 存在任意用户覆盖时静默丢失（fromJson 回落 Dart 构造默认值）——
///  修复当天就漏了 generation 节点。本测试逐叶子路径比对 JSON 与
/// 合并基底，防止未来新增配置节点时再次断裂。
///
/// 2026-08-27 导演设置体系：advanced 段纳入同款守门（walk + 全叶子
/// override 深合并往返，设计文档 §8.2）。
void main() {
  test('合并基底覆盖 default_config.json 的全部配置键（排除 prompts）', () async {
    final jsonMap = jsonDecode(
      File('assets/configs/default_config.json').readAsStringSync(),
    ) as Map<String, dynamic>;

    final repo = await _buildRepo();

    final base = repo.configToMapForTest(AppConfig.fromJson(jsonMap));

    // prompts 子树按设计只持久化用户显式覆盖（缺省回落常量），排除
    final missing = <String>[];
    void walk(Map<String, dynamic> node, String path) {
      for (final entry in node.entries) {
        final keyPath = path.isEmpty ? entry.key : '$path.${entry.key}';
        if (entry.value is Map<String, dynamic>) {
          walk(entry.value as Map<String, dynamic>, keyPath);
        } else if (identical(baseLookup(base, keyPath), _missing)) {
          missing.add(keyPath);
        }
      }
    }

    walk(jsonMap['intermediate'] as Map<String, dynamic>, 'intermediate');
    walk(jsonMap['advanced'] as Map<String, dynamic>, 'advanced');
    // 守门扩到 broadcast_chat/network/common 三节点
    //（此前盲区——这三段新增/改名键时同样会被 _configToMap 静默丢掉）
    walk(jsonMap['broadcast_chat'] as Map<String, dynamic>, 'broadcast_chat');
    walk(jsonMap['network'] as Map<String, dynamic>, 'network');
    walk(jsonMap['common'] as Map<String, dynamic>, 'common');

    expect(
      missing,
      isEmpty,
      reason: '以下 JSON 配置键不在合并基底中，存在用户覆盖时会静默丢失',
    );
  });

  test('advanced 全叶子 override 深合并后经 fromJson 逐叶子存活', () async {
    final jsonMap = jsonDecode(
      File('assets/configs/default_config.json').readAsStringSync(),
    ) as Map<String, dynamic>;

    final repo = await _buildRepo();

    // 含 advanced 全叶子键的 override（含 tools 三态），复刻
    // setUserOverride 的扁平 key → _expandFlatKeys → _deepMerge 管线
    const overrides = <String, dynamic>{
      'advanced.system_prompt': '导演全局规则',
      'advanced.phase_models.generating_preset_id': 'p1',
      'advanced.phase_models.generating_model_id': 'm1',
      'advanced.generation.temperature': 1.1,
      'advanced.generation.top_p': 0.9,
      'advanced.generation.max_tokens': 4096,
      'advanced.generation.presence_penalty': 0.2,
      'advanced.generation.frequency_penalty': 0.1,
      'advanced.generation.reasoning_effort': 'low',
      'advanced.defaults.max_steps': 12,
      'advanced.budget.max_duration_minutes': 9,
      'advanced.budget.token_budget_ratio': 0.7,
      'advanced.budget.max_request_retries': 2,
      'advanced.doom_loop.threshold': 5,
      'advanced.hitl.ask_user_timeout_minutes': 8,
      'advanced.hitl.approval_timeout_minutes': 4,
      'advanced.subagent.max_steps': 3,
      'advanced.subagent.max_duration_minutes': 6,
      // harness 段此前整体缺席 override 表——
      // event_log_retention_turns 写侧齐全而 fromJson 漏解析，死键第 5 次
      // 断裂。harness 全键纳入「override 存活」守门。
      'advanced.harness.tool_output_limit': 12345,
      'advanced.harness.tool_timeout_seconds': 77,
      'advanced.harness.core_blocks_in_tail': false,
      'advanced.harness.full_chunk_events': true,
      'advanced.harness.foreshadow_check_interval': 3,
      'advanced.harness.event_log_retention_turns': 50,
      'advanced.harness.maintenance_gap_interval': 9,
      'advanced.harness.maintenance_nudge_cooldown': 5,
      'advanced.harness.major_review_interval': 40,
      'advanced.harness.maintenance_extra_steps': 8,
      'advanced.harness.recent_active_entities_window': 20,
      'advanced.harness.recent_active_entities_cap': 12,
      'advanced.context.effective_context_limit': 65536,
      'advanced.contextBudget.compactionTriggerRatio': 0.4,
      // 上下文配置收敛：recentMinRatio/retrievalRatio 已从
      // advanced 段移除（组装侧定死，导出 map 不再产出）；override 残值
      // 由值类解析兜底但 inert，不纳入存活守门
      'advanced.contextBudget.recentMinTokenTarget': 16000,
      'advanced.tools.spawn': 'deny',
      'advanced.tools.update_facts': 'ask',
      'advanced.narrative_pacing': 'conservative',
      'advanced.embedding_preset_id': 'pe',
      'advanced.embedding_model_id': 'me',
      'advanced.embedding.timeout_ms': 8000,
      'advanced.embedding.fallback_on_failure': true,
      'advanced.memory.factual.enabled': false,
      'advanced.memory.factual.key_entity_importance_threshold': 6,
      'advanced.memory.factual.key_entity_auto_cap': 7,
      'advanced.memory.factual.injection_max_entities': 10,
      'advanced.memory.factual.force_inject_safety_cap': 40,
      'advanced.memory.factual.modify_confidence_threshold': 3,
      'advanced.memory.factual.max_updates_per_3turns': 2,
      'advanced.memory.factual.max_attr_value_length': 300,
      'advanced.consolidation.trigger_threshold': 0.9,
      'advanced.consolidation.min_artifacts_to_consolidate': 4,
      'advanced.consolidation.max_artifacts_to_consolidate': 15,
      // 2026-08-29 审查 ：advanced.retrieval 仅保留导演运行时消费的双门槛两键
      'advanced.retrieval.importance_storage_threshold': 2,
      'advanced.retrieval.micro_vectorize_threshold': 5,
      'advanced.suggest_reply.preset_id': 'ps',
      'advanced.suggest_reply.model_id': 'ms',
      'advanced.suggest_reply.prompt': '自定义提示词',
      'advanced.suggest_reply.temperature': 0.7,
      'advanced.suggest_reply.max_tokens': 500,
      'advanced.suggest_reply.candidate_count': 2,
      'advanced.suggest_reply.max_reply_length': 100,
      'advanced.review_enabled': true,
      'advanced.prompts.consolidation_prompt': '自定义归并提示词',
    };

    final merged = repo.configToMapForTest(AppConfig.fromJson(jsonMap));
    deepMerge(merged, expandFlatKeys(overrides));
    final cfg = AppConfig.fromJson(merged);

    expect(cfg.advanced.systemPrompt, '导演全局规则');
    expect(cfg.advanced.generatingPresetId, 'p1');
    expect(cfg.advanced.generatingModelId, 'm1');
    expect(cfg.advanced.generation.temperature, 1.1);
    expect(cfg.advanced.generation.topP, 0.9);
    expect(cfg.advanced.generation.maxTokens, 4096);
    expect(cfg.advanced.generation.presencePenalty, 0.2);
    expect(cfg.advanced.generation.frequencyPenalty, 0.1);
    expect(cfg.advanced.generation.reasoningEffort, 'low');
    expect(cfg.advanced.defaults.maxSteps, 12);
    expect(cfg.advanced.budget.maxDurationMinutes, 9);
    expect(cfg.advanced.budget.tokenBudgetRatio, 0.7);
    expect(cfg.advanced.budget.maxRequestRetries, 2);
    expect(cfg.advanced.doomLoop.threshold, 5);
    expect(cfg.advanced.hitl.askUserTimeoutMinutes, 8);
    expect(cfg.advanced.hitl.approvalTimeoutMinutes, 4);
    expect(cfg.advanced.subagent.maxSteps, 3);
    expect(cfg.advanced.subagent.maxDurationMinutes, 6);
    expect(cfg.advanced.harness.toolOutputLimit, 12345);
    expect(cfg.advanced.harness.toolTimeoutSeconds, 77);
    expect(cfg.advanced.harness.coreBlocksInTail, isFalse);
    expect(cfg.advanced.harness.fullChunkEvents, isTrue);
    expect(cfg.advanced.harness.foreshadowCheckInterval, 3);
    expect(cfg.advanced.harness.eventLogRetentionTurns, 50);
    expect(cfg.advanced.harness.maintenanceGapInterval, 9);
    expect(cfg.advanced.harness.maintenanceNudgeCooldown, 5);
    expect(cfg.advanced.harness.majorReviewInterval, 40);
    expect(cfg.advanced.harness.maintenanceExtraSteps, 8);
    expect(cfg.advanced.harness.recentActiveEntitiesWindow, 20);
    expect(cfg.advanced.harness.recentActiveEntitiesCap, 12);
    expect(cfg.advanced.context.effectiveContextLimit, 65536);
    expect(cfg.advanced.contextBudget.compactionTriggerRatio, 0.4);
    expect(cfg.advanced.contextBudget.recentMinTokenTarget, 16000);
    expect(cfg.advanced.tools['spawn'], 'deny');
    expect(cfg.advanced.tools['update_facts'], 'ask');
    expect(cfg.advanced.embeddingPresetId, 'pe');
    expect(cfg.advanced.embeddingModelId, 'me');
    expect(cfg.advanced.embedding.timeoutMs, 8000);
    expect(cfg.advanced.embedding.fallbackOnFailure, isTrue);
    expect(cfg.advanced.memory.factual.enabled, isFalse);
    expect(cfg.advanced.memory.factual.keyEntityImportanceThreshold, 6);
    expect(cfg.advanced.memory.factual.keyEntityAutoCap, 7);
    expect(cfg.advanced.memory.factual.injectionMaxEntities, 10);
    expect(cfg.advanced.memory.factual.forceInjectSafetyCap, 40);
    expect(cfg.advanced.memory.factual.modifyConfidenceThreshold, 3);
    expect(cfg.advanced.memory.factual.maxUpdatesPer3Turns, 2);
    expect(
      AppConfig.fromJson(jsonMap).advanced.memory.factual.maxAttrValueLength,
      1000,
    );
    expect(cfg.advanced.memory.factual.maxAttrValueLength, 300);
    expect(cfg.advanced.consolidation.triggerThreshold, 0.9);
    expect(cfg.advanced.consolidation.minArtifactsToConsolidate, 4);
    expect(cfg.advanced.consolidation.maxArtifactsToConsolidate, 15);
    expect(cfg.advanced.retrieval.importanceStorageThreshold, 2);
    expect(cfg.advanced.retrieval.microVectorizeThreshold, 5);
    expect(cfg.advanced.suggestReply.presetId, 'ps');
    expect(cfg.advanced.suggestReply.modelId, 'ms');
    expect(cfg.advanced.suggestReply.prompt, '自定义提示词');
    expect(cfg.advanced.suggestReply.temperature, 0.7);
    expect(cfg.advanced.suggestReply.maxTokens, 500);
    expect(cfg.advanced.suggestReply.candidateCount, 2);
    expect(cfg.advanced.suggestReply.maxReplyLength, 100);
    expect(cfg.advanced.reviewEnabled, isTrue);
    expect(cfg.advanced.prompts.consolidationPrompt, '自定义归并提示词');
    // 基底不受 override 污染（同一 repo 实例二次序列化仍为默认值）
    expect(
      repo.configToMapForTest(AppConfig.fromJson(jsonMap))['advanced']
          is Map<String, dynamic>,
      isTrue,
    );
  });

  // 上下文配置收敛：advanced.contextBudget 三方逐叶——
  // JSON ↔ 写侧键集一致性（三段式遗产两键已从产品面移除；导出 map
  // 若再产出死键在此红）
  test('advanced.contextBudget 写侧键集与 JSON 一致（死键守门）', () async {
    final jsonMap = jsonDecode(
      File('assets/configs/default_config.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final jsonBudget = (jsonMap['advanced']
        as Map<String, dynamic>)['contextBudget'] as Map<String, dynamic>;

    final repo = await _buildRepo();
    final base = repo.configToMapForTest(AppConfig.fromJson(jsonMap));
    final baseBudget = (base['advanced']
        as Map<String, dynamic>)['contextBudget'] as Map<String, dynamic>;

    expect(
      baseBudget.keys.toSet(),
      jsonBudget.keys.toSet(),
      reason:
          'advanced.contextBudget 写侧与 default_config.json 键集不一致——新增/移除键时须同步 _configToMap 与本测试',
    );
    for (final key in jsonBudget.keys) {
      expect(
        baseBudget[key],
        jsonBudget[key],
        reason: '合并基底 advanced.contextBudget.$key 与 JSON 默认值不一致',
      );
    }
  });

  // 改进设想①：三方逐叶比对——JSON 默认 ↔ _configToMap
  // 写侧 ↔ fromJson 读回。此前的守门只比「JSON ↔ 写侧」，「写侧齐、读侧漏」
  // （fromJson 漏键）无机械守护；本测试对 harness 段全键做 override 后
  // fromJson 读回断言，新增 harness 键漏解析即红。
  test('harness 段三方逐叶比对：JSON ↔ _configToMap ↔ fromJson 读回', () async {
    final jsonMap = jsonDecode(
      File('assets/configs/default_config.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final jsonHarness = (jsonMap['advanced'] as Map<String, dynamic>)['harness']
        as Map<String, dynamic>;

    final repo = await _buildRepo();
    final base = repo.configToMapForTest(AppConfig.fromJson(jsonMap));
    final baseHarness = (base['advanced'] as Map<String, dynamic>)['harness']
        as Map<String, dynamic>;

    // ① 写侧：_configToMap 对 JSON harness 段逐叶子产出，键集一致
    expect(
      baseHarness.keys.toSet(),
      jsonHarness.keys.toSet(),
      reason:
          'harness 合并基底与 default_config.json 键集不一致，新增/删除配置键时须同步 _configToMap',
    );

    // ③ 基底一致（值级）：写侧对 JSON 默认逐叶子取值相同
    for (final key in jsonHarness.keys) {
      expect(
        baseHarness[key],
        jsonHarness[key],
        reason: '合并基底 advanced.harness.$key 与 JSON 默认值不一致',
      );
    }

    // ② 读侧：每个键 override 非默认值 → 深合并 → fromJson 读回必须等于
    //    override 值（写侧可写、读侧必须可读，防死键复发）
    const overrides = <String, Object>{
      'advanced.harness.tool_output_limit': 12345,
      'advanced.harness.tool_timeout_seconds': 77,
      'advanced.harness.core_blocks_in_tail': false,
      'advanced.harness.full_chunk_events': true,
      'advanced.harness.foreshadow_check_interval': 3,
      'advanced.harness.event_log_retention_turns': 50,
      'advanced.harness.maintenance_gap_interval': 9,
      'advanced.harness.maintenance_nudge_cooldown': 5,
      'advanced.harness.major_review_interval': 40,
      'advanced.harness.maintenance_extra_steps': 8,
      'advanced.harness.recent_active_entities_window': 20,
      'advanced.harness.recent_active_entities_cap': 12,
    };
    final merged = repo.configToMapForTest(AppConfig.fromJson(jsonMap));
    deepMerge(merged, expandFlatKeys(overrides));
    final harness = AppConfig.fromJson(merged).advanced.harness;

    // snake_case JSON 键 → fromJson 读回值（漏写断言的新键在此红）
    final readback = <String, Object>{
      'tool_output_limit': harness.toolOutputLimit,
      'tool_timeout_seconds': harness.toolTimeoutSeconds,
      'core_blocks_in_tail': harness.coreBlocksInTail,
      'full_chunk_events': harness.fullChunkEvents,
      'foreshadow_check_interval': harness.foreshadowCheckInterval,
      'event_log_retention_turns': harness.eventLogRetentionTurns,
      'maintenance_gap_interval': harness.maintenanceGapInterval,
      'maintenance_nudge_cooldown': harness.maintenanceNudgeCooldown,
      'major_review_interval': harness.majorReviewInterval,
      'maintenance_extra_steps': harness.maintenanceExtraSteps,
      'recent_active_entities_window': harness.recentActiveEntitiesWindow,
      'recent_active_entities_cap': harness.recentActiveEntitiesCap,
    };
    for (final key in jsonHarness.keys) {
      expect(
        readback.keys,
        contains(key),
        reason: 'harness 键 $key 缺少读回断言——新增配置键时须同步本测试',
      );
      expect(
        readback[key],
        overrides['advanced.harness.$key'],
        reason:
            'override advanced.harness.$key 后 fromJson 读回值不一致，读侧漏解析=死键（用户覆盖静默失效）',
      );
    }
  });

  test('B9：broadcast_chat.max_tokens 真 null——缺省 null 往返 + override 后回落 null',
      () async {
    final jsonMap = jsonDecode(
      File('assets/configs/default_config.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final repo = await _buildRepo();

    // 1. 缺省（default_config.json 已删 max_tokens）：基底带 null 值键，
    //    合并任一无关 override 后经 fromJson 仍是 null（由模型决定）
    final merged = repo.configToMapForTest(AppConfig.fromJson(jsonMap));
    deepMerge(merged, expandFlatKeys({'broadcast_chat.temperature': 0.9}));
    expect(AppConfig.fromJson(merged).broadcastChat.maxTokens, isNull);

    // 2. 用户设值 → 存活
    final merged2 = repo.configToMapForTest(AppConfig.fromJson(jsonMap));
    deepMerge(merged2, expandFlatKeys({'broadcast_chat.max_tokens': 2048}));
    expect(AppConfig.fromJson(merged2).broadcastChat.maxTokens, 2048);

    // 3. 显式 0（无上限哨兵）透传，不回退任何数值
    final merged3 = repo.configToMapForTest(AppConfig.fromJson(jsonMap));
    deepMerge(merged3, expandFlatKeys({'broadcast_chat.max_tokens': 0}));
    expect(AppConfig.fromJson(merged3).broadcastChat.maxTokens, 0);
  });
}

Future<SettingsRepositoryImpl> _buildRepo() async {
  SharedPreferences.setMockInitialValues({});
  return SettingsRepositoryImpl(
    preferences: Preferences(
      prefs: await SharedPreferences.getInstance(),
    ),
    configLoader: ConfigLoader(),
    apiKeyDatasource: _NoopApiKeyDatasource(),
    logger: const Logger('test'),
  );
}

/// 按点路径取嵌套 Map 值；键不存在时返回 [_missing]（区分"值为 null"）
const _missing = Object();

Object? baseLookup(Map<String, dynamic> base, String path) {
  Object? node = base;
  for (final segment in path.split('.')) {
    if (node is! Map<String, dynamic>) return _missing;
    if (!node.containsKey(segment)) return _missing;
    node = node[segment];
  }
  return node;
}

/// 扁平点分 key → 嵌套 Map（复刻 SettingsRepositoryImpl._expandFlatKeys 语义）
Map<String, dynamic> expandFlatKeys(Map<String, dynamic> flat) {
  final result = <String, dynamic>{};
  for (final entry in flat.entries) {
    final segments = entry.key.split('.');
    var node = result;
    for (var i = 0; i < segments.length - 1; i++) {
      node[segments[i]] ??= <String, dynamic>{};
      node = node[segments[i]] as Map<String, dynamic>;
    }
    node[segments.last] = entry.value;
  }
  return result;
}

/// 深度合并（复刻 SettingsRepositoryImpl._deepMerge 语义）
void deepMerge(Map<String, dynamic> target, Map<String, dynamic> source) {
  for (final entry in source.entries) {
    final sourceValue = entry.value;
    if (sourceValue is Map<String, dynamic> &&
        target[entry.key] is Map<String, dynamic>) {
      deepMerge(
        target[entry.key] as Map<String, dynamic>,
        sourceValue,
      );
    } else {
      target[entry.key] = sourceValue;
    }
  }
}

class _NoopApiKeyDatasource implements ApiKeyDatasource {
  @override
  Future<void> save(String presetId, String apiKey) async {}

  @override
  Future<String?> read(String presetId) async => null;

  @override
  Future<void> delete(String presetId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}
