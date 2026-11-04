import 'dart:convert';

import 'package:lmstory/core/network/llm_adapters/llm_protocol_adapter.dart'
    show LlmProtocolAdapter;
import 'package:lmstory/features/settings/data/provider_templates.dart'
    show ProviderTemplate;
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';
import 'package:lmstory/features/settings/domain/entities/model_capability.dart';

/// API 预设实体
///
/// 一个 ApiPreset 对应一行数据库记录，描述一家 LLM 供应商的接入配置：
/// - [presetId]：唯一标识（内置以 `builtin-` 前缀，自定义用 UUID）
/// - [protocol]：协议类型，决定 [LlmProtocolAdapter] 的分发目标
/// - [templateId]：基于哪个模板创建（null = 完全自定义或内置本身）
/// - [baseUrl]：API 端点根 URL（不含路径）
/// - [isBuiltIn]：内置 preset 不可删除，可覆盖式更新或重置
/// - [cachedModels]：上次"获取模型"拉取并富化后的模型列表缓存
/// - [providerOptions]：协议特有参数透传（如 OpenRouter extra_headers）
class ApiPreset {
  const ApiPreset({
    required this.presetId,
    required this.name,
    required this.baseUrl,
    required this.createdAt,
    required this.updatedAt,
    this.isBuiltIn = false,
    this.cachedModels = const [],
    this.protocol = LlmProtocol.openaiCompatible,
    this.templateId,
    this.providerOptions,
  });

  /// 从 JSON 反序列化（用于数据导入）
  factory ApiPreset.fromJson(Map<String, dynamic> json) {
    final modelsRaw = json['cachedModels'];
    final models = <ModelInfo>[];
    if (modelsRaw is List) {
      for (final m in modelsRaw) {
        if (m is Map<String, dynamic>) {
          models.add(ModelInfo.fromJson(m));
        }
      }
    }
    // providerOptions 反序列化（JSON 字符串或 Map）
    Map<String, dynamic>? providerOptions;
    final rawOptions = json['providerOptions'];
    if (rawOptions is Map<String, dynamic>) {
      providerOptions = rawOptions;
    } else if (rawOptions is String && rawOptions.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawOptions);
        if (decoded is Map<String, dynamic>) providerOptions = decoded;
      } on FormatException {
        // 忽略格式错误，降级为 null
      }
    }
    return ApiPreset(
      presetId: json['presetId'] as String,
      name: json['name'] as String,
      baseUrl: (json['baseUrl'] as String?) ?? '',
      isBuiltIn: (json['isBuiltIn'] as bool?) ?? false,
      protocol: LlmProtocol.fromJson(json['protocol'] as String?),
      templateId: json['templateId'] as String?,
      providerOptions: providerOptions,
      cachedModels: models,
      createdAt: DateTime.parse(json['createdAt'] as String),
      updatedAt: DateTime.parse(json['updatedAt'] as String),
    );
  }

  final String presetId;
  final String name;
  final String baseUrl;
  final bool isBuiltIn;
  final List<ModelInfo> cachedModels;

  /// 协议类型（决定请求构造与响应解析方式）
  ///
  /// 默认 [LlmProtocol.openaiCompatible]，兼容 v0.1 旧数据（无 protocol 列时回退）
  final LlmProtocol protocol;

  /// 模板 ID（null = 完全自定义或内置本身；非 null = 基于模板创建的自定义实例）
  ///
  /// 用于"基于模板新建"功能支持多账号。值为 `tpl-openai` / `tpl-deepseek` 等
  /// （对应 [ProviderTemplate.templateId]）
  final String? templateId;

  /// 协议特有参数透传（高级用户配置，nullable）
  ///
  /// 存储协议特有的配置参数，由 [LlmProtocolAdapter] 在构造请求时读取。
  /// null 表示无配置，适配器走默认逻辑。
  ///
  /// 常见用途（详见 DOC-12 §5.5）：
  /// - OpenRouter：`{'extra_headers': {'HTTP-Referer': '...'}}`
  /// - Anthropic：`{'anthropic_beta': ['interleaved-thinking-2025-05-14']}`
  /// - Gemini：`{'thinkingConfig': {'thinkingBudget': 2048}}`
  /// - DeepSeek：`{'thinking': {'type': 'enabled'}}`
  final Map<String, dynamic>? providerOptions;

  final DateTime createdAt;
  final DateTime updatedAt;

  ApiPreset copyWith({
    String? name,
    String? baseUrl,
    bool? isBuiltIn,
    List<ModelInfo>? cachedModels,
    LlmProtocol? protocol,
    String? templateId,
    Map<String, dynamic>? providerOptions,
    DateTime? updatedAt,
  }) =>
      ApiPreset(
        presetId: presetId,
        name: name ?? this.name,
        baseUrl: baseUrl ?? this.baseUrl,
        isBuiltIn: isBuiltIn ?? this.isBuiltIn,
        cachedModels: cachedModels ?? this.cachedModels,
        protocol: protocol ?? this.protocol,
        templateId: templateId ?? this.templateId,
        providerOptions: providerOptions ?? this.providerOptions,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  /// 序列化为 JSON（用于数据导入/导出）
  Map<String, dynamic> toJson() => {
        'presetId': presetId,
        'name': name,
        'baseUrl': baseUrl,
        'isBuiltIn': isBuiltIn,
        'protocol': protocol.toJson(),
        if (templateId != null) 'templateId': templateId,
        if (providerOptions != null) 'providerOptions': providerOptions,
        'cachedModels': cachedModels.map((m) => m.toJson()).toList(),
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };
}

/// 模型信息
///
/// 对标 ChatBox 的 `ProviderModelInfo`。一个模型 = 一份完整元数据：
/// 类型（chat/embedding/rerank）+ 能力标签 + 上下文/输出长度 + 显示信息。
class ModelInfo {
  const ModelInfo({
    required this.modelId,
    this.displayName,
    this.type = ModelType.chat,
    this.capabilities = const [],
    this.contextWindow,
    this.maxOutput,
    this.labels = const [],
  });

  /// 从 JSON 反序列化
  ///
  /// 兼容两种 key 格式：新格式 camelCase（modelId/displayName/contextWindow）
  /// 和旧格式 snake_case（model_id/display_name/context_window）。
  factory ModelInfo.fromJson(Map<String, dynamic> json) {
    final capsRaw = json['capabilities'];
    final caps = <ModelCapability>[];
    if (capsRaw is List) {
      for (final c in capsRaw) {
        final parsed = ModelCapability.fromString(c as String?);
        if (parsed != null) caps.add(parsed);
      }
    }
    final labelsRaw = json['labels'];
    final labels = <String>[];
    if (labelsRaw is List) {
      labels.addAll(labelsRaw.whereType<String>());
    }
    // 兼容旧 snake_case key（model_id/display_name/context_window）
    final modelId =
        json['modelId'] as String? ?? json['model_id'] as String? ?? '';
    final displayName =
        json['displayName'] as String? ?? json['display_name'] as String?;
    final contextWindow =
        json['contextWindow'] as int? ?? json['context_window'] as int?;
    return ModelInfo(
      modelId: modelId,
      displayName: displayName,
      type: ModelType.fromString(json['type'] as String?),
      capabilities: caps,
      contextWindow: contextWindow,
      maxOutput: json['maxOutput'] as int?,
      labels: labels,
    );
  }

  /// 模型唯一标识（如 gpt-4o）
  final String modelId;

  /// 显示名称（用户可自定义，对应 ChatBox 的 nickname）
  final String? displayName;

  /// 模型类型（默认 chat）
  final ModelType type;

  /// 能力标签列表
  final List<ModelCapability> capabilities;

  /// 上下文窗口大小（输入 token 上限）
  final int? contextWindow;

  /// 最大输出 token 数
  final int? maxOutput;

  /// 标签（如 recommended/pro/new）
  final List<String> labels;

  ModelInfo copyWith({
    String? modelId,
    String? displayName,
    ModelType? type,
    List<ModelCapability>? capabilities,
    int? contextWindow,
    int? maxOutput,
    List<String>? labels,
  }) =>
      ModelInfo(
        modelId: modelId ?? this.modelId,
        displayName: displayName ?? this.displayName,
        type: type ?? this.type,
        capabilities: capabilities ?? this.capabilities,
        contextWindow: contextWindow ?? this.contextWindow,
        maxOutput: maxOutput ?? this.maxOutput,
        labels: labels ?? this.labels,
      );

  /// 序列化为 JSON（用于 drift cached_models 字段存储）
  Map<String, dynamic> toJson() => {
        'modelId': modelId,
        if (displayName != null) 'displayName': displayName,
        if (type != ModelType.chat) 'type': type.toJson(),
        if (capabilities.isNotEmpty)
          'capabilities': capabilities.map((c) => c.toJson()).toList(),
        if (contextWindow != null) 'contextWindow': contextWindow,
        if (maxOutput != null) 'maxOutput': maxOutput,
        if (labels.isNotEmpty) 'labels': labels,
      };
}
