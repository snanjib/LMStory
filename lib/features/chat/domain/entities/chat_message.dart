import 'dart:convert';

import 'package:lmstory/features/chat/domain/entities/message_attachment.dart';

/// 工具调用数据
///
/// 表示一次 LLM 工具调用的完整信息，包括调用 ID、函数名、参数和结果。
class ToolCallData {
  const ToolCallData({
    required this.id,
    required this.name,
    required this.arguments,
    this.result,
  });

  /// 从 JSON Map 创建
  factory ToolCallData.fromJson(Map<String, dynamic> json) {
    return ToolCallData(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      arguments: json['arguments'] as String? ?? '{}',
      result: json['result'] as String?,
    );
  }

  /// 工具调用 ID
  final String id;

  /// 函数名称
  final String name;

  /// 函数参数（JSON 字符串）
  final String arguments;

  /// 工具响应结果（可选）
  final String? result;

  /// 转换为 JSON Map
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'arguments': arguments,
      if (result != null) 'result': result,
    };
  }

  ToolCallData copyWith({
    String? id,
    String? name,
    String? arguments,
    String? result,
  }) {
    return ToolCallData(
      id: id ?? this.id,
      name: name ?? this.name,
      arguments: arguments ?? this.arguments,
      result: result ?? this.result,
    );
  }
}

/// 聊天消息实体
///
/// 表示一条聊天消息，支持分支（Fork）和压缩摘要。
class ChatMessage {
  const ChatMessage({
    required this.messageId,
    required this.sessionId,
    required this.role,
    required this.createdAt,
    this.content,
    this.toolCalls,
    this.toolCallId,
    this.thinkingContent,
    this.thinkingDuration,
    this.reasoningContent,
    this.parentUserMsgId,
    this.branchIndex = 0,
    this.isSummary = false,
    this.isContinued = false,
    this.attachments,
    this.error,
    this.tokensUsed,
    this.firstTokenLatency,
    this.modelName,
  });

  /// 从 JSON Map 创建（用于分支快照反序列化）
  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      messageId: json['messageId'] as String,
      sessionId: json['sessionId'] as String,
      role: json['role'] as String,
      content: json['content'] as String?,
      toolCalls: json['toolCalls'] as String?,
      toolCallId: json['toolCallId'] as String?,
      thinkingContent: json['thinkingContent'] as String?,
      thinkingDuration: json['thinkingDuration'] as int?,
      reasoningContent: json['reasoningContent'] as String?,
      parentUserMsgId: json['parentUserMsgId'] as String?,
      branchIndex: json['branchIndex'] as int? ?? 0,
      isSummary: json['isSummary'] as bool? ?? false,
      isContinued: json['isContinued'] as bool? ?? false,
      attachments: json['attachments'] != null
          ? MessageAttachment.listFromJson(json['attachments'] as String)
          : null,
      error: json['error'] as String?,
      tokensUsed: json['tokensUsed'] as int?,
      firstTokenLatency: json['firstTokenLatency'] as int?,
      modelName: json['modelName'] as String?,
      createdAt: DateTime.parse(json['createdAt'] as String),
    );
  }

  /// 摘要消息缺失时的占位哨兵。
  ///
  /// 压缩点存在而摘要消息行缺失（外部删除/修复路径遗留）时，
  /// getCompressedMessages 构造带本哨兵的占位消息。哨兵是稳定协议值——
  /// 会进 API 上下文（对模型诚实表明摘要缺失），UI 渲染层
  /// （chat 摘要卡 / 故事摘要隔断卡）应识别并映射为本地化文案。
  static const String summaryUnavailableContent = '[summary-unavailable]';

  /// 消息唯一标识
  final String messageId;

  /// 所属会话 ID
  final String sessionId;

  /// 角色：user / assistant / system / tool
  final String role;

  /// 消息内容
  final String? content;

  /// 工具调用 JSON 字符串
  final String? toolCalls;

  /// 工具调用 ID（用于配对响应）
  final String? toolCallId;

  /// 思考/推理内容（DeepSeek-R1 的 <think> 标签、Claude 的 thinking block、
  /// OpenAI o1/o3 的 reasoning_content）
  final String? thinkingContent;

  /// 思考耗时（秒）
  final int? thinkingDuration;

  /// DeepSeek V4 原始 reasoning_content 字段（DOC-12 §5.4.2）
  ///
  /// 与 [thinkingContent] 的差异：
  /// - [thinkingContent]：从 `<think>` 标签提取的内容（用于 UI 显示）
  /// - reasoningContent：DeepSeek V4 API 响应的 `reasoning_content` 字段原文
  ///
  /// 用途：tool call 场景下，必须将此字段原样回传给 API，否则 400 错误。
  /// 非 tool call 场景可为 null（不影响兼容性）。
  final String? reasoningContent;

  /// 父用户消息 ID（用于分支追踪）
  final String? parentUserMsgId;

  /// 分支索引
  final int branchIndex;

  /// 是否为压缩摘要消息
  final bool isSummary;

  /// 「已中断·续写」标记：被续写合并过的消息（停止后
  /// 「继续生成」的新内容追加了进来，单气泡+徽标）
  final bool isContinued;

  /// 消息附件列表（图片、文件等）
  final List<MessageAttachment>? attachments;

  /// 错误信息（API 调用失败时持久化到消息中，切换分支时保留）
  final String? error;

  /// Tokens 使用量（来自 API 响应 usage.total_tokens）
  /// 仅助手消息有值，用于在消息下方显示 tokens 信息
  final int? tokensUsed;

  /// 首字延迟（毫秒）— 从请求发送到收到首个文本 token 的耗时
  /// 仅助手消息有值，用于在消息下方显示首字延迟
  final int? firstTokenLatency;

  /// 模型名称（生成此消息时使用的模型显示名）
  /// 仅助手消息有值，用于在消息下方显示模型名
  final String? modelName;

  /// 创建时间
  final DateTime createdAt;

  /// 解析 toolCalls JSON 字符串为 ToolCallData 列表
  List<ToolCallData> get parsedToolCalls {
    if (toolCalls == null || toolCalls!.isEmpty) return const [];
    try {
      final list = const JsonDecoder().convert(toolCalls!) as List<dynamic>;
      return list
          .map((e) => ToolCallData.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// 序列化为 JSON Map（用于分支快照存储）
  Map<String, dynamic> toJson() {
    return {
      'messageId': messageId,
      'sessionId': sessionId,
      'role': role,
      if (content != null) 'content': content,
      if (toolCalls != null) 'toolCalls': toolCalls,
      if (toolCallId != null) 'toolCallId': toolCallId,
      if (thinkingContent != null) 'thinkingContent': thinkingContent,
      if (thinkingDuration != null) 'thinkingDuration': thinkingDuration,
      if (reasoningContent != null) 'reasoningContent': reasoningContent,
      if (parentUserMsgId != null) 'parentUserMsgId': parentUserMsgId,
      'branchIndex': branchIndex,
      'isSummary': isSummary,
      'isContinued': isContinued,
      if (attachments != null && attachments!.isNotEmpty)
        'attachments': MessageAttachment.listToJson(attachments!),
      if (error != null) 'error': error,
      if (tokensUsed != null) 'tokensUsed': tokensUsed,
      if (firstTokenLatency != null) 'firstTokenLatency': firstTokenLatency,
      if (modelName != null) 'modelName': modelName,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  /// 将消息列表序列化为 JSON 字符串（用于分支快照存储）
  static String listToJson(List<ChatMessage> messages) {
    if (messages.isEmpty) return '[]';
    return jsonEncode(messages.map((m) => m.toJson()).toList());
  }

  /// 从 JSON 字符串反序列化消息列表
  static List<ChatMessage> listFromJson(String? jsonStr) {
    if (jsonStr == null || jsonStr.isEmpty) return const [];
    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      return list
          .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Sentinel object to distinguish "not provided" from "explicitly null"
  /// in copyWith for nullable fields.
  static const _sentinel = Object();

  /// 创建副本并应用修改
  ChatMessage copyWith({
    String? messageId,
    String? sessionId,
    String? role,
    Object? content = _sentinel,
    Object? toolCalls = _sentinel,
    String? toolCallId,
    Object? thinkingContent = _sentinel,
    int? thinkingDuration,
    Object? reasoningContent = _sentinel,
    String? parentUserMsgId,
    int? branchIndex,
    bool? isSummary,
    bool? isContinued,
    DateTime? createdAt,
    List<MessageAttachment>? attachments,
    Object? error = _sentinel,
    int? tokensUsed,
    int? firstTokenLatency,
    String? modelName,
  }) {
    return ChatMessage(
      messageId: messageId ?? this.messageId,
      sessionId: sessionId ?? this.sessionId,
      role: role ?? this.role,
      content:
          identical(content, _sentinel) ? this.content : content as String?,
      toolCalls: identical(toolCalls, _sentinel)
          ? this.toolCalls
          : toolCalls as String?,
      toolCallId: toolCallId ?? this.toolCallId,
      thinkingContent: identical(thinkingContent, _sentinel)
          ? this.thinkingContent
          : thinkingContent as String?,
      thinkingDuration: thinkingDuration ?? this.thinkingDuration,
      reasoningContent: identical(reasoningContent, _sentinel)
          ? this.reasoningContent
          : reasoningContent as String?,
      parentUserMsgId: parentUserMsgId ?? this.parentUserMsgId,
      branchIndex: branchIndex ?? this.branchIndex,
      isSummary: isSummary ?? this.isSummary,
      isContinued: isContinued ?? this.isContinued,
      createdAt: createdAt ?? this.createdAt,
      attachments: attachments ?? this.attachments,
      error: identical(error, _sentinel) ? this.error : error as String?,
      tokensUsed: tokensUsed ?? this.tokensUsed,
      firstTokenLatency: firstTokenLatency ?? this.firstTokenLatency,
      modelName: modelName ?? this.modelName,
    );
  }
}

// ignore: avoid_classes_with_only_static_members
/// ChatMessage 工具方法
class ChatMessageUtils {
  /// 将 ToolCallData 列表编码为 JSON 字符串（用于存储到数据库）
  static String? encodeToolCalls(List<ToolCallData> calls) {
    if (calls.isEmpty) return null;
    final list = calls.map((c) => c.toJson()).toList();
    return const JsonEncoder().convert(list);
  }

  /// DeepSeek-R1 思考标签开始标记
  static const thinkStartTag = '<think>';

  /// DeepSeek-R1 思考标签结束标记
  static const thinkEndTag = '</think>';

  /// 从文本中解析 <think>...</think> 标签，分离思考内容和正文
  ///
  /// 返回 (thinkingContent, displayContent)：
  /// - thinkingContent: <think> 标签内的内容（不含标签本身）
  /// - displayContent: 移除 <think> 标签后的正文
  ///
  /// 如果 <think> 标签未闭合，thinkingContent 包含已接收的思考内容，
  /// displayContent 为空字符串（表示仍在思考中）。
  static (String?, String) parseThinkingTags(String text) {
    final startIdx = text.indexOf(thinkStartTag);
    if (startIdx == -1) return (null, text);

    final afterStart = startIdx + thinkStartTag.length;
    final endIdx = text.indexOf(thinkEndTag, afterStart);

    if (endIdx == -1) {
      // <think> 未闭合 — 仍在思考中
      final thinking = text.substring(afterStart);
      return (thinking, '');
    }

    final thinking = text.substring(afterStart, endIdx);
    final afterEnd = endIdx + thinkEndTag.length;
    var display = text.substring(0, startIdx) + text.substring(afterEnd);
    display = display.trim();
    return (thinking.isEmpty ? null : thinking, display);
  }
}
