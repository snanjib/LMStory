/// 有序内容块（assistant 响应块的原始顺序载体）。
///
/// Anthropic 要求带工具时把 `thinking` / `redacted_thinking` 原样回传，
/// 不能重排、编辑或过滤。原先 text / thinkingBlocks / toolCalls 三份平行
/// 列表无法表达块间顺序，本类型作为唯一权威顺序载体，平行字段继续保留
/// 供 UI 与旧日志使用。
library;

sealed class LlmContentBlock {
  const LlmContentBlock();

  /// Anthropic Messages API 的 content block JSON。
  Map<String, dynamic> toAnthropicJson();

  /// durable 事件 / 调试日志用的 JSON（当前与 Anthropic 形态一致）。
  Map<String, dynamic> toJson() => toAnthropicJson();

  /// 解析持久化 JSON；未知类型返回 null（向前兼容）。
  static LlmContentBlock? fromJson(Map<String, dynamic> json) {
    return switch (json['type']) {
      'text' => LlmTextContentBlock(text: json['text'] as String? ?? ''),
      'thinking' => LlmThinkingContentBlock(
          thinking: json['thinking'] as String? ?? '',
          signature: json['signature'] as String? ?? '',
        ),
      'redacted_thinking' =>
        LlmRedactedThinkingContentBlock(data: json['data'] as String? ?? ''),
      'tool_use' => LlmToolUseContentBlock(
          toolCallId: json['id'] as String? ?? '',
          name: json['name'] as String? ?? '',
          arguments: json['input'] is Map<String, dynamic>
              ? json['input'] as Map<String, dynamic>
              : <String, dynamic>{},
        ),
      _ => null,
    };
  }

  /// 解析 Anthropic 原始 content block；与 [fromJson] 同形，保留独立入口
  /// 便于将来持久化格式与 wire 格式分叉。
  static LlmContentBlock? fromAnthropicJson(Map<String, dynamic> json) =>
      fromJson(json);
}

class LlmTextContentBlock extends LlmContentBlock {
  const LlmTextContentBlock({required this.text});

  final String text;

  @override
  Map<String, dynamic> toAnthropicJson() => {'type': 'text', 'text': text};
}

class LlmThinkingContentBlock extends LlmContentBlock {
  const LlmThinkingContentBlock({
    required this.thinking,
    required this.signature,
  });

  final String thinking;

  /// 空签名不可回传（Anthropic 会 400）；调用方应跳过空签名块。
  final String signature;

  @override
  Map<String, dynamic> toAnthropicJson() => {
        'type': 'thinking',
        'thinking': thinking,
        'signature': signature,
      };
}

class LlmRedactedThinkingContentBlock extends LlmContentBlock {
  const LlmRedactedThinkingContentBlock({required this.data});

  /// 服务端加密的不透明数据，必须原样回传。
  final String data;

  @override
  Map<String, dynamic> toAnthropicJson() => {
        'type': 'redacted_thinking',
        'data': data,
      };
}

class LlmToolUseContentBlock extends LlmContentBlock {
  const LlmToolUseContentBlock({
    required this.toolCallId,
    required this.name,
    required this.arguments,
  });

  final String toolCallId;
  final String name;
  final Map<String, dynamic> arguments;

  @override
  Map<String, dynamic> toAnthropicJson() => {
        'type': 'tool_use',
        'id': toolCallId,
        'name': name,
        'input': arguments,
      };
}
