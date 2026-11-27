import 'dart:async';

import 'package:flutter/material.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
// gateway 实现撤回 feature 层后
// 的装配注入——core/agent 只留抽象，实现经 DI 取用
import 'package:lmstory/core/agent/agent_llm_gateway.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/config/resource_ai_config.dart';
import 'package:lmstory/core/llm/tool_calling/provider_tool_capabilities.dart';
import 'package:lmstory/core/network/dio_client.dart';
import 'package:lmstory/core/network/http_client.dart';
import 'package:lmstory/core/network/llm_adapters/llm_adapter_factory.dart';
import 'package:lmstory/core/services/data_store_operation_guard.dart';
import 'package:lmstory/core/services/incoming_file_receiver.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/storage/secure_storage.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/advanced/data/repositories/agent_event_log_repository.dart';
import 'package:lmstory/features/advanced/domain/services/api_key_lookup.dart';
import 'package:lmstory/features/chat/data/agent/llm_service_agent_gateway.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/datasources/llm_remote_datasource.dart';
import 'package:lmstory/features/chat/data/datasources/negotiating_llm_service.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/domain/services/compaction_service.dart';
import 'package:lmstory/features/chat/domain/services/compaction_streamer.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/diagnostics/data/repositories/failure_log_repository_impl.dart';
import 'package:lmstory/features/diagnostics/domain/repositories/failure_log_repository.dart';
import 'package:lmstory/features/intermediate/presentation/controllers/intermediate_chat_controller.dart'
    show IntermediateChatController;
import 'package:lmstory/features/memory/data/datasources/embedding_remote_datasource.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';
import 'package:lmstory/features/memory/data/repositories/factual_repository_impl.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/repositories/factual_repository.dart';
import 'package:lmstory/features/memory/domain/services/embedding_service.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';
import 'package:lmstory/features/resource_ai/data/resource_ai_save_service.dart';
import 'package:lmstory/features/resource_ai/data/resource_ai_skill_loader.dart';
import 'package:lmstory/features/resource_ai/domain/services/resource_ai_session.dart';
import 'package:lmstory/features/resource_library/data/repositories/resource_library_repository_impl.dart';
import 'package:lmstory/features/resource_library/domain/repositories/resource_library_repository.dart';
import 'package:lmstory/features/resource_library/domain/services/resource_import_service.dart';
import 'package:lmstory/features/settings/data/auto_backup_manager.dart';
import 'package:lmstory/features/settings/data/datasources/api_key_datasource.dart';
import 'package:lmstory/features/settings/data/repositories/api_preset_repository_impl.dart';
import 'package:lmstory/features/settings/data/repositories/backup_repository_impl.dart';
import 'package:lmstory/features/settings/data/repositories/settings_repository_impl.dart';
import 'package:lmstory/features/settings/data/services/model_test_service.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart'
    show LlmProtocol;
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/backup_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/domain/services/agent_events_usage_port.dart';
import 'package:lmstory/features/settings/domain/services/data_management_service.dart';
import 'package:lmstory/features/settings/domain/services/message_variants_count_port.dart';
import 'package:lmstory/features/story_runtime/data/persistence_service_impl.dart';
import 'package:lmstory/features/story_runtime/domain/services/compaction_service.dart';
import 'package:lmstory/features/story_runtime/domain/services/persistence_service.dart';
import 'package:lmstory/features/templates/data/repositories/template_repository_impl.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// locale 持久化键（main 启动预读与 [LocaleNotifier] 写入共用，勿散写字面量）
const localePrefKey = 'app_locale';

/// Preferences Provider（全局单例）
final preferencesProvider = Provider<Preferences>((ref) => Preferences());

/// Locale 状态管理 Notifier
class LocaleNotifier extends Notifier<AppLocale> {
  @override
  AppLocale build() {
    // 初始化时使用当前 slang 设置（由 initI18n 配置）
    return LocaleSettings.currentLocale;
  }

  /// 切换语言
  Future<void> switchLocale(AppLocale locale) async {
    await LocaleSettings.setLocale(locale);
    state = locale;
    final prefs = ref.read(preferencesProvider);
    // 持久化失败仅保留会话内生效（UI 已切换，不回弹；重启后回到上次
    // 成功保存的语言）——静默失败记日志即可，属低概率存储异常。
    try {
      await prefs.setString(localePrefKey, locale.languageTag);
    } catch (e) {
      const Logger('LocaleNotifier')
          .warn('Failed to persist locale switch', detail: '$e');
    }
  }

  /// 重置为系统语言
  Future<void> resetToSystem() async {
    await LocaleSettings.useDeviceLocale();
    state = LocaleSettings.currentLocale;
    final prefs = ref.read(preferencesProvider);
    try {
      await prefs.remove(localePrefKey);
    } catch (e) {
      const Logger('LocaleNotifier')
          .warn('Failed to persist locale reset', detail: '$e');
    }
  }
}

/// Locale Provider
final localeProvider = NotifierProvider<LocaleNotifier, AppLocale>(
  LocaleNotifier.new,
);

/// Flutter Locale Provider（响应式）
final flutterLocaleProvider = Provider<Locale>((ref) {
  final appLocale = ref.watch(localeProvider);
  return appLocale.flutterLocale;
});

// -- Database --

/// AppDatabase Provider（全局单例）
final appDatabaseProvider = Provider<AppDatabase>((ref) => AppDatabase());

final _storeOperationGuards = Expando<DataStoreOperationGuard>();

/// The same database shares one guard, including across container overrides.
final dataStoreOperationGuardProvider = Provider<DataStoreOperationGuard>(
  (ref) => _storeOperationGuards[ref.watch(appDatabaseProvider)] ??=
      DataStoreOperationGuard(),
);

// -- Secure Storage --

/// SecureStorage Provider（全局单例）
final secureStorageProvider = Provider<SecureStorage>((ref) => SecureStorage());

// -- Settings --

/// ApiKeyDatasource Provider
final apiKeyDatasourceProvider = Provider<ApiKeyDatasource>(
  (ref) => ApiKeyDatasource(secureStorage: ref.read(secureStorageProvider)),
);

/// ApiKeyLookup Provider
///
/// Agent Loop 自检控制器（advanced presentation）依赖 advanced/domain
/// 声明的最小取 Key 端口 [ApiKeyLookup]（函数类型别名），组合根在此以
/// settings 的 ApiKeyDatasource.read 撕脱适配——presentation 不再跨特性
/// import settings 的 data 层具体类。
final apiKeyLookupProvider = Provider<ApiKeyLookup>(
  (ref) => ref.watch(apiKeyDatasourceProvider).read,
);

/// SettingsRepository Provider
final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepositoryImpl(
    preferences: ref.read(preferencesProvider),
    configLoader: ref.read(configLoaderProvider),
    apiKeyDatasource: ref.read(apiKeyDatasourceProvider),
  ),
);

/// 共享 DioClient Provider
///
/// 此前三处裸 `DioClient()`（供应商列表/模型实测/embedding）各自持
/// 独立连接池；统一注入共享实例（连接复用 + 未来拦截器单点挂载）。
final dioClientProvider = Provider<DioClient>((ref) => DioClient());

/// ApiPresetRepository Provider
final apiPresetRepositoryProvider = Provider<ApiPresetRepository>(
  (ref) => ApiPresetRepositoryImpl(
    database: ref.read(appDatabaseProvider),
    apiKeyDatasource: ref.read(apiKeyDatasourceProvider),
    dioClient: ref.read(dioClientProvider),
    adapterFactory: ref.read(llmAdapterFactoryProvider),
    settingsRepository: ref.read(settingsRepositoryProvider),
  ),
);

/// ModelTestService Provider
///
/// 模型能力实测服务（对标 ChatBox model-tester.ts）。
/// 通过发送实际请求探测 vision/tool_use 能力。
final modelTestServiceProvider = Provider<ModelTestService>(
  (ref) => ModelTestService(
    presetRepo: ref.read(apiPresetRepositoryProvider),
    apiKeyDatasource: ref.read(apiKeyDatasourceProvider),
    dioClient: ref.read(dioClientProvider),
    adapterFactory: ref.read(llmAdapterFactoryProvider),
    settingsRepository: ref.read(settingsRepositoryProvider),
  ),
);

/// AgentEventLogRepository Provider
///
/// 此前 4 处散建（组合根/会话轨迹控制器/导演页/诊断页）各自 new、无
/// provider——收口为组合根单点构造，「凡仓库必有 Provider」。
final agentEventLogRepositoryProvider = Provider<AgentEventLogRepository>(
  (ref) => AgentEventLogRepository(
    database: ref.read(appDatabaseProvider),
    logger: ref.read(loggerProvider),
  ),
);

/// settings 域存储统计的最小端口适配
///
/// DataManagementService（settings/domain）此前直接 import advanced/data
/// 仓库实现（features 内 domain→data 违例）；改为依赖 settings/domain
/// 声明的 [AgentEventsUsagePort]，适配在组合根完成，特性间零耦合。
class _AgentEventsUsagePortAdapter implements AgentEventsUsagePort {
  const _AgentEventsUsagePortAdapter(this._repo);

  final AgentEventLogRepository _repo;

  @override
  Future<({int count, int bytes})> eventsUsage() => _repo.eventsUsage();
}

final agentEventsUsagePortProvider = Provider<AgentEventsUsagePort>(
  (ref) =>
      _AgentEventsUsagePortAdapter(ref.read(agentEventLogRepositoryProvider)),
);

/// 稿件变体行数端口适配（存储统计可见性）
class _MessageVariantsCountPortAdapter implements MessageVariantsCountPort {
  const _MessageVariantsCountPortAdapter(this._db);

  final AppDatabase _db;

  @override
  Future<int> messageVariantCount() async {
    final rows = await _db
        .customSelect('SELECT COUNT(*) AS c FROM message_variants')
        .get();
    return rows.first.read<int>('c');
  }
}

final messageVariantsCountPortProvider = Provider<MessageVariantsCountPort>(
  (ref) => _MessageVariantsCountPortAdapter(ref.read(appDatabaseProvider)),
);

/// DataManagementService Provider
///
/// 数据管理服务（导出/导入/统计/恢复）。
/// 统一封装数据管理业务逻辑，由 DataManagementPage 和会话导出入口调用。
final dataManagementServiceProvider = Provider<DataManagementService>(
  (ref) => DataManagementService(
    operationGuard: ref.read(dataStoreOperationGuardProvider),
    chatRepository: ref.read(chatRepositoryProvider),
    presetRepository: ref.read(apiPresetRepositoryProvider),
    settingsRepository: ref.read(settingsRepositoryProvider),
    backupRepository: ref.read(backupRepositoryProvider),
    agentEventsUsagePort: ref.read(agentEventsUsagePortProvider),
    messageVariantsCountPort: ref.read(messageVariantsCountPortProvider),
  ),
);

/// AutoBackupManager Provider（备份完整性立项）
///
/// 自动备份管理器：启动后空闲静默检查（>24h 且有会话数据）导出全量备份
/// 到应用文档目录 backups/（不含 API Key），滚动保留 3 份。
/// 触发点：MainLayout 首帧后延迟；开关/立即备份入口在数据管理页。
final autoBackupManagerProvider = Provider<AutoBackupManager>(
  (ref) => AutoBackupManager(
    dataManagementService: ref.read(dataManagementServiceProvider),
    settingsRepository: ref.read(settingsRepositoryProvider),
    chatRepository: ref.read(chatRepositoryProvider),
  ),
);

/// ConfigurationResolver Provider
///
/// 配置解析器全局单例，用于解析模型 contextWindow、会话设置等。
final configurationResolverProvider = Provider<ConfigurationResolver>(
  (ref) => ConfigurationResolver(
    presetRepository: ref.read(apiPresetRepositoryProvider),
    settingsRepository: ref.read(settingsRepositoryProvider),
    logger: const Logger('ConfigurationResolver'),
  ),
);

/// 故事模式全局 phaseModels 的 generating/reviewing 模型 contextWindow
///
/// 用于全局设置页展示生成/审查阶段的 token 预估。
/// 读取 intermediate.phaseModels 配置的模型，从 cachedModels 中查找 contextWindow。
/// 未配置模型或模型不在缓存中时回退到 [ConfigurationResolver.defaultContextWindow]。
final intermediateGlobalContextWindowProvider =
    FutureProvider.autoDispose<({int generating, int? reviewing})>((ref) async {
  final config = ref.watch(intermediateConfigProvider).valueOrNull;
  if (config == null) {
    return (
      generating: ConfigurationResolver.defaultContextWindow,
      reviewing: null,
    );
  }

  final resolver = ref.read(configurationResolverProvider);
  // intermediateConfigProvider 返回的就是 IntermediateConfig 本身，
  // 直接访问 phaseModels / context 字段，不需要 .intermediate 中间层。
  final phaseModels = config.phaseModels;
  final effectiveLimit = config.context.effectiveContextLimit;

  final generating = await resolver.resolveContextWindowForPhase(
    presetId: phaseModels.generatingPresetId.isEmpty
        ? null
        : phaseModels.generatingPresetId,
    modelId: phaseModels.generatingModelId.isEmpty
        ? null
        : phaseModels.generatingModelId,
    effectiveContextLimit: effectiveLimit,
  );

  int? reviewing;
  if (phaseModels.reviewingPresetId.isNotEmpty &&
      phaseModels.reviewingModelId.isNotEmpty) {
    reviewing = await resolver.resolveContextWindowForPhase(
      presetId: phaseModels.reviewingPresetId,
      modelId: phaseModels.reviewingModelId,
      effectiveContextLimit: effectiveLimit,
    );
  }

  return (generating: generating, reviewing: reviewing);
});

/// 导演模式全局 GM 模型生效上下文窗口（上下文配置收敛 §2.1-1）
///
/// 「上下文压缩阈值」双显示与窗口上限生效值披露的分母：读取
/// advanced.phase_models 的 GM 模型解析 contextWindow，再与窗口上限
///（advanced.context.effective_context_limit，>0 时生效）取 min——与
/// 控制器 _resolveContextWindow 同口径。未配置模型或解析失败时由
/// resolveContextWindowForPhase 回退 [ConfigurationResolver.defaultContextWindow]。
final advancedGlobalContextWindowProvider =
    FutureProvider.autoDispose<int>((ref) async {
  final config = ref.watch(advancedConfigProvider).valueOrNull;
  if (config == null) {
    return ConfigurationResolver.defaultContextWindow;
  }

  final resolver = ref.read(configurationResolverProvider);
  return resolver.resolveContextWindowForPhase(
    presetId:
        config.generatingPresetId.isEmpty ? null : config.generatingPresetId,
    modelId: config.generatingModelId.isEmpty ? null : config.generatingModelId,
    effectiveContextLimit: config.context.effectiveContextLimit,
  );
});

// -- Templates --

/// TemplateRepository Provider
final templateRepositoryProvider = Provider<TemplateRepository>(
  (ref) => TemplateRepositoryImpl(ref.read(appDatabaseProvider)),
);

// -- Resource Library --

/// ResourceLibraryRepository Provider（角色卡/世界书资源库，DOC-15 §9.1）
final resourceLibraryRepositoryProvider = Provider<ResourceLibraryRepository>(
  (ref) =>
      ResourceLibraryRepositoryImpl(database: ref.read(appDatabaseProvider)),
);

/// resource_ai：skill 注册表与正文加载（三个建卡规范资产）
final resourceAiSkillLoaderProvider = Provider<ResourceAiSkillLoader>(
  (ref) => const ResourceAiSkillLoader(),
);

final resourceAiSessionProvider =
    FutureProvider<ResourceAiSession>((ref) async {
  final loader = ref.read(resourceAiSkillLoaderProvider);
  final registry = await loader.loadRegistry();
  return ResourceAiSession(
    skillRegistry: registry,
    loadSkillBody: loader.loadBody,
    settingsRepository: ref.read(settingsRepositoryProvider),
  );
});

/// resource_ai：落库服务（新建/另存/覆盖三路径）
final resourceAiSaveServiceProvider = Provider<ResourceAiSaveService>(
  (ref) => ResourceAiSaveService(
    repository: ref.read(resourceLibraryRepositoryProvider),
  ),
);

/// resource_ai：解析后配置（含 override 合并；模型未配置时 isModelConfigured
/// 为 false，进入工具页由 session.ensureModelSnapshot 落首用快照）
final resourceAiConfigProvider = FutureProvider<ResourceAiConfig>((ref) async {
  final config = await ref.read(settingsRepositoryProvider).getResolvedConfig();
  return config.resourceAi;
});

/// ResourceImportService Provider（应用内导入 + 外部"打开方式/分享"导入共用）
final resourceImportServiceProvider = Provider<ResourceImportService>(
  (ref) => ResourceImportService(
    repository: ref.read(resourceLibraryRepositoryProvider),
  ),
);

/// 外部传入文件事件流（其他应用"打开方式/分享"给 LMStory）
///
/// 单订阅 controller 在监听前缓冲事件；MainLayout 在 onboarding 完成
/// 后监听，冷启动暂存的文件由原生 pending + getInitialFile 兜底补投。
final incomingFileReceiverProvider = Provider<IncomingFileReceiver>((ref) {
  final receiver = IncomingFileReceiver();
  unawaited(receiver.init());
  ref.onDispose(receiver.dispose);
  return receiver;
});

final incomingFileEventsProvider = StreamProvider<IncomingFile>(
  (ref) => ref.watch(incomingFileReceiverProvider).stream,
);

/// macOS 文件拖放→对话会话附件的注入桥（生产方=MainLayout 拖放分发，
/// 消费方=ChatModeInputArea：附件构造与上限检查在消费侧统一）。
/// 消费后置回空表。
final pendingDropFilesProvider =
    StateProvider<List<IncomingFile>>((ref) => const []);

// -- Chat --

/// ChatRepository Provider
final chatRepositoryProvider = Provider<ChatRepository>(
  (ref) => ChatRepositoryImpl(database: ref.read(appDatabaseProvider)),
);

/// BackupRepository Provider
///
/// 数据备份仓储，用于导入/导出的批量数据访问。
/// 由 DataManagementService 使用，提供跨表的原始行级别读写。
final backupRepositoryProvider = Provider<BackupRepository>(
  (ref) => BackupRepositoryImpl(database: ref.read(appDatabaseProvider)),
);

/// HttpClient Provider
final httpClientProvider = Provider<HttpClient>((ref) => HttpClient());

/// LlmAdapterFactory Provider
///
/// 多协议适配器工厂，按 [LlmProtocol] 分发到对应适配器。
/// 已实现：OpenAI 兼容 / Anthropic / Gemini；OpenAI Responses 待 v0.3+ 落地。
final llmAdapterFactoryProvider = Provider<LlmAdapterFactory>((ref) {
  return LlmAdapterFactory();
});

/// Logger Provider
final loggerProvider = Provider<Logger>((ref) => const Logger('LMStory'));

/// ConfigLoader Provider
final configLoaderProvider = Provider<ConfigLoader>((ref) => ConfigLoader());

/// IntermediateConfig Provider（异步只读）
///
/// 中级模式各组件通过 `ref.watch(intermediateConfigProvider)` 获取配置。
/// 配置来源：SettingsRepository.getResolvedConfig()——合并 default_config.json
/// 的 intermediate 顶层块（DOC-09B §10）与 user_overrides 中的用户覆盖
/// （如 `intermediate.system_prompt`，由「故事模式设置」页写入）。
///
///  改用 getResolvedConfig：原 configLoader.load 仅返回默认配置，
/// 无法拾取用户覆盖。改为 resolved 后，全局系统提示词等覆盖项自动生效。
/// 用户在设置页保存后，调用方应 `ref.invalidate(intermediateConfigProvider)` 刷新。
final intermediateConfigProvider =
    FutureProvider<IntermediateConfig>((ref) async {
  final settingsRepo = ref.read(settingsRepositoryProvider);
  final appConfig = await settingsRepo.getResolvedConfig();
  return appConfig.intermediate;
});

/// 导演模式配置 Provider（异步只读，2026-08-27 导演设置体系）
///
/// 与 [intermediateConfigProvider] 平级、零配置依赖（"两个产品"原则）：
/// 配置来源为 default_config.json 的 advanced 段 + user_overrides 中的
/// `advanced.*` 覆盖（导演设置页写入）。用户保存后调用方应
/// `ref.invalidate(advancedConfigProvider)` 刷新。
final advancedConfigProvider = FutureProvider<AdvancedConfig>((ref) async {
  final settingsRepo = ref.read(settingsRepositoryProvider);
  final appConfig = await settingsRepo.getResolvedConfig();
  return appConfig.advanced;
});

/// EmbeddingService Provider
///
/// 中级模式 EmbeddingQueue 通过 `ref.read(embeddingServiceProvider)` 获取。
/// 默认实现为 EmbeddingRemoteDS（调用 OpenAI 兼容 /embeddings 端点）。
/// DioClient 的 baseUrl 在此留空——实际 baseUrl 由调用方通过 embed() 参数传入。
final embeddingServiceProvider = Provider<EmbeddingService>((ref) {
  return EmbeddingRemoteDS(dioClient: ref.read(dioClientProvider));
});

/// LlmService Provider
///
/// 收口项目中散落的 LLM 调用（中级模式 generating/reviewing、Simple 模式对话、
/// 压缩、标题生成、模型测试）。通过 [LlmAdapterFactory] 按协议类型分发到
/// 对应适配器，自身不再感知协议差异。
final llmServiceProvider = Provider<LlmService>((ref) {
  return NegotiatingLlmService(
    inner: LlmRemoteDataSource(
      httpClient: ref.read(httpClientProvider),
      adapterFactory: ref.read(llmAdapterFactoryProvider),
      logger: ref.read(loggerProvider),
    ),
    logger: ref.read(loggerProvider),
  );
});

/// Agent 工具调用能力画像覆盖 Provider（Domain / Core 装配点）
///
/// 默认为 null：使用生产端点真实三元组通过 ProviderToolCapabilities.resolve 解析。
/// 仅在独立无父的 Demo 作用域内通过 buildDemoOverrides 注入数据包绑定的已审核画像。
final agentCapabilitiesOverrideProvider =
    Provider<ProviderToolCapabilities?>((ref) => null);

/// Agent 网关 Provider（：core 抽象 + feature 实现的装配点）
///
/// 导演 runner 内部就地构造（持 _llmService），资源建卡等外部消费方
/// 经本 provider 取实现——core/agent 不再反向依赖 feature。
final agentLlmGatewayProvider = Provider<AgentLlmGateway>((ref) {
  return LlmServiceAgentGateway(
    llmService: ref.watch(llmServiceProvider),
    capabilitiesOverride: ref.watch(agentCapabilitiesOverrideProvider),
  );
});

/// VectorEngine Provider
///
/// 中级模式 ExperienceRepositoryImpl 通过 `ref.read(vectorEngineProvider)` 获取。
/// 纯 Dart 暴力检索引擎，无外部依赖。const 构造，无状态，全局单例安全。
final vectorEngineProvider =
    Provider<VectorEngine>((ref) => const VectorEngine());

/// ExperienceRepository Provider
///
/// 中级模式经历类记忆仓储（DOC-05-5 §4.5）。混合检索算法在 Impl 内实现，
/// Controller 通过本 Provider 获取实例并决定"何时检索"和"如何使用结果"。
/// 关键词向量化（网络调用）在 Controller 完成，queryVector 通过参数传入。
final experienceRepositoryProvider = Provider<ExperienceRepository>(
  (ref) => ExperienceRepositoryImpl(
    database: ref.read(appDatabaseProvider),
    vectorEngine: ref.read(vectorEngineProvider),
  ),
);

/// FailureLogRepository Provider（诊断包）
///
/// 失败日志持久化仓储（DOC-05 待  补充索引）。Controller `_fail` 进入
/// failed 状态时调用 insertLog；诊断页调用 getRecentLogs 列出最近 N 条。
/// 日志操作失败静默降级，不影响主流程。
final failureLogRepositoryProvider = Provider<FailureLogRepository>(
  (ref) => FailureLogRepositoryImpl(
    database: ref.read(appDatabaseProvider),
  ),
);

/// FactualRepository Provider
///
/// 事实层仓储（DOC-11 §11.1）。所有写方法不开自身事务，可安全嵌套在
/// StoryPersistenceServiceImpl 的外层 drift transaction 内。
final factualRepositoryProvider = Provider<FactualRepository>(
  (ref) => FactualRepositoryImpl(database: ref.read(appDatabaseProvider)),
);

/// FactApplier Provider
///
/// 事实变更应用器（DOC-11 §7）。三重防护 + 5 层健康度防护 + 消歧。
/// 不开自身事务，由 StoryPersistenceServiceImpl 在事务内调用。
final factApplierProvider = Provider<FactApplier>(
  (ref) => FactApplier(repository: ref.read(factualRepositoryProvider)),
);

/// StoryPersistenceService Provider
///
/// 中级模式原子持久化服务（DOC-09C §1）。将一轮对话的 5 步写入包在单一
/// drift transaction 内，保证原子性。注入 AppDatabase + ChatRepository +
/// ExperienceRepository + FactApplier（DOC-11 §8.2 同事务事实层），
/// 跨仓储编排事务。
final intermediatePersistenceServiceProvider =
    Provider<StoryPersistenceService>(
  (ref) => StoryPersistenceServiceImpl(
    database: ref.read(appDatabaseProvider),
    chatRepository: ref.read(chatRepositoryProvider),
    experienceRepository: ref.read(experienceRepositoryProvider),
    factApplier: ref.read(factApplierProvider),
  ),
);

/// TokenCounter Provider
final tokenCounterProvider = Provider<TokenCounter>((ref) => TokenCounter());

/// CompactionStreamer Provider
final compactionStreamerProvider = Provider<CompactionStreamer>(
  (ref) => CompactionStreamer(
    llmService: ref.read(llmServiceProvider),
  ),
);

/// CompactionService Provider
final compactionServiceProvider = Provider<CompactionService>(
  (ref) => CompactionService(
    chatRepository: ref.read(chatRepositoryProvider),
    tokenCounter: ref.read(tokenCounterProvider),
    settingsRepository: ref.read(settingsRepositoryProvider),
    presetRepository: ref.read(apiPresetRepositoryProvider),
    streamer: ref.read(compactionStreamerProvider),
    llmService: ref.read(llmServiceProvider),
  ),
);

/// StoryCompactionService Provider
///
/// 故事模式 CompactionPoint 压缩服务。
/// 注入到 [IntermediateChatController] 供 compacting 阶段调用。
///
/// 2026-08-04 修复：原生产代码未注入此服务，导致 compacting 阶段
/// 被跳过（service=null → 直接进 extracting），但 phase 已被设为
/// compacting → UI 每轮闪现"正在压缩对话历史"。注入后压缩可正常
/// 触发与执行，phase 与实际行为一致。
final intermediateCompactionServiceProvider = Provider<StoryCompactionService>(
  (ref) => StoryCompactionService(
    tokenCounter: ref.read(tokenCounterProvider),
    llmService: ref.read(llmServiceProvider),
  ),
);
