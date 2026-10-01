import 'package:lmstory/features/settings/domain/entities/model_capability.dart';

/// models.dev 注册表中的模型元数据
///
/// 对标 ChatBox 的 `ModelMetadata`。从 https://models.dev/api.json 拉取，
/// 用于富化用户从 /models 拉取到的模型列表（补充 capabilities/contextWindow/maxOutput）。
class ModelMetadata {
  const ModelMetadata({
    required this.modelId,
    this.name,
    this.type = ModelType.chat,
    this.capabilities = const [],
    this.contextWindow,
    this.maxOutput,
    this.family,
    this.releaseDate,
  });

  /// 从 models.dev API 的 JSON 对象解析
  ///
  /// models.dev 格式：
  /// ```json
  /// {
  ///   "id": "gpt-4o",
  ///   "name": "GPT-4o",
  ///   "attachment": true,
  ///   "reasoning": false,
  ///   "tool_call": true,
  ///   "limit": { "context": 128000, "output": 16384 },
  ///   "modalities": { "input": ["text","image"], "output": ["text"] }
  /// }
  /// ```
  factory ModelMetadata.fromModelsDev(Map<String, dynamic> json) {
    final caps = <ModelCapability>[];
    // attachment=true 或 modalities.input 含 image → vision
    if (json['attachment'] == true) {
      caps.add(ModelCapability.vision);
    } else {
      final modalities = json['modalities'];
      if (modalities is Map) {
        final input = modalities['input'];
        if (input is List && input.any((m) => m == 'image')) {
          caps.add(ModelCapability.vision);
        }
      }
    }
    if (json['reasoning'] == true) caps.add(ModelCapability.reasoning);
    if (json['tool_call'] == true) caps.add(ModelCapability.toolUse);

    final limit = json['limit'];
    int? contextWindow;
    int? maxOutput;
    if (limit is Map) {
      contextWindow = (limit['context'] as num?)?.toInt();
      maxOutput = (limit['output'] as num?)?.toInt();
    }

    return ModelMetadata(
      modelId: json['id'] as String? ?? '',
      name: json['name'] as String?,
      capabilities: caps,
      contextWindow: contextWindow,
      maxOutput: maxOutput,
      family: json['family'] as String?,
      releaseDate: json['release_date'] as String?,
    );
  }

  /// 模型 ID（与 /models 返回的 id 对应）
  final String modelId;

  /// 模型显示名
  final String? name;

  /// 模型类型
  final ModelType type;

  /// 能力列表
  final List<ModelCapability> capabilities;

  /// 上下文窗口
  final int? contextWindow;

  /// 最大输出
  final int? maxOutput;

  /// 模型家族（如 gpt、claude、gemini）
  final String? family;

  /// 发布日期（ISO 字符串）
  final String? releaseDate;
}
