import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:lmstory/core/model_registry/model_metadata.dart';
import 'package:lmstory/core/model_registry/model_registry_cache.dart'
    if (dart.library.html) 'package:lmstory/core/model_registry/model_registry_cache_web.dart';
import 'package:lmstory/core/model_registry/provider_mapping.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/model_capability.dart';

/// models.dev 模型元数据注册表
///
/// 对标 ChatBox 的 model-registry 模块。从 https://models.dev/api.json 拉取
/// 全量模型元数据，缓存到本地文件，用于富化用户从 /models 拉取的模型列表。
///
/// 富化策略（与 ChatBox 一致）：
/// - capabilities/contextWindow/maxOutput：registry 覆盖（registry 更权威）
/// - displayName/type：仅缺失时填充（保留用户自定义）
class ModelRegistry {
  ModelRegistry._();
  static final ModelRegistry instance = ModelRegistry._();

  static const _apiUrl = 'https://models.dev/api.json';
  static const _cacheMaxAge = Duration(days: 7);

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );

  /// 内存缓存：providerId → (modelId → ModelMetadata)
  Map<String, Map<String, ModelMetadata>> _cache = {};
  bool _loaded = false;

  /// 加载缓存（内存 → 文件）
  ///
  /// 在 fetchModels 调用前确保 registry 已加载。若缓存过期或不存在，
  /// enrich 时按无 registry 处理（不阻塞主流程）。
  ///
  /// **Web 平台**：条件导入自动切换为 no-op（仅内存缓存）。
  Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final content = await readModelCache();
      if (content != null) {
        final modified = await getCacheLastModified();
        if (modified != null &&
            DateTime.now().difference(modified) < _cacheMaxAge) {
          _cache = _parseCache(content);
        }
      }
    } on Exception {
      // 缓存加载失败不阻塞，enrich 时按无 registry 处理
    }
  }

  /// 从 models.dev 在线刷新（用户在供应商详情页点"获取模型"时调用）
  ///
  /// **Web 平台**：条件导入自动切换为 no-op（仅内存缓存）。
  Future<void> refresh() async {
    try {
      final response = await _dio.get<dynamic>(_apiUrl);
      final data = response.data;
      final body = data is String ? data : jsonEncode(data);
      _cache = _parseCache(body);
      await writeModelCache(body);
    } on Exception {
      // 网络失败时保留现有缓存
    }
  }

  /// 获取指定供应商的所有模型元数据
  Map<String, ModelMetadata> getProviderModels(String? providerId) {
    if (providerId == null) return {};
    return _cache[providerId] ?? {};
  }

  /// 富化模型列表
  ///
  /// 查找优先级（对标 ChatBox 的三级优先级链）：
  /// 1. 按 provider 映射查找（精确，如 builtin-openai → openai）
  /// 2. 跨供应商查找兜底（对标 ChatBox getModelContextWindowSync）：
  ///    当自定义供应商不在 ProviderMapping 中（如 NVIDIA
  ///    integrate.api.nvidia.com）时，用模型 ID 在整个 registry 中
  ///    跨供应商查找匹配项。这样只要模型 ID 在 models.dev 有记录，
  ///    即使供应商本身不返回 context_length，也能获取正确上下文窗口。
  ///
  /// 富化策略：
  /// - capabilities/contextWindow/maxOutput：registry 覆盖（registry 更权威）
  /// - displayName/type：仅缺失时填充（保留用户自定义）
  List<ModelInfo> enrichModels(
    List<ModelInfo> models, {
    required String presetId,
    required String baseUrl,
  }) {
    if (_cache.isEmpty) return models;

    final providerId =
        ProviderMapping.resolve(presetId: presetId, baseUrl: baseUrl);
    // 按供应商查找的 registry（可能为空：自定义供应商无映射时）
    final providerRegistry = providerId != null
        ? getProviderModels(providerId)
        : <String, ModelMetadata>{};

    return models.map((m) {
      // 1. 优先按供应商查找（更精确）
      if (providerRegistry.isNotEmpty) {
        final meta = _findModel(m.modelId, providerRegistry);
        if (meta != null) return _enrichOne(m, meta);
      }
      // 2. 跨供应商查找兜底（自定义供应商无映射，或按供应商未命中时）
      final crossMeta = _findModelAcrossProviders(m.modelId);
      if (crossMeta != null) return _enrichOne(m, crossMeta);
      return m;
    }).toList();
  }

  /// 跨供应商查找模型元数据（兜底）
  ///
  /// 对标 ChatBox 的 getModelContextWindowSync。两轮查找确保准确性：
  /// 1. **第一轮：跨所有供应商精确匹配**（最准确）。例如 `z-ai/glm5.1`
  ///    只匹配 `z-ai/glm5.1`，不会误匹配 `z-ai/glm5`。
  /// 2. **第二轮：跨所有供应商前缀匹配**（兜底，对标 ChatBox）。覆盖带
  ///    后缀的变体（如 `gpt-4o:ft-xxx` → `gpt-4o`）。仅在精确匹配未命中时触发。
  ///
  /// 用于自定义供应商（如 NVIDIA）不在 ProviderMapping 中时的兜底富化。
  /// 注意：displayName 不会被填充（避免误匹配时显示名错误），仅
  /// contextWindow/maxOutput/capabilities 按 registry 值富化。
  ModelMetadata? _findModelAcrossProviders(String modelId) {
    // 第一轮：跨所有供应商精确匹配（大小写不敏感）
    final lower = modelId.toLowerCase();
    for (final providerModels in _cache.values) {
      for (final entry in providerModels.entries) {
        if (entry.key.toLowerCase() == lower) return entry.value;
      }
    }
    // 第二轮：跨所有供应商前缀匹配（兜底）
    for (final providerModels in _cache.values) {
      final meta = _findModel(modelId, providerModels);
      if (meta != null) return meta;
    }
    return null;
  }

  ModelInfo _enrichOne(ModelInfo model, ModelMetadata meta) {
    return model.copyWith(
      // registry 覆盖（更权威）
      capabilities:
          meta.capabilities.isNotEmpty ? meta.capabilities : model.capabilities,
      contextWindow: meta.contextWindow ?? model.contextWindow,
      maxOutput: meta.maxOutput ?? model.maxOutput,
      // 不自动填充 displayName：避免跨供应商/前缀匹配时显示名不准确
      //（如 z-ai/glm5.1 被填充为 glm5）。displayName 由 API 返回或用户自定义。
      type: model.type == ModelType.chat && meta.type != ModelType.chat
          ? meta.type
          : model.type,
    );
  }

  /// 查找模型元数据：精确匹配 → 前缀匹配
  ModelMetadata? _findModel(
    String modelId,
    Map<String, ModelMetadata> registry,
  ) {
    if (registry.isEmpty) return null;
    // 1. 精确匹配（大小写不敏感）
    final lower = modelId.toLowerCase();
    for (final entry in registry.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    // 2. 前缀匹配（带边界检查）：找最长前缀匹配
    ModelMetadata? best;
    var bestLen = 0;
    for (final entry in registry.entries) {
      final key = entry.key.toLowerCase();
      if (lower.startsWith(key) && key.length > bestLen) {
        // 前缀后必须是边界字符（- : . 或字符串结束）
        final nextChar = lower.length > key.length ? lower[key.length] : '';
        if (nextChar.isEmpty ||
            nextChar == '-' ||
            nextChar == ':' ||
            nextChar == '.') {
          best = entry.value;
          bestLen = key.length;
        }
      }
    }
    return best;
  }

  /// 解析 models.dev API 响应为内存缓存结构
  Map<String, Map<String, ModelMetadata>> _parseCache(String body) {
    final result = <String, Map<String, ModelMetadata>>{};
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return result;
      for (final providerEntry in decoded.entries) {
        final providerId = providerEntry.key as String;
        final providerData = providerEntry.value;
        if (providerData is! Map) continue;
        final models = providerData['models'];
        if (models is! Map) continue;
        final modelMap = <String, ModelMetadata>{};
        for (final modelEntry in models.entries) {
          final modelJson = modelEntry.value;
          if (modelJson is! Map<String, dynamic>) continue;
          final meta = ModelMetadata.fromModelsDev(modelJson);
          if (meta.modelId.isNotEmpty) {
            modelMap[meta.modelId] = meta;
          }
        }
        if (modelMap.isNotEmpty) {
          result[providerId] = modelMap;
        }
      }
    } on FormatException {
      // 解析失败返回空缓存
    }
    return result;
  }
}
