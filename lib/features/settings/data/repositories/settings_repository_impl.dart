import 'dart:convert';

import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/settings/data/datasources/api_key_datasource.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:meta/meta.dart';

/// SettingsRepository 实现
///
/// 使用 [Preferences] 存储用户覆盖配置，[ConfigLoader] 加载默认配置，
/// [ApiKeyDatasource] 安全存储 API Key。
class SettingsRepositoryImpl implements SettingsRepository {
  SettingsRepositoryImpl({
    required Preferences preferences,
    required ConfigLoader configLoader,
    required ApiKeyDatasource apiKeyDatasource,
    Logger? logger,
  })  : _preferences = preferences,
        _configLoader = configLoader,
        _apiKeyDatasource = apiKeyDatasource,
        _logger = logger ?? const Logger('SettingsRepo');

  final Preferences _preferences;
  final ConfigLoader _configLoader;
  final ApiKeyDatasource _apiKeyDatasource;
  final Logger _logger;

  /// 类型不兼容覆盖的 drop WARN 按 keyPath 去重，
  /// 每个实例生命周期只报一次。仓库实现经单例 provider 注入，实例字段安全。
  /// 注意：坏 key 本身不清理（保留用户数据——未来版本可能把该类型合法化），
  /// 仅做日志去重，避免每次打开设置页都重复刷同一条 WARN。
  final Set<String> _warnedOverrideDropPaths = {};

  static const _overridesKey = 'user_overrides';

  // -- API Key 操作（委托给 ApiKeyDatasource）--

  @override
  Future<void> saveApiKey(String presetId, String apiKey) =>
      _apiKeyDatasource.save(presetId, apiKey);

  @override
  Future<String?> getApiKey(String presetId) =>
      _apiKeyDatasource.read(presetId);

  @override
  Future<void> deleteApiKey(String presetId) =>
      _apiKeyDatasource.delete(presetId);

  // -- 用户覆盖配置 --

  /// user_overrides 解析失败时的原串备份键。
  ///
  /// 解析失败时 getUserOverrides 返回 {}，随后的 setUserOverride/
  /// removeUserOverride 会以「{}+新键」整体覆写——静默灭失全部用户配置。
  /// 覆写前把损坏原串挪到备份键留档（可人工恢复），违反数据保护铁律的
  /// 静默丢失路径不再存在。
  static const String _corruptOverridesBackupKey =
      'user_overrides_corrupt_backup';

  String? _lastCorruptOverridesRaw;

  @override
  Future<Map<String, dynamic>> getUserOverrides() async {
    final jsonStr = await _preferences.getString(_overridesKey);
    if (jsonStr == null || jsonStr.isEmpty) return {};
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is Map<String, dynamic>) {
        _lastCorruptOverridesRaw = null;
        return decoded;
      }
      _logger.warn('User overrides JSON is not a map, returning empty');
      _lastCorruptOverridesRaw = jsonStr;
      return {};
    } on FormatException catch (e) {
      _logger.warn('Failed to parse user overrides JSON', detail: '$e');
      _lastCorruptOverridesRaw = jsonStr;
      return {};
    }
  }

  /// 覆写前若上一轮读取发现损坏原串，先落备份键留档。
  Future<void> _backupCorruptOverridesIfAny() async {
    final raw = _lastCorruptOverridesRaw;
    if (raw == null) return;
    _lastCorruptOverridesRaw = null;
    await _preferences.setString(_corruptOverridesBackupKey, raw);
    _logger.warn(
      'Corrupt user_overrides backed up before overwrite',
      detail: '${raw.length} chars → $_corruptOverridesBackupKey',
    );
  }

  @override
  Future<void> setUserOverride(String key, dynamic value) async {
    final overrides = await getUserOverrides();
    await _backupCorruptOverridesIfAny();
    overrides[key] = value;
    await _preferences.setString(_overridesKey, jsonEncode(overrides));
  }

  @override
  Future<void> removeUserOverride(String key) async {
    final overrides = await getUserOverrides();
    await _backupCorruptOverridesIfAny();
    overrides.remove(key);
    await _preferences.setString(_overridesKey, jsonEncode(overrides));
  }

  // -- 合并配置 --

  @override
  Future<AppConfig> getResolvedConfig() async {
    final defaultConfig = await _configLoader.load();
    final overrides = await getUserOverrides();
    if (overrides.isEmpty) return defaultConfig;

    // 将默认配置序列化为 Map，合并用户覆盖，再反序列化
    // 注意：setUserOverride 使用扁平 key（如 'network.connect_timeout_ms'），
    // 需要先展开为嵌套结构才能与默认配置的嵌套 Map 正确合并
    final defaultMap = _configToMap(defaultConfig);
    final nestedOverrides = _expandFlatKeys(overrides);
    _deepMerge(defaultMap, nestedOverrides);
    return AppConfig.fromJson(defaultMap);
  }

  @override
  Future<void> clearAllUserOverrides() async {
    await _preferences.remove(_overridesKey);
  }

  @override
  Future<int> getUserOverrideCount() async {
    final overrides = await getUserOverrides();
    return overrides.length;
  }

  /// 将扁平 key（如 'network.connect_timeout_ms'）展开为嵌套 Map 结构
  ///
  /// setUserOverride 存储的是点分隔的扁平 key，而 _configToMap 返回的是嵌套 Map。
  /// 不展开直接合并会导致扁平 key 被错误地加到顶层，而非更新嵌套字段。
  Map<String, dynamic> _expandFlatKeys(Map<String, dynamic> flat) {
    final result = <String, dynamic>{};
    for (final entry in flat.entries) {
      final key = entry.key;
      final value = entry.value;
      final segments = key.split('.');
      if (segments.length == 1) {
        result[key] = value;
      } else {
        var node = result;
        for (var i = 0; i < segments.length - 1; i++) {
          final segment = segments[i];
          node[segment] ??= <String, dynamic>{};
          if (node[segment] is! Map<String, dynamic>) {
            // 类型冲突时以新值覆盖
            node[segment] = <String, dynamic>{};
          }
          node = node[segment] as Map<String, dynamic>;
        }
        node[segments.last] = value;
      }
    }
    return result;
  }

  /// 将 AppConfig 递归转为可修改的 Map
  ///
  /// ** 修复潜在 bug**：原实现缺失 `intermediate` 节点序列化，导致
  /// 任何 `intermediate.*` 用户覆盖都会丢失 default_config.json 中其他 intermediate
  /// 配置（retrieval/context/retry 等）。原 bug 未暴露是因为默认值与常量一致。
  /// 现补全 intermediate 节点（含  新增的 prompts 子节点），确保
  /// _deepMerge 正确合并用户覆盖与默认配置。
  ///
  /// ****：守门测试
  ///（settings_config_roundtrip_test.dart）逐叶子路径比对 JSON 与本方法
  /// 产出——新增配置节点若忘记在此登记，测试即刻失败。
  @visibleForTesting
  Map<String, dynamic> configToMapForTest(AppConfig config) =>
      _configToMap(config);

  Map<String, dynamic> _configToMap(AppConfig config) {
    return <String, dynamic>{
      'version': config.version,
      'network': <String, dynamic>{
        'connect_timeout_ms': config.network.connectTimeoutMs,
        'receive_timeout_ms': config.network.receiveTimeoutMs,
      },
      'common': <String, dynamic>{
        'title_model': <String, dynamic>{
          'preset_id': config.common.titleModel.presetId,
          'model_id': config.common.titleModel.modelId,
        },
      },
      'broadcast_chat': <String, dynamic>{
        'preset_id': config.broadcastChat.presetId,
        'model_id': config.broadcastChat.modelId,
        'temperature': config.broadcastChat.temperature,
        'top_p': config.broadcastChat.topP,
        'max_tokens': config.broadcastChat.maxTokens,
        'auto_compaction': config.broadcastChat.autoCompaction,
        'compaction_threshold': config.broadcastChat.compactionThreshold,
        'stream_enabled': config.broadcastChat.streamEnabled,
      },
      'intermediate': <String, dynamic>{
        'embedding_preset_id': config.intermediate.embeddingPresetId,
        'embedding_model_id': config.intermediate.embeddingModelId,
        'system_prompt': config.intermediate.systemPrompt,
        // generation 节点此前未序列化
        //（同类遗漏）——用户在「故事模式设置→生成参数」设任一参数后，
        // 其余 5 字段的 JSON 基底丢失（当前值恰好与 Dart 默认相等故行为
        // 中性，调 JSON 默认值即静默翻车）。
        'generation': <String, dynamic>{
          'temperature': config.intermediate.generation.temperature,
          'top_p': config.intermediate.generation.topP,
          'max_tokens': config.intermediate.generation.maxTokens,
          'presence_penalty': config.intermediate.generation.presencePenalty,
          'frequency_penalty': config.intermediate.generation.frequencyPenalty,
          'reasoning_effort': config.intermediate.generation.reasoningEffort,
        },
        'retrieval': <String, dynamic>{
          'top_k': config.intermediate.retrieval.topK,
          'fts5_weight': config.intermediate.retrieval.fts5Weight,
          'vector_weight': config.intermediate.retrieval.vectorWeight,
          'key_event_threshold':
              config.intermediate.retrieval.keyEventThreshold,
          'key_event_boost': config.intermediate.retrieval.keyEventBoost,
          'normalization_epsilon':
              config.intermediate.retrieval.normalizationEpsilon,
          'recency_weight': config.intermediate.retrieval.recencyWeight,
          'importance_weight': config.intermediate.retrieval.importanceWeight,
          'recency_half_life': config.intermediate.retrieval.recencyHalfLife,
          'vector_score_threshold':
              config.intermediate.retrieval.vectorScoreThreshold,
          'importance_storage_threshold':
              config.intermediate.retrieval.importanceStorageThreshold,
          'micro_vectorize_threshold':
              config.intermediate.retrieval.microVectorizeThreshold,
          'absolute_threshold': config.intermediate.retrieval.absoluteThreshold,
          'relative_threshold': config.intermediate.retrieval.relativeThreshold,
          // 纯语义候选独立低阈同样必须进合并基底
          'vector_only_cosine_floor':
              config.intermediate.retrieval.vectorOnlyCosineFloor,
          // 主表子串兜底两键必须进合并基底，
          // 否则存在任意用户覆盖时被静默丢弃（回落 Dart 默认值）
          'substring_fallback_enabled':
              config.intermediate.retrieval.substringFallbackEnabled,
          'substring_fallback_limit':
              config.intermediate.retrieval.substringFallbackLimit,
        },
        'context': <String, dynamic>{
          //  修复：补齐 effective_context_limit，
          // 否则存在任意用户覆盖时该字段回落 Dart 默认（null）
          'effective_context_limit':
              config.intermediate.context.effectiveContextLimit,
        },
        //  修复：以下六个节点此前未序列化——一旦存在任意
        // 用户覆盖，这些节点整体从合并基底中消失，fromJson 回落 Dart 构造
        // 默认值。最重后果：consolidation.trigger_threshold 的 JSON 值 2.0
        // （等效禁用记忆提炼）回落为 Dart 默认 0.8（激活），且跑的是已废弃
        // 的单字段提示词。_configToMap 只作合并基底不落盘，因此此处与
        // default_config.json 对齐即可，无"覆盖钉死默认值"的副作用。
        'phase_models': <String, dynamic>{
          'generating_preset_id':
              config.intermediate.phaseModels.generatingPresetId,
          'generating_model_id':
              config.intermediate.phaseModels.generatingModelId,
          'extracting_preset_id':
              config.intermediate.phaseModels.extractingPresetId,
          'extracting_model_id':
              config.intermediate.phaseModels.extractingModelId,
          'reviewing_preset_id':
              config.intermediate.phaseModels.reviewingPresetId,
          'reviewing_model_id':
              config.intermediate.phaseModels.reviewingModelId,
          'summarizing_preset_id':
              config.intermediate.phaseModels.summarizingPresetId,
          'summarizing_model_id':
              config.intermediate.phaseModels.summarizingModelId,
        },
        'consolidation': <String, dynamic>{
          'trigger_threshold':
              config.intermediate.consolidation.triggerThreshold,
          'min_artifacts_to_consolidate':
              config.intermediate.consolidation.minArtifactsToConsolidate,
          'max_artifacts_to_consolidate':
              config.intermediate.consolidation.maxArtifactsToConsolidate,
        },
        'memory': <String, dynamic>{
          'factual': <String, dynamic>{
            'enabled': config.intermediate.memory.factual.enabled,
            'key_entity_importance_threshold':
                config.intermediate.memory.factual.keyEntityImportanceThreshold,
            'injection_max_entities':
                config.intermediate.memory.factual.injectionMaxEntities,
            'force_inject_safety_cap':
                config.intermediate.memory.factual.forceInjectSafetyCap,
            'modify_confidence_threshold':
                config.intermediate.memory.factual.modifyConfidenceThreshold,
            'max_updates_per_3turns':
                config.intermediate.memory.factual.maxUpdatesPer3Turns,
            'max_attr_value_length':
                config.intermediate.memory.factual.maxAttrValueLength,
          },
        },
        'suggest_reply': <String, dynamic>{
          'preset_id': config.intermediate.suggestReply.presetId,
          'model_id': config.intermediate.suggestReply.modelId,
          'prompt': config.intermediate.suggestReply.prompt,
          'temperature': config.intermediate.suggestReply.temperature,
          'max_tokens': config.intermediate.suggestReply.maxTokens,
          'candidate_count': config.intermediate.suggestReply.candidateCount,
          'max_reply_length': config.intermediate.suggestReply.maxReplyLength,
        },
        'contextBudget': <String, dynamic>{
          'compactionTriggerRatio':
              config.intermediate.contextBudget.compactionTriggerRatio,
          'recentMinRatio': config.intermediate.contextBudget.recentMinRatio,
          'retrievalRatio': config.intermediate.contextBudget.retrievalRatio,
          'recentMinTokenTarget':
              config.intermediate.contextBudget.recentMinTokenTarget,
        },
        'reviewEnabled': config.intermediate.reviewEnabled,
        'retry': <String, dynamic>{
          'generating_max_retries':
              config.intermediate.retry.generatingMaxRetries,
          'extracting_max_retries':
              config.intermediate.retry.extractingMaxRetries,
          'retrieval_max_retries':
              config.intermediate.retry.retrievalMaxRetries,
          'reviewing_max_retries':
              config.intermediate.retry.reviewingMaxRetries,
          'summarizing_max_retries':
              config.intermediate.retry.summarizingMaxRetries,
          'json_format_retry': config.intermediate.retry.jsonFormatRetry,
          'stream_interrupt_retry':
              config.intermediate.retry.streamInterruptRetry,
        },
        'embedding': <String, dynamic>{
          'timeout_ms': config.intermediate.embedding.timeoutMs,
          'fallback_on_failure':
              config.intermediate.embedding.fallbackOnFailure,
        },
        'stream': <String, dynamic>{
          'tool_calling_enabled': config.intermediate.stream.toolCallingEnabled,
          // G2 修复：五个 @Deprecated 键不再序列化——
          // 其中 draft_separator 等键名与代码读取键漂移，在 JSON 里本就是
          // 永不生效的死键；fromJson 对缺失键回落相同默认值，行为不变。
          'generating_fold_delay_ms':
              config.intermediate.stream.generatingFoldDelayMs,
          'retrieval_fold_delay_ms':
              config.intermediate.stream.retrievalFoldDelayMs,
        },
        'fork': <String, dynamic>{
          'regenerate_window_rounds':
              config.intermediate.fork.regenerateWindowRounds,
        },
        // prompts 子节点：仅持久化用户显式覆盖的字段。
        // 缺省值由 PromptsConfig.fromJson 回落到 intermediate_prompts.dart 常量。
        // 此处放空 Map，让 _deepMerge 正确合并用户覆盖（如 intermediate.prompts.draft_suffix）。
        'prompts': <String, dynamic>{},
      },
      // 导演模式配置段（2026-08-27 导演设置体系，设计文档 §4）。
      // 与 intermediate 同构守门：default_config.json advanced 段的每个叶子
      // 都必须在此登记，否则存在任意用户覆盖时静默回落 Dart 默认值。
      // AI 建卡工具段：model 子节点仅持久化用户显式覆盖的
      // 字段（默认无模型引用），与 intermediate.prompts 同构守门。
      'resource_ai': <String, dynamic>{
        'max_steps': config.resourceAi.maxSteps,
        'model': <String, dynamic>{},
      },
      'advanced': <String, dynamic>{
        'system_prompt': config.advanced.systemPrompt,
        'phase_models': <String, dynamic>{
          'generating_preset_id': config.advanced.generatingPresetId,
          'generating_model_id': config.advanced.generatingModelId,
        },
        'generation': <String, dynamic>{
          'temperature': config.advanced.generation.temperature,
          'top_p': config.advanced.generation.topP,
          'max_tokens': config.advanced.generation.maxTokens,
          'presence_penalty': config.advanced.generation.presencePenalty,
          'frequency_penalty': config.advanced.generation.frequencyPenalty,
          'reasoning_effort': config.advanced.generation.reasoningEffort,
        },
        'defaults': <String, dynamic>{
          'max_steps': config.advanced.defaults.maxSteps,
        },
        'budget': <String, dynamic>{
          'max_duration_minutes': config.advanced.budget.maxDurationMinutes,
          'token_budget_ratio': config.advanced.budget.tokenBudgetRatio,
          'max_request_retries': config.advanced.budget.maxRequestRetries,
        },
        'doom_loop': <String, dynamic>{
          'threshold': config.advanced.doomLoop.threshold,
        },
        'hitl': <String, dynamic>{
          'ask_user_timeout_minutes':
              config.advanced.hitl.askUserTimeoutMinutes,
          'approval_timeout_minutes':
              config.advanced.hitl.approvalTimeoutMinutes,
        },
        'subagent': <String, dynamic>{
          'max_steps': config.advanced.subagent.maxSteps,
          'max_duration_minutes': config.advanced.subagent.maxDurationMinutes,
          'token_budget_ratio': config.advanced.subagent.tokenBudgetRatio,
        },
        // harness 段随合并基底产出，防用户
        // override 静默丢失（守门测试逐叶子比对 default_config.json）
        'harness': <String, dynamic>{
          'tool_output_limit': config.advanced.harness.toolOutputLimit,
          'tool_timeout_seconds': config.advanced.harness.toolTimeoutSeconds,
          'core_blocks_in_tail': config.advanced.harness.coreBlocksInTail,
          // 流式分片全量落盘档（默认关；最小粒度聚合档无配置键）
          'full_chunk_events': config.advanced.harness.fullChunkEvents,
          // 伏笔定期清点间隔轮数（0=停用；轮尾提醒+finish_round 对账闸门）
          'foreshadow_check_interval':
              config.advanced.harness.foreshadowCheckInterval,
          // 批 I：事件日志滚动保留轮数（0=不限制）
          'event_log_retention_turns':
              config.advanced.harness.eventLogRetentionTurns,
        },
        'context': <String, dynamic>{
          'effective_context_limit':
              config.advanced.context.effectiveContextLimit,
        },
        // 上下文配置收敛：advanced.contextBudget 只保留
        // 压缩阈值与动态下限目标 token——recentMinRatio/retrievalRatio
        // 是故事三段式遗产，导演组装侧定死（DirectorContextBudgetPin），
        // 不再进合并基底（值类解析兜底仍在，override 残值 inert）
        'contextBudget': <String, dynamic>{
          'compactionTriggerRatio':
              config.advanced.contextBudget.compactionTriggerRatio,
          'recentMinTokenTarget':
              config.advanced.contextBudget.recentMinTokenTarget,
        },
        //  审查移除：advanced.stream 段整体删除（导演运行时零消费，
        // 残留的用户 override 值保留在 SP 中 inert，不丢数据）
        // tools 子树按设计只承载用户显式覆盖（空 map = 全 allow 内置默认）
        'tools': <String, dynamic>{},
        'narrative_pacing': config.advanced.narrativePacing,
        'embedding_preset_id': config.advanced.embeddingPresetId,
        'embedding_model_id': config.advanced.embeddingModelId,
        'embedding': <String, dynamic>{
          'timeout_ms': config.advanced.embedding.timeoutMs,
          'fallback_on_failure': config.advanced.embedding.fallbackOnFailure,
        },
        'memory': <String, dynamic>{
          'factual': <String, dynamic>{
            'enabled': config.advanced.memory.factual.enabled,
            'key_entity_importance_threshold':
                config.advanced.memory.factual.keyEntityImportanceThreshold,
            'injection_max_entities':
                config.advanced.memory.factual.injectionMaxEntities,
            'force_inject_safety_cap':
                config.advanced.memory.factual.forceInjectSafetyCap,
            'modify_confidence_threshold':
                config.advanced.memory.factual.modifyConfidenceThreshold,
            'max_updates_per_3turns':
                config.advanced.memory.factual.maxUpdatesPer3Turns,
            'max_attr_value_length':
                config.advanced.memory.factual.maxAttrValueLength,
          },
        },
        'consolidation': <String, dynamic>{
          'trigger_threshold': config.advanced.consolidation.triggerThreshold,
          'min_artifacts_to_consolidate':
              config.advanced.consolidation.minArtifactsToConsolidate,
          'max_artifacts_to_consolidate':
              config.advanced.consolidation.maxArtifactsToConsolidate,
        },
        // 2026-08-29 审查 ：导演运行时仅消费双门槛两键（persist 索引门槛 +
        // 向量化门槛），故事混合检索的 14 个排序参数不再进导演合并基底。
        // advanced 侧 substring_fallback_* 两键摘除——
        // 导演检索的子串兜底是无条件执行（不读这两键），写进合并基底
        // 只制造「配置有效」的错觉，违反「配置键即行为承诺」。
        'retrieval': <String, dynamic>{
          'importance_storage_threshold':
              config.advanced.retrieval.importanceStorageThreshold,
          'micro_vectorize_threshold':
              config.advanced.retrieval.microVectorizeThreshold,
        },
        'suggest_reply': <String, dynamic>{
          'preset_id': config.advanced.suggestReply.presetId,
          'model_id': config.advanced.suggestReply.modelId,
          'prompt': config.advanced.suggestReply.prompt,
          'temperature': config.advanced.suggestReply.temperature,
          'max_tokens': config.advanced.suggestReply.maxTokens,
          'candidate_count': config.advanced.suggestReply.candidateCount,
          'max_reply_length': config.advanced.suggestReply.maxReplyLength,
        },
        'review_enabled': config.advanced.reviewEnabled,
        // prompts 子节点：同 intermediate 约定，仅持久化用户显式覆盖
        'prompts': <String, dynamic>{},
      },
    };
  }

  /// 深度合并：[source] 中的值覆盖 [target] 中的同名键
  /// 对于嵌套 Map 递归合并；叶子值经 [_coerceOverrideValue] 类型矫正
  ///
  /// 手改/异版本备份可把 `"connect_timeout_ms":
  /// "15000"`（String）写进覆盖表，读取侧 `as int?` 硬转型会让
  /// getResolvedConfig 持续抛 TypeError、设置页进 error 态且需手清 SP
  /// 自救。此处是「覆盖 × 默认」合并的唯一收口点：叶子值按默认值的
  /// 运行时类型做宽容转换（可转则转、不可转丢弃保留默认），任何读取方
  /// 从此拿到的都是类型安全的值。
  void _deepMerge(
    Map<String, dynamic> target,
    Map<String, dynamic> source, [
    String path = '',
  ]) {
    for (final entry in source.entries) {
      final key = entry.key;
      final sourceValue = entry.value;
      final keyPath = path.isEmpty ? key : '$path.$key';
      if (sourceValue is Map<String, dynamic> &&
          target[key] is Map<String, dynamic>) {
        _deepMerge(
          target[key] as Map<String, dynamic>,
          sourceValue,
          keyPath,
        );
      } else {
        var coerced = _coerceOverrideValue(target[key], sourceValue);
        // 枚举标量白名单——
        // AdvancedConfig.fromJson 对枚举键解析期 throw（对随包默认资产
        // 是对的：坏配置启动即暴露）；但 userOverrides 是用户手改/异版本
        // 备份可写面，坏字符串经 String 直通合并后会让**全部模式**
        // getResolvedConfig 持续抛 FormatException（设置页 error 态）。
        // 合并收口点拦截：不在枚举集内的值按 _OverrideDrop 同通道丢弃。
        if (coerced is! _OverrideDrop &&
            _isInvalidEnumOverride(keyPath, coerced)) {
          coerced = const _OverrideDrop();
        }
        if (coerced is _OverrideDrop) {
          // 坏 key 永续滞留时每次解析都 WARN 会重复刷屏——同
          // keyPath 实例生命周期内只报首次（Set.add 返回 false 即已报过）。
          if (_warnedOverrideDropPaths.add(keyPath)) {
            _logger.warn(
              'Drop type-incompatible override, keep default',
              detail: '$keyPath: override=${sourceValue.runtimeType} '
                  'default=${target[key].runtimeType}',
            );
          }
        } else {
          target[key] = coerced;
        }
      }
    }
  }

  /// 枚举标量覆盖白名单：keyPath → 合法值集合。
  ///
  /// 与 AdvancedConfig._parseTools/_parseNarrativePacing 的解析期
  /// 拒绝互为两道闸：解析闸守随包资产（开发错误启动即崩），本闸守
  /// 用户可写面（坏值降级为默认，不炸全部模式的配置解析）。
  static const Map<String, Set<String>> _enumOverrideWhitelist = {
    'advanced.narrative_pacing': {'conservative', 'balanced', 'aggressive'},
  };

  /// [keyPath] 是枚举键且 [value] 不在合法值集合内时返回 true。
  /// advanced.tools.<name> 的工具名是开放键集，按前缀匹配三态值。
  static bool _isInvalidEnumOverride(String keyPath, Object? value) {
    if (value is! String) return false;
    final exact = _enumOverrideWhitelist[keyPath];
    if (exact != null) return !exact.contains(value);
    if (keyPath.startsWith('advanced.tools.')) {
      return value != 'allow' && value != 'ask' && value != 'deny';
    }
    return false;
  }

  /// 叶子覆盖值按默认值类型宽容转换；不可转换时返回 [_OverrideDrop]
  ///（合并侧丢弃、保留默认值）。
  ///
  /// 规则（宽松优先用户意图，类型安全优先于生效）：
  /// - 默认 int：int 直用 / num 取整 / String 解析；其余丢弃
  /// - 默认 double：num / String 解析；其余丢弃
  /// - 默认 bool：bool / 'true'|'false' / num 0|1；其余丢弃
  /// - 默认 String：String 直用 / num、bool toString；其余丢弃
  /// - 默认 null（可空键）：仅放行标量，Map/List 丢弃
  /// - 其余（默认为集合等）：仅同运行时类型放行
  static Object? _coerceOverrideValue(Object? defaultValue, Object? value) {
    if (defaultValue is int) {
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) {
        final parsed = int.tryParse(value.trim());
        if (parsed != null) return parsed;
      }
      return const _OverrideDrop();
    }
    if (defaultValue is double) {
      if (value is double) return value;
      if (value is num) return value.toDouble();
      if (value is String) {
        final parsed = double.tryParse(value.trim());
        if (parsed != null) return parsed;
      }
      return const _OverrideDrop();
    }
    if (defaultValue is bool) {
      if (value is bool) return value;
      if (value is String) {
        final lowered = value.trim().toLowerCase();
        if (lowered == 'true') return true;
        if (lowered == 'false') return false;
      }
      if (value is num && (value == 0 || value == 1)) {
        return value == 1;
      }
      return const _OverrideDrop();
    }
    if (defaultValue is String) {
      if (value is String) return value;
      if (value is num || value is bool) return value.toString();
      return const _OverrideDrop();
    }
    if (defaultValue == null) {
      if (value is num || value is bool || value is String) return value;
      return const _OverrideDrop();
    }
    if (value.runtimeType == defaultValue.runtimeType) return value;
    return const _OverrideDrop();
  }
}

/// [SettingsRepositoryImpl._coerceOverrideValue] 的丢弃哨兵（合并侧保留默认值）。
class _OverrideDrop {
  const _OverrideDrop();
}
