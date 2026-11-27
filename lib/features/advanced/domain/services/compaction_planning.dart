import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' as crypto;
import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/intermediate_config.dart'
    show ContextBudget;
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';
import 'package:lmstory/core/network/llm_adapters/output_budget.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session_settings.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';

/// 压缩选材与触发公式（纯函数；正文覆盖边界=摘要实际包含的最后一个已完成轮）。
///
/// 选材对象=纪元窗投影（事件不动，checkpoint 以 surfaceOp replace 遮蔽）；
/// 冻结前缀不在窗内（组装器前置），天然永不压缩。保尾沿现状公式为初值
/// + 切点回退到工具配对平衡处 + 优先对齐已完成轮边界。

/// 触发与选材参数（生产默认见 default_config.json 的 advanced.engineering_compaction 段）
class EngineeringCompactionTuning {
  const EngineeringCompactionTuning({
    this.outputReserveTokens = 16384,
    this.headroomTokens = 8192,
    this.retainRatio = 0.30,
    this.retainMinTokens = 8192,
    this.retainMaxTokens = 32768,
    this.retainMaxWindowRatio = 0.45,
    this.charsPerToken = 4,
    this.oversizedResultChars = 8192,
    this.degradeHeadChars = 500,
  });

  factory EngineeringCompactionTuning.forDirectorRequest(
    AdvancedEngineeringCompactionConfig config, {
    required NamingConfig naming,
    required ChatSessionSettings settings,
  }) {
    final protocol = switch (naming.protocol) {
      LlmProtocol.anthropic => WireOutputProtocol.anthropic,
      LlmProtocol.openaiCompatible => WireOutputProtocol.openaiCompatible,
      LlmProtocol.openaiResponses => WireOutputProtocol.openaiResponses,
      LlmProtocol.geminiNative => WireOutputProtocol.geminiNative,
    };
    return EngineeringCompactionTuning.fromConfig(
      config,
      actualMaxTokens: resolveWireOutputTokens(
            protocol: protocol,
            modelId: naming.modelId,
            baseUrl: naming.baseUrl,
            configured: settings.maxTokens,
            modelMaxOutput: naming.maxOutputTokens,
            providerOptions: naming.providerOptions,
            reasoningEffort: settings.reasoningEffort,
          ) ??
          0,
    );
  }

  /// 配置单源：生产默认来自 default_config.json 的
  /// advanced.engineering_compaction 段；测试显式注入的 tuning 不走此路。
  /// [actualMaxTokens] 为当前请求的真实输出预算（>0 时优先于默认预留——
  /// 区分「请求真实 maxTokens」与「默认量」）。
  factory EngineeringCompactionTuning.fromConfig(
    AdvancedEngineeringCompactionConfig config, {
    int actualMaxTokens = 0,
  }) {
    final base = EngineeringCompactionTuning(
      outputReserveTokens: config.outputReserveTokens,
      headroomTokens: config.headroomTokens,
      retainRatio: config.retainRatio,
      retainMinTokens: config.retainMinTokens,
      retainMaxTokens: config.retainMaxTokens,
      retainMaxWindowRatio: config.retainMaxWindowRatio,
      charsPerToken: config.charsPerToken,
      oversizedResultChars: config.oversizedResultChars,
      degradeHeadChars: config.degradeHeadChars,
    );
    return actualMaxTokens > 0
        ? base.copyWith(outputReserveTokens: actualMaxTokens)
        : base;
  }

  EngineeringCompactionTuning copyWith({int? outputReserveTokens}) {
    return EngineeringCompactionTuning(
      outputReserveTokens: outputReserveTokens ?? this.outputReserveTokens,
      headroomTokens: headroomTokens,
      retainRatio: retainRatio,
      retainMinTokens: retainMinTokens,
      retainMaxTokens: retainMaxTokens,
      retainMaxWindowRatio: retainMaxWindowRatio,
      charsPerToken: charsPerToken,
      oversizedResultChars: oversizedResultChars,
      degradeHeadChars: degradeHeadChars,
    );
  }

  /// 输出预留（请求 max_tokens 量级）
  final int outputReserveTokens;

  /// headroom
  final int headroomTokens;

  /// 保尾比例/上下限（token）
  final double retainRatio;
  final int retainMinTokens;
  final int retainMaxTokens;
  final double retainMaxWindowRatio;

  /// 估算口径（dsh：4 chars/token）
  final int charsPerToken;

  /// 超限工具结果阈值（字符；超过者进入 model-free 降级候选）
  final int oversizedResultChars;

  /// 降级保留头部字符数（头 500 字+结论行+裁剪标记）
  final int degradeHeadChars;
}

/// 单条消息的实际可回传表示字符（wire-map 口径）：出站估算 map 的 JSON
/// 长度——与适配器出站面同源。正文/回执/结构化调用签名/思考块/签名等
/// 按当前协议的实际回传表示计入（协议分歧、剥离后不计由 map 本身保证
/// ——投影已剥离的表示不在 map 里，保留的恰好是会随请求发出的材料）。
int messageSurfaceChars(AgentMessage m, AgentWireOptions options) =>
    jsonEncode(_estimationWireMap(m, options)).length;

/// 估算用的出站 map：按适配器实际发送形态归一双表示——Anthropic 有序
/// 块（anthropicBlocks）可用时整体取代 content/thinkingBlocks/tool_calls
/// （适配器只发 blocks 数组），且写回**过滤后**的块（空 signature
/// thinking/空 redacted 适配器不发，不得计价）；不可用（缺 tool_use 而
/// 平行字段有调用、或全部滤光，适配器回退旧重建）时丢弃块、按
/// content/thinkingBlocks/tool_calls 计——重建路径同样按适配器丢弃空
/// signature thinking。Anthropic 的聚合 `reasoningContent` 与 Responses
/// 的明文 `reasoning_content` 都不进各自最终请求体（Anthropic 只用
/// thinkingBlocks/anthropicBlocks；Responses 不回放 reasoning），估算
/// 同步剔除。OpenAI 兼容端点的 `reasoning_content` 确实随消息透传发送，
/// 保留计量。不归一会让同一思考内容双计，或把适配器已丢弃的负载计进
/// 预算。
Map<String, dynamic> _estimationWireMap(
  AgentMessage m,
  AgentWireOptions options,
) {
  final map = m.toRequestMap(options);
  if (options.anthropicExtras) {
    // 聚合 reasoningContent 仅是网关供调用方使用的明文聚合；适配器有序
    // 块与回退重建路径都不读取它，不得计价
    map.remove('reasoningContent');
  }
  if (options.openaiResponses) {
    // Responses 不回放明文 reasoning（reasoning item 为服务端加密内容），
    // 最终 input 只含正文与 function_call items
    map.remove('reasoning_content');
  }
  final blocks = map['anthropicBlocks'];
  if (blocks is List && blocks.isNotEmpty) {
    // 与适配器同款逐块过滤（空 signature thinking/空 redacted/非法块）：
    // 全部滤光时适配器回退旧重建（_convertOrderedAssistantBlocks 返回
    // null），估算同样丢块走重建口径
    final usableBlocks = blocks.where((b) {
      if (b is! Map) return false;
      switch (b['type']) {
        case 'thinking':
          return (b['signature'] as String? ?? '').isNotEmpty;
        case 'redacted_thinking':
          return (b['data'] as String? ?? '').isNotEmpty;
        default:
          return true;
      }
    }).toList();
    final hasToolUse =
        usableBlocks.any((b) => b is Map && b['type'] == 'tool_use');
    final toolCalls = map['tool_calls'];
    final blocksUsable = usableBlocks.isNotEmpty &&
        (hasToolUse || !(toolCalls is List && toolCalls.isNotEmpty));
    if (blocksUsable) {
      map
        ..remove('content')
        ..remove('thinkingBlocks')
        ..remove('tool_calls')
        // 过滤结果写回：只要还有一个有效块，未滤掉的无效块（如空
        // signature thinking）也必须从计价面剔除——适配器只发有效块
        ..['anthropicBlocks'] = usableBlocks;
    } else {
      map.remove('anthropicBlocks');
    }
  }
  if (options.anthropicExtras) {
    // 重建路径（无有序块或全部滤光）按适配器同款丢弃空 signature
    // thinking：适配器重建只发有签名的思考块
    final thinkingBlocks = map['thinkingBlocks'];
    if (thinkingBlocks is List) {
      final usable = thinkingBlocks
          .where(
            (b) => b is Map && (b['signature'] as String? ?? '').isNotEmpty,
          )
          .toList();
      if (usable.isEmpty) {
        map.remove('thinkingBlocks');
      } else {
        map['thinkingBlocks'] = usable;
      }
    }
  }
  return map;
}

/// 出站面完整输入字符：Σ 消息实际可回传表示（wire-map 口径）+ 额外固定面
///（工具定义、冻结前缀等——不进投影但进请求，压缩永远不能触碰，
/// 须计入窗口估算）。
int surfaceInputChars(
  List<AgentMessage> messages, {
  AgentWireOptions options = const AgentWireOptions(),
  int extraFixedChars = 0,
}) {
  var chars = extraFixedChars;
  for (final m in messages) {
    chars += messageSurfaceChars(m, options);
  }
  return chars;
}

/// 工具定义的完整预算面字符（与请求 wire 同源的 JSON 近似口径）
int toolDefinitionsChars(List<ToolDefinition> tools) => tools.isEmpty
    ? 0
    : jsonEncode([
        for (final t in tools)
          {
            'name': t.name,
            'description': t.description,
            'parameters': t.parameters,
          },
      ]).length;

/// 触发阈值（token）：窗口 − max(输出预留, 检索预留) − headroom
int compactionThresholdTokens({
  required int contextWindowTokens,
  required double retrievalRatio,
  required EngineeringCompactionTuning tuning,
}) {
  final retrievalReserve = (contextWindowTokens * retrievalRatio).round();
  final reserve = tuning.outputReserveTokens > retrievalReserve
      ? tuning.outputReserveTokens
      : retrievalReserve;
  return contextWindowTokens - reserve - tuning.headroomTokens;
}

/// In engineering mode the output reserve can bring compaction forward.
int directorCompactionTriggerTokens({
  required int contextWindowTokens,
  required ContextBudget budget,
  EngineeringCompactionTuning? engineeringTuning,
}) {
  final configured =
      (contextWindowTokens * budget.compactionTriggerRatio).floor();
  if (engineeringTuning == null) return configured;
  final safe = compactionThresholdTokens(
    contextWindowTokens: contextWindowTokens,
    retrievalRatio: budget.retrievalRatio,
    tuning: engineeringTuning,
  );
  return math.max(1, math.min(configured, safe));
}

/// 估算（token；4 chars/token 粗估口径——上下文预计的锚点差分共用此换算）
int estimateTokensForChars(int chars, EngineeringCompactionTuning tuning) =>
    chars ~/ tuning.charsPerToken;

/// 选材结果
class CompactionIntervalPlan {
  const CompactionIntervalPlan({
    required this.projectionStart,
    required this.projectionEnd,
    required this.startSeq,
    required this.endSeq,
    required this.shadowedSeqs,
    required this.narrativeBoundaryTurn,
    required this.oversizedResultSeqs,
  });

  /// 窗投影消息坐标 [start, end)（checkpoint replace 坐标空间）
  final int projectionStart;
  final int projectionEnd;

  /// 事件区间（seq 坐标，[startSeq, endSeq)）
  final int startSeq;
  final int endSeq;

  /// 被遮蔽事件的 seq（checkpoint sourceEventSeqs 引用）
  final List<int> shadowedSeqs;

  /// 区间内最后一个「已完成并持久化」（存在 replay/binding）且其全部
  /// 消息（含轮末正文）完整纳入区间的轮号；null = 区间内无此类轮
  /// （纯在途/覆盖不完整材料——正文侧零产物，不得虚报覆盖）
  final int? narrativeBoundaryTurn;

  /// 区间内超限工具结果事件的 seq（提交前 model-free 降级候选）
  final List<int> oversizedResultSeqs;
}

/// 区间不可选原因
enum CompactionSelectionFailure { emptyAfterRetain, allFrozenOrBlocked }

/// 选材：保尾预算 → 切点回退（先轮边界、再工具配对平衡）→ 区间。
///
/// 切点合法性（工具配对不可拆）：过切点的未闭合工具调用计数必须为 0。
/// 该折叠条件两侧同时成立——区间侧不以未闭合调用声明收尾，保尾侧不
/// 残留其调用声明已被压掉的工具结果（dsh toolPairingBalancedBefore 同
/// 语义：按投影消息折叠 in-progress 计数，不依赖 span 类型单一检查）。
/// 切点只回退不前伸：不得为凑整轮叙事覆盖而把区间延伸过保尾预算——
/// 正文覆盖一律止于摘要实际包含的最后一个已完成轮（无延后补写）。
CompactionIntervalPlan? selectCompactionInterval({
  required List<AgentDurableEvent> windowEvents,
  required List<AgentSurfaceSpan> spans,
  required List<AgentMessage> projectionMessages,
  required int contextWindowTokens,
  required EngineeringCompactionTuning tuning,
  int extraFixedChars = 0,
  AgentWireOptions wireOptions = const AgentWireOptions(),
}) {
  // 消息级素材：span（from>=0）→ 归属轮号 + 字符量。完整预算面 wire-map
  // 口径：该 span 覆盖的投影消息的 toRequestMap JSON 长度（与适配器出站
  // 面同源——正文/回执/调用签名/协议化思考表示自动随 map 计入，每条
  // 消息只计一次不双计）。spans 按投影坐标排序（原位 replace 的
  // span 产生于账本尾部，须归位）。
  final sortedSpans = [...spans]..sort((a, b) => a.from.compareTo(b.from));
  final entries = <({int index, int turn, int chars, AgentSurfaceSpan span})>[];
  var totalChars = 0;
  for (final span in sortedSpans) {
    if (span.from < 0) continue;
    final turn = (span.event.data['turn'] as num?)?.toInt() ?? 0;
    var chars = 0;
    for (var i = span.from; i < span.to && i < projectionMessages.length; i++) {
      chars += messageSurfaceChars(projectionMessages[i], wireOptions);
    }
    entries.add((index: span.from, turn: turn, chars: chars, span: span));
    totalChars += chars;
  }
  if (entries.isEmpty) return null;
  // 固定不可压面（工具定义等）：计入窗口估算与保尾比例基数——它随
  // 请求发出却不进投影，漏计会低估真实表面并高估可压空间。
  totalChars += extraFixedChars;

  // 过切点平衡：balanceBefore[m] = messages[0..m) 的未闭合调用数
  //（assistant 携带 n 个调用 +n，tool 结果 -1）
  final balanceBefore = List<int>.filled(projectionMessages.length + 1, 0);
  var inProgress = 0;
  for (var i = 0; i < projectionMessages.length; i++) {
    balanceBefore[i] = inProgress;
    final m = projectionMessages[i];
    if (m.role == 'assistant') {
      inProgress += m.toolCalls?.length ?? 0;
    } else if (m.role == 'tool') {
      inProgress--;
    }
  }
  balanceBefore[projectionMessages.length] = inProgress;

  bool safeCut(int k) {
    final cutAt =
        k < entries.length ? entries[k].span.from : projectionMessages.length;
    return balanceBefore[cutAt] == 0;
  }

  // 保尾预算（token→chars）
  final windowTokens = estimateTokensForChars(totalChars, tuning);
  var retainTokens = (windowTokens * tuning.retainRatio).round();
  if (retainTokens < tuning.retainMinTokens) {
    retainTokens = tuning.retainMinTokens;
  }
  final retainCap =
      tuning.retainMaxTokens < contextWindowTokens * tuning.retainMaxWindowRatio
          ? tuning.retainMaxTokens
          : (contextWindowTokens * tuning.retainMaxWindowRatio).round();
  if (retainTokens > retainCap) retainTokens = retainCap;
  var retainChars = retainTokens * tuning.charsPerToken;

  // 从尾向前累计保尾量 → 切点候选（保留段起点）
  var budgetCutoff = entries.length; // 保留 entries[budgetCutoff..)
  for (var i = entries.length - 1; i >= 0; i--) {
    if (retainChars <= 0) break;
    retainChars -= entries[i].chars;
    budgetCutoff = i;
  }
  if (budgetCutoff <= 0) {
    // 全部消息都进保留段：无可压区间
    return null;
  }

  // 每轮最后一条 span 的序号（entries 按投影顺序；用于真实覆盖判定）
  final lastSpanIndexOfTurn = <int, int>{};
  for (var i = 0; i < entries.length; i++) {
    lastSpanIndexOfTurn[entries[i].turn] = i;
  }
  final completedTurns = <int>{
    for (final e in windowEvents)
      if (e.type == AgentEventTypes.replayBinding)
        (e.data['turn'] as num?)?.toInt() ?? -1,
  };

  // 切点回退①：轮边界优先——某轮起始 span 处且过切点平衡。
  // 只回退：区间不得越过保尾预算去凑已完成轮整轮。
  var cutoff = -1;
  for (var k = budgetCutoff; k >= 1; k--) {
    final isTurnStart =
        k == entries.length || entries[k].turn != entries[k - 1].turn;
    if (isTurnStart && safeCut(k)) {
      cutoff = k;
      break;
    }
  }
  // 切点回退②：任意平衡切点（轮内合法切点——叙事覆盖按实际包含计算）
  if (cutoff < 0) {
    for (var k = budgetCutoff; k >= 1; k--) {
      if (safeCut(k)) {
        cutoff = k;
        break;
      }
    }
  }
  if (cutoff <= 0) return null;

  // 组装区间：消息坐标/seq 坐标/遮蔽 seq/轮边界/超限结果
  final startEntry = entries.first;
  final endEntry = entries[cutoff - 1];
  final projectionStart = startEntry.index;
  final projectionEnd = endEntry.span.to;
  final startSeq = startEntry.span.event.seq ?? 0;
  final endSeq = endEntry.span.event.seq ?? 0;
  final shadowedSeqs = <int>[];
  final oversized = <int>[];
  for (var i = 0; i < cutoff; i++) {
    final event = entries[i].span.event;
    final seq = event.seq;
    if (seq == null) continue;
    shadowedSeqs.add(seq);
    if (event.type == AgentEventTypes.toolResult) {
      final output = event.data['output'];
      if (output is String && output.length > tuning.oversizedResultChars) {
        oversized.add(seq);
      }
    }
  }
  // 遮蔽 seq 的传递展开：区间内的 replace 事件（超限降级等
  // 原位重写）按其 sourceEventSeqs 取代旧事件——被取代者的内容同样被
  // 本次 checkpoint 替换，其 seq 必须一并入列；否则旧证据/旧声明按 seq
  // 资格判定时会绕过遮蔽继续生效（降级过的证据在压缩后「仍 active」）。
  if (shadowedSeqs.isNotEmpty) {
    final seqToEvent = <int, AgentDurableEvent>{
      for (final e in windowEvents)
        if (e.seq != null) e.seq!: e,
    };
    final expanded = shadowedSeqs.toSet();
    final queue = [...shadowedSeqs];
    while (queue.isNotEmpty) {
      final event = seqToEvent[queue.removeLast()];
      if (event == null || event.sourceEventSeqs.isEmpty) continue;
      for (final src in event.sourceEventSeqs) {
        if (expanded.add(src)) queue.add(src);
      }
    }
    shadowedSeqs
      ..clear()
      ..addAll(expanded.toList()..sort());
  }
  // 叙事覆盖边界：区间内已完成且完整纳入（该轮最后一条 span 在区间内，
  // 即轮末正文确实被本次摘要看到）的最后一轮
  var narrative = -1;
  for (final t in completedTurns) {
    final last = lastSpanIndexOfTurn[t];
    if (last != null && last < cutoff && t > narrative) narrative = t;
  }

  return CompactionIntervalPlan(
    projectionStart: projectionStart,
    projectionEnd: projectionEnd,
    startSeq: startSeq,
    endSeq: endSeq,
    shadowedSeqs: shadowedSeqs,
    narrativeBoundaryTurn: narrative > 0 ? narrative : null,
    oversizedResultSeqs: oversized,
  );
}

/// 投影消息的确定性摘要（surfaceDigest/intervalDigest——log-only 事件
/// 不改投影，投影摘要天然不随其变化）
String projectionMessagesDigest(List<AgentMessage> messages) {
  final payload = jsonEncode([
    for (final m in messages) agentMessageToSurfaceData(m),
  ]);
  return crypto.sha256.convert(utf8.encode(payload)).toString();
}
