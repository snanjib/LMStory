import 'package:lmstory/core/network/llm_adapters/llm_adapter_factory.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';

/// Gemini 预览用的占位模型 ID（Gemini 把 modelId 拼进路径，
/// 预览无处取真实模型名，展示 `{model}` 让用户识别可替换段）。
const String _previewPlaceholderModel = '{model}';

/// 按协议解析供应商详情页 baseUrl 预览 URL（CF-3）。
///
/// 预览必须与真实出网同源：经 [LlmAdapterFactory] 分发到对应协议适配器的
/// `buildUrl`（openai/deepseek → `/chat/completions`、anthropic → `/messages`、
/// gemini → `/v1beta/models/{model}:generateContent`），不另造一套路径拼接。
///
/// [LlmProtocol.openaiResponses] 适配器尚未实现（工厂抛 UnimplementedError，
/// 创建入口已排除该协议），预览回退 OpenAI 兼容路径，保证旧数据不崩。
String buildProviderEndpointPreview({
  required LlmProtocol protocol,
  required String baseUrl,
}) {
  final effectiveProtocol = protocol == LlmProtocol.openaiResponses
      ? LlmProtocol.openaiCompatible
      : protocol;
  final adapter = LlmAdapterFactory().getAdapter(
    protocol: effectiveProtocol,
    baseUrl: baseUrl,
    modelId: _previewPlaceholderModel,
  );
  return adapter.buildUrl(baseUrl, _previewPlaceholderModel, stream: false);
}
