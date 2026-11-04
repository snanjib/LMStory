import 'dart:async';

import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/config/intermediate_prompts_v2.dart';
import 'package:lmstory/core/config/output_token_policy.dart';
import 'package:lmstory/core/llm/tool_calling/tool_choice.dart';
import 'package:lmstory/core/llm/tool_schema_rejection.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/intermediate/domain/services/stream_marker_parser.dart';
import 'package:lmstory/features/story_runtime/domain/entities/classified_keywords.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_context.dart';
import 'package:lmstory/features/story_runtime/presentation/controllers/stream_runner.dart';

/// 关键词提取失败异常（Phase 6 Step 6.2 新增）
///
/// 由 [ExtractPhaseHandler] 抛出，控制器 catch 后调用 `_fail(E013)`。
/// 携带 [reason] 供日志与失败上下文展示。
class ExtractFailedException implements Exception {
  const ExtractFailedException(this.reason);
  final String reason;

  @override
  String toString() => 'ExtractFailed: $reason';
}

/// 关键词提取阶段处理器（Phase 6 Step 6.2 新增，前置改造）
///
/// 从用户当前消息中提取 5 类检索关键词，输出 [ClassifiedKeywords]。
/// 降级链：工具调用 -> JSON 模式。
///
/// **工具调用模式**（[StreamConfig.toolCallingEnabled] = true）：
/// - 注入 `tools=[kExtractKeywordsToolDefinition]`, `toolChoice=required`
/// - [StreamRunner.runWithToolCall] 返回 [ToolCallResult]
/// - `hasToolCall=true` -> 解析 `arguments {characters, items, locations, actions, plots}` -> [ClassifiedKeywords]
/// - `hasToolCall=false` -> LLM 未调用工具（可能不支持），降级到 JSON 模式
///   - 解析 `fallbackText` 为 JSON（LLM 通常会直接输出 JSON 文本）
///   - 解析失败 -> 抛 [ExtractFailedException]
///
/// **JSON 模式**（`toolCallingEnabled=false` 或工具调用降级）：
/// - 不注入 tools，注入 `response_format=json_object`（供应商支持时）
/// - LLM 通过 `LlmTextDelta` 输出 JSON，累积为 `fallbackText`
/// - 解析 `fallbackText` 为 JSON -> [ClassifiedKeywords]
/// - 解析失败 -> 抛 [ExtractFailedException]
///
/// **不接入控制器主流程**：本类只提供 `run` 方法，由 Step 6.4 控制器
/// 在 `_runExtractPhase` 中调用。工具调用探测（供应商降级标志）
/// 留到 Step 6.4 接入控制器时实现。
class ExtractPhaseHandler {
  const ExtractPhaseHandler({
    required this.streamRunner,
    required this.logger,
  });

  final StreamRunner streamRunner;
  final Logger logger;

  /// 执行关键词提取
  ///
  /// [toolCallingEnabled] = true 时先尝试工具调用，失败降级到 JSON 模式。
  /// [toolCallingEnabled] = false 时直接走 JSON 模式。
  Future<ClassifiedKeywords> run({
    required RoundContext ctx,
    required bool toolCallingEnabled,
  }) async {
    final messages = _buildMessages(ctx);

    // 步骤1：工具调用模式（如果启用）
    if (toolCallingEnabled) {
      final ToolCallResult result;
      try {
        result = await streamRunner.runWithToolCall(
          request: _buildToolCallRequest(ctx, messages),
          phaseLabel: 'extracting',
        );
      } on StreamErrorException catch (e) {
        // 供应商拒收工具 schema（400 + schema 关键字）是确定性问题，
        // 重发同一载荷必然再失败——直接走 JSON 降级，不进 E016 重试。
        if (!isToolSchemaRejectionText(e.message)) rethrow;
        logger.warn(
          'Extract: tool schema rejected by provider, falling back to JSON mode',
          detail: e.message,
        );
        return _runJsonMode(ctx, messages);
      }
      final args = result.arguments;
      if (result.hasToolCall && args != null) {
        // 工具调用成功：信任 arguments 解析结果（即使为空，也是 LLM 的有意输出）
        return _parseKeywordsFromArguments(args);
      } else if (result.fallbackText != null &&
          result.fallbackText!.isNotEmpty) {
        // 工具调用未触发，但 LLM 输出了文本（可能是 JSON）-> 尝试解析
        // parseKeywords 返回 null 表示格式不匹配，返回非 null（即使空）表示有效解析
        final parsed = parseKeywords(result.fallbackText!);
        if (parsed != null) return parsed;
        logger.warn(
          'Extract: 工具调用未触发，fallbackText 解析失败',
          detail: 'fallbackLen=${result.fallbackText!.length}',
        );
      }
      // 工具调用完全失败 -> 降级到 JSON 模式
      logger.info('Extract: 降级到 JSON 模式');
      return _runJsonMode(ctx, messages);
    }

    // 直接 JSON 模式
    return _runJsonMode(ctx, messages);
  }

  /// 构建 extract 请求消息
  ///
  /// 2026-08-05 改造（缓存优化）：
  /// - 从"提示词+用户消息+最近5轮对话揉成1条user"改为
  ///   "提示词+压缩摘要?+历史对话(独立消息)+用户消息"
  /// - 历史对话用独立消息（不塞进1条user），旧消息跨轮不变，命中 prompt cache
  /// - 提示词强调：关键词仅从用户消息提取，历史仅供揣测语境
  /// - ctx.history 已被 compacting 阶段处理（超阈值会压缩），无需额外裁剪
  ///
  /// 2026-08-05 修复（消息隔离）：历史对话独立后，最后的 user 消息
  /// 不带任务前缀（改动前是"【用户当前消息】"包装的），容易被模型误判为
  /// 角色扮演对话续写。加上任务标记明确这是关键词提取任务。
  ///
  /// 2026-08-23 回滚（真机回归）：2026-08-22 曾把任务标记改为"提示词后的
  /// 独立 system 消息 + 末条 user 消息保持原文"以换取跨轮缓存对齐，真机
  /// 验证复现了 08-05 记录的失败模式——模型无视远处的 system 说明，把
  /// 原文末条 user 消息当角色扮演续写，输出正文而非关键词 JSON，extract
  /// 持续 E013。恢复相邻包装：任务标记必须紧贴输入内容。缓存代价仅为
  /// extract 每轮一条 user 消息，正确性优先。
  List<Map<String, dynamic>> _buildMessages(RoundContext ctx) {
    final hasCompactionSummary =
        ctx.compactionSummary != null && ctx.compactionSummary!.isNotEmpty;
    final filteredHistory = ctx.history
        .where(
          (m) =>
              (m.role == 'user' || m.role == 'assistant') &&
              (m.content?.isNotEmpty ?? false),
        )
        .toList();
    return [
      {'role': 'system', 'content': ctx.config.prompts.extractKeywordsPrompt},
      if (hasCompactionSummary)
        {'role': 'system', 'content': ctx.compactionSummary},
      ...filteredHistory.map(
        (m) => {'role': m.role, 'content': m.content ?? ''},
      ),
      {
        'role': 'user',
        'content': '【提取关键词任务 - 从以下用户消息提取关键词，'
            ' 不是角色扮演对话续写】\n\n${ctx.userInput}',
      },
    ];
  }

  /// 构建工具调用模式的 LlmRequest
  LlmRequest _buildToolCallRequest(
    RoundContext ctx,
    List<Map<String, dynamic>> messages,
  ) {
    return LlmRequest(
      baseUrl: ctx.extractNamingConfig.baseUrl,
      apiKey: ctx.extractNamingConfig.apiKey,
      modelId: ctx.extractNamingConfig.modelId,
      messages: messages.map(Map<String, dynamic>.from).toList(),
      temperature: ctx.settings.temperature,
      topP: ctx.settings.topP,
      maxTokens: OutputTokenPolicy.extractingLimit,
      modelMaxOutputTokens: ctx.extractNamingConfig.maxOutputTokens,
      tools: const [kExtractKeywordsToolDefinition],
      toolChoice: ToolChoice.required,
      // v0.2.2 阶段 2-G：思考预算仅作用于 generating/reviewing 阶段。
      // extracting 是结构化关键词提取任务，不需要思考预算，强制禁用。
      reasoningEffort: ReasoningEffort.disabled,
      protocol: ctx.extractNamingConfig.protocol,
      providerOptions: ctx.extractNamingConfig.providerOptions,
      connectTimeout: ctx.connectTimeout,
      readTimeout: ctx.readTimeout,
    );
  }

  /// JSON 模式：不注入 tools，LLM 通过 LlmTextDelta 输出 JSON
  ///
  /// 响应格式不注入（response_format=null）-- 纯提示词约束。
  /// 因为 JSON 模式降级场景下供应商通常也不支持 response_format，
  /// 且提示词已强约束"第一个字符必须是 {"。
  Future<ClassifiedKeywords> _runJsonMode(
    RoundContext ctx,
    List<Map<String, dynamic>> messages,
  ) async {
    final request = LlmRequest(
      baseUrl: ctx.extractNamingConfig.baseUrl,
      apiKey: ctx.extractNamingConfig.apiKey,
      modelId: ctx.extractNamingConfig.modelId,
      messages: messages.map(Map<String, dynamic>.from).toList(),
      temperature: ctx.settings.temperature,
      topP: ctx.settings.topP,
      maxTokens: OutputTokenPolicy.extractingLimit,
      modelMaxOutputTokens: ctx.extractNamingConfig.maxOutputTokens,
      // v0.2.2 阶段 2-G：思考预算仅作用于 generating/reviewing 阶段。
      // extracting 是结构化关键词提取任务，不需要思考预算，强制禁用。
      reasoningEffort: ReasoningEffort.disabled,
      protocol: ctx.extractNamingConfig.protocol,
      providerOptions: ctx.extractNamingConfig.providerOptions,
      connectTimeout: ctx.connectTimeout,
      readTimeout: ctx.readTimeout,
    );

    final result = await streamRunner.runWithToolCall(
      request: request,
      phaseLabel: 'extracting.fallback',
    );

    if (result.fallbackText == null || result.fallbackText!.isEmpty) {
      throw const ExtractFailedException('JSON 模式：LLM 未输出任何内容');
    }

    final parsed = parseKeywords(result.fallbackText!);
    if (parsed == null) {
      throw ExtractFailedException(
        'JSON 解析失败：${result.fallbackText!.substring(0, result.fallbackText!.length > 200 ? 200 : result.fallbackText!.length)}',
      );
    }
    return parsed;
  }

  /// 从工具调用 arguments 解析关键词（5 类关键词）
  ///
  /// 解析 5 类分类关键词：characters/items/locations/actions/plots。
  /// 与记忆库分类结构对齐，供 retrieving 阶段 5 路并行检索使用。
  ClassifiedKeywords _parseKeywordsFromArguments(Map<String, dynamic> args) {
    return ClassifiedKeywords(
      characters: _coerceStringList(args['characters']),
      items: _coerceStringList(args['items']),
      locations: _coerceStringList(args['locations']),
      actions: _coerceStringList(args['actions']),
      plots: _coerceStringList(args['plots']),
    );
  }

  /// 把任意值转换为字符串列表（容错：String 按逗号切分）
  ///
  /// 复用 stream_marker_parser 的 _coerceStringList 逻辑，
  /// 但因原函数是 private，这里内联实现（Step 6.5 删除标记模式后
  /// 可考虑提取到独立 json_repair.dart）。
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
