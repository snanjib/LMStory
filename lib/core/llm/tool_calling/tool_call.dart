import 'dart:convert';

/// 工具调用值对象（Core 层，工具调用模块）
///
/// 表示 LLM 发起的一次工具调用，由 SSE 层的 ToolCallAccumulator
/// 累积完成后产出。包含工具名与已解析的参数 Map。
///
/// 纯 Dart 值对象，不依赖 Flutter / Domain 业务实体。
class ToolCall {
  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
    this.thoughtSignature,
  });

  /// 从 LLM 返回的原始 arguments JSON 字符串构造 [ToolCall]
  ///
  /// 解析失败时 [arguments] 为空 Map（容错，由调用方决定是否重试）。
  factory ToolCall.fromRawArgs({
    required String id,
    required String name,
    required String rawArguments,
    String? thoughtSignature,
  }) {
    var parsed = <String, dynamic>{};
    if (rawArguments.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawArguments);
        if (decoded is Map<String, dynamic>) {
          parsed = decoded;
        }
      } on FormatException {
        // 容错：参数 JSON 非法时返回空 Map，调用方可触发重试
      }
    }
    return ToolCall(
      id: id,
      name: name,
      arguments: parsed,
      thoughtSignature: thoughtSignature,
    );
  }

  /// 工具调用 ID（LLM 返回的 tool_call_id，用于多工具并发区分）
  final String id;

  /// 被调用的工具名（对应 `ToolDefinition.name`）
  final String name;

  /// 已解析的参数（从 LLM 返回的 JSON 字符串解析为 Map）
  final Map<String, dynamic> arguments;

  /// Gemini 3 的思考签名（part 级 `thoughtSignature`，base64）
  ///
  /// Gemini 原生协议无 tool call id，但 functionCall part 可能携带
  /// thoughtSignature；多轮工具调用中必须原样随 tool-call part 回传，
  /// 否则多轮质量下降（设计报告 §4.3）。其他协议恒为 null。
  final String? thoughtSignature;
}

/// 工具调用状态（流式累积过程）
enum ToolCallStatus {
  /// 参数仍在累积中
  incomplete,

  /// 累积完成，可解析
  complete,
}
