import 'dart:convert';

import 'package:lmstory/core/llm/llm_content_block.dart';
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
    this.openaiResponses = false,
  });

  /// 按协议名构造（'anthropic' / 'geminiNative' / 'openaiResponses' /
  /// 其余按 openaiCompatible）
  factory AgentWireOptions.forProtocolName(String protocol) {
    return AgentWireOptions(
      anthropicExtras: protocol == 'anthropic',
      openaiReasoningContent:
          protocol != 'anthropic' && protocol != 'geminiNative',
      geminiThoughtSignatures: protocol == 'geminiNative',
      openaiResponses: protocol == 'openaiResponses',
    );
  }

  /// Anthropic：`thinkingBlocks`（含 signature）+ `reasoningContent`（camelCase）
  final bool anthropicExtras;

  /// OpenAI 兼容 / DeepSeek：`reasoning_content`（snake_case）
  final bool openaiReasoningContent;

  /// Gemini：tool_calls 元素内携带 `thought_signature`；thought 块以
  /// `thinkingBlocks`（thinking + signature）回传（thoughtSignature 在
  /// Part 层级，官方要求多轮原样回传全部 thought 块）
  final bool geminiThoughtSignatures;

  /// Responses 协议：请求 map 形态与 OpenAI 兼容一致（`reasoning_content`
  /// 仍注入，适配器忽略该键），但适配器最终 input **不回放** reasoning
  /// （reasoning item 携带服务端加密内容，无法从明文重建）——预算估算
  /// 侧据此剔除该键，使估算体与最终请求体同源。
  final bool openaiResponses;
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
    this.contentBlocks,
    this.isToolError = false,
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
    List<LlmContentBlock>? contentBlocks,
  }) =>
      AgentMessage._(
        role: 'assistant',
        content: text,
        toolCalls: toolCalls,
        reasoningContent: reasoningContent,
        thinkingBlocks: thinkingBlocks,
        contentBlocks: contentBlocks,
      );

  /// 工具结果消息（role=tool，OpenAI 风格；各协议适配器负责转换）
  factory AgentMessage.toolResult({
    required String toolCallId,
    required String content,
    bool isError = false,
  }) =>
      AgentMessage._(
        role: 'tool',
        toolCallId: toolCallId,
        content: content,
        isToolError: isError,
      );

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

  /// 原始 block 顺序（Anthropic 专用；含 redacted_thinking）。
  final List<LlmContentBlock>? contentBlocks;

  /// 工具结果是否为错误（协议层分别映射为原生 error 标记或文本前缀）
  final bool isToolError;

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
          // HAR-02：assistant 恒发 content 键（空正文为 ''）——整体省略键
          // 会让 Anthropic/Gemini 适配器收不到正文线索而产出空 content
          // 数组/空 parts（消息形状被吞）。空串由各适配器转占位 block。
          'content': content ?? '',
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
          if ((options.anthropicExtras || options.geminiThoughtSignatures) &&
              thinkingBlocks != null &&
              thinkingBlocks!.isNotEmpty)
            'thinkingBlocks': thinkingBlocks!
                .map(
                  (b) => {'thinking': b.thinking, 'signature': b.signature},
                )
                .toList(),
          if (options.anthropicExtras &&
              contentBlocks != null &&
              contentBlocks!.isNotEmpty)
            'anthropicBlocks':
                contentBlocks!.map((b) => b.toAnthropicJson()).toList(),
        };
      case 'tool':
        if (!isToolError) {
          return {
            'role': 'tool',
            'tool_call_id': toolCallId ?? '',
            'content': content ?? '',
          };
        }
        if (options.anthropicExtras || options.geminiThoughtSignatures) {
          return {
            'role': 'tool',
            'tool_call_id': toolCallId ?? '',
            'content': content ?? '',
            'is_error': true,
          };
        }
        return {
          'role': 'tool',
          'tool_call_id': toolCallId ?? '',
          'content': '[TOOL_ERROR] ${content ?? ''}',
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
