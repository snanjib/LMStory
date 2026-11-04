/// resource_ai 会话装配：skill 注册表 + 模型首用快照 + 工具工厂。
///
/// controller经本对象取得一次会话的全部依赖；asset 读取在
/// Data 层 loader（`resource_ai_skill_loader.dart`）注入，domain 不碰
/// rootBundle。
library;

import 'package:lmstory/core/agent/agent_skill_registry.dart';
import 'package:lmstory/core/config/resource_ai_config.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';

class ResourceAiSession {
  ResourceAiSession({
    required this.skillRegistry,
    required Future<String?> Function(String name) loadSkillBody,
    required SettingsRepository settingsRepository,
  })  : _loadSkillBody = loadSkillBody,
        _settingsRepository = settingsRepository;

  final AgentSkillRegistry skillRegistry;
  final Future<String?> Function(String name) _loadSkillBody;
  final SettingsRepository _settingsRepository;

  /// read_skill 工具的正文加载回调。
  Future<String?> loadSkillBody(String name) => _loadSkillBody(name);

  /// 模型首用快照（配置哲学：禁「跟随全局」动态引用）。
  ///
  /// - 已配置（override 有 resource_ai.model）：直接返回，什么都不写。
  /// - 未配置且全局对话默认模型可用：把 broadcast_chat 的 preset/model
  ///   落成 override 快照，之后 static；⚙ 重选 = 直接覆盖写。
  /// - 全局也无模型：返回未配置状态（UI 走内联模型选择）。
  Future<ResourceAiConfig> ensureModelSnapshot() async {
    final config = await _settingsRepository.getResolvedConfig();
    if (config.resourceAi.isModelConfigured) return config.resourceAi;

    final presetId = config.broadcastChat.presetId;
    final modelId = config.broadcastChat.modelId;
    if (presetId.isEmpty || modelId.isEmpty) return config.resourceAi;

    await _settingsRepository.setUserOverride(
      'resource_ai.model.preset_id',
      presetId,
    );
    await _settingsRepository.setUserOverride(
      'resource_ai.model.model_id',
      modelId,
    );
    return (await _settingsRepository.getResolvedConfig()).resourceAi;
  }

  /// 更换模型（会话级 override 覆盖写，下一轮生效）。
  Future<void> updateModelOverride(String presetId, String modelId) async {
    await _settingsRepository.setUserOverride(
      'resource_ai.model.preset_id',
      presetId,
    );
    await _settingsRepository.setUserOverride(
      'resource_ai.model.model_id',
      modelId,
    );
  }

  /// 设置采样温度覆盖（`resource_ai.temperature`）。
  Future<void> setTemperature(double value) =>
      _settingsRepository.setUserOverride('resource_ai.temperature', value);

  /// 设置每轮步数预算覆盖（`resource_ai.max_steps`）。
  Future<void> setMaxSteps(int value) =>
      _settingsRepository.setUserOverride('resource_ai.max_steps', value);

  /// 会话起步温度：resource_ai 覆盖优先，未覆盖回退全局对话温度。
  Future<double> resolveInitialTemperature() async {
    final config = await _settingsRepository.getResolvedConfig();
    return config.resourceAi.temperature ?? config.broadcastChat.temperature;
  }

  /// 当前全局对话温度（UI 展示「回退值」用）。
  Future<double> currentBroadcastTemperature() async =>
      (await _settingsRepository.getResolvedConfig()).broadcastChat.temperature;
}
