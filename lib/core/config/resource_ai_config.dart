/// AI 建卡工具配置（resource_ai 节点）
///
/// 模型引用**不进 default_config.json**——只有用户覆盖值（首用快照落
/// override），静态默认仅 [maxSteps]。[temperature] 同为 override-only：
/// 未覆盖时运行期回退 broadcast_chat 的 temperature。
/// 持久化：SettingsRepository user_overrides：
/// - `resource_ai.model.preset_id` / `resource_ai.model.model_id`
/// - `resource_ai.temperature`
/// - `resource_ai.max_steps`
class ResourceAiConfig {
  const ResourceAiConfig({
    this.modelPresetId,
    this.modelId,
    this.maxSteps = 6,
    this.temperature,
  });

  factory ResourceAiConfig.fromJson(Map<String, dynamic> json) {
    final model = json['model'] as Map<String, dynamic>?;
    return ResourceAiConfig(
      modelPresetId:
          model?['preset_id'] as String? ?? json['preset_id'] as String?,
      modelId: model?['model_id'] as String? ?? json['model_id'] as String?,
      maxSteps: json['max_steps'] as int? ?? 6,
      temperature: (json['temperature'] as num?)?.toDouble(),
    );
  }

  /// 模型引用（presetId+modelId）。
  final String? modelPresetId;
  final String? modelId;

  /// 每轮 agent 预算步数上限。
  final int maxSteps;

  /// 采样温度（override-only；null = 未覆盖，回退 broadcast_chat 温度）。
  final double? temperature;

  /// 模型引用是否已完整（preset+model 均非空）。
  bool get isModelConfigured =>
      modelPresetId != null &&
      modelPresetId!.isNotEmpty &&
      modelId != null &&
      modelId!.isNotEmpty;
}
