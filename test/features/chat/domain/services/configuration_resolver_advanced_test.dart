import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/config/intermediate_prompts_v2.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/session_phase_models.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';

/// ConfigurationResolver 导演模式解析链单元测试（导演设置体系）
///
/// 验证 resolveAdvancedSettings / resolveAdvancedGeneratingNamingConfig /
/// snapshotAdvancedDefaults / resolveAdvancedEmbeddingConfig：
/// - 生成参数：会话列 > advanced.generation（无 broadcastChat 兜底）
/// - systemPrompt：会话列 > advanced.system_prompt（全局值合入 settings，
///   runner 仅空串回退内置规则——与故事模式不同）
/// - 模型：会话 phaseModels.generating > advanced.phase_models（导演无六步 phase）
/// - embedding：advanced.embedding*（intermediate.* 不再影响导演）

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

ApiPreset _preset(String id, {String baseUrl = 'https://api.adv.com/v1'}) =>
    ApiPreset(
      presetId: id,
      name: '导演供应商 $id',
      baseUrl: baseUrl,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

ChatSession _session({
  String? systemPromptOverride,
  double? temperature,
  int? maxTokens,
  SessionPhaseModels? phaseModels,
}) =>
    ChatSession(
      sessionId: 'session-adv',
      title: '导演会话',
      mode: 'advanced',
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 0,
      systemPromptOverride: systemPromptOverride,
      temperature: temperature,
      maxTokens: maxTokens,
      phaseModels: phaseModels ?? const SessionPhaseModels.empty(),
    );

const _logger = Logger('test', minLevel: LogLevel.warn);

/// advanced 段带自定义全局值的 AppConfig（intermediate 保持默认以验证解耦）
const _advancedConfig = AppConfig(
  version: '0.1',
  broadcastChat: BroadcastChatConfig(),
  intermediate: IntermediateConfig(
    systemPrompt: '故事规则（导演不得读取）',
    generation: GenerationConfig(temperature: 0.1),
  ),
  advanced: AdvancedConfig(
    systemPrompt: '导演全局规则',
    generatingPresetId: 'adv-preset',
    generatingModelId: 'gm-1',
    embeddingPresetId: 'emb-adv',
    embeddingModelId: 'emb-model',
  ),
);

ConfigurationResolver _resolver({AppConfig? config}) => ConfigurationResolver(
      presetRepository: _FakeApiPresetRepository(
        presets: [_preset('adv-preset'), _preset('emb-adv')],
      ),
      settingsRepository: _FakeSettingsRepository(
        config: config ?? _advancedConfig,
        apiKeys: {'adv-preset': 'key-adv', 'emb-adv': 'key-emb'},
      ),
      logger: _logger,
    );

// ── 测试 ────────────────────────────────────────────────────────────

void main() {
  group('resolveAdvancedSettings', () {
    test('会话列全 NULL → 回退 advanced 全局（不受 intermediate 影响）', () async {
      final settings =
          (await _resolver().resolveAdvancedSettings(_session())).settings;
      expect(settings.temperature, 0.8); // advanced.generation，非 0.1
      expect(settings.topP, 0.95);
      expect(settings.maxTokens, 8192);
      expect(settings.presencePenalty, 0.0);
      expect(settings.frequencyPenalty, 0.0);
      expect(settings.effectiveContextLimit, isNull);
      expect(settings.systemPrompt, '导演全局规则');
      expect(settings.reasoningEffort, isNull);
    });

    test('会话列有值 → 会话值胜出', () async {
      final settings = (await _resolver().resolveAdvancedSettings(
        _session(
          temperature: 0.3,
          maxTokens: 4096,
        ),
      ))
          .settings;
      expect(settings.temperature, 0.3);
      expect(settings.maxTokens, 4096);
    });

    test('systemPrompt 三级回退：会话 override 优先于 advanced 全局', () async {
      final settings = (await _resolver().resolveAdvancedSettings(
        _session(
          systemPromptOverride: '会话规则',
        ),
      ))
          .settings;
      expect(settings.systemPrompt, '会话规则');
    });

    test('apiKey 恒为 null（模型走独立命名解析）', () async {
      final result = await _resolver().resolveAdvancedSettings(_session());
      expect(result.apiKey, isNull);
    });
  });

  group('resolveAdvancedGeneratingNamingConfig', () {
    test('会话与全局均未配置 → null（E010 语义）', () async {
      final resolver = _resolver(
        config: const AppConfig(
          version: '0.1',
          broadcastChat: BroadcastChatConfig(),
        ),
      );
      expect(
        await resolver.resolveAdvancedGeneratingNamingConfig(_session()),
        isNull,
      );
    });

    test('全局 advanced.phase_models.generating → NamingConfig', () async {
      final naming =
          await _resolver().resolveAdvancedGeneratingNamingConfig(_session());
      expect(naming, isNotNull);
      expect(naming!.presetId, 'adv-preset');
      expect(naming.modelId, 'gm-1');
      expect(naming.apiKey, 'key-adv');
      expect(naming.baseUrl, 'https://api.adv.com/v1');
    });

    test('会话级 phaseModels.generating 优先于全局', () async {
      final naming = await _resolver().resolveAdvancedGeneratingNamingConfig(
        _session(
          phaseModels: const SessionPhaseModels(
            generatingPresetId: 'adv-preset',
            generatingModelId: 'session-gm',
          ),
        ),
      );
      expect(naming!.modelId, 'session-gm');
    });

    test('intermediate.phase_models 不影响导演解析（解耦）', () async {
      final resolver = _resolver(
        config: const AppConfig(
          version: '0.1',
          broadcastChat: BroadcastChatConfig(),
          intermediate: IntermediateConfig(
            phaseModels: PhaseModelsConfig(
              generatingPresetId: 'story-preset',
              generatingModelId: 'story-gm',
            ),
          ),
        ),
      );
      expect(
        await resolver.resolveAdvancedGeneratingNamingConfig(_session()),
        isNull,
      );
    });
  });

  group('snapshotAdvancedDefaults', () {
    test('快照来源为 advanced 段（仅 generating，其余 phase 为 null）', () async {
      final snapshot = await _resolver().snapshotAdvancedDefaults();
      expect(snapshot.temperature, 0.8);
      expect(snapshot.systemPrompt, '导演全局规则');
      expect(snapshot.phaseModels?.generatingPresetId, 'adv-preset');
      expect(snapshot.phaseModels?.generatingModelId, 'gm-1');
      expect(snapshot.phaseModels?.extractingPresetId, isNull);
      expect(snapshot.phaseModels?.reviewingModelId, isNull);
      expect(snapshot.phaseModels?.summarizingPresetId, isNull);
    });
  });

  group('resolveAdvancedEmbeddingConfig', () {
    test('advanced.embedding* 配置完整 → EmbeddingApiConfig', () async {
      final result = await _resolver().resolveAdvancedEmbeddingConfig();
      expect(result, isNotNull);
      expect(result!.model, 'emb-model');
      expect(result.apiKey, 'key-emb');
      expect(result.timeoutMs, 5000);
      expect(result.fallbackOnFailure, false);
    });

    test('仅 intermediate 配置 embedding → null（导演不再寄生故事配置）', () async {
      final resolver = _resolver(
        config: const AppConfig(
          version: '0.1',
          broadcastChat: BroadcastChatConfig(),
          intermediate: IntermediateConfig(
            embeddingPresetId: 'emb-adv',
            embeddingModelId: 'emb-model',
          ),
        ),
      );
      expect(await resolver.resolveAdvancedEmbeddingConfig(), isNull);
    });
  });

  group('resolveAdvancedSuggestReplyNamingConfig', () {
    test('全局 advanced.suggest_reply → NamingConfig', () async {
      final resolver = _resolver(
        config: const AppConfig(
          version: '0.1',
          broadcastChat: BroadcastChatConfig(),
          advanced: AdvancedConfig(
            generatingPresetId: 'adv-preset',
            generatingModelId: 'gm-1',
            suggestReply: SuggestReplyConfig(
              presetId: 'adv-preset',
              modelId: 'suggest-1',
            ),
          ),
        ),
      );
      final naming =
          await resolver.resolveAdvancedSuggestReplyNamingConfig(_session());
      expect(naming, isNotNull);
      expect(naming!.modelId, 'suggest-1');
      expect(naming.presetId, 'adv-preset');
      expect(naming.apiKey, 'key-adv');
    });

    test('intermediate.suggest_reply 不影响导演解析（不再寄生故事配置）', () async {
      final resolver = _resolver(
        config: const AppConfig(
          version: '0.1',
          broadcastChat: BroadcastChatConfig(),
          intermediate: IntermediateConfig(
            suggestReply: SuggestReplyConfig(
              presetId: 'adv-preset',
              modelId: 'story-suggest',
            ),
          ),
          advanced: AdvancedConfig(
            generatingPresetId: 'adv-preset',
            generatingModelId: 'gm-1',
          ),
        ),
      );
      // 未配置 advanced.suggest_reply → fallback 到 GM（gm-1），而非故事模型
      final naming =
          await resolver.resolveAdvancedSuggestReplyNamingConfig(_session());
      expect(naming, isNotNull);
      expect(naming!.modelId, 'gm-1');
    });

    test('会话级 suggestReply 模型优先于全局', () async {
      final resolver = _resolver(
        config: const AppConfig(
          version: '0.1',
          broadcastChat: BroadcastChatConfig(),
          advanced: AdvancedConfig(
            generatingPresetId: 'adv-preset',
            generatingModelId: 'gm-1',
            suggestReply: SuggestReplyConfig(
              presetId: 'adv-preset',
              modelId: 'suggest-global',
            ),
          ),
        ),
      );
      final naming = await resolver.resolveAdvancedSuggestReplyNamingConfig(
        _session().copyWith(
          suggestReplyPresetId: 'adv-preset',
          suggestReplyModelId: 'suggest-session',
        ),
      );
      expect(naming!.modelId, 'suggest-session');
    });

    test('会话与全局均未配置 → fallback GM；GM 也未配置 → null', () async {
      final resolver = _resolver(
        config: const AppConfig(
          version: '0.1',
          broadcastChat: BroadcastChatConfig(),
          advanced: AdvancedConfig(
            generatingPresetId: 'adv-preset',
            generatingModelId: 'gm-1',
          ),
        ),
      );
      final naming =
          await resolver.resolveAdvancedSuggestReplyNamingConfig(_session());
      expect(naming!.modelId, 'gm-1');

      final empty = await _resolver(
        config: const AppConfig(
          version: '0.1',
          broadcastChat: BroadcastChatConfig(),
        ),
      ).resolveAdvancedSuggestReplyNamingConfig(_session());
      expect(empty, isNull);
    });
  });

  group('resolveAdvancedSuggestReplyPrompt', () {
    test('advanced.suggest_reply.prompt > 内置默认；intermediate 不影响', () async {
      final resolver = _resolver(
        config: const AppConfig(
          version: '0.1',
          broadcastChat: BroadcastChatConfig(),
          intermediate: IntermediateConfig(
            suggestReply: SuggestReplyConfig(prompt: '故事推荐提示词'),
          ),
          advanced: AdvancedConfig(
            suggestReply: SuggestReplyConfig(prompt: '导演推荐提示词'),
          ),
        ),
      );
      expect(
        await resolver.resolveAdvancedSuggestReplyPrompt(_session()),
        '导演推荐提示词',
      );
    });

    test('会话级覆盖 > 全局；未配置 → 内置默认', () async {
      final resolver = _resolver();
      expect(
        await resolver.resolveAdvancedSuggestReplyPrompt(
          _session().copyWith(suggestReplyPromptOverride: '会话提示词'),
        ),
        '会话提示词',
      );
      expect(
        await resolver.resolveAdvancedSuggestReplyPrompt(_session()),
        kSuggestReplyDefaultPrompt,
      );
    });
  });
}
