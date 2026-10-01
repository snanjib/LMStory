import 'dart:async';

import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/config/intermediate_prompts_v2.dart';
import 'package:lmstory/core/config/output_token_policy.dart';
import 'package:lmstory/core/network/http_client.dart' show CancellationToken;
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/story_runtime/domain/services/round_history_utils.dart'
    as turn_utils;
import 'package:uuid/uuid.dart';

/// CompactionPoint 压缩结果
///
/// 由 [StoryCompactionService.compact] 返回，包含压缩摘要和压缩后的历史。
class CompactionResult {
  const CompactionResult({
    required this.summary,
    required this.boundaryMessageId,
    required this.compactedHistory,
    this.segmentMacroSummary,
    this.hitRetentionFloor = false,
  });

  /// 压缩摘要文本（剧情宏观骨架，累积式）
  final String summary;

  /// 压缩边界消息 ID（最后一条被压缩的消息）
  ///
  /// persisting 阶段据此创建 CompactionPoint 记录。
  final String boundaryMessageId;

  /// 压缩后的历史消息列表
  ///
  /// `[summary message, ...boundary 之后的消息]`，
  /// 用于替换 RoundContext.history。
  final List<ChatMessage> compactedHistory;

  /// 分段宏摘要（仅覆盖本次压缩新增轮次的实际对话）
  ///
  /// v0.2.3 新增：分离压缩摘要与宏摘要职责。
  /// - **null**：首次压缩，压缩摘要兼作宏摘要（同一内容，无需单独生成）
  /// - **非空**：后续压缩，分段宏摘要仅基于新增轮次的实际对话内容生成，
  ///   与累积式压缩摘要分离。用于记忆检索（标注为「段落摘要」）和
  ///   记忆查看器编年史展示。
  ///
  /// 生成失败时为 null（仅首次压缩，压缩摘要兼作宏摘要）。
  final String? segmentMacroSummary;

  /// 保留量触底警示
  ///
  /// true = 本次压缩的保留量上限（触发线 − 检索预留 − 基础上下文）已 ≤ 0，
  /// 近期对话保留区被压到保底 4 条。此时后续轮次极易再次触发压缩
  /// （死亡螺旋边缘），控制器据此在压缩摘要卡上向用户显示警示。
  final bool hitRetentionFloor;
}

/// 中级模式 CompactionPoint 压缩服务
///
/// 实现 CompactionPoint 上下文压缩策略（会议纪要 §5.4-5.5）：
///
/// 1. **阈值检测**：当总占用（基础上下文 + 检索区 + 历史）token 数超过
///    `contextWindow × compactionTriggerRatio`（默认 0.5）时触发压缩
/// 2. **边界计算**：保留近期对话（`availableWindow × recentMinRatio`），
///    压缩更早的消息
/// 3. **LLM 压缩**：调用 LLM 将旧对话压缩为剧情宏观骨架摘要
/// 4. **历史替换**：返回 `[summary, ...recent messages]` 作为压缩后历史
///
/// **v0.2.3 压缩摘要与宏摘要职责分离**：
/// - **压缩摘要**（累积式）：基于"旧摘要+新对话"生成，用于上下文注入（稳定前缀）
/// - **分段宏摘要**（分段式）：仅基于"新对话"生成，用于记忆检索+记忆查看器编年史
/// - 首次压缩：压缩摘要兼作宏摘要（同一内容，无需单独生成）
/// - 后续压缩：并行生成两个摘要（不增加等待时间）
/// - 分段宏摘要是压缩事务的一部分，失败时整个压缩操作失败（E018）
///
/// **事务性**（§7.1）：
/// compacting 阶段仅生成摘要存内存（RoundContext），不写 DB。
/// persisting 阶段将摘要写入 chat_messages + compaction_points +
/// experiential_memories，与回复写入在同一事务内。
///
/// 设计
class StoryCompactionService {
  StoryCompactionService({
    required TokenCounter tokenCounter,
    required LlmService llmService,
    Logger? logger,
  })  : _tokenCounter = tokenCounter,
        _llmService = llmService,
        _logger = logger ?? const Logger('StoryCompactionService'),
        _uuid = const Uuid();

  final TokenCounter _tokenCounter;
  final LlmService _llmService;
  final Logger _logger;
  final Uuid _uuid;

  /// 最少保留的对话消息数（2 轮 = 4 条）
  ///
  /// 与 IntermediateContextBuilder._minDialogueMessages 一致，
  /// 确保压缩后仍保留足够的近期上下文。
  static const int _minRecentMessages = 4;

  /// 手动压缩入口的最少对话消息数（上下文用量指示 §4.3；与
  /// shouldCompact/compact 的 `_minRecentMessages * 2` 同源）
  static int get minDialogueMessages => _minRecentMessages * 2;

  /// 压缩后增长跑道比例（2026-08-22 死亡螺旋修复）
  ///
  /// 保留量上限 = (触发线 − 检索预留 − 基础上下文×[_summaryGrowthAllowanceRatio])
  /// × 本比例。0.7 表示压缩后总占用约为触发线的七成，剩余三成是再次触发前
  /// 的增长跑道（期间 shouldCompact 为 false，前缀缓存可稳定累积）。
  static const double _postCompactionRunwayRatio = 0.7;

  /// 基础上下文的摘要增长余量系数（2026-08-22 死亡螺旋修复）
  ///
  /// 压缩时传入的基础上下文按旧摘要计；累积式压缩后新摘要通常略长，
  /// 按 1.2 倍预留，避免"压缩刚完成就因摘要变长再次触发"。
  static const double _summaryGrowthAllowanceRatio = 1.2;

  /// 从按 CompactionPoint 过滤后的历史中提取持久化压缩摘要（2026-08-22 新增）
  ///
  /// [filterByCompactionPoint] 返回 `[summary, ...boundary 之后的消息]`，
  /// 摘要消息 role=system 且 isSummary=true，会被 generating/extracting 的
  /// user/assistant 过滤器静默丢弃。控制器必须在轮次启动时调用本方法，
  /// 把摘要回填到 RoundContext.compactionSummary：
  /// - 供消息组装注入为稳定前缀 system 消息（缓存命中 + 已压缩剧情不丢）
  /// - 供 shouldCompact/compact 计入基础上下文 / 走累积式压缩分支
  ///
  /// 无摘要消息或内容为空时返回 null。
  static String? extractPersistedSummary(List<ChatMessage> history) {
    for (final m in history) {
      if (m.isSummary && (m.content?.isNotEmpty ?? false)) {
        return m.content;
      }
    }
    return null;
  }

  /// 计算可用上下文窗口
  ///
  /// availableWindow = contextWindow - maxTokens
  /// （v0.2.2：outputReserve 废弃，统一用 maxTokens，避免可用窗口被多扣一倍）
  int computeAvailableWindow({
    required int contextWindow,
    required int maxTokens,
  }) {
    final available = contextWindow - maxTokens;
    return available > 0 ? available : 0;
  }

  /// 计算压缩触发阈值 token 数
  ///
  /// compactionTriggerTokens = contextWindow × compactionTriggerRatio（默认 0.5）
  int computeCompactionTriggerTokens({
    required int contextWindow,
    required ContextBudget budget,
  }) {
    return (contextWindow * budget.compactionTriggerRatio).floor();
  }

  /// 计算原文区下限 token 数（压缩后保留的近期对话量）
  ///
  /// 当 [ContextBudget.recentMinRatio] 为 null 时动态计算：
  /// `recentMinRatio = max(0.10, recentMinTokenTarget / availableWindow)`
  /// 下限保护：最低 10%，最高 45%（避免挤占其他区）
  int computeRecentMinTokens({
    required int availableWindow,
    required ContextBudget budget,
  }) {
    final minRatio = budget.recentMinRatio ??
        _computeDynamicRecentMinRatio(availableWindow, budget);
    // 2026-08-04 修复浮点精度：availableWindow * (recentMinTokenTarget/availableWindow)
    // 在 double 精度下可能得 31999.9999，floor 后误差 1 token。加极小 epsilon 补偿，
    // 使 result 精确还原 recentMinTokenTarget，不改变正常情况的结果。
    return (availableWindow * minRatio + 1e-6).floor();
  }

  /// 动态计算原文区下限百分比
  ///
  /// `recentMinRatio = max(0.10, recentMinTokenTarget / availableWindow)`
  /// 下限保护 10%-45%（会议纪要 §5.5）
  double _computeDynamicRecentMinRatio(
    int availableWindow,
    ContextBudget budget,
  ) {
    if (availableWindow <= 0) return 0.10;
    final raw = budget.recentMinTokenTarget / availableWindow;
    return raw.clamp(0.10, 0.45);
  }

  /// 检查是否需要压缩（仅判断阈值，不执行压缩）
  ///
  /// 触发条件（设计文档 §5.1）：总占用（基础上下文 + 检索区 + 历史）token
  /// 超过 `contextWindow × compactionTriggerRatio`（默认 50%）时触发压缩。
  ///
  /// **为什么基于"总占用"而非"纯历史"**：
  /// - 旧逻辑（历史 > 阈值）在固定开销大时压缩线不可达
  /// - 新逻辑自动适应：固定开销越大，历史可用空间越小，越早触发压缩
  /// - 压缩线永远可达，不会出现"死循环"
  ///
  /// 参数：
  /// - [history]：当前会话的全部消息（含可能的旧摘要消息）
  /// - [contextWindow]：解析后的上下文窗口大小
  /// - [budget]：上下文预算配置
  /// - [rolePrompt]：角色提示词文本（基础上下文组成部分）
  /// - [userInput]：当前用户输入（基础上下文组成部分）
  /// - [compactionSummary]：上一轮压缩摘要（基础上下文组成部分，可空）
  ///
  /// 返回 true 表示需要触发压缩。
  Future<bool> shouldCompact({
    required List<ChatMessage> history,
    required int contextWindow,
    required ContextBudget budget,
    required String rolePrompt,
    required String userInput,
    String? compactionSummary,
  }) async {
    final dialogueMessages = _filterDialogueMessages(history);
    if (dialogueMessages.length < _minRecentMessages * 2) return false;

    final triggerTokens = computeCompactionTriggerTokens(
      contextWindow: contextWindow,
      budget: budget,
    );
    if (triggerTokens <= 0) return false;

    // 并行计算基础上下文 token + 历史 token
    final results = await Future.wait([
      estimateBaseContextTokens(
        rolePrompt: rolePrompt,
        compactionSummary: compactionSummary,
        userInput: userInput,
      ),
      _tokenCounter.countTokensForMessages(
        dialogueMessages.map((m) => m.content!).toList(),
      ),
    ]);
    final baseContextTokens = results[0];
    final historyTokens = results[1];

    // 检索区预留 = contextWindow × retrievalRatio
    final retrievalReserve = (contextWindow * budget.retrievalRatio).floor();

    // 总占用 = 基础上下文 + 检索区预留 + 历史
    final totalUsage = baseContextTokens + retrievalReserve + historyTokens;

    _logger.info(
      'Compaction threshold check',
      detail: 'totalUsage=$totalUsage, '
          'baseContext=$baseContextTokens, '
          'retrievalReserve=$retrievalReserve, '
          'history=$historyTokens, '
          'triggerTokens=$triggerTokens, '
          'contextWindow=$contextWindow, '
          'compactionTriggerRatio=${budget.compactionTriggerRatio}',
    );

    return totalUsage > triggerTokens;
  }

  /// 估算基础上下文 token（角色提示词 + 压缩摘要 + 用户输入）
  ///
  /// [shouldCompact] 内部与控制器调用 [compact] 前共用本方法，
  /// 保证触发判定与保留量上限看到同一份基础上下文。
  Future<int> estimateBaseContextTokens({
    required String rolePrompt,
    required String userInput,
    String? compactionSummary,
  }) {
    final hasCompactionSummary =
        compactionSummary != null && compactionSummary.isNotEmpty;
    return _tokenCounter.countTokens(
      [
        rolePrompt,
        if (hasCompactionSummary) compactionSummary,
        userInput,
      ].join('\n'),
    );
  }

  /// 执行压缩
  ///
  /// 编排流程：
  /// 1. 过滤对话消息（user/assistant，非摘要）
  /// 2. 计算边界（保留近期对话在 recentMinTokens 预算内）
  /// 3. 调用 LLM 压缩 boundary 之前（含 boundary）的消息
  /// 4. 若存在已有压缩摘要，并行生成分段宏摘要（仅覆盖新增轮次）
  /// 5. 返回 [CompactionResult]（摘要 + 压缩后历史 + 可选分段宏摘要）
  ///
  /// **v0.2.3 分段宏摘要**：
  /// - [existingCompactionSummary] 为 null 或空：首次压缩，压缩摘要兼作宏摘要
  /// - [existingCompactionSummary] 非空：后续压缩，并行生成累积压缩摘要 +
  ///   分段宏摘要（仅基于新增轮次实际对话）。分段宏摘要失败不阻塞压缩。
  ///
  /// 参数：
  /// - [history]：当前会话的全部消息
  /// - [sessionId]：会话 ID（用于创建摘要消息）
  /// - [namingConfig]：压缩 LLM 调用的模型配置
  /// - [contextWindow]：上下文窗口大小
  /// - [maxTokens]：输出预留 token 数（v0.2.2：原 outputReserve，统一用 maxTokens）
  /// - [budget]：上下文预算配置
  /// - [connectTimeout] / [readTimeout]：网络超时
  /// - [existingCompactionSummary]：上一轮压缩摘要（null=首次压缩）
  /// - [baseContextTokens]：基础上下文 token（角色提示词+压缩摘要+用户输入，
  ///   由控制器经 [estimateBaseContextTokens] 计算后传入，默认 0=不约束）。
  ///   用于把保留量上限约束在触发线包络内（2026-08-22 死亡螺旋修复）。
  /// - [onSummaryDelta]：手动压缩流式回调（上下文用量指示 §4.3）：非 null 时
  ///   压缩摘要走 streamChat，增量实时回调；自动压缩传 null 保持非流式不变。
  /// - [cancelToken]：取消通道。流式路径（手动压缩）
  ///   由底层转 CancelledException 中断在途请求；非流式路径（轮前/自愈）
  ///   生效点为请求发送前（datasource XC-5 检查）。传 null 不取消。
  ///
  /// 失败时抛异常，由控制器捕获后走三选项失败处理（E018）。
  Future<CompactionResult> compact({
    required List<ChatMessage> history,
    required String sessionId,
    required NamingConfig namingConfig,
    required int contextWindow,
    required int maxTokens,
    required ContextBudget budget,
    required Duration connectTimeout,
    required Duration readTimeout,
    String? existingCompactionSummary,
    int baseContextTokens = 0,
    void Function(String delta)? onSummaryDelta,
    CancellationToken? cancelToken,
  }) async {
    final dialogueMessages = _filterDialogueMessages(history);
    if (dialogueMessages.length < _minRecentMessages * 2) {
      throw const CompactionException('对话消息不足，无需压缩');
    }

    final availableWindow = computeAvailableWindow(
      contextWindow: contextWindow,
      maxTokens: maxTokens,
    );
    var recentMinTokens = computeRecentMinTokens(
      availableWindow: availableWindow,
      budget: budget,
    );

    // 2026-08-22 死亡螺旋修复：保留量上限受触发线包络约束。
    // 旧逻辑只按 recentMinTokenTarget（clamp 10%-45% 可用窗口）确定保留量，
    // 当 保留量 + 检索预留 + 基础上下文 > 触发线（默认 0.5×contextWindow）时
    // （contextWindow ≲ 100k 的模型几乎必然如此），压缩完成后 shouldCompact
    // 仍为 true → 每轮重复压缩、每轮重写摘要：既多烧一次 LLM 调用，
    // 又让 generating/extracting 的缓存前缀每轮在第 2 条消息处断裂。
    final triggerTokens = computeCompactionTriggerTokens(
      contextWindow: contextWindow,
      budget: budget,
    );
    final retrievalReserve = (contextWindow * budget.retrievalRatio).floor();
    final baseReserve =
        (baseContextTokens * _summaryGrowthAllowanceRatio).ceil();
    final retentionCeiling = ((triggerTokens - retrievalReserve - baseReserve) *
            _postCompactionRunwayRatio)
        .floor();
    //  触底警示：retentionCeiling ≤ 0 说明触发线已被检索预留 +
    // 基础上下文吃满，近期对话保留区只剩保底 4 条——不再仅记日志，
    // 经 CompactionResult.hitRetentionFloor 透出到压缩摘要卡警示用户。
    final hitRetentionFloor = retentionCeiling <= 0;
    if (retentionCeiling < recentMinTokens) {
      _logger.warn(
        'Compaction retention capped by trigger envelope',
        detail: 'legacyRecentMin=$recentMinTokens, ceiling=$retentionCeiling, '
            'triggerTokens=$triggerTokens, retrievalReserve=$retrievalReserve, '
            'baseReserve=$baseReserve',
      );
      recentMinTokens = retentionCeiling < 0 ? 0 : retentionCeiling;
    }

    // 计算边界：从末尾向前累积，找到满足 recentMinTokens 的最近消息集合
    // （2026-08-22：per-message 精确计数，单位与 shouldCompact 一致——
    // 原 chars/3.5 估算对中文偏差 2-4 倍，会架空保留量约束并过度压缩）
    final dialogueTokenCounts = await _tokenCounter.countTokensForEach(
      dialogueMessages.map((m) => m.content ?? '').toList(),
    );
    final boundaryIndex = _findBoundaryIndex(
      dialogueMessages,
      dialogueTokenCounts,
      recentMinTokens,
    );

    if (boundaryIndex < 0) {
      throw const CompactionException('无法确定压缩边界，消息不足');
    }

    // 被 compress 的消息：dialogueMessages[0..boundaryIndex]
    final messagesToCompress = dialogueMessages.sublist(0, boundaryIndex + 1);
    final boundaryMessage = messagesToCompress.last;

    // 保留的近期消息：dialogueMessages[boundaryIndex+1..end]
    // 显式排除旧的 isSummary=true 消息——多次压缩后旧摘要会堆积，
    // 每次压缩由新摘要替代旧摘要，旧摘要不应保留在 recentMessages 中。
    final recentMessages = history.where((m) {
      if (m.isSummary) return false; // 丢弃旧摘要，由新摘要替代
      // 保留 boundary 之后的对话消息
      final dialogueIdx = dialogueMessages.indexOf(m);
      return dialogueIdx == -1 || dialogueIdx > boundaryIndex;
    }).toList();

    _logger.info(
      'Compacting messages',
      detail: 'compressCount=${messagesToCompress.length}, '
          'recentCount=${recentMessages.length}, '
          'boundaryMessageId=${boundaryMessage.messageId}',
    );

    // 调用 LLM 生成压缩摘要（累积式）
    // 若存在已有压缩摘要，并行生成分段宏摘要（仅覆盖新增轮次）
    final hasExistingSummary = existingCompactionSummary != null &&
        existingCompactionSummary.isNotEmpty;

    String summary;
    String? segmentMacroSummary;

    if (hasExistingSummary) {
      // 后续压缩：并行生成压缩摘要 + 分段宏摘要（压缩事务）
      // 两者失败都会抛 CompactionException，导致整个压缩操作失败
      final summaryFuture = _generateSummary(
        messagesToCompress: messagesToCompress,
        namingConfig: namingConfig,
        connectTimeout: connectTimeout,
        readTimeout: readTimeout,
        existingSummary: existingCompactionSummary,
        onDelta: onSummaryDelta,
        cancelToken: cancelToken,
      );
      final macroFuture = _generateSegmentMacroSummary(
        messagesToCompress: messagesToCompress,
        namingConfig: namingConfig,
        connectTimeout: connectTimeout,
        readTimeout: readTimeout,
        cancelToken: cancelToken,
      );
      // 并行等待两个 LLM 调用完成
      summary = await summaryFuture;
      segmentMacroSummary = await macroFuture;
    } else {
      // 首次压缩：仅生成压缩摘要（兼作宏摘要，segmentMacroSummary=null）
      summary = await _generateSummary(
        messagesToCompress: messagesToCompress,
        namingConfig: namingConfig,
        connectTimeout: connectTimeout,
        readTimeout: readTimeout,
        onDelta: onSummaryDelta,
        cancelToken: cancelToken,
      );
    }

    // 创建摘要消息（仅内存，不写 DB）
    final summaryMessage = ChatMessage(
      messageId: _uuid.v4(),
      sessionId: sessionId,
      role: 'system',
      content: summary,
      isSummary: true,
      createdAt: DateTime.now(),
    );

    // 压缩后历史：[summary, ...recent messages]
    final compactedHistory = [summaryMessage, ...recentMessages];

    return CompactionResult(
      summary: summary,
      boundaryMessageId: boundaryMessage.messageId,
      compactedHistory: compactedHistory,
      segmentMacroSummary: segmentMacroSummary,
      hitRetentionFloor: hitRetentionFloor,
    );
  }

  /// 调用 LLM 生成压缩摘要
  ///
  /// 把待压缩历史打包为单条 user 消息信封（2026-09-04 压缩正确性修复）。
  ///
  /// 旧实现把历史原样逐条 user/assistant 追加到指令后：请求以 assistant
  /// 剧情文本收尾、指令孤悬最前，角色扮演模型必然续写剧情而非输出摘要
  /// （实测缺陷：压缩"摘要"是成段对话与描写）。信封结构上消灭续写偏置：
  /// 围栏标记 + 角色标签平铺 + 收尾指令锚点（[closingInstruction]），
  /// 最后一条消息永远是载有指令的 user 消息。
  ///
  /// 压缩摘要与分段宏摘要共用（[closingInstruction] 各自锚定任务）。
  static String buildHistoryEnvelope({
    required List<ChatMessage> messages,
    required String closingInstruction,
  }) {
    const openMarker = '【待压缩对话历史开始】';
    const closeMarker = '【待压缩对话历史结束】';
    final buffer = StringBuffer(openMarker);
    for (final m in messages) {
      final label = m.role == 'assistant' ? 'AI' : '用户';
      buffer
        ..writeln()
        ..write('$label：${m.content ?? ''}');
    }
    buffer
      ..writeln()
      ..write(closeMarker)
      ..writeln()
      ..write(closingInstruction);
    return buffer.toString();
  }

  static const String _summaryClosingInstruction =
      '以上是完整的待压缩对话历史。对话已结束，禁止续写任何剧情。'
      '请严格按系统指令输出剧情宏观骨架摘要。';

  static const String _segmentMacroClosingInstruction =
      '以上是完整的对话记录。对话已结束，禁止续写任何剧情。'
      '请严格按系统指令生成分段宏摘要。';

  /// 调用 LLM 生成累积式压缩摘要
  ///
  /// 使用 [kIntermediateCompactionPrompt] 作为系统指令，
  /// 待压缩对话经 [buildHistoryEnvelope] 打包为单条 user 消息发送。
  ///
  /// [existingSummary] 非空时（累积式压缩，2026-08-22 落地）作为独立
  /// system 消息注入（[kIntermediateCompactionExistingSummaryInjection] 前缀），
  /// 新摘要须完整继承旧摘要信息——修复此前旧摘要从不进入压缩输入、
  /// 再次压缩即丢失更早剧情的问题。
  ///
  /// [onDelta] 非空时走流式（上下文用量指示 §4.3：手动压缩面板实时打字）；
  /// 默认 null 非流式（compacting 阶段不需要流式 UI 反馈）。
  /// temperature=0.3（低温度保证摘要稳定）。
  Future<String> _generateSummary({
    required List<ChatMessage> messagesToCompress,
    required NamingConfig namingConfig,
    required Duration connectTimeout,
    required Duration readTimeout,
    String? existingSummary,
    void Function(String delta)? onDelta,
    CancellationToken? cancelToken,
  }) async {
    final hasExistingSummary =
        existingSummary != null && existingSummary.isNotEmpty;
    final messages = <Map<String, dynamic>>[
      // 系统指令：压缩提示词
      {'role': 'system', 'content': kIntermediateCompactionPrompt},
      // 累积式压缩：旧摘要并入输入，新摘要必须完整继承其信息
      if (hasExistingSummary)
        {
          'role': 'system',
          'content':
              '$kIntermediateCompactionExistingSummaryInjection\n$existingSummary',
        },
      // 历史信封（2026-09-04 正确性修复）：单条 user 消息 + 收尾指令锚点，
      // 禁止请求中出现 assistant 角色（防续写，回归见 compaction_service_test）
      {
        'role': 'user',
        'content': buildHistoryEnvelope(
          messages: messagesToCompress,
          closingInstruction: _summaryClosingInstruction,
        ),
      },
    ];

    final request = LlmRequest(
      baseUrl: namingConfig.baseUrl,
      apiKey: namingConfig.apiKey,
      modelId: namingConfig.modelId,
      messages: messages,
      temperature: 0.3,
      maxTokens: OutputTokenPolicy.compactionLimit,
      modelMaxOutputTokens: namingConfig.maxOutputTokens,
      stream: onDelta != null,
      protocol: namingConfig.protocol,
      providerOptions: namingConfig.providerOptions,
      connectTimeout: connectTimeout,
      readTimeout: readTimeout,
      cancelToken: cancelToken,
    );

    if (Logger.debugOptions.logPrompts) {
      _logger.info(
        'Compaction request messages',
        detail: 'messageCount=${messages.length}, '
            'modelId=${namingConfig.modelId}',
      );
    }

    try {
      String content;
      if (onDelta != null) {
        content = await _chatStreaming(request, onDelta);
      } else {
        final response = await _llmService.chat(request);
        content = response.content.trim();
      }
      if (content.isEmpty) {
        throw const CompactionException('压缩服务返回空内容');
      }
      return content;
    } on CompactionException {
      rethrow;
    } catch (e) {
      _logger.error('Compaction LLM call failed', detail: '$e');
      throw CompactionException('压缩请求失败：$e');
    }
  }

  /// 流式压缩摘要（上下文用量指示 §4.3：手动压缩面板实时打字）
  ///
  /// 累积 [LlmTextDelta]；[LlmStreamDone] 视为成功终点；
  /// [LlmStreamError] 抛 [CompactionException]（由调用方整体失败处理）。
  Future<String> _chatStreaming(
    LlmRequest request,
    void Function(String delta) onDelta,
  ) async {
    final buffer = StringBuffer();
    await for (final event in _llmService.streamChat(request)) {
      switch (event) {
        case LlmTextDelta(:final content):
          if (content.isNotEmpty) {
            buffer.write(content);
            onDelta(content);
          }
        case LlmStreamDone():
          return buffer.toString().trim();
        case LlmStreamError(:final message):
          throw CompactionException('压缩请求失败：$message');
        default:
          break;
      }
    }
    return buffer.toString().trim();
  }

  /// 调用 LLM 生成分段宏摘要（v0.2.3 新增，2026-08-04）
  ///
  /// 仅基于本次压缩新增轮次的实际对话内容（user/assistant 消息），
  /// 生成分段宏摘要供记忆检索和记忆查看器使用。
  ///
  /// 使用 [kIntermediateSegmentMacroPrompt] 作为系统指令。
  /// 非流式调用，temperature=0.3（低温度保证摘要稳定）。
  ///
  /// **事务性**：分段宏摘要与压缩摘要组成"压缩事务"，
  /// 失败时抛 [CompactionException]，导致整个压缩操作失败。
  /// 这确保压缩完成后下轮对话检索一定能用到分段宏摘要，
  /// 不会出现"压缩成功了但宏摘要缺失"的不一致状态。
  Future<String> _generateSegmentMacroSummary({
    required List<ChatMessage> messagesToCompress,
    required NamingConfig namingConfig,
    required Duration connectTimeout,
    required Duration readTimeout,
    CancellationToken? cancelToken,
  }) async {
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': kIntermediateSegmentMacroPrompt},
      // 历史信封（2026-09-04 正确性修复）：与压缩摘要同构，禁止 assistant 尾巴
      {
        'role': 'user',
        'content': buildHistoryEnvelope(
          messages: messagesToCompress,
          closingInstruction: _segmentMacroClosingInstruction,
        ),
      },
    ];

    final request = LlmRequest(
      baseUrl: namingConfig.baseUrl,
      apiKey: namingConfig.apiKey,
      modelId: namingConfig.modelId,
      messages: messages,
      temperature: 0.3,
      maxTokens: OutputTokenPolicy.compactionLimit,
      modelMaxOutputTokens: namingConfig.maxOutputTokens,
      stream: false,
      protocol: namingConfig.protocol,
      providerOptions: namingConfig.providerOptions,
      connectTimeout: connectTimeout,
      readTimeout: readTimeout,
      cancelToken: cancelToken,
    );

    if (Logger.debugOptions.logPrompts) {
      _logger.info(
        'Segment macro summary request messages',
        detail: 'messageCount=${messages.length}, '
            'modelId=${namingConfig.modelId}',
      );
    }

    try {
      final response = await _llmService.chat(request);
      final content = response.content.trim();
      if (content.isEmpty) {
        throw const CompactionException('分段宏摘要服务返回空内容');
      }
      return content;
    } on CompactionException {
      rethrow;
    } catch (e) {
      _logger.error('Segment macro summary LLM call failed', detail: '$e');
      throw CompactionException('分段宏摘要请求失败：$e');
    }
  }

  /// 按最新 CompactionPoint 过滤历史消息（对标 Simple 模式 getCompressedMessages）
  ///
  /// 故事模式加载历史消息和准备轮次上下文时调用，确保已压缩的旧消息
  /// 不再进入 history token 计算，避免每轮都误触发压缩。
  ///
  /// 过滤逻辑（对标 ChatBox buildContextForSession）：
  /// 1. 无 CompactionPoint → 返回原始列表（首轮或未触发过压缩）
  /// 2. 有 CompactionPoint → 找最新 boundary，返回
  ///    `[最新summary, ...boundary之后的消息（排除旧摘要）]`
  ///
  /// **为什么排除旧摘要**：多次压缩后旧摘要会堆积，每次压缩由新摘要
  /// 替代旧摘要，旧摘要不应保留在历史中（其内容已被纳入新摘要）。
  ///
  /// **新用户消息位置**：boundary 是"压缩到此为止"的最后一条消息，
  /// boundary 之后的消息（含本轮新用户消息和助手回复）保留在 summary
  /// 之后，确保新用户消息在压缩摘要后边（用户需求 2026-08-04）。
  ///
  /// 参数：
  /// - [allMessages]：从 DB 加载的全量消息（按 createdAt 排序）
  /// - [compactionPoints]：从 DB 加载的压缩点列表
  ///
  /// 返回过滤后的消息列表，供 UI 展示和 shouldCompact/compact 使用。
  static List<ChatMessage> filterByCompactionPoint({
    required List<ChatMessage> allMessages,
    required List<Map<String, dynamic>> compactionPoints,
  }) {
    if (compactionPoints.isEmpty) return allMessages;

    final latest = compactionPoints.last;
    final boundaryMessageId = latest['boundaryMessageId'] as String;
    final summaryMessageId = latest['summaryMessageId'] as String;

    final boundaryIndex = allMessages.indexWhere(
      (m) => m.messageId == boundaryMessageId,
    );
    // boundary 消息不在列表中（异常情况）→ 返回原始列表
    if (boundaryIndex == -1) return allMessages;

    // 查找摘要消息（应在 allMessages 中，持久化时已写入）
    final summaryMessage = allMessages.firstWhere(
      (m) => m.messageId == summaryMessageId,
      orElse: () => ChatMessage(
        messageId: summaryMessageId,
        sessionId: '',
        role: 'system',
        content: ChatMessage.summaryUnavailableContent,
        isSummary: true,
        createdAt: DateTime.now(),
      ),
    );

    // boundary 之后的消息，排除旧摘要（isSummary=true）
    // 对标 Simple 模式 getCompressedMessages：旧摘要由新摘要替代，不保留
    final messagesAfterBoundary = allMessages
        .sublist(boundaryIndex + 1)
        .where((m) => !m.isSummary)
        .toList();

    return [summaryMessage, ...messagesAfterBoundary];
  }

  /// 统计消息列表中的真实对话消息数（user/assistant，排除摘要卡等 system 消息）
  ///
  /// turnNumber 推导必须基于真实对话消息而非列表长度——压缩后可见列表
  /// 头部会多出一条 system 角色的摘要卡，直接 length ~/ 2 会把它算进配对。
  /// 实现委托 story_runtime 共享工具（round_history_utils），
  /// 公式侧唯一实现，保留本静态入口兼容既有调用点。
  static int countDialogueMessages(Iterable<ChatMessage> messages) {
    return turn_utils.countDialogueMessages(messages);
  }

  /// 计算最新 CompactionPoint 已覆盖的轮次基数
  ///
  ///  修复：此前 turnNumber 一律从"过滤后的可见历史"推导
  /// （messages.length ~/ 2 + 1），首次压缩后可见列表骤减，新记忆的
  /// turnNumber 会回归到库中旧记忆之前——recency 时间衰减失效
  /// （turnsAgo≤0 全取最高加成）、按轮删除范围过杀旧记忆、时间线标签错乱。
  ///
  /// 本方法返回"已被压缩覆盖的完整轮数"作为基数，调用方按下式还原单调轮次：
  ///
  ///   真实 turnNumber = 基数 + 可见真实对话消息数 ~/ 2 + 1
  ///
  /// 无压缩点、boundary 不在 [allMessages] 中时返回 0（与未压缩行为一致）。
  static int compactedTurnBaseFor({
    required List<ChatMessage> allMessages,
    required List<Map<String, dynamic>> compactionPoints,
  }) {
    if (compactionPoints.isEmpty) return 0;
    final boundaryMessageId =
        compactionPoints.last['boundaryMessageId'] as String;
    final boundaryIndex = allMessages.indexWhere(
      (m) => m.messageId == boundaryMessageId,
    );
    // boundary 消息不在列表中（异常情况）→ 与 filterByCompactionPoint 同口径回退
    if (boundaryIndex == -1) return 0;
    return countDialogueMessages(allMessages.take(boundaryIndex + 1)) ~/ 2;
  }

  /// 过滤对话消息（user/assistant，非摘要，内容非空）
  List<ChatMessage> _filterDialogueMessages(List<ChatMessage> history) {
    return history
        .where(
          (m) =>
              (m.role == 'user' || m.role == 'assistant') &&
              !m.isSummary &&
              (m.content?.isNotEmpty ?? false),
        )
        .toList();
  }

  /// 从末尾向前累积 token，找到满足 [recentMinTokens] 预算的边界索引
  ///
  /// 返回 boundary 在 dialogueMessages 中的索引。
  /// boundary 之前（含 boundary）的消息将被压缩，
  /// boundary 之后的消息保留为近期对话。
  ///
  /// [tokenCounts] 为 dialogueMessages 逐条精确 token 数（tiktoken），
  /// 由调用方经 [TokenCounter.countTokensForEach] 批量计算——
  /// 单位必须与 [shouldCompact] 一致，保留量约束才有效
  /// （2026-08-22：替换原 chars/3.5 估算，该启发式按英文校准，
  /// 中文内容偏差 2-4 倍，导致中文会话被过度压缩到只剩保底 4 条）。
  ///
  /// 保底保留 [_minRecentMessages] 条消息（2 轮 = 4 条）。
  ///
  /// 审查  修复：原代码循环允许 i 过大时返回 i-1，
  /// 导致保留消息少于保底 4 条。修复：用 maxBoundary 限制 boundary 上限，
  /// 确保任何情况下保留至少 [_minRecentMessages] 条消息。
  ///
  ///  压缩边界吸附 assistant：
  /// boundary 必须落在 assistant 消息上——落在 user 上会把一对
  /// user/assistant 拆到压缩区与保留区两侧，产生孤儿 assistant，
  /// 进而使轮次号配对公式集体分裂（同事务双轮号、记忆撞号、
  /// 过程小窗查不到）。吸附方式：boundary 角色为 user 时回退一位；
  /// 回退只把一条消息从压缩区移入保留区，保留量只增不减，安全。
  /// 按角色而非下标奇偶判断，不依赖「首条必为 user」的假设。
  int _findBoundaryIndex(
    List<ChatMessage> dialogueMessages,
    List<int> tokenCounts,
    int recentMinTokens,
  ) {
    if (dialogueMessages.length <= _minRecentMessages) {
      return -1; // 消息不足，不压缩
    }

    // 保底：boundary 最大值 = length - _minRecentMessages - 1
    // 确保保留至少 _minRecentMessages 条消息
    final maxBoundary = dialogueMessages.length - _minRecentMessages - 1;

    // 从末尾向前累积 token
    var accumulatedTokens = 0;
    for (var i = dialogueMessages.length - 1; i >= _minRecentMessages; i--) {
      accumulatedTokens += tokenCounts[i];

      // 当累积 token 超过 recentMinTokens 时，i-1 就是 boundary
      // （i 及之后的消息保留，i-1 及之前的消息被压缩）
      // 但 boundary 不能超过 maxBoundary（保底至少 _minRecentMessages 条）
      if (accumulatedTokens >= recentMinTokens) {
        final boundary = i - 1;
        final capped = boundary > maxBoundary ? maxBoundary : boundary;
        return _snapBoundaryToAssistant(dialogueMessages, capped);
      }
    }

    // 累积完所有消息（除保底 4 条）仍未达到 recentMinTokens
    // → boundary = _minRecentMessages - 1（保留最近 4 条，压缩其余）
    return _snapBoundaryToAssistant(
      dialogueMessages,
      _minRecentMessages - 1,
    );
  }

  /// 把 boundary 吸附到 assistant 消息
  ///
  /// boundary 落在 user 上时回退一位；回退后为负（首条即 user 的退化
  /// 场景，正常会话不可达——shouldCompact 已挡掉消息不足 8 条的情况）
  /// 返回 -1，由调用方按「无法确定压缩边界」处理。
  static int _snapBoundaryToAssistant(
    List<ChatMessage> dialogueMessages,
    int boundary,
  ) {
    if (boundary < 0) return boundary;
    if (dialogueMessages[boundary].role == 'assistant') return boundary;
    final snapped = boundary - 1;
    return snapped >= 0 ? snapped : -1;
  }
}

/// 压缩异常
///
/// 压缩过程中发生的可向用户展示的错误。消息使用通俗语言。
class CompactionException implements Exception {
  const CompactionException(this.message);

  final String message;

  @override
  String toString() => message;
}
