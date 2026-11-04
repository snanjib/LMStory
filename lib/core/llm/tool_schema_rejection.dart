// 工具 schema 被供应商拒绝的报文特征（故事模式结构化步骤共享口径）。
//
// 供应商对 function/tool schema 有各自的字段白名单：Gemini 只接受
// Schema proto 子集（`additionalProperties` 直接 400 INVALID_ARGUMENT），
// OpenAI strict 模式也会拒收不合规的 function schema。二者都表现为
// HTTP 400 + 报文点名 schema 字段，与网络中断无关——识别后应直接降级
// JSON 模式，而不是按流中断重试同一份必失败的载荷。
//
// 与 context_overflow.dart / model_unavailability.dart 同属文本匹配口径，
// 勿在调用侧另造第二套模式。

/// 报文是否在描述「工具 schema 不被接受」。
bool isToolSchemaRejectionText(String text) {
  final lower = text.toLowerCase();
  return lower.contains('additionalproperties') ||
      lower.contains('function_declarations') ||
      lower.contains('functiondeclarations') ||
      lower.contains('invalid schema for function');
}
