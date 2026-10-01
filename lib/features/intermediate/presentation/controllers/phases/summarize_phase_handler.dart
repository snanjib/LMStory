import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/config/intermediate_prompts_v2.dart';
import 'package:lmstory/core/config/output_token_policy.dart';
import 'package:lmstory/core/llm/tool_calling/tool_choice.dart';
import 'package:lmstory/core/llm/tool_calling/tool_definition.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/intermediate/domain/services/stream_marker_parser.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/entities/facts_delta.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/services/fact_context_builder.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_context.dart';
import 'package:lmstory/features/story_runtime/presentation/controllers/stream_runner.dart';

/// 事件摘要生成失败异常（Phase 6 Step 6.3 新增）
///
/// 由 [SummarizePhaseHandler] 抛出，控制器 catch 后调用 `_fail(E017)`。
/// 携带 [reason] 供日志与失败上下文展示。
class SummarizeFailedException implements Exception {
  const SummarizeFailedException(this.reason);
  final String reason;

  @override
  String toString() => 'SummarizeFailed: $reason';
}

/// summarizing 阶段产出（DOC-11 §4.4 双工具并行调用）
///
/// 包含两个工具调用的解析结果：
/// - [summary]：事件摘要（必填，summarizing 阶段核心任务，失败则整轮失败）
/// - [factsDeltas]：事实变更列表（可空，失败不影响经历层，仅记日志）
class SummarizePhaseResult {
  const SummarizePhaseResult({
    required this.summary,
    this.factsDeltas = const [],
  });

  /// 事件摘要（必填）
  final EventSummary summary;

  /// 事实变更列表（可能为空：本轮无事实变更 OR 事实层失败 OR 禁用）
  final List<FactsDelta> factsDeltas;
}

/// 事件摘要生成阶段处理器（Phase 6 Step 6.3 新增）
///
/// 基于回复正文生成事件摘要，输出 [EventSummary]。
/// 降级链：工具调用 → JSON 模式。
///
/// **工具调用模式**（[StreamConfig.toolCallingEnabled] = true）：
/// - 注入 `tools=[kExtractSummaryToolDefinition, kExtractFactsToolDefinition]`
///   （DOC-11 §4.4 双工具并行调用，2026-07-20 新增 facts 工具）
/// - `toolChoice=required`：LLM 必须调用至少一个工具，可以是任一或两者
/// - [StreamRunner.runWithToolCall] 返回 [ToolCallResult]
/// - `summary` 工具被调用 → 解析 `arguments {what, tags, importance, ...}` → [EventSummary]
/// - `summary` 工具未被调用 → 尝试 `fallbackText` JSON 降级 → 失败则降级 JSON 模式
/// - `facts` 工具被调用 → 解析 `arguments {deltas: [...]}` → [List<FactsDelta>]
/// - `facts` 工具未被调用 → 返回空列表（事实层失败不影响经历层）
/// - `hasToolCall=false` → LLM 未调用任何工具，降级到 JSON 模式
///
/// **JSON 模式**（`toolCallingEnabled=false` 或工具调用降级）：
/// - 不注入 tools，注入 `response_format=json_object`（供应商支持时）
/// - LLM 通过 `LlmTextDelta` 输出 JSON，累积为 `fallbackText`
/// - 解析 `fallbackText` 为 JSON → [EventSummary]
/// - 解析失败 → 抛 [SummarizeFailedException]
/// - JSON 模式不产出 facts（事实层依赖工具调用，JSON 降级时本轮无事实变更）
///
/// **不接入控制器主流程**：本类只提供 `run` 方法，由 Step 6.4 控制器
/// 在 `_runSummarizePhase` 中调用。
///
/// **compact 降级复用**：summarizing 始终执行——即使 reviewing 因 compact
/// 模式跳过（`skipReview=true`，reply=generatedText），仍需生成 EventSummary
/// 以持久化记忆（DOC-09A-2 §6.6）。
class SummarizePhaseHandler {
  const SummarizePhaseHandler({
    required this.streamRunner,
    required this.logger,
    this.factContextBuilder,
    this.experienceRepository,
  });

  final StreamRunner streamRunner;
  final Logger logger;

  /// 事实上下文构建器（nullable，测试可不注入）
  ///
  /// 2026-07-22 新增：用于在 summarizing 阶段查询本会话已知实体，
  /// 替换 extractFactsPrompt 中的 `{{known_entities}}` 占位符
  /// （DOC-11 §5.2）。null 时不替换（保留字面占位符，LLM 无法发起
  /// update_attr 等需要 entityId 的操作）。
  final FactContextBuilder? factContextBuilder;

  /// 经历记忆仓储（nullable，测试可不注入）
  ///
  /// 2026-07-25 新增（叙事时间机制）：用于查询最近几轮的经历记忆，
  /// 提取 narrativeTime 构建时间线上下文，替换 extractSummaryPrompt
  /// 中的 `{{recent_timeline}}` 占位符。null 时不替换（保留字面占位符）。
  final ExperienceRepository? experienceRepository;

  /// 执行事件摘要生成 + 事实变更提取（双工具并行调用，DOC-11 §4.4）
  ///
  /// [toolCallingEnabled] = true 时先尝试工具调用（注入 summary + facts 两工具），
  /// 失败降级到 JSON 模式（仅产出 summary）。
  /// [toolCallingEnabled] = false 时直接走 JSON 模式（仅产出 summary）。
  ///
  /// 返回 [SummarizePhaseResult]，包含 EventSummary（必填）+ FactsDelta 列表（可空）。
  /// summary 失败抛 [SummarizeFailedException]；facts 失败返回空列表不抛异常。
  ///
  /// **串行兜底机制**（2026-07-26 新增，DOC-11 §4.5）：
  /// 兼容不支持 `parallel_tool_calls` 的模型（如 agnes-2.0-flash）。
  /// 当首次并行调用两个工具但模型只调用了 `extract_event_summary`
  /// 而跳过 `extract_facts` 时，自动发起第二次请求单独调用
  /// `extract_facts`，把已生成的 summary 作为上下文注入。
  /// 机制对比：
  /// - 支持并行的模型（如 agnes-2.5-pro-alpha）：一次完成，无额外开销
  /// - 不支持并行的模型（如 agnes-2.0-flash）：自动串行兜底，无功能缺失
  Future<SummarizePhaseResult> run({
    required RoundContext ctx,
    required bool toolCallingEnabled,
    String sessionId = '',
  }) async {
    // 2026-07-22 修复：替换 {{known_entities}} 占位符（DOC-11 §5.2）
    // 查询本会话已知实体并格式化，让 LLM 知道已有实体的 entityId 和属性值，
    // 从而能正确发起 update_attr / append_list 等属性修改 delta。
    // sessionId 为空时（如单元测试）跳过查询，保留字面占位符。
    final knownEntitiesBlock = await _buildKnownEntitiesBlock(ctx, sessionId);
    final timelineResult = await _buildRecentTimelineBlock(ctx, sessionId);
    final recentTimelineBlock = timelineResult.timelineBlock;
    final latestNarrativeTime = timelineResult.latestNarrativeTime;
    final messages = _buildMessages(
      ctx,
      knownEntitiesBlock,
      recentTimelineBlock,
    );

    // 步骤1：工具调用模式（如果启用）
    if (toolCallingEnabled) {
      final primaryResult = await streamRunner.runWithToolCall(
        request: _buildToolCallRequest(ctx, messages),
        phaseLabel: 'summarizing',
      );

      // 1.1 解析 summary 工具调用（来自首次调用）
      EventSummary? summary;
      final hasSummary = primaryResult.hasTool('extract_event_summary');
      if (hasSummary) {
        final summaryArgs =
            primaryResult.argumentsFor('extract_event_summary')!;
        summary = _parseSummaryFromArguments(
          summaryArgs,
          turnNumber: ctx.turnNumber,
          fallbackNarrativeTime: latestNarrativeTime,
        );
        if (summary == null) {
          logger.warn('Summarize: summary 工具调用解析失败，尝试 fallback');
        }
      } else if (primaryResult.hasToolCall) {
        // 调用了其他工具（如 facts）但未调用 summary
        logger.warn('Summarize: LLM 未调用 summary 工具');
      }

      // 1.2 summary 工具未被调用或解析失败 → 尝试 fallbackText
      if (summary == null &&
          primaryResult.fallbackText != null &&
          primaryResult.fallbackText!.isNotEmpty) {
        summary = parseEventSummary(
          primaryResult.fallbackText!,
          turnNumber: ctx.turnNumber,
        );
        if (summary == null) {
          logger.warn(
            'Summarize: 工具调用未触发或解析失败，fallbackText 解析也失败',
            detail: 'fallbackLen=${primaryResult.fallbackText!.length}',
          );
        }
      }

      // 1.3 串行兜底：summary 已成功，但 facts 未被并行调用
      // 兼容不支持 parallel_tool_calls 的模型（如 agnes-2.0-flash）：
      // 模型只调用 extract_event_summary 而跳过 extract_facts，
      // 此时单独发起一次请求补调 extract_facts。
      // 失败不抛异常——summary 已成功，facts 兜底失败应只让 facts 为空，
      // 不应让整个 summarizing 阶段失败（DOC-11 §4.4 事实层失败不阻塞经历层）。
      // 注意：summary 失败时不触发兜底，直接走原有 JSON 降级路径，
      // 避免对 summary 失败场景的测试造成额外 LLM 调用。
      final hasFacts = primaryResult.hasTool('extract_facts');
      var factsResult = primaryResult;
      if (summary != null && hasSummary && !hasFacts) {
        try {
          factsResult = await _runSingleToolCall(
            ctx: ctx,
            messages: messages,
            toolDefinition: kExtractFactsToolDefinition,
            toolName: 'extract_facts',
          );
        } catch (e) {
          logger.warn(
            'Summarize: 串行兜底 extract_facts 失败',
            detail: 'turn=${ctx.turnNumber}, error=${e.runtimeType}: $e'
                '（facts 为空，summary 仍可正常返回）',
          );
          // factsResult 保持为 primaryResult（不含 facts 调用），
          // _parseFactsSafely 会输出"未调用 extract_facts"日志并返回空列表
        }
      }

      // 1.4 解析 facts 工具调用（可能来自兜底结果，失败不阻塞 summary）
      final factsDeltas = _parseFactsSafely(factsResult, ctx.turnNumber);

      // 1.5 如果 summary 已成功 → 返回（无需 JSON 降级）
      if (summary != null) {
        return SummarizePhaseResult(
          summary: summary,
          factsDeltas: factsDeltas,
        );
      }

      // 1.6 summary 完全失败 → 降级到 JSON 模式（仅产出 summary）
      // 注意：factsDeltas 仍保留前序 _parseFactsSafely 的解析结果
      // （DOC-11 §4.4：facts 工具独立于 summary，summary 降级不应丢弃已解析的事实变更）
      logger.info('Summarize: 降级到 JSON 模式（summary 降级，facts 保留）');
      final jsonSummary = await _runJsonMode(ctx, messages);
      return SummarizePhaseResult(
        summary: jsonSummary,
        factsDeltas: factsDeltas,
      );
    }

    // 直接 JSON 模式（仅产出 summary）
    final summary = await _runJsonMode(ctx, messages);
    return SummarizePhaseResult(summary: summary);
  }

  /// 安全解析 facts 工具调用结果（失败不抛异常，返回空列表）
  ///
  /// DOC-11 §4.4：事实层失败不应阻塞经历层 summarizing。
  /// 解析过程中任何异常（如 deltas 字段缺失、JSON 格式错误、FactAction 未知值）
  /// 都被捕获并记日志，返回空列表。
  List<FactsDelta> _parseFactsSafely(ToolCallResult result, int turnNumber) {
    if (!result.hasTool('extract_facts')) {
      // LLM 未调用 extract_facts 工具（提示词已要求每轮必须调用）
      // 输出 warn 日志便于排查（之前静默导致事实层始终为空且无法定位）
      logger.warn(
        'Summarize: LLM 未调用 extract_facts 工具',
        detail: 'turnNumber=$turnNumber（提示词要求每轮必须调用，'
            '无变更时也应传入空 deltas 数组）',
      );
      return const [];
    }
    final args = result.argumentsFor('extract_facts');
    if (args == null) {
      logger.warn(
        'Summarize: extract_facts 工具 arguments 为 null',
        detail: 'turnNumber=$turnNumber',
      );
      return const [];
    }

    try {
      final deltasRaw = args['deltas'];
      if (deltasRaw is! List) {
        logger.warn(
          'Summarize: facts 工具调用 deltas 字段非数组',
          detail: 'type=${deltasRaw.runtimeType}',
        );
        return const [];
      }
      if (deltasRaw.isEmpty) {
        // LLM 调用了工具但本轮无事实变更（正常情况）
        logger.info(
          'Summarize: LLM 调用了 extract_facts 但 deltas 为空',
          detail: 'turnNumber=$turnNumber（本轮无事实变更）',
        );
        return const [];
      }

      final deltas = FactsDelta.listFromJson(deltasRaw);
      logger.info(
        'Summarize: 解析 facts deltas 成功',
        detail: 'count=${deltas.length}, turnNumber=$turnNumber',
      );
      return deltas;
    } catch (e) {
      logger.warn(
        'Summarize: facts 工具调用解析失败',
        detail: 'error=${e.runtimeType}: $e',
      );
      return const [];
    }
  }

  /// 构建 summarize 请求消息（系统提示 + 用户消息 + 回复正文）
  ///
  /// 2026-07-16 优化：输入从"只看回复正文"改为"用户消息+回复正文"这一对，
  /// 避免漏掉用户发起的核心事件（如用户说"我把玉佩摔碎了"但 AI 只回安慰话）。
  /// 与 IntermediateContextBuilder.buildSummarizeMessagesV2 逻辑同源，
  /// 返回 `List<Map<String, dynamic>>`（LlmRequest 要求 dynamic）。
  /// 预览页通过 context_builder 公共方法展示相同内容。
  ///
  /// DOC-11 §4.4 双工具并行调用修复：
  /// 注入两段 system 消息——`extractSummaryPrompt`（事件摘要提取规则）+
  /// `extractFactsPrompt`（事实变更提取规则）。修复前只注入 summaryPrompt，
  /// 导致 LLM 调用 `extract_facts` 工具时看不到详细的属性 schema 白名单、
  /// 识别要点、禁止条款等指引，事实层提取质量严重下降。
  ///
  /// 2026-07-22 修复：替换 `extractFactsPrompt` 中的 `{{known_entities}}`
  /// 占位符为实际已知实体列表（DOC-11 §5.2）。修复前占位符未被替换，
  /// LLM 看到字面字符串 `{{known_entities}}`，不知道已有实体的 entityId，
  /// 无法发起 update_attr 等属性修改操作，导致 factual_attributes 表
  /// 永远无新记录。
  List<Map<String, dynamic>> _buildMessages(
    RoundContext ctx,
    String knownEntitiesBlock,
    String recentTimelineBlock,
  ) {
    // 替换 {{known_entities}} 占位符
    final extractFactsPrompt = knownEntitiesBlock.isEmpty
        ? ctx.config.prompts.extractFactsPrompt.replaceAll(
            '{{known_entities}}',
            '（暂无已知实体）',
          )
        : ctx.config.prompts.extractFactsPrompt.replaceAll(
            '{{known_entities}}',
            knownEntitiesBlock,
          );

    // 替换 {{recent_timeline}} 占位符（叙事时间机制，2026-07-25）
    final extractSummaryPrompt = recentTimelineBlock.isEmpty
        ? ctx.config.prompts.extractSummaryPrompt.replaceAll(
            '{{recent_timeline}}',
            '（首轮，暂无历史时间线）',
          )
        : ctx.config.prompts.extractSummaryPrompt.replaceAll(
            '{{recent_timeline}}',
            recentTimelineBlock,
          );

    // 2026-07-26 修订：将两段 system message 合并为一段。
    // 原注入两条 system message 时，LLM 倾向把第一条（summary）当主任务，
    // 第二条（facts）当附加项，配合 tool_choice=required（只需调用一个工具）
    // 导致 LLM 只调用 extract_event_summary 而跳过 extract_facts。
    // 合并为一段后，两个工具处于同等地位，且【输出方式】段落明确告知
    // "必须同时调用两者"（kExtractSummaryToolPrompt / kExtractFactsToolPrompt 中已交叉引用）。
    return [
      {
        'role': 'system',
        'content': '$extractSummaryPrompt\n\n$extractFactsPrompt',
      },
      {
        'role': 'user',
        'content': '【用户消息】\n${ctx.userInput}\n\n【回复正文】\n${ctx.replyText ?? ''}',
      },
    ];
  }

  /// 构建已知实体替换文本（DOC-11 §5.2）
  ///
  /// 委托给 [FactContextBuilder.buildKnownEntitiesBlock] 查询并格式化。
  /// factContextBuilder 为 null 或事实层禁用时返回空字符串。
  ///
  /// 漏洞A修复：把本轮 retrieving 阶段检索命中的实体 ID 作为
  /// focusEntityIds 传入，让低分（importance<baseThreshold）的命中实体也对
  /// 事实更新步骤可见，避免对已有实体误判为新建（如"庄园" vs "异世界庄园"）。
  Future<String> _buildKnownEntitiesBlock(
    RoundContext ctx,
    String sessionId,
  ) async {
    final builder = factContextBuilder;
    if (builder == null) return '';
    if (!ctx.config.memory.factual.enabled) return '';
    if (sessionId.isEmpty) return '';
    final focusEntityIds =
        ctx.retrievedFacts?.facts.map((f) => f.entity.entityId).toList();
    return builder.buildKnownEntitiesBlock(
      sessionId: sessionId,
      config: ctx.config.memory.factual,
      focusEntityIds: focusEntityIds,
    );
  }

  /// 构建最近叙事时间线替换文本（叙事时间机制，2026-07-25）
  ///
  /// 查询最近 5 轮的经历记忆，提取 narrativeTime 构建时间线列表，
  /// 让 LLM 能看到时间推进趋势，判断本轮时间是否推进。
  ///
  /// 格式示例：
  /// ```text
  /// 第3轮：来公寓第二天
  /// 第2轮：来公寓第二天
  /// 第1轮：来公寓第一天
  /// ```
  ///
  /// experienceRepository 为 null 或 sessionId 为空时返回空字符串。
  /// 无历史记忆时返回空字符串（首轮场景）。
  ///
  /// 审查  修复：同时返回最近一轮的 narrativeTime，
  /// 供 [_parseSummaryFromArguments] 在 LLM 未输出 narrativeTime 时做代码级兜底。
  Future<({String timelineBlock, String? latestNarrativeTime})>
      _buildRecentTimelineBlock(
    RoundContext ctx,
    String sessionId,
  ) async {
    final repo = experienceRepository;
    if (repo == null) {
      return (timelineBlock: '', latestNarrativeTime: null);
    }
    if (sessionId.isEmpty) {
      return (timelineBlock: '', latestNarrativeTime: null);
    }

    try {
      final recent = await repo.getRecentExperiences(
        sessionId,
        limit: 5,
      );
      if (recent.isEmpty) {
        return (timelineBlock: '', latestNarrativeTime: null);
      }

      // 按 turnNumber 降序排列（最近在前），只取有 narrativeTime 的
      final sorted = [...recent]
        ..sort((a, b) => b.turnNumber.compareTo(a.turnNumber));
      final withTime = sorted
          .where((m) => m.narrativeTime != null && m.narrativeTime!.isNotEmpty)
          .toList();
      if (withTime.isEmpty) {
        return (timelineBlock: '', latestNarrativeTime: null);
      }

      final lines = <String>[];
      for (final m in withTime) {
        lines.add('第${m.turnNumber}轮：${m.narrativeTime}');
      }
      return (
        timelineBlock: lines.join('\n'),
        latestNarrativeTime: withTime.first.narrativeTime,
      );
    } catch (e) {
      logger.warn(
        'Summarize: 构建时间线失败，跳过',
        detail: 'error=${e.runtimeType}: $e',
      );
      return (timelineBlock: '', latestNarrativeTime: null);
    }
  }

  /// 构建工具调用模式的 LlmRequest
  ///
  /// DOC-11 §4.4 双工具并行调用：默认同时注入 `extract_event_summary` +
  /// `extract_facts` 两个工具，LLM 自行决定调用哪些。
  /// `toolChoice=required`：强制调用至少一个工具（避免 LLM 输出纯文本）。
  ///
  /// **串行兜底支持**（2026-07-26 新增）：兼容不支持 `parallel_tool_calls`
  /// 的模型（如 agnes-2.0-flash）。当并行调用只返回了一个工具结果时，
  /// 调用方通过 [tools] 参数注入单个工具，发起第二次请求补调缺失的工具。
  /// 默认 [tools] 为双工具列表（向后兼容现有调用）。
  LlmRequest _buildToolCallRequest(
    RoundContext ctx,
    List<Map<String, dynamic>> messages, {
    List<ToolDefinition> tools = const [
      kExtractSummaryToolDefinition,
      kExtractFactsToolDefinition,
    ],
  }) {
    return LlmRequest(
      baseUrl: ctx.summarizeNamingConfig.baseUrl,
      apiKey: ctx.summarizeNamingConfig.apiKey,
      modelId: ctx.summarizeNamingConfig.modelId,
      messages: messages.map(Map<String, dynamic>.from).toList(),
      temperature: ctx.settings.temperature,
      topP: ctx.settings.topP,
      maxTokens: OutputTokenPolicy.summarizingLimit,
      modelMaxOutputTokens: ctx.summarizeNamingConfig.maxOutputTokens,
      tools: tools,
      toolChoice: ToolChoice.required,
      // v0.2.2 阶段 2-G：思考预算仅作用于 generating/reviewing 阶段。
      // summarizing 是结构化事件摘要提取任务，不需要思考预算，强制禁用。
      reasoningEffort: ReasoningEffort.disabled,
      protocol: ctx.summarizeNamingConfig.protocol,
      providerOptions: ctx.summarizeNamingConfig.providerOptions,
      connectTimeout: ctx.connectTimeout,
      readTimeout: ctx.readTimeout,
    );
  }

  /// 串行兜底：发起单工具调用请求（2026-07-26 新增）
  ///
  /// **目的**：兼容不支持 `parallel_tool_calls` 的模型（如 agnes-2.0-flash）。
  /// 当首次并行调用两个工具但模型只调用了其中一个时，调用本方法单独
  /// 发起一次请求，只注入缺失的那个工具，强制 LLM 调用它。
  ///
  /// **机制**：
  /// - 复用 [_buildMessages] 构建的消息（system prompt 已包含两个工具
  ///   的说明，让 LLM 知道完整任务上下文）
  /// - 只注入 [toolDefinition] 一个工具
  /// - `toolChoice=required` 强制调用
  /// - 失败时抛出异常由调用方处理（不内部捕获，便于日志区分）
  ///
  /// **设计权衡**：
  /// - 选择"串行兜底"而非"分两次请求"作为默认行为，是因为支持并行的
  ///   模型一次完成两个任务，无额外开销；只有不支持的模型才走兜底。
  /// - 不增加配置开关：这是模型能力兼容机制，对支持并行的模型无副作用。
  Future<ToolCallResult> _runSingleToolCall({
    required RoundContext ctx,
    required List<Map<String, dynamic>> messages,
    required ToolDefinition toolDefinition,
    required String toolName,
  }) async {
    logger.info(
      'Summarize: 串行兜底触发',
      detail: 'tool=$toolName, turn=${ctx.turnNumber}'
          '（模型未并行调用该工具，单独发起补调）',
    );
    final request = _buildToolCallRequest(
      ctx,
      messages,
      tools: [toolDefinition],
    );
    return streamRunner.runWithToolCall(
      request: request,
      phaseLabel: 'summarizing.facts',
    );
  }

  /// JSON 模式：不注入 tools，LLM 通过 LlmTextDelta 输出 JSON
  ///
  /// 响应格式不注入（response_format=null）—— 纯提示词约束。
  /// 因为 JSON 模式降级场景下供应商通常也不支持 response_format，
  /// 且提示词已强约束"第一个字符必须是 {"。
  Future<EventSummary> _runJsonMode(
    RoundContext ctx,
    List<Map<String, dynamic>> messages,
  ) async {
    final request = LlmRequest(
      baseUrl: ctx.summarizeNamingConfig.baseUrl,
      apiKey: ctx.summarizeNamingConfig.apiKey,
      modelId: ctx.summarizeNamingConfig.modelId,
      messages: messages.map(Map<String, dynamic>.from).toList(),
      temperature: ctx.settings.temperature,
      topP: ctx.settings.topP,
      maxTokens: OutputTokenPolicy.summarizingLimit,
      modelMaxOutputTokens: ctx.summarizeNamingConfig.maxOutputTokens,
      // v0.2.2 阶段 2-G：思考预算仅作用于 generating/reviewing 阶段。
      // summarizing 是结构化事件摘要提取任务，不需要思考预算，强制禁用。
      reasoningEffort: ReasoningEffort.disabled,
      protocol: ctx.summarizeNamingConfig.protocol,
      providerOptions: ctx.summarizeNamingConfig.providerOptions,
      connectTimeout: ctx.connectTimeout,
      readTimeout: ctx.readTimeout,
    );

    final result = await streamRunner.runWithToolCall(
      request: request,
      phaseLabel: 'summarizing.fallback',
    );

    if (result.fallbackText == null || result.fallbackText!.isEmpty) {
      throw const SummarizeFailedException('JSON 模式：LLM 未输出任何内容');
    }

    final parsed = parseEventSummary(
      result.fallbackText!,
      turnNumber: ctx.turnNumber,
    );
    if (parsed == null) {
      final preview = result.fallbackText!.length > 200
          ? result.fallbackText!.substring(0, 200)
          : result.fallbackText!;
      throw SummarizeFailedException('JSON 解析失败：$preview');
    }
    return parsed;
  }

  /// 从工具调用 arguments 解析事件摘要
  ///
  /// v0.2 Phase C 方案二：扩展为 5W1E 6 字段结构。
  /// 必填字段：what（替代原 summary）；其余 5W1E 字段全部可选。
  /// 兼容旧格式：若 what 缺失但 summary 存在，用 summary 反填 what。
  ///
  /// 复用 [parseEventSummary] 的字段提取逻辑（importance 夹紧、tags 容错），
  /// 但因 [parseEventSummary] 接收 JSON 字符串而非 Map，这里独立实现。
  ///
  /// importance 容错：int / double / 字符串 "3" → int 3（夹紧到 [1,5]）。
  /// event_ended 容错（DOC-10 §4.2）：bool / 字符串 "true"/"false" → bool，
  /// 缺失或类型不匹配 → false（保守默认，避免误触发宏摘要）。
  /// 失败返回 null（调用方按降级链处理）。
  EventSummary? _parseSummaryFromArguments(
    Map<String, dynamic> args, {
    required int turnNumber,
    // 审查  修复：narrativeTime 代码级兜底
    // LLM 未输出 narrativeTime 时，从最近一轮经历记忆回退
    String? fallbackNarrativeTime,
  }) {
    // 必填字段 what（v0.2 Phase C 方案二）
    // 兼容旧格式：若 what 缺失但 summary 存在，用 summary 反填 what
    final what = _coerceNonEmptyString(args['what']);
    final summary = _coerceNonEmptyString(args['summary']);
    final whatOrFallback = what ?? summary;
    if (whatOrFallback == null) return null;

    final importance = _coerceImportance(args['importance']);
    if (importance == null) return null;

    final tags = _coerceStringList(args['tags']);
    final eventEnded = _coerceBool(args['event_ended']);

    // 5W1E 其余字段（v0.2 Phase C 方案二新增）
    final when = _coerceNonEmptyString(args['when']);
    final where = _coerceNonEmptyString(args['where']);
    final who = _coerceNonEmptyString(args['who']);
    final significance = _coerceNonEmptyString(args['significance']);
    final extra = _coerceNonEmptyString(args['extra']);

    // 叙事时间（2026-07-25 新增）：LLM 输出的绝对叙事时间
    // 必填字段，但容错处理：缺失时记日志，不阻塞摘要生成
    // 审查  修复：缺失时从最近一轮回退，避免叙事时间丢失
    var narrativeTime = _coerceNonEmptyString(args['narrativeTime']);
    if (narrativeTime == null) {
      logger.warn(
        'Summarize: narrativeTime 字段缺失',
        detail: 'turnNumber=$turnNumber, '
            'fallbackApplied=${fallbackNarrativeTime != null}',
      );
      if (fallbackNarrativeTime != null && fallbackNarrativeTime.isNotEmpty) {
        narrativeTime = fallbackNarrativeTime;
        logger.info(
          'Summarize: narrativeTime 使用最近一轮回退值',
          detail: 'turnNumber=$turnNumber, fallback=$fallbackNarrativeTime',
        );
      }
    }

    return EventSummary(
      // 若 what 缺失但 summary 存在（旧格式兼容），用 summary 反填 what
      // summary 字段始终保留原值（向后兼容 + 历史小窗展示）
      what: whatOrFallback,
      summary: summary,
      importance: importance,
      tags: tags,
      turnNumber: turnNumber,
      eventEnded: eventEnded,
      when: when,
      where: where,
      who: who,
      significance: significance,
      extra: extra,
      narrativeTime: narrativeTime,
    );
  }

  /// 把任意值转换为 bool（容错：bool / 字符串 "true"/"false"）
  ///
  /// DOC-10 §4.2 新增：解析 event_ended 字段。
  /// 缺失或类型不匹配时返回 false（保守默认，避免误触发宏摘要）。
  bool _coerceBool(Object? value) {
    if (value is bool) return value;
    if (value is String) {
      final lower = value.trim().toLowerCase();
      return lower == 'true' || lower == '1';
    }
    return false;
  }

  /// 把任意值转换为非空字符串，失败返回 null
  ///
  /// 仅接受 String 类型。num/bool/null → null。
  /// 复用 stream_marker_parser 的 _coerceNonEmptyString 逻辑，
  /// 但因原函数是 private，这里内联实现。
  String? _coerceNonEmptyString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// 把任意值转换为 [1, 5] 整数，失败返回 null
  ///
  /// 复用 stream_marker_parser 的 _coerceImportance 逻辑，
  /// 但因原函数是 private，这里内联实现。
  /// 修复 LLM 输出 `importance: "3"`（字符串）、`importance: 3.5`（小数）等类型错误。
  int? _coerceImportance(Object? value) {
    if (value == null) return null;
    int num;
    if (value is int) {
      num = value;
    } else if (value is double) {
      num = value.toInt();
    } else if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed == null) return null;
      num = parsed;
    } else {
      return null;
    }
    if (num < 1) num = 1;
    if (num > 5) num = 5;
    return num;
  }

  /// 把任意值转换为字符串列表（容错：String 按逗号切分）
  ///
  /// 复用 stream_marker_parser 的 _coerceStringList 逻辑，
  /// 但因原函数是 private，这里内联实现。
  List<String> _coerceStringList(Object? value) {
    if (value == null) return const <String>[];
    if (value is List) {
      return value
          .map((e) => e is String ? e.trim() : null)
          .whereType<String>()
          .where((s) => s.isNotEmpty)
          .toList();
    }
    if (value is String) {
      final parts = value.split(RegExp('[,，]'));
      return parts.map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    }
    return const <String>[];
  }
}
