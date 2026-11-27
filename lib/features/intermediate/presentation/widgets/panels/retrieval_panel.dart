import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_motion.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/factual_detail_dialog.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/memory_detail_dialog.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/entities/factual_entity.dart';
import 'package:lmstory/features/memory/domain/services/fact_context_builder.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 记忆检索小窗（DOC-06B §6.3）。
///
/// 状态映射：
/// - retrieving：surfaceElevated 底 + "正在检索记忆..."
/// - 完成：先展开 [foldDelayMs] 毫秒展示命中结果列表（stagger 淡入），
///   然后自动折叠为 "▸ 找到 N 条相关经历"；用户点击可重新展开/折叠
/// - 失败：AnimatedOpacity + 灰度滤镜（300ms ease-out，DOC-06B §5.3）+ 重试按钮
/// - 历史态（[artifacts] != null）：用 HistoryPanelShell 渲染，默认折叠、
///   muted 箭头、入场淡入、无 stagger 淡入、无失败态/无重试按钮
///
/// 自动折叠时序（DOC-09B §7.3）、检索结果 stagger 淡入（DOC-06B §5.3）、
/// easeInOut 曲线、reduced-motion 备选。
///
/// 统一组件（避免"四合二"闪动）：本组件同时承载"生成中"和"完成后"两种态，
/// 通过 [artifacts] 参数切换数据源。历史态从 `artifacts.retrievedMemories`
/// 读取记忆列表，无 stagger 淡入动效（已是历史，不需要逐条淡入）。
///
/// 5W1E 详情查看（v0.2 Phase C 方案二，2026-07-19 新增）：展开态下用户点击
/// 记忆条目可弹出 [MemoryDetailDialog]，展示完整 5W1E 6 字段详情。micro 与
/// macro 记忆均可点击；macro 记忆额外展示聚合微摘要数和触发原因。详见
/// DOC-06B §6.3 / §6.3C。
class RetrievalPanel extends StatefulWidget {
  const RetrievalPanel({
    required this.phase,
    required this.retrievedMemories,
    required this.failureContext,
    required this.onRetry,
    this.foldDelayMs = 1000,
    this.artifacts,
    this.retrievedFacts,
    this.embeddingConfigured = true,
    this.embeddingDegradedForRound = false,
    super.key,
  });

  final IntermediatePhase phase;
  final List<ExperientialMemory>? retrievedMemories;
  final FailureContext? failureContext;
  final VoidCallback onRetry;

  /// 自动折叠延迟（毫秒）。从 `StreamConfig.retrievalFoldDelayMs` 传入。
  final int foldDelayMs;

  /// 历史快照（非 null 时进入历史态渲染）。
  ///
  /// 完成后的轮次通过此参数传入持久化的 [StoryRoundArtifacts]，
  /// 组件从 `artifacts.retrievedMemories` 读取记忆列表。
  /// 历史态忽略 [phase]/[retrievedMemories]/[failureContext]/[onRetry]。
  final StoryRoundArtifacts? artifacts;

  /// 检索到的事实类命中列表（DOC-11 §6.1，2026-07-20 新增）
  ///
  /// 经历层 [retrievedMemories] 的事实层对照。null 表示事实层未启用或
  /// retrieving 阶段未执行；空列表表示启用但无命中。
  /// 生成中态据此渲染【相关事实】分区；历史态从 artifacts.retrievedFacts 读取。
  final List<RetrievedFact>? retrievedFacts;

  /// 嵌入模型是否已配置（2026-07-21 新增）
  ///
  /// - true（默认）：摘要行显示「语义」标签（琥珀金）
  /// - false：摘要行显示「关键词」标签（灰色，提示用户当前用的是 FTS5）
  ///
  /// 历史态忽略此参数（历史轮次的检索模式不影响当前轮显示）。
  final bool embeddingConfigured;

  /// 本轮是否临时降级为关键词检索（2026-07-21 新增）
  ///
  /// - true：摘要行显示「关键词（临时降级）」标签（红色，提示用户本轮降级了）
  /// - false：按 [embeddingConfigured] 判断
  ///
  /// 临时降级发生在 embedding 调用失败时用户选择"临时降级继续本轮"。
  final bool embeddingDegradedForRound;

  @override
  State<RetrievalPanel> createState() => _RetrievalPanelState();
}

class _RetrievalPanelState extends State<RetrievalPanel> {
  bool _expanded = false;
  Timer? _autoFoldTimer;

  /// 是否已完成自动折叠（用户已交互或定时器已触发，之后不再自动折叠）
  bool _hasAutoFolded = false;

  /// 可见时延迟折叠的已重试次数（2026-07-16 修复问题3）
  int _foldRetryCount = 0;
  static const int _maxFoldRetries = 2;

  /// 是否已渲染过实时态（非历史态）。
  /// 用于检测从实时态切换到历史态时跳过 HistoryPanelShell 的淡入动画（问题1修复）。

  // 含 retrievingRetry（自动重试时小窗保持 retrieving 视觉态）
  bool get _isRetrieving =>
      widget.phase == IntermediatePhase.retrieving ||
      widget.phase == IntermediatePhase.retrievingRetry;
  bool get _isFailed =>
      widget.phase == IntermediatePhase.failed &&
      widget.failureContext?.failedPhase == IntermediatePhase.retrieving;
  bool get _isCompleted =>
      !_isRetrieving &&
      !_isFailed &&
      (widget.retrievedMemories != null || widget.retrievedFacts != null);

  @override
  void didUpdateWidget(RetrievalPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 新轮次开始：从 idle/failed → retrieving，重置自动折叠状态
    // （防御性：统一组件重构后 panel 可能跨轮次复用 State）
    final wasIdleOrFailed = oldWidget.phase == IntermediatePhase.idle ||
        oldWidget.phase == IntermediatePhase.failed;
    if (wasIdleOrFailed && _isRetrieving) {
      _hasAutoFolded = false;
      _expanded = false;
      _autoFoldTimer?.cancel();
      _autoFoldTimer = null;
    }
    // 检测从 retrieving 转 _isCompleted：进入完成态，启动自动折叠时序
    final wasRetrieving = oldWidget.phase == IntermediatePhase.retrieving ||
        oldWidget.phase == IntermediatePhase.retrievingRetry;
    if (wasRetrieving && _isCompleted && !_hasAutoFolded) {
      // 进入完成态：先展开展示检索结果列表（含 stagger 淡入）
      _expanded = true;
      _foldRetryCount = 0; // 重置可见延迟计数
      _autoFoldTimer?.cancel();
      if (widget.foldDelayMs <= 0) {
        // foldDelayMs=0：立即折叠
        _hasAutoFolded = true;
        _expanded = false;
      } else if (widget.phase == IntermediatePhase.idle) {
        _autoFoldTimer = Timer(
          Duration(milliseconds: widget.foldDelayMs),
          _doAutoFold,
        );
      }
      // 问题4+5修复：生成中（非 idle）不自动折叠，保持展开供用户阅读
    }
  }

  void _doAutoFold() {
    if (mounted) {
      // 2026-07-16 修复问题3：面板在视口可见时延迟折叠，避免打断用户阅读。
      if (_isVisibleInViewport() && _foldRetryCount < _maxFoldRetries) {
        _foldRetryCount++;
        _autoFoldTimer = Timer(
          Duration(milliseconds: widget.foldDelayMs),
          _doAutoFold,
        );
        return;
      }
      setState(() {
        _expanded = false;
        _hasAutoFolded = true;
      });
    }
  }

  /// 检测当前面板是否在视口可见（用于自动折叠前判断用户是否在阅读）。
  bool _isVisibleInViewport() {
    if (!mounted) return false;
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox) return false;
    final offset = renderObject.localToGlobal(Offset.zero);
    final screenHeight = MediaQuery.of(context).size.height;
    return offset.dy < screenHeight && offset.dy + renderObject.size.height > 0;
  }

  void _toggleExpanded() {
    // 用户手动点击：取消自动折叠定时器，标记已交互
    _autoFoldTimer?.cancel();
    _autoFoldTimer = null;
    setState(() {
      _expanded = !_expanded;
      _hasAutoFolded = true;
    });
  }

  @override
  void dispose() {
    _autoFoldTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 历史态：用 HistoryPanelShell 渲染（默认折叠、muted 箭头、入场淡入）
    if (widget.artifacts != null) {
      return _buildHistory(context);
    }

    // 标记已渲染实时态，用于切换到历史态时跳过淡入动画（问题1修复）

    final colors = context.lm.palette;
    final t = Translations.of(context);
    // reduced-motion：动效时长改 0（DOC-06B §5.1）
    // 自动折叠延时仍生效（属时序逻辑，非动效）
    final reducedMotion = LmMotion.reducedMotion(context);

    return AnimatedSize(
      duration: reducedMotion ? Duration.zero : LmMotion.base,
      // easeOut → easeInOut（DOC-06B §5.3 小窗折叠要求）
      curve: LmMotion.easeBoth,
      child: Container(
        margin: const EdgeInsets.symmetric(
          horizontal: IntermediateSpacing.sLg,
          vertical: IntermediateSpacing.sXs,
        ),
        decoration: BoxDecoration(
          color: colors.surfaceElevated,
          borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
        ),
        child: _buildContent(colors, t, reducedMotion),
      ),
    );
  }

  /// 历史态渲染：用 HistoryPanelShell 容器 + 记忆列表展开内容。
  ///
  /// DOC-11 §6.1 扩展：记忆列表之后追加【相关事实】分区，
  /// 展示事实类命中实体（按类型分组），点击实体可弹出 [FactualDetailDialog]。
  Widget _buildHistory(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    final artifacts = widget.artifacts!;
    final memories = artifacts.retrievedMemories;
    final facts = artifacts.retrievedFacts;
    final hasMemories = memories.isNotEmpty;
    final hasFacts = facts.isNotEmpty;
    final count = memories.length;

    // 摘要行：经历为空且事实为空 → "未找到"；否则显示经历计数
    // （事实数量在展开后按类型分组合计，不在摘要行展示避免信息过载）
    final summary = (hasMemories || hasFacts)
        ? t.intermediate.chat.historyRetrievalReady(
            turn: artifacts.turnNumber,
            count: count,
          )
        : t.intermediate.chat.historyRetrievalEmpty(
            turn: artifacts.turnNumber,
          );

    final children = <Widget>[];
    // 2026-07-21 调整顺序：事实层在前，经历层在后（与生成中态保持一致）
    if (hasFacts) {
      children.add(_buildFactsSection(colors, t, facts, isHistory: true));
    }
    if (hasMemories) {
      for (final m in memories) {
        children.add(_buildHistoryMemoryItem(colors, m));
      }
    }

    return context.lmUi.historyPanelShell(
      context,
      key: ValueKey('history-retrieval-${artifacts.turnNumber}'),
      summary: summary,
      animateEntrance: false,
      expandedContent: children.isEmpty
          ? const SizedBox.shrink()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: children,
            ),
    );
  }

  /// 历史记忆条目（与 _StaggeredMemoryItem 静态部分相同，无 AnimatedOpacity）
  ///
  /// 点击记忆文本可弹出 [MemoryDetailDialog] 查看 5W1E 详情（v0.2 Phase C
  /// 方案二，2026-07-19 新增）。注意：父级 HistoryPanelShell 不消费 tap，
  /// 因此这里的 InkWell 不会与外部展开/折叠逻辑冲突。
  Widget _buildHistoryMemoryItem(
    LmPalette colors,
    ExperientialMemory m,
  ) {
    // 重要性 ≥4 视为关键事件（与 _StaggeredMemoryItem 一致）
    final isKey = m.importance >= 4;
    return Padding(
      padding: const EdgeInsets.only(bottom: IntermediateSpacing.sXs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 关键事件用 primary 琥珀金星标
          Icon(
            isKey ? Icons.star : Icons.circle_outlined,
            size: 12,
            color: isKey ? colors.primary : colors.faint,
          ),
          const SizedBox(width: IntermediateSpacing.sXs),
          Expanded(
            // 点击查看 5W1E 详情（命中 outer InkWell 时由内层优先消费）
            child: InkWell(
              onTap: () =>
                  MemoryDetailDialog.showExperientialMemory(context, memory: m),
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
              child: Text(
                m.formatDisplayText(
                  emptyPlaceholder: Translations.of(context)
                      .intermediate
                      .chat
                      .memoryDetail
                      .empty,
                ),
                style: IntermediateTextStyles.caption.copyWith(
                  color: colors.ink,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(
    LmPalette colors,
    Translations t,
    bool reducedMotion,
  ) {
    if (_isRetrieving) {
      return _buildRetrieving(colors, t);
    }
    if (_isFailed) {
      return _buildFailed(colors, t, reducedMotion);
    }
    if (_isCompleted) {
      return _buildCompleted(colors, t, reducedMotion);
    }
    return const SizedBox.shrink();
  }

  /// retrieving 阶段
  Widget _buildRetrieving(LmPalette colors, Translations t) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: IntermediateSpacing.sMd,
        vertical: IntermediateSpacing.sSm,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: colors.primary,
            ),
          ),
          const SizedBox(width: IntermediateSpacing.sXs),
          Expanded(
            child: Text(
              t.intermediate.chat.retrieving,
              style: IntermediateTextStyles.caption.copyWith(
                color: colors.muted,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// 检索模式标签（2026-07-21 新增）
  ///
  /// 三种状态：
  /// - 语义检索（琥珀金）：embedding 已配置且本轮未降级
  /// - 关键词检索（灰色）：embedding 未配置
  /// - 关键词（临时降级）（红色）：本轮 embedding 调用失败，用户选择临时降级
  ///
  /// 设计要点（impeccable 规范）：
  /// - 不使用 border-left 侧条，使用透明底色 + 完整边框
  /// - 文字对比度 ≥4.5:1
  /// - 紧凑设计，不抢主摘要行视觉权重
  Widget _buildModeBadge(LmPalette colors, Translations t) {
    final String label;
    final Color textColor;
    final Color bgColor;
    final Color borderColor;

    if (widget.embeddingDegradedForRound) {
      label = t.intermediate.chat.retrievalMode.degraded;
      textColor = colors.error;
      bgColor = colors.error.withValues(alpha: 0.12);
      borderColor = colors.error.withValues(alpha: 0.4);
    } else if (!widget.embeddingConfigured) {
      label = t.intermediate.chat.retrievalMode.keyword;
      textColor = colors.muted;
      bgColor = colors.muted.withValues(alpha: 0.12);
      borderColor = colors.muted.withValues(alpha: 0.4);
    } else {
      label = t.intermediate.chat.retrievalMode.semantic;
      textColor = colors.primary;
      bgColor = colors.primary.withValues(alpha: 0.12);
      borderColor = colors.primary.withValues(alpha: 0.4);
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: 6,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: borderColor),
      ),
      child: Text(
        label,
        style: IntermediateTextStyles.caption.copyWith(
          color: textColor,
          fontSize: 10,
          fontWeight: FontWeight.w500,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  /// 完成态：折叠行 + 展开列表
  ///
  /// DOC-11 §6.1 扩展：记忆列表之后追加【相关事实】分区，
  /// 展示事实类命中实体（按类型分组），点击实体可弹出 [FactualDetailDialog]。
  Widget _buildCompleted(
    LmPalette colors,
    Translations t,
    bool reducedMotion,
  ) {
    final memories = widget.retrievedMemories ?? [];
    final facts = widget.retrievedFacts ?? [];
    final hasMemories = memories.isNotEmpty;
    final hasFacts = facts.isNotEmpty;
    final count = memories.length;
    final summary = (hasMemories || hasFacts)
        ? t.intermediate.chat.retrievalReady(count: count)
        : t.intermediate.chat.retrievalEmpty;
    // 语义模式 0 命中时的阈值口径说明——「语义」徽标是
    // 存储口径（已配置嵌入），召回还受相似度阈值约束；不解释的话
    // 「徽标亮绿但 0 命中」会被误读为缺陷。
    final showThresholdNote = !hasMemories &&
        !hasFacts &&
        widget.embeddingConfigured &&
        !widget.embeddingDegradedForRound;

    return InkWell(
      onTap: _toggleExpanded,
      borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.md)),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: IntermediateSpacing.sMd,
          vertical: IntermediateSpacing.sSm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right,
                  size: 16,
                  color: colors.primary,
                ),
                const SizedBox(width: IntermediateSpacing.sXs),
                Expanded(
                  child: Text(
                    summary,
                    style: IntermediateTextStyles.caption.copyWith(
                      color: colors.muted,
                    ),
                  ),
                ),
                // 2026-07-21：检索模式标签（语义/关键词/临时降级）
                // 让用户明确知道当前用的是什么检索模式，不再"偷偷降级"
                _buildModeBadge(colors, t),
              ],
            ),
            if (showThresholdNote) ...[
              const SizedBox(height: IntermediateSpacing.s2xs),
              Text(
                t.intermediate.chat.retrievalEmptyThresholdNote,
                style: IntermediateTextStyles.caption.copyWith(
                  color: colors.faint,
                ),
              ),
            ],
            if (_expanded) ...[
              // 2026-07-21 调整顺序：事实层在前，经历层在后。
              // 用户需求：先看到"本次请求涉及哪些角色/世界设定"建立上下文，
              // 再看具体事件细节，符合"先框架后细节"的阅读习惯。
              if (hasFacts) ...[
                const SizedBox(height: IntermediateSpacing.sSm),
                _buildFactsSection(colors, t, facts, isHistory: false),
              ],
              if (hasMemories) ...[
                const SizedBox(height: IntermediateSpacing.sSm),
                Divider(height: 1, color: colors.divider),
                const SizedBox(height: IntermediateSpacing.sSm),
                // 检索结果 stagger 淡入（DOC-06B §5.3：每条 150ms ease-out，间隔 80ms）
                ...memories.asMap().entries.map(
                  (entry) {
                    return _StaggeredMemoryItem(
                      memory: entry.value,
                      index: entry.key,
                      reducedMotion: reducedMotion,
                    );
                  },
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  /// 构建事实层分区（DOC-11 §6.1，2026-07-20 新增）
  ///
  /// 按实体类型分组（角色/地点/物品/设定/组织/杂项），每组显示类型标签 + 实体列表。
  /// 实体按 importance 降序展示，点击实体名弹出 [FactualDetailDialog]。
  ///
  /// 历史态与生成中态共用此方法：
  /// - [isHistory]=true：历史态，无 stagger 动效
  /// - [isHistory]=false：生成中态，无 stagger 动效（避免与经历层 stagger 冲突）
  Widget _buildFactsSection(
    LmPalette colors,
    Translations t,
    List<RetrievedFact> facts, {
    required bool isHistory,
  }) {
    // 按 type 分组（保持枚举定义顺序）
    final groups = <FactualEntityType, List<RetrievedFact>>{
      for (final type in FactualEntityType.values) type: [],
    };
    for (final fact in facts) {
      groups[fact.entity.type]!.add(fact);
    }

    final children = <Widget>[];
    for (final type in FactualEntityType.values) {
      final group = groups[type]!;
      if (group.isEmpty) continue;

      // 类型分组标签 + 该组实体数
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: IntermediateSpacing.sXs),
          child: Row(
            children: [
              Flexible(
                child: Text(
                  '${_typeGroupLabel(type, t)}：',
                  style: IntermediateTextStyles.caption.copyWith(
                    color: colors.muted,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: IntermediateSpacing.sXs),
              Text(
                t.intermediate.chat.factsSectionReady(count: group.length),
                style: IntermediateTextStyles.caption.copyWith(
                  color: colors.faint,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      );

      // 该组实体列表
      // 同组内按 importance 降序、primaryName 字典序
      final sorted = [...group]..sort((a, b) {
          if (a.entity.importance != b.entity.importance) {
            return b.entity.importance.compareTo(a.entity.importance);
          }
          return a.entity.primaryName.compareTo(b.entity.primaryName);
        });

      for (final fact in sorted) {
        children.add(_buildFactItem(colors, t, fact));
      }
    }

    // 分区整体：标题 + 内容
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 分区标题（独立行，与【相关往事】并列）
        Row(
          children: [
            Icon(
              Icons.public_outlined,
              size: 12,
              color: colors.primary,
            ),
            const SizedBox(width: IntermediateSpacing.sXs),
            Expanded(
              child: Text(
                t.intermediate.chat.factsSectionTitle,
                style: IntermediateTextStyles.caption.copyWith(
                  color: colors.muted,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: IntermediateSpacing.sXs),
        ...children,
      ],
    );
  }

  /// 单个事实条目（实体名 + 徽章）
  ///
  /// 点击实体名弹出 [FactualDetailDialog] 查看完整属性。
  /// 徽章：关键实体（primary 琥珀金）、命中（surfaceVariant 灰）、归档（error 红）
  Widget _buildFactItem(
    LmPalette colors,
    Translations t,
    RetrievedFact fact,
  ) {
    final entity = fact.entity;
    final chat = t.intermediate.chat;
    final name = chat.factsMatchName(
      type: _typeGroupLabel(entity.type, t),
      name: entity.primaryName,
    );
    final aliases = entity.aliases.isEmpty
        ? ''
        : chat.factsMatchAliases(
            label: chat.factDetail.aliases,
            aliases: entity.aliases.join(', '),
          );
    return Padding(
      padding: const EdgeInsets.only(
        bottom: IntermediateSpacing.sXs,
        left: IntermediateSpacing.sMd,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 关键实体用 primary 琥珀金星标
          Icon(
            fact.isKeyEntity ? Icons.star : Icons.circle_outlined,
            size: 12,
            color: fact.isKeyEntity ? colors.primary : colors.faint,
          ),
          const SizedBox(width: IntermediateSpacing.sXs),
          Expanded(
            child: InkWell(
              onTap: () => FactualDetailDialog.show(context, fact: fact),
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: IntermediateSpacing.s2xs,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 实体名（primaryName）
                    Expanded(
                      child: Text(
                        '$name$aliases',
                        style: IntermediateTextStyles.caption.copyWith(
                          color: colors.ink,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // 命中徽章（关键实体不重复显示，避免与左侧星标重复）
                    if (fact.isKeywordMatched && !fact.isKeyEntity) ...[
                      const SizedBox(width: IntermediateSpacing.sXs),
                      _buildFactBadge(
                        colors,
                        text: t.intermediate.chat.factsMatchedBadge,
                        color: colors.ink,
                        bgColor: colors.surfaceVariant,
                      ),
                    ],
                    // 归档徽章
                    if (entity.isArchived) ...[
                      const SizedBox(width: IntermediateSpacing.sXs),
                      _buildFactBadge(
                        colors,
                        text: t.intermediate.chat.factsArchivedBadge,
                        color: colors.error,
                        bgColor: colors.surfaceVariant,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 事实徽章（与 FactualDetailDialog 一致）
  Widget _buildFactBadge(
    LmPalette colors, {
    required String text,
    required Color color,
    required Color bgColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: IntermediateSpacing.sSm,
        vertical: IntermediateSpacing.s2xs,
      ),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
      ),
      child: Text(
        text,
        style: IntermediateTextStyles.caption.copyWith(
          color: color,
          fontWeight: FontWeight.w500,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  /// 界面语言中的事实类型标签。
  String _typeGroupLabel(FactualEntityType type, Translations t) {
    switch (type) {
      case FactualEntityType.character:
        return t.intermediate.chat.factsTypeCharacter;
      case FactualEntityType.location:
        return t.intermediate.chat.factsTypeLocation;
      case FactualEntityType.item:
        return t.intermediate.chat.factsTypeItem;
      case FactualEntityType.lore:
        return t.intermediate.chat.factsTypeLore;
      case FactualEntityType.organization:
        return t.intermediate.chat.factsTypeOrganization;
      case FactualEntityType.misc:
        return t.intermediate.chat.factsTypeMisc;
    }
  }

  /// 失败态：AnimatedOpacity + 灰度滤镜 + 重试按钮（DOC-06B §5.3 300ms ease-out）
  Widget _buildFailed(
    LmPalette colors,
    Translations t,
    bool reducedMotion,
  ) {
    return AnimatedOpacity(
      opacity: 0.4,
      duration: reducedMotion ? Duration.zero : LmMotion.emphasis,
      curve: LmMotion.easeStandard,
      child: ColorFiltered(
        // 灰度滤镜：饱和度 0（保留明度，去除色相）
        colorFilter: const ColorFilter.matrix(<double>[
          0.2126,
          0.7152,
          0.0722,
          0,
          0,
          0.2126,
          0.7152,
          0.0722,
          0,
          0,
          0.2126,
          0.7152,
          0.0722,
          0,
          0,
          0,
          0,
          0,
          1,
          0,
        ]),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: IntermediateSpacing.sMd,
            vertical: IntermediateSpacing.sSm,
          ),
          child: Row(
            children: [
              Icon(Icons.error_outline, size: 16, color: colors.error),
              const SizedBox(width: IntermediateSpacing.sXs),
              Expanded(
                child: Text(
                  t.intermediate.chat.retrievalFailed,
                  style: IntermediateTextStyles.caption.copyWith(
                    color: colors.muted,
                  ),
                ),
              ),
              // 重试按钮：ColorFiltered 会作用于子树绘制（按钮也灰显），
              // 但点击事件正常传递；灰显状态下按钮仍可点击符合"失败可重试"语义
              TextButton(
                onPressed: widget.onRetry,
                style: TextButton.styleFrom(
                  foregroundColor: colors.primary,
                  minimumSize: const Size(0, 32),
                  padding: const EdgeInsets.symmetric(
                    horizontal: IntermediateSpacing.sSm,
                  ),
                  textStyle: IntermediateTextStyles.caption,
                ),
                child: Text(
                  t.common.retry,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 检索记忆条目（带 stagger 淡入动效）。
///
/// DOC-06B §5.3：命中结果逐条淡入，stagger 80ms，每条 150ms ease-out。
/// reduced-motion 下瞬时显示无延时。
class _StaggeredMemoryItem extends StatefulWidget {
  const _StaggeredMemoryItem({
    required this.memory,
    required this.index,
    required this.reducedMotion,
  });

  final ExperientialMemory memory;
  final int index;
  final bool reducedMotion;

  @override
  State<_StaggeredMemoryItem> createState() => _StaggeredMemoryItemState();
}

class _StaggeredMemoryItemState extends State<_StaggeredMemoryItem> {
  bool _visible = false;
  Timer? _delayTimer;

  @override
  void initState() {
    super.initState();
    if (widget.reducedMotion) {
      // reduced-motion：立即显示
      _visible = true;
    } else {
      // stagger：延迟 index * 80ms 后显示
      _delayTimer = Timer(
        Duration(milliseconds: widget.index * 80),
        () {
          if (mounted) {
            setState(() => _visible = true);
          }
        },
      );
    }
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final m = widget.memory;
    // 重要性 ≥4 视为关键事件（default_config keyEventThreshold）
    final isKey = m.importance >= 4;

    return AnimatedOpacity(
      opacity: _visible ? 1.0 : 0.0,
      duration: widget.reducedMotion ? Duration.zero : LmMotion.fast,
      curve: LmMotion.easeStandard,
      child: Padding(
        padding: const EdgeInsets.only(bottom: IntermediateSpacing.sXs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 关键事件用 primary 琥珀金星标
            Icon(
              isKey ? Icons.star : Icons.circle_outlined,
              size: 12,
              color: isKey ? colors.primary : colors.faint,
            ),
            const SizedBox(width: IntermediateSpacing.sXs),
            Expanded(
              // 点击查看 5W1E 详情（命中外层 _toggleExpanded InkWell 时由内层优先消费）
              child: InkWell(
                onTap: () => MemoryDetailDialog.showExperientialMemory(
                  context,
                  memory: m,
                ),
                borderRadius:
                    BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
                child: Text(
                  m.formatDisplayText(
                    emptyPlaceholder: Translations.of(context)
                        .intermediate
                        .chat
                        .memoryDetail
                        .empty,
                  ),
                  style: IntermediateTextStyles.caption.copyWith(
                    color: colors.ink,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
