import 'dart:convert';

import 'package:lmstory/core/agent/agent_events.dart'
    show kAgentSurfaceReplaceToEnd;
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/llm/llm_content_block.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart'
    show LlmThinkingBlock;

/// surface 操作类型
enum AgentSurfaceOpKind { append, replace }

/// Agent 持久事件（dsh SessionEvent 信封，设计报告 §7.3）
///
/// 一切进模型的内容必须能从事件日志重建（"model-visible means logged"）。
/// surface 事件（[surfaceOp] 非 null）由 [deriveAgentSurface] 投影为
/// 模型可见消息；压缩/裁剪只产生 replace 事件，历史事件永不改写。
class AgentDurableEvent {
  AgentDurableEvent({
    required this.type,
    required this.data,
    this.seq,
    DateTime? time,
    this.surfaceOp,
    this.replaceStart,
    this.replaceEnd,
    this.sourceEventSeqs = const [],
  }) : time = time ?? DateTime.now();

  factory AgentDurableEvent.fromJson(Map<String, dynamic> json) {
    return AgentDurableEvent(
      seq: json['seq'] as int?,
      type: json['type'] as String,
      time: DateTime.fromMillisecondsSinceEpoch(json['time'] as int),
      data: (json['data'] as Map).cast<String, dynamic>(),
      surfaceOp: switch (json['surfaceOp']) {
        'append' => AgentSurfaceOpKind.append,
        'replace' => AgentSurfaceOpKind.replace,
        _ => null,
      },
      replaceStart: json['replaceStart'] as int?,
      replaceEnd: json['replaceEnd'] as int?,
      sourceEventSeqs:
          (json['sourceEventSeqs'] as List<dynamic>? ?? const []).cast<int>(),
    );
  }

  /// 会话内单调序号（落库时由仓库分配）
  final int? seq;

  /// 事件类型（见 AgentEventTypes）
  final String type;

  final DateTime time;

  /// 事件负载（结构因类型而异，见各 data 类）
  final Map<String, dynamic> data;

  /// surface 操作；null = log-only 事件
  final AgentSurfaceOpKind? surfaceOp;

  /// replace 的投影坐标区间 [replaceStart, replaceEnd)；append 为 null
  final int? replaceStart;
  final int? replaceEnd;

  /// 溯源事件 seq（replace → 被替换的事件；assistant/message → 源 step）
  final List<int> sourceEventSeqs;

  Map<String, dynamic> toJson() {
    return {
      if (seq != null) 'seq': seq,
      'type': type,
      'time': time.millisecondsSinceEpoch,
      'data': data,
      if (surfaceOp != null)
        'surfaceOp':
            surfaceOp == AgentSurfaceOpKind.append ? 'append' : 'replace',
      if (replaceStart != null) 'replaceStart': replaceStart,
      if (replaceEnd != null) 'replaceEnd': replaceEnd,
      if (sourceEventSeqs.isNotEmpty) 'sourceEventSeqs': sourceEventSeqs,
    };
  }

  /// data 的 JSON 字符串（落库用）
  String encodeData() => jsonEncode(data);
}

/// 事件类型常量
abstract final class AgentEventTypes {
  /// 用户/系统输入（surface append）
  static const String userMessage = 'user/message';

  /// 模型输出（surface append；含 toolCalls 与协议回传字段）
  static const String assistantMessage = 'assistant/message';

  /// 工具结果（surface append）
  static const String toolResult = 'tool/result';

  /// core memory blocks 系统消息（surface append/replace）
  static const String systemCore = 'system/core';

  /// 冻结 system 前缀（①角色+②工作规范+③工具索引；会话首turn append 一次）
  static const String systemFrozen = 'system/frozen';

  static const String turnBegin = 'turn/begin';
  static const String turnEnd = 'turn/end';
  static const String stepBegin = 'step/begin';
  static const String stepEnd = 'step/end';

  /// 流式正文分片（最小粒度：中断恢复用，log-only 不进投影）。
  /// data: {stepIndex, text}（聚合分片）或 {stepIndex, reset: true}
  ///（重试丢弃半截流，重建时清空此前分片）
  static const String assistantChunk = 'assistant/chunk';

  /// 大纲更新（log-only；当前大纲 = 事件的纯 fold）
  static const String outlineUpdate = 'outline/update';

  /// 通用 surface 替换（prune：旧 tool 结果折叠为占位，原文仍在日志）
  static const String surfaceReplace = 'surface/replace';

  /// skill 目录摘要消息（：append 一次，digest 变更才 replace）

  static const String doomLoop = 'doom/loop';

  /// persist 阶段嵌入向量化降级留痕（：
  /// log-only，不进 surface 投影；data: {turn, error}）
  static const String persistEmbeddingDegraded = 'persist/embedding-degraded';
}

/// data 载荷：user/message
class AgentUserMessageData {
  const AgentUserMessageData({required this.content, this.source = 'user'});

  final String content;

  /// user（真实用户输入）/ harness 注入来源（AgentInjectedMessageKinds）
  final String source;

  Map<String, dynamic> toJson() => {'content': content, 'source': source};
}

/// data 载荷：assistant/message（保留全部协议回传字段）
class AgentAssistantMessageData {
  const AgentAssistantMessageData({
    this.text,
    this.reasoningContent,
    this.toolCalls = const [],
    this.thinkingBlocks = const [],
    this.contentBlocks = const [],
    this.stepIndex = 0,
  });

  final String? text;
  final String? reasoningContent;

  /// [{id, name, args, thoughtSignature?}]
  final List<Map<String, dynamic>> toolCalls;

  /// [{thinking, signature}]
  final List<Map<String, dynamic>> thinkingBlocks;

  /// Anthropic 原始 block 顺序；旧日志无此键时为 null。
  final List<Map<String, dynamic>> contentBlocks;
  final int stepIndex;

  Map<String, dynamic> toJson() {
    return {
      if (text != null && text!.isNotEmpty) 'text': text,
      if (reasoningContent != null && reasoningContent!.isNotEmpty)
        'reasoningContent': reasoningContent,
      if (toolCalls.isNotEmpty) 'toolCalls': toolCalls,
      if (thinkingBlocks.isNotEmpty) 'thinkingBlocks': thinkingBlocks,
      if (contentBlocks.isNotEmpty) 'contentBlocks': contentBlocks,
      'stepIndex': stepIndex,
    };
  }
}

/// data 载荷：tool/result
class AgentToolResultData {
  const AgentToolResultData({
    required this.callId,
    required this.toolName,
    required this.output,
    this.isError = false,
    this.title,
    this.durationMs,
  });

  final String callId;
  final String toolName;
  final String output;
  final bool isError;
  final String? title;

  /// 执行耗时毫秒（：轮轨迹步时间线用；null = 未知/占位补齐）
  final int? durationMs;

  Map<String, dynamic> toJson() {
    return {
      'callId': callId,
      'toolName': toolName,
      'output': output,
      'isError': isError,
      if (title != null) 'title': title,
      if (durationMs != null) 'durationMs': durationMs,
    };
  }
}

/// surface 投影结果
class AgentSurfaceProjection {
  const AgentSurfaceProjection({
    required this.messages,
    required this.coreIndex,
    required this.lastSeq,
  });

  /// 模型可见消息（折叠 surface 事件后的最终形态）
  final List<AgentMessage> messages;

  /// core memory blocks 消息的投影坐标（无则 -1；replace 时用它定位）
  final int coreIndex;

  /// 已折叠到的最大事件 seq（增量折叠的 watermark）
  final int lastSeq;
}

/// 把事件日志投影为模型可见消息（纯函数，设计报告 §7.3 deriveMessages）
///
/// 规则：
/// - `user/message` / `assistant/message` / `tool/result` append → 追加消息
/// - `system/core` append → 追加系统消息并记录坐标；
///   `system/core` replace → 替换坐标 [replaceStart, replaceEnd) 内的消息
/// - log-only 事件跳过
AgentSurfaceProjection deriveAgentSurface(List<AgentDurableEvent> events) {
  var messages = <AgentMessage>[];
  var coreIndex = -1;
  var lastSeq = -1;

  for (final event in events) {
    if (event.seq != null && event.seq! > lastSeq) lastSeq = event.seq!;
    final op = event.surfaceOp;
    if (op == null) continue;

    switch (event.type) {
      case AgentEventTypes.userMessage:
        messages.add(
          AgentMessage.user((event.data['content'] as String?) ?? ''),
        );
      case AgentEventTypes.assistantMessage:
        messages.add(_assistantFromData(event.data));
      case AgentEventTypes.toolResult:
        messages.add(
          AgentMessage.toolResult(
            toolCallId: (event.data['callId'] as String?) ?? '',
            content: (event.data['output'] as String?) ?? '',
          ),
        );
      case AgentEventTypes.systemFrozen:
        // 冻结前缀：append 一次后永不主动 replace（缓存断点 1/2 的载体）。
        // 审查收官  读取侧折叠：应用重启后 runner 内存判据失忆会
        // 重落一条 frozen（append-only 不删旧）——投影按「前缀当前值」
        // 语义只保留最新一条（旧条位于头部 0 位时原位替换）
        final content = (event.data['content'] as String?) ?? '';
        if (messages.isNotEmpty && messages[0].role == 'system') {
          messages = [...messages]..[0] = AgentMessage.system(content);
        } else {
          messages.insert(0, AgentMessage.system(content));
        }
      case AgentEventTypes.systemCore:
        final content = (event.data['content'] as String?) ?? '';
        if (op == AgentSurfaceOpKind.append && coreIndex >= 0) {
          // 审查收官  读取侧折叠：A 案下生产侧每轮 append 一条
          // core（写侧无 replace 生产者）——投影按「世界状态当前值」原位
          // 替换既有 core，不再逐轮累积过期块（真实请求只含一条当前 core）
          messages = [...messages]..[coreIndex] = AgentMessage.system(content);
        } else if (op == AgentSurfaceOpKind.append) {
          messages.add(AgentMessage.system(content));
          coreIndex = messages.length - 1;
        } else {
          final start = event.replaceStart ?? 0;
          final end = event.replaceEnd ?? start;
          final next = <AgentMessage>[...messages];
          if (start >= 0 && end > start && end <= next.length) {
            next.replaceRange(start, end, [AgentMessage.system(content)]);
            messages = next;
            coreIndex = start;
          } else {
            // 区间失效（防御）：退化为追加
            next.add(AgentMessage.system(content));
            messages = next;
            coreIndex = messages.length - 1;
          }
        }
      case AgentEventTypes.surfaceReplace:
        // 通用 surface replace（prune 用）：data.messages 携带替换后的
        // 消息数组（按原角色重建，保持 tool_use/tool_result 配对合法）
        if (op == AgentSurfaceOpKind.replace) {
          final start = event.replaceStart ?? 0;
          final rawEnd = event.replaceEnd ?? start;
          // 整面替换哨兵：投影坐标是全会话累积的，轮内长度不可换算
          final isWholeReplace = rawEnd == kAgentSurfaceReplaceToEnd;
          final end = isWholeReplace ? messages.length : rawEnd;
          final replacements =
              (event.data['messages'] as List<dynamic>? ?? const [])
                  .whereType<Map<String, dynamic>>()
                  .map(_messageFromData)
                  .toList();
          final rangeValid = isWholeReplace
              ? start >= 0 && start <= messages.length
              : start >= 0 && end > start && end <= messages.length;
          if (rangeValid) {
            final next = <AgentMessage>[...messages]
              ..replaceRange(start, end, replacements);
            messages = next;
            // 审查收官  附带：整面替换后旧 core 坐标失效（压缩产物
            // 自带 system 前缀，core 可能移位或消失）——重置，后续 core
            // append 按新追加处理
            if (isWholeReplace) coreIndex = -1;
          }
          // append 或区间失效：忽略（prune 只产出合法 replace）
        }
      default:
        // 未知 surface 事件类型：跳过（向前兼容，不拒绝重建）
        break;
    }
  }

  return AgentSurfaceProjection(
    messages: List.unmodifiable(messages),
    coreIndex: coreIndex,
    lastSeq: lastSeq,
  );
}

/// AgentMessage → surface 事件 data（：surface/replace 替换数组序列化；
/// 与 [_messageFromData] 互逆）
Map<String, dynamic> agentMessageToSurfaceData(AgentMessage message) {
  if (message.toolCallId != null) {
    return {
      'as': 'tool',
      'callId': message.toolCallId,
      'content': message.content ?? '',
    };
  }
  switch (message.role) {
    case 'assistant':
      return {
        'as': 'assistant',
        'text': message.content,
        'reasoningContent': message.reasoningContent,
        'toolCalls': [
          for (final tc in message.toolCalls ?? const <AgentToolCall>[])
            {
              'id': tc.id,
              'name': tc.name,
              'args': tc.arguments,
              if (tc.thoughtSignature != null)
                'thoughtSignature': tc.thoughtSignature,
            },
        ],
        if (message.thinkingBlocks != null &&
            message.thinkingBlocks!.isNotEmpty)
          'thinkingBlocks': [
            for (final b in message.thinkingBlocks!)
              {'thinking': b.thinking, 'signature': b.signature},
          ],
        if (message.contentBlocks != null && message.contentBlocks!.isNotEmpty)
          'contentBlocks': [
            for (final b in message.contentBlocks!) b.toJson(),
          ],
      };
    case 'user':
      return {'as': 'user', 'content': message.content ?? ''};
    default:
      return {'as': 'system', 'content': message.content ?? ''};
  }
}

/// 从事件 data 构建任意角色的消息（surface replace 的替换数组用）
AgentMessage _messageFromData(Map<String, dynamic> data) {
  switch (data['as']) {
    case 'tool':
      return AgentMessage.toolResult(
        toolCallId: (data['callId'] as String?) ?? '',
        content: (data['content'] as String?) ?? '',
      );
    case 'assistant':
      return _assistantFromData(data);
    case 'user':
      return AgentMessage.user((data['content'] as String?) ?? '');
    default:
      return AgentMessage.system((data['content'] as String?) ?? '');
  }
}

AgentMessage _assistantFromData(Map<String, dynamic> data) {
  final toolCalls = (data['toolCalls'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .map(
        (tc) => AgentToolCall(
          id: (tc['id'] as String?) ?? '',
          name: (tc['name'] as String?) ?? '',
          arguments: (tc['args'] as Map?)?.cast<String, dynamic>() ?? const {},
          thoughtSignature: tc['thoughtSignature'] as String?,
        ),
      )
      .toList();
  final thinkingBlocks = (data['thinkingBlocks'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .map(
        (b) => LlmThinkingBlock(
          thinking: (b['thinking'] as String?) ?? '',
          signature: (b['signature'] as String?) ?? '',
        ),
      )
      .toList();
  final contentBlocks = (data['contentBlocks'] as List<dynamic>? ?? const [])
      .whereType<Map<String, dynamic>>()
      .map(LlmContentBlock.fromJson)
      .whereType<LlmContentBlock>()
      .toList();
  return AgentMessage.assistant(
    text: data['text'] as String?,
    toolCalls: toolCalls.isEmpty ? null : toolCalls,
    reasoningContent: data['reasoningContent'] as String?,
    thinkingBlocks: thinkingBlocks.isEmpty ? null : thinkingBlocks,
    contentBlocks: contentBlocks.isEmpty ? null : contentBlocks,
  );
}

/// 单轮内一次工具执行的工作摘要（载入时从事件日志反推，供过程展示）
class AgentToolWork {
  const AgentToolWork({
    required this.toolName,
    required this.title,
    required this.output,
    required this.isError,
  });

  final String toolName;
  final String title;
  final String output;
  final bool isError;
}

/// 单轮的工作过程摘要（从 agent 事件日志按 `turn` 分组反推）
///
/// 解决"重进会话后步骤消失"：事件日志是唯一真相源，步骤可从
/// tool/result、step/end、turn/begin、turn/end 事件重建。
class AgentTurnWork {
  const AgentTurnWork({
    required this.turnNumber,
    required this.steps,
    required this.totalTokens,
    required this.durationMs,
    required this.tools,
    required this.reason,
  });

  final int turnNumber;
  final int steps;
  final int totalTokens;
  final int durationMs;
  final List<AgentToolWork> tools;

  /// 轮停止原因（completed / budget / doom / interrupted 等）
  final String? reason;
}

/// 从事件日志反推每轮工作过程（返回 Map<turnNumber, AgentTurnWork>）
Map<int, AgentTurnWork> deriveAgentWorkLog(List<AgentDurableEvent> events) {
  final byTurn = <int, List<AgentDurableEvent>>{};
  for (final event in events) {
    // 审查收官 ：子代理中继事件不进轮工作摘要（beginMs 被子代理
    // turn/begin 覆盖会少算主轮时长）
    if (event.data['subagent'] == true) continue;
    final turn = event.data['turn'];
    if (turn is int) {
      byTurn.putIfAbsent(turn, () => []).add(event);
    }
  }

  final result = <int, AgentTurnWork>{};
  byTurn.forEach((turn, turnEvents) {
    final tools = <AgentToolWork>[];
    var steps = 0;
    var totalTokens = 0;
    int? beginMs;
    int? endMs;
    String? reason;

    for (final event in turnEvents) {
      switch (event.type) {
        case AgentEventTypes.toolResult:
          tools.add(
            AgentToolWork(
              toolName: (event.data['toolName'] as String?) ?? '',
              title: (event.data['title'] as String?) ?? '',
              output: (event.data['output'] as String?) ?? '',
              isError: event.data['isError'] == true,
            ),
          );
        case AgentEventTypes.stepEnd:
          steps++;
          totalTokens += (event.data['totalTokens'] as int?) ?? 0;
        case AgentEventTypes.turnBegin:
          beginMs = event.time.millisecondsSinceEpoch;
        case AgentEventTypes.turnEnd:
          endMs = event.time.millisecondsSinceEpoch;
          reason = event.data['reason'] as String?;
        default:
          break;
      }
    }

    result[turn] = AgentTurnWork(
      turnNumber: turn,
      steps: steps,
      totalTokens: totalTokens,
      durationMs: (beginMs != null && endMs != null) ? endMs - beginMs : 0,
      tools: tools,
      reason: reason,
    );
  });
  return result;
}

/// 中断半截正文重建（：assistant/chunk 事件的最小粒度消费方）
///
/// 取「最后一个有分片但无 assistant/message 收尾」的 step，拼接其分片
/// 文本。reset 分片（同 step 重试）清空此前累积；assistant/message 到达
/// 即视为该 step 已完整（分片作废）。返回 null = 无可重建的半截正文。
String? rebuildInterruptedAssistantText(List<AgentDurableEvent> events) {
  final chunkTextByStep = <int, String>{};
  final completedSteps = <int>{};
  var lastChunkedStep = -1;
  for (final event in events) {
    switch (event.type) {
      case AgentEventTypes.assistantChunk:
        final stepIndex = (event.data['stepIndex'] as num?)?.toInt() ?? 0;
        if (event.data['reset'] == true) {
          chunkTextByStep[stepIndex] = '';
        } else {
          final text = (event.data['text'] as String?) ?? '';
          chunkTextByStep[stepIndex] =
              (chunkTextByStep[stepIndex] ?? '') + text;
          lastChunkedStep = stepIndex;
        }
      case AgentEventTypes.assistantMessage:
        final stepIndex = (event.data['stepIndex'] as num?)?.toInt() ?? 0;
        completedSteps.add(stepIndex);
      default:
        break;
    }
  }
  if (lastChunkedStep < 0 || completedSteps.contains(lastChunkedStep)) {
    return null;
  }
  final text = chunkTextByStep[lastChunkedStep] ?? '';
  return text.isEmpty ? null : text;
}
