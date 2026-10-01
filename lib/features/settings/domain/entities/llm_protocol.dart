import 'package:lmstory/core/network/llm_adapters/llm_protocol_adapter.dart'
    show LlmProtocolAdapter;
import 'package:lmstory/features/settings/domain/entities/api_preset.dart'
    show ApiPreset;

/// LLM 协议类型枚举
///
/// 决定 [LlmProtocolAdapter] 的分发目标。每个 [ApiPreset] 持有一个协议类型，
/// 运行时按此字段选择对应的适配器构造请求 URL/Header/Body 并解析响应/SSE。
///
/// 详见 DOC-12 §3.1。
enum LlmProtocol {
  /// OpenAI Chat Completions 兼容协议（`{baseUrl}/chat/completions`）
  ///
  /// 适用：OpenAI、DeepSeek、OpenRouter、各类第三方兼容供应商
  openaiCompatible,

  /// OpenAI Responses API（`/v1/responses`，新协议）
  ///
  /// 适用：OpenAI 官方 Responses API（v0.3+ 适配，本期不实现）
  openaiResponses,

  /// Anthropic Messages API（`{baseUrl}/messages`，原生协议）
  ///
  /// 适用：Anthropic Claude 系列
  anthropic,

  /// Google Gemini generateContent（`/v1beta/models/{model}:generateContent`）
  ///
  /// 适用：Google Gemini 系列（AI Studio API Key 方式）
  geminiNative;

  /// 序列化为 JSON 字符串（存入 `api_presets.protocol` 列）
  String toJson() => name;

  /// 从 JSON 字符串反序列化
  ///
  /// 未知值回退到 [openaiCompatible]（兼容旧版本数据 + 用户手填协议场景）
  static LlmProtocol fromJson(String? value) {
    if (value == null) return openaiCompatible;
    return values.firstWhere(
      (e) => e.name == value,
      orElse: () => openaiCompatible,
    );
  }

  /// 中文显示名（用于 UI 展示协议类型）
  String get displayName => switch (this) {
        openaiCompatible => 'OpenAI 兼容',
        openaiResponses => 'OpenAI Responses',
        anthropic => 'Anthropic Claude',
        geminiNative => 'Google Gemini',
      };
}
