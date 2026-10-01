import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/components/experience_memory_tab.dart';
import 'package:lmstory/core/theme/intermediate/components/factual_memory_tab.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/advanced/presentation/pages/advanced_chat_page.dart';
import 'package:lmstory/features/chat/domain/entities/chat_mode.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/intermediate/presentation/pages/intermediate_chat_page.dart';
import 'package:lmstory/features/memory/domain/services/facts_merge_service.dart';
import 'package:lmstory/features/memory/domain/services/memory_index_health.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 会话记忆查看器（2026-07-22 新增）
///
/// 独立全屏页面，展示当前故事模式会话的全部记忆。
/// 两个 Tab 切换：
/// - 经历记忆（ExperientialMemory）：发生过的事件，按轮次时间线展示
/// - 事实记忆（FactualEntity + FactualAttribute）：角色/地点/物品等实体及其属性
///
/// 两类记忆均支持：搜索关键字 + 手动新增/编辑/删除（完全 CRUD）。
///
/// 视觉规范：夜航主题（DOC-06B），独立全屏 Scaffold + TabBar。
/// 入口：IntermediateSessionSettingsSheet → 记忆管理区段 → 「查看记忆库」按钮。
///
/// **调用方约束（2026-07-28 补充）**：传入的 [session] 必须是物化后的真实 session
/// （含 real sessionId，非 `__draft_*` 草稿 ID）。本页面内部直接使用
/// `widget.session.sessionId` 查询记忆库，不参与 family provider key 查找，
/// 因此不适用"family key 用 widget.session"的约定。调用方（目前仅
/// IntermediateSessionSettingsSheet）需保证传入 `controller.state.session`。
class MemoryBrowserPage extends ConsumerStatefulWidget {
  const MemoryBrowserPage({
    required this.session,
    this.initialTab = 0,
    this.preselectEntityIds = const {},
    super.key,
  });

  final ChatSession session;

  /// 初始 Tab（0=经历记忆，1=事实记忆）
  final int initialTab;

  /// 事实 Tab 预选实体并直接进多选（疑似重复/
  /// 找相似跳转归并用）
  final Set<String> preselectEntityIds;

  @override
  ConsumerState<MemoryBrowserPage> createState() => _MemoryBrowserPageState();
}

/// 归并模型解析（2026-08-26 修正）：会话当前「生成」模型。
///
/// 与故事/导演主管线同源（advanced_chat_controller.sendMessage /
/// intermediate 回合都先解析 generating）。此前走 summarizing→generating
/// 回落链，读的是会话物化时的旧「总结」快照——模型已下架/换配时归并会
/// 一直调死模型，且用户无从知晓归并用的是哪个模型。
///
/// 按会话模式分流。导演会话此前错走故事模式
/// phase 链（intermediate.phase_models.generating*），只配了导演全局
/// 模型时归并误报「模型未配置」，两边配置不同时静默用错模型——
/// 现与导演主管线同源，读 advanced.generating*。
Future<NamingConfig?> resolveSessionMergeNamingConfig(
  ConfigurationResolver resolver,
  ChatSession session,
) {
  if (session.mode == ChatMode.advanced) {
    return resolver.resolveAdvancedGeneratingNamingConfig(session);
  }
  return resolver.resolveIntermediatePhaseNamingConfig(session, 'generating');
}

class _MemoryBrowserPageState extends ConsumerState<MemoryBrowserPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      // 外部跳转可指定初始 Tab（预选进事实 Tab）
      initialIndex: widget.initialTab.clamp(0, 1),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    // 手动归并：复用总结模型配置发起一次 LLM 整合调用
    final mergeService = FactsMergeService(
      llmService: ref.read(llmServiceProvider),
    );
    final resolver = ref.read(configurationResolverProvider);

    return Scaffold(
      backgroundColor: context.scaffoldBgOf(colors.bg),
      appBar: AppBar(
        title: Text(
          t.intermediate.memoryBrowser.title,
          style: IntermediateTextStyles.title.copyWith(color: colors.ink),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: context.scaffoldBgOf(colors.bg),
        foregroundColor: colors.ink,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        bottom: TabBar(
          controller: _tabController,
          tabs: [
            Tab(
              icon: const Icon(Icons.history_outlined, size: 18),
              text: t.intermediate.memoryBrowser.tabExperiences,
            ),
            Tab(
              icon: const Icon(Icons.account_tree_outlined, size: 18),
              text: t.intermediate.memoryBrowser.tabFacts,
            ),
          ],
          labelColor: colors.primary,
          unselectedLabelColor: colors.muted,
          indicatorColor: colors.primary,
          indicatorSize: TabBarIndicatorSize.tab,
          labelStyle: IntermediateTextStyles.label,
          unselectedLabelStyle: IntermediateTextStyles.label,
          padding: const EdgeInsets.symmetric(
            horizontal: IntermediateSpacing.sSm,
          ),
        ),
      ),
      body: Column(
        children: [
          // 索引健康条——只把
          // "应索引却缺行"的缺口暴露出来（健康时完全隐藏），可一键补齐。
          _MemoryIndexHealthBanner(session: widget.session),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                ExperienceMemoryTab(sessionId: widget.session.sessionId),
                FactualMemoryTab(
                  sessionId: widget.session.sessionId,
                  mergeService: mergeService,
                  // 归并模型=会话当前生成模型（2026-08-26 修正）：
                  // 与主管线同源，避免读旧「总结」快照调死已下架模型；
                  // 所用模型在合并确认弹窗中明示。
                  resolveMergeNamingConfig: () =>
                      resolveSessionMergeNamingConfig(
                    resolver,
                    widget.session,
                  ),
                  // 外部预选（疑似重复/找相似跳转归并）
                  preselectEntityIds: widget.preselectEntityIds,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 记忆索引健康条
///
/// 记忆库里看得见的记忆，检索可能因缺 `memories_fts` 行而搜不到；低重要性
/// 记忆按策略不建索引属正常（由主表子串通道兜底），这里只把"应索引却缺行"
/// 的缺口暴露出来并提供一键补齐。向量缺口只提示（在会话设置里重建）。
/// 索引完整时整条隐藏，不占视觉噪声。
class _MemoryIndexHealthBanner extends ConsumerStatefulWidget {
  const _MemoryIndexHealthBanner({required this.session});

  final ChatSession session;

  @override
  ConsumerState<_MemoryIndexHealthBanner> createState() =>
      _MemoryIndexHealthBannerState();
}

class _MemoryIndexHealthBannerState
    extends ConsumerState<_MemoryIndexHealthBanner> {
  final _logger = const Logger('MemoryIndexHealth');

  MemoryIndexHealth? _health;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<RetrievalConfig> _retrievalConfig() async {
    if (widget.session.mode == ChatMode.advanced) {
      final config = await ref.read(advancedConfigProvider.future);
      return config.retrieval;
    }
    final config = await ref.read(intermediateConfigProvider.future);
    return config.retrieval;
  }

  MemoryIndexHealthService _service() => MemoryIndexHealthService(
        experienceRepository: ref.read(experienceRepositoryProvider),
      );

  Future<void> _refresh() async {
    try {
      final retrieval = await _retrievalConfig();
      final health = await _service().inspect(
        widget.session.sessionId,
        importanceStorageThreshold: retrieval.importanceStorageThreshold,
        microVectorizeThreshold: retrieval.microVectorizeThreshold,
      );
      if (!mounted) return;
      setState(() => _health = health);
    } catch (e) {
      _logger.warn('Memory index health inspect failed', detail: '$e');
    }
  }

  Future<void> _repair() async {
    setState(() => _busy = true);
    try {
      final retrieval = await _retrievalConfig();
      final repaired = await _service().repairKeywordIndex(
        widget.session.sessionId,
        importanceStorageThreshold: retrieval.importanceStorageThreshold,
      );
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            Translations.of(context)
                .intermediate
                .memoryBrowser
                .indexHealthRepaired(count: repaired),
          ),
        ),
      );
    } catch (e) {
      _logger.warn('Memory index repair failed', detail: '$e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            Translations.of(context)
                .intermediate
                .memoryBrowser
                .indexHealthRepairFailed,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 一键重建向量索引
  ///
  /// 复用会话控制器的 rebuildEmbeddings 流程（含未向量化 + 维度陈旧并集、
  /// 嵌入配置解析与逐条降级）；本页轻量呈现（busy 态 + 结果 SnackBar），
  /// 不复制设置面板的进度对话框。
  Future<void> _rebuildEmbeddings() async {
    setState(() => _busy = true);
    final t = Translations.of(context);
    try {
      final result = widget.session.mode == ChatMode.advanced
          ? await ref
              .read(advancedChatControllerProvider(widget.session).notifier)
              .rebuildEmbeddings(
                onProgress: (processed, total, failed) {},
              )
          : await ref
              .read(intermediateChatControllerProvider(widget.session).notifier)
              .rebuildEmbeddings(
                onProgress: (processed, total, failed) {},
              );
      await _refresh();
      if (!mounted) return;
      final message = switch (result.failureReason) {
        'busy' =>
          t.intermediate.chat.sessionSettings.rebuildVectorIndexFailureBusy,
        'not_configured' => t.intermediate.chat.sessionSettings
            .rebuildVectorIndexFailureNotConfigured,
        _ =>
          t.intermediate.chat.sessionSettings.rebuildVectorIndexResultSuccess(
            succeeded: result.succeeded,
            failed: result.failed,
          ),
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(message, maxLines: 2, overflow: TextOverflow.ellipsis),
        ),
      );
    } catch (e) {
      _logger.warn('Embedding rebuild from banner failed', detail: '$e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            t.intermediate.memoryBrowser.indexHealthRepairFailed,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final health = _health;
    if (health == null || health.isHealthy) return const SizedBox.shrink();

    final colors = context.lm.palette;
    final t = Translations.of(context);
    // 向量缺口拆两口径——「未向量化」（has_embedding=false）与
    // 「与新模型不匹配」（换嵌入模型后维度不符的陈旧向量）。
    final hasVectorGap = health.memoriesWithoutEmbedding > 0 ||
        health.staleEmbeddingMemories > 0;
    final pending = <String>[
      if (!health.keywordIndexHealthy)
        t.intermediate.memoryBrowser.indexHealthKeywordPending(
          count: health.unindexedIndexableMemories,
        ),
      if (health.memoriesWithoutEmbedding > 0)
        t.intermediate.memoryBrowser.indexHealthEmbeddingPending(
          count: health.memoriesWithoutEmbedding,
        ),
      if (health.staleEmbeddingMemories > 0)
        t.intermediate.memoryBrowser.indexHealthEmbeddingStale(
          count: health.staleEmbeddingMemories,
        ),
    ];

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(
        IntermediateSpacing.sMd,
        IntermediateSpacing.sSm,
        IntermediateSpacing.sMd,
        0,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: IntermediateSpacing.sMd,
        vertical: IntermediateSpacing.sXs,
      ),
      decoration: BoxDecoration(
        color: colors.warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colors.warning.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 14, color: colors.warning),
          const SizedBox(width: IntermediateSpacing.sXs),
          Expanded(
            child: Text(
              '${t.intermediate.memoryBrowser.indexHealthTitle} · '
              '${pending.join(' · ')}',
              style: IntermediateTextStyles.caption.copyWith(
                color: colors.muted,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (!health.keywordIndexHealthy)
            TextButton(
              onPressed: _busy ? null : _repair,
              style: TextButton.styleFrom(
                foregroundColor: colors.primary,
                visualDensity: VisualDensity.compact,
              ),
              child: Text(
                t.intermediate.memoryBrowser.indexHealthRepair,
                style: IntermediateTextStyles.caption.copyWith(
                  color: colors.primary,
                ),
              ),
            ),
          // 向量缺口一键重建（复用控制器 rebuildEmbeddings，
          // 未向量化与陈旧维度并集逐条补齐）
          if (hasVectorGap)
            TextButton(
              onPressed: _busy ? null : _rebuildEmbeddings,
              style: TextButton.styleFrom(
                foregroundColor: colors.primary,
                visualDensity: VisualDensity.compact,
              ),
              child: Text(
                t.intermediate.chat.sessionSettings.rebuildVectorIndexButton,
                style: IntermediateTextStyles.caption.copyWith(
                  color: colors.primary,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
