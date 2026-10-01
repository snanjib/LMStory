// 上下文超限错误识别（提取为共享口径）
//
// 权威口径说明：各家供应商的超限响应
// 均为 400 + 错误文案，HTTP 状态码层面判不出；wire 层未实现
// CONTEXT_WINDOW_EXCEEDED 语义码。识别统一走本文件的 body 模式匹配
// （导演网关与故事失败分类器共用，勿在任一侧另造状态码或第二套模式）。

/// 上下文超限文案识别模式（OpenAI/DeepSeek/Anthropic/Gemini/中转站中文变体）
final List<Pattern> contextOverflowPatterns = [
  // OpenAI 官方错误码
  'context_length_exceeded',
  // OpenAI / DeepSeek："This model's maximum context length is 128000
  // tokens. However, you requested ... tokens"
  'maximum context length',
  // OpenAI 新版："...exceeding the model's context window of Y..."
  "model's context window",
  'context window is too long',
  // Anthropic："prompt is too long: 205845 tokens > 200000 maximum"
  'prompt is too long',
  // Gemini："The input token count (X) exceeds the maximum number of
  // tokens allowed (Y)"
  'exceeds the maximum number of tokens',
  'input token count',
  // 中转站常见中文变体
  '上下文长度',
  '超过上下文',
  '超出上下文',
  '上下文上限',
];

/// 是否为上下文超限错误（[message] 错误文案，[code] 错误码可空）
bool isContextOverflowText(String message, String? code) {
  if (code != null && code.toLowerCase().contains('context_length_exceeded')) {
    return true;
  }
  final lower = message.toLowerCase();
  return contextOverflowPatterns.any((p) => lower.contains(p.toString()));
}
