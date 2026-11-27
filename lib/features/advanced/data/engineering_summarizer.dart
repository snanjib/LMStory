import 'package:lmstory/core/agent/agent_message.dart';
import 'package:lmstory/core/agent/agent_runner.dart'
    show AgentOverflowCompactor;
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';
import 'package:lmstory/core/network/http_client_types.dart'
    show CancellationToken;
import 'package:lmstory/features/advanced/data/engineering_compaction_service.dart';
import 'package:lmstory/features/advanced/domain/services/agent_log_recovery.dart';
import 'package:lmstory/features/advanced/domain/services/compaction_planning.dart'
    show EngineeringCompactionTuning;
import 'package:lmstory/features/advanced/domain/services/director_surface_v2.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart'
    show NamingConfig;
import 'package:lmstory/features/chat/domain/services/llm_service.dart';

/// 工程摘要指令（叙事适配 8 段；dsh COMPACTION_INSTRUCTION 骨架）。
///
/// 分段产出供后续消费：已完成剧情梗概（宏摘要只复用此段）/世界状态
/// 演变（承接被压快照「最新事实」职责）/人物状态与关系/时间线与场景锚
/// /未兑现伏笔与契约要点/工作轨迹要点（检索过什么、结论是什么——证据
/// 承接）/当前轮衔接/必须逐字保留项。
const String kEngineeringCompactionInstruction = '''
请把以上对话材料压缩为一份工程纪要，供下一轮工作续接使用。严格分段输出，各段标题固定如下：

【已完成剧情梗概】按轮概括已完成并交付的剧情（只写正文已定稿的内容；不确定处标注）。
【世界状态演变】事实如何变化、每条变化的来源轮号（承接各轮世界事实快照的「最新事实」职责）。
【人物状态与关系】主要人物的当前状态与相互关系。
【时间线与场景锚】故事内时间推进与地点转移。
【未兑现伏笔与契约要点】尚未兑现的伏笔、承诺与约束。
【工作轨迹要点】逐条记录检索过什么、结论是什么（保留可核查的检索结论，供后续证据核对）。检索类回执在材料中带有工具调用编号（形如 call_…）时，逐条保留该编号。
【当前轮衔接】若材料含未定稿的在途过程，以「未定稿过程，仅供工作续接」口径单列，不写成已发生剧情。
【必须逐字保留项】专名、文言措辞、数字等需原样保留的内容。

纪律：不得虚构未发生的剧情；区分已提交事实、历史演变与待提交/未定稿事项；「拟更新」不得写成「已经发生」。''';

/// 摘要响应不合格（截断/工具调用/空内容——由压缩服务按 summary-error
/// 计入失败重试与熔断路径，不得把异常结构当成功纪要）
class EngineeringSummaryException implements Exception {
  const EngineeringSummaryException(this.reason, {this.usage});

  final String reason;

  /// 响应已到达时的计量样本（摘要 usage 无论成败落痕——
  /// 截断/带工具调用的响应同样携带 usage，随 end{error} 落账）
  final Map<String, dynamic>? usage;

  @override
  String toString() => 'EngineeringSummaryException($reason)';
}

/// 生产摘要器：共享前部式请求（[system 冻结前缀, 被压区间投影消息,
/// user 摘要指令]）经 [LlmService.chat] 单次调用。
///
/// 响应经结构校验（finishReason 截断/工具调用/空内容→异常，fail-closed）。
/// narrativeSection 按【已完成剧情梗概】段标记提取；提取失败不回退全文
/// ——提交侧以 narrative-section-missing 拒绝（正文资产只写验证过的
/// 已完成叙事段）。carriedEvidence 由压缩服务可检验解析（摘要文本引用
/// callId ∧ 被压区间真实证据回执，两者同时成立才承接）。
class LlmEngineeringSummarizer implements EngineeringSummarizer {
  LlmEngineeringSummarizer({
    required LlmService llmService,
    required this.namingConfig,
    required this.frozenPrefix,
    this.maxTokens = 4096,
    this.connectTimeout,
    this.readTimeout,
  }) : _llmService = llmService;

  final LlmService _llmService;
  final NamingConfig namingConfig;
  final String frozenPrefix;
  final int maxTokens;
  final Duration? connectTimeout;
  final Duration? readTimeout;

  @override
  Future<EngineeringSummaryOutput> summarize({
    required String sessionId,
    required List<AgentMessage> intervalMessages,
    required int narrativeBoundaryTurn,
    required List<ToolDefinition> tools,
    required void Function(String delta)? onDelta,
  }) async {
    final wire = AgentWireOptions.forProtocolName(namingConfig.protocol.name);
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': frozenPrefix},
      for (final m in intervalMessages) m.toRequestMap(wire),
      {'role': 'user', 'content': kEngineeringCompactionInstruction},
    ];
    final response = await _llmService.chat(
      LlmRequest(
        baseUrl: namingConfig.baseUrl,
        apiKey: namingConfig.apiKey,
        modelId: namingConfig.modelId,
        protocol: namingConfig.protocol,
        providerOptions: namingConfig.providerOptions,
        stream: false,
        maxTokens: maxTokens,
        messages: messages,
        // 与主对话共享同一工具定义（dsh buildSummarizationInput=system+
        // tools+被压区间共享前部式；tools 与模型/前缀同源）
        tools: tools.isEmpty ? null : tools,
        connectTimeout: connectTimeout,
        readTimeout: readTimeout,
        temperature: 0.2,
      ),
    );
    final usage = _usagePayloadOf(response.usage, response.finishReason);
    // 响应结构校验（fail-closed）：截断/工具调用/空内容不得当成功纪要
    final calls = response.toolCalls;
    if (calls != null && calls.isNotEmpty) {
      throw EngineeringSummaryException(
        'summary-response-tool-calls',
        usage: usage,
      );
    }
    if (response.finishReason == 'length') {
      throw EngineeringSummaryException(
        'summary-response-truncated',
        usage: usage,
      );
    }
    final text = response.content.trim();
    if (text.isEmpty) {
      throw EngineeringSummaryException('summary-response-empty', usage: usage);
    }
    return EngineeringSummaryOutput(
      summary: text,
      narrativeSection: _extractSection(text, '已完成剧情梗概'),
      usage: usage,
    );
  }

  /// 【标题】…（到下一个【或文末）段提取
  static String? _extractSection(String text, String title) {
    final start = text.indexOf('【$title】');
    if (start < 0) return null;
    final bodyStart = start + title.length + 2;
    var end = text.indexOf('【', bodyStart);
    if (end < 0) end = text.length;
    final section = text.substring(bodyStart, end).trim();
    return section.isEmpty ? null : section;
  }

  /// 响应计量样本（落痕口径）：完整输入面优先；无任何计量时 null
  static Map<String, dynamic>? _usagePayloadOf(
    LlmUsage? usage,
    String? finishReason,
  ) {
    if (usage == null) return null;
    final payload = <String, dynamic>{
      if (usage.fullInputTokens != null) 'inputTokens': usage.fullInputTokens,
      if (usage.promptTokens != null) 'promptTokens': usage.promptTokens,
      if (usage.completionTokens != null)
        'completionTokens': usage.completionTokens,
      if (usage.totalTokens != null) 'totalTokens': usage.totalTokens,
      if (usage.cacheReadTokens != null)
        'cacheReadTokens': usage.cacheReadTokens,
      if (usage.cacheCreationTokens != null)
        'cacheCreationTokens': usage.cacheCreationTokens,
      if (finishReason != null) 'finishReason': finishReason,
    };
    return payload.isEmpty ? null : payload;
  }
}

/// 溢出自愈压缩器（开启态）：复用 AgentRunner 既有溢出分支——执行账本
/// 压缩事务后返回新投影的出站消息（working 就地重建由 runner 完成）。
class EngineeringOverflowCompactor implements AgentOverflowCompactor {
  EngineeringOverflowCompactor({
    required this.service,
    required this.eventRepository,
    required this.sessionId,
    required this.contextWindowTokens,
    required this.retrievalRatio,
    this.tuning,
    this.cancelToken,
    // 完整预算面口径：出站 wire 选项与冻结前缀字符（选材估算同源）
    this.wireOptions = const AgentWireOptions(),
    this.frozenPrefixChars = 0,
  });

  final EngineeringCompactionService service;
  final AgentEventLogStore eventRepository;
  final String sessionId;
  final int contextWindowTokens;
  final double retrievalRatio;

  /// 调用方按会话配置解析的压缩参数（配置单源；null=服务缺省）
  final EngineeringCompactionTuning? tuning;
  final CancellationToken? cancelToken;
  final AgentWireOptions wireOptions;
  final int frozenPrefixChars;

  @override
  Future<List<AgentMessage>?> compact(List<AgentMessage> working) async {
    // 冻结前缀与构造时点解耦：显式给值（>0）优先，否则按当前账本取
    //（与返回面 assemble 同源，自愈估算不低估冻结前缀）
    final frozenChars = frozenPrefixChars > 0
        ? frozenPrefixChars
        : (DirectorSurfaceV2.latestFrozenPrefixOf(
              await eventRepository.readEvents(sessionId),
            )?.length ??
            0);
    final result = await service.compact(
      sessionId: sessionId,
      trigger: 'overflow',
      contextWindowTokens: contextWindowTokens,
      retrievalRatio: retrievalRatio,
      tuning: tuning,
      cancelToken: cancelToken,
      wireOptions: wireOptions,
      frozenPrefixChars: frozenChars,
    );
    if (result.outcome != 'committed') return null;
    // 提交成功：新纪元投影（checkpoint 遮蔽已生效）
    final events = await eventRepository.readEvents(sessionId);
    final frozen = DirectorSurfaceV2.latestFrozenPrefixOf(events);
    final projection = DirectorSurfaceV2.epochWindowProjection(events);
    return DirectorSurfaceV2.assemble(
      epochWindowMessages: projection.messages,
      frozenPrefix: frozen,
    );
  }
}
