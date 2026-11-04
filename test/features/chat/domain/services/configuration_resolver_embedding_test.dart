import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';

/// ConfigurationResolver.resolveEmbeddingConfig 单元测试（V3）
///
/// 验证 V1 新增的 embedding 配置解析逻辑（DOC-08 §3.4 纯 API 方案）：
/// - 未配置 embedding preset/model（空串）→ null（FTS5 兜底）
/// - 已配置完整 → 返回 EmbeddingApiConfig（model/baseUrl/apiKey/timeoutMs/fallbackOnFailure）
/// - preset 不存在（已被删除）→ null
/// - apiKey 缺失 → null
/// - timeoutMs/fallbackOnFailure 从 EmbeddingConfig 正确读取
///
/// 权威设计：DOC-09A-1 §3.7（失败降级 FTS5）、DOC-08 §3.4（纯 API 方案）。

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

// ── 测试数据 ────────────────────────────────────────────────────────

ApiPreset _preset(String id, {String baseUrl = 'https://api.emb.com/v1'}) =>
    ApiPreset(
      presetId: id,
      name: '嵌入供应商 $id',
      baseUrl: baseUrl,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

const _logger = Logger('test', minLevel: LogLevel.warn);

/// 未配置 embedding 的 AppConfig（embeddingPresetId/ModelId 均空串）
const _noEmbeddingConfig = AppConfig(
  version: '0.1',
  broadcastChat: BroadcastChatConfig(),
);

/// 已配置 embedding 的 AppConfig（自定义 timeoutMs/fallbackOnFailure 验证读取）
const _embeddingConfig = AppConfig(
  version: '0.1',
  broadcastChat: BroadcastChatConfig(),
  intermediate: IntermediateConfig(
    embeddingPresetId: 'emb-preset',
    embeddingModelId: 'text-embedding-3-small',
    embedding: EmbeddingConfig(timeoutMs: 3000),
  ),
);

/// 仅配置 embeddingPresetId（modelId 空串）→ 应返回 null
const _partialConfig = AppConfig(
  version: '0.1',
  broadcastChat: BroadcastChatConfig(),
  intermediate: IntermediateConfig(
    embeddingPresetId: 'emb-preset',
    // embeddingModelId 空串
  ),
);

// ── 测试 ────────────────────────────────────────────────────────────

void main() {
  group('resolveEmbeddingConfig', () {
    test('1. 未配置 embedding（presetId/modelId 均空）→ null', () async {
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(
          presets: [_preset('emb-preset')],
        ),
        settingsRepository: _FakeSettingsRepository(
          config: _noEmbeddingConfig,
          apiKeys: {'emb-preset': 'key-emb'},
        ),
        logger: _logger,
      );

      expect(await resolver.resolveEmbeddingConfig(), isNull);
    });

    test('2. 仅配置 presetId（modelId 空）→ null', () async {
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(
          presets: [_preset('emb-preset')],
        ),
        settingsRepository: _FakeSettingsRepository(
          config: _partialConfig,
          apiKeys: {'emb-preset': 'key-emb'},
        ),
        logger: _logger,
      );

      expect(await resolver.resolveEmbeddingConfig(), isNull);
    });

    test('3. 已配置完整 → 返回 EmbeddingApiConfig（含自定义 timeoutMs/fallbackOnFailure）',
        () async {
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(
          presets: [_preset('emb-preset')],
        ),
        settingsRepository: _FakeSettingsRepository(
          config: _embeddingConfig,
          apiKeys: {'emb-preset': 'key-emb'},
        ),
        logger: _logger,
      );

      final result = await resolver.resolveEmbeddingConfig();

      expect(result, isNotNull);
      expect(result!.model, 'text-embedding-3-small');
      expect(result.baseUrl, 'https://api.emb.com/v1');
      expect(result.apiKey, 'key-emb');
      // 验证从 EmbeddingConfig 读取（自定义值）
      expect(result.timeoutMs, 3000);
      expect(result.fallbackOnFailure, false);
    });

    test('4. preset 不存在（已被删除）→ null（catch 降级）', () async {
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(
          presets: [], // emb-preset 不在列表中 → getPreset 抛 StateError
        ),
        settingsRepository: _FakeSettingsRepository(
          config: _embeddingConfig,
          apiKeys: {'emb-preset': 'key-emb'},
        ),
        logger: _logger,
      );

      // getPreset 抛异常 → catch → 返回 null（FTS5 兜底）
      expect(await resolver.resolveEmbeddingConfig(), isNull);
    });

    test('5. apiKey 缺失（null）→ null', () async {
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(
          presets: [_preset('emb-preset')],
        ),
        settingsRepository: _FakeSettingsRepository(
          config: _embeddingConfig,
          apiKeys: {}, // 无 emb-preset 的 key
        ),
        logger: _logger,
      );

      expect(await resolver.resolveEmbeddingConfig(), isNull);
    });

    test('6. apiKey 为空串 → null', () async {
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(
          presets: [_preset('emb-preset')],
        ),
        settingsRepository: _FakeSettingsRepository(
          config: _embeddingConfig,
          apiKeys: {'emb-preset': ''}, // 空串
        ),
        logger: _logger,
      );

      expect(await resolver.resolveEmbeddingConfig(), isNull);
    });

    test('7. 默认 EmbeddingConfig 值（timeoutMs=5000/fallbackOnFailure=false）',
        () async {
      const config = AppConfig(
        version: '0.1',
        broadcastChat: BroadcastChatConfig(),
        intermediate: IntermediateConfig(
          embeddingPresetId: 'emb-preset',
          embeddingModelId: 'emb-model',
          // embedding 用默认值（timeoutMs=5000, fallbackOnFailure=false）
        ),
      );
      final resolver = ConfigurationResolver(
        presetRepository: _FakeApiPresetRepository(
          presets: [_preset('emb-preset')],
        ),
        settingsRepository: _FakeSettingsRepository(
          config: config,
          apiKeys: {'emb-preset': 'key-emb'},
        ),
        logger: _logger,
      );

      final result = await resolver.resolveEmbeddingConfig();

      expect(result, isNotNull);
      expect(result!.timeoutMs, 5000);
      expect(result.fallbackOnFailure, false);
    });
  });
}
