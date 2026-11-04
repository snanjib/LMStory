import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/model_registry/model_registry.dart';
import 'package:lmstory/core/network/llm_adapters/sampling_params.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/settings/data/provider_templates.dart'
    show ProviderTemplates;
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/display_preferences.dart';
import 'package:lmstory/features/settings/domain/entities/input_keys.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';

/// Settings 模块状态
class SettingsState {
  const SettingsState({
    this.presets = const [],
    this.defaultPresetId,
    this.apiKeyStatus = const {},
    this.templates = const [],
    this.isLoading = false,
    this.isTestingConnection = false,
    this.isFetchingModels = false,
    this.error,
    this.testResult,
    this.fetchModelsError,
    this.fontSize = 15,
    this.contentWidthMode = LmContentWidthMode.fluid,
    this.autoCompaction = true,
    this.compactionThreshold = 0.6,
    this.defaultModelId,
    this.sendKey = SendKey.enter,
    this.newlineKey = NewlineKey.shiftEnter,
    this.displayPreferences = const DisplayPreferences(),
    this.connectTimeoutSec = 15,
    this.receiveTimeoutSec = 30,
    this.directorResponseStartTimeoutSec = 600,
    this.directorNonStreamingTimeoutSec = 600,
    this.autoRetryMaxAttempts = 5,
    this.autoRetryWaitBudgetSec = 90,
    this.defaultReasoningEffort,
    this.titleModelPresetId,
    this.titleModelModelId,
    this.globalTemperature = 0.7,
    this.globalTopP = 1.0,
    this.globalMaxTokens,
    this.globalStreamEnabled = true,
  });

  /// API 预设（供应商）列表
  final List<ApiPreset> presets;

  /// 默认供应商 ID（新对话建立时默认填充的 presetId）。
  ///
  /// 注意：供应商配置本身没有"激活/选择"的概念，这里只是新对话的默认
  /// 填充值，由"默认模型"选择页隐式设置（选模型时同时记录 presetId）。
  final String? defaultPresetId;

  /// API Key 状态映射：presetId -> 是否已设置
  final Map<String, bool> apiKeyStatus;

  /// 模板列表
  final List<Template> templates;

  /// 是否正在加载
  final bool isLoading;

  /// 是否正在测试连接
  final bool isTestingConnection;

  /// 是否正在获取模型列表
  final bool isFetchingModels;

  /// 错误信息
  final String? error;

  /// 测试连接结果
  final String? testResult;

  /// 获取模型列表错误
  final String? fetchModelsError;

  /// 字体大小（int，与 SimpleTextStyles.body 基准字号 15px 联动）。
  ///
  /// 范围 12-22，默认 15。fontScale = fontSize / 15.0，应用到消息气泡。
  /// 改造自原 `fontSizeIndex` (0/1/2 离散索引)——参考 ChatBox 连续 Slider。
  final int fontSize;

  /// 内容宽度模式（通用设置-外观）：流式（随窗口放大，默认）/
  /// 固定上限（超宽屏不拉长）。版心消费面经 LmContentWidthScope 下发。
  final LmContentWidthMode contentWidthMode;

  /// 是否启用自动压缩
  final bool autoCompaction;

  /// 压缩阈值百分比（0.4-0.9，默认 0.6），对标 ChatBox compactionThreshold
  final double compactionThreshold;

  /// 默认模型 ID（新对话建立时默认填充的 modelId）
  final String? defaultModelId;

  /// 发送键
  final SendKey sendKey;

  /// 换行键（桌面端）
  final NewlineKey newlineKey;

  /// 显示偏好设置
  final DisplayPreferences displayPreferences;

  /// 连接超时（秒）— 连接服务器的最长等待时间
  final int connectTimeoutSec;

  /// 响应超时（秒）— 等待模型回复的最长时间（无数据接收超时）
  final int receiveTimeoutSec;
  final int directorResponseStartTimeoutSec;
  final int directorNonStreamingTimeoutSec;

  /// 自动重试次数上限（2026-10-15 批 E / P5：三模式共享底座，0-5）
  final int autoRetryMaxAttempts;

  /// 自动重试累计等待预算（秒；0 = 不限，P6）
  final int autoRetryWaitBudgetSec;

  /// 默认思考预算档位（新会话的默认值，null = 未配置）
  ///
  /// 用户在通用设置中配置，会话级设置可覆盖。仅对具备 reasoning 能力的模型生效。
  final ReasoningEffort? defaultReasoningEffort;

  /// 会话标题模型供应商 ID（2026-07-21 新增）
  ///
  /// 独立于业务模式，用于所有模式的会话标题自动生成。
  /// 存储于 `common.title_model.preset_id`。null = 未配置，标题降级为字符截取。
  final String? titleModelPresetId;

  /// 会话标题模型 ID（2026-07-21 新增）
  ///
  /// 存储于 `common.title_model.model_id`。null = 未配置。
  final String? titleModelModelId;

  /// 全局生成参数默认值（2026-07-22 新增，对标 ChatBox Default Settings for New Conversation）
  ///
  /// 存储于 `broadcast_chat.*`，会话级字段 snapshot 时读取这些值。
  /// 修改全局参数不影响已物化的会话（快照语义）。
  final double globalTemperature;
  final double globalTopP;
  final int? globalMaxTokens;
  final bool globalStreamEnabled;

  SettingsState copyWith({
    List<ApiPreset>? presets,
    String? defaultPresetId,
    Map<String, bool>? apiKeyStatus,
    List<Template>? templates,
    bool? isLoading,
    bool? isTestingConnection,
    bool? isFetchingModels,
    Object? error = _sentinel,
    Object? testResult = _sentinel,
    int? fontSize,
    LmContentWidthMode? contentWidthMode,
    bool? autoCompaction,
    double? compactionThreshold,
    String? defaultModelId,
    SendKey? sendKey,
    NewlineKey? newlineKey,
    DisplayPreferences? displayPreferences,
    int? connectTimeoutSec,
    int? receiveTimeoutSec,
    int? directorResponseStartTimeoutSec,
    int? directorNonStreamingTimeoutSec,
    int? autoRetryMaxAttempts,
    int? autoRetryWaitBudgetSec,
    Object? defaultReasoningEffort = _sentinel,
    Object? titleModelPresetId = _sentinel,
    Object? fetchModelsError = _sentinel,
    Object? titleModelModelId = _sentinel,
    double? globalTemperature,
    double? globalTopP,
    Object? globalMaxTokens = _sentinel,
    bool? globalStreamEnabled,
  }) =>
      SettingsState(
        presets: presets ?? this.presets,
        defaultPresetId: defaultPresetId ?? this.defaultPresetId,
        apiKeyStatus: apiKeyStatus ?? this.apiKeyStatus,
        templates: templates ?? this.templates,
        isLoading: isLoading ?? this.isLoading,
        isTestingConnection: isTestingConnection ?? this.isTestingConnection,
        isFetchingModels: isFetchingModels ?? this.isFetchingModels,
        error: error == _sentinel ? this.error : error as String?,
        // testResult 改哨兵语义——
        // null 合并模式下「传 null 清除」永远走不进（?? 回退旧值），
        // clearTestResult() 曾是恒空操作
        testResult:
            testResult == _sentinel ? this.testResult : testResult as String?,
        fetchModelsError: fetchModelsError == _sentinel
            ? this.fetchModelsError
            : fetchModelsError as String?,
        fontSize: fontSize ?? this.fontSize,
        contentWidthMode: contentWidthMode ?? this.contentWidthMode,
        autoCompaction: autoCompaction ?? this.autoCompaction,
        compactionThreshold: compactionThreshold ?? this.compactionThreshold,
        defaultModelId: defaultModelId ?? this.defaultModelId,
        sendKey: sendKey ?? this.sendKey,
        newlineKey: newlineKey ?? this.newlineKey,
        displayPreferences: displayPreferences ?? this.displayPreferences,
        connectTimeoutSec: connectTimeoutSec ?? this.connectTimeoutSec,
        receiveTimeoutSec: receiveTimeoutSec ?? this.receiveTimeoutSec,
        directorResponseStartTimeoutSec: directorResponseStartTimeoutSec ??
            this.directorResponseStartTimeoutSec,
        directorNonStreamingTimeoutSec: directorNonStreamingTimeoutSec ??
            this.directorNonStreamingTimeoutSec,
        autoRetryMaxAttempts: autoRetryMaxAttempts ?? this.autoRetryMaxAttempts,
        autoRetryWaitBudgetSec:
            autoRetryWaitBudgetSec ?? this.autoRetryWaitBudgetSec,
        defaultReasoningEffort: defaultReasoningEffort == _sentinel
            ? this.defaultReasoningEffort
            : defaultReasoningEffort as ReasoningEffort?,
        titleModelPresetId: titleModelPresetId == _sentinel
            ? this.titleModelPresetId
            : titleModelPresetId as String?,
        titleModelModelId: titleModelModelId == _sentinel
            ? this.titleModelModelId
            : titleModelModelId as String?,
        globalTemperature: globalTemperature ?? this.globalTemperature,
        globalTopP: globalTopP ?? this.globalTopP,
        globalMaxTokens: globalMaxTokens == _sentinel
            ? this.globalMaxTokens
            : globalMaxTokens as int?,
        globalStreamEnabled: globalStreamEnabled ?? this.globalStreamEnabled,
      );

  /// Sentinel 用于区分"未提供"和"显式 null"
  static const _sentinel = Object();
}

/// Settings 模块状态管理 Notifier
class SettingsNotifier extends StateNotifier<SettingsState> {
  SettingsNotifier({
    required ApiPresetRepository presetRepo,
    required TemplateRepository templateRepo,
    required SettingsRepository settingsRepo,
  })  : _presetRepo = presetRepo,
        _templateRepo = templateRepo,
        _settingsRepo = settingsRepo,
        super(const SettingsState()) {
    _init();
  }

  final ApiPresetRepository _presetRepo;
  final TemplateRepository _templateRepo;
  final SettingsRepository _settingsRepo;
  final _log = const Logger('SettingsNotifier');

  /// updatePreset 的 providerOptions「不修改」哨兵
  static const Object _providerOptionsUnset = Object();

  /// 初始化：加载预设和模板
  Future<void> _init({bool silent = false}) async {
    // silent 刷新不闪全屏 spinner——本地 DB 读取很快，
    // 已有数据时（如从详情页返回/列表页背后被联动刷新）保留旧数据直接
    // 静默换新；仅首载（无缓存数据）才走 loading 态。
    final alreadyLoaded =
        state.presets.isNotEmpty || state.templates.isNotEmpty;
    if (!silent || !alreadyLoaded) {
      state = state.copyWith(isLoading: true);
    }
    try {
      // 供应商列表初始为空，用户通过"+新建"基于模板创建
      // （ensureBuiltInPresets 不再调用，避免首次安装出现大量未配 Key 的内置项）
      await _templateRepo.ensureBuiltInTemplates();

      // 后台预热 models.dev registry（不阻塞初始化）：
      // 首次安装 / 重装 app 时缓存文件为空，主动拉一次确保后续富化有效。
      // refresh() 内部静默吞掉网络异常，失败也不影响主流程。
      unawaited(ModelRegistry.instance.refresh());

      // 并发加载：预设、模板、用户覆盖
      final presetsFuture = _presetRepo.getAllPresets();
      final templatesFuture = _templateRepo.getAllTemplates();
      final overridesFuture = _settingsRepo.getUserOverrides();

      final presets = await presetsFuture;
      //  #28：toolUpdateWorld 已在仓库映射层过滤，无需再滤
      final templates = await templatesFuture;
      final overrides = await overridesFuture;

      // 加载 API Key 状态
      final apiKeyStatus = <String, bool>{};
      for (final preset in presets) {
        final key = await _settingsRepo.getApiKey(preset.presetId);
        apiKeyStatus[preset.presetId] = key != null && key.isNotEmpty;
      }

      // override 读取容忍化——此前十余处裸 `as` cast，
      // 单个类型坏键（手改 SP/异版本备份导入，如 "temperature": "0.7"）
      // 令整个设置初始化进 error 态（只收口了 getResolvedConfig 合并
      // 路径，控制器直读路径未覆盖；运行时走 resolver 反而活着——表现层
      // 比运行时更脆）。坏键按未配置处理并告警，不炸页。
      T? readOverride<T>(String key) {
        final value = overrides[key];
        if (value == null) return null;
        if (value is T) return value;
        _log.warn(
          'Drop type-incompatible override, keep default',
          detail: '$key: expected $T, got ${value.runtimeType}',
        );
        return null;
      }

      // 从用户覆盖中读取字体大小（int 12-22，默认 15，对标 ChatBox 连续 Slider）
      // 旧 key `general.font_size_index` (0/1/2 离散) 已废弃，dev 阶段覆盖式重建
      final fontSize = readOverride<num>('general.font_size')?.toInt() ?? 15;
      final contentWidthMode =
          switch (readOverride<String>('general.content_width_mode')) {
        'capped' => LmContentWidthMode.capped,
        _ => LmContentWidthMode.fluid,
      };
      final autoCompaction =
          readOverride<bool>('broadcast_chat.auto_compaction') ?? true;
      final compactionThreshold =
          readOverride<num>('broadcast_chat.compaction_threshold')
                  ?.toDouble() ??
              0.6;
      final defaultModelId = readOverride<String>('broadcast_chat.model_id');
      final sendKeyStr = readOverride<String>('general.send_key') ?? 'enter';
      final sendKey = switch (sendKeyStr) {
        'shift_enter' => SendKey.shiftEnter,
        'ctrl_enter' => SendKey.ctrlEnter,
        'button' => SendKey.button,
        _ => SendKey.enter,
      };
      final newlineKeyStr =
          readOverride<String>('general.newline_key') ?? 'shift_enter';
      final newlineKey = switch (newlineKeyStr) {
        'enter' => NewlineKey.enter,
        'ctrl_enter' => NewlineKey.ctrlEnter,
        'alt_enter' => NewlineKey.altEnter,
        _ => NewlineKey.shiftEnter,
      };

      // 解析默认供应商 ID（broadcast_chat.preset_id）：
      // - 已设置但预设已被删除 → 清理 stale key，fallback 到第一个
      // - 从未设置 → 不写入，运行时 fallback 到第一个
      final persistedPresetId =
          readOverride<String>('broadcast_chat.preset_id');
      final defaultPresetId = await _resolveDefaultPresetId(
        persistedId: persistedPresetId,
        presets: presets,
      );

      final displayPreferences = DisplayPreferences.fromOverrides(overrides);

      // 读取用户配置的超时时间（默认：连接 15s，响应 30s）
      final connectTimeoutSec =
          readOverride<int>('network.connect_timeout_ms') ?? 15000;
      final receiveTimeoutSec =
          readOverride<int>('network.receive_timeout_ms') ?? 30000;

      // 读取默认思考预算档位（null = 未配置，由模型自行决定）
      final defaultReasoningEffort = ReasoningEffort.fromString(
        readOverride<String>('broadcast_chat.reasoning_effort'),
      );

      // 读取会话标题模型配置（2026-07-21 新增，独立于业务模式）
      // 存储于 common.title_model.preset_id / common.title_model.model_id
      // null = 未配置，回落生成模型起标题，仍失败才前缀兜底（三级优先级）
      final titleModelPresetId =
          readOverride<String>('common.title_model.preset_id');
      final titleModelModelId =
          readOverride<String>('common.title_model.model_id');

      // 读取全局生成参数默认值（2026-07-22 新增，对标 ChatBox Default Settings for New Conversation）
      // 存储于 broadcast_chat.temperature / top_p / max_tokens / stream_enabled
      // 未配置时使用 default_config.json 中的默认值（temperature=0.7, top_p=1.0,
      // max_tokens=4096, stream_enabled=true）。
      // 这些值是会话级字段 snapshot 时的"快照源"——修改全局参数不影响已物化的会话。
      final globalTemperature =
          readOverride<num>('broadcast_chat.temperature')?.toDouble() ?? 0.7;
      final globalTopP =
          readOverride<num>('broadcast_chat.top_p')?.toDouble() ?? 1.0;
      final globalMaxTokens = readOverride<int>('broadcast_chat.max_tokens');
      final globalStreamEnabled =
          readOverride<bool>('broadcast_chat.stream_enabled') ?? true;

      state = state.copyWith(
        presets: presets,
        templates: templates,
        apiKeyStatus: apiKeyStatus,
        defaultPresetId: defaultPresetId,
        isLoading: false,
        fontSize: fontSize,
        contentWidthMode: contentWidthMode,
        autoCompaction: autoCompaction,
        compactionThreshold: compactionThreshold,
        defaultModelId: defaultModelId,
        sendKey: sendKey,
        newlineKey: newlineKey,
        displayPreferences: displayPreferences,
        connectTimeoutSec: (connectTimeoutSec / 1000).round(),
        receiveTimeoutSec: (receiveTimeoutSec / 1000).round(),
        directorResponseStartTimeoutSec:
            ((readOverride<int>('network.director_response_start_timeout_ms') ??
                        600000) /
                    1000)
                .round(),
        directorNonStreamingTimeoutSec:
            ((readOverride<int>('network.director_non_streaming_timeout_ms') ??
                        600000) /
                    1000)
                .round(),
        autoRetryMaxAttempts: readOverride<int>(
              'network.auto_retry_max_attempts',
            ) ??
            5,
        autoRetryWaitBudgetSec:
            ((readOverride<int>('network.auto_retry_wait_budget_ms') ?? 90000) /
                    1000)
                .round(),
        defaultReasoningEffort: defaultReasoningEffort,
        titleModelPresetId: titleModelPresetId,
        titleModelModelId: titleModelModelId,
        globalTemperature: globalTemperature,
        globalTopP: globalTopP,
        globalMaxTokens: globalMaxTokens,
        globalStreamEnabled: globalStreamEnabled,
      );
    } catch (e) {
      _log.error('Failed to init settings', detail: '$e');
      state = state.copyWith(
        isLoading: false,
        error: e.toString(),
      );
    }
  }

  /// 刷新所有数据
  ///
  /// [silent] = true：已有数据时不进入 loading 态，
  /// 静默换新——避免每次进入供应商页全屏 spinner、以及共享 provider
  /// 让背后列表页同步闪烁。首载（无数据）时仍正常显示 loading。
  Future<void> refresh({bool silent = false}) async {
    await _init(silent: silent);
  }

  // -- API 预设操作 --

  /// 创建预设
  ///
  /// [baseUrl] 可选——创建时可仅填名称，后续在详情页补全 URL。
  /// [protocol] 可选——创建时锁定协议类型，默认 [LlmProtocol.openaiCompatible]。
  Future<ApiPreset?> createPreset({
    required String name,
    String baseUrl = '',
    String? apiKey,
    LlmProtocol protocol = LlmProtocol.openaiCompatible,
  }) async {
    try {
      final preset = await _presetRepo.createPreset(
        name: name,
        baseUrl: baseUrl,
        protocol: protocol,
      );
      if (apiKey != null && apiKey.isNotEmpty) {
        await _settingsRepo.saveApiKey(preset.presetId, apiKey);
      }
      await _refreshPresets();
      return preset;
    } catch (e) {
      _log.error('Failed to create preset', detail: '$e');
      state = state.copyWith(error: e.toString());
      return null;
    }
  }

  /// 基于模板创建自定义 preset（DOC-12 §4.3）
  ///
  /// 从 [ProviderTemplates] 注册表查找 [templateId]，继承 protocol 和
  /// defaultBaseUrl。用户只需填入 API Key 即可使用。
  Future<ApiPreset?> createFromTemplate({
    required String templateId,
    required String name,
  }) async {
    try {
      final preset = await _presetRepo.createFromTemplate(
        templateId: templateId,
        name: name,
      );
      await _refreshPresets();
      return preset;
    } catch (e) {
      _log.error('Failed to create preset from template', detail: '$e');
      state = state.copyWith(error: e.toString());
      return null;
    }
  }

  /// 重置内置 preset 为模板默认值（DOC-12 §4.3）
  ///
  /// 仅对内置 preset 有效。从 [ProviderTemplates] 注册表查找对应模板，
  /// 重置 name/baseUrl/protocol 为模板默认值，清空 cachedModels，
  /// 保留 API Key。自定义 preset 调用此方法会在 repo 层抛错。
  Future<bool> resetPreset(String presetId) async {
    try {
      await _presetRepo.resetPreset(presetId);
      await _refreshPresets();
      return true;
    } catch (e) {
      _log.error('Failed to reset preset', detail: '$e');
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  /// 更新预设
  ///
  /// [providerOptions] 用 [_providerOptionsUnset] 哨兵区分「不修改」与
  /// 「清除」：传 Map 设置，传 null 清除（空就是空），不传保持原值。
  /// ApiPreset.copyWith 的 null 合并语义无法置空，清除走显式重建。
  Future<ApiPreset?> updatePreset(
    String presetId, {
    String? name,
    String? baseUrl,
    Object? providerOptions = _providerOptionsUnset,
  }) async {
    try {
      final updated = await _presetRepo.updatePreset(presetId, (current) {
        final updated = current.copyWith(name: name, baseUrl: baseUrl);
        if (identical(providerOptions, _providerOptionsUnset)) {
          return updated;
        }
        return _withProviderOptions(
          updated,
          providerOptions as Map<String, dynamic>?,
        );
      });
      await _refreshPresets();
      return updated;
    } catch (e) {
      _log.error('Failed to update preset', detail: '$e');
      state = state.copyWith(error: e.toString());
      return null;
    }
  }

  /// 供应商级「不发送采样参数」开关。
  ///
  /// 在仓储层做原子读改写，避免页面持有的旧 Map 覆盖其他 providerOptions
  /// 键；键删空后回落 null（与存储层「空就是空」口径一致）。
  Future<ApiPreset?> setOmitSamplingParams(
    String presetId, {
    required bool omit,
  }) async {
    try {
      final updated = await _presetRepo.updatePreset(presetId, (current) {
        final options = Map<String, dynamic>.of(
          current.providerOptions ?? const <String, dynamic>{},
        );
        if (omit) {
          options[kOmitSamplingParamsOption] = true;
        } else {
          options.remove(kOmitSamplingParamsOption);
        }
        return _withProviderOptions(current, options.isEmpty ? null : options);
      });
      await _refreshPresets();
      return updated;
    } catch (e) {
      _log.error('Failed to update sampling params option', detail: '$e');
      state = state.copyWith(error: e.toString());
      return null;
    }
  }

  /// copyWith 的 null 合并语义无法清空 providerOptions，清除走显式重建。
  ApiPreset _withProviderOptions(
    ApiPreset current,
    Map<String, dynamic>? options,
  ) {
    return ApiPreset(
      presetId: current.presetId,
      name: current.name,
      baseUrl: current.baseUrl,
      isBuiltIn: current.isBuiltIn,
      cachedModels: current.cachedModels,
      protocol: current.protocol,
      templateId: current.templateId,
      providerOptions: options,
      createdAt: current.createdAt,
      updatedAt: current.updatedAt,
    );
  }

  /// 删除预设
  ///
  /// 2026-07-17 修复：级联清理所有引用该供应商的 user_overrides，
  /// 避免"删除供应商后故事模式设置页因悬空引用飘红"的 bug。
  /// 清理范围：默认模型 + 嵌入模型 + 分步骤模型配置（4 阶段 × 2 key）。
  /// 会话级 chat_sessions.preset_id 由运行时 resolvePhaseNamingConfig 兜底。
  Future<bool> deletePreset(String presetId) async {
    try {
      await _presetRepo.deletePreset(presetId);
      await _settingsRepo.deleteApiKey(presetId);
      await _cascadeClearPresetReferences(presetId);
      await _refreshPresets();
      return true;
    } catch (e) {
      _log.error('Failed to delete preset', detail: '$e');
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  /// 级联清理 user_overrides 中所有引用指定 presetId 的 key。
  ///
  /// 删除供应商后，相关配置变成悬空引用，会让 DropdownButtonFormField
  /// 因 initialValue 不在 items 中而断言失败。这里在删除时一次性清理：
  /// - common.title_model.preset_id / model_id（会话标题生成模型）
  /// - broadcast_chat.preset_id / model_id（Simple 模式默认模型）
  /// - intermediate.embedding_preset_id / model_id（嵌入模型）
  /// - intermediate.phase_models.{generating,extracting,reviewing,summarizing}_preset_id / model_id
  /// - intermediate.suggest_reply.preset_id / model_id（推荐回复模型）
  /// - advanced.phase_models.generating_preset_id / model_id（导演 GM）
  /// - advanced.embedding_preset_id / model_id（导演向量化模型）
  /// - advanced.suggest_reply.preset_id / model_id（导演推荐回复模型）
  ///
  /// 注：先读出当前值再判断是否等于 presetId，避免误清用户配置的其他供应商。
  /// model_id 依赖 preset_id，preset_id 被清时 model_id 一起清。
  ///
  /// 2026-08-29 审查 ：补齐分家后的 advanced 模型键与两侧推荐回复键
  /// （此前删除供应商后导演 GM 引用悬空，开轮直接 E010/请求失败）。
  Future<void> _cascadeClearPresetReferences(String presetId) async {
    final overrides = await _settingsRepo.getUserOverrides();
    final keysToRemove = <String>[];

    void checkAndMark(String presetKey, String modelKey) {
      final v = overrides[presetKey];
      if (v is String && v == presetId) {
        keysToRemove
          ..add(presetKey)
          ..add(modelKey);
      }
    }

    // 会话标题生成模型（跨模式共享）
    checkAndMark('common.title_model.preset_id', 'common.title_model.model_id');
    // Simple 模式默认模型
    checkAndMark('broadcast_chat.preset_id', 'broadcast_chat.model_id');
    // 故事模式嵌入模型
    checkAndMark(
      'intermediate.embedding_preset_id',
      'intermediate.embedding_model_id',
    );
    // 故事模式分步骤模型配置（4 阶段）
    for (final phase in const [
      'generating',
      'extracting',
      'reviewing',
      'summarizing',
    ]) {
      checkAndMark(
        'intermediate.phase_models.${phase}_preset_id',
        'intermediate.phase_models.${phase}_model_id',
      );
    }
    // 故事模式推荐回复模型
    checkAndMark(
      'intermediate.suggest_reply.preset_id',
      'intermediate.suggest_reply.model_id',
    );
    // 导演模式：GM（phase_models 仅 generating）+ 向量化 + 推荐回复
    checkAndMark(
      'advanced.phase_models.generating_preset_id',
      'advanced.phase_models.generating_model_id',
    );
    checkAndMark(
      'advanced.embedding_preset_id',
      'advanced.embedding_model_id',
    );
    checkAndMark(
      'advanced.suggest_reply.preset_id',
      'advanced.suggest_reply.model_id',
    );

    for (final key in keysToRemove) {
      await _settingsRepo.removeUserOverride(key);
    }
    if (keysToRemove.isNotEmpty) {
      _log.info(
        'Cascaded clear stale references to preset $presetId',
        detail: 'keys: ${keysToRemove.join(", ")}',
      );
    }
  }

  /// 保存 API Key。返回是否成功——存储层异常此前未捕获会直接上抛，
  /// 调用方（设置页）无反馈且状态不更新。
  Future<bool> saveApiKey(String presetId, String apiKey) async {
    // G3 修复：空串 = 清除 Key，不再把空串存成"已设置"
    if (apiKey.isEmpty) {
      return clearApiKey(presetId);
    }
    try {
      await _settingsRepo.saveApiKey(presetId, apiKey);
    } catch (e) {
      _log.error('Failed to save API key', detail: '$e');
      state = state.copyWith(error: e.toString());
      return false;
    }
    final newStatus = Map<String, bool>.from(state.apiKeyStatus);
    newStatus[presetId] = true;
    state = state.copyWith(apiKeyStatus: newStatus);
    return true;
  }

  /// 清除 API Key（G3 修复新增）。异常语义同 [saveApiKey]。
  Future<bool> clearApiKey(String presetId) async {
    try {
      await _settingsRepo.deleteApiKey(presetId);
    } catch (e) {
      _log.error('Failed to clear API key', detail: '$e');
      state = state.copyWith(error: e.toString());
      return false;
    }
    final newStatus = Map<String, bool>.from(state.apiKeyStatus);
    newStatus[presetId] = false;
    state = state.copyWith(apiKeyStatus: newStatus);
    return true;
  }

  /// 测试连接
  ///
  /// 通过"获取模型列表"（GET {baseUrl}/models，不消耗 token）验证连接。
  /// 成功即代表 API Key 有效、网络可达、供应商配置正确。
  ///
  /// 修复历程：
  /// - v1：依赖 fetchModels（正确，但不消耗 token）
  /// - v2：改为发真实对话请求——部分供应商（如火山 Coding Plan）无 models
  ///   列表 API 时误判失败；且会消耗 token 额度
  /// - v3（当前）：回归 fetchModels。火山 Coding Plan 实测 `/api/coding/v3/models`
  ///   端点存在（401=需要认证，非 404），与 ChatBox 的获取方式完全一致。
  ///   ChatBox 调研（llm_utils.ts + openai-compatible.ts）：最终请求
  ///   `{apiHost}/models` + Bearer 认证，GET 请求，不消耗 token。
  Future<void> testConnection(String presetId) async {
    state = state.copyWith(isTestingConnection: true);
    try {
      // 获取模型列表成功即连接成功（顺带刷新缓存模型列表）
      await _presetRepo.fetchModels(presetId);
      state = state.copyWith(
        isTestingConnection: false,
        testResult: 'success',
      );
    } catch (e) {
      // 按状态码分类，供 UI 映射人话提示——
      // 此前 'fail:$e' 直出英文原始异常，新手分不清 Key 错/网络断/
      // baseUrl 层级错（配置是第一价值时刻的闸门）。
      state = state.copyWith(
        isTestingConnection: false,
        testResult: 'fail:${classifyTestError(e)}|$e',
      );
    }
  }

  /// 连接测试错误分类：auth / network / endpoint / server / unknown
  static String classifyTestError(Object e) {
    if (e is AppHttpException) {
      final status = e.statusCode ?? 0;
      if (status == 401 || status == 403) return 'auth';
      if (status == 404) return 'endpoint';
      if (status >= 500) return 'server';
      return 'unknown';
    }
    // 平台安全的网络异常识别（不 import dart:io）
    final text = e.toString();
    if (e is TimeoutException ||
        text.contains('SocketException') ||
        text.contains('Connection refused') ||
        text.contains('Failed host lookup') ||
        text.contains('Connection timed out')) {
      return 'network';
    }
    return 'unknown';
  }

  /// 清除测试结果
  void clearTestResult() {
    // copyWith 哨兵化后 null 才真正可达（此前是恒空操作）
    state = state.copyWith(testResult: null);
  }

  /// 设置默认模型（同时记录 defaultPresetId + defaultModelId）。
  ///
  /// 这是"默认模型"选择页的唯一入口：用户从所有供应商的所有模型里选一个，
  /// 同时记录其所属供应商和模型 ID，作为新对话建立时的默认填充值。
  /// 传 null 表示清除默认模型。
  ///
  /// 持久化：presetId 与 modelId 均存入 SettingsRepository.user_overrides，
  /// key 为 `broadcast_chat.preset_id` 与 `broadcast_chat.model_id`，
  /// 与其他 broadcast_chat.* 配置项保持一致的存储机制。
  Future<void> setDefaultModel({
    required String? presetId,
    required String? modelId,
  }) async {
    if (presetId != null && modelId != null) {
      await _settingsRepo.setUserOverride('broadcast_chat.preset_id', presetId);
      await _settingsRepo.setUserOverride('broadcast_chat.model_id', modelId);
    } else {
      // 清除：移除持久化的默认供应商和默认模型
      await _settingsRepo.removeUserOverride('broadcast_chat.preset_id');
      await _settingsRepo.removeUserOverride('broadcast_chat.model_id');
    }
    state = state.copyWith(
      defaultPresetId: presetId,
      defaultModelId: modelId,
    );
  }

  /// 设置会话标题模型（2026-07-21 新增）。
  ///
  /// 独立于业务模式，所有模式的会话标题自动生成都使用此配置。
  /// 传 null 表示清除配置，回落生成模型起标题，仍失败才前缀兜底（三级优先级）。
  ///
  /// 持久化：presetId 与 modelId 均存入 SettingsRepository.user_overrides，
  /// key 为 `common.title_model.preset_id` 与 `common.title_model.model_id`。
  Future<void> setTitleModel({
    required String? presetId,
    required String? modelId,
  }) async {
    if (presetId != null && modelId != null) {
      await _settingsRepo.setUserOverride(
        'common.title_model.preset_id',
        presetId,
      );
      await _settingsRepo.setUserOverride(
        'common.title_model.model_id',
        modelId,
      );
    } else {
      await _settingsRepo.removeUserOverride('common.title_model.preset_id');
      await _settingsRepo.removeUserOverride('common.title_model.model_id');
    }
    state = state.copyWith(
      titleModelPresetId: presetId,
      titleModelModelId: modelId,
    );
  }

  /// 设置字体大小（int 12-22，默认 15）
  ///
  /// 持久化到 `general.font_size`。fontScale = fontSize / 15.0
  /// 由 ChatModePage 计算并应用到消息气泡。
  Future<void> setFontSize(int size) async {
    // 钳制到合法范围
    final clamped = size.clamp(12, 22);
    await _settingsRepo.setUserOverride('general.font_size', clamped);
    state = state.copyWith(fontSize: clamped);
  }

  /// 设置内容宽度模式（流式/固定上限）
  ///
  /// 持久化到 `general.content_width_mode`；版心消费面经顶层
  /// LmContentWidthScope 即时生效。
  Future<void> setContentWidthMode(LmContentWidthMode mode) async {
    await _settingsRepo.setUserOverride(
      'general.content_width_mode',
      mode.name,
    );
    state = state.copyWith(contentWidthMode: mode);
  }

  /// 设置是否启用自动压缩
  // ignore: avoid_positional_boolean_parameters — 与其他 setter 签名保持一致
  Future<void> setAutoCompaction(bool enabled) async {
    await _settingsRepo.setUserOverride(
      'broadcast_chat.auto_compaction',
      enabled,
    );
    state = state.copyWith(autoCompaction: enabled);
  }

  /// 设置压缩阈值百分比（0.4-0.9），对标 ChatBox compactionThreshold
  Future<void> setCompactionThreshold(double value) async {
    // 钳制到合法范围
    final clamped = value.clamp(0.4, 0.9);
    await _settingsRepo.setUserOverride(
      'broadcast_chat.compaction_threshold',
      clamped,
    );
    state = state.copyWith(compactionThreshold: clamped);
  }

  /// 设置发送键
  ///
  /// 如果新的发送键与当前换行键冲突，自动将换行键切换到不冲突的值。
  Future<void> setSendKey(SendKey key) async {
    final value = switch (key) {
      SendKey.enter => 'enter',
      SendKey.shiftEnter => 'shift_enter',
      SendKey.ctrlEnter => 'ctrl_enter',
      SendKey.button => 'button',
    };
    await _settingsRepo.setUserOverride('general.send_key', value);

    // 冲突处理：发送键和换行键不能相同
    final conflictNewline = _resolveNewlineConflict(key, state.newlineKey);
    if (conflictNewline != null) {
      final newlineValue = switch (conflictNewline) {
        NewlineKey.enter => 'enter',
        NewlineKey.shiftEnter => 'shift_enter',
        NewlineKey.ctrlEnter => 'ctrl_enter',
        NewlineKey.altEnter => 'alt_enter',
      };
      await _settingsRepo.setUserOverride(
        'general.newline_key',
        newlineValue,
      );
      state = state.copyWith(sendKey: key, newlineKey: conflictNewline);
    } else {
      state = state.copyWith(sendKey: key);
    }
  }

  /// 检测发送键和换行键是否冲突，冲突则返回一个不冲突的换行键。
  static NewlineKey? _resolveNewlineConflict(SendKey send, NewlineKey newline) {
    final conflicts = switch (send) {
      SendKey.enter when newline == NewlineKey.enter => NewlineKey.shiftEnter,
      SendKey.shiftEnter when newline == NewlineKey.shiftEnter =>
        NewlineKey.enter,
      SendKey.ctrlEnter when newline == NewlineKey.ctrlEnter =>
        NewlineKey.enter,
      _ => null,
    };
    return conflicts;
  }

  /// 设置换行键（桌面端）
  Future<void> setNewlineKey(NewlineKey key) async {
    final value = switch (key) {
      NewlineKey.enter => 'enter',
      NewlineKey.shiftEnter => 'shift_enter',
      NewlineKey.ctrlEnter => 'ctrl_enter',
      NewlineKey.altEnter => 'alt_enter',
    };
    await _settingsRepo.setUserOverride('general.newline_key', value);
    state = state.copyWith(newlineKey: key);
  }

  /// 设置连接超时（秒）
  Future<void> setConnectTimeoutSec(int seconds) async {
    await _settingsRepo.setUserOverride(
      'network.connect_timeout_ms',
      seconds * 1000,
    );
    state = state.copyWith(connectTimeoutSec: seconds);
  }

  /// 自动重试次数上限（0-5；2026-10-15 批 E / P5）
  Future<void> setAutoRetryMaxAttempts(int attempts) async {
    await _settingsRepo.setUserOverride(
      'network.auto_retry_max_attempts',
      attempts,
    );
    state = state.copyWith(autoRetryMaxAttempts: attempts);
  }

  /// 自动重试累计等待预算（秒；0 = 不限，P6）
  Future<void> setAutoRetryWaitBudgetSec(int seconds) async {
    await _settingsRepo.setUserOverride(
      'network.auto_retry_wait_budget_ms',
      seconds * 1000,
    );
    state = state.copyWith(autoRetryWaitBudgetSec: seconds);
  }

  /// 设置响应超时（秒）
  Future<void> setReceiveTimeoutSec(int seconds) async {
    await _settingsRepo.setUserOverride(
      'network.receive_timeout_ms',
      seconds * 1000,
    );
    state = state.copyWith(receiveTimeoutSec: seconds);
  }

  Future<void> setDirectorResponseStartTimeoutSec(int seconds) async {
    await _settingsRepo.setUserOverride(
      'network.director_response_start_timeout_ms',
      seconds * 1000,
    );
    state = state.copyWith(directorResponseStartTimeoutSec: seconds);
  }

  Future<void> setDirectorNonStreamingTimeoutSec(int seconds) async {
    await _settingsRepo.setUserOverride(
      'network.director_non_streaming_timeout_ms',
      seconds * 1000,
    );
    state = state.copyWith(directorNonStreamingTimeoutSec: seconds);
  }

  /// 设置默认思考预算档位
  ///
  /// 传 null 表示清除配置（恢复"未配置"状态，由模型自行决定是否思考）。
  /// 存储于 user overrides 的 `broadcast_chat.reasoning_effort` key，
  /// 由 ConfigurationResolver 在解析会话设置时读取。
  Future<void> setDefaultReasoningEffort(ReasoningEffort? effort) async {
    if (effort == null) {
      await _settingsRepo.removeUserOverride(
        'broadcast_chat.reasoning_effort',
      );
    } else {
      await _settingsRepo.setUserOverride(
        'broadcast_chat.reasoning_effort',
        effort.toJson(),
      );
    }
    state = state.copyWith(defaultReasoningEffort: effort);
  }

  // -- 全局生成参数默认值（2026-07-22 新增，对标 ChatBox Default Settings for New Conversation） --
  //
  // 这些值是新会话物化时的"快照源"——会话级字段在物化时读取当前全局值并写入
  // chat_sessions 对应字段。修改全局参数不会影响已物化的会话（快照语义）。
  // 存储于 user overrides 的 `broadcast_chat.temperature` / `top_p` /
  // `max_tokens` / `stream_enabled` key。

  /// 设置全局温度默认值（0.0-2.0）
  Future<void> setGlobalTemperature(double value) async {
    final clamped = value.clamp(0.0, 2.0);
    await _settingsRepo.setUserOverride('broadcast_chat.temperature', clamped);
    state = state.copyWith(globalTemperature: clamped);
  }

  /// 设置全局 Top P 默认值（0.0-1.0）
  Future<void> setGlobalTopP(double value) async {
    final clamped = value.clamp(0.0, 1.0);
    await _settingsRepo.setUserOverride('broadcast_chat.top_p', clamped);
    state = state.copyWith(globalTopP: clamped);
  }

  /// 设置全局最大 Token 数默认值
  ///
  /// 传 null 表示清除配置（恢复"未配置"状态，由模型自行决定上限）。
  Future<void> setGlobalMaxTokens(int? value) async {
    if (value == null) {
      await _settingsRepo.removeUserOverride('broadcast_chat.max_tokens');
    } else {
      await _settingsRepo.setUserOverride('broadcast_chat.max_tokens', value);
    }
    state = state.copyWith(globalMaxTokens: value);
  }

  /// 设置全局流式输出默认值
  // ignore: avoid_positional_boolean_parameters — 与其他 setter 签名保持一致
  Future<void> setGlobalStreamEnabled(bool value) async {
    await _settingsRepo.setUserOverride(
      'broadcast_chat.stream_enabled',
      value,
    );
    state = state.copyWith(globalStreamEnabled: value);
  }

  /// 设置是否显示时间戳
  // ignore: avoid_positional_boolean_parameters
  Future<void> setShowTimestamp(bool value) async {
    await _settingsRepo.setUserOverride('display.show_timestamp', value);
    state = state.copyWith(
      displayPreferences: state.displayPreferences.copyWith(
        showTimestamp: value,
      ),
    );
  }

  /// 设置是否显示模型名称
  // ignore: avoid_positional_boolean_parameters
  Future<void> setShowModelName(bool value) async {
    await _settingsRepo.setUserOverride('display.show_model_name', value);
    state = state.copyWith(
      displayPreferences: state.displayPreferences.copyWith(
        showModelName: value,
      ),
    );
  }

  /// 设置是否显示头像
  // ignore: avoid_positional_boolean_parameters
  Future<void> setShowAvatar(bool value) async {
    await _settingsRepo.setUserOverride('display.show_avatar', value);
    state = state.copyWith(
      displayPreferences: state.displayPreferences.copyWith(
        showAvatar: value,
      ),
    );
  }

  /// 设置是否显示 Tokens 使用量（对标 ChatBox showTokenUsed）
  // ignore: avoid_positional_boolean_parameters
  Future<void> setShowTokenUsed(bool value) async {
    await _settingsRepo.setUserOverride('display.show_token_used', value);
    state = state.copyWith(
      displayPreferences: state.displayPreferences.copyWith(
        showTokenUsed: value,
      ),
    );
  }

  /// 设置是否显示字数统计（对标 ChatBox showWordCount）
  // ignore: avoid_positional_boolean_parameters
  Future<void> setShowWordCount(bool value) async {
    await _settingsRepo.setUserOverride('display.show_word_count', value);
    state = state.copyWith(
      displayPreferences: state.displayPreferences.copyWith(
        showWordCount: value,
      ),
    );
  }

  /// 设置是否显示首字延迟（对标 ChatBox showFirstTokenLatency）
  // ignore: avoid_positional_boolean_parameters
  Future<void> setShowFirstTokenLatency(bool value) async {
    await _settingsRepo.setUserOverride(
      'display.show_first_token_latency',
      value,
    );
    state = state.copyWith(
      displayPreferences: state.displayPreferences.copyWith(
        showFirstTokenLatency: value,
      ),
    );
  }

  /// 设置消息布局模式
  Future<void> setMessageLayoutMode(MessageLayoutMode mode) async {
    final value = mode == MessageLayoutMode.standard ? 'standard' : 'bubble';
    await _settingsRepo.setUserOverride('display.message_layout_mode', value);
    state = state.copyWith(
      displayPreferences: state.displayPreferences.copyWith(
        messageLayoutMode: mode,
      ),
    );
  }

  /// 获取模型列表
  Future<List<ModelInfo>> fetchModels(String presetId) async {
    state = state.copyWith(isFetchingModels: true);
    try {
      final models = await _presetRepo.fetchModels(presetId);
      // 成功时清掉旧错误——此前 error 粘在
      // state 上且 copyWith 结构性无法置回 null，修好 Key 后的成功获取
      // 仍被旧错误短路，模型弹窗永不出现
      state = state.copyWith(isFetchingModels: false, fetchModelsError: null);
      return models;
    } catch (e) {
      _log.error('Failed to fetch models', detail: '$e');
      state = state.copyWith(
        isFetchingModels: false,
        fetchModelsError: e.toString(),
      );
      return [];
    }
  }

  /// 直接更新某个供应商的模型列表（用于在详情页添加/删除模型）
  Future<void> updatePresetModels(
    String presetId,
    List<ModelInfo> models,
  ) async {
    try {
      await _presetRepo.updateModelList(presetId, models);
      await _refreshPresets();
    } catch (e) {
      _log.error('Failed to update preset models', detail: '$e');
      state = state.copyWith(error: e.toString());
    }
  }

  // -- 模板操作 --

  /// 创建模板
  Future<Template?> createTemplate({
    required String name,
    required TemplateKind kind,
    required String content,
  }) async {
    try {
      final template = await _templateRepo.createTemplate(
        name: name,
        kind: kind,
        content: content,
      );
      await _refreshTemplates();
      return template;
    } catch (e) {
      _log.error('Failed to create template', detail: '$e');
      state = state.copyWith(error: e.toString());
      return null;
    }
  }

  /// 更新模板
  Future<Template?> updateTemplate(
    String templateId, {
    String? name,
    TemplateKind? kind,
    String? content,
  }) async {
    try {
      final updated = await _templateRepo.updateTemplate(
        templateId,
        (current) => current.copyWith(
          name: name,
          kind: kind,
          content: content,
        ),
      );
      await _refreshTemplates();
      return updated;
    } catch (e) {
      _log.error('Failed to update template', detail: '$e');
      state = state.copyWith(error: e.toString());
      return null;
    }
  }

  /// 删除模板
  Future<bool> deleteTemplate(String templateId) async {
    try {
      await _templateRepo.deleteTemplate(templateId);
      await _refreshTemplates();
      return true;
    } catch (e) {
      _log.error('Failed to delete template', detail: '$e');
      state = state.copyWith(error: e.toString());
      return false;
    }
  }

  /// 复制模板
  Future<Template?> copyTemplate(String templateId, {String? newName}) async {
    try {
      final copied = await _templateRepo.copyTemplate(
        templateId,
        newName: newName,
      );
      await _refreshTemplates();
      return copied;
    } catch (e) {
      _log.error('Failed to copy template', detail: '$e');
      state = state.copyWith(error: e.toString());
      return null;
    }
  }

  // -- 私有方法 --

  /// 清除 state.error
  ///
  /// UI 层（通过 ref.listen 监听 error）弹完错误提示后调用，
  /// 避免下次状态变化时再次触发同一错误提示。
  void clearError() {
    if (state.error == null) return;
    // 2026-07-22 修复：改用 copyWith + sentinel 模式清除 error，
    // 避免手动重建 state 时漏掉新增字段（曾导致 global* 配置丢失）。
    state = state.copyWith(error: null);
  }

  Future<void> _refreshPresets() async {
    final presets = await _presetRepo.getAllPresets();
    final apiKeyStatus = <String, bool>{};
    for (final preset in presets) {
      final key = await _settingsRepo.getApiKey(preset.presetId);
      apiKeyStatus[preset.presetId] = key != null && key.isNotEmpty;
    }
    state = state.copyWith(presets: presets, apiKeyStatus: apiKeyStatus);
  }

  Future<void> _refreshTemplates() async {
    //  #28：toolUpdateWorld 全下架——枚举值已删，存量行在仓库
    // 映射层（tryFromDbValue → null → 跳过）被过滤，此处无需再滤。
    final templates = await _templateRepo.getAllTemplates();
    state = state.copyWith(templates: templates);
  }

  /// 解析默认供应商 ID。
  ///
  /// - [persistedId] 非空且对应预设存在 → 直接返回
  /// - [persistedId] 非空但预设已被删除 → 清理 stale key，fallback 到第一个
  /// - [persistedId] 为空 → 不写入，运行时 fallback 到第一个
  Future<String?> _resolveDefaultPresetId({
    required String? persistedId,
    required List<ApiPreset> presets,
  }) async {
    if (presets.isEmpty) return null;

    if (persistedId != null && persistedId.isNotEmpty) {
      final exists = presets.any((p) => p.presetId == persistedId);
      if (exists) return persistedId;
      // 预设已被删除，清理 stale key 后 fallback。
      // 与 deletePreset 级联同口径双键同删——只清
      // preset_id 会留下 model_id 孤儿，新会话可能拿 presets.first 的
      // baseUrl 配孤儿 modelId 出网。
      await _settingsRepo.removeUserOverride('broadcast_chat.preset_id');
      await _settingsRepo.removeUserOverride('broadcast_chat.model_id');
    }
    // fallback 到第一个可用预设（不写入，保留用户"未设置"的语义）
    return presets.first.presetId;
  }
}

/// SettingsNotifier Provider
final settingsNotifierProvider =
    StateNotifierProvider<SettingsNotifier, SettingsState>((ref) {
  return SettingsNotifier(
    presetRepo: ref.read(apiPresetRepositoryProvider),
    templateRepo: ref.read(templateRepositoryProvider),
    settingsRepo: ref.read(settingsRepositoryProvider),
  );
});
