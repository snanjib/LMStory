import 'dart:convert';

import 'package:lmstory/core/llm/llm_usage.dart' show LlmThinkingBlock;

/// 一次工具调用（Agent surface 消息内的值对象）
///
/// 在 `ToolCall`（Core 协议层）基础上保留 Gemini thoughtSignature，
/// 并随 assistant 消息持久化（事件日志），供恢复时原样重放。
class AgentToolCall {
  const AgentToolCall({
    required this.id,
    required this.name,
    required this.arguments,
    this.thoughtSignature,
  });

  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  /// Gemini 3 思考签名（多轮回传必需，其他协议 null）
  final String? thoughtSignature;

  AgentToolCall copyWith({Map<String, dynamic>? arguments}) {
    return AgentToolCall(
      id: id,
      name: name,
      arguments: arguments ?? this.arguments,
      thoughtSignature: thoughtSignature,
    );
  }
}

/// wire 格式序列化选项（按协议注入原始协议字段）
///
/// 设计报告 §7.3：每条 surface 消息保留原始协议字段，恢复时原样重放。
/// 协议特有 key 只发给对应协议，避免污染其他协议的请求体
/// （OpenAI 兼容端点会把 messages 原样上传）。
class AgentWireOptions {
  const AgentWireOptions({
    this.anthropicExtras = false,
    this.openaiReasoningContent = false,
    this.geminiThoughtSignatures = false,
  });

  /// 按协议名构造（'anthropic' / 'gemini' / 其余按 openaiCompatible）
  factory AgentWireOptions.forProtocolName(String protocol) {
    return AgentWireOptions(
      anthropicExtras: protocol == 'anthropic',
      openaiReasoningContent:
          protocol != 'anthropic' && protocol != 'geminiNative',
      geminiThoughtSignatures: protocol == 'geminiNative',
    );
  }

  /// Anthropic：`thinkingBlocks`（含 signature）+ `reasoningContent`（camelCase）
  final bool anthropicExtras;

  /// OpenAI 兼容 / DeepSeek：`reasoning_content`（snake_case）
  final bool openaiReasoningContent;

  /// Gemini：tool_calls 元素内携带 `thought_signature`
  final bool geminiThoughtSignatures;
}

/// Agent surface 消息（模型可见消息的领域表示）
///
///  为内存表示； 事件日志落地后，本类由 surface 投影（deriveMessages）
/// 派生，"进模型的必已入日志"（设计报告 §7.3）。
class AgentMessage {
  const AgentMessage._({
    required this.role,
    this.content,
    this.toolCallId,
    this.toolCalls,
    this.reasoningContent,
    this.thinkingBlocks,
  });

  factory AgentMessage.system(String content) =>
      AgentMessage._(role: 'system', content: content);

  factory AgentMessage.user(String content) =>
      AgentMessage._(role: 'user', content: content);

  factory AgentMessage.assistant({
    String? text,
    List<AgentToolCall>? toolCalls,
    String? reasoningContent,
    List<LlmThinkingBlock>? thinkingBlocks,
  }) =>
      AgentMessage._(
        role: 'assistant',
        content: text,
        toolCalls: toolCalls,
        reasoningContent: reasoningContent,
        thinkingBlocks: thinkingBlocks,
      );

  /// 工具结果消息（role=tool，OpenAI 风格；各协议适配器负责转换）
  factory AgentMessage.toolResult({
    required String toolCallId,
    required String content,
  }) =>
      AgentMessage._(role: 'tool', toolCallId: toolCallId, content: content);

  /// system / user / assistant / tool（OpenAI 规范 role）
  final String role;

  /// 文本内容（assistant 可能与 toolCalls 并存；tool 结果为输出文本）
  final String? content;

  /// tool 消息关联的调用 id（对应 [AgentToolCall.id]）
  final String? toolCallId;

  /// assistant 消息携带的工具调用（可为多个）
  final List<AgentToolCall>? toolCalls;

  /// DeepSeek / OpenAI 兼容思维链（多轮回传）
  final String? reasoningContent;

  /// Anthropic 结构化思考块（含 signature，多轮回传）
  final List<LlmThinkingBlock>? thinkingBlocks;

  bool get hasToolCalls => toolCalls != null && toolCalls!.isNotEmpty;

  /// 序列化为协议 wire 格式（OpenAI 规范为基准，各适配器再转换）
  ///
  /// [options] 决定协议特有字段的注入（见 [AgentWireOptions]）。
  Map<String, dynamic> toRequestMap([
    AgentWireOptions options = const AgentWireOptions(),
  ]) {
    switch (role) {
      case 'assistant':
        return {
          'role': 'assistant',
          if (content != null && content!.isNotEmpty) 'content': content,
          if (hasToolCalls)
            'tool_calls': toolCalls!
                .map(
                  (tc) => {
                    'id': tc.id,
                    'type': 'function',
                    'function': {
                      'name': tc.name,
                      'arguments': jsonEncode(tc.arguments),
                    },
                    if (options.geminiThoughtSignatures &&
                        tc.thoughtSignature != null)
                      'thought_signature': tc.thoughtSignature,
                  },
                )
                .toList(),
          if (options.openaiReasoningContent &&
              reasoningContent != null &&
              reasoningContent!.isNotEmpty)
            'reasoning_content': reasoningContent,
          if (options.anthropicExtras && reasoningContent != null)
            'reasoningContent': reasoningContent,
          if (options.anthropicExtras &&
              thinkingBlocks != null &&
              thinkingBlocks!.isNotEmpty)
            'thinkingBlocks': thinkingBlocks!
                .map(
                  (b) => {'thinking': b.thinking, 'signature': b.signature},
                )
                .toList(),
        };
      case 'tool':
        return {
          'role': 'tool',
          'tool_call_id': toolCallId ?? '',
          'content': content ?? '',
        };
      default:
        return {
          'role': role,
          if (content != null) 'content': content,
        };
    }
  }

  /// 人类可读预览（事件/日志用）
  String preview([int max = 80]) {
    final src = content ?? (hasToolCalls ? '[${toolCalls!.length} 个工具调用]' : '');
    if (src.length <= max) return src;
    return '${src.substring(0, max)}…';
  }
}
