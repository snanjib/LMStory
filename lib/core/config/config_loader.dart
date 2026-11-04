import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/config/network_config.dart';
import 'package:lmstory/core/config/resource_ai_config.dart';
import 'package:lmstory/core/utils/logger.dart';

export 'package:lmstory/core/config/network_config.dart';

/// 应用配置
class AppConfig {
  const AppConfig({
    required this.version,
    required this.broadcastChat,
    this.network = const NetworkConfig(),
    this.common = const CommonConfig(),
    this.intermediate = const IntermediateConfig(),
    this.advanced = const AdvancedConfig(),
    this.resourceAi = const ResourceAiConfig(),
  });

  factory AppConfig.fromJson(Map<String, dynamic> json) => AppConfig(
        version: json['version'] as String? ?? '0.1',
        network: NetworkConfig.fromJson(
          json['network'] as Map<String, dynamic>? ?? {},
        ),
        common: CommonConfig.fromJson(
          json['common'] as Map<String, dynamic>? ?? {},
        ),
        broadcastChat: BroadcastChatConfig.fromJson(
          json['broadcast_chat'] as Map<String, dynamic>? ?? {},
        ),
        intermediate: IntermediateConfig.fromJson(
          json['intermediate'] as Map<String, dynamic>? ?? {},
        ),
        advanced: AdvancedConfig.fromJson(
          json['advanced'] as Map<String, dynamic>? ?? {},
        ),
        resourceAi: ResourceAiConfig.fromJson(
          json['resource_ai'] as Map<String, dynamic>? ?? {},
        ),
      );

  final String version;
  final NetworkConfig network;
  final CommonConfig common;
  final BroadcastChatConfig broadcastChat;
  final IntermediateConfig intermediate;

  /// 导演模式配置（2026-08-27 导演设置体系，设计文档 §4）
  final AdvancedConfig advanced;

  /// AI 建卡工具配置（2026-09-11 AI 建卡工具，设计文档 §配置）
  final ResourceAiConfig resourceAi;
}

/// 跨模式共享配置（common 节点，2026-07-21 新增）
///
/// 容纳与具体业务模式无关的"工具型"配置。当前仅含会话标题生成模型配置，
/// 后续可扩展其他跨模式共享项（如通用通知、全局快捷键等）。
class CommonConfig {
  const CommonConfig({
    this.titleModel = const TitleModelConfig(),
    this.auxiliary = const AuxiliaryCallConfig(),
  });

  factory CommonConfig.fromJson(Map<String, dynamic> json) => CommonConfig(
        titleModel: TitleModelConfig.fromJson(
          json['title_model'] as Map<String, dynamic>? ?? {},
        ),
        auxiliary: AuxiliaryCallConfig.fromJson(
          json['auxiliary'] as Map<String, dynamic>? ?? {},
        ),
      );

  /// 会话标题生成模型配置
  ///
  /// 独立于对话模式/故事模式，所有模式的会话标题生成都使用此配置。
  /// 未配置时（preset_id 或 model_id 为空），标题降级为回复前 N 字符。
  final TitleModelConfig titleModel;

  /// 辅助调用统一温度（压缩/标题/记忆整合/事实合并/世界设定共用）
  final AuxiliaryCallConfig auxiliary;
}

/// 会话标题生成模型配置（common.title_model 子节点）
///
/// **2026-07-21 配置架构重构**：原对话模式与故事模式各自从会话/全局模型配置
/// 中推导标题生成模型，导致逻辑分散。现统一收敛到此处，简化优先级链：
/// - 标题生成：common.title_model（无则降级为字符截取）
/// - 业务模型：对话模式 broadcastChat + 会话级覆盖；故事模式 phaseModels + 会话级覆盖
///
/// 持久化：SettingsRepository user_overrides
/// - `common.title_model.preset_id`
/// - `common.title_model.model_id`
class TitleModelConfig {
  const TitleModelConfig({
    this.presetId = '',
    this.modelId = '',
  });

  factory TitleModelConfig.fromJson(Map<String, dynamic> json) =>
      TitleModelConfig(
        presetId: json['preset_id'] as String? ?? '',
        modelId: json['model_id'] as String? ?? '',
      );

  /// 标题生成所用的供应商 ID
  ///
  /// 空串表示未配置，标题降级为字符截取。
  final String presetId;

  /// 标题生成所用的模型 ID
  ///
  /// 空串表示未配置，标题降级为字符截取。
  final String modelId;

  /// 是否已完整配置（preset_id 和 model_id 均非空）
  bool get isConfigured => presetId.isNotEmpty && modelId.isNotEmpty;
}

/// 辅助调用统一温度配置（common.auxiliary 子节点）
///
/// 压缩/标题/记忆整合/事实合并/世界设定等内部 LLM 任务共用一个温度，
/// 取代各调用点散落的硬编码值；缺键回退 0.3（快照口径：不留空）。
/// 禁发名单模型的实际出网由 resolveAuxiliaryTemperature 统一判定。
class AuxiliaryCallConfig {
  const AuxiliaryCallConfig({this.temperature = 0.3});

  factory AuxiliaryCallConfig.fromJson(Map<String, dynamic> json) =>
      AuxiliaryCallConfig(
        temperature: (json['temperature'] as num?)?.toDouble() ?? 0.3,
      );

  final double temperature;
}

/// 聊天配置
class BroadcastChatConfig {
  const BroadcastChatConfig({
    this.presetId = '',
    this.modelId = '',
    this.temperature = 0.7,
    this.topP = 1.0,
    //  真 null：null = 不设应用层上限（由模型决定）。语义对齐故事侧
    // OutputTokenPolicy——出网时 null/0 等价（OpenAI/Gemini 省略字段、
    // Anthropic 用模型 maxOutput 元数据填充，缺失时报错）。
    this.maxTokens,
    this.autoCompaction = true,
    this.compactionThreshold = 0.6,
    this.streamEnabled = true,
  });

  factory BroadcastChatConfig.fromJson(Map<String, dynamic> json) =>
      BroadcastChatConfig(
        presetId: json['preset_id'] as String? ?? '',
        modelId: json['model_id'] as String? ?? '',
        temperature: (json['temperature'] as num?)?.toDouble() ?? 0.7,
        topP: (json['top_p'] as num?)?.toDouble() ?? 1.0,
        // 缺键/null 保持 null（不回退数值）；显式 0 = 无上限哨兵，原样透传
        maxTokens: json['max_tokens'] as int?,
        autoCompaction: json['auto_compaction'] as bool? ?? true,
        compactionThreshold:
            (json['compaction_threshold'] as num?)?.toDouble() ?? 0.6,
        streamEnabled: json['stream_enabled'] as bool? ?? true,
      );

  final String presetId;
  final String modelId;
  final double temperature;
  final double topP;

  /// 单次回复 Token 上限（null = 由模型决定；0 = 无上限哨兵）
  final int? maxTokens;
  final bool autoCompaction;

  /// 压缩阈值百分比（0.4-0.9，默认 0.6），对标 ChatBox compactionThreshold
  final double compactionThreshold;
  final bool streamEnabled;
}

/// 配置加载器
class ConfigLoader {
  ConfigLoader({Logger? logger})
      : _logger =
            logger ?? const Logger('ConfigLoader', minLevel: LogLevel.warn);

  static const String _configPath = 'assets/configs/default_config.json';

  final Logger _logger;
  AppConfig? _cachedConfig;
  Completer<AppConfig>? _loadCompleter;

  /// 加载配置（带缓存和并发保护）
  Future<AppConfig> load() async {
    final cached = _cachedConfig;
    if (cached != null) return cached;

    // 并发保护：多个调用共享同一个加载过程
    if (_loadCompleter != null) {
      return _loadCompleter!.future;
    }

    _loadCompleter = Completer<AppConfig>();

    try {
      final jsonStr = await rootBundle.loadString(_configPath);
      final jsonMap = jsonDecode(jsonStr) as Map<String, dynamic>;
      final config = AppConfig.fromJson(jsonMap);
      _cachedConfig = config;
      _loadCompleter!.complete(config);
      return config;
    } on FormatException catch (e) {
      _logger.warn('Config JSON format error, using defaults', detail: '$e');
    } on PlatformException catch (e) {
      _logger.warn('Config asset not found, using defaults', detail: '$e');
    } catch (e) {
      // 确保异常路径也完成 Completer，避免后续调用永久挂起
      _loadCompleter!.completeError(e);
      _loadCompleter = null;
      rethrow;
    }

    const defaults = AppConfig(
      version: '0.1',
      broadcastChat: BroadcastChatConfig(),
    );
    _cachedConfig = defaults;
    _loadCompleter!.complete(defaults);
    return defaults;
  }

  /// 强制重新加载
  Future<AppConfig> reload() async {
    _cachedConfig = null;
    _loadCompleter = null;
    return load();
  }
}
