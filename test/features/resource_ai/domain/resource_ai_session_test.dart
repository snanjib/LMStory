import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/agent/agent_skill_registry.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/config/resource_ai_config.dart';
import 'package:lmstory/features/resource_ai/domain/services/resource_ai_session.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';

/// 内存 override 表 fake：getResolvedConfig 走「默认配置 + 覆盖」的
/// 最小合并（仅 resource_ai 与 broadcast_chat 两段，够测快照逻辑）。
class _FakeSettingsRepository implements SettingsRepository {
  _FakeSettingsRepository(this._defaultConfig);

  final AppConfig _defaultConfig;
  final overrides = <String, dynamic>{};

  @override
  Future<AppConfig> getResolvedConfig() async {
    final presetId = overrides['resource_ai.model.preset_id'] as String? ?? '';
    final modelId = overrides['resource_ai.model.model_id'] as String? ?? '';
    final maxSteps = overrides['resource_ai.max_steps'] as int? ??
        _defaultConfig.resourceAi.maxSteps;
    return AppConfig(
      version: _defaultConfig.version,
      network: _defaultConfig.network,
      common: _defaultConfig.common,
      broadcastChat: _defaultConfig.broadcastChat,
      intermediate: _defaultConfig.intermediate,
      advanced: _defaultConfig.advanced,
      resourceAi: ResourceAiConfig(
        modelPresetId: presetId.isEmpty ? null : presetId,
        modelId: modelId.isEmpty ? null : modelId,
        maxSteps: maxSteps,
        temperature: overrides['resource_ai.temperature'] as double?,
      ),
    );
  }

  @override
  Future<void> setUserOverride(String key, dynamic value) async {
    overrides[key] = value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

ResourceAiSession _session(_FakeSettingsRepository repo) => ResourceAiSession(
      skillRegistry: const AgentSkillRegistry([]),
      loadSkillBody: (_) async => null,
      settingsRepository: repo,
    );

void main() {
  group('ensureModelSnapshot 首用快照', () {
    test('未配置且全局有默认模型 → 快照 broadcast_chat 到 override', () async {
      final repo = _FakeSettingsRepository(
        const AppConfig(
          version: '0.1',
          broadcastChat: BroadcastChatConfig(
            presetId: 'openrouter',
            modelId: 'agnes-2.5-flash',
          ),
        ),
      );
      final session = _session(repo);

      final config = await session.ensureModelSnapshot();

      expect(config.isModelConfigured, isTrue);
      expect(config.modelPresetId, 'openrouter');
      expect(config.modelId, 'agnes-2.5-flash');
      expect(repo.overrides['resource_ai.model.preset_id'], 'openrouter');
      expect(repo.overrides['resource_ai.model.model_id'], 'agnes-2.5-flash');
    });

    test('已配置 → 原样返回不写 override', () async {
      final repo = _FakeSettingsRepository(
        const AppConfig(
          version: '0.1',
          broadcastChat: BroadcastChatConfig(
            presetId: 'openrouter',
            modelId: 'agnes-2.5-flash',
          ),
        ),
      );
      await repo.setUserOverride('resource_ai.model.preset_id', 'other');
      await repo.setUserOverride('resource_ai.model.model_id', 'glm-5.3');
      final session = _session(repo);

      final config = await session.ensureModelSnapshot();

      expect(config.modelPresetId, 'other', reason: '已有配置不被快照覆盖');
      expect(repo.overrides['resource_ai.model.preset_id'], 'other');
    });

    test('全局也无模型 → 保持未配置（UI 走内联选择），不写 override', () async {
      final repo = _FakeSettingsRepository(
        const AppConfig(
          version: '0.1',
          broadcastChat: BroadcastChatConfig(),
        ),
      );
      final session = _session(repo);

      final config = await session.ensureModelSnapshot();

      expect(config.isModelConfigured, isFalse);
      expect(repo.overrides, isEmpty);
    });
  });

  test('loadSkillBody 透传注入的加载回调', () async {
    final repo = _FakeSettingsRepository(
      const AppConfig(version: '0.1', broadcastChat: BroadcastChatConfig()),
    );
    final session = ResourceAiSession(
      skillRegistry: const AgentSkillRegistry([]),
      loadSkillBody: (name) async => name == 'card-crafting' ? '正文' : null,
      settingsRepository: repo,
    );
    expect(await session.loadSkillBody('card-crafting'), '正文');
    expect(await session.loadSkillBody('nope'), isNull);
  });

  group('会话级设置写入', () {
    test('updateModelOverride 覆盖写 preset/model 两个键', () async {
      final repo = _FakeSettingsRepository(
        const AppConfig(version: '0.1', broadcastChat: BroadcastChatConfig()),
      );
      await repo.setUserOverride('resource_ai.model.preset_id', 'old');
      final session = _session(repo);

      await session.updateModelOverride('openrouter', 'glm-5.3');

      expect(repo.overrides['resource_ai.model.preset_id'], 'openrouter');
      expect(repo.overrides['resource_ai.model.model_id'], 'glm-5.3');
      final resolved = await repo.getResolvedConfig();
      expect(resolved.resourceAi.modelPresetId, 'openrouter');
      expect(resolved.resourceAi.modelId, 'glm-5.3');
    });

    test('setTemperature / setMaxSteps 写对应 override 键', () async {
      final repo = _FakeSettingsRepository(
        const AppConfig(version: '0.1', broadcastChat: BroadcastChatConfig()),
      );
      final session = _session(repo);

      await session.setTemperature(0.3);
      await session.setMaxSteps(10);

      expect(repo.overrides['resource_ai.temperature'], 0.3);
      expect(repo.overrides['resource_ai.max_steps'], 10);
    });
  });

  group('resolveInitialTemperature 回退链', () {
    test('无覆盖 → 取 broadcast_chat 温度', () async {
      final repo = _FakeSettingsRepository(
        const AppConfig(
          version: '0.1',
          broadcastChat: BroadcastChatConfig(temperature: 0.85),
        ),
      );
      final session = _session(repo);

      expect(await session.resolveInitialTemperature(), 0.85);
    });

    test('有 resource_ai.temperature 覆盖 → 覆盖优先', () async {
      final repo = _FakeSettingsRepository(
        const AppConfig(
          version: '0.1',
          broadcastChat: BroadcastChatConfig(temperature: 0.85),
        ),
      );
      await repo.setUserOverride('resource_ai.temperature', 0.2);
      final session = _session(repo);

      expect(await session.resolveInitialTemperature(), 0.2);
    });

    test('currentBroadcastTemperature 返回全局对话温度', () async {
      final repo = _FakeSettingsRepository(
        const AppConfig(
          version: '0.1',
          broadcastChat: BroadcastChatConfig(temperature: 0.6),
        ),
      );
      final session = _session(repo);

      expect(await session.currentBroadcastTemperature(), 0.6);
    });
  });
}
