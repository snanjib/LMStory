import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/intermediate/presentation/controllers/phases/extract_phase_handler.dart'
    show ExtractPhaseHandler;
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/scored_memory.dart';

/// 生成/审查请求的消息列表与稳定 system 段元数据。
///
/// [stableSystemPrefixCount] 与 [messages] 由同一装配过程产出：请求的
/// system 消息按适配器规则过滤空文本后，前多少个连续块属于稳定段。
class IntermediatePromptAssembly {
  const IntermediatePromptAssembly({
    required this.messages,
    required this.stableSystemPrefixCount,
  });

  final List<Map<String, String>> messages;
  final int stableSystemPrefixCount;
}

/// 中级模式上下文组装器（DOC-09A-2 §4）
///
/// 为四步生成的四个 LLM 请求步骤组装消息列表：
/// - 请求1（生成 generating）：system_prompt + 最近 n 轮对话 + 用户消息
/// - 请求2（提取 extracting）：extract_keywords_prompt + 生成内容
/// - 请求3（审查 reviewing）：system_prompt + 最近 n 轮对话 + 生成内容 + 检索经历 + 用户消息
/// - 请求4（摘要 summarizing）：extract_summary_prompt + 回复正文
///
/// **token 预算控制**（仅 generating/reviewing，DOC-09A-2 §4.3）：
/// - 砍对话轮次（从最旧开始），保最近 2 轮（4 条消息）
/// - 第 2 级（砍检索经历）、第 3 级（截断生成内容）推迟到 v0.3
///
/// **系统提示词拼接**（仅 generating/reviewing）：会话 systemPrompt（共享前缀）+ 差异后缀。
/// 后缀文本由 [PromptsConfig] 提供（3 白盒化，原为硬编码常量）。
/// 不做缓存友好的稳定前置拆分（推迟到 v0.3）。详见 intermediate_prompts.dart。
class IntermediateContextBuilder {
  IntermediateContextBuilder({
    required TokenCounter tokenCounter,
    Logger? logger,
  })  : _tokenCounter = tokenCounter,
        _logger = logger ?? const Logger('IntermediateContextBuilder');

  final TokenCounter _tokenCounter;
  final Logger _logger;

  /// 最少保留的对话消息数（2 轮 = 4 条，DOC-09A-2 §4.3 第 1 级保留下限）
  static const int _minDialogueMessages = 4;

  /// 固定开销 token 上限（设计文档 §3，防止固定开销膨胀挤占历史空间）
  ///
  /// 超限时记警告日志，UI 层做精简建议（角色提示词）/再精简（压缩摘要）/
  /// 截断提示（用户输入）。不强制截断以避免破坏内容完整性。
  static const int _maxRolePromptTokens = 2000;
  static const int _maxCompactionSummaryTokens = 8000;
  static const int _maxUserInputTokens = 2000;

  /// 固定开销上限校验（超限记警告，不强制截断）
  void _checkFixedOverhead(String label, int tokens, int limit) {
    if (tokens > limit) {
      _logger.warn(
        'Fixed overhead exceeds limit',
        detail: '$label: $tokens tokens > $limit limit',
      );
    }
  }

  /// 注入前质量过滤：绝对阈值（2026-07-16 优化项5）
  ///
  /// finalScore < 0.4 的记忆不注入【相关往事】区块。
  //
  // 质量过滤已迁移到 Controller 层（_runRetrievePhase），
  // 由 RetrievalConfig.absoluteThreshold / relativeThreshold 配置驱动。
  // ContextBuilder 不再持有配置访问权，此处硬编码常量已移除，注入前不再过滤。
  // 保留注释说明历史设计决策，避免未来误加回硬编码过滤。

  /// 【相关往事】区块免责声明（2026-07-22 新增）
  ///
  /// 避免 LLM 误把往事中提到的角色当作本轮已出场角色，导致最终回复叫出
  /// 实际未在场的角色名。声明明确告知 LLM：往事中的角色仅作参考，
  /// 最终回复只应出场对话历史中实际在场的角色。
  static const String _kMemoryDisclaimer = '（以下为历史记忆参考，其中的角色不代表本轮已出场，'
      '最终回复只应出场对话历史中实际在场的角色）';

  /// 组装请求1（生成）消息列表
  ///
  /// **V1 遗留**（V2 四步重构后无调用点，仅保留供测试参考）。
  /// V2 请使用 [buildGenerateMessagesV2]。
  ///
  /// 顺序：`[system]` + `[history...]` + `[user]`
  ///
  /// [jsonFallback] = true 时使用 JSON 兜底版提示词（DOC-09B §8.6），
  /// 要求 LLM 输出完整 JSON 对象而非分隔标记格式。
  ///
  /// [globalSystemPrompt] 为「故事模式设置」中配置的全局默认提示词。
  /// 优先级：[sessionSystemPrompt] > [globalSystemPrompt] > prompts.defaultRolePrompt。
  ///
  /// [prompts]提供差异后缀与默认角色指引文本，替代原硬编码常量。
  // 第十三轮：ContextConfig 的废弃键已清理（字段/解析/
  // 发货键），V1 方法本身保留至正式发版——测试仍以它验证提示词组装
  // 语义（_buildSystemPrompt 后缀选择），届时随发版清单一并移除。
  @Deprecated('V2 四步重构后无调用点，请使用 buildGenerateMessagesV2。正式发版时移除。')
  Future<List<Map<String, String>>> buildGenerateMessages({
    required String userInput,
    required List<ChatMessage> history,
    required String? sessionSystemPrompt,
    required int contextWindow,
    required int outputReserve,
    required PromptsConfig prompts,
    String globalSystemPrompt = '',
    bool jsonFallback = false,
  }) async {
    final systemPrompt = _buildSystemPrompt(
      sessionSystemPrompt,
      globalSystemPrompt,
      jsonFallback ? prompts.draftSuffixJson : prompts.draftSuffix,
      prompts,
    );

    // v0.2.2 阶段 2-F：maxContextMessages 参数已移除，_prepareHistory 仅过滤
    final historyMessages = _prepareHistory(history);

    // 单次批量计数（：countTokensForEach 单 isolate 内加载一次
    // BPE 表逐条编码——此前 Future.wait 逐条调用，每次都在新 isolate
    // 重新解析 cl100k_base 表）
    final results = await _tokenCounter.countTokensForEach([
      systemPrompt,
      userInput,
    ]);
    final systemTokens = results[0];
    final userTokens = results[1];

    final budget = contextWindow - outputReserve;
    final remaining = budget - systemTokens - userTokens;
    // 生成请求无检索经历，dialogueBudget = remaining
    final dialogueBudget = remaining;

    final reducedHistory =
        await _reduceHistory(historyMessages, dialogueBudget);

    return [
      {'role': 'system', 'content': systemPrompt},
      ...reducedHistory.map(_toMessageMap),
      {'role': 'user', 'content': userInput},
    ];
  }

  /// 组装请求2（审查）消息列表
  ///
  /// **V1 遗留**（V2 四步重构后无调用点，仅保留供测试参考）。
  /// V2 请使用 [buildReviewMessagesV2]。
  ///
  /// 顺序：`[system]` + `[history...]` + `[system(生成内容)]` + `[system(往事)?]` + `[user]`
  ///
  /// 生成内容与检索经历以 system 角色注入（DOC-09A-2 §4.6），避免污染对话角色流。
  ///
  /// [jsonFallback] = true 时使用 JSON 兜底版提示词（DOC-09B §8.6）。
  ///
  /// [compactMode] = true 时启用 compact 降级（DOC-09A-2 §6.6，Stage 4）：
  /// 使用 compact 后缀提示词（仅要求 LLM 生成 EventSummary，不重写 reply），
  /// 且不注入检索记忆（本就为空）。生成内容仍注入供 LLM 参考生成摘要。
  /// 触发条件由 controller `_runRetrievePhase` 末尾根据 keywords/scoredMemories
  /// 是否为空决定，调用方传入。
  ///
  /// [globalSystemPrompt] 为「故事模式设置」中配置的全局默认提示词。
  /// 优先级：[sessionSystemPrompt] > [globalSystemPrompt] > prompts.defaultRolePrompt。
  ///
  /// [prompts]提供差异后缀、注入前缀/标题与默认角色指引文本。
  @Deprecated('V2 四步重构后无调用点，请使用 buildReviewMessagesV2。正式发版时移除。')
  Future<List<Map<String, String>>> buildReviewMessages({
    required String userInput,
    required String generated,
    required List<ScoredMemory> retrievedMemories,
    required List<ChatMessage> history,
    required String? sessionSystemPrompt,
    required int contextWindow,
    required int outputReserve,
    required double dialogueBudgetRatio,
    required int currentTurnNumber,
    required PromptsConfig prompts,
    String globalSystemPrompt = '',
    bool jsonFallback = false,
    bool compactMode = false,
  }) async {
    final suffix = compactMode
        ? (jsonFallback
            ? prompts.compactReviewSuffixJson
            : prompts.compactReviewSuffix)
        : (jsonFallback ? prompts.reviewSuffixJson : prompts.reviewSuffix);
    final systemPrompt = _buildSystemPrompt(
      sessionSystemPrompt,
      globalSystemPrompt,
      suffix,
      prompts,
    );

    // v0.2.2 阶段 2-F：maxContextMessages 参数已移除，_prepareHistory 仅过滤
    final historyMessages = _prepareHistory(history);

    final generatedInjection = '${prompts.generatedInjectionPrefix}$generated';
    // compact 模式下不注入检索记忆（本就为空，且 compact 提示词不要求 LLM 参考往事）
    final memoriesInjection = compactMode
        ? null
        : _formatMemories(retrievedMemories, currentTurnNumber, prompts);

    // 单次批量计数（：同上，BPE 表单次加载）
    final parts = [
      systemPrompt,
      userInput,
      generatedInjection,
      if (memoriesInjection != null) memoriesInjection,
    ];
    final results = await _tokenCounter.countTokensForEach(parts);

    final systemTokens = results[0];
    final userTokens = results[1];
    final generatedTokens = results[2];
    final memoriesTokens = memoriesInjection != null ? results[3] : 0;

    final budget = contextWindow - outputReserve;
    final remaining =
        budget - systemTokens - userTokens - generatedTokens - memoriesTokens;
    final dialogueBudget = (remaining * dialogueBudgetRatio).floor();

    final reducedHistory =
        await _reduceHistory(historyMessages, dialogueBudget);

    final messages = <Map<String, String>>[
      {'role': 'system', 'content': systemPrompt},
      ...reducedHistory.map(_toMessageMap),
      {'role': 'system', 'content': generatedInjection},
    ];
    if (memoriesInjection != null) {
      messages.add({'role': 'system', 'content': memoriesInjection});
    }
    messages.add({'role': 'user', 'content': userInput});
    return messages;
  }

  // ==================== V2 四步流程消息组装（Phase 6）====================

  /// 组装生成请求消息列表（薄包装）
  ///
  /// 与 [buildGeneratePromptAssembly] 共用一次装配实现；保留原返回类型
  /// 供提示词预览与既有调用者使用。
  Future<List<Map<String, String>>> buildGenerateMessagesV2({
    required String userInput,
    required List<ChatMessage> history,
    required String? sessionSystemPrompt,
    required int contextWindow,
    required int maxTokens,
    required PromptsConfig prompts,
    required List<ScoredMemory> retrievedMemories,
    required String factBlock,
    required int currentTurnNumber,
    String globalSystemPrompt = '',
    String? compactionSummary,
    double retrievalRatio = 0.0,
    String? continuationPrefix,
  }) async =>
      (await buildGeneratePromptAssembly(
        userInput: userInput,
        history: history,
        sessionSystemPrompt: sessionSystemPrompt,
        contextWindow: contextWindow,
        maxTokens: maxTokens,
        prompts: prompts,
        retrievedMemories: retrievedMemories,
        factBlock: factBlock,
        currentTurnNumber: currentTurnNumber,
        globalSystemPrompt: globalSystemPrompt,
        compactionSummary: compactionSummary,
        retrievalRatio: retrievalRatio,
        continuationPrefix: continuationPrefix,
      ))
          .messages;

  /// 组装生成请求消息（V2 四步流程，generating 步骤）
  ///
  /// V2 与 [buildGenerateMessages] 的差异：
  /// - 使用 [PromptsConfig.generatingSuffixV2]（纯文本生成，无 JSON/关键词）
  /// - 无 `jsonFallback` 参数（V2 generating 只输出纯文本）
  ///
  /// **v0.2.2 修订**：generating 不再注入生成后缀，让 LLM 觉得自己在进行
  /// 正常的角色扮演（与对话模式体验一致），避免"生成/初步/审查"等暗示字眼
  /// 降低生成质量。
  ///
  /// **v0.2.2 消息结构**（设计文档 §4.1，记忆块移到历史后）：
  /// `[system(角色提示词)]` + `[system(压缩摘要)?]` + `[history...]`
  /// + `[system(世界设定)?]` + `[system(往事)?]` + `[user]`
  ///
  /// 记忆块从历史前移到历史后（v0.2.2 修订），语义为"先看背景惯性，
  /// 再看本轮规则，最后看方向"，且让旧历史消息紧接压缩摘要，提升缓存命中率。
  ///
  /// **缓存命中区** = 角色提示词 + 压缩摘要 + 旧历史消息（稳定前缀）。
  /// 相比 v0.2.2 前的设计（记忆块在历史前破坏全部缓存），缓存命中区从
  /// "只有角色提示词"扩大到"角色提示词 + 压缩摘要 + 旧历史消息"。
  ///
  /// **token 预算**（设计文档 §4.3）：
  /// - 不塞满：历史不足剩余空间时全保留
  /// - 不截断：历史过长靠压缩管理（§5），仅极端兜底砍到最近 4 条
  /// - 余量不分配：模型注意力更集中，省 token
  Future<IntermediatePromptAssembly> buildGeneratePromptAssembly({
    required String userInput,
    required List<ChatMessage> history,
    required String? sessionSystemPrompt,
    required int contextWindow,
    required int maxTokens,
    required PromptsConfig prompts,
    required List<ScoredMemory> retrievedMemories,
    required String factBlock,
    required int currentTurnNumber,
    String globalSystemPrompt = '',
    String? compactionSummary,
    double retrievalRatio = 0.0,
    String? continuationPrefix,
  }) async {
    final systemPrompt = resolveRolePrompt(
      sessionSystemPrompt,
      globalSystemPrompt,
      prompts,
    );

    // 中断续写——半截正文作为前缀上下文注入用户
    // 消息（一次性救援路径，注入块随正文长度增长属预期，跳过用户输入
    // 固定开销告警防误报；token 预算照常计入）。
    final effectiveInput =
        continuationPrefix == null || continuationPrefix.isEmpty
            ? userInput
            : buildContinuationUserInput(userInput, continuationPrefix);

    // v0.2.2 阶段 2-F：maxContextMessages 参数已移除，_prepareHistory 仅过滤
    final historyMessages = _prepareHistory(history);

    final hasCompactionSummary =
        compactionSummary != null && compactionSummary.isNotEmpty;
    final hasFactBlock = factBlock.isNotEmpty;
    final memoriesInjection =
        _formatMemories(retrievedMemories, currentTurnNumber, prompts);

    // 单次批量计数（：BPE 表单次加载）
    final parts = <String>[
      systemPrompt,
      effectiveInput,
      if (hasCompactionSummary) compactionSummary,
      if (hasFactBlock) factBlock,
      if (memoriesInjection != null) memoriesInjection,
    ];
    final results = await _tokenCounter.countTokensForEach(parts);

    final systemTokens = results[0];
    final userTokens = results[1];
    var index = 2;
    final compactionTokens = hasCompactionSummary ? results[index++] : 0;
    final factBlockTokens = hasFactBlock ? results[index++] : 0;
    final memoriesTokens = memoriesInjection != null ? results[index] : 0;

    // 固定开销上限校验（设计文档 §3，超限记警告，不强制截断）
    _checkFixedOverhead('角色提示词', systemTokens, _maxRolePromptTokens);
    if (hasCompactionSummary) {
      _checkFixedOverhead(
        '压缩摘要',
        compactionTokens,
        _maxCompactionSummaryTokens,
      );
    }
    if (continuationPrefix == null || continuationPrefix.isEmpty) {
      _checkFixedOverhead('用户输入', userTokens, _maxUserInputTokens);
    }

    // budget = contextWindow - maxTokens（v0.2.2：outputReserve 废弃，统一用 maxTokens）
    final budget = contextWindow - maxTokens;
    // 检索区预算：retrievalRatio × budget
    final retrievalBudget = (budget * retrievalRatio).round();
    final actualRetrievalTokens = factBlockTokens + memoriesTokens;
    if (retrievalBudget > 0 && actualRetrievalTokens > retrievalBudget) {
      _logger.warn(
        'Retrieval tokens exceed reserved budget',
        detail: 'actual=$actualRetrievalTokens, '
            'budget=$retrievalBudget, '
            'retrievalRatio=$retrievalRatio',
      );
    }
    // 有效检索区预留：取预留值与实际值的较大者（保留检索区扩展空间）
    final effectiveRetrievalReserve = retrievalBudget > 0
        ? (actualRetrievalTokens > retrievalBudget
            ? actualRetrievalTokens
            : retrievalBudget)
        : actualRetrievalTokens;
    // assemblySpace = 历史可用空间（v0.2.2：remaining 重命名为 assemblySpace）
    final assemblySpace = budget -
        effectiveRetrievalReserve -
        systemTokens -
        userTokens -
        compactionTokens;
    final dialogueBudget = assemblySpace;

    final reducedHistory =
        await _reduceHistory(historyMessages, dialogueBudget);

    // 消息结构（v0.2.2 §4.1）：记忆块移到历史后，旧历史紧接压缩摘要提升缓存命中
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': systemPrompt},
      if (hasCompactionSummary)
        {'role': 'system', 'content': compactionSummary},
      ...reducedHistory.map(_toMessageMap),
      if (hasFactBlock) {'role': 'system', 'content': factBlock},
      if (memoriesInjection != null)
        {'role': 'system', 'content': memoriesInjection},
      {'role': 'user', 'content': effectiveInput},
    ];
    // 稳定段 = 开头连续的角色与压缩摘要；空文本被适配器过滤，不占稳定位。
    var stableSystemPrefixCount = 0;
    if (systemPrompt.isNotEmpty) stableSystemPrefixCount++;
    if (hasCompactionSummary) stableSystemPrefixCount++;
    return IntermediatePromptAssembly(
      messages: messages,
      stableSystemPrefixCount: stableSystemPrefixCount,
    );
  }

  /// 中断续写用户消息——原指令 + 已写正文前缀 +
  /// 续写指令块（明示从中断处自然继续、不重复已有内容）。domain 层常量
  ///（面向模型的 prompt，非用户可见文案）。
  static String buildContinuationUserInput(
    String userInput,
    String continuationPrefix,
  ) {
    final buffer = StringBuffer(userInput.isEmpty ? '' : '$userInput\n\n')
      ..write('【续写说明】\n')
      ..write('以下是你上一段生成中断前已经写出的正文：\n')
      ..write('<<<已写正文\n')
      ..write(continuationPrefix)
      ..write('\n已写正文>>>\n')
      ..write(
        '请接在上述正文结尾处自然续写，完成本段故事的剩余部分。'
        '不要重复、改写或概述已有内容，不要重新开头，'
        '直接从中断点继续写下去。',
      );
    return buffer.toString();
  }

  /// 组装审查请求消息列表（薄包装）
  ///
  /// 与 [buildReviewPromptAssembly] 共用一次装配实现；保留原返回类型
  /// 供提示词预览与既有调用者使用。
  Future<List<Map<String, String>>> buildReviewMessagesV2({
    required String userInput,
    required String generated,
    required List<ScoredMemory> retrievedMemories,
    required String? sessionSystemPrompt,
    required int contextWindow,
    required int maxTokens,
    required int currentTurnNumber,
    required PromptsConfig prompts,
    String globalSystemPrompt = '',
    String factBlock = '',
    double retrievalRatio = 0.0,
  }) async =>
      (await buildReviewPromptAssembly(
        userInput: userInput,
        generated: generated,
        retrievedMemories: retrievedMemories,
        sessionSystemPrompt: sessionSystemPrompt,
        contextWindow: contextWindow,
        maxTokens: maxTokens,
        currentTurnNumber: currentTurnNumber,
        prompts: prompts,
        globalSystemPrompt: globalSystemPrompt,
        factBlock: factBlock,
        retrievalRatio: retrievalRatio,
      ))
          .messages;

  /// 组装审查请求消息（V2 四步流程，reviewing 步骤）
  ///
  /// V2 与 [buildReviewMessages] 的差异：
  /// - 使用 [PromptsConfig.reviewSuffixV2]（三维度审查：事实一致性+去AI味+易读性）
  /// - 无 `jsonFallback` / `compactMode` 参数
  ///   （compact 降级时控制器直接跳过 reviewing，reply=generatedText，不调用本方法）
  /// - 总是注入检索记忆（调用本方法即意味着有检索素材）
  ///
  /// **2026-08-05 消息结构**（方案D：去掉历史+独立 system）：
  /// 去掉压缩摘要和历史对话（审查不需要，生成时已基于历史）。
  /// 审查提示词作为独立 system 消息（方案A：角色提示词命中 generating 缓存）。
  ///
  /// `[system(角色提示词)]` + `[system(审查提示词)]`
  /// + `[system(世界设定)?]` + `[system(往事)?]`
  /// + `[user(用户消息+生成内容)]`
  ///
  /// 最后一条 user 消息结构：
  /// ```text
  /// 【用户消息】
  /// [用户输入]
  ///
  /// 【需要审查的生成内容】
  /// [生成内容全文]
  /// ```
  ///
  /// **引用传递**（§7.4）：kReviewSuffixPromptV2 中的 {factInjectionTitle}
  /// / {memoriesInjectionTitle} 占位符在本方法中替换为 PromptsConfig 实际值。
  ///
  /// **token 预算**：
  /// - 去掉历史后无需 dialogueBudget 计算，仅校验检索区不超限
  /// - 保留固定开销上限校验（角色提示词、用户输入）
  Future<IntermediatePromptAssembly> buildReviewPromptAssembly({
    required String userInput,
    required String generated,
    required List<ScoredMemory> retrievedMemories,
    required String? sessionSystemPrompt,
    required int contextWindow,
    required int maxTokens,
    required int currentTurnNumber,
    required PromptsConfig prompts,
    String globalSystemPrompt = '',
    String factBlock = '',
    double retrievalRatio = 0.0,
  }) async {
    // 引用传递（§7.4）：替换 prompt 中的占位符为实际配置值
    final reviewSuffix = prompts.reviewSuffixV2
        .replaceAll('{factInjectionTitle}', prompts.factInjectionTitle)
        .replaceAll(
          '{memoriesInjectionTitle}',
          prompts.memoriesInjectionTitle,
        );

    // 角色提示词（放第一条 system，命中 generating 缓存前缀）
    final rolePrompt = resolveRolePrompt(
      sessionSystemPrompt,
      globalSystemPrompt,
      prompts,
    );

    final hasFactBlock = factBlock.isNotEmpty;
    final memoriesInjection =
        _formatMemories(retrievedMemories, currentTurnNumber, prompts);

    // 单次批量计数（：BPE 表单次加载）
    final parts = <String>[
      rolePrompt,
      userInput,
      if (hasFactBlock) factBlock,
      if (memoriesInjection != null) memoriesInjection,
    ];
    final results = await _tokenCounter.countTokensForEach(parts);

    final rolePromptTokens = results[0];
    final userTokens = results[1];
    var index = 2;
    final factBlockTokens = hasFactBlock ? results[index++] : 0;
    final memoriesTokens = memoriesInjection != null ? results[index] : 0;

    // 固定开销上限校验
    _checkFixedOverhead('角色提示词', rolePromptTokens, _maxRolePromptTokens);
    _checkFixedOverhead('用户输入', userTokens, _maxUserInputTokens);

    // 检索区预算校验（去掉历史后无需 dialogueBudget，仅校验检索区不超限）
    final budget = contextWindow - maxTokens;
    final retrievalBudget = (budget * retrievalRatio).round();
    final actualRetrievalTokens = factBlockTokens + memoriesTokens;
    if (retrievalBudget > 0 && actualRetrievalTokens > retrievalBudget) {
      _logger.warn(
        'Retrieval tokens exceed reserved budget (review)',
        detail: 'actual=$actualRetrievalTokens, '
            'budget=$retrievalBudget, '
            'retrievalRatio=$retrievalRatio',
      );
    }

    // 消息结构（2026-08-05 方案D）：去掉历史+压缩摘要
    // [system]角色提示词（命中 generating 缓存）+ [system]审查提示词
    // + [system]事实类? + [system]经历类? + [user]用户消息+生成内容
    final messages = <Map<String, String>>[
      {'role': 'system', 'content': rolePrompt},
      {'role': 'system', 'content': reviewSuffix},
      if (hasFactBlock) {'role': 'system', 'content': factBlock},
      if (memoriesInjection != null)
        {'role': 'system', 'content': memoriesInjection},
      {
        'role': 'user',
        //  修复：用可编辑的注入前缀段替代硬编码字面量，
        // 第 6 段提示词（generatedInjectionPrefix）从此真实生效
        'content': '【用户消息】\n$userInput\n\n'
            '${prompts.generatedInjectionPrefix}$generated',
      },
    ];
    // 稳定段 = 开头连续的角色提示词与审查规则段；空文本不占稳定位。
    var stableSystemPrefixCount = 0;
    if (rolePrompt.isNotEmpty) stableSystemPrefixCount++;
    if (reviewSuffix.isNotEmpty) stableSystemPrefixCount++;
    return IntermediatePromptAssembly(
      messages: messages,
      stableSystemPrefixCount: stableSystemPrefixCount,
    );
  }

  /// 组装关键词提取请求消息（V2 四步流程，extracting 步骤）
  ///
  /// 2026-08-05 改造（缓存优化）：
  /// - 从"提示词+用户消息+最近5轮对话揉成1条user"改为
  ///   "提示词+压缩摘要?+历史对话(独立消息)+用户消息"
  /// - 历史对话用独立消息（不塞进1条user），旧消息跨轮不变，命中 prompt cache
  /// - 与 [ExtractPhaseHandler] 的 _buildMessages 保持一致（预览页展示用）
  ///
  /// 2026-08-23 修订（预览即所得 + 回滚对齐）：与请求侧同步——末条 user
  /// 消息带任务前缀包装（ExtractPhaseHandler 2026-08-23 回滚后结构，
  /// 详见其注释：真机验证 raw user 消息会诱发正文续写）。此前预览侧
  /// 一直显示原文、与实际请求不一致，本次一并对齐。
  ///
  /// 顺序：`[system(extractKeywordsPrompt)]` + `[system(compactionSummary)?]`
  /// + `[history...]` + `[user(任务包装+userInput)]`
  List<Map<String, String>> buildExtractMessagesV2({
    required String userInput,
    required List<ChatMessage> history,
    required PromptsConfig prompts,
    String? compactionSummary,
  }) {
    final hasCompactionSummary =
        compactionSummary != null && compactionSummary.isNotEmpty;
    final filtered = history
        .where(
          (m) =>
              (m.role == 'user' || m.role == 'assistant') &&
              (m.content?.isNotEmpty ?? false),
        )
        .toList();
    return [
      {'role': 'system', 'content': prompts.extractKeywordsPrompt},
      if (hasCompactionSummary)
        {'role': 'system', 'content': compactionSummary},
      ...filtered.map(_toMessageMap),
      {
        'role': 'user',
        'content': '【提取关键词任务 - 从以下用户消息提取关键词，'
            ' 不是角色扮演对话续写】\n\n$userInput',
      },
    ];
  }

  /// 组装事件摘要请求消息（V2 四步流程，summarizing 步骤）
  ///
  /// summarizing 步骤不涉及对话历史和 token 预算控制——它是一个简单的
  /// system+user 两条消息请求，system 为事件摘要提示词，user 为
  /// "用户消息+回复正文"这一对内容。
  ///
  /// 2026-07-16 优化：输入从"只看回复正文"改为"用户消息+回复正文"，
  /// 避免漏掉用户发起的核心事件。
  ///
  /// 工具调用模式（`toolCallingEnabled=true`）下，控制器会在 LlmRequest 中
  /// 额外注入 `tools=[kExtractSummaryToolDefinition]`，但 messages 本身不变。
  /// 预览页展示的 messages 与工具调用模式无关——两种模式 messages 相同。
  ///
  /// 顺序：`[system(extractSummaryPrompt)]` + `[user(【用户消息】\n$userInput\n\n【回复正文】\n$reply)]`
  List<Map<String, String>> buildSummarizeMessagesV2({
    required String userInput,
    required String reply,
    required PromptsConfig prompts,
  }) {
    return [
      {'role': 'system', 'content': prompts.extractSummaryPrompt},
      {
        'role': 'user',
        'content': '【用户消息】\n$userInput\n\n【回复正文】\n$reply',
      },
    ];
  }

  /// 构建系统提示词：前缀（会话 > 全局 > 默认）+ 差异后缀
  ///
  /// 优先级（DOC-09B §10.2）：
  /// 1. [sessionSystemPrompt] 非空 → 用会话级（每会话可覆盖）
  /// 2. [globalSystemPrompt] 非空 → 用全局级（「故事模式设置」中配置）
  /// 3. 都为空 → 用 prompts.defaultRolePrompt（原为 kDefaultRolePrompt 常量）
  String _buildSystemPrompt(
    String? sessionSystemPrompt,
    String globalSystemPrompt,
    String suffix,
    PromptsConfig prompts,
  ) {
    final prefix = resolveRolePrompt(
      sessionSystemPrompt,
      globalSystemPrompt,
      prompts,
    );
    return '$prefix$suffix';
  }

  /// 解析角色提示词（不含后缀）
  ///
  /// v0.2.2 改为 public static：compaction_service 的 shouldCompact 需要
  /// 解析角色提示词以统计基础上下文 token，提取为静态方法供跨类复用。
  ///
  /// 优先级：
  /// 1. [sessionSystemPrompt] 非空 → 用会话级
  /// 2. [globalSystemPrompt] 非空 → 用全局级
  /// 3. 都为空 → 用 prompts.defaultRolePrompt
  static String resolveRolePrompt(
    String? sessionSystemPrompt,
    String globalSystemPrompt,
    PromptsConfig prompts,
  ) {
    return (sessionSystemPrompt != null && sessionSystemPrompt.isNotEmpty)
        ? sessionSystemPrompt
        : (globalSystemPrompt.isNotEmpty
            ? globalSystemPrompt
            : prompts.defaultRolePrompt);
  }

  /// 过滤历史消息：仅保留 user/assistant 且内容非空
  ///
  /// v0.2.2 阶段 2-F：移除 maxContextMessages 截断逻辑。
  /// 故事模式引入 CompactionPoint 压缩机制后，原文区由
  /// recentMinRatio + compactionTriggerRatio 动态控制，不再需要
  /// 硬性消息数截断。极端超长场景由 [_reduceHistory] 兜底。
  List<ChatMessage> _prepareHistory(List<ChatMessage> history) {
    return history
        .where(
          (m) =>
              (m.role == 'user' || m.role == 'assistant') &&
              (m.content?.isNotEmpty ?? false),
        )
        .toList();
  }

  /// token 预算极端兜底：历史超 assemblySpace 时砍到最近 2 轮（4 条）
  ///
  /// v0.2.2 修订（设计文档 §5.4）：有压缩机制后不再需要按比例截断，
  /// 仅保留极端兜底——当历史 token 超过 assemblySpace 时保底保留最近
  /// [_minDialogueMessages] 条，防止超 contextWindow。
  ///
  /// 正常流程：历史涨到压缩线 → 触发压缩 → 压缩后回到下限 → 继续对话。
  /// 本方法仅在压缩被关闭或压缩失败的极端情况下生效。
  Future<List<ChatMessage>> _reduceHistory(
    List<ChatMessage> history,
    int assemblySpace,
  ) async {
    if (history.isEmpty) return const [];
    // 预算非正：保底返回最近 4 条（或全部，若不足 4 条）
    if (assemblySpace <= 0) {
      return history.length > _minDialogueMessages
          ? history.sublist(history.length - _minDialogueMessages)
          : history;
    }

    final historyText = history.map(_messageToText).join('\n');
    final totalTokens = await _tokenCounter.countTokens(historyText);

    // 不塞满：历史不足 assemblySpace 时全保留
    if (totalTokens <= assemblySpace) return history;

    // 极端兜底：保底最近 4 条（正常情况靠压缩管理，不走到这里）
    return history.sublist(history.length - _minDialogueMessages);
  }

  /// 格式化检索经历为"【相关往事】"区块（DOC-09A-1 §3.2）
  ///
  /// 无记忆时返回 null（不注入）。
  /// [prompts]提供往事注入标题文本，原为 kMemoriesInjectionTitle 常量。
  ///
  /// 注入前质量过滤（双阈值）已迁移到 Controller 层
  /// （`_runRetrievePhase`，由 `RetrievalConfig.absoluteThreshold` /
  /// `relativeThreshold` 配置驱动）。本方法不再做质量过滤，调用方传入的
  /// `memories` 已经过滤完毕。
  ///
  /// **多粒度共存**：移除原 DOC-10 §5.3 多粒度去重逻辑，
  /// macro 与 micro 记忆共存注入，分别标注为"段落摘要"和"事件记忆"，
  /// 让 LLM 同时获得段落级概览和事件级细节。原去重逻辑（macro 覆盖 micro）
  /// 已废弃。
  ///
  /// v0.2 Phase C 方案二：注入格式从单行 summary 改为
  /// 多行结构化 5W1E 字段。每条记忆按字段非空情况展开为多行，提升 LLM
  /// 对细节信息的可见度。原 summary 字段保留作为兜底展示文本。
  String? _formatMemories(
    List<ScoredMemory> memories,
    int currentTurnNumber,
    PromptsConfig prompts,
  ) {
    if (memories.isEmpty) return null;

    // 多粒度共存：macro 与 micro 分别格式化，不再去重
    final macroMemories = memories.where((sm) => sm.memory.isMacro).toList();
    final microMemories = memories.where((sm) => !sm.memory.isMacro).toList();

    final lines = <String>[
      prompts.memoriesInjectionTitle,
      _kMemoryDisclaimer,
    ];

    // 段落摘要（macro）
    if (macroMemories.isNotEmpty) {
      lines.add('── 段落摘要 ──');
      for (final sm in macroMemories) {
        lines.add(_formatMacroMemory(sm.memory));
      }
    }

    // 事件记忆（micro）
    if (microMemories.isNotEmpty) {
      lines.add('── 事件记忆 ──');
      for (final sm in microMemories) {
        final turnsAgo = currentTurnNumber - sm.memory.turnNumber;
        lines.add(_formatSingleMemory(sm.memory, turnsAgo));
      }
    }

    return lines.join('\n');
  }

  /// 格式化单条宏摘要记忆（macro）为注入文本
  ///
  /// macro 记忆是若干相邻微摘要的聚合概览，通常只有 summary 字段，
  /// 没有 5W1E 细节字段。输出格式：
  /// ```text
  /// [第3轮·重要性3]
  /// {summary 文本}
  /// ```
  ///
  /// 若 summary 为空，回退使用 [ExperientialMemory.displayText]。
  String _formatMacroMemory(ExperientialMemory memory) {
    final buffer = StringBuffer()
      ..writeln('[第${memory.turnNumber}轮·重要性${memory.importance}]')
      ..write(memory.summary ?? memory.displayText);
    return buffer.toString();
  }

  /// 格式化单条经历记忆为多行结构化文本（v0.2 Phase C 方案二）
  ///
  /// 输出格式示例（5W1E 字段非空才输出对应行）：
  /// ```text
  /// [来公寓第三天·来源第37轮·重要性4]
  /// · 何事：勇者斩杀了巨龙
  /// · 何时：战斗结束时
  /// · 何地：火山口
  /// · 何人：勇者与巨龙
  /// · 为何重要：获得了关键道具
  /// · 补充：巨龙临死前留下一句预言
  /// ```
  ///
  /// 标题行标签优先级（叙事时间机制，2026-07-25）：
  /// 1. narrativeTime（绝对叙事时间，如"来公寓第三天"）--首选
  /// 2. turnsAgo（相对时序，如"3轮前"）--narrativeTime 缺失时回退
  /// 3. 可靠的单轮来源另标注来源轮号，来源未知时省略
  ///
  /// 设计原则：
  /// - 每条记忆独立成块，用空行分隔（提升 LLM 注意力分配）
  /// - 仅展示非空字段（避免空行污染）
  /// - 字段标签用中文（与提示词中字段说明一致，便于 LLM 关联）
  /// - 若所有 5W1E 字段都为空，回退使用 displayText（兼容旧数据）
  String _formatSingleMemory(ExperientialMemory memory, int turnsAgo) {
    // 标题行：优先用 narrativeTime（绝对时间），回退用 turnsAgo（相对时序）
    final timeLabel =
        (memory.narrativeTime != null && memory.narrativeTime!.isNotEmpty)
            ? memory.narrativeTime
            : '$turnsAgo轮前';
    final canShowSource = memory.hasVerifiedSourceTurn &&
        memory.source == 'auto' &&
        !memory.isSummary &&
        memory.turnNumber > 0;
    final sourceLabel = canShowSource ? '·来源第${memory.turnNumber}轮' : '';
    final buffer = StringBuffer()
      ..writeln('[$timeLabel$sourceLabel·重要性${memory.importance}]');

    final fields = <String>[
      if (memory.what != null && memory.what!.isNotEmpty) '· 何事：${memory.what}',
      if (memory.when != null && memory.when!.isNotEmpty) '· 何时：${memory.when}',
      if (memory.where != null && memory.where!.isNotEmpty)
        '· 何地：${memory.where}',
      if (memory.who != null && memory.who!.isNotEmpty) '· 何人：${memory.who}',
      if (memory.significance != null && memory.significance!.isNotEmpty)
        '· 为何重要：${memory.significance}',
      if (memory.extra != null && memory.extra!.isNotEmpty)
        '· 补充：${memory.extra}',
    ];

    if (fields.isEmpty) {
      // 所有 5W1E 字段都为空（旧数据兼容），回退使用 summary 或 displayText
      buffer.write('· ${memory.summary ?? memory.displayText}');
    } else {
      buffer.write(fields.join('\n'));
    }

    return buffer.toString();
  }

  /// ChatMessage → API 消息 Map
  ///
  /// **不注入 reasoning_content 的决策说明**：
  /// Intermediate 模式的 generating/reviewing 输出纯文本（用 `runPlainText`，
  /// 不带 tool_calls）。根据 DeepSeek V4 thinking 模式官方文档：
  /// "在两个 user 消息之间，如果模型未进行工具调用，则中间 assistant 的
  /// reasoning_content 无需参与上下文拼接，在后续轮次中将其传入 API 会被忽略。"
  /// 因此此处不注入 reasoning_content 是符合规范的。
  ///
  /// **v0.3 注意**：若未来 Intermediate 模式引入 Agent Loop（多轮工具调用），
  /// 带 tool_calls 的 assistant 消息必须回传 reasoning_content，届时需改造
  /// 本方法或新增专用转换方法，返回 `Map<String, dynamic>` 并注入
  /// `reasoning_content` 字段（参考 Simple 模式 chat_mode_controller 的
  /// `_buildMessagesForApi` 实现）。
  Map<String, String> _toMessageMap(ChatMessage m) =>
      {'role': m.role, 'content': m.content ?? ''};

  /// ChatMessage → 纯文本（用于 token 计数）
  String _messageToText(ChatMessage m) => '${m.role} ${m.content ?? ''}';
}
