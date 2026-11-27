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

  /// 工程上下文模式纪元边界（log-only）：进入/退出新模式的事件标记。
  ///
  /// data: {phase: 'enter'|'exit', epochId, status?: 'pending'|'complete',
  /// fromTurn?, captureCount?}。enter 以两段追加表达（pending → complete
  /// 各一条，同一 epochId），投影器按最新 complete 纪元建立开启态表面；
  /// exit 令其前全部纪元降为 log-only。
  static const String modeEpoch = 'mode/epoch';

  /// 工程上下文模式进入时的一次性历史捕获（surface append）。
  ///
  /// 把关闭态可见历史（正文+trace 行，含压缩摘要）逐条物化为事件，
  /// data: {as: 'user'|'assistant'|'system', content, epochId,
  /// source: 'mode_capture'}。捕获文本入账后不可改写。
  static const String modeCapture = 'mode/capture';

  /// 表面守卫留痕（log-only）：装配一致性疑点（如投影与内存工作面漂移）
  /// 的 fail-closed 记录。data: {kind, detail?}
  static const String surfaceGuard = 'surface/guard';

  /// 逐请求分叉度量（log-only）：开启态每步出站面与前一次
  /// 出站面的内容前缀分叉位置 + 断点策略摘要。data: {stepIndex,
  /// divergedAtIndex（首个差异消息下标；null=首步/全新面）, prevChars,
  /// newChars, prefixChars（分叉前公共前缀字符量）, frozenPrefixChars,
  /// digest}。随账本导出可复算缓存分叉与断点收益。
  static const String requestMetric = 'request/metric';

  /// 正文版本绑定留痕（log-only，生成事实）：persist 成功后写入
  /// {turn, attemptId, variantIndex, proseHash, inputHash, encoding}。
  /// 入账后不可改写——变体切换的轨迹身份核对（先 attemptId 后 proseHash）
  /// 读它判定「保留轨迹 / 遮蔽」。缺编码标记的旧算法留痕按未绑定降级。
  static const String replayBinding = 'replay/binding';

  /// 压缩事务四事件+作废（log-only；checkpoint 本体是 user/message
  /// replace，见 compactionSummary 说明）。
  /// start：{opId, trigger, surfaceDigest, intervalDigest, intervalSeqs}
  /// cancel：{opId, reason}——取消轮/退出会话/删轮的显式作废（表面没变
  /// ≠取消后有提交资格，第四条件即「无本 opId 作废记录」）
  /// summary：{opId, trigger, shadowedSeqs, evidenceCarried,
  /// narrativeBoundary?{summaryMessageId,boundaryMessageId,macroMemoryId,
  /// turn}}——narrativeBoundary 缺席=纯工程 checkpoint（正文侧零产物）
  /// end：{opId, error?}（失败/被拒/收敛均落，error 区分原因）
  /// undo：{targetOpId, targetStartSeq}——checkpoint 作废，影子区间回到
  /// 表面；chat 侧按 narrativeBoundary 产物 ID 精确回退
  static const String compactionStart = 'compaction/start';
  static const String compactionCancel = 'compaction/cancel';
  static const String compactionSummary = 'compaction/summary';
  static const String compactionEnd = 'compaction/end';
  static const String compactionUndo = 'compaction/undo';

  /// 轮首尾料入账标记（log-only）：data: {turn, attemptId,
  /// coreBlocksDigest?, snapshot: 'full'|'unchanged'|'none'}——无变化
  /// 变更检测的真源（下一轮对照本链判定全量/单行）。
  static const String roundBootstrap = 'round/bootstrap';

  /// 分支重建边界（编辑/重生成/删轮/变体切换）。
  ///
  /// log-only 形态：审计标记（data: {reason, turn, ...}；物理删旧尝试的
  /// 重建路径——重生成/编辑/删轮）。surface replace 形态：变体切换的
  /// 轨迹处置——遮蔽该轮工作轨迹区间为单行遮蔽说明并/或恢复原轨迹
  /// （data.messages 携带替换消息数组，replaceStart/replaceEnd 为当前
  /// 投影坐标）。绑定留痕不随重建重算（历史绑定是不可变生成事实）。
  static const String branchRebuild = 'branch/rebuild';
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
    this.contentGeneration = 0,
  });

  /// 模型可见消息（折叠 surface 事件后的最终形态）
  final List<AgentMessage> messages;

  /// core memory blocks 消息的投影坐标（无则 -1；replace 时用它定位）
  final int coreIndex;

  /// 已折叠到的最大事件 seq（增量折叠的 watermark）
  final int lastSeq;

  /// 投影代数：账本内 surfaceOp=replace 事件的累计数（压缩提交/变体
  /// 遮蔽/撤销等显式失效都会推进）。变化=表面曾被改写，增量缓存必须
  /// 整体重建（对齐 dsh contentGeneration 语义）。
  final int contentGeneration;
}

/// 事件在投影中产生的消息区间（[from, to)；from=-1 = 未产生消息）
typedef AgentSurfaceSpan = ({AgentDurableEvent event, int from, int to});

/// 带区间记录的投影结果（变体切换遮蔽规划等需要事件→消息坐标映射）
class AgentSurfaceProjectionWithSpans {
  const AgentSurfaceProjectionWithSpans({
    required this.projection,
    required this.spans,
  });

  final AgentSurfaceProjection projection;
  final List<AgentSurfaceSpan> spans;
}

/// 把事件日志投影为模型可见消息（纯函数，设计报告 §7.3 deriveMessages）
///
/// 规则：
/// - `user/message` / `assistant/message` / `tool/result` append → 追加消息；
///   带 replace 且区间合法 → 原位替换 [replaceStart, replaceEnd)
///   （压缩 checkpoint / 变体遮蔽；区间非法的 replace 忽略，与
///   surface/replace 的防御口径一致——下游守卫兜漂移）
/// - `system/core` append → 追加系统消息并记录坐标；
///   `system/core` replace → 替换坐标 [replaceStart, replaceEnd) 内的消息
/// - log-only 事件跳过
AgentSurfaceProjection deriveAgentSurface(List<AgentDurableEvent> events) =>
    deriveAgentSurfaceSpans(events).projection;

/// 同 [deriveAgentSurface]，并逐事件记录其产生/替换的消息区间（遮蔽
/// 规划按 data.turn 定位轮区间用；未产生消息的事件 span 为 from=-1）。
///
/// span 坐标始终为最终投影坐标：合法应用的 replace 会先修复既有 span
///（与替换区间交叠者废弃——被新内容取代；其后方者按长度增量平移），
/// 保证任意前缀读取时 span 两两不交且有序（压缩选材/变体遮蔽依赖）。
AgentSurfaceProjectionWithSpans deriveAgentSurfaceSpans(
  List<AgentDurableEvent> events,
) {
  var messages = <AgentMessage>[];
  var coreIndex = -1;
  var lastSeq = -1;
  var contentGeneration = 0;
  final spans = <AgentSurfaceSpan>[];

  for (final event in events) {
    if (event.seq != null && event.seq! > lastSeq) lastSeq = event.seq!;
    final op = event.surfaceOp;
    if (op == null) {
      continue;
    }
    if (op == AgentSurfaceOpKind.replace) contentGeneration++;
    final spanFrom = messages.length;
    // 本事件对既有消息区间的改写（应用成功才记）：[start, end) → n 条
    (int, int, int)? replacedRange;

    switch (event.type) {
      case AgentEventTypes.userMessage:
        replacedRange = _messageReplaceRange(event, spanFrom);
        messages = _applyAppendOrReplace(
          messages,
          event,
          AgentMessage.user((event.data['content'] as String?) ?? ''),
        );
      case AgentEventTypes.assistantMessage:
        replacedRange = _messageReplaceRange(event, spanFrom);
        messages = _applyAppendOrReplace(
          messages,
          event,
          _assistantFromData(event.data),
        );
      case AgentEventTypes.toolResult:
        replacedRange = _messageReplaceRange(event, spanFrom);
        messages = _applyAppendOrReplace(
          messages,
          event,
          AgentMessage.toolResult(
            toolCallId: (event.data['callId'] as String?) ?? '',
            content: (event.data['output'] as String?) ?? '',
            isError: event.data['isError'] == true,
          ),
        );
      case AgentEventTypes.systemFrozen:
        // 冻结前缀：append 一次后永不主动 replace（缓存断点 1/2 的载体）。
        // 审查收官  读取侧折叠：应用重启后 runner 内存判据失忆会
        // 重落一条 frozen（append-only 不删旧）——投影按「前缀当前值」
        // 语义只保留最新一条（旧条位于头部 0 位时原位替换）
        final content = (event.data['content'] as String?) ?? '';
        if (messages.isNotEmpty && messages[0].role == 'system') {
          replacedRange = (0, 1, 1);
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
          replacedRange = (coreIndex, coreIndex + 1, 1);
          messages = [...messages]..[coreIndex] = AgentMessage.system(content);
        } else if (op == AgentSurfaceOpKind.append) {
          messages.add(AgentMessage.system(content));
          coreIndex = messages.length - 1;
        } else {
          final start = event.replaceStart ?? 0;
          final end = event.replaceEnd ?? start;
          final next = <AgentMessage>[...messages];
          if (start >= 0 && end > start && end <= next.length) {
            replacedRange = (start, end, 1);
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
            replacedRange = (start, end, replacements.length);
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
      case AgentEventTypes.modeCapture:
        // 工程模式进入捕获：按 data.as 还原角色（关闭态可见历史的逐条
        // 物化）。不触碰 system/frozen 与 system/core 的坐标逻辑——捕获区
        // 是历史快照，与冻结前缀/场记板「当前值」语义无关。
        if (op == AgentSurfaceOpKind.append) {
          final content = (event.data['content'] as String?) ?? '';
          switch (event.data['as']) {
            case 'assistant':
              messages.add(_assistantFromData({'text': content}));
            case 'system':
              messages.add(AgentMessage.system(content));
            default:
              messages.add(AgentMessage.user(content));
          }
        }
      case AgentEventTypes.compactionUndo:
        // 压缩撤销：checkpoint 作废，影子区间回到表面——事件携带
        // 恢复消息数组（撤销方从「剔除该 checkpoint 的重投影」取原区间），
        // 区间为当前投影坐标（checkpoint 现占位）。
        if (op == AgentSurfaceOpKind.replace) {
          final start = event.replaceStart ?? 0;
          final end = event.replaceEnd ?? start;
          final restored =
              (event.data['messages'] as List<dynamic>? ?? const [])
                  .whereType<Map<String, dynamic>>()
                  .map(_messageFromData)
                  .toList();
          if (start >= 0 && end > start && end <= messages.length) {
            replacedRange = (start, end, restored.length);
            messages = [...messages]..replaceRange(start, end, restored);
          }
        }
      case AgentEventTypes.branchRebuild:
        // 变体切换的轨迹处置：data.messages 携带替换消息数组（遮蔽行+
        // 新正文，或恢复的原轨迹），区间为当前投影坐标。
        // log-only 形态（无 surfaceOp）跳过（纯审计标记）。
        if (op == AgentSurfaceOpKind.replace) {
          final start = event.replaceStart ?? 0;
          final end = event.replaceEnd ?? start;
          final replacements =
              (event.data['messages'] as List<dynamic>? ?? const [])
                  .whereType<Map<String, dynamic>>()
                  .map(_messageFromData)
                  .toList();
          if (start >= 0 && end > start && end <= messages.length) {
            replacedRange = (start, end, replacements.length);
            messages = [...messages]..replaceRange(start, end, replacements);
          }
        }
      default:
        // 未知 surface 事件类型：跳过（向前兼容，不拒绝重建）
        break;
    }

    // 坐标修复：本事件改写了既有区间——交叠 span 废弃，后方 span 平移
    if (replacedRange != null) {
      final (s, e, n) = replacedRange;
      final delta = n - (e - s);
      final remapped = <AgentSurfaceSpan>[];
      for (final sp in spans) {
        if (sp.from < 0 || sp.to <= s) {
          remapped.add(sp);
        } else if (sp.from >= e) {
          remapped.add(
            (
              event: sp.event,
              from: sp.from + delta,
              to: sp.to + delta,
            ),
          );
        }
        // 与 [s, e) 交叠：被本事件取代，废弃
      }
      spans
        ..clear()
        ..addAll(remapped);
    }

    // 区间记录：对既有区间的合法改写记其新占位区间（变长 replace 的
    // 长度增量不能误记为尾部追加）；append 型（长度增长）记尾部区间；
    // 未产生消息/忽略/log-only 记 from=-1。
    if (replacedRange != null) {
      final (s, _, n) = replacedRange;
      spans.add((event: event, from: s, to: s + n));
    } else if (messages.length > spanFrom) {
      spans.add((event: event, from: spanFrom, to: messages.length));
    } else {
      spans.add((event: event, from: -1, to: -1));
    }
  }

  return AgentSurfaceProjectionWithSpans(
    projection: AgentSurfaceProjection(
      messages: List.unmodifiable(messages),
      coreIndex: coreIndex,
      lastSeq: lastSeq,
      contentGeneration: contentGeneration,
    ),
    spans: List.unmodifiable(spans),
  );
}

/// 消息型事件的 replace 区间（应用前长度校验；null=append 或区间非法）
(int, int, int)? _messageReplaceRange(AgentDurableEvent event, int preLen) {
  if (event.surfaceOp != AgentSurfaceOpKind.replace) return null;
  final start = event.replaceStart ?? 0;
  final end = event.replaceEnd ?? start;
  if (start >= 0 && end > start && end <= preLen) return (start, end, 1);
  return null;
}

/// 消息型 surface 事件的通用折叠：append → 就地追加；replace 且区间
/// 合法 → 原位替换 [replaceStart, replaceEnd)（非法区间忽略——账本坐标
/// 损坏时宁可让下游守卫发现漂移，也不静默换位）。
List<AgentMessage> _applyAppendOrReplace(
  List<AgentMessage> messages,
  AgentDurableEvent event,
  AgentMessage message,
) {
  if (event.surfaceOp == AgentSurfaceOpKind.replace) {
    final start = event.replaceStart ?? 0;
    final end = event.replaceEnd ?? start;
    if (start >= 0 && end > start && end <= messages.length) {
      return [...messages]..replaceRange(start, end, [message]);
    }
    return messages;
  }
  messages.add(message);
  return messages;
}

/// AgentMessage → surface 事件 data（：surface/replace 替换数组序列化；
/// 与 [_messageFromData] 互逆）
Map<String, dynamic> agentMessageToSurfaceData(AgentMessage message) {
  if (message.toolCallId != null) {
    return {
      'as': 'tool',
      'callId': message.toolCallId,
      'content': message.content ?? '',
      if (message.isToolError) 'isError': true,
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
        isError: data['isError'] == true,
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
