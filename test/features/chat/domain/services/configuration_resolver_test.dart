import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/session_phase_models.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';

/// ConfigurationResolver 单元测试（2026-07-21 配置架构重构后版本）
///
/// 重点验证 resolveIntermediateSettings 和 resolveIntermediatePhaseNamingConfig
/// 的两级优先级：session > intermediate.phase_models（全局）。
///
/// **重构变更**：
/// - 删除 `IntermediateConfig.modelId` / `presetId` 字段
/// - 删除 `resolveNamingConfig(ChatSession)` 和 `resolveIntermediateNamingConfig(ChatSession)` 方法
/// - 新增 `resolveTitleNamingConfig()` 从 `common.title_model` 全局配置读取
/// - `resolveIntermediateSettings` 不再返回 modelId/presetId（始终为空串）和 apiKey（始终 null）
///   仅返回生成参数（temperature 等）和非生成参数（streamEnabled 等）

// ── Fake / Stub ─────────────────────────────────────────────────────

class _FakeApiPresetRepository implements ApiPresetRepository {
  _FakeApiPresetRepository({this.presets = const []});

  final List<ApiPreset> presets;

  @override
  Future<List<ApiPreset>> getAllPresets() async => presets;

  @override
  Future<ApiPreset> getPreset(String presetId) async {
    final preset = presets.where((p) => p.presetId == presetId).firstOrNull;
    if (preset == null) {
      throw StateError('Preset not found: $presetId');
    }
    return preset;
  }

  Future<String?> getDefaultPresetId() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _FakeSettingsRepository implements SettingsRepository {
  _FakeSettingsRepository({
    required this.config,
    this.apiKeys = const {},
  });

  final AppConfig config;
  final Map<String, String> apiKeys;

  @override
  Future<AppConfig> getResolvedConfig() async => config;

  @override
  Future<String?> getApiKey(String presetId) async => apiKeys[presetId];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

// ── 测试数据 ────────────────────────────────────────────────────────

ApiPreset _preset(
  String id, {
  String baseUrl = 'https://api.test.com/v1',
  List<ModelInfo> cachedModels = const [],
}) =>
    ApiPreset(
      presetId: id,
      name: '供应商 $id',
      baseUrl: baseUrl,
      cachedModels: cachedModels,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

/// 构造测试会话。默认使用空 phaseModels（与会话默认值一致，调用方按需覆盖）。
ChatSession _session({SessionPhaseModels? phaseModels}) => ChatSession(
      sessionId: 'session-1',
      title: '测试故事',
      mode: 'intermediate',
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 0,
      phaseModels: phaseModels ?? const SessionPhaseModels.empty(),
    );

/// 构造带 Simple 模式模型配置的测试会话（供 resolveBroadcastGeneratingNamingConfig 用）。
ChatSession _sessionWithModel({String? presetId, String? modelId}) =>
    ChatSession(
      sessionId: 'session-1',
      title: '测试故事',
      mode: 'chat',
      presetId: presetId,
      modelId: modelId,
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 0,
    );

const _logger = Logger('test', minLevel: LogLevel.warn);

/// 默认 AppConfig：broadcastChat.modelId='bc-model'，intermediate 全默认
const _defaultConfig = AppConfig(
  version: '0.1',
  broadcastChat: BroadcastChatConfig(modelId: 'bc-model'),
);

/// 含 intermediate.phase_models 全局配置的 AppConfig
const _phaseModelsConfig = AppConfig(
  version: '0.1',
  broadcastChat: BroadcastChatConfig(modelId: 'bc-model'),
  intermediate: IntermediateConfig(
    phaseModels: PhaseModelsConfig(
      generatingPresetId: 'int-preset',
      generatingModelId: 'int-model',
    ),
  ),
);

/// 含 common.title_model 全局配置的 AppConfig
const _titleModelConfig = AppConfig(
  version: '0.1',
  broadcastChat: BroadcastChatConfig(modelId: 'bc-model'),
  common: CommonConfig(
    titleModel: TitleModelConfig(
      presetId: 'title-preset',
      modelId: 'title-model',
    ),
  ),
);

// ── 测试 ────────────────────────────────────────────────────────────

void main() {
  group('resolveIntermediateSettings', () {
    test('1. 生成参数走 intermediate.generation 默认值', () async {
      // 2026-07-21 重构：resolveIntermediateSettings 不再返回 modelId/presetId
      // （始终为空串），仅返回生成参数 + 非生成参数
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(presets: [_preset('p1')]),
        settingsRepository: _FakeSettingsRepository(
          config: _defaultConfig,
          apiKeys: {'p1': 'key-p1'},
        ),
        logger: _logger,
      );

      final result = await resolver.resolveIntermediateSettings(_session());

      // modelId/presetId 始终为空串（业务模型由分步骤解析器负责）
      expect(result.settings.modelId, '');
      expect(result.settings.presetId, '');
      // apiKey 始终为 null（由分步骤解析器各自解析）
      expect(result.apiKey, isNull);
      // 生成参数：来自 intermediate.generation 默认值（GenerationConfig）
      expect(result.settings.temperature, 0.8);
      expect(result.settings.maxTokens, 8192);
      expect(result.settings.topP, 0.95);
      expect(result.settings.presencePenalty, 0.0);
      expect(result.settings.frequencyPenalty, 0.0);
    });

    test('2. 会话级生成参数覆盖 intermediate.generation 默认值', () async {
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(presets: [_preset('p1')]),
        settingsRepository: _FakeSettingsRepository(
          config: _defaultConfig,
          apiKeys: {'p1': 'key-p1'},
        ),
        logger: _logger,
      );

      final session = _session().copyWith(
        temperature: 0.5,
        maxTokens: 2048,
      );
      final result = await resolver.resolveIntermediateSettings(session);

      expect(result.settings.temperature, 0.5);
      expect(result.settings.maxTokens, 2048);
      // 未覆盖的字段仍来自 intermediate.generation 默认值
      expect(result.settings.topP, 0.95);
    });

    test('3. 非生成参数仍复用 broadcastChat 默认', () async {
      const config = AppConfig(
        version: '0.1',
        broadcastChat: BroadcastChatConfig(
          modelId: 'bc-model',
          streamEnabled: false,
          autoCompaction: false,
        ),
      );
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(presets: [_preset('p1')]),
        settingsRepository: _FakeSettingsRepository(
          config: config,
          apiKeys: {'p1': 'key-p1'},
        ),
        logger: _logger,
      );

      final result = await resolver.resolveIntermediateSettings(_session());

      // 非生成参数来自 broadcastChat
      expect(result.settings.streamEnabled, false);
      expect(result.settings.autoCompaction, false);
    });

    test('4. systemPrompt 来自会话级 override', () async {
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(presets: [_preset('p1')]),
        settingsRepository: _FakeSettingsRepository(
          config: _defaultConfig,
          apiKeys: {'p1': 'key-p1'},
        ),
        logger: _logger,
      );

      final session = _session().copyWith(
        systemPromptOverride: '你是海盗船长',
      );
      final result = await resolver.resolveIntermediateSettings(session);

      expect(result.settings.systemPrompt, '你是海盗船长');
    });

    test('5. systemPrompt 空串表示未配置（由 ContextBuilder 回退到默认）', () async {
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(presets: [_preset('p1')]),
        settingsRepository: _FakeSettingsRepository(
          config: _defaultConfig,
          apiKeys: {'p1': 'key-p1'},
        ),
        logger: _logger,
      );

      final result = await resolver.resolveIntermediateSettings(_session());

      // 会话级 systemPromptOverride 为 null → settings.systemPrompt 为空串
      expect(result.settings.systemPrompt, '');
    });
  });

  group('resolveIntermediatePhaseNamingConfig', () {
    test('1. 会话级 phase 模型优先', () async {
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(
          presets: [_preset('p1', baseUrl: 'https://api.p1.com/v1')],
        ),
        settingsRepository: _FakeSettingsRepository(
          config: _phaseModelsConfig,
          apiKeys: {'p1': 'key-p1'},
        ),
        logger: _logger,
      );

      final session = _session(
        phaseModels: const SessionPhaseModels(
          generatingPresetId: 'p1',
          generatingModelId: 'session-model',
        ),
      );
      final result = await resolver.resolveIntermediatePhaseNamingConfig(
        session,
        'generating',
      );

      expect(result, isNotNull);
      expect(result!.modelId, 'session-model');
      expect(result.baseUrl, 'https://api.p1.com/v1');
      expect(result.apiKey, 'key-p1');
    });

    test('2. 会话级未配置 → 回退全局 phase_models', () async {
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(
          presets: [
            _preset('int-preset', baseUrl: 'https://api.int.com/v1'),
          ],
        ),
        settingsRepository: _FakeSettingsRepository(
          config: _phaseModelsConfig,
          apiKeys: {'int-preset': 'key-int'},
        ),
        logger: _logger,
      );

      final result = await resolver.resolveIntermediatePhaseNamingConfig(
        _session(),
        'generating',
      );

      expect(result, isNotNull);
      expect(result!.modelId, 'int-model');
      expect(result.baseUrl, 'https://api.int.com/v1');
      expect(result.apiKey, 'key-int');
    });

    test('3. 会话级 + 全局级都未配置 → 返回 null', () async {
      // _defaultConfig 的 intermediate.phaseModels 全部为空串
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(presets: [_preset('p1')]),
        settingsRepository: _FakeSettingsRepository(
          config: _defaultConfig,
          apiKeys: {'p1': 'key-p1'},
        ),
        logger: _logger,
      );

      final result = await resolver.resolveIntermediatePhaseNamingConfig(
        _session(),
        'generating',
      );

      // 都未配置 → null（调用方应触发 E010 配置错误）
      expect(result, isNull);
    });

    test('4. 无可用 preset → 返回 null', () async {
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(presets: []),
        settingsRepository: _FakeSettingsRepository(config: _phaseModelsConfig),
        logger: _logger,
      );

      final result = await resolver.resolveIntermediatePhaseNamingConfig(
        _session(),
        'generating',
      );

      expect(result, isNull);
    });

    test('5. 有 preset 但全无 key → 返回 null', () async {
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(presets: [_preset('p1')]),
        settingsRepository: _FakeSettingsRepository(
          config: _phaseModelsConfig,
          apiKeys: {},
        ),
        logger: _logger,
      );

      final result = await resolver.resolveIntermediatePhaseNamingConfig(
        _session(),
        'generating',
      );

      expect(result, isNull);
    });

    test('6. 全局 modelId 为空串 → 返回 null', () async {
      const config = AppConfig(
        version: '0.1',
        broadcastChat: BroadcastChatConfig(),
        intermediate: IntermediateConfig(
          phaseModels: PhaseModelsConfig(
            generatingPresetId: 'p1',
          ),
        ),
      );
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(presets: [_preset('p1')]),
        settingsRepository: _FakeSettingsRepository(
          config: config,
          apiKeys: {'p1': 'key-p1'},
        ),
        logger: _logger,
      );

      final result = await resolver.resolveIntermediatePhaseNamingConfig(
        _session(),
        'generating',
      );

      expect(result, isNull);
    });

    test('7. 非法 phase 值 → 返回 null', () async {
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(presets: [_preset('p1')]),
        settingsRepository: _FakeSettingsRepository(
          config: _phaseModelsConfig,
          apiKeys: {'p1': 'key-p1'},
        ),
        logger: _logger,
      );

      final result = await resolver.resolveIntermediatePhaseNamingConfig(
        _session(),
        'invalid_phase',
      );

      expect(result, isNull);
    });

    test('8. 返回所选模型的最大输出元数据', () async {
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(
          presets: [
            _preset(
              'p1',
              cachedModels: const [
                ModelInfo(modelId: 'session-model', maxOutput: 32768),
              ],
            ),
          ],
        ),
        settingsRepository: _FakeSettingsRepository(
          config: _phaseModelsConfig,
          apiKeys: {'p1': 'key-p1'},
        ),
        logger: _logger,
      );
      final session = _session(
        phaseModels: const SessionPhaseModels(
          generatingPresetId: 'p1',
          generatingModelId: 'session-model',
        ),
      );

      final result = await resolver.resolveIntermediatePhaseNamingConfig(
        session,
        'generating',
      );

      expect(result!.maxOutputTokens, 32768);
    });
  });

  group('resolveTitleNamingConfig', () {
    test('1. common.title_model 配置完整 → 返回 NamingConfig', () async {
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(
          presets: [
            _preset('title-preset', baseUrl: 'https://api.title.com/v1'),
          ],
        ),
        settingsRepository: _FakeSettingsRepository(
          config: _titleModelConfig,
          apiKeys: {'title-preset': 'key-title'},
        ),
        logger: _logger,
      );

      final result = await resolver.resolveTitleNamingConfig();

      expect(result, isNotNull);
      expect(result!.modelId, 'title-model');
      expect(result.baseUrl, 'https://api.title.com/v1');
      expect(result.apiKey, 'key-title');
    });

    test('2. common.title_model 未配置 → 返回 null', () async {
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(presets: [_preset('p1')]),
        settingsRepository: _FakeSettingsRepository(
          config: _defaultConfig, // 无 title_model 配置
          apiKeys: {'p1': 'key-p1'},
        ),
        logger: _logger,
      );

      final result = await resolver.resolveTitleNamingConfig();

      expect(result, isNull);
    });

    test('3. title_model 配置了但 preset 无 key → 返回 null', () async {
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(presets: [_preset('p1')]),
        settingsRepository: _FakeSettingsRepository(
          config: _titleModelConfig,
          apiKeys: {}, // 无 key
        ),
        logger: _logger,
      );

      final result = await resolver.resolveTitleNamingConfig();

      expect(result, isNull);
    });
  });

  group('resolveBroadcastGeneratingNamingConfig', () {
    test('1. 会话级 preset+model 配置完整 → 用会话级模型', () async {
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(
          presets: [
            _preset('p1', baseUrl: 'https://api.p1.com/v1'),
            _preset('p2', baseUrl: 'https://api.p2.com/v1'),
          ],
        ),
        settingsRepository: _FakeSettingsRepository(
          config: _defaultConfig,
          apiKeys: {'p1': 'key-p1', 'p2': 'key-p2'},
        ),
        logger: _logger,
      );
      final session = _sessionWithModel(presetId: 'p2', modelId: 'p2-model');

      final result = await resolver.resolveBroadcastGeneratingNamingConfig(
        session,
      );

      expect(result, isNotNull);
      expect(result!.presetId, 'p2');
      expect(result.modelId, 'p2-model');
      expect(result.baseUrl, 'https://api.p2.com/v1');
      expect(result.apiKey, 'key-p2');
    });

    test('2. 会话级未配置 → 回落 broadcastChat.modelId + 第一个 preset', () async {
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(presets: [_preset('p1')]),
        settingsRepository: _FakeSettingsRepository(
          config: _defaultConfig, // broadcastChat.modelId='bc-model'
          apiKeys: {'p1': 'key-p1'},
        ),
        logger: _logger,
      );

      final result = await resolver.resolveBroadcastGeneratingNamingConfig(
        _sessionWithModel(),
      );

      expect(result, isNotNull);
      expect(result!.presetId, 'p1');
      expect(result.modelId, 'bc-model');
      expect(result.apiKey, 'key-p1');
    });

    test('3. 会话级与 broadcastChat 均无 modelId → 返回 null', () async {
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(presets: [_preset('p1')]),
        settingsRepository: _FakeSettingsRepository(
          config: const AppConfig(
            version: '0.1',
            broadcastChat: BroadcastChatConfig(), // modelId 为空
          ),
          apiKeys: {'p1': 'key-p1'},
        ),
        logger: _logger,
      );

      final result = await resolver.resolveBroadcastGeneratingNamingConfig(
        _sessionWithModel(),
      );

      expect(result, isNull);
    });

    test('4. 全部 preset 无 key → 返回 null', () async {
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(presets: [_preset('p1')]),
        settingsRepository: _FakeSettingsRepository(
          config: _defaultConfig,
          apiKeys: {},
        ),
        logger: _logger,
      );

      final result = await resolver.resolveBroadcastGeneratingNamingConfig(
        _sessionWithModel(),
      );

      expect(result, isNull);
    });
  });

  group('Simple 模式零侵验证', () {
    test('resolveSettings 仍用 broadcastChat（不受 intermediate 影响）', () async {
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(presets: [_preset('p1')]),
        settingsRepository: _FakeSettingsRepository(
          config: _phaseModelsConfig,
          apiKeys: {'p1': 'key-p1'},
        ),
        logger: _logger,
      );

      final result = await resolver.resolveSettings(_session());

      // Simple 模式 resolveSettings 应该用 broadcastChat.modelId
      expect(result.settings.modelId, 'bc-model');
    });
  });
}
