import 'package:lmstory/features/settings/data/repositories/api_preset_repository_impl.dart'
    show ApiPresetRepositoryImpl;
import 'package:lmstory/features/settings/domain/entities/api_preset.dart'
    show ApiPreset;
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';

/// 供应商模板
///
/// 静态注册的内置供应商配置模板。用户基于模板创建自定义 [ApiPreset] 时，
/// 自动继承 [protocol] 和 [defaultBaseUrl]，仅需填入 API Key 即可使用。
///
/// 不预填模型列表（符合"模型迭代快"要求，避免下架/更新导致的隐性问题）。
///
/// 实现依据：DOC-12 §4.1。
class ProviderTemplate {
  const ProviderTemplate({
    required this.templateId,
    required this.name,
    required this.protocol,
    required this.defaultBaseUrl,
    this.providerOptions,
    this.websiteUrl,
    this.docsUrl,
    this.apiKeyUrl,
  });

  /// 模板唯一标识（`tpl-openai` / `tpl-deepseek` 等）
  final String templateId;

  /// 显示名
  final String name;

  /// 协议类型（决定 LlmProtocolAdapter 的分发目标）
  final LlmProtocol protocol;

  /// 默认 baseUrl（不含路径，路径由适配器拼接）
  final String defaultBaseUrl;

  /// 模板快照的协议特有参数（S-1，2026-09-06 新增）
  ///
  /// 重置 = 把当前模板快照值写入本层：现有模板均为 null（无自定义参数），
  /// resetPreset 据此清空 provider_options 列。未来模板可预填默认参数。
  final Map<String, dynamic>? providerOptions;

  /// 官网链接（用于详情页跳转）
  final String? websiteUrl;

  /// 文档链接（用于详情页跳转，帮助用户查阅协议差异）
  final String? docsUrl;

  /// 获取 API Key 的链接（用于详情页引导用户申请）
  final String? apiKeyUrl;

  /// 从 templateId 推导内置 preset 的 presetId
  ///
  /// 约定：`tpl-openai` → `builtin-openai`（DOC-12 §4.2）
  String get builtInPresetId => 'builtin-${templateId.substring(4)}';
}

/// 供应商模板注册表
///
/// 静态注册所有内置模板。后续扩展只需在 [all] 列表加一行，不影响数据库。
///
/// 实现依据：DOC-12 §4.1。
class ProviderTemplates {
  const ProviderTemplates();

  /// 所有内置模板
  static const List<ProviderTemplate> all = [
    ProviderTemplate(
      templateId: 'tpl-openai',
      name: 'OpenAI',
      protocol: LlmProtocol.openaiCompatible,
      defaultBaseUrl: 'https://api.openai.com',
      websiteUrl: 'https://openai.com',
      docsUrl: 'https://platform.openai.com/docs',
      apiKeyUrl: 'https://platform.openai.com/api-keys',
    ),
    ProviderTemplate(
      templateId: 'tpl-deepseek',
      name: 'DeepSeek',
      protocol: LlmProtocol.openaiCompatible,
      defaultBaseUrl: 'https://api.deepseek.com',
      websiteUrl: 'https://www.deepseek.com',
      apiKeyUrl: 'https://platform.deepseek.com/api_keys',
    ),
    ProviderTemplate(
      templateId: 'tpl-openrouter',
      name: 'OpenRouter',
      protocol: LlmProtocol.openaiCompatible,
      // 注意：OpenRouter 的 baseUrl 必须带 /v1，否则 API 请求 404
      defaultBaseUrl: 'https://openrouter.ai/api/v1',
      websiteUrl: 'https://openrouter.ai',
      docsUrl: 'https://openrouter.ai/docs',
      apiKeyUrl: 'https://openrouter.ai/keys',
    ),
    ProviderTemplate(
      templateId: 'tpl-anthropic',
      name: 'Anthropic Claude',
      protocol: LlmProtocol.anthropic,
      defaultBaseUrl: 'https://api.anthropic.com',
      websiteUrl: 'https://www.anthropic.com',
      docsUrl: 'https://docs.anthropic.com',
      apiKeyUrl: 'https://console.anthropic.com/settings/keys',
    ),
    ProviderTemplate(
      templateId: 'tpl-gemini',
      name: 'Google Gemini',
      protocol: LlmProtocol.geminiNative,
      defaultBaseUrl: 'https://generativelanguage.googleapis.com',
      websiteUrl: 'https://ai.google.dev',
      docsUrl: 'https://ai.google.dev/gemini-api/docs',
      apiKeyUrl: 'https://aistudio.google.com/app/apikey',
    ),
    ProviderTemplate(
      templateId: 'tpl-nvidia-nim',
      name: 'NVIDIA NIM',
      // NVIDIA NIM 完全兼容 OpenAI 协议（官方文档明确声明：
      // "Compatible with OpenAI. See platform.openai.com/docs/api-reference/chat/create"）
      // 端点 /chat/completions + /models（版本号由 ApiUrlResolver 管理），SSE 格式同 OpenAI。
      // 复用 openaiCompatible 适配器即可，无需独立适配器。
      protocol: LlmProtocol.openaiCompatible,
      defaultBaseUrl: 'https://integrate.api.nvidia.com',
      websiteUrl: 'https://developer.nvidia.com/nim',
      docsUrl: 'https://docs.api.nvidia.com/nim',
      apiKeyUrl: 'https://build.nvidia.com/explore/discover',
    ),
    ProviderTemplate(
      templateId: 'tpl-agnes',
      name: 'Agnes AI',
      // Agnes AI 完全兼容 OpenAI 协议（官方文档明确声明：
      // "兼容 OpenAI 风格的接口，只需修改 Base URL/API Key/模型名称"）
      // 端点 /chat/completions + /models（版本号由 ApiUrlResolver 管理），SSE 格式同 OpenAI。
      // 复用 openaiCompatible 适配器即可，无需独立适配器。
      // defaultBaseUrl 使用 apihub 网关（支持文本/图像/视频全模态模型）。
      protocol: LlmProtocol.openaiCompatible,
      defaultBaseUrl: 'https://apihub.agnes-ai.com',
      websiteUrl: 'https://agnes-ai.com',
      docsUrl: 'https://agnes-ai.com/zh-Hans/docs/overview',
      apiKeyUrl: 'https://platform.agnes-ai.com',
    ),
  ];

  /// 按 templateId 查找模板
  static ProviderTemplate? findById(String templateId) =>
      all.where((t) => t.templateId == templateId).firstOrNull;

  /// 按 builtInPresetId 查找模板
  ///
  /// 用于 [ApiPresetRepositoryImpl.resetPreset] 从内置 presetId 反查模板默认值。
  static ProviderTemplate? findByBuiltInPresetId(String presetId) =>
      all.where((t) => t.builtInPresetId == presetId).firstOrNull;
}
