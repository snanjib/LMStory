import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/model_registry/model_capability_inferrer.dart';
import 'package:lmstory/core/model_registry/model_registry.dart';
import 'package:lmstory/core/network/dio_client.dart';
import 'package:lmstory/core/network/llm_adapters/llm_adapter_factory.dart';
import 'package:lmstory/core/network/llm_adapters/sampling_params.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/settings/data/datasources/api_key_datasource.dart';
import 'package:lmstory/features/settings/data/provider_templates.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart'
    as domain;
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';
import 'package:lmstory/features/settings/domain/entities/model_capability.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:uuid/uuid.dart';

/// ApiPresetRepository 实现
///
/// 使用 [AppDatabase] 持久化预设数据，[ApiKeyDatasource] 安全存储 API Key，
/// [DioClient] 请求远程模型列表。
///
/// 内置 preset 永不预装：[ProviderTemplates]
/// 注册表仅供「从模板新建」路径取默认值；导入侧对内置 id 恒 skip。
class ApiPresetRepositoryImpl implements ApiPresetRepository {
  ApiPresetRepositoryImpl({
    required AppDatabase database,
    required ApiKeyDatasource apiKeyDatasource,
    required DioClient dioClient,
    required LlmAdapterFactory adapterFactory,
    SettingsRepository? settingsRepository,
    Logger? logger,
  })  : _database = database,
        _apiKeyDatasource = apiKeyDatasource,
        _dioClient = dioClient,
        _adapterFactory = adapterFactory,
        _settingsRepository = settingsRepository,
        _logger = logger ?? const Logger('ApiPresetRepo');

  final AppDatabase _database;
  final ApiKeyDatasource _apiKeyDatasource;
  final DioClient _dioClient;

  /// 获取模型的用户超时来源（null=构造默认超时）
  final SettingsRepository? _settingsRepository;
  final LlmAdapterFactory _adapterFactory;
  final Logger _logger;
  final _uuid = const Uuid();
  static const _newProviderOptions = <String, dynamic>{
    kOmitSamplingParamsOption: true,
  };

  // -- 查询 --

  @override
  Future<List<domain.ApiPreset>> getAllPresets() async {
    final rows = await _database.select(_database.apiPresetsTable).get();
    return rows.map(_toEntity).toList();
  }

  @override
  Future<domain.ApiPreset> getPreset(String presetId) async {
    final row = await (_database.select(_database.apiPresetsTable)
          ..where((t) => t.presetId.equals(presetId)))
        .getSingleOrNull();

    if (row == null) {
      throw ModelNotFoundException(presetId);
    }
    return _toEntity(row);
  }

  // -- 创建 --

  @override
  Future<domain.ApiPreset> createPreset({
    required String name,
    String baseUrl = '',
    LlmProtocol protocol = LlmProtocol.openaiCompatible,
    bool omitSamplingParams = true,
  }) async {
    final presetId = _uuid.v4();
    final now = DateTime.now();
    final providerOptions = omitSamplingParams ? _newProviderOptions : null;
    await _database.into(_database.apiPresetsTable).insert(
          ApiPresetsTableCompanion.insert(
            presetId: presetId,
            name: name,
            baseUrl: Value(baseUrl),
            isBuiltIn: const Value(false),
            protocol: Value(protocol.toJson()),
            cachedModels: const Value('[]'),
            providerOptions: Value(_encodeProviderOptions(providerOptions)),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
    return domain.ApiPreset(
      presetId: presetId,
      name: name,
      baseUrl: baseUrl,
      createdAt: now,
      updatedAt: now,
      protocol: protocol,
      providerOptions: providerOptions,
    );
  }

  @override
  Future<domain.ApiPreset> createFromTemplate({
    required String templateId,
    required String name,
  }) async {
    final template = ProviderTemplates.findById(templateId);
    if (template == null) {
      throw InvalidConfigurationException(
        'Unknown templateId: $templateId',
      );
    }
    final presetId = _uuid.v4();
    final now = DateTime.now();
    final providerOptions = {
      ...?template.providerOptions,
      ..._newProviderOptions,
    };
    await _database.into(_database.apiPresetsTable).insert(
          ApiPresetsTableCompanion.insert(
            presetId: presetId,
            name: name,
            baseUrl: Value(template.defaultBaseUrl),
            isBuiltIn: const Value(false),
            protocol: Value(template.protocol.toJson()),
            templateId: Value(templateId),
            cachedModels: const Value('[]'),
            providerOptions: Value(_encodeProviderOptions(providerOptions)),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
    return domain.ApiPreset(
      presetId: presetId,
      name: name,
      baseUrl: template.defaultBaseUrl,
      protocol: template.protocol,
      templateId: templateId,
      providerOptions: providerOptions,
      createdAt: now,
      updatedAt: now,
    );
  }

  // -- 更新（覆盖式，DOC-12 §4.3）--

  @override
  Future<domain.ApiPreset> updatePreset(
    String presetId,
    domain.ApiPreset Function(domain.ApiPreset current) updater,
  ) async {
    final current = await getPreset(presetId);
    final updated = updater(current);
    final now = DateTime.now();
    await (_database.update(_database.apiPresetsTable)
          ..where((t) => t.presetId.equals(presetId)))
        .write(
      ApiPresetsTableCompanion(
        name: Value(updated.name),
        baseUrl: Value(updated.baseUrl),
        cachedModels: Value(_encodeModels(updated.cachedModels)),
        providerOptions: Value(_encodeProviderOptions(updated.providerOptions)),
        updatedAt: Value(now),
      ),
    );
    return updated.copyWith(updatedAt: now);
  }

  @override
  Future<domain.ApiPreset> resetPreset(String presetId) async {
    final current = await getPreset(presetId);
    // 基于模板创建的 preset（有 templateId）可重置为模板默认值
    final templateId = current.templateId;
    if (templateId == null) {
      throw const InvalidConfigurationException(
        'Cannot reset preset without templateId',
      );
    }
    // 从 ProviderTemplates 注册表查找模板默认值
    final template = ProviderTemplates.findById(templateId);
    if (template == null) {
      throw ModelNotFoundException(presetId);
    }
    final now = DateTime.now();
    await (_database.update(_database.apiPresetsTable)
          ..where((t) => t.presetId.equals(presetId)))
        .write(
      ApiPresetsTableCompanion(
        name: Value(template.name),
        baseUrl: Value(template.defaultBaseUrl),
        protocol: Value(template.protocol.toJson()),
        cachedModels: const Value('[]'),
        // S-1：重置 = 写入当前模板快照值。模板无
        // providerOptions 字段，快照即 null——不写该列会残留旧值，
        // 重置后 thinking 等参数静默续用，与「恢复为模板默认值」相悖。
        providerOptions:
            Value(_encodeProviderOptions(template.providerOptions)),
        updatedAt: Value(now),
      ),
    );
    return domain.ApiPreset(
      presetId: current.presetId,
      name: template.name,
      baseUrl: template.defaultBaseUrl,
      isBuiltIn: current.isBuiltIn,
      protocol: template.protocol,
      templateId: current.templateId,
      providerOptions: template.providerOptions,
      createdAt: current.createdAt,
      updatedAt: now,
    );
  }

  // -- 删除 --

  @override
  Future<void> deletePreset(String presetId) async {
    // 所有 preset 均可删除（不再有不可删除的内置 preset）
    await (_database.delete(_database.apiPresetsTable)
          ..where((t) => t.presetId.equals(presetId)))
        .go();
    // 同时清理 API Key
    await _apiKeyDatasource.delete(presetId);
  }

  // -- 模型列表 --

  @override
  Future<List<domain.ModelInfo>> fetchModels(String presetId) async {
    final preset = await getPreset(presetId);
    final apiKey = await _apiKeyDatasource.read(presetId);

    // 确保本地缓存已加载（快速，从文件读取，毫秒级）
    // 再后台刷新 models.dev 缓存（不阻塞主流程）
    //
    // 修复：原 `await ModelRegistry.instance.refresh()` 同步等待 models.dev
    // 网络请求完成，而 models.dev 国内访问不稳定，导致"测试连接"和"获取模型
    // 列表"时好时坏（通畅时秒过，慢/超时时卡 10-40 秒）。改为非阻塞后，真正
    // 的供应商 API 请求立即发出，models.dev 刷新在后台进行。
    // refresh() 内部静默吞掉网络异常，失败也不影响富化（使用已有本地缓存）。
    await ModelRegistry.instance.ensureLoaded();
    unawaited(ModelRegistry.instance.refresh());

    // 通过适配器工厂按 protocol 分发，获取正确的 URL 和 headers
    // 修复：原硬编码 /models + OpenAI 认证头，导致 Anthropic/Gemini 等
    // 非标准供应商获取模型列表失败。火山引擎 Coding Plan 的 /models 端点
    // 返回 404 也是真实场景——某些供应商不提供模型列表 API。
    final adapter = _adapterFactory.getAdapter(
      protocol: preset.protocol,
      baseUrl: preset.baseUrl,
      modelId: '', // models 端点不需要 modelId
    );
    final url = adapter.buildModelsUrl(preset.baseUrl);

    // 构造最小 LlmRequest 让适配器生成正确的认证 + 协议 headers
    final headerRequest = LlmRequest(
      baseUrl: preset.baseUrl,
      modelId: '',
      messages: const [],
      apiKey: apiKey,
      protocol: preset.protocol,
      providerOptions: preset.providerOptions,
    );
    final headers = adapter.buildHeaders(headerRequest);

    // 用户 network.* 超时对获取模型生效（透传合并）
    Duration? connectTimeout;
    Duration? receiveTimeout;
    final settings = _settingsRepository;
    if (settings != null) {
      try {
        final network = (await settings.getResolvedConfig()).network;
        connectTimeout = network.connectTimeout;
        receiveTimeout = network.receiveTimeout;
      } on Exception {
        // 解析失败回退 DioClient 构造默认值
      }
    }
    // 1. 从 API 响应提取 + 推断能力（对标 ChatBox fetchRemoteModels）
    // Anthropic Models API 默认 limit=20 且返回 has_more/last_id，按游标
    // 最多翻 10 页；其它协议无分页字段时只请求一次。
    final models = <domain.ModelInfo>[];
    final seenIds = <String>{};
    var requestUrl = url;
    for (var page = 0; page < 10; page++) {
      final response = await _dioClient.get<Map<String, dynamic>>(
        requestUrl,
        options: Options(headers: headers),
        connectTimeout: connectTimeout,
        receiveTimeout: receiveTimeout,
      );

      if (!response.isSuccessful || response.data == null) {
        // 不再静默吞掉错误，向上抛出让 UI 层给用户清晰提示
        throw AppHttpException(
          'Failed to fetch models (HTTP ${response.statusCode})',
          statusCode: response.statusCode,
          uri: Uri.tryParse(requestUrl),
          responseBody: response.data?.toString(),
        );
      }

      final data = response.data!;
      // ListModels 响应顶层键按协议分流——Gemini 是
      // `models`（此前只解析 OpenAI 的 `data`，Gemini 供应商永远返回空列表，
      // 且与"测试连接成功"并存形成首次配置死局）
      final modelsList = switch (preset.protocol) {
        LlmProtocol.geminiNative => data['models'],
        _ => data['data'],
      };
      if (modelsList is! List) break;

      for (final item in modelsList) {
        if (item is! Map<String, dynamic>) continue;
        // id 解析：OpenAI/Anthropic 用 `id`；Gemini 用 `name`（带 models/ 前缀）
        var id = item['id'];
        if (id is! String && preset.protocol == LlmProtocol.geminiNative) {
          final name = item['name'];
          if (name is String) {
            id = name.startsWith('models/') ? name.substring(7) : name;
          }
        }
        if (id is! String || id.isEmpty) continue;
        if (!seenIds.add(id)) continue;
        models.add(_inferModelFromApi({...item, 'id': id}));
      }

      final hasMore = data['has_more'] == true;
      final lastId = data['last_id'];
      if (!hasMore || lastId is! String || lastId.isEmpty) break;
      final separator = url.contains('?') ? '&' : '?';
      requestUrl =
          '$url${separator}after_id=${Uri.encodeQueryComponent(lastId)}'
          '&limit=1000';
    }
    if (models.isEmpty) return [];

    // 2. 用 models.dev registry 富化（覆盖 capabilities/contextWindow/maxOutput）
    // ensureLoaded() 已在方法开头调用，此处直接使用已加载的缓存
    return ModelRegistry.instance.enrichModels(
      models,
      presetId: preset.presetId,
      baseUrl: preset.baseUrl,
    );
  }

  /// 从 models 列表单个模型对象推断 ModelInfo
  ///
  /// 兼容多种 API 格式（对标 ChatBox 的推断逻辑）：
  /// - 标准 OpenAI：仅 id
  /// - OpenRouter 扩展：含 architecture/pricing/context_length/top_p/max_tokens
  /// - 新版 OpenAI：max_context_tokens 替代 context_length
  ///
  /// 字段兼容：
  /// - contextWindow: max_context_tokens（新版） / context_length（旧版/OpenRouter）
  /// - maxOutput: max_completion_tokens（新版） / max_tokens（旧版）
  /// - displayName: name（OpenRouter）
  /// - vision: architecture.input_modalities 含 image
  /// - reasoning: pricing.internal_reasoning 不为 "0" + modelId 模式匹配兜底
  /// - tool_use 无法从 API 推断，依赖 registry 或用户手填
  domain.ModelInfo _inferModelFromApi(Map<String, dynamic> item) {
    final caps = <ModelCapability>[];

    // vision：OpenRouter 的 architecture.input_modalities
    final architecture = item['architecture'];
    if (architecture is Map) {
      final inputModalities = architecture['input_modalities'];
      if (inputModalities is List && inputModalities.any((m) => m == 'image')) {
        caps.add(ModelCapability.vision);
      }
    }

    // reasoning 来源 1：OpenRouter 的 pricing.internal_reasoning 不为 "0"
    final pricing = item['pricing'];
    if (pricing is Map) {
      final internalReasoning = pricing['internal_reasoning'];
      if (internalReasoning is String &&
          internalReasoning.isNotEmpty &&
          internalReasoning != '0') {
        caps.add(ModelCapability.reasoning);
      }
    }

    // reasoning 来源 2（2026-07-27 新增）：modelId 模式匹配兜底
    // 解决 DeepSeek/Qwen3/GLM/Kimi 等供应商 /models 响应无 reasoning 字段
    // 导致能力标记缺失的问题（详见 ModelCapabilityInferrer 注释）
    final modelId = item['id'] as String;
    if (!caps.contains(ModelCapability.reasoning) &&
        ModelCapabilityInferrer.infersReasoning(modelId)) {
      caps.add(ModelCapability.reasoning);
    }

    // 兼容新旧字段名
    // contextWindow: max_context_tokens（新版） / max_input_tokens（Anthropic
    // Models API） / context_length（旧版/OpenRouter）
    final contextWindow = (item['max_context_tokens'] as num?)?.toInt() ??
        (item['max_input_tokens'] as num?)?.toInt() ??
        (item['context_length'] as num?)?.toInt();

    // maxOutput: max_completion_tokens（新版） / max_tokens（旧版）
    final maxOutput = (item['max_completion_tokens'] as num?)?.toInt() ??
        (item['max_tokens'] as num?)?.toInt();

    // displayName 兼容：OpenRouter `name` / Anthropic `display_name` /
    // Gemini `displayName`（Anthropic 此前回落裸 modelId）
    final displayName =
        item['display_name'] as String? ?? item['displayName'] as String?;

    // Gemini ListModels 用 inputTokenLimit/outputTokenLimit 表达窗口
    final geminiContext = (item['inputTokenLimit'] as num?)?.toInt();
    final geminiMaxOutput = (item['outputTokenLimit'] as num?)?.toInt();

    return domain.ModelInfo(
      modelId: modelId,
      displayName: displayName ?? item['name'] as String?,
      capabilities: caps,
      contextWindow: contextWindow ?? geminiContext,
      maxOutput: maxOutput ?? geminiMaxOutput,
    );
  }

  @override
  Future<void> updateModelList(
    String presetId,
    List<domain.ModelInfo> models,
  ) async {
    final now = DateTime.now();
    await (_database.update(_database.apiPresetsTable)
          ..where((t) => t.presetId.equals(presetId)))
        .write(
      ApiPresetsTableCompanion(
        cachedModels: Value(_encodeModels(models)),
        updatedAt: Value(now),
      ),
    );
  }

  // -- 数据管理 --

  @override
  Future<void> deleteAllCustomPresets() async {
    // 1. 查询所有自定义预设（用于清理关联的 API Key）
    final customPresets = await (_database.select(_database.apiPresetsTable)
          ..where((t) => t.isBuiltIn.equals(false)))
        .get();

    if (customPresets.isEmpty) return;

    // 2. 批量删除 API Key
    for (final preset in customPresets) {
      await _apiKeyDatasource.delete(preset.presetId);
    }

    // 3. 批量删除预设
    await (_database.delete(_database.apiPresetsTable)
          ..where((t) => t.isBuiltIn.equals(false)))
        .go();

    _logger.info(
      'Deleted all custom presets',
      detail: 'count=${customPresets.length}',
    );
  }

  @override
  Future<int> getCustomPresetCount() async {
    final row = await (_database.selectOnly(_database.apiPresetsTable)
          ..addColumns([_database.apiPresetsTable.presetId.count()])
          ..where(_database.apiPresetsTable.isBuiltIn.equals(false)))
        .getSingle();
    return row.read(_database.apiPresetsTable.presetId.count()) ?? 0;
  }

  // -- 映射工具 --

  /// 将数据库行映射为领域实体
  domain.ApiPreset _toEntity(ApiPresetsTableData row) {
    return domain.ApiPreset(
      presetId: row.presetId,
      name: row.name,
      baseUrl: row.baseUrl,
      isBuiltIn: row.isBuiltIn,
      protocol: LlmProtocol.fromJson(row.protocol),
      templateId: row.templateId,
      providerOptions: _decodeProviderOptions(row.providerOptions),
      cachedModels: _decodeModels(row.cachedModels),
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
    );
  }

  /// 解析 providerOptions JSON 字符串为 Map
  ///
  /// 数据库存储为 TEXT（JSON 字符串），领域实体用 Map<String, dynamic>。
  /// null 或空串返回 null（表示无配置，适配器走默认逻辑）。
  /// 格式错误时返回 null 并记录 warn 日志（降级而非崩溃）。
  Map<String, dynamic>? _decodeProviderOptions(String? jsonStr) {
    if (jsonStr == null || jsonStr.isEmpty) return null;
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } on FormatException catch (e) {
      _logger.warn(
        'Failed to decode providerOptions',
        detail: '$e (raw=$jsonStr)',
      );
      return null;
    }
  }

  /// 编码 providerOptions Map 为 JSON 字符串
  String? _encodeProviderOptions(Map<String, dynamic>? options) {
    if (options == null || options.isEmpty) return null;
    return jsonEncode(options);
  }

  /// 解析 cachedModels JSON 字符串为 ModelInfo 列表
  ///
  /// 委托给 [domain.ModelInfo.fromJson]，兼容新旧两种 key 格式。
  List<domain.ModelInfo> _decodeModels(String jsonStr) {
    if (jsonStr.isEmpty) return [];
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(domain.ModelInfo.fromJson)
          .where((m) => m.modelId.isNotEmpty)
          .toList();
    } on FormatException catch (e) {
      _logger.warn('Failed to decode cached models', detail: '$e');
      return [];
    }
  }

  /// 将 ModelInfo 列表编码为 JSON 字符串
  String _encodeModels(List<domain.ModelInfo> models) {
    final list = models.map((m) => m.toJson()).toList();
    return jsonEncode(list);
  }
}
