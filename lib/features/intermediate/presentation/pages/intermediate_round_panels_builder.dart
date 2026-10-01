import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/components/intermediate_markdown_body.dart';
import 'package:lmstory/core/theme/intermediate/components/intermediate_message_bubble.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/intermediate/domain/entities/intermediate_chat_state.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/panels/extract_panel.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/panels/facts_change_panel.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/panels/generate_panel.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/panels/retrieval_panel.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/panels/summarize_panel.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/services/round_history_utils.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式"轮次小窗"构建工具。
///
/// 从 `IntermediateChatBody` 抽离，负责构建当前轮与历史轮的 4 个统一小窗
/// （关键词/检索/生成内容?/摘要）。统一组件在生成中与完成后复用，避免"四合二"
/// 闪动（DOC-09B §7.4.1）。
///
/// 三个顶层函数：
/// - [shouldRenderCurrentRoundPanels]：判断是否在末尾渲染当前轮小窗
/// - [buildHistoryPanelsBeforeReply]：构建回复前的历史小窗（关键词/检索/生成内容?）
/// - [buildHistorySummaryPanel]：构建回复后的摘要历史小窗
/// - [buildCurrentRoundPanels]：构建当前轮小窗（实时流式 / artifacts 切换）

/// 判断是否需要在末尾渲染"当前轮"小窗区域。
///
/// - 生成中（非 idle/failed）：总是渲染（流式小窗）
/// - 完成后（idle）：最后一轮有 artifacts 时渲染（避免"四合二"闪动）
/// - 失败（failed）：有中断正文快照时渲染（：半截稿件卡；
///   无快照不渲染——错误通过消息气泡展示，维持旧行为）
bool shouldRenderCurrentRoundPanels(IntermediateChatState state) {
  if (state.phase != IntermediatePhase.idle &&
      state.phase != IntermediatePhase.failed) {
    return true;
  }
  if (state.phase == IntermediatePhase.idle) {
    //  修复：存储键是真实轮次号，本地可见轮数需叠加压缩基数
    // 公式收编 story_runtime 共享工具（length ~/2 会把摘要卡算进配对）
    final lastTurn = completedTurnCount(
      compactedTurnBase: state.compactedTurnBase,
      messages: state.messages,
    );
    return state.artifactsByTurnNumber?[lastTurn] != null;
  }
  return (state.partialReplySnapshot ?? '').isNotEmpty;
}

/// 构建回复气泡前的历史小窗（关键词/检索/生成内容?）。
///
/// 显示顺序：关键词→检索→生成?→**回复气泡**→摘要
/// 回复气泡由调用方（intermediate_chat_body）在 messages 渲染中插入，
/// 摘要小窗由 [buildHistorySummaryPanel] 在回复气泡后插入。
List<Widget> buildHistoryPanelsBeforeReply(
  StoryRoundArtifacts artifacts,
) {
  return [
    ExtractPanel(
      key: ValueKey('history-extract-${artifacts.turnNumber}'),
      phase: IntermediatePhase.idle,
      keywords: null,
      failureContext: null,
      artifacts: artifacts,
    ),
    RetrievalPanel(
      key: ValueKey('history-retrieval-${artifacts.turnNumber}'),
      phase: IntermediatePhase.idle,
      retrievedMemories: null,
      failureContext: null,
      onRetry: () {},
      artifacts: artifacts,
    ),
    // v0.2.2 修复：生成面板仅在执行了审查时显示（生成≠回复，有对比价值）
    // 跳过审查时（生成即最终），不显示生成面板，避免重复内容
    if (artifacts.reviewExecuted)
      GeneratePanel(
        key: ValueKey('history-generate-${artifacts.turnNumber}'),
        phase: IntermediatePhase.idle,
        streamingGenerated: null,
        generatedText: null,
        failureContext: null,
        artifacts: artifacts,
      ),
  ];
}

/// 构建回复气泡后的摘要历史小窗。
///
/// 显示顺序：关键词→检索→生成?→回复气泡→**摘要**
/// 与 [buildHistoryPanelsBeforeReply] 配合使用，中间由调用方插入回复气泡。
Widget buildHistorySummaryPanel(StoryRoundArtifacts artifacts) {
  return SummarizePanel(
    key: ValueKey('history-summarize-${artifacts.turnNumber}'),
    phase: IntermediatePhase.idle,
    eventSummary: null,
    failureContext: null,
    artifacts: artifacts,
  );
}

/// 构建回复气泡后的事实层变更历史小窗（事实层变更小窗配套）。
///
/// 显示顺序：关键词→检索→生成?→回复气泡→摘要→**事实层变更**
/// 与 [buildHistorySummaryPanel] 配合，在摘要历史小窗之后插入。
Widget buildHistoryFactsChangePanel(StoryRoundArtifacts artifacts) {
  return FactsChangePanel(
    key: ValueKey('history-facts-change-${artifacts.turnNumber}'),
    phase: IntermediatePhase.idle,
    factsChanges: null,
    failureContext: null,
    artifacts: artifacts,
  );
}

/// 构建"当前轮"小窗区域（统一组件 + 数据源切换）。
///
/// 核心思路：完成后 phase=idle 切换瞬间，临时小窗组件实例保留
/// （相同 Key + 类型），仅切换数据源从 streaming 到 artifacts，
/// 避免销毁重建造成的画面跳变（"四合二"闪动）。
///
/// 生成中：按阶段渲染实时流式小窗（GeneratePanel/ExtractPanel/
///   RetrievalPanel/streamingReply/SummarizePanel）
/// 完成后（idle）：用 artifacts 模式渲染（4 个统一组件的历史态）
///
/// 修复：idle 分支渲染回复气泡时未传入动作回调，
/// 导致最新一条回复点击"重新生成"等操作无反应。新增 `messageCallbacks`
/// 参数组，由调用方（IntermediateChatBody）查找最后一条 assistant 消息
/// 后构造闭包传入。
List<Widget> buildCurrentRoundPanels({
  required BuildContext context,
  required IntermediateChatState state,
  required int generatingFoldDelayMs,
  required int retrievalFoldDelayMs,
  required VoidCallback onRetryRetrieval,
  required CurrentRoundMessageActions messageActions,
  required bool embeddingConfigured,
  required double fontScale,
  Widget? variantSwitcher,
}) {
  // 失败态——半截稿件卡（只读 + 复制），正文不再
  // 随中断蒸发；修复路径（以此收稿/续写）在底部 FailureBar。
  if (state.phase == IntermediatePhase.failed) {
    final snapshot = state.partialReplySnapshot;
    if (snapshot == null || snapshot.isEmpty) return const [];
    return [
      _PanelEntrance(
        child: _PartialManuscriptCard(text: snapshot, fontScale: fontScale),
      ),
    ];
  }

  // 完成后：用 artifacts 模式渲染（避免闪动）
  // 显示顺序：关键词→检索→生成内容?→回复气泡→摘要
  // 回复气泡从 messages 渲染中 skip（由本函数统一渲染以保持顺序一致）
  // v0.2.2 新增：生成面板仅在 reviewExecuted=true 时显示。
  // reviewExecuted=false（生成即最终）时跳过 GeneratePanel，避免重复内容。
  if (state.phase == IntermediatePhase.idle) {
    //  修复：同 shouldRenderCurrentRoundPanels，键需叠加压缩基数
    // 公式收编 story_runtime 共享工具
    final lastTurn = completedTurnCount(
      compactedTurnBase: state.compactedTurnBase,
      messages: state.messages,
    );
    final artifacts = state.artifactsByTurnNumber?[lastTurn];
    if (artifacts == null) return const [];
    // 2026-07-29 修复：从最后一条 assistant 消息读取 thinkingContent，
    // 修复 idle 分支断链导致回复完成后思考内容消失的问题。
    // thinkingContent 在 persisting 阶段已写入消息并持久化到数据库，
    // 切换会话重新加载也能正确恢复。
    final lastAssistantMessage =
        state.messages.isNotEmpty && state.messages.last.role == 'assistant'
            ? state.messages.last
            : null;
    // 使用 'current-round' 前缀 Key，与生成中保持一致，
    // 确保phase切换时Widget实例被复用而非销毁重建。
    // 问题1修复：idle 分支也用 _PanelEntrance 包裹（与生成中分支结构一致），
    // 避免 phase 切换时外层组件类型变化导致销毁重建。
    // 回复气泡不包裹（与生成中分支一致，流式回复气泡也未包裹）。
    return [
      _PanelEntrance(
        child: ExtractPanel(
          key: const ValueKey('current-round-extract'),
          phase: IntermediatePhase.idle,
          keywords: null,
          failureContext: null,
          artifacts: artifacts,
        ),
      ),
      _PanelEntrance(
        child: RetrievalPanel(
          key: const ValueKey('current-round-retrieval'),
          phase: IntermediatePhase.idle,
          retrievedMemories: null,
          failureContext: null,
          onRetry: onRetryRetrieval,
          artifacts: artifacts,
        ),
      ),
      // v0.2.2：生成面板仅在执行了审查时显示（生成≠回复，有对比价值）
      // 跳过审查时（生成即最终），不显示生成面板，避免重复内容
      // 顺序调整：从列表顶部移到检索面板之后，
      // 匹配执行顺序（extracting -> retrieving -> generating），
      // 避免 generating 阶段生成面板从顶部插入造成突兀跳转
      // 问题2修复：Key 从 'current-round-draft' 统一为 'current-round-generate'，
      // 与生成中分支一致，避免销毁重建。
      if (artifacts.reviewExecuted)
        _PanelEntrance(
          // 生成面板单独成层（idle/生成两分支结构一致，保 Key 复用不变量）
          child: RepaintBoundary(
            child: GeneratePanel(
              key: const ValueKey('current-round-generate'),
              phase: IntermediatePhase.idle,
              streamingGenerated: null,
              generatedText: null,
              failureContext: null,
              artifacts: artifacts,
            ),
          ),
        ),
      // 回复气泡（始终显示，不可折叠）
      // 修复：idle 时当前轮 assistant 消息就是最后一条 assistant，
      // isLastAssistantMessage=true 让动作按钮常驻显示，
      // 同时把 onRegenerate 等回调正确传入（之前为 _noop 导致点击无反应）
      // 2026-07-29 修复：传入 thinkingContent，使回复完成后思考内容仍可见
      RepaintBoundary(
        // 回复气泡单独成层（idle/生成两分支结构一致，保 Key 复用不变量）
        child: IntermediateMessageBubble(
          key: const ValueKey('current-round-reply'),
          content: artifacts.replyText ?? '',
          isUser: false,
          thinkingContent: lastAssistantMessage?.thinkingContent,
          isLastAssistantMessage: true,
          canOperate: messageActions.canOperate,
          windowRounds: messageActions.windowRounds,
          actionsEnabled: messageActions.actionsEnabled,
          onCopy: messageActions.onCopy,
          onRegenerate: messageActions.onRegenerate,
          onEdit: messageActions.onEdit,
          onDeleteRound: messageActions.onDeleteRound,
          // 字体缩放比例透传，与历史消息气泡保持字号一致
          fontScale: fontScale,
        ),
      ),
      // 当前轮稿件变体切换器（调用方按渲染条件
      // 预构建，null = 不渲染——与动作回调组同一传参模式）
      if (variantSwitcher != null) variantSwitcher,
      _PanelEntrance(
        // 摘要面板单独成层（idle/生成两分支结构一致，保 Key 复用不变量）
        child: RepaintBoundary(
          child: SummarizePanel(
            key: const ValueKey('current-round-summarize'),
            phase: IntermediatePhase.idle,
            eventSummary: null,
            failureContext: null,
            artifacts: artifacts,
          ),
        ),
      ),
      _PanelEntrance(
        child: FactsChangePanel(
          key: const ValueKey('current-round-facts-change'),
          phase: IntermediatePhase.idle,
          factsChanges: null,
          failureContext: null,
          artifacts: artifacts,
        ),
      ),
    ];
  }

  // 生成中：按阶段渲染实时流式小窗
  final panels = <Widget>[];

  // 审查  修复：compacting 阶段显示压缩加载提示
  // compacting 阶段检查是否需要压缩 + 执行压缩 LLM 调用，期间无其他产出
  // 审查  修复：文案改用 i18n（phaseHints.compacting）
  if (state.phase == IntermediatePhase.compacting) {
    final t = Translations.of(context);
    panels.add(
      _PanelEntrance(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  t.intermediate.chat.phaseHints.compacting,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return panels;
  }

  // ExtractPanel：extracting 产出分类关键词，在 extracting/retrieving/
  // generating/reviewing/summarizing/persisting 阶段持续可见（折叠态保留）
  // 2026-07-16 修复问题4：包裹 _PanelEntrance 实现入场动画
  // v0.2.2 修复：V2 六步流程重构后 extracting/retrieving 前置到 generating 之前，
  // 关键词在 generating 阶段已存在，必须保留显示。原条件漏掉 generating/generatingRetry，
  // 导致 phase 从 retrieving 切到 generating 时关键词卡片消失。
  // 顺序调整：ExtractPanel 移到首位，匹配执行顺序（extracting 最先执行）
  if (state.phase == IntermediatePhase.extracting ||
      state.phase == IntermediatePhase.extractingRetry ||
      state.phase == IntermediatePhase.retrieving ||
      state.phase == IntermediatePhase.retrievingRetry ||
      state.phase == IntermediatePhase.generating ||
      state.phase == IntermediatePhase.generatingRetry ||
      state.phase == IntermediatePhase.reviewing ||
      state.phase == IntermediatePhase.reviewingRetry ||
      state.phase == IntermediatePhase.summarizing ||
      state.phase == IntermediatePhase.summarizingRetry ||
      state.phase == IntermediatePhase.persisting) {
    panels.add(
      _PanelEntrance(
        child: ExtractPanel(
          key: const ValueKey('current-round-extract'),
          phase: state.phase,
          keywords: state.classifiedKeywords,
          failureContext: state.failureContext,
          foldDelayMs: retrievalFoldDelayMs,
        ),
      ),
    );
  }

  // RetrievalPanel：retrieving/generating/reviewing/summarizing/persisting 阶段显示
  // V2 四步：summarizing 阶段检索结果仍应可见（用户可复核依据）
  // 2026-07-16 修复问题4：包裹 _PanelEntrance 实现入场动画
  // v0.2.2 修复：V2 六步流程重构后 retrieving 在 generating 之前，
  // 检索结果在 generating 阶段已存在，必须保留显示。原条件漏掉 generating/generatingRetry，
  // 导致 phase 从 retrieving 切到 generating 时检索结果卡片消失。
  if (state.phase == IntermediatePhase.retrieving ||
      state.phase == IntermediatePhase.retrievingRetry ||
      state.phase == IntermediatePhase.generating ||
      state.phase == IntermediatePhase.generatingRetry ||
      state.phase == IntermediatePhase.reviewing ||
      state.phase == IntermediatePhase.reviewingRetry ||
      state.phase == IntermediatePhase.summarizing ||
      state.phase == IntermediatePhase.summarizingRetry ||
      state.phase == IntermediatePhase.persisting) {
    panels.add(
      _PanelEntrance(
        child: RetrievalPanel(
          key: const ValueKey('current-round-retrieval'),
          phase: state.phase,
          retrievedMemories: state.retrievedMemories,
          failureContext: state.failureContext,
          onRetry: onRetryRetrieval,
          foldDelayMs: retrievalFoldDelayMs,
          retrievedFacts: state.retrievedFacts,
          // 2026-07-21：传入检索模式信息，让小窗显示「语义/关键词/临时降级」标签
          embeddingConfigured: embeddingConfigured,
          embeddingDegradedForRound: state.embeddingDegradedForRound,
        ),
      ),
    );
  }

  // GeneratePanel：generating 阶段流式显示，generating 完成后于 reviewing/
  // summarizing/persisting 阶段仍可见（_isCompleted 内部渲染折叠态）
  // 含 *Retry 状态（自动重试时小窗不消失）
  // 2026-07-16 修复问题4：包裹 _PanelEntrance 实现入场动画
  // v0.2.2 修复：
  // 1. V2 六步流程重构后 extracting/retrieving 在 generating 之前，GeneratePanel
  //    不应在 extracting/retrieving 阶段显示（还没有生成内容）。原条件含这两个阶段
  //    是旧四步流程遗留。现已移除。
  // 2. isReviewEnabled=false（生成即最终）时不显示 GeneratePanel，流式直接在最终回复
  //    气泡位置显示。避免生成与回复内容相同造成 UI 冗余。
  // 顺序调整：GeneratePanel 从列表首位移到 RetrievalPanel 之后，
  // 匹配执行顺序（extracting -> retrieving -> generating），
  // 避免 generating 阶段生成面板从顶部插入造成突兀跳转。
  if (state.isReviewEnabled &&
      (state.phase == IntermediatePhase.generating ||
          state.phase == IntermediatePhase.generatingRetry ||
          state.phase == IntermediatePhase.reviewing ||
          state.phase == IntermediatePhase.reviewingRetry ||
          state.phase == IntermediatePhase.summarizing ||
          state.phase == IntermediatePhase.summarizingRetry ||
          state.phase == IntermediatePhase.persisting)) {
    panels.add(
      _PanelEntrance(
        // 流式草稿期间的重绘只落在草稿面板自己的 layer
        child: RepaintBoundary(
          child: GeneratePanel(
            key: const ValueKey('current-round-generate'),
            phase: state.phase,
            streamingGenerated: state.streamingGenerated,
            streamingGeneratedThinking: state.streamingGeneratedThinking,
            generatedText: state.generatedText,
            failureContext: state.failureContext,
            foldDelayMs: generatingFoldDelayMs,
          ),
        ),
      ),
    );
  }

  // 流式回复（reviewing 阶段实时显示，含 reviewingRetry）
  // 流式气泡不显示 actions（isStreaming=true 已让 _showActions=false）
  // review-off（默认）时 generating 增量
  // 写 streamingReply，此前气泡 isStreaming 只认 reviewing——无呼吸光标、
  // 不走快速路径/配速/淡入，且生成中点按会弹全 no-op 动作条（共根因）。
  // generating/generatingRetry 且审查关闭时同样按流式渲染。
  // Key 与 idle 分支一致，确保 phase 切换时 Widget 实例复用
  // 2026-07-29 新增：传递 streamingReplyThinking 显示审查阶段的思考内容
  if (state.streamingReply != null && state.streamingReply!.isNotEmpty) {
    final phaseIsStreaming = state.phase == IntermediatePhase.reviewing ||
        state.phase == IntermediatePhase.reviewingRetry;
    final generatingWithoutReview =
        (state.phase == IntermediatePhase.generating ||
                state.phase == IntermediatePhase.generatingRetry) &&
            !state.isReviewEnabled;
    panels.add(
      RepaintBoundary(
        // 流式回复期间的重绘只落在回复气泡自己的 layer
        child: IntermediateMessageBubble(
          key: const ValueKey('current-round-reply'),
          content: state.streamingReply!,
          isUser: false,
          thinkingContent: state.streamingReplyThinking,
          isStreaming: phaseIsStreaming || generatingWithoutReview,
          // 字体缩放比例透传，流式与回复字号保持一致
          fontScale: fontScale,
        ),
      ),
    );
  }

  // SummarizePanel：summarizing/persisting 阶段持续可见
  // 2026-07-16 修复问题4：包裹 _PanelEntrance 实现入场动画
  if (state.phase == IntermediatePhase.summarizing ||
      state.phase == IntermediatePhase.summarizingRetry ||
      state.phase == IntermediatePhase.persisting) {
    panels.add(
      _PanelEntrance(
        // 摘要流式期间的重绘只落在摘要面板自己的 layer
        child: RepaintBoundary(
          child: SummarizePanel(
            key: const ValueKey('current-round-summarize'),
            phase: state.phase,
            eventSummary: state.currentEventSummary,
            failureContext: state.failureContext,
            foldDelayMs: retrievalFoldDelayMs,
          ),
        ),
      ),
    );
  }

  // FactsChangePanel：summarizing/persisting 阶段持续可见（与摘要小窗同阶段）
  // 展示本轮事实层的新增/更新/变更前后；无变更时显示占位
  if (state.phase == IntermediatePhase.summarizing ||
      state.phase == IntermediatePhase.summarizingRetry ||
      state.phase == IntermediatePhase.persisting) {
    panels.add(
      _PanelEntrance(
        child: FactsChangePanel(
          key: const ValueKey('current-round-facts-change'),
          phase: state.phase,
          factsChanges: state.currentFactsChanges,
          failureContext: state.failureContext,
          foldDelayMs: retrievalFoldDelayMs,
          // 疑似重复行（点击进记忆库归并预选）
          similarNameCandidates: state.similarNameCandidates,
          session: state.session,
        ),
      ),
    );
  }

  return panels;
}

/// 面板入场动画包裹器（2026-07-16 修复问题4）。///
/// 面板首次出现时（如 ExtractPanel 在 extracting 阶段首次插入），
/// 从 0 高度 + 0 透明度 平滑过渡到完整高度 + 完全不透明（200ms easeOut），
/// 避免面板突然插入导致下方内容瞬移跳动。
///
/// 原理：`TweenAnimationBuilder` 在 widget 首次构建时从 begin(0) 到 end(1) 过渡。
/// 面板因 if 条件增删——首次出现时是全新 widget，重新触发入场动画；
/// 后续 phase 变化但面板继续存在时（同 Key 复用），不重复触发。
///
/// reduced-motion：时长改 0（DOC-06B §5.1），仅保留淡入逻辑无动画。
class _PanelEntrance extends StatelessWidget {
  const _PanelEntrance({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final reducedMotion = LmMotion.reducedMotion(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: reducedMotion ? Duration.zero : LmMotion.base,
      curve: LmMotion.easeStandard,
      builder: (context, value, child) => ClipRect(
        child: Align(
          alignment: Alignment.topCenter,
          heightFactor: value.clamp(0.0, 1.0),
          child: Opacity(opacity: value.clamp(0.0, 1.0), child: child),
        ),
      ),
      child: child,
    );
  }
}

/// 当前轮 assistant 消息的动作回调集合（2026-07-18 修复重新生成 bug）。
///
/// `buildCurrentRoundPanels` 在 idle 分支渲染最后一轮 assistant 气泡时，
/// 需要把消息动作（复制/重新生成/编辑重发/删除）正确连接到 controller。
/// 由于 `buildCurrentRoundPanels` 是顶层函数，无法直接访问 widget 的回调，
/// 调用方（`IntermediateChatBody`）查找最后一条 assistant 消息后构造本对象传入。
///
/// 设计为不可变值对象，所有字段必填（语义上无"部分回调"场景）。
class CurrentRoundMessageActions {
  const CurrentRoundMessageActions({
    required this.canOperate,
    required this.windowRounds,
    required this.actionsEnabled,
    required this.onCopy,
    required this.onRegenerate,
    required this.onEdit,
    required this.onDeleteRound,
  });

  /// 当前轮 assistant 消息是否可操作（在 Fork 窗口内）
  final bool canOperate;

  /// Fork 窗口轮数（用于 canOperate=false 时的提示文案）
  final int windowRounds;

  /// 全局动作开关（phase != idle 时为 false）
  final bool actionsEnabled;

  /// 复制回调
  final VoidCallback onCopy;

  /// 重新生成回调
  final VoidCallback onRegenerate;

  /// 编辑重发回调（assistant 消息不显示此按钮，但仍需传入占位）
  final VoidCallback onEdit;

  /// 删除整轮回调
  final VoidCallback onDeleteRound;
}

/// 失败轮半截稿件卡——只读正文 + 复制按钮。
///
/// 生成/审查中断时正文已快照进 partialReplySnapshot，本卡让半截正文
/// 保持可见（此前 failed 态当前轮完全不渲染，正文随中断蒸发）。
/// 修复路径（以此收稿/续写）在底部 FailureBar，不在卡内重复。
class _PartialManuscriptCard extends StatelessWidget {
  const _PartialManuscriptCard({required this.text, required this.fontScale});

  final String text;

  /// 字体缩放比例（与消息气泡同源，应用到正文与引用字号）
  final double fontScale;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          Translations.of(context).intermediate.chat.partialManuscript.copyDone,
        ),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: IntermediateSpacing.sSm,
        vertical: IntermediateSpacing.sXs,
      ),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(IntermediateSpacing.sLg),
        decoration: BoxDecoration(
          color: colors.surfaceElevated,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
          border: Border.all(color: colors.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.edit_note_outlined,
                  size: 18,
                  color: colors.muted,
                ),
                const SizedBox(width: IntermediateSpacing.sXs),
                Expanded(
                  child: Text(
                    t.intermediate.chat.partialManuscript.title,
                    style: IntermediateTextStyles.caption.copyWith(
                      color: colors.muted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  iconSize: 18,
                  tooltip: t.intermediate.chat.partialManuscript.copy,
                  onPressed: () => _copy(context),
                  icon: Icon(Icons.copy_outlined, color: colors.muted),
                ),
              ],
            ),
            const SizedBox(height: IntermediateSpacing.sXs),
            IntermediateMarkdownBody(
              data: text,
              isUser: false,
              fontScale: fontScale,
            ),
          ],
        ),
      ),
    );
  }
}
