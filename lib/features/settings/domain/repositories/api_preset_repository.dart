import 'package:lmstory/features/settings/data/provider_templates.dart'
    show ProviderTemplates;
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';

/// API 预设管理仓库接口
abstract class ApiPresetRepository {
  /// 获取全部预设（含内置 + 自定义）
  Future<List<ApiPreset>> getAllPresets();

  /// 获取单个预设
  Future<ApiPreset> getPreset(String presetId);

  /// 创建自定义预设
  ///
  /// [baseUrl] 可选——创建时可仅填名称，后续在详情页补全 URL。
  /// 未提供时存为空字符串，由详情页的 URL 编辑逻辑负责补全。
  /// [protocol] 可选——创建时锁定协议类型，默认 [LlmProtocol.openaiCompatible]。
  /// 协议类型创建后不可修改（DOC-12 §9.3）。
  /// [omitSamplingParams] 默认开启，旧版备份恢复可保留原来的发送行为。
  Future<ApiPreset> createPreset({
    required String name,
    String baseUrl = '',
    LlmProtocol protocol = LlmProtocol.openaiCompatible,
    bool omitSamplingParams = true,
  });

  /// 基于模板创建自定义 preset（支持多账号）
  ///
  /// 从 [ProviderTemplates] 注册表查找 [templateId]，继承 protocol 和
  /// defaultBaseUrl，创建 isBuiltIn=false 的新行。
  /// 用户只需填入 API Key 即可使用，无需手动配置 URL。
  ///
  /// [name] 为用户自定义显示名（如 "OpenAI 备用账号"）。
  ///
  /// 实现依据：DOC-12 §4.3。
  Future<ApiPreset> createFromTemplate({
    required String templateId,
    required String name,
  });

  /// 更新预设（覆盖式：内置与自定义都直接更新原行）
  ///
  /// v0.2 起 DOC-12 §4.3 改为覆盖式更新，移除原 fork-on-write 行为。
  /// 内置 preset 可通过 [resetPreset] 恢复默认值。
  Future<ApiPreset> updatePreset(
    String presetId,
    ApiPreset Function(ApiPreset current) updater,
  );

  /// 重置内置 preset 为默认值（清空用户覆盖）
  ///
  /// 仅对内置 preset 有效。从 [ProviderTemplates] 注册表查找对应模板，
  /// 重置 name/baseUrl/protocol 为模板默认值，清空 cachedModels，
  /// 保留 API Key。自定义 preset 调用此方法抛错。
  ///
  /// 实现依据：DOC-12 §4.3。
  Future<ApiPreset> resetPreset(String presetId);

  /// 删除预设（内置预设不可删除）
  Future<void> deletePreset(String presetId);

  /// 从 API 获取可用模型列表（通过适配器按 protocol 路由到正确的端点）
  Future<List<ModelInfo>> fetchModels(String presetId);

  /// 更新预设的模型列表（缓存到本地）
  Future<void> updateModelList(String presetId, List<ModelInfo> models);

  /// 删除所有自定义供应商（保留内置供应商）
  ///
  /// 用于数据导入覆盖模式。同时清除关联的 API Key。
  Future<void> deleteAllCustomPresets();

  /// 获取自定义供应商数量（不含内置）
  Future<int> getCustomPresetCount();
}
