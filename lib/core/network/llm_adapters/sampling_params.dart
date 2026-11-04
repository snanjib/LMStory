/// 采样参数出网前的统一清洗与省略策略。
///
/// 设置界面的滑块按「min + 段长 × 档位」离散化取值，双精度段长乘法会留下
/// 浮点尾差（如拖到 0.57 实际写入 0.5700000000000001）；数字输入框也允许
/// 手输任意位数小数。这类值持久化后原样进入请求体，部分厂商校验小数位数
/// 并直接 400（如「top_p参数非法：限制小数点[2]位」）。
///
/// 各设置界面均按 0.01 步进展示与存储语义，出网前统一取整到 2 位小数
/// 不损失有效精度。
library;

/// `ApiPreset.providerOptions` 保留键：`true` 表示该供应商的所有请求都不发送
/// 采样参数（temperature / top_p，OpenAI 兼容协议同时包含两个 penalty）。
///
/// 只认严格 `bool true`；字符串 `'true'` 或数字 `1` 不生效，避免 JSON 手误。
/// 值为 `false` 或缺省时不强制省略，模型能力启发式仍然生效。
const String kOmitSamplingParamsOption = 'omit_sampling_params';

/// 将采样参数取整到 2 位小数；null 原样返回，负零归一为 0.0。
double? sanitizeSamplingParam(double? value) {
  if (value == null) return null;
  final rounded = (value * 100).roundToDouble() / 100;
  return rounded == 0 ? 0.0 : rounded;
}

/// 出网前判定是否省略采样参数：供应商显式开关优先，其次 moonshot 官方
/// 端点家族（该端点全系模型采样参数固定值禁传），最后按模型能力名单。
bool shouldOmitSamplingParams({
  required String modelId,
  Map<String, dynamic>? providerOptions,
  String? baseUrl,
}) {
  if (providerOptions?[kOmitSamplingParamsOption] == true) return true;
  if (_isMoonshotFamilyEndpoint(baseUrl)) return true;
  return isSamplingUnsupportedModel(modelId);
}

/// 辅助调用（压缩/标题/记忆整合/事实合并/世界设定等内部 LLM 任务）的
/// 统一温度解析：配置值来自全局 common.auxiliary.temperature（默认 0.3），
/// 禁发判定命中（供应商开关/moonshot 端点/模型名单）时返回 null 不发参。
double? resolveAuxiliaryTemperature({
  required String modelId,
  required double configuredTemperature,
  Map<String, dynamic>? providerOptions,
  String? baseUrl,
}) {
  if (shouldOmitSamplingParams(
    modelId: modelId,
    providerOptions: providerOptions,
    baseUrl: baseUrl,
  )) {
    return null;
  }
  return configuredTemperature;
}

/// moonshot 官方端点家族（与 thinking_param_builder 的家族口径同源）。
/// 官方参数表对全系模型标注采样参数 Fixed：传任何非固定值返回错误，
/// 故端点级整体停发；中转站上的 K 系模型由名单兜底。
bool _isMoonshotFamilyEndpoint(String? baseUrl) {
  if (baseUrl == null) return false;
  final url = baseUrl.toLowerCase();
  return url.contains('moonshot.cn') || url.contains('moonshot.ai');
}

/// [实验性 / 前瞻适配] 判断模型是否不支持或已废弃采样参数（temperature / top_p / top_k）。
///
/// **维护说明**：大模型架构与 API 规范更新迭代频繁（尤其是混合推理与思考模型），
/// 本方法作为请求出网前的保护性兜底映射：
/// 1. OpenAI o-series（o1 / o3 / o4 等）：API 明文禁止 temperature / top_p，违者 400；
/// 2. OpenAI GPT-5 / GPT-6 系推理模型：官方迁移指南要求 reasoning effort 非 none
///    时移除 temperature / top_p（违者请求报错）；effort 为 none 时虽受支持，
///    但按模型级保守省略（与 Claude 5 系同口径，采样对这些模型无实际效果）；
/// 3. Claude 新一代混合推理及旗舰模型（Claude Sonnet 5 / 5.5 / Opus 4.7+ / Opus 5 / Haiku 5 系列）：
///    官方与中转站已废弃自定义采样参数，显式发送 temperature / top_p 会导致 400 校验拒绝；
/// 4. 含 `reasoner` 标记的纯推理模型（如 deepseek-reasoner）；
/// 5. Kimi K 系（kimi-k2 / kimi-k3 全系）：官方参数表将 temperature /
///    top_p / 双 penalty 标注为 Fixed 值，传任何其他值返回错误。
///    `moonshot-v1` 系（含 thinking 版）是标准对话模型，采样正常，
///    名单 token 用 compact 后的 `kimik2` / `kimik3` 避免误伤。
///
/// 模型名先做归一化（小写并抹平 `-` `_` `.` 空格 `/` 等分隔符），再匹配模型族
/// token，因此 `claude-sonnet-5.5`、`Claude Sonnet 5.5`、`sonnet5.5`
/// 与 `anthropic/claude-sonnet-5.5` 等价命中；`claude-sonnet-4-5`、
/// `claude-3-5-sonnet-*` 等旧版本不会误伤。
///
/// 若上游服务参数策略放宽或调整，可在此调整 `unsupportedTokens`。
/// OpenAI o 系（o1 / o3 / o4）单源判定：小写归一 + 裸前缀与路径前缀双口径。
///
/// 消费点（采样省略名单、max_completion_tokens/max_tokens 分流）统一走本
/// 判定，避免各适配器自持大小写敏感的本地副本产生口径漂移
/// （`OpenAI/`、`openai/o1-mini` 等变体曾因此走错 token 字段）。
bool isOpenAIOSeriesModel(String modelId) {
  final id = modelId.toLowerCase();
  return id.startsWith('o1') ||
      id.startsWith('o3') ||
      id.startsWith('o4') ||
      id.contains('/o1') ||
      id.contains('/o3') ||
      id.contains('/o4');
}

bool isSamplingUnsupportedModel(String modelId) {
  if (isOpenAIOSeriesModel(modelId)) return true;

  final compact = _compactModelId(modelId.toLowerCase());
  const unsupportedTokens = [
    // GPT-5 / GPT-6 全系（含 5.4/5.5/5.6/6-astra/6.1-sol 等子型号——
    // compact 后均含 gpt5 / gpt6 前缀）；gpt-4o 等旧模型不受影响
    'gpt5',
    'gpt6',
    'sonnet5',
    'opus5',
    'haiku5',
    'claude5',
    'opus47',
    'reasoner',
    // Kimi K 系：kimi-k2.6 → kimik26、kimi-k3.1-pro → kimik31pro 等
    // compact 后均含 kimik2 / kimik3；moonshot-v1-8k → moonshotv18k 不含
    'kimik2',
    'kimik3',
  ];
  return unsupportedTokens.any(compact.contains);
}

/// 抹平大小写与分隔符，兼容 `claude-sonnet-5.5` / `claude_sonnet_5_5` /
/// `anthropic/claude-sonnet-5.5` / Bedrock `us.anthropic....` 等写法。
String _compactModelId(String id) => id.replaceAll(RegExp('[^a-z0-9]'), '');
