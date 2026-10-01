import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/config/intermediate_prompts_v2.dart';
import 'package:lmstory/core/config/output_token_policy.dart';
import 'package:lmstory/core/model_registry/model_capability_inferrer.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session_settings.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/entities/session_phase_models.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';
import 'package:lmstory/features/settings/domain/entities/model_capability.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_runtime_config.dart'
    show DirectorContextBudgetPin;

/// 模型显示信息
///
/// 由 [ConfigurationResolver.resolveModelDisplayInfo] 解析得出，
/// 供输入框工具栏的模型选择芯片和 token 计数警告使用。
class ModelDisplayInfo {
  const ModelDisplayInfo({
    required this.modelName,
    required this.providerName,
    required this.contextWindowTokens,
    this.supportsReasoning = false,
  });

  /// 当前解析出的模型显示名（会话级 > 全局默认）
  final String? modelName;

  /// 当前解析出的供应商显示名（会话级 > 第一个可用 preset）
  final String? providerName;

  /// 当前模型的上下文窗口大小（token），用于输入框 token 计数警告阈值
  final int? contextWindowTokens;

  /// 当前模型是否支持思考/推理能力（基于 ModelCapability.reasoning）
  ///
  /// 用于决定是否向 API 发送 `reasoning_effort` 参数。
  /// 发送不支持该参数的模型可能导致 400 错误。
  final bool supportsReasoning;
}

/// 自动命名所需的 API 配置
///
/// 由 [ConfigurationResolver.resolveTitleNamingConfig] 解析 `common.title_model`
/// 全局配置后生成，供自动命名功能调用 LLM 生成标题使用。
///
/// 2026-07-28 新增 [protocol] / [providerOptions] 字段：
/// 之前 NamingConfig 只装 baseUrl/apiKey/modelId 3 个字段，导致所有用 NamingConfig
/// 构造 LlmRequest 的地方 protocol 默认 openaiCompatible，Claude/Gemini 适配器
/// 永远不被选中；providerOptions 透传机制也失效。现在 NamingConfig 完整承载
/// preset 的协议信息，确保 LlmRequest 构造时协议适配正确分发。
class NamingConfig {
  const NamingConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.modelId,
    this.presetId,
    this.protocol = LlmProtocol.openaiCompatible,
    this.providerOptions,
    this.maxOutputTokens,
  });

  /// API 基础地址（已含或不含 /v1 后缀，由 ApiUrlResolver 统一处理）
  final String baseUrl;

  /// API 密钥
  final String apiKey;

  /// 模型 ID
  final String modelId;

  /// 来源 API 预设 ID（2026-08-04 新增）
  ///
  /// 供调用方查询模型的 contextWindow 等预设级属性。
  /// null 表示来源不明（如降级构造），调用方应回退到默认值。
  final String? presetId;

  /// LLM 协议类型（决定 LlmAdapterFactory 分发目标）
  ///
  /// 默认 [LlmProtocol.openaiCompatible]，兼容 v0.1 旧数据。
  /// 由 [ConfigurationResolver] 从 ApiPreset.protocol 填充。
  final LlmProtocol protocol;

  /// 协议特有参数透传（高级用户配置，nullable）
  ///
  /// 由 [ConfigurationResolver] 从 ApiPreset.providerOptions 填充。
  /// null 表示无配置，适配器走默认逻辑。详见 [ApiPreset.providerOptions]。
  final Map<String, dynamic>? providerOptions;

  /// 当前模型元数据声明的最大输出 token 数。
  final int? maxOutputTokens;
}

/// 语义检索用 embedding API 配置（V1 启用语义检索）
///
/// 由 [ConfigurationResolver.resolveEmbeddingConfig] 解析全局 embedding 配置后生成，
/// 供 IntermediateChatController 调用 EmbeddingService.embed 使用。
///
/// 与 [NamingConfig] 的差异：
/// - 来源是 `intermediate.embedding_preset_id` / `intermediate.embedding_model_id`（独立于聊天模型）
/// - 含超时与降级开关（[timeoutMs] / [fallbackOnFailure]，来自 EmbeddingConfig）
/// - 全局配置（非会话级），因为 embedding 模型切换影响向量维度，会话级切换会导致向量不一致
class EmbeddingApiConfig {
  const EmbeddingApiConfig({
    required this.model,
    required this.baseUrl,
    required this.apiKey,
    required this.timeoutMs,
    required this.fallbackOnFailure,
  });

  /// embedding 模型 ID（如 text-embedding-3-small）
  final String model;

  /// API 基础地址
  final String baseUrl;

  /// API 密钥（nullable，部分本地部署供应商可为 null）
  final String? apiKey;

  /// embedding API 超时（毫秒）
  final int timeoutMs;

  /// 失败时是否降级到 FTS5（false = 失败则整轮失败）
  final bool fallbackOnFailure;
}

/// 全局默认配置快照（用于会话物化时复制到会话级）
///
/// 用户需求："如果使用的是全局设置的值，使用这一刻的值，
/// 而不是全局设置那一项的引用"。
///
/// 本类在会话物化时由 [ConfigurationResolver.snapshotSimpleDefaults] /
/// [ConfigurationResolver.snapshotIntermediateDefaults] 生成，
/// 包含当前全局配置的所有具体值。控制器将草稿值与快照值合并后写入会话级字段，
/// 实现快照语义：后续全局配置变更不影响已物化的会话。
///
/// 字段语义：
/// - 非 null：当前全局配置有具体值，应写入会话级字段
/// - null：该字段无全局默认（如 Simple 模式无 systemPrompt 全局默认），
///   会话级字段保持 null，由运行时回退逻辑处理
class GlobalDefaultsSnapshot {
  const GlobalDefaultsSnapshot({
    this.modelId,
    this.presetId,
    this.systemPrompt,
    this.temperature,
    this.topP,
    this.maxTokens,
    this.presencePenalty,
    this.frequencyPenalty,
    this.autoCompaction,
    this.compactionThreshold,
    this.streamEnabled,
    this.maxContextMessages,
    this.effectiveContextLimit,
    this.reasoningEffort,
    this.phaseModels,
    this.jsonMode,
    this.contextBudget,
    this.maxSteps,
    this.maxDurationMinutes,
    this.narrativePacing,
    this.toolPermissions,
    this.retrievalOverrides,
    this.reviewEnabled,
    this.suggestReplyPresetId,
    this.suggestReplyModelId,
    this.suggestReplyPromptOverride,
  });

  /// 导演会话面板全量快照化的补齐源——
  /// 此前物化只覆盖 11 列，maxSteps/toolPermissions/maxDurationMinutes/
  /// narrativePacing/retrievalOverrides 五列新建后仍 NULL 继承全局。
  final int? maxSteps;
  final int? maxDurationMinutes;
  final String? narrativePacing;

  /// 全局工具权限 map 快照（advanced.tools 原样；消费侧按需展开为
  /// 12 工具完整 map）
  final Map<String, String>? toolPermissions;

  /// 检索松紧度快照（「平衡」档=当前全局行为的具体值， 语义）
  final String? retrievalOverrides;

  /// 故事侧补齐源——审查开关与推荐回复三件
  /// （此前快照缺列，新建后仍 null 跟随）
  final bool? reviewEnabled;
  final String? suggestReplyPresetId;
  final String? suggestReplyModelId;
  final String? suggestReplyPromptOverride;

  /// 全局默认模型 ID（Simple 模式来自 broadcastChat.modelId；
  /// Intermediate 模式为 null，使用 phaseModels）
  final String? modelId;

  /// 全局默认供应商 ID（Simple 模式来自 broadcastChat.presetId 或第一个可用 preset；
  /// Intermediate 模式为 null）
  final String? presetId;

  /// 全局默认系统提示词（Intermediate 模式来自 intermediate.systemPrompt；
  /// Simple 模式为 null，运行时回退到内置默认）
  final String? systemPrompt;

  final double? temperature;
  final double? topP;
  final int? maxTokens;
  final double? presencePenalty;
  final double? frequencyPenalty;
  final bool? autoCompaction;
  final double? compactionThreshold;
  final bool? streamEnabled;
  final int? maxContextMessages;

  /// 全局默认单次请求 token 上限（仅 Intermediate 模式；
  /// 来自 intermediate.context.effective_context_limit）
  final int? effectiveContextLimit;

  final ReasoningEffort? reasoningEffort;

  /// 全局默认分步骤模型配置（仅 Intermediate 模式；全局 phaseModels 全空时为 null）
  final SessionPhaseModels? phaseModels;

  /// 全局默认工具调用开关（仅 Intermediate 模式；
  /// 来自 intermediate.stream.tool_calling_enabled）
  final bool? jsonMode;

  /// 全局默认上下文预算（仅 Intermediate 模式；
  /// 来自 intermediate.contextBudget，含 compactionTriggerRatio /
  /// recentMinRatio / retrievalRatio / recentMinTokenTarget）
  ///
  /// 物化时复制到会话级 override 字段，实现"快照独立"语义：
  /// 后续全局配置变更不影响已物化的会话。
  final ContextBudget? contextBudget;
}

/// 配置解析器
///
/// 统一管理模型信息解析、会话设置解析、命名配置解析等逻辑，
/// 从 ChatModeController 中抽离的配置相关职责。
///
/// 解析逻辑遵循统一的优先级规则：
/// - presetId：会话级 > 第一个可用 preset
/// - modelId：会话级 > 全局默认
/// - API Key：会话级 preset > 第一个有 key 的 preset
class ConfigurationResolver {
  ConfigurationResolver({
    required ApiPresetRepository presetRepository,
    required SettingsRepository settingsRepository,
    required Logger logger,
  })  : _presetRepository = presetRepository,
        _settingsRepository = settingsRepository,
        _logger = logger;

  final ApiPresetRepository _presetRepository;
  final SettingsRepository _settingsRepository;
  final Logger _logger;

  /// 默认上下文窗口大小（对标 ChatBox DEFAULT_CONTEXT_WINDOW）
  ///
  /// 用于未知模型，确保用户能看到"已用/上限"并触发自动压缩。
  static const int defaultContextWindow = 96000;

  /// 解析当前会话的模型显示信息（供应商名、模型名、上下文窗口）
  ///
  /// 供输入框工具栏的模型选择芯片和 token 计数警告使用。
  /// contextWindow 来源（对标 ChatBox 两级回退）：
  /// 1. 模型缓存中的 contextWindow 字段（用户通过"获取模型列表"或手动配置）
  /// 2. 默认值 [defaultContextWindow]（用于未知模型）
  Future<ModelDisplayInfo> resolveModelDisplayInfo(ChatSession session) async {
    try {
      final config = await _settingsRepository.getResolvedConfig();
      final chatConfig = config.broadcastChat;
      final presets = await _presetRepository.getAllPresets();

      // 1. 确定 preset：会话级 presetId 优先，否则取第一个
      final presetId = session.presetId ?? '';
      ApiPreset? preset;
      if (presetId.isNotEmpty) {
        preset = presets.where((p) => p.presetId == presetId).firstOrNull;
      }
      preset ??= presets.isNotEmpty ? presets.first : null;

      // 2. 确定 modelId：会话级 > 全局默认
      final modelId = session.modelId ?? chatConfig.modelId;

      // 3. 查找模型信息以获取 displayName 和 contextWindow
      String? modelName;
      int? contextWindow;
      var supportsReasoning = false;
      if (preset != null && modelId.isNotEmpty) {
        final model =
            preset.cachedModels.where((m) => m.modelId == modelId).firstOrNull;
        if (model != null) {
          modelName = model.displayName ?? model.modelId;
          contextWindow = model.contextWindow;
          supportsReasoning =
              model.capabilities.contains(ModelCapability.reasoning);
        } else {
          // 模型不在缓存列表中，直接使用 modelId 作为显示名
          modelName = modelId;
        }
        // 兜底：modelId 模式匹配推断（未在 cachedModels 中标记 reasoning 的模型）
        // 2026-07-27 新增：解决 DeepSeek/Qwen3/GLM 等供应商 /models 响应无
        // reasoning 字段导致能力标记缺失的问题
        if (!supportsReasoning && modelId.isNotEmpty) {
          supportsReasoning = ModelCapabilityInferrer.infersReasoning(modelId);
        }
      }

      // contextWindow 未知时使用默认值
      contextWindow ??= defaultContextWindow;

      return ModelDisplayInfo(
        modelName: modelName,
        providerName: preset?.name,
        contextWindowTokens: contextWindow,
        supportsReasoning: supportsReasoning,
      );
    } catch (e) {
      _logger.warn('Failed to resolve model display info', detail: '$e');
      return const ModelDisplayInfo(
        modelName: null,
        providerName: null,
        contextWindowTokens: defaultContextWindow,
      );
    }
  }

  /// 解析指定阶段模型的 contextWindow（供 UI 展示 token 预估）
  ///
  /// 从 presetId/modelId 查找模型的 contextWindow。
  /// 用于全局/会话级设置页展示生成阶段和审查阶段的 token 分配。
  ///
  /// - presetId/modelId 为空或模型未在缓存中时返回 [defaultContextWindow]
  /// - 调用方可选传入 [effectiveContextLimit] 取 min 值（应对 TPM 限制）
  Future<int> resolveContextWindowForPhase({
    String? presetId,
    String? modelId,
    int? effectiveContextLimit,
  }) async {
    var contextWindow = defaultContextWindow;

    if (presetId != null &&
        presetId.isNotEmpty &&
        modelId != null &&
        modelId.isNotEmpty) {
      try {
        final presets = await _presetRepository.getAllPresets();
        final preset = presets.where((p) => p.presetId == presetId).firstOrNull;
        if (preset != null) {
          final model = preset.cachedModels
              .where((m) => m.modelId == modelId)
              .firstOrNull;
          if (model?.contextWindow != null) {
            contextWindow = model!.contextWindow!;
          }
        }
      } catch (e) {
        _logger.warn('Failed to resolve contextWindow for phase', detail: '$e');
      }
    }

    // 取 min(effectiveContextLimit, modelWindow)，与控制器 _resolveContextWindow 一致
    if (effectiveContextLimit != null &&
        effectiveContextLimit > 0 &&
        effectiveContextLimit < contextWindow) {
      return effectiveContextLimit;
    }
    return contextWindow;
  }

  /// 解析模型显示名（从 preset 的 cachedModels 中查找）
  ///
  /// 优先使用模型的 displayName，找不到则使用 modelId 作为显示名。
  /// 用于写入助手消息的 modelName 字段，在消息下方显示。
  String? resolveModelDisplayName(ApiPreset? preset, String modelId) {
    if (preset == null || modelId.isEmpty) return null;
    final model =
        preset.cachedModels.where((m) => m.modelId == modelId).firstOrNull;
    if (model != null) {
      return model.displayName ?? model.modelId;
    }
    return modelId;
  }

  /// 解析会话设置（会话级设置优先，否则使用全局默认）
  ///
  /// 返回 [ChatSessionSettings] 和解析出的 API Key。
  /// API Key 解析逻辑：会话级 preset 的 key > 第一个有 key 的 preset。
  Future<({ChatSessionSettings settings, String? apiKey})> resolveSettings(
    ChatSession session,
  ) async {
    final config = await _settingsRepository.getResolvedConfig();
    final chatConfig = config.broadcastChat;

    // 1. 确定 presetId：会话级 > 第一个可用 preset
    var presetId = session.presetId ?? '';
    if (presetId.isEmpty) {
      final presets = await _presetRepository.getAllPresets();
      if (presets.isNotEmpty) {
        presetId = presets.first.presetId;
      }
    }

    // 2. 获取 API key（含 fallback 到其他有 key 的 preset）
    final (apiKey, effectivePresetId) = await _resolveApiKey(presetId);
    presetId = effectivePresetId;

    final settings = ChatSessionSettings(
      modelId: session.modelId ?? chatConfig.modelId,
      presetId: presetId,
      systemPrompt:
          session.systemPromptOverride ?? 'You are a helpful assistant.',
      temperature: session.temperature ?? chatConfig.temperature,
      topP: session.topP ?? chatConfig.topP,
      //  真 null：两级均 null（由模型决定）物化为 0（无上限哨兵）——
      // ChatSessionSettings.maxTokens 保持非空，出网层 null/0 等价
      //（OpenAI/Gemini 省略字段；Anthropic 用模型 maxOutput 元数据填充）
      maxTokens: session.maxTokens ??
          chatConfig.maxTokens ??
          OutputTokenPolicy.unlimited,
      autoCompaction: session.autoCompaction ?? chatConfig.autoCompaction,
      compactionThreshold:
          session.compactionThreshold ?? chatConfig.compactionThreshold,
      streamEnabled: session.streamEnabled ?? chatConfig.streamEnabled,
      // P0-A 修复：maxContextMessages 仅会话级配置，全局默认无此字段（null = 无限制）。
      // default_config.json 的 broadcastChat 不提供该字段，故这里不做 ?? chatConfig.xxx 回退。
      maxContextMessages: session.maxContextMessages,
      reasoningEffort: await _resolveReasoningEffort(session),
    );

    return (settings: settings, apiKey: apiKey);
  }

  /// 解析 API key：原 [presetId] 优先，无 key 时遍历所有 preset 找第一个有 key 的
  ///
  /// 抽取自 [resolveSettings] / [resolveTitleNamingConfig] / [resolveIntermediateSettings]
  /// 共用的 key 解析逻辑。
  ///
  /// 返回 (apiKey, effectivePresetId)：
  /// - 原 presetId 有 key → (key, presetId)
  /// - 原 presetId 无 key 但找到其他有 key 的 preset → (otherKey, otherPresetId)
  /// - 全部无 key 或 presetId 为空 → (null, presetId)
  Future<(String?, String)> _resolveApiKey(String presetId) async {
    if (presetId.isEmpty) return (null, presetId);

    String? apiKey;
    try {
      apiKey = await _settingsRepository.getApiKey(presetId);
    } catch (e) {
      _logger.warn(
        'Failed to load API key for preset $presetId',
        detail: '$e',
      );
    }

    if (apiKey != null && apiKey.isNotEmpty) {
      return (apiKey, presetId);
    }

    // 当前 preset 没有 key，尝试查找第一个有 key 的 preset
    final presets = await _presetRepository.getAllPresets();
    for (final preset in presets) {
      if (preset.presetId == presetId) continue;
      try {
        final key = await _settingsRepository.getApiKey(preset.presetId);
        if (key != null && key.isNotEmpty) {
          return (key, preset.presetId);
        }
      } catch (_) {
        continue;
      }
    }

    return (null, presetId);
  }

  /// 解析思考预算档位（会话级 > 全局默认）
  ///
  /// 优先级：
  /// 1. 会话级 [ChatSession.reasoningEffort]（用户在该会话设置中配置）
  /// 2. 全局默认（用户在通用设置中配置，存储于 user overrides 的
  ///    `broadcast_chat.reasoning_effort` key）
  /// 3. null（未配置，不发送 reasoning_effort 参数，由模型自行决定）
  Future<ReasoningEffort?> _resolveReasoningEffort(
    ChatSession session,
  ) async {
    if (session.reasoningEffort != null) {
      return session.reasoningEffort;
    }
    return _resolveGlobalReasoningEffort();
  }

  /// 解析全局默认思考预算档位（仅从 user overrides 读取，不含会话级）
  ///
  /// 用于 [snapshotSimpleDefaults] / [snapshotIntermediateDefaults]，
  /// 在会话物化时快照当前全局 reasoning effort 值。
  Future<ReasoningEffort?> _resolveGlobalReasoningEffort() async {
    try {
      final overrides = await _settingsRepository.getUserOverrides();
      // 容忍读取——裸 `as String?` 会让非 String
      // 标量（手改/异版本备份导入的 `"reasoning_effort": 1`）抛 TypeError
      // 被上层 catch 吞掉，全局思考档静默失联且 WARN 归因误导排障
      //（同族收口遗漏）。
      final raw = overrides['broadcast_chat.reasoning_effort'];
      final value = raw is String ? raw : null;
      return ReasoningEffort.fromString(value);
    } catch (e) {
      _logger.warn('Failed to load global reasoning effort', detail: '$e');
      return null;
    }
  }

  /// 解析自动命名所需的 API 配置（统一从 `common.title_model` 全局配置读取）
  ///
  /// **2026-07-21 配置架构重构**：原方法从会话级 modelId/presetId 推导标题模型，
  /// 与业务模型耦合，导致故事模式需要单独的 `resolveIntermediateNamingConfig`。
  /// 现统一收敛到 `common.title_model`，所有模式的会话标题生成都走此方法。
  ///
  /// 优先级：
  /// - **presetId**：`common.title_model.preset_id`（无则返回 null，标题降级为字符截取）
  /// - **modelId**：`common.title_model.model_id`（无则返回 null，标题降级为字符截取）
  /// - **API Key**：原 presetId 的 key > 第一个有 key 的 preset
  ///
  /// **2026-09-09 标题模型三级优先级**：本方法只负责第 1 级（配置的标题模型），
  /// 未配置或解析失败时返回 null；调用方应依次回退——第 2 级用该会话生成正文
  /// 的模型（Simple 走 [resolveBroadcastGeneratingNamingConfig]、故事走
  /// [resolveIntermediatePhaseNamingConfig] 'generating'、导演走
  /// [resolveAdvancedGeneratingNamingConfig]），第 3 级用
  /// `SessionTitleGenerator.fallbackTitle` 前缀兜底。
  /// 通用 preset+model → NamingConfig 解析（resource_ai 等工具面共用）。
  ///
  /// 与 [resolveAdvancedGeneratingNamingConfig] 同构但参数化：调用方自备
  /// presetId/modelId（如 resource_ai 首用快照后的 override）。解析失败
  /// （preset 不存在/无 key）返回 null。
  Future<NamingConfig?> resolvePresetModelNamingConfig(
    String presetId,
    String modelId,
  ) async {
    if (presetId.isEmpty || modelId.isEmpty) return null;
    try {
      final (apiKey, effectivePresetId) = await _resolveApiKey(presetId);
      if (apiKey == null || apiKey.isEmpty) return null;

      final preset = await _presetRepository.getPreset(effectivePresetId);
      final maxOutputTokens = preset.cachedModels
          .where((model) => model.modelId == modelId)
          .firstOrNull
          ?.maxOutput;

      return NamingConfig(
        baseUrl: preset.baseUrl,
        apiKey: apiKey,
        modelId: modelId,
        presetId: effectivePresetId,
        protocol: preset.protocol,
        providerOptions: preset.providerOptions,
        maxOutputTokens: maxOutputTokens,
      );
    } catch (e) {
      _logger.error(
        'Resolve preset model naming config failed',
        detail: '$presetId/$modelId: $e',
      );
      return null;
    }
  }

  Future<NamingConfig?> resolveTitleNamingConfig() async {
    try {
      final config = await _settingsRepository.getResolvedConfig();
      final titleModel = config.common.titleModel;
      if (!titleModel.isConfigured) return null;

      // 1. 确定 presetId：title_model.preset_id（无则尝试第一个可用 preset）
      var presetId = titleModel.presetId;
      if (presetId.isEmpty) {
        final presets = await _presetRepository.getAllPresets();
        if (presets.isNotEmpty) {
          presetId = presets.first.presetId;
        }
      }
      if (presetId.isEmpty) return null;

      // 2. 获取 API key（复用 _resolveApiKey）
      final (apiKey, effectivePresetId) = await _resolveApiKey(presetId);
      if (apiKey == null || apiKey.isEmpty) return null;
      presetId = effectivePresetId;

      // 3. 获取 preset
      final preset = await _presetRepository.getPreset(presetId);

      // 4. 确定 modelId：title_model.model_id
      final modelId = titleModel.modelId;
      if (modelId.isEmpty) return null;

      return NamingConfig(
        baseUrl: preset.baseUrl,
        apiKey: apiKey,
        modelId: modelId,
        presetId: effectivePresetId,
        protocol: preset.protocol,
        providerOptions: preset.providerOptions,
      );
    } catch (e) {
      _logger.error('Resolve title naming config failed', detail: '$e');
      return null;
    }
  }

  /// 解析 Simple 模式生成正文所用的模型 NamingConfig（标题模型回退用）
  ///
  /// 模型口径与 [resolveSettings] 一致：
  /// - **presetId**：会话级 `session.presetId` > 第一个可用 preset
  /// - **modelId**：会话级 `session.modelId` > `broadcast_chat.model_id`
  /// - **API Key**：`_resolveApiKey`（原 presetId 优先，无 key 时借其他有 key 的 preset）
  ///
  /// 用于标题模型三级优先级的第 2 级：`common.title_model` 未配置时，
  /// 以该会话生成正文的模型生成标题。任一层解析失败返回 null，
  /// 调用方降级 `SessionTitleGenerator.fallbackTitle` 前缀兜底。
  Future<NamingConfig?> resolveBroadcastGeneratingNamingConfig(
    ChatSession session,
  ) async {
    try {
      final config = await _settingsRepository.getResolvedConfig();
      final chatConfig = config.broadcastChat;

      final modelId = session.modelId ?? chatConfig.modelId;
      if (modelId.isEmpty) return null;

      var presetId = session.presetId ?? '';
      if (presetId.isEmpty) {
        final presets = await _presetRepository.getAllPresets();
        if (presets.isNotEmpty) {
          presetId = presets.first.presetId;
        }
      }
      if (presetId.isEmpty) return null;

      final (apiKey, effectivePresetId) = await _resolveApiKey(presetId);
      if (apiKey == null || apiKey.isEmpty) return null;

      final preset = await _presetRepository.getPreset(effectivePresetId);

      return NamingConfig(
        baseUrl: preset.baseUrl,
        apiKey: apiKey,
        modelId: modelId,
        presetId: effectivePresetId,
        protocol: preset.protocol,
        providerOptions: preset.providerOptions,
      );
    } catch (e) {
      _logger.error(
        'Resolve broadcast generating naming config failed',
        detail: '$e',
      );
      return null;
    }
  }

  /// 解析中级模式会话设置（2026-07-21 配置架构重构）
  ///
  /// **重构说明**：原方法优先级链 `session > intermediate > broadcastChat`
  /// 依赖已删除的 `intermediate.modelId` / `presetId` 中间层。重构后故事模式
  /// 只有两层模型配置（会话级 phaseModels + 全局 phaseModels），不再有单一
  /// "默认模型"。此方法仅返回生成参数 + 非生成参数，**modelId/presetId 返回空串**
  /// （实际分步骤模型解析由 [resolveIntermediatePhaseNamingConfig] 负责）。
  ///
  /// 优先级：
  /// - **modelId/presetId**：始终返回空串（由分步骤解析器负责）
  /// - **systemPrompt**：session.systemPromptOverride ?? ''（空串由 ContextBuilder 回退到
  ///   intermediate.systemPrompt → kDefaultRolePrompt）
  /// - **temperature/topP/maxTokens/presencePenalty/frequencyPenalty**（生成参数）：
  ///   会话级 > intermediate.generation（故事模式独立生成参数配置）
  /// - **reasoningEffort**（v0.2.2 新增独立链）：会话级 > intermediate.generation
  ///   .reasoning_effort > broadcast_chat.reasoning_effort（向后兼容）>
  ///   null。仅 generating/reviewing 阶段消费。
  /// - **streamEnabled/autoCompaction/compactionThreshold/maxContextMessages**：
  ///   会话级 > broadcastChat（这些非生成参数仍复用 Simple 模式默认）
  /// - **effectiveContextLimit**：会话级 > intermediate.context.effectiveContextLimit
  ///   （单次请求 token 上限，用于应对 TPM 限制）
  ///
  /// 权威设计：DOC-09B §10.2（2026-07-21 修订，2026-07-31 增 reasoningEffort 链）。
  Future<({ChatSessionSettings settings, String? apiKey})>
      resolveIntermediateSettings(ChatSession session) async {
    final config = await _settingsRepository.getResolvedConfig();
    final chatConfig = config.broadcastChat;
    final generation = config.intermediate.generation;

    // 故事模式业务模型走分步骤解析（resolveIntermediatePhaseNamingConfig），
    // 此处的 modelId/presetId 仅用于 ChatSessionSettings 结构填充，无实际业务意义。
    const presetId = '';
    const modelId = '';

    // v0.2.2：故事模式思考预算独立解析链（不与 Simple 共用 _resolveReasoningEffort）
    // 优先级：会话级 > intermediate.generation.reasoning_effort >
    // broadcast_chat.reasoning_effort（向后兼容）> null
    final intermediateReasoning = generation.reasoningEffort != null
        ? ReasoningEffort.fromString(generation.reasoningEffort)
        : null;
    final reasoningEffort = session.reasoningEffort ??
        intermediateReasoning ??
        await _resolveGlobalReasoningEffort();

    // API key 由分步骤解析器各自解析，此处返回 null（兼容旧调用签名）
    final settings = ChatSessionSettings(
      modelId: modelId,
      presetId: presetId,
      // 空串语义：由 IntermediateContextBuilder 回退到
      // intermediate.systemPrompt（globalSystemPrompt 参数）→ kDefaultRolePrompt
      systemPrompt: session.systemPromptOverride ?? '',
      // 生成参数：会话级 > intermediate.generation（不再回退 broadcastChat）
      temperature: session.temperature ?? generation.temperature,
      topP: session.topP ?? generation.topP,
      maxTokens: session.maxTokens ?? generation.maxTokens,
      presencePenalty: session.presencePenalty ?? generation.presencePenalty,
      frequencyPenalty: session.frequencyPenalty ?? generation.frequencyPenalty,
      // 非生成参数仍复用 broadcastChat 默认
      autoCompaction: session.autoCompaction ?? chatConfig.autoCompaction,
      compactionThreshold:
          session.compactionThreshold ?? chatConfig.compactionThreshold,
      streamEnabled: session.streamEnabled ?? chatConfig.streamEnabled,
      maxContextMessages: session.maxContextMessages,
      // 单次请求 token 上限：会话级 > intermediate.context.effectiveContextLimit
      effectiveContextLimit: session.effectiveContextLimit ??
          config.intermediate.context.effectiveContextLimit,
      reasoningEffort: reasoningEffort,
      // 审查会话级覆盖（透传，null = 用全局 reviewEnabled）
      // 控制器在 _runGeneratePhase 末尾自行做 `?? config.reviewEnabled` 回退
      reviewEnabledOverride: session.reviewEnabledOverride,
      // 审查  修复：contextBudget 会话级覆盖（透传）
      // 控制器在 _applyContextBudgetOverride 中合并到全局配置
      recentMinRatioOverride: session.recentMinRatioOverride,
      retrievalRatioOverride: session.retrievalRatioOverride,
      compactionTriggerRatioOverride: session.compactionTriggerRatioOverride,
    );

    return (settings: settings, apiKey: null);
  }

  /// 解析导演模式会话设置（2026-08-27 导演设置体系，设计文档 §6.1）。
  ///
  /// 与 [resolveIntermediateSettings] 同构但全局来源为 advanced 段
  /// （"两个产品"零依赖）：
  /// - 生成参数：会话列 > advanced.generation（无 broadcastChat 兜底）
  /// - systemPrompt：会话列 > advanced.system_prompt（全局值直接合入
  ///   settings，runner 仅在空串时回退内置编辑部规则——与故事模式不同，
  ///   故事靠消费侧三级回退，导演靠解析侧合并）
  /// - effectiveContextLimit：会话列 > advanced.context.effectiveContextLimit
  /// - contextBudget override：仅 compactionTriggerRatio 被导演消费（控制器
  ///   合并进聚合）；recentMin/retrieval 为故事遗产，导演组装侧定死 inert
  /// - autoCompaction/compactionThreshold/maxContextMessages：导演运行时
  ///   不消费，填 session 值透传（保持 ChatSessionSettings 结构完整）
  Future<({ChatSessionSettings settings, String? apiKey})>
      resolveAdvancedSettings(ChatSession session) async {
    final config = await _settingsRepository.getResolvedConfig();
    final advanced = config.advanced;
    final generation = advanced.generation;

    // 导演模型走 resolveAdvancedGeneratingNamingConfig 独立解析，
    // 此处的 modelId/presetId 仅用于 ChatSessionSettings 结构填充。
    const presetId = '';
    const modelId = '';

    final reasoningEffort = session.reasoningEffort ??
        (generation.reasoningEffort != null
            ? ReasoningEffort.fromString(generation.reasoningEffort)
            : null);

    final settings = ChatSessionSettings(
      modelId: modelId,
      presetId: presetId,
      systemPrompt: session.systemPromptOverride ?? advanced.systemPrompt,
      temperature: session.temperature ?? generation.temperature,
      topP: session.topP ?? generation.topP,
      maxTokens: session.maxTokens ?? generation.maxTokens,
      presencePenalty: session.presencePenalty ?? generation.presencePenalty,
      frequencyPenalty: session.frequencyPenalty ?? generation.frequencyPenalty,
      autoCompaction: session.autoCompaction ?? true,
      compactionThreshold: session.compactionThreshold ?? 0.6,
      streamEnabled: session.streamEnabled ?? true,
      maxContextMessages: session.maxContextMessages,
      effectiveContextLimit: session.effectiveContextLimit ??
          advanced.context.effectiveContextLimit,
      reasoningEffort: reasoningEffort,
      reviewEnabledOverride: session.reviewEnabledOverride,
      recentMinRatioOverride: session.recentMinRatioOverride,
      retrievalRatioOverride: session.retrievalRatioOverride,
      compactionTriggerRatioOverride: session.compactionTriggerRatioOverride,
    );

    return (settings: settings, apiKey: null);
  }

  /// 解析导演主模型（GM）NamingConfig（导演设置体系）
  ///
  /// 优先级链：会话 phaseModels.generating > advanced.phase_models.generating。
  /// 都未配置返回 null（调用方触发 E010，语义与故事 generating 一致）。
  /// 导演无六步 phase 结构，不读 intermediate.phase_models。
  Future<NamingConfig?> resolveAdvancedGeneratingNamingConfig(
    ChatSession session,
  ) async {
    try {
      final config = await _settingsRepository.getResolvedConfig();
      final advanced = config.advanced;

      final sessionPresetId = session.phaseModels.generatingPresetId;
      final sessionModelId = session.phaseModels.generatingModelId;
      final presetId = (sessionPresetId != null && sessionPresetId.isNotEmpty)
          ? sessionPresetId
          : advanced.generatingPresetId;
      final modelId = (sessionModelId != null && sessionModelId.isNotEmpty)
          ? sessionModelId
          : advanced.generatingModelId;
      if (presetId.isEmpty || modelId.isEmpty) return null;

      final (apiKey, effectivePresetId) = await _resolveApiKey(presetId);
      if (apiKey == null || apiKey.isEmpty) return null;

      final preset = await _presetRepository.getPreset(effectivePresetId);
      final maxOutputTokens = preset.cachedModels
          .where((model) => model.modelId == modelId)
          .firstOrNull
          ?.maxOutput;

      return NamingConfig(
        baseUrl: preset.baseUrl,
        apiKey: apiKey,
        modelId: modelId,
        presetId: effectivePresetId,
        protocol: preset.protocol,
        providerOptions: preset.providerOptions,
        maxOutputTokens: maxOutputTokens,
      );
    } catch (e) {
      _logger.error(
        'Resolve advanced generating naming config failed',
        detail: '$e',
      );
      return null;
    }
  }

  /// 解析中级模式指定阶段的 NamingConfig（分步骤模型配置）
  ///
  /// **2026-07-21 配置架构重构**：删除原 `intermediate.modelId` / `presetId`
  /// 中间层后，优先级链简化为两层：
  /// - **会话级**：`chat_sessions.{phase}_preset_id` / `{phase}_model_id`（8 列）
  /// - **全局级**：`intermediate.phase_models.{phase}_preset_id` / `{phase}_model_id`
  /// 都未配置时返回 null，调用方应：
  ///   - generating 阶段：触发 E010 配置错误，终止本轮生成
  ///   - 其他阶段：可降级复用 generating 阶段的 NamingConfig（由 controller 决定）
  ///
  /// [phase] 取值：`'generating'` | `'extracting'` | `'reviewing'` | `'summarizing'`。
  /// 非法值视为未配置，返回 null。
  Future<NamingConfig?> resolveIntermediatePhaseNamingConfig(
    ChatSession session,
    String phase,
  ) async {
    try {
      final config = await _settingsRepository.getResolvedConfig();
      final globalPhaseModels = config.intermediate.phaseModels;
      final sessionPhaseModels = session.phaseModels;

      // 1. 读取会话级 + 全局级 phase 模型配置
      final (sessionPresetId, sessionModelId) =
          sessionPhaseModels.forPhase(phase);
      final (globalPresetId, globalModelId) =
          _globalPhaseFor(globalPhaseModels, phase);
      // 非法 phase（forPhase 返回 (null, null) 且全局也为 (null, null)）
      if (sessionPresetId == null &&
          sessionModelId == null &&
          globalPresetId == null &&
          globalModelId == null) {
        return null;
      }

      // 2. 优先级合并：会话级 > 全局级
      final presetId = (sessionPresetId != null && sessionPresetId.isNotEmpty)
          ? sessionPresetId
          : (globalPresetId ?? '');
      final modelId = (sessionModelId != null && sessionModelId.isNotEmpty)
          ? sessionModelId
          : (globalModelId ?? '');
      if (presetId.isEmpty || modelId.isEmpty) return null;

      // 3. 获取 API key（复用 _resolveApiKey，含 fallback 到其他有 key 的 preset）
      final (apiKey, effectivePresetId) = await _resolveApiKey(presetId);
      if (apiKey == null || apiKey.isEmpty) return null;

      // 4. 获取 preset
      final preset = await _presetRepository.getPreset(effectivePresetId);
      final maxOutputTokens = preset.cachedModels
          .where((model) => model.modelId == modelId)
          .firstOrNull
          ?.maxOutput;

      return NamingConfig(
        baseUrl: preset.baseUrl,
        apiKey: apiKey,
        modelId: modelId,
        presetId: effectivePresetId,
        protocol: preset.protocol,
        providerOptions: preset.providerOptions,
        maxOutputTokens: maxOutputTokens,
      );
    } catch (e) {
      _logger.error(
        'Resolve intermediate phase naming config failed (phase=$phase)',
        detail: '$e',
      );
      return null;
    }
  }

  /// 从全局 PhaseModelsConfig 读取指定阶段的 (presetId, modelId)
  ///
  /// 返回 (null, null) 表示 phase 非法。
  (String?, String?) _globalPhaseFor(
    PhaseModelsConfig phaseModels,
    String phase,
  ) {
    switch (phase) {
      case 'generating':
        return (phaseModels.generatingPresetId, phaseModels.generatingModelId);
      case 'extracting':
        return (phaseModels.extractingPresetId, phaseModels.extractingModelId);
      case 'reviewing':
        return (phaseModels.reviewingPresetId, phaseModels.reviewingModelId);
      case 'summarizing':
        return (
          phaseModels.summarizingPresetId,
          phaseModels.summarizingModelId
        );
      default:
        return (null, null);
    }
  }

  /// 解析推荐回复功能的 NamingConfig
  ///
  /// 推荐回复功能：点击按钮调用 LLM 生成 3 条候选用户回复。
  ///
  /// **优先级链**（2026-07-29 新增）：
  /// 1. 会话级 `suggestReplyPresetId` / `suggestReplyModelId`
  /// 2. 全局 `intermediate.suggest_reply.preset_id` / `model_id`
  /// 3. generating 阶段模型（fallback，复用 [resolveIntermediatePhaseNamingConfig]）
  ///
  /// 返回 null 表示所有层级均未配置（含 generating fallback 也失败），
  /// 调用方应禁用推荐回复按钮。
  Future<NamingConfig?> resolveSuggestReplyNamingConfig(
    ChatSession session,
  ) async {
    try {
      final config = await _settingsRepository.getResolvedConfig();
      final globalSuggestReply = config.intermediate.suggestReply;

      // 1. 优先级合并：会话级 > 全局级
      final presetId = (session.suggestReplyPresetId != null &&
              session.suggestReplyPresetId!.isNotEmpty)
          ? session.suggestReplyPresetId!
          : (globalSuggestReply.presetId.isNotEmpty
              ? globalSuggestReply.presetId
              : '');
      final modelId = (session.suggestReplyModelId != null &&
              session.suggestReplyModelId!.isNotEmpty)
          ? session.suggestReplyModelId!
          : (globalSuggestReply.modelId.isNotEmpty
              ? globalSuggestReply.modelId
              : '');

      // 2. 未配置推荐回复专用模型 → fallback 到 generating 阶段
      if (presetId.isEmpty || modelId.isEmpty) {
        return await resolveIntermediatePhaseNamingConfig(
          session,
          'generating',
        );
      }

      // 3. 获取 API key（复用 _resolveApiKey，含 fallback 到其他有 key 的 preset）
      final (apiKey, effectivePresetId) = await _resolveApiKey(presetId);
      if (apiKey == null || apiKey.isEmpty) {
        // API key 解析失败 → fallback 到 generating 阶段
        return await resolveIntermediatePhaseNamingConfig(
          session,
          'generating',
        );
      }

      // 4. 获取 preset
      final preset = await _presetRepository.getPreset(effectivePresetId);

      return NamingConfig(
        baseUrl: preset.baseUrl,
        apiKey: apiKey,
        modelId: modelId,
        presetId: effectivePresetId,
        protocol: preset.protocol,
        providerOptions: preset.providerOptions,
      );
    } catch (e) {
      _logger.error(
        'Resolve suggest reply naming config failed',
        detail: '$e',
      );
      // 异常时 fallback 到 generating 阶段
      return resolveIntermediatePhaseNamingConfig(session, 'generating');
    }
  }

  /// 解析推荐回复功能的系统提示词
  ///
  /// **优先级链**：
  /// 1. 会话级 `suggestReplyPromptOverride`
  /// 2. 全局 `intermediate.suggest_reply.prompt`
  /// 3. 内置默认提示词（`kSuggestReplyDefaultPrompt`）
  Future<String> resolveSuggestReplyPrompt(ChatSession session) async {
    try {
      // 1. 会话级覆盖
      if (session.suggestReplyPromptOverride != null &&
          session.suggestReplyPromptOverride!.isNotEmpty) {
        return session.suggestReplyPromptOverride!;
      }
      // 2. 全局配置
      final config = await _settingsRepository.getResolvedConfig();
      final globalPrompt = config.intermediate.suggestReply.prompt;
      if (globalPrompt.isNotEmpty) {
        return globalPrompt;
      }
    } catch (e) {
      _logger.warn(
        'Resolve suggest reply prompt failed, using default',
        detail: '$e',
      );
    }
    // 3. 内置默认
    return kSuggestReplyDefaultPrompt;
  }

  /// 解析导演模式推荐回复模型 NamingConfig（"两个产品"零依赖）
  ///
  /// 优先级链与 [resolveSuggestReplyNamingConfig] 同构，但全局来源为
  /// advanced 段、fallback 为导演 GM 模型：
  /// 1. 会话级 `suggestReplyPresetId/ModelId`
  /// 2. 全局 `advanced.suggest_reply.preset_id/model_id`
  /// 3. 导演 GM 模型（`resolveAdvancedGeneratingNamingConfig`）
  Future<NamingConfig?> resolveAdvancedSuggestReplyNamingConfig(
    ChatSession session,
  ) async {
    try {
      final config = await _settingsRepository.getResolvedConfig();
      final globalSuggestReply = config.advanced.suggestReply;

      final presetId = (session.suggestReplyPresetId != null &&
              session.suggestReplyPresetId!.isNotEmpty)
          ? session.suggestReplyPresetId!
          : (globalSuggestReply.presetId.isNotEmpty
              ? globalSuggestReply.presetId
              : '');
      final modelId = (session.suggestReplyModelId != null &&
              session.suggestReplyModelId!.isNotEmpty)
          ? session.suggestReplyModelId!
          : (globalSuggestReply.modelId.isNotEmpty
              ? globalSuggestReply.modelId
              : '');

      // 未配置推荐回复专用模型 → fallback 到导演 GM
      if (presetId.isEmpty || modelId.isEmpty) {
        return await resolveAdvancedGeneratingNamingConfig(session);
      }

      final (apiKey, effectivePresetId) = await _resolveApiKey(presetId);
      if (apiKey == null || apiKey.isEmpty) {
        return await resolveAdvancedGeneratingNamingConfig(session);
      }

      final preset = await _presetRepository.getPreset(effectivePresetId);

      return NamingConfig(
        baseUrl: preset.baseUrl,
        apiKey: apiKey,
        modelId: modelId,
        presetId: effectivePresetId,
        protocol: preset.protocol,
        providerOptions: preset.providerOptions,
      );
    } catch (e) {
      _logger.error(
        'Resolve advanced suggest reply naming config failed',
        detail: '$e',
      );
      return resolveAdvancedGeneratingNamingConfig(session);
    }
  }

  /// 解析导演模式推荐回复系统提示词
  ///
  /// 优先级链：会话级覆盖 > `advanced.suggest_reply.prompt` > 内置默认。
  Future<String> resolveAdvancedSuggestReplyPrompt(ChatSession session) async {
    try {
      if (session.suggestReplyPromptOverride != null &&
          session.suggestReplyPromptOverride!.isNotEmpty) {
        return session.suggestReplyPromptOverride!;
      }
      final config = await _settingsRepository.getResolvedConfig();
      final globalPrompt = config.advanced.suggestReply.prompt;
      if (globalPrompt.isNotEmpty) {
        return globalPrompt;
      }
    } catch (e) {
      _logger.warn(
        'Resolve advanced suggest reply prompt failed, using default',
        detail: '$e',
      );
    }
    return kSuggestReplyDefaultPrompt;
  }

  /// 解析语义检索用 embedding API 配置（V1 启用语义检索）
  ///
  /// 全局配置（非会话级）：读取 `intermediate.embedding_preset_id` /
  /// `intermediate.embedding_model_id`（DOC-08 §3.4 纯 API 方案）。
  ///
  /// 返回 null 的情形（均降级为 FTS5 兜底，DOC-09A-1 §3.7）：
  /// - 未配置 embedding preset 或 model（空串）
  /// - preset 不存在（已被删除）
  /// - 该 preset 无 API Key
  ///
  /// embedding 模型与聊天模型独立：用户可为 embedding 配置不同供应商
  /// （如聊天用 DeepSeek，embedding 用 OpenAI text-embedding-3-small）。
  /// 全局统一避免会话内向量维度不一致。
  Future<EmbeddingApiConfig?> resolveEmbeddingConfig() async {
    try {
      final config = await _settingsRepository.getResolvedConfig();
      final intermediate = config.intermediate;
      final presetId = intermediate.embeddingPresetId;
      final modelId = intermediate.embeddingModelId;
      if (presetId.isEmpty || modelId.isEmpty) return null;

      final preset = await _presetRepository.getPreset(presetId);
      final apiKey = await _settingsRepository.getApiKey(presetId);
      if (apiKey == null || apiKey.isEmpty) return null;

      return EmbeddingApiConfig(
        model: modelId,
        baseUrl: preset.baseUrl,
        apiKey: apiKey,
        timeoutMs: intermediate.embedding.timeoutMs,
        fallbackOnFailure: intermediate.embedding.fallbackOnFailure,
      );
    } catch (e) {
      _logger.warn('Resolve embedding config failed', detail: '$e');
      return null;
    }
  }

  /// 解析导演模式 embedding 配置（导演设置体系）
  ///
  /// 与 [resolveEmbeddingConfig] 同构但来源为 advanced.embedding*——
  /// 导演不再寄生 intermediate.embedding*（"两个产品"零依赖）。
  Future<EmbeddingApiConfig?> resolveAdvancedEmbeddingConfig() async {
    try {
      final config = await _settingsRepository.getResolvedConfig();
      final advanced = config.advanced;
      final presetId = advanced.embeddingPresetId;
      final modelId = advanced.embeddingModelId;
      if (presetId.isEmpty || modelId.isEmpty) return null;

      final preset = await _presetRepository.getPreset(presetId);
      final apiKey = await _settingsRepository.getApiKey(presetId);
      if (apiKey == null || apiKey.isEmpty) return null;

      return EmbeddingApiConfig(
        model: modelId,
        baseUrl: preset.baseUrl,
        apiKey: apiKey,
        timeoutMs: advanced.embedding.timeoutMs,
        fallbackOnFailure: advanced.embedding.fallbackOnFailure,
      );
    } catch (e) {
      _logger.warn('Resolve advanced embedding config failed', detail: '$e');
      return null;
    }
  }

  /// 解析微摘要向量化阈值（microVectorizeThreshold）。
  ///
  /// 2026-07-22 新增：用于重建向量索引时按 importance 筛选，对齐持久化时的
  /// 两级向量化策略。持久化时 importance < microVectorizeThreshold(默认4) 的
  /// 记忆有意不建 embedding，重建时也不应补齐这些记忆。
  ///
  /// v0.2.3：microVectorizeThreshold 从 memory.macroSummary 移至
  /// retrieval 配置组。
  ///
  /// 返回阈值（默认 4），异常时返回默认值。
  Future<int> resolveMicroVectorizeThreshold() async {
    try {
      final config = await _settingsRepository.getResolvedConfig();
      return config.intermediate.retrieval.microVectorizeThreshold;
    } catch (_) {
      return 4;
    }
  }

  /// 解析全局网络超时配置（连接/读取）。
  ///
  /// 用于故事模式（intermediate）9 处 LlmRequest 构造点透传 timeout。
  /// 修复前：故事模式所有 LlmRequest 未传 timeout，回退到 HttpClient
  /// 硬编码 15s/30s，用户在通用设置→高级调整的超时值对故事模式无效。
  ///
  /// 配置来源：`network.connect_timeout_ms` / `network.receive_timeout_ms`
  /// （由通用设置→高级 → TimeoutSection 写入 user_overrides）。
  /// 返回 (connectTimeout, readTimeout)，单位 Duration。
  Future<({Duration connectTimeout, Duration readTimeout})>
      resolveTimeouts() async {
    try {
      final config = await _settingsRepository.getResolvedConfig();
      final network = config.network;
      return (
        connectTimeout: network.connectTimeout,
        readTimeout: network.receiveTimeout,
      );
    } catch (e) {
      _logger.warn('Resolve timeouts failed', detail: '$e');
      // 失败时回落到 HttpClient 默认值（与修复前行为一致，避免阻断流程）
      return (
        connectTimeout: const Duration(seconds: 15),
        readTimeout: const Duration(seconds: 30),
      );
    }
  }

  /// 快照 Simple 模式当前全局默认值（用于会话物化）
  ///
  /// 用户需求："会话成立的标志是发第一条消息或会话配置变更"。
  /// 草稿会话物化为真实会话时，调用本方法将当前 broadcastChat 全局默认 +
  /// reasoning effort 全局配置作为具体值返回。控制器合并草稿值与快照值后
  /// 写入会话级字段，实现"快照而非引用"语义。
  ///
  /// 字段来源：
  /// - modelId/presetId：broadcastChat.modelId / presetId（presetId 为空时
  ///   fallback 到第一个可用 preset，与 [resolveSettings] 一致）
  /// - temperature/topP/maxTokens/autoCompaction/compactionThreshold/streamEnabled：
  ///   broadcastChat 对应字段
  /// - reasoningEffort：user overrides 的 `broadcast_chat.reasoning_effort`
  /// - systemPrompt/presencePenalty/frequencyPenalty/maxContextMessages/phaseModels：
  ///   null（Simple 模式无对应全局默认）
  Future<GlobalDefaultsSnapshot> snapshotSimpleDefaults() async {
    try {
      final config = await _settingsRepository.getResolvedConfig();
      final chatConfig = config.broadcastChat;

      // presetId: 全局默认 > 第一个可用 preset（与 resolveSettings 一致）
      var presetId = chatConfig.presetId;
      if (presetId.isEmpty) {
        final presets = await _presetRepository.getAllPresets();
        if (presets.isNotEmpty) {
          presetId = presets.first.presetId;
        }
      }

      final reasoningEffort = await _resolveGlobalReasoningEffort();

      return GlobalDefaultsSnapshot(
        modelId: chatConfig.modelId.isEmpty ? null : chatConfig.modelId,
        presetId: presetId.isEmpty ? null : presetId,
        temperature: chatConfig.temperature,
        topP: chatConfig.topP,
        maxTokens: chatConfig.maxTokens,
        autoCompaction: chatConfig.autoCompaction,
        compactionThreshold: chatConfig.compactionThreshold,
        streamEnabled: chatConfig.streamEnabled,
        reasoningEffort: reasoningEffort,
      );
    } catch (e) {
      _logger.warn('Failed to snapshot simple defaults', detail: '$e');
      return const GlobalDefaultsSnapshot();
    }
  }

  /// 快照 Intermediate 模式当前全局默认值（用于会话物化）
  ///
  /// 与 [snapshotSimpleDefaults] 对应，但字段来源不同：
  /// - temperature/topP/maxTokens/presencePenalty/frequencyPenalty：
  ///   intermediate.generation（故事模式独立生成参数）
  /// - systemPrompt：intermediate.systemPrompt（全局默认系统提示词）
  /// - autoCompaction/compactionThreshold/streamEnabled：broadcastChat
  ///   （非生成参数仍复用 Simple 模式默认）
  /// - reasoningEffort：intermediate.generation.reasoning_effort（v0.2.2 新增）
  ///   为 null 时回退 broadcast_chat.reasoning_effort（向后兼容）
  /// - phaseModels：intermediate.phaseModels（全局分步骤模型配置）
  /// - modelId/presetId/maxContextMessages：null（Intermediate 模式不使用
  ///   单一 modelId/presetId，由 phaseModels 负责；maxContextMessages 无全局默认）
  /// - effectiveContextLimit：intermediate.context.effectiveContextLimit
  ///   （单次请求 token 上限全局默认）
  Future<GlobalDefaultsSnapshot> snapshotIntermediateDefaults() async {
    try {
      final config = await _settingsRepository.getResolvedConfig();
      final chatConfig = config.broadcastChat;
      final generation = config.intermediate.generation;

      // v0.2.2：故事模式思考预算优先读 intermediate.generation.reasoning_effort，
      // 为 null 时回退 broadcast_chat.reasoning_effort（向后兼容旧用户）。
      // 作用范围：仅 generating/reviewing 阶段消费（详见 GenerationConfig 注释）。
      final intermediateReasoning = generation.reasoningEffort != null
          ? ReasoningEffort.fromString(generation.reasoningEffort)
          : null;
      final reasoningEffort =
          intermediateReasoning ?? await _resolveGlobalReasoningEffort();

      // 快照全局分步骤模型配置（空串转 null）
      final globalPhaseModels = config.intermediate.phaseModels;
      final phaseModels = SessionPhaseModels(
        generatingPresetId: globalPhaseModels.generatingPresetId.isEmpty
            ? null
            : globalPhaseModels.generatingPresetId,
        generatingModelId: globalPhaseModels.generatingModelId.isEmpty
            ? null
            : globalPhaseModels.generatingModelId,
        extractingPresetId: globalPhaseModels.extractingPresetId.isEmpty
            ? null
            : globalPhaseModels.extractingPresetId,
        extractingModelId: globalPhaseModels.extractingModelId.isEmpty
            ? null
            : globalPhaseModels.extractingModelId,
        reviewingPresetId: globalPhaseModels.reviewingPresetId.isEmpty
            ? null
            : globalPhaseModels.reviewingPresetId,
        reviewingModelId: globalPhaseModels.reviewingModelId.isEmpty
            ? null
            : globalPhaseModels.reviewingModelId,
        summarizingPresetId: globalPhaseModels.summarizingPresetId.isEmpty
            ? null
            : globalPhaseModels.summarizingPresetId,
        summarizingModelId: globalPhaseModels.summarizingModelId.isEmpty
            ? null
            : globalPhaseModels.summarizingModelId,
      );

      return GlobalDefaultsSnapshot(
        systemPrompt: config.intermediate.systemPrompt.isEmpty
            ? null
            : config.intermediate.systemPrompt,
        temperature: generation.temperature,
        topP: generation.topP,
        maxTokens: generation.maxTokens,
        presencePenalty: generation.presencePenalty,
        frequencyPenalty: generation.frequencyPenalty,
        autoCompaction: chatConfig.autoCompaction,
        compactionThreshold: chatConfig.compactionThreshold,
        streamEnabled: chatConfig.streamEnabled,
        effectiveContextLimit:
            config.intermediate.context.effectiveContextLimit,
        reasoningEffort: reasoningEffort,
        phaseModels: phaseModels.isAllEmpty ? null : phaseModels,
        jsonMode: config.intermediate.stream.toolCallingEnabled,
        contextBudget: config.intermediate.contextBudget,
        // 故事侧补齐源（reviewEnabled+suggestReply 三件）
        reviewEnabled: config.intermediate.reviewEnabled,
        suggestReplyPresetId: config.intermediate.suggestReply.presetId.isEmpty
            ? null
            : config.intermediate.suggestReply.presetId,
        suggestReplyModelId: config.intermediate.suggestReply.modelId.isEmpty
            ? null
            : config.intermediate.suggestReply.modelId,
        suggestReplyPromptOverride:
            config.intermediate.suggestReply.prompt.isEmpty
                ? null
                : config.intermediate.suggestReply.prompt,
      );
    } catch (e) {
      _logger.warn('Failed to snapshot intermediate defaults', detail: '$e');
      return const GlobalDefaultsSnapshot();
    }
  }

  /// 快照导演模式当前全局默认值（用于会话物化，导演设置体系）
  ///
  /// 与 [snapshotIntermediateDefaults] 对应但来源为 advanced 段：
  /// - 生成参数：advanced.generation
  /// - systemPrompt：advanced.system_prompt
  /// - phaseModels：仅 generating（导演无六步 phase），其余为 null
  /// - jsonMode：null（审查移除：导演不消费该列，不再物化）
  /// - autoCompaction/compactionThreshold：null（导演运行时不消费这些列，
  ///   保持 null = 无全局默认，不物化 Simple 模式值）
  /// - streamEnabled：透传 broadcastChat 全局值（②，2026-09-14 订正：
  ///    快照化后会话列物化需要全局具体值，方法体已透传，注释此前未跟）
  Future<GlobalDefaultsSnapshot> snapshotAdvancedDefaults() async {
    try {
      final config = await _settingsRepository.getResolvedConfig();
      final advanced = config.advanced;
      final generation = advanced.generation;

      final reasoningEffort = generation.reasoningEffort != null
          ? ReasoningEffort.fromString(generation.reasoningEffort)
          : null;

      final phaseModels = SessionPhaseModels(
        generatingPresetId: advanced.generatingPresetId.isEmpty
            ? null
            : advanced.generatingPresetId,
        generatingModelId: advanced.generatingModelId.isEmpty
            ? null
            : advanced.generatingModelId,
      );

      return GlobalDefaultsSnapshot(
        systemPrompt:
            advanced.systemPrompt.isEmpty ? null : advanced.systemPrompt,
        temperature: generation.temperature,
        topP: generation.topP,
        maxTokens: generation.maxTokens,
        presencePenalty: generation.presencePenalty,
        frequencyPenalty: generation.frequencyPenalty,
        effectiveContextLimit: advanced.context.effectiveContextLimit,
        reasoningEffort: reasoningEffort,
        phaseModels: phaseModels.isAllEmpty ? null : phaseModels,
        //  审查移除：导演 agent 循环不消费 jsonMode/toolCalling 开关，
        // 不再把该值快照进会话列（存量会话列值保留但 inert）
        // 上下文配置收敛：contextBudget 按导演形态收窄——
        // 物化只消费压缩阈值，三段式遗产参数由 DirectorContextBudgetPin
        // 定死（检索预留 0、原文区下限动态），不再随快照进会话列
        contextBudget: advanced.contextBudget.directorPinned,
        // 新建/存量物化补齐五列（retrievalOverrides
        // 因 RetrievalProfile 属 advanced 实体，由 controller 物化时补）；
        // streamEnabled 的全局源是通用设置 broadcast_chat（原快照漏填）
        streamEnabled: config.broadcastChat.streamEnabled,
        maxSteps: advanced.defaults.maxSteps,
        maxDurationMinutes: advanced.budget.maxDurationMinutes,
        narrativePacing: advanced.narrativePacing,
        toolPermissions: advanced.tools.isEmpty ? null : advanced.tools,
      );
    } catch (e) {
      _logger.warn('Failed to snapshot advanced defaults', detail: '$e');
      return const GlobalDefaultsSnapshot();
    }
  }
}
