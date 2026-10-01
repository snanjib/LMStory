import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 协议类型的本地化显示名（UI 层共享工具）
///
/// LlmProtocol enum 本身的 displayName 是硬编码中文 fallback（domain 层
/// 不能依赖 i18n）。UI 层统一通过此函数获取本地化文本。
///
/// 实现依据：DOC-12 §9。
String protocolDisplayName(LlmProtocol protocol, Translations t) {
  return switch (protocol) {
    LlmProtocol.openaiCompatible =>
      t.settings.provider.protocolOptions.openaiCompatible,
    LlmProtocol.openaiResponses =>
      t.settings.provider.protocolOptions.openaiResponses,
    LlmProtocol.anthropic => t.settings.provider.protocolOptions.anthropic,
    LlmProtocol.geminiNative =>
      t.settings.provider.protocolOptions.geminiNative,
  };
}
