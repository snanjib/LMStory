import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/config_visibility.dart';
import 'package:lmstory/core/config/intermediate_prompts.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/shared/components/panel_heading.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/widgets/advanced_level_hint.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/intermediate/domain/entities/intermediate_chat_state.dart';
import 'package:lmstory/features/intermediate/presentation/pages/intermediate_chat_page.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/collapsed_sections_store.dart';
import 'package:lmstory/features/intermediate/presentation/widgets/collapsible_settings_section.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/pages/intermediate_settings_page.dart';
import 'package:lmstory/features/settings/presentation/utils/model_sampling_controls.dart';
import 'package:lmstory/features/settings/presentation/widgets/context_budget_slider.dart';
import 'package:lmstory/features/settings/presentation/widgets/intermediate_model_picker_sheet.dart';
import 'package:lmstory/features/settings/presentation/widgets/intermediate_phase_models_section.dart';
import 'package:lmstory/features/story_runtime/presentation/pages/memory_browser_page.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/seed_resource_section.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/session_settings_fields.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';
import 'package:lmstory/features/templates/presentation/support/template_l10n.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 中级模式会话设置面板（夜航主题，独立组件）。
///
/// 2026-07-21 配置架构重构：
/// - 模型区段改为 4 步骤独立配置（generating/extracting/reviewing/summarizing），
///   复用 [IntermediatePhaseModelsSection] 的会话级模式
/// - 删除原"模型与供应商"单一选择器，由 4 步骤分别配置 preset+model
/// - 优先级链：会话级 phase > 全局 phase（都没配 → 报错 E010）
///
/// 2026-07-18 重构（用户需求：故事模式每个对话需要单独的配置选项）：
/// - 4 类会话级配置：分步骤模型、提示词、生成参数、上下文窗口
/// - 工具调用会话级覆盖
/// - 用户可在会话内修改任意字段，也可重置为"使用默认"（NULL）
///
/// 2026-07-18 修订（v0.2.2 阶段 2-F 更新）：
/// - "上下文窗口"区段仅暴露 effectiveContextLimit（单次请求 token 上限）
/// - 删除 maxContextMessages（引入 CompactionPoint 压缩机制后由
///   recentMinRatio + compactionTriggerRatio 动态控制原文区，不再需要硬性消息数截断）
/// - 移除 autoCompaction / compactionThreshold（故事模式不用 Simple 的 CompactionPoint，
///   详见 DOC-09A-2 §5.1。这两个字段是 Simple 模式专用）
///
/// 生成中（phase != idle）禁用所有控件 + 头部显示提示文案。
/// 通过 IntermediateChatController.updateSession 持久化（草稿会话仅内存）。
/// 与 Simple 模式 SessionSettingsSheet 完全独立，不复用组件。
class IntermediateSessionSettingsSheet extends ConsumerStatefulWidget {
  const IntermediateSessionSettingsSheet({
    required this.session,
    super.key,
  });

  final ChatSession session;

  @override
  ConsumerState<IntermediateSessionSettingsSheet> createState() =>
      _IntermediateSessionSettingsSheetState();
}

class _IntermediateSessionSettingsSheetState
    extends ConsumerState<IntermediateSessionSettingsSheet> {
  late ChatSession _session;
  late TextEditingController _systemPromptController;
  late TextEditingController _maxTokensController;
  late TextEditingController _suggestReplyPromptController;

  List<Template> _systemPromptTemplates = [];
  List<ApiPreset> _presets = const [];
  bool _isLoading = true;

  /// 配置解析器（用于"重置为全局当前值"按钮重新快照全局默认）
  ///
  /// nullable：[_loadInitialData] 异常时保持 null，[_resetFieldToGlobal] /
  /// [_resetContextBudgetToGlobal] 会跳过重置（按钮点击无副作用）。
  /// 正常流程下在 [_loadInitialData] try 块中初始化。
  ConfigurationResolver? _resolver;

  /// 全局默认快照（用于会话级字段为 null 时显示真实全局值，而非硬编码默认）
  ///
  /// 2026-07-22 新增：第一次打开 sheet 时加载一次，让用户看到当前生效的
  /// 全局配置（如温度 1.2），而不是硬编码的 0.8。会话字段仍保持 null 语义
  ///（表示"跟随全局"），只是 UI 显示用快照值兜底。
  GlobalDefaultsSnapshot _globalSnapshot = const GlobalDefaultsSnapshot();

  /// 快照是否加载成功。
  ///
  /// [_loadInitialData] 失败时保持 false——此时 [_globalSnapshot] 是空快照，
  /// 若仍以硬编码默认值渲染「全局值」徽标会与真实全局不符（如显示
  /// 「全局 0.80」而真实是 0.70）。false 时徽标传 null 自然隐藏。
  bool _globalSnapshotReady = false;

  /// 折叠的分区 id（全局记忆，DOC-14 §3.4）。空集 = 全部展开。
  Set<String> _collapsed = <String>{};

  /// 折叠状态存储（user_overrides.ui.storySession.collapsedSections）。
  late final CollapsedSectionsStore _collapseStore;

  /// 本会话未向量化记忆数量（用于「重建向量索引」按钮显示）
  ///
  /// 2026-07-21 新增。null = 未加载（按钮显示加载中），0 = 全部已向量化，
  /// >0 = 可点击重建。重建完成后刷新该值。
  int? _pendingEmbeddingCount;

  /// 与基准维度不一致的陈旧向量数
  ///
  /// 换嵌入模型后旧向量被检索静默跳过；>0 时与未向量化数并列为重建理由。
  int _staleEmbeddingCount = 0;

  /// 生成阶段（generating）模型的有效 contextWindow（token）。
  ///
  /// 用于 [ContextBudgetSlider] 展示生成阶段 token 预估。初始值
  /// [ConfigurationResolver.defaultContextWindow]（96000），在
  /// [_loadInitialData] 中根据会话 phaseModels 解析后更新。
  int _generatingWindow = 96000;

  /// 审查阶段（reviewing）模型的有效 contextWindow（token）。
  ///
  /// null 表示会话未配置 reviewing 阶段模型（或与 generating 相同），
  /// [ContextBudgetSlider] 不展示第二组 token 预估。在 [_loadInitialData]
  /// 中根据会话 phaseModels 解析后更新。
  int? _reviewingWindow;

  /// 重建中标记（true 时禁用按钮，显示进度文案）
  bool _isRebuilding = false;

  @override
  void initState() {
    super.initState();
    // 2026-07-22 修复：从 controller.state.session 读取最新 session，
    // 而非 widget.session（可能过时）。物化后 widget.session 仍是草稿，
    // 但 controller.state.session 已是真实 session（含保存的配置）。
    // 修复"关闭设置再打开，配置变回默认"的 bug。
    _session =
        ref.read(intermediateChatControllerProvider(widget.session)).session;
    _systemPromptController = TextEditingController(
      text: _session.systemPromptOverride ?? '',
    );
    _maxTokensController = TextEditingController(
      text: _session.maxTokens?.toString() ?? '',
    );
    _suggestReplyPromptController = TextEditingController(
      text: _session.suggestReplyPromptOverride ?? '',
    );
    _collapseStore = CollapsedSectionsStore(
      ref.read(settingsRepositoryProvider),
    );
    _loadInitialData();
  }

  @override
  void dispose() {
    _systemPromptController.dispose();
    _maxTokensController.dispose();
    _suggestReplyPromptController.dispose();
    super.dispose();
  }

  // ── 数据加载 ────────────────────────────────────────────────────────

  /// 加载系统提示词模板 + 未向量化记忆数量。
  ///
  /// 2026-07-22 重构：移除 resolveIntermediateSettings 调用，
  /// 改为快照语义——会话字段在物化时已被全局快照填充，UI 直接显示会话字段值。
  /// 2026-07-21 重构：移除 presets / modelDisplayInfo 加载，
  /// 模型选择由 [IntermediatePhaseModelsSection] 内部管理。
  /// 2026-07-21 新增：并行加载 [_pendingEmbeddingCount]，供「重建向量索引」按钮显示。
  /// 2026-07-22 修复：未向量化数量按 microVectorizeThreshold 筛选，对齐
  /// rebuildEmbeddings 的实际补齐范围，避免显示数量与实际补齐数量不一致。
  Future<void> _loadInitialData() async {
    try {
      final presetRepo =
          ref.read<ApiPresetRepository>(apiPresetRepositoryProvider);
      final templateRepo =
          ref.read<TemplateRepository>(templateRepositoryProvider);
      final settingsRepo =
          ref.read<SettingsRepository>(settingsRepositoryProvider);
      final experienceRepo =
          ref.read<ExperienceRepository>(experienceRepositoryProvider);

      // 折叠状态全局记忆（DOC-14 §3.4），失败时由 catch 保持默认空集。
      _collapsed = await _collapseStore.load();

      _resolver = ConfigurationResolver(
        presetRepository: presetRepo,
        settingsRepository: settingsRepo,
        logger: const Logger('IntermediateSessionSettingsSheet'),
      );
      // 局部变量提升：避免后续使用 _resolver! 强解包（_resolver 为 nullable）
      final resolver = _resolver!;

      // 先读取阈值，再按阈值查询未向量化记忆（两者并行会导致阈值未就绪）
      final microVectorizeThreshold =
          await resolver.resolveMicroVectorizeThreshold();
      // 以最近写入维度为基准并入陈旧行，按 hasEmbedding 拆两口径
      final expectedDimensions =
          await experienceRepo.getLatestEmbeddingDimensions(_session.sessionId);

      final results = await Future.wait([
        templateRepo.getTemplatesByKind(TemplateKind.systemPrompt),
        experienceRepo.getMemoriesWithoutEmbedding(
          _session.sessionId,
          minImportance: microVectorizeThreshold,
          expectedDimensions: expectedDimensions,
        ),
        resolver.snapshotIntermediateDefaults(),
        presetRepo.getAllPresets(),
      ]);
      final templates = results[0] as List<Template>;
      final pendingMemories =
          results[1] as List<dynamic>; // List<ExperientialMemory>
      final snapshot = results[2] as GlobalDefaultsSnapshot;
      final presets = results[3] as List<ApiPreset>;

      // 读取会话 phaseModels 的 generating/reviewing 模型 contextWindow
      // 用于 ContextBudgetSlider 展示 token 预估和阶段差异。
      // 会话级 phaseModels 字段已 nullable（null = 跟随全局），
      // resolveContextWindowForPhase 内部对 null/空串返回默认 96000。
      final phaseModels = _session.phaseModels;
      final effectiveLimit = _session.effectiveContextLimit;
      final hasReviewing =
          (phaseModels.reviewingPresetId?.isNotEmpty ?? false) &&
              (phaseModels.reviewingModelId?.isNotEmpty ?? false);

      final generatingWindow = await resolver.resolveContextWindowForPhase(
        presetId: phaseModels.generatingPresetId,
        modelId: phaseModels.generatingModelId,
        effectiveContextLimit: effectiveLimit,
      );
      int? reviewingWindow;
      if (hasReviewing) {
        reviewingWindow = await resolver.resolveContextWindowForPhase(
          presetId: phaseModels.reviewingPresetId,
          modelId: phaseModels.reviewingModelId,
          effectiveContextLimit: effectiveLimit,
        );
      }

      if (!mounted) return;

      setState(() {
        _systemPromptTemplates = templates;
        _pendingEmbeddingCount = pendingMemories
            .where((m) => !(m as ExperientialMemory).hasEmbedding)
            .length;
        _staleEmbeddingCount = pendingMemories
            .where((m) => (m as ExperientialMemory).hasEmbedding)
            .length;
        _globalSnapshot = snapshot;
        _globalSnapshotReady = true;
        _presets = presets;
        _generatingWindow = generatingWindow;
        _reviewingWindow = reviewingWindow;
        _isLoading = false;
      });
    } catch (e) {
      // 加载失败时降级：仍显示 UI（使用空列表 + 默认值），不阻塞用户操作。
      if (!mounted) return;
      setState(() {
        _systemPromptTemplates = [];
        _pendingEmbeddingCount = 0;
        _staleEmbeddingCount = 0;
        _presets = const [];
        _isLoading = false;
      });
    }
  }

  /// 刷新未向量化记忆数量（重建完成后调用）
  ///
  /// 重建后 has_embedding 已更新，重新查询获取最新数量。
  /// 2026-07-22 修复：按 microVectorizeThreshold 筛选，对齐 _loadInitialData
  /// 和 rebuildEmbeddings 的筛选逻辑。
  Future<void> _refreshPendingCount() async {
    try {
      final experienceRepo =
          ref.read<ExperienceRepository>(experienceRepositoryProvider);
      // _resolver 在 _loadInitialData 中初始化，若未初始化（异常场景）用默认值 4
      final resolver = _resolver;
      final microVectorizeThreshold = resolver == null
          ? 4
          : await resolver.resolveMicroVectorizeThreshold();
      // 与 _loadInitialData 同口径并入陈旧行并拆分两口径
      final expectedDimensions =
          await experienceRepo.getLatestEmbeddingDimensions(
        _session.sessionId,
      );
      final memories = await experienceRepo.getMemoriesWithoutEmbedding(
        _session.sessionId,
        minImportance: microVectorizeThreshold,
        expectedDimensions: expectedDimensions,
      );
      if (!mounted) return;
      setState(() {
        _pendingEmbeddingCount = memories.where((m) => !m.hasEmbedding).length;
        _staleEmbeddingCount = memories.where((m) => m.hasEmbedding).length;
      });
    } catch (_) {
      // 刷新失败忽略，按钮仍显示上次数量
    }
  }

  // ── 变更推送 ────────────────────────────────────────────────────────

  Future<void> _pushUpdate(ChatSession updated) async {
    // 从 controller.state.session 同步本地副本，
    // 避免草稿物化后 sessionId 从 __draft_intermediate_xxx 变成 real-xxx，
    // 但 sheet 仍持有旧草稿 sessionId 导致第二次修改失败。
    final controller =
        ref.read(intermediateChatControllerProvider(widget.session).notifier);
    try {
      await controller.updateSession(updated);
      if (!mounted) return;
      // 通过 ref.read 读取最新 state（避免直接访问 StateNotifier.state
      // protected member）。ref.read 返回的就是当前 IntermediateChatState。
      final persisted =
          ref.read(intermediateChatControllerProvider(widget.session)).session;
      setState(() => _session = persisted);
    } catch (e) {
      const Logger('IntermediateSessionSettingsSheet')
          .error('Failed to update session', detail: '$e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(Translations.of(context).error.generic),
        ),
      );
    }
  }

  Future<String?> _ensureSessionIdForResource() async {
    final provider = intermediateChatControllerProvider(widget.session);
    final controller = ref.read(provider.notifier);
    if (controller.isDraftSession) {
      final saved = await controller.updateSession(ref.read(provider).session);
      if (!mounted || !saved) return null;
      setState(() => _session = ref.read(provider).session);
    }
    return ref.read(provider).session.sessionId;
  }

  /// null=跟随清算 + 惰性物化后，会话列
  /// 恒非 null，「!= null」判据恒「已自定义」——「全局值」标注永久失效。
  /// 改按值比较：双 null=跟随（false）；滑杆量化误差按显示精度容差；
  /// 值恰等于全局 → 显示「全局 X」标注。
  bool _doubleIsCustomized(double? sessionValue, double? globalValue) {
    if (sessionValue == null && globalValue == null) return false;
    if (sessionValue == null || globalValue == null) return true;
    return (sessionValue - globalValue).abs() >= 1e-9;
  }

  /// 重置指定字段为当前全局默认值（快照语义：使用此刻的全局值）
  ///
  /// 用户需求："保留重置按钮"——重置时读取当前全局配置的具体值，
  /// 覆盖会话级字段。调用 [ConfigurationResolver.snapshotIntermediateDefaults] 获取快照。
  Future<void> _resetFieldToGlobal(
    ChatSession Function(GlobalDefaultsSnapshot snapshot) updater,
  ) async {
    final resolver = _resolver;
    if (resolver == null) return;
    final snapshot = await resolver.snapshotIntermediateDefaults();
    await _pushUpdate(updater(snapshot));
  }

  void _onSystemPromptChanged(String value) {
    _pushUpdate(
      _session.copyWith(
        systemPromptOverride: value.isEmpty ? null : value,
      ),
    );
  }

  void _onTemplateSelected(Template template) {
    final content = template.localizedContent(Translations.of(context));
    _systemPromptController.text = content;
    _systemPromptController.selection = TextSelection.fromPosition(
      TextPosition(offset: content.length),
    );
    _pushUpdate(
      _session.copyWith(systemPromptOverride: content),
    );
  }

  void _onTemperatureChanged(double v) {
    _pushUpdate(_session.copyWith(temperature: v));
  }

  void _onTopPChanged(double v) {
    _pushUpdate(_session.copyWith(topP: v));
  }

  /// 空输入写全局当前快照（不再置 null 跟随态；
  /// 全局未配置按  写 0=无上限哨兵）。：快照不可得
  /// 时置 null（跟随）而非钉死 0——resolver 回退链在运行时取真实全局。
  Future<void> _onMaxTokensSubmitted(int? v) async {
    if (v != null) {
      await _pushUpdate(_session.copyWith(maxTokens: v));
      return;
    }
    final snapshot = await _storySnapshotOrNull();
    await _pushUpdate(
      _session.copyWith(maxTokens: snapshot?.maxTokens),
    );
  }

  void _onPresencePenaltyChanged(double v) {
    _pushUpdate(_session.copyWith(presencePenalty: v));
  }

  void _onFrequencyPenaltyChanged(double v) {
    _pushUpdate(_session.copyWith(frequencyPenalty: v));
  }

  void _onEffectiveContextLimitChanged(int? v) {
    _pushUpdate(_session.copyWith(effectiveContextLimit: v));
  }

  void _onJsonModeChanged(bool? value) {
    _pushUpdate(_session.copyWith(jsonModeOverride: value));
  }

  // ── 审查会话级覆盖（审查  新增）──

  /// 审查三态变更回调。
  ///
  /// 接受 true（开启）/ false（关闭）直接持久化；null（首项「使用全局
  /// 设置」）写全局当前快照，不再置 null 跟随态。
  /// 快照不可得时保持 null——
  /// 「不得写死 false 覆盖回退语义」（与控制器物化同口径），由 resolver
  /// 回退链在运行时兜底，钉死 false 会与全局实际值相反。
  Future<void> _onReviewEnabledChanged(bool? value) async {
    if (value != null) {
      await _pushUpdate(_session.copyWith(reviewEnabledOverride: value));
      return;
    }
    final snapshot = await _storySnapshotOrNull();
    await _pushUpdate(
      _session.copyWith(reviewEnabledOverride: snapshot?.reviewEnabled),
    );
  }

  /// 重置审查为全局当前值快照（不再置 null 跟随全局；同上，
  /// 快照不可得时保持 null 而非钉死 false）。
  Future<void> _onReviewEnabledReset() async {
    final snapshot = await _storySnapshotOrNull();
    await _pushUpdate(
      _session.copyWith(reviewEnabledOverride: snapshot?.reviewEnabled),
    );
  }

  /// 故事快照（resolver 未就绪时返回 null，调用方回落保守值）。
  Future<GlobalDefaultsSnapshot?> _storySnapshotOrNull() async {
    final resolver = _resolver;
    if (resolver == null) return null;
    return resolver.snapshotIntermediateDefaults();
  }

  // ── 上下文预算会话级覆盖（审查  修复，2026-07-31 新增）──

  /// 原文区下限比例会话级覆盖变更回调。
  ///
  /// 接受 null（跟随全局）或自定义比例值，直接持久化到
  /// [ChatSession.recentMinRatioOverride]。
  void _onRecentMinRatioOverrideChanged(double? value) {
    _pushUpdate(_session.copyWith(recentMinRatioOverride: value));
  }

  /// 检索区比例会话级覆盖变更回调。
  ///
  /// 接受 null（跟随全局）或自定义比例值，直接持久化到
  /// [ChatSession.retrievalRatioOverride]。
  void _onRetrievalRatioOverrideChanged(double? value) {
    _pushUpdate(_session.copyWith(retrievalRatioOverride: value));
  }

  /// 压缩触发线会话级覆盖变更回调（DOC-14 §3.3）。
  ///
  /// 压缩触发线始终为具体比例值（无"动态"态），直接持久化到
  /// [ChatSession.compactionTriggerRatioOverride]。
  void _onCompactionTriggerRatioOverrideChanged(double value) {
    _pushUpdate(_session.copyWith(compactionTriggerRatioOverride: value));
  }

  /// 重置 contextBudget 为当前全局值（快照独立模式的重置）。
  ///
  /// 调用 [ConfigurationResolver.snapshotIntermediateDefaults] 读取当前全局
  /// contextBudget，将 compactionTriggerRatio / recentMinRatio / retrievalRatio
  /// 三个会话级覆盖字段覆盖为全局当前值（区别于"置 null 跟随全局"——这里写入
  /// 具体值，让用户在 UI 上看到明确的数值，且后续全局变更不影响本会话）。
  Future<void> _resetContextBudgetToGlobal() async {
    final resolver = _resolver;
    if (resolver == null) return;
    final snapshot = await resolver.snapshotIntermediateDefaults();
    final budget = snapshot.contextBudget;
    await _pushUpdate(
      _session.copyWith(
        recentMinRatioOverride: budget?.recentMinRatio,
        retrievalRatioOverride: budget?.retrievalRatio,
        compactionTriggerRatioOverride: budget?.compactionTriggerRatio,
      ),
    );
  }

  // ── 推荐回复会话级配置（2026-07-29 新增）──

  /// 推荐回复模型选择回调（来自 [IntermediateModelPickerSheet]）。
  ///
  /// (null, null) 表示清除——写全局当前快照（不再置 null
  /// 跟随态）；全局未配置推荐模型时回落生成模型链由 resolver 兜底，
  /// 此处写快照空（保持未配置具体态）。
  Future<void> _onSuggestReplyModelSelected(
    String? presetId,
    String? modelId,
  ) async {
    if (presetId == null && modelId == null) {
      final snapshot = await _storySnapshotOrNull();
      await _pushUpdate(
        _session.copyWith(
          suggestReplyPresetId: snapshot?.suggestReplyPresetId,
          suggestReplyModelId: snapshot?.suggestReplyModelId,
        ),
      );
      return;
    }
    await _pushUpdate(
      _session.copyWith(
        suggestReplyPresetId: presetId,
        suggestReplyModelId: modelId,
      ),
    );
  }

  /// 推荐回复提示词即时持久化（参照 [_onSystemPromptChanged] 模式）。
  ///
  /// 空串写全局当前快照（不再置 null 跟随；全局空时写空串
  /// =「用内置默认」具体态）。
  Future<void> _onSuggestReplyPromptChanged(String value) async {
    if (value.isNotEmpty) {
      await _pushUpdate(
        _session.copyWith(suggestReplyPromptOverride: value),
      );
      return;
    }
    final snapshot = await _storySnapshotOrNull();
    await _pushUpdate(
      _session.copyWith(
        suggestReplyPromptOverride: snapshot?.suggestReplyPromptOverride ?? '',
      ),
    );
  }

  /// 重置推荐回复模型为全局当前快照（不再置 null 跟随全局）。
  Future<void> _onSuggestReplyModelReset() async {
    final snapshot = await _storySnapshotOrNull();
    await _pushUpdate(
      _session.copyWith(
        suggestReplyPresetId: snapshot?.suggestReplyPresetId,
        suggestReplyModelId: snapshot?.suggestReplyModelId,
      ),
    );
  }

  /// 重置推荐回复提示词为全局当前快照（全局空时写空串=
  /// 「用内置默认」具体态，不再置 null 跟随）。
  Future<void> _onSuggestReplyPromptReset() async {
    final snapshot = await _storySnapshotOrNull();
    final prompt = snapshot?.suggestReplyPromptOverride ?? '';
    _suggestReplyPromptController.text = prompt;
    await _pushUpdate(
      _session.copyWith(suggestReplyPromptOverride: prompt),
    );
  }

  /// 2026-07-19 Phase B：会话级 reasoningEffort 覆盖
  ///
  /// v0.2.2 阶段 2-G：思考预算仅作用于 generating（生成）和 reviewing（审查）
  /// 两个阶段。extracting/summarizing 等结构化任务阶段强制
  /// 禁用思考预算（在各自 PhaseHandler 中硬编码 ReasoningEffort.disabled）。
  /// 2026-07-21 重构：原条件 supportsReasoning 依赖 _modelDisplayInfo，重构后
  /// 4 步骤模型独立配置，无单一"当前模型"概念。UI 改为无条件显示，
  /// 模型不支持时选了不生效即可（与 IntermediateReasoningEffortSelector 一致）。
  void _onReasoningEffortChanged(ReasoningEffort? value) {
    _pushUpdate(_session.copyWith(reasoningEffort: value));
  }

  /// 跳转到全局设置页
  void _navigateToGlobalSettings() {
    Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const IntermediateSettingsPage(),
      ),
    );
  }

  // ── 辅助方法 ────────────────────────────────────────────────────────

  String? get _defaultPromptPreview {
    // 2026-07-22 重构：快照语义下，会话字段在物化时已被全局快照填充。
    // 若 session.systemPromptOverride 非空，直接预览；否则回退到内置默认角色设定。
    final sessionPrompt = _session.systemPromptOverride ?? '';
    if (sessionPrompt.isNotEmpty) {
      return sessionPrompt.length > 30
          ? sessionPrompt.substring(0, 30)
          : sessionPrompt;
    }
    // 回退到内置默认角色设定（kDefaultRolePrompt）
    return kDefaultRolePrompt.length > 30
        ? kDefaultRolePrompt.substring(0, 30)
        : kDefaultRolePrompt;
  }

  // ── 折叠状态（DOC-14 §3.4）─────────────────────────────────────────

  /// 可折叠分区 id。`memoryManagement` 常驻置顶（一键折叠时跳过，记忆库始终可达）。
  ///
  /// 补 `resource`——种子资源分区随
  /// 只读语义 2.0 加入后未登记，一键折叠漏折该区。
  static const List<String> _collapsibleSectionIds = [
    'memoryManagement',
    'phaseModels',
    'systemPrompt',
    'generation',
    'contextWindow',
    'contextBudget',
    'toolCalling',
    'resource',
    'suggestReply',
  ];

  /// 常驻分区 id（一键折叠保持展开）。
  static const String _pinnedSectionId = 'memoryManagement';

  bool _isSectionExpanded(String id) => !_collapsed.contains(id);

  Future<void> _toggleSection(String id) async {
    setState(() {
      if (_collapsed.contains(id)) {
        _collapsed.remove(id);
      } else {
        _collapsed.add(id);
      }
    });
    await _collapseStore.save(_collapsed);
  }

  /// 区级可见性键；null = 行级混排区壳（生成参数），双模式恒显，
  /// 过滤落在区内的行级键上。
  String? _sectionVisibilityKey(String id) => switch (id) {
        'memoryManagement' => ConfigVisibilityKeys.storyMemoryManagement,
        'resource' => ConfigVisibilityKeys.storyResource,
        'phaseModels' => ConfigVisibilityKeys.storyPhaseModels,
        'systemPrompt' => ConfigVisibilityKeys.storySystemPrompt,
        'generation' => null,
        'contextWindow' => ConfigVisibilityKeys.storyContextWindow,
        'contextBudget' => ConfigVisibilityKeys.storyContextBudget,
        'toolCalling' => ConfigVisibilityKeys.storyToolCalling,
        'suggestReply' => ConfigVisibilityKeys.storySuggestReply,
        _ => null,
      };

  /// 该区在当前配置显示模式下是否渲染。
  bool _isSectionRendered(String id, ConfigLevel level) {
    final key = _sectionVisibilityKey(id);
    return key == null || ConfigVisibility.of(key, level);
  }

  /// 当前模式下实际渲染的可折叠区 id——折叠批操作只作用于可见区，
  /// 被隐藏区的折叠记录原样保留，切回进阶模式恢复原折叠状态。
  Iterable<String> _renderedCollapsibleIds() {
    final level = ref.read(configLevelProvider);
    return _collapsibleSectionIds.where((id) => _isSectionRendered(id, level));
  }

  Future<void> _collapseAllSections() async {
    setState(() {
      _collapsed.addAll(
        _renderedCollapsibleIds().where((id) => id != _pinnedSectionId),
      );
    });
    await _collapseStore.save(_collapsed);
  }

  Future<void> _expandAllSections() async {
    setState(() {
      _collapsed.removeAll(_renderedCollapsibleIds());
    });
    await _collapseStore.save(_collapsed);
  }

  /// 构造一个可折叠分区（带顶部间距，标题/折叠态/回调由本类管理）。
  Widget _collapsibleSection({
    required String id,
    required String title,
    required Widget child,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: IntermediateSpacing.sMd),
      child: CollapsibleSettingsSection(
        title: title,
        isExpanded: _isSectionExpanded(id),
        onToggle: () => _toggleSection(id),
        child: child,
      ),
    );
  }

  // ── UI ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    ref.listen(settingsNotifierProvider.select((s) => s.presets), (_, presets) {
      setState(() => _presets = presets);
    });
    final t = Translations.of(context);
    final colors = context.lm.palette;
    final controllerState =
        ref.watch(intermediateChatControllerProvider(widget.session));
    // 2026-07-22 修复：failed 状态下允许修改会话配置（如模型/温度），
    // 让用户能调整配置后重试。仅 idle 和 failed 状态下可编辑。
    // 手动压缩期间 phase 仍为 idle，须并入互斥（压缩在途改会话
    // 配置会让压缩结果与后续轮口径分叉）。
    final isGenerating = (controllerState.phase != IntermediatePhase.idle &&
            controllerState.phase != IntermediatePhase.failed) ||
        controllerState.isManualCompacting;
    final globalConfig = ref.watch(intermediateConfigProvider);
    final stream = globalConfig.valueOrNull?.stream;
    final globalToolCallingEnabled = stream?.toolCallingEnabled ?? true;
    // 提取全局 contextBudget，供会话级 ContextBudgetSlider 显示全局兜底值。
    // 会话级覆盖字段为 null 时回退到这些全局值（仅用于显示，不改变 NULL 语义）。
    final globalBudget = globalConfig.valueOrNull?.contextBudget;
    // 配置显示模式：组装层按级别过滤，被隐藏区已有用户值继续生效。
    final configLevel = ref.watch(configLevelProvider);

    return Material(
      // 琉璃下面层让位 GlassBottomSheet 工厂；经典保持原槽位零变化。
      color: context.lmSheetFaceColor(colors.surface),
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(context.lmUi.radius(LmCorner.lg)),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHandle(colors),
            _buildHeader(t, colors, isGenerating),
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.all(IntermediateSpacing.s3xl),
                child: CircularProgressIndicator(),
              )
            else
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: IntermediateSpacing.sLg,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── 记忆管理（常驻置顶：一键折叠时跳过，记忆库始终可达）──
                      // DOC-14 §3.4。2026-08-06 起置顶于会话设置首屏。
                      if (_isSectionRendered('memoryManagement', configLevel))
                        _collapsibleSection(
                          id: 'memoryManagement',
                          title: t.intermediate.chat.sessionSettings
                              .sectionMemoryManagement,
                          child: _buildMemoryManagementSection(
                            t,
                            colors,
                            isGenerating,
                          ),
                        ),

                      // ── 角色卡/世界书（应用只读资源，DOC-15 §9.3）──
                      // 区段抽取为 story_runtime 共享组件（导演面板同款挂载）
                      if (_isSectionRendered('resource', configLevel))
                        _collapsibleSection(
                          id: 'resource',
                          title: t.intermediate.chat.sessionSettings
                              .sectionResource,
                          child: SeedResourceSection(
                            sessionId: controllerState.session.sessionId,
                            enabled: !isGenerating,
                            ensureSessionIdForApply:
                                _ensureSessionIdForResource,
                          ),
                        ),

                      // ── 分步骤模型（4 步骤独立配置）──
                      if (_isSectionRendered('phaseModels', configLevel))
                        _collapsibleSection(
                          id: 'phaseModels',
                          title: t.settings.intermediate.phaseModels.title,
                          child: IntermediatePhaseModelsSection(
                            session: _session,
                            onPhaseModelsChanged: (phaseModels) => _pushUpdate(
                              _session.copyWith(phaseModels: phaseModels),
                            ),
                            enabled: !isGenerating,
                          ),
                        ),

                      // ── 系统提示词 ──
                      if (_isSectionRendered('systemPrompt', configLevel))
                        _collapsibleSection(
                          id: 'systemPrompt',
                          title: t.intermediate.chat.sessionSettings
                              .sectionSystemPrompt,
                          child: IntermediateSystemPromptField(
                            controller: _systemPromptController,
                            defaultPromptPreview: _defaultPromptPreview,
                            templates: _systemPromptTemplates,
                            onChanged: _onSystemPromptChanged,
                            onTemplateSelected: _onTemplateSelected,
                            onReset: () => _resetFieldToGlobal(
                              (s) => _session.copyWith(
                                systemPromptOverride: s.systemPrompt,
                              ),
                            ),
                            enabled: !isGenerating,
                          ),
                        ),

                      // ── 生成参数（区壳双模式恒显，行级过滤：简单模式
                      //    仅见思考预算行，采样参数行仅进阶模式）──
                      if (_isSectionRendered('generation', configLevel))
                        _collapsibleSection(
                          id: 'generation',
                          title: t.intermediate.chat.sessionSettings
                              .sectionGeneration,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: _buildGenerationRows(
                              t,
                              colors,
                              isGenerating,
                              configLevel,
                              controllerState.session,
                            ),
                          ),
                        ),

                      // ── 上下文窗口 ──
                      if (_isSectionRendered('contextWindow', configLevel))
                        _collapsibleSection(
                          id: 'contextWindow',
                          title: t.intermediate.chat.sessionSettings
                              .sectionContextWindow,
                          child: IntermediateEffectiveContextLimitSlider(
                            value: _session.effectiveContextLimit,
                            isCustomized: _session.effectiveContextLimit !=
                                _globalSnapshot.effectiveContextLimit,
                            onChanged: _onEffectiveContextLimitChanged,
                            onReset: () => _resetFieldToGlobal(
                              (s) => _session.copyWith(
                                effectiveContextLimit: s.effectiveContextLimit,
                              ),
                            ),
                            enabled: !isGenerating,
                          ),
                        ),

                      // ── 上下文预算（会话级覆盖：压缩触发线/原文区下限/检索区比例）──
                      if (_isSectionRendered('contextBudget', configLevel))
                        _collapsibleSection(
                          id: 'contextBudget',
                          title: t.intermediate.chat.sessionSettings
                              .sectionContextBudget,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Material(
                                color: colors.surface,
                                borderRadius: BorderRadius.circular(
                                  context.lmUi.radius(LmCorner.lg),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.all(
                                    IntermediateSpacing.sLg,
                                  ),
                                  child: ContextBudgetSlider(
                                    compactionTriggerRatio: _session
                                            .compactionTriggerRatioOverride ??
                                        globalBudget?.compactionTriggerRatio ??
                                        0.5,
                                    recentMinRatio:
                                        _session.recentMinRatioOverride ??
                                            globalBudget?.recentMinRatio,
                                    retrievalRatio:
                                        _session.retrievalRatioOverride ??
                                            globalBudget?.retrievalRatio ??
                                            0.15,
                                    availableWindow: _generatingWindow,
                                    secondaryWindow: _reviewingWindow,
                                    recentMinTokenTarget:
                                        globalBudget?.recentMinTokenTarget ??
                                            32000,
                                    enabled: !isGenerating,
                                    onCompactionTriggerRatioChanged: !isGenerating
                                        ? _onCompactionTriggerRatioOverrideChanged
                                        : null,
                                    onMinRatioChanged: !isGenerating
                                        ? _onRecentMinRatioOverrideChanged
                                        : null,
                                    onRetrievalRatioChanged: !isGenerating
                                        ? _onRetrievalRatioOverrideChanged
                                        : null,
                                  ),
                                ),
                              ),
                              const SizedBox(height: IntermediateSpacing.sXs),
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton.icon(
                                  onPressed: isGenerating
                                      ? null
                                      : _resetContextBudgetToGlobal,
                                  icon: Icon(
                                    Icons.refresh,
                                    size: 16,
                                    color: colors.faint,
                                  ),
                                  label: Text(
                                    t.intermediate.chat.sessionSettings
                                        .resetToGlobal,
                                    style: IntermediateTextStyles.caption
                                        .copyWith(color: colors.faint),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),

                      // ── 工具调用（含审查阶段）──
                      if (_isSectionRendered('toolCalling', configLevel))
                        _collapsibleSection(
                          id: 'toolCalling',
                          title: t.intermediate.chat.sessionSettings
                              .sectionToolCalling,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              IntermediateJsonModeSelector(
                                value: _session.jsonModeOverride ??
                                    globalToolCallingEnabled,
                                onChanged: _onJsonModeChanged,
                                onReset: () => _resetFieldToGlobal(
                                  (s) => _session.copyWith(
                                    jsonModeOverride: s.jsonMode,
                                  ),
                                ),
                                enabled: !isGenerating,
                              ),
                              const SizedBox(height: IntermediateSpacing.sMd),
                              IntermediateReviewEnabledSelector(
                                value: _session.reviewEnabledOverride,
                                onChanged: _onReviewEnabledChanged,
                                onReset: _onReviewEnabledReset,
                                enabled: !isGenerating,
                              ),
                            ],
                          ),
                        ),

                      // ── 推荐回复 ──
                      if (_isSectionRendered('suggestReply', configLevel))
                        _collapsibleSection(
                          id: 'suggestReply',
                          title: t.intermediate.chat.sessionSettings
                              .sectionSuggestReply,
                          child: _buildSuggestReplySection(
                            t,
                            colors,
                            isGenerating,
                          ),
                        ),

                      // ── 底部：前往全局设置链接 ──
                      const SizedBox(height: IntermediateSpacing.sXl),
                      _buildGlobalSettingsLink(t, colors),
                      const AdvancedLevelHint(
                        surfaceId: ConfigVisibilitySurfaces.storyPanel,
                      ),
                      SizedBox(
                        height: MediaQuery.of(context).viewInsets.bottom +
                            MediaQuery.of(context).padding.bottom +
                            IntermediateSpacing.sLg,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── 记忆管理：重建向量索引 ──────────────────────────────────────────

  // ── 推荐回复区段 ──────────────────────────────────────────────────

  /// 构造「推荐回复」区段（模型选择卡片 + 提示词编辑器）。
  ///
  /// 视觉与"工具调用"/"系统提示词"区段保持一致：标题由
  /// IntermediateSectionHeader 提供，内容为 Column 布局（不嵌套卡片）。
  ///
  /// **模型卡片**：subtitle 显示规则：
  /// - 会话级已配 preset+model → "供应商名 · 模型名"
  /// - 会话级未配 → "使用全局配置（含 generating fallback）"
  ///
  /// **提示词编辑器**：TextField + 重置按钮，参照系统提示词字段设计。
  /// 空串等价于"跟随全局/内置默认"，存储为 null。
  Widget _buildSuggestReplySection(
    Translations t,
    LmPalette colors,
    bool isGenerating,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── 模型 ──
        _buildSuggestReplyModelRow(t, colors, isGenerating),
        const SizedBox(height: IntermediateSpacing.sMd),
        // ── 提示词 ──
        _buildSuggestReplyPromptRow(t, colors, isGenerating),
      ],
    );
  }

  /// 推荐回复模型行：标题 + 重置按钮 + 卡片入口。
  Widget _buildSuggestReplyModelRow(
    Translations t,
    LmPalette colors,
    bool isGenerating,
  ) {
    final currentPresetId = _session.suggestReplyPresetId ?? '';
    final currentModelId = _session.suggestReplyModelId ?? '';
    final selectedPreset =
        _presets.where((p) => p.presetId == currentPresetId).firstOrNull;
    final presetExists = currentPresetId.isEmpty || selectedPreset != null;
    final selectedModel = selectedPreset?.cachedModels
        .where((m) => m.modelId == currentModelId)
        .firstOrNull;

    final String subtitle;
    if (presetExists &&
        currentPresetId.isNotEmpty &&
        selectedPreset != null &&
        selectedModel != null) {
      final modelDesc = selectedModel.displayName ?? selectedModel.modelId;
      subtitle = '${selectedPreset.name} · $modelDesc';
    } else {
      subtitle = t.chat.sessionSettings.notConfigured;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                t.intermediate.chat.sessionSettings.suggestReplyModel,
                style: IntermediateTextStyles.caption
                    .copyWith(color: colors.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: Icon(Icons.refresh, size: 16, color: colors.faint),
              onPressed: (isGenerating || currentPresetId.isEmpty)
                  ? null
                  : _onSuggestReplyModelReset,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: t.intermediate.chat.sessionSettings.resetToGlobal,
            ),
          ],
        ),
        Text(
          t.intermediate.chat.sessionSettings.suggestReplyModelHint,
          style: IntermediateTextStyles.caption.copyWith(color: colors.faint),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: IntermediateSpacing.sXs),
        context.lmUi.settingCard(
          context,
          narrative: true,
          icon: Icons.smart_toy_outlined,
          title: t.intermediate.chat.sessionSettings.suggestReplyModel,
          subtitle: subtitle,
          enabled: !isGenerating,
          onTap: () => _showSuggestReplyModelPicker(t),
        ),
      ],
    );
  }

  /// 推荐回复提示词行：标题 + 重置按钮 + TextField。
  Widget _buildSuggestReplyPromptRow(
    Translations t,
    LmPalette colors,
    bool isGenerating,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                t.intermediate.chat.sessionSettings.suggestReplyPrompt,
                style: IntermediateTextStyles.caption
                    .copyWith(color: colors.muted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: Icon(Icons.refresh, size: 16, color: colors.faint),
              onPressed: (isGenerating ||
                      (_session.suggestReplyPromptOverride ?? '').isEmpty)
                  ? null
                  : _onSuggestReplyPromptReset,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              tooltip: t.intermediate.chat.sessionSettings.resetToGlobal,
            ),
          ],
        ),
        const SizedBox(height: IntermediateSpacing.sXs),
        TextField(
          controller: _suggestReplyPromptController,
          maxLines: 5,
          minLines: 1,
          enabled: !isGenerating,
          style: IntermediateTextStyles.bodyUi.copyWith(color: colors.ink),
          decoration: InputDecoration(
            filled: true,
            fillColor: colors.surfaceVariant,
            border: OutlineInputBorder(
              borderRadius:
                  BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: IntermediateSpacing.sMd,
              vertical: IntermediateSpacing.sSm,
            ),
            hintText:
                t.intermediate.chat.sessionSettings.suggestReplyPromptEmptyHint,
            hintStyle:
                IntermediateTextStyles.bodyUi.copyWith(color: colors.faint),
          ),
          onChanged: _onSuggestReplyPromptChanged,
        ),
      ],
    );
  }

  /// 弹出 IntermediateModelPickerSheet 选择推荐回复模型。
  ///
  /// 提供 clearLabel 让用户可清除会话级配置（回退到全局/generating）。
  void _showSuggestReplyModelPicker(Translations t) {
    final currentPresetId = _session.suggestReplyPresetId ?? '';
    final currentModelId = _session.suggestReplyModelId ?? '';

    showLmSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => IntermediateModelPickerSheet(
        selectedPresetId: currentPresetId.isEmpty ? null : currentPresetId,
        selectedModelId: currentModelId.isEmpty ? null : currentModelId,
        title: t.intermediate.chat.sessionSettings.suggestReplyModel,
        clearLabel: t.intermediate.chat.sessionSettings.resetToGlobal,
        clearSuccessMessage:
            t.intermediate.chat.sessionSettings.suggestReplyModelCleared,
        successMessage:
            t.intermediate.chat.sessionSettings.suggestReplyModelSaved,
        onModelSelected: _onSuggestReplyModelSelected,
      ),
    );
  }

  /// 构造「记忆管理」区段（标题 + 说明 + 状态行 + 操作按钮）
  ///
  /// 视觉与"工具调用"区段保持一致：标题由 IntermediateSectionHeader 提供，
  /// 内容为 Column 布局（不嵌套卡片）。
  /// 状态行显示「未向量化记忆数量」+（如有）「与新模型不匹配数量」，或
  /// 「全部已向量化」，前者用 warning 色提示。
  /// 按钮禁用条件：生成中、重建中、未加载（_pendingEmbeddingCount=null）、
  /// 两口径均为 0。
  Widget _buildMemoryManagementSection(
    Translations t,
    LmPalette colors,
    bool isGenerating,
  ) {
    final isBusy = isGenerating || _isRebuilding;
    final pendingCount = _pendingEmbeddingCount;
    // 陈旧向量（换嵌入模型后维度不符）与未向量化同为重建理由
    final hasStale = _staleEmbeddingCount > 0;
    final hasPending = pendingCount != null && (pendingCount > 0 || hasStale);
    final canRebuild = !isBusy && hasPending;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.intermediate.chat.sessionSettings.rebuildVectorIndexDesc,
          style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: IntermediateSpacing.sSm),
        Row(
          children: [
            Icon(
              hasPending
                  ? Icons.cloud_off_outlined
                  : Icons.check_circle_outline,
              size: 14,
              color: hasPending ? colors.warning : colors.success,
            ),
            const SizedBox(width: IntermediateSpacing.sXs),
            Expanded(
              child: Text(
                pendingCount == null
                    ? t.common.loading
                    : hasPending
                        ? ([
                            if (pendingCount > 0)
                              t.intermediate.chat.sessionSettings
                                  .rebuildVectorIndexCount(
                                count: pendingCount,
                              ),
                            if (hasStale)
                              t.intermediate.chat.sessionSettings
                                  .rebuildVectorIndexStaleCount(
                                count: _staleEmbeddingCount,
                              ),
                          ].join(' · '))
                        : t.intermediate.chat.sessionSettings
                            .rebuildVectorIndexNoPending,
                style: IntermediateTextStyles.caption.copyWith(
                  color: hasPending ? colors.warning : colors.muted,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: IntermediateSpacing.sMd),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: canRebuild ? _onRebuildTapped : null,
            icon: _isRebuilding
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(colors.primary),
                    ),
                  )
                : const Icon(Icons.auto_fix_high_outlined, size: 16),
            label: Text(
              _isRebuilding
                  ? t.intermediate.chat.sessionSettings
                      .rebuildVectorIndexRunning
                  : t.intermediate.chat.sessionSettings
                      .rebuildVectorIndexButton,
              style: IntermediateTextStyles.label.copyWith(
                color: canRebuild ? colors.primary : colors.faint,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            style: OutlinedButton.styleFrom(
              side: BorderSide(
                color: canRebuild ? colors.primary : colors.divider,
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: IntermediateSpacing.sMd,
                vertical: IntermediateSpacing.sSm + 2,
              ),
              shape: RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
              ),
            ),
          ),
        ),
        // ── 查看记忆库入口（2026-07-22 新增）──
        // 独立全屏页面：Tab 切换经历类 / 事实类，支持搜索 + 完整 CRUD
        const SizedBox(height: IntermediateSpacing.sMd),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _onOpenMemoryBrowser,
            icon: const Icon(Icons.library_books_outlined, size: 16),
            label: Text(
              t.intermediate.memoryBrowser.openButton,
              style: IntermediateTextStyles.label.copyWith(
                color: colors.bg,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            style: FilledButton.styleFrom(
              backgroundColor: colors.primary,
              foregroundColor: colors.bg,
              padding: const EdgeInsets.symmetric(
                horizontal: IntermediateSpacing.sMd,
                vertical: IntermediateSpacing.sSm + 2,
              ),
              shape: RoundedRectangleBorder(
                borderRadius:
                    BorderRadius.circular(context.lmUi.radius(LmCorner.xs)),
              ),
            ),
          ),
        ),
        const SizedBox(height: IntermediateSpacing.sXs),
        Text(
          t.intermediate.memoryBrowser.openButtonSubtitle,
          style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  /// 打开记忆查看器（独立全屏页面）
  ///
  /// 2026-07-22 修复：使用 `_session`（从 controller.state.session 同步的真实
  /// session，物化后为 real-xxx），而非 `widget.session`（草稿 session，物化后
  /// 仍为 draft-xxx）。记忆持久化时写入的是 real-xxx 名下，若用 draft-xxx 查询
  /// 将导致记忆库始终为空。与 line 191-200 _pushUpdate 的修复同理。
  void _onOpenMemoryBrowser() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MemoryBrowserPage(session: _session),
      ),
    );
  }

  /// 重建按钮点击：弹确认对话框 → 用户确认 → 执行重建
  Future<void> _onRebuildTapped() async {
    final count = _pendingEmbeddingCount;
    if (count == null || (count == 0 && _staleEmbeddingCount == 0)) return;

    final t = Translations.of(context);
    final confirmed = await showLmDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          t.intermediate.chat.sessionSettings.rebuildVectorIndexConfirmTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: Text(
          // 确认口径 = 未向量化 + 陈旧（重建实际处理的总条数）
          t.intermediate.chat.sessionSettings.rebuildVectorIndexConfirmContent(
            count: count + _staleEmbeddingCount,
          ),
          maxLines: 5,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.common.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              t.intermediate.chat.sessionSettings
                  .rebuildVectorIndexConfirmAction,
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;

    await _runRebuild();
  }

  /// 执行重建：显示进度对话框 → 调用 controller.rebuildEmbeddings → 显示结果
  ///
  /// 进度对话框使用 [ValueNotifier] + [ValueListenableBuilder] 实时更新进度。
  /// 失败情况（busy/not_configured）不显示进度对话框，直接显示错误 SnackBar。
  Future<void> _runRebuild() async {
    final t = Translations.of(context);
    final colors = context.lm.palette;

    setState(() => _isRebuilding = true);

    final progressNotifier =
        ValueNotifier<(int, int, int)>((0, 0, 0)); // (processed, total, failed)

    // 显示进度对话框（unawaited：通过 finally 关闭）
    unawaited(
      showLmDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => _RebuildProgressDialog(
          progressNotifier: progressNotifier,
          translations: t,
        ),
      ),
    );

    final controller = ref.read(
      intermediateChatControllerProvider(widget.session).notifier,
    );

    // 重建调用包 try/finally——查询
    // 抛异常时进度框（barrierDismissible=false）与按钮禁用态此前永久
    // 滞留，只能重启应用。异常转通用失败提示。
    final result = await controller.rebuildEmbeddings(
      onProgress: (processed, total, failed) {
        progressNotifier.value = (processed, total, failed);
      },
    ).onError((e, _) {
      return (total: 0, succeeded: 0, failed: 0, failureReason: 'error');
    });

    // 关闭进度对话框
    if (mounted) Navigator.of(context).pop();

    if (!mounted) return;

    setState(() => _isRebuilding = false);
    await _refreshPendingCount();
    if (!mounted) return;

    // 显示结果（失败原因 or 成功统计）
    final message = switch (result.failureReason) {
      'busy' =>
        t.intermediate.chat.sessionSettings.rebuildVectorIndexFailureBusy,
      'not_configured' => t.intermediate.chat.sessionSettings
          .rebuildVectorIndexFailureNotConfigured,
      'error' => t.common.error,
      _ => t.intermediate.chat.sessionSettings.rebuildVectorIndexResultSuccess(
          succeeded: result.succeeded,
          failed: result.failed,
        ),
    };
    final isError = result.failureReason != null;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          message,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        duration: Duration(seconds: isError ? 3 : 2),
        backgroundColor: isError ? colors.error : colors.success,
      ),
    );
  }

  Widget _buildGlobalSettingsLink(
    Translations t,
    LmPalette colors,
  ) {
    return Center(
      child: TextButton.icon(
        onPressed: _navigateToGlobalSettings,
        icon: Icon(
          Icons.settings_outlined,
          size: 16,
          color: colors.primary,
        ),
        label: Text(
          t.intermediate.chat.sessionSettings.openGlobalSettings,
          style: IntermediateTextStyles.caption.copyWith(color: colors.primary),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  (String?, String?) _samplingModelForPhase(ChatSession session, String phase) {
    final (presetId, modelId) = session.phaseModels.forPhase(phase);
    final (globalPresetId, globalModelId) =
        _globalSnapshot.phaseModels?.forPhase(phase) ?? (null, null);
    return (
      (presetId?.isNotEmpty ?? false) ? presetId : globalPresetId,
      (modelId?.isNotEmpty ?? false) ? modelId : globalModelId,
    );
  }

  /// 采样参数只在进阶模式且有使用这些参数的模型时显示。
  List<Widget> _buildGenerationRows(
    Translations t,
    LmPalette colors,
    bool isGenerating,
    ConfigLevel level,
    ChatSession session,
  ) {
    final reviewEnabled =
        session.reviewEnabledOverride ?? _globalSnapshot.reviewEnabled ?? false;
    final sampling = samplingControlsForStory(
      _presets,
      generating: _samplingModelForPhase(session, 'generating'),
      reviewing:
          reviewEnabled ? _samplingModelForPhase(session, 'reviewing') : null,
      extracting: _samplingModelForPhase(session, 'extracting'),
      reasoningEffort:
          session.reasoningEffort ?? _globalSnapshot.reasoningEffort,
    );
    final rows = <Widget>[
      if (sampling.showsTemperatureAndTopP &&
          ConfigVisibility.of(
            ConfigVisibilityKeys.storyGenerationTemperature,
            level,
          ))
        IntermediateSliderField(
          label: t.intermediate.chat.sessionSettings.temperature,
          value: _session.temperature ?? _globalSnapshot.temperature ?? 0.8,
          min: 0,
          max: 2,
          divisions: 200,
          // 标注值来源（会话自定义 vs 全局）
          isCustomized: _doubleIsCustomized(
            _session.temperature,
            _globalSnapshot.temperature,
          ),
          // 快照加载失败时传 null（徽标隐藏），
          // 不猜硬编码默认值冒充真实全局
          globalValueText: _globalSnapshotReady
              ? (_globalSnapshot.temperature ?? 0.8).toStringAsFixed(2)
              : null,
          onChanged: _onTemperatureChanged,
          onReset: () => _resetFieldToGlobal(
            (s) => _session.copyWith(temperature: s.temperature),
          ),
          enabled: !isGenerating,
        ),
      if (sampling.showsTemperatureAndTopP &&
          ConfigVisibility.of(
            ConfigVisibilityKeys.storyGenerationTopP,
            level,
          ))
        IntermediateSliderField(
          label: t.intermediate.chat.sessionSettings.topP,
          value: _session.topP ?? _globalSnapshot.topP ?? 0.95,
          min: 0,
          max: 1,
          divisions: 100,
          isCustomized: _doubleIsCustomized(
            _session.topP,
            _globalSnapshot.topP,
          ),
          globalValueText: _globalSnapshotReady
              ? (_globalSnapshot.topP ?? 0.95).toStringAsFixed(2)
              : null,
          onChanged: _onTopPChanged,
          onReset: () =>
              _resetFieldToGlobal((s) => _session.copyWith(topP: s.topP)),
          enabled: !isGenerating,
        ),
      if (ConfigVisibility.of(
        ConfigVisibilityKeys.storyGenerationMaxTokens,
        level,
      ))
        IntermediateMaxTokensField(
          controller: _maxTokensController,
          isCustomized: _session.maxTokens != _globalSnapshot.maxTokens,
          globalValueText: _globalSnapshotReady
              ? _globalSnapshot.maxTokens?.toString()
              : null,
          onSubmitted: _onMaxTokensSubmitted,
          onReset: () => _resetFieldToGlobal(
            (s) => _session.copyWith(maxTokens: s.maxTokens),
          ),
          enabled: !isGenerating,
        ),
      if (sampling.showsPenalties &&
          ConfigVisibility.of(
            ConfigVisibilityKeys.storyGenerationPresencePenalty,
            level,
          ))
        IntermediateSliderField(
          label: t.intermediate.chat.sessionSettings.presencePenalty,
          value: _session.presencePenalty ??
              _globalSnapshot.presencePenalty ??
              0.6,
          min: -2,
          max: 2,
          divisions: 400,
          isCustomized: _doubleIsCustomized(
            _session.presencePenalty,
            _globalSnapshot.presencePenalty,
          ),
          globalValueText: _globalSnapshotReady
              ? (_globalSnapshot.presencePenalty ?? 0.6).toStringAsFixed(2)
              : null,
          onChanged: _onPresencePenaltyChanged,
          onReset: () => _resetFieldToGlobal(
            (s) => _session.copyWith(presencePenalty: s.presencePenalty),
          ),
          hint: t.intermediate.chat.sessionSettings.presencePenaltyHint,
          enabled: !isGenerating,
        ),
      if (sampling.showsPenalties &&
          ConfigVisibility.of(
            ConfigVisibilityKeys.storyGenerationFrequencyPenalty,
            level,
          ))
        IntermediateSliderField(
          label: t.intermediate.chat.sessionSettings.frequencyPenalty,
          value: _session.frequencyPenalty ??
              _globalSnapshot.frequencyPenalty ??
              0.3,
          min: -2,
          max: 2,
          divisions: 400,
          isCustomized: _doubleIsCustomized(
            _session.frequencyPenalty,
            _globalSnapshot.frequencyPenalty,
          ),
          globalValueText: _globalSnapshotReady
              ? (_globalSnapshot.frequencyPenalty ?? 0.3).toStringAsFixed(2)
              : null,
          onChanged: _onFrequencyPenaltyChanged,
          onReset: () => _resetFieldToGlobal(
            (s) => _session.copyWith(frequencyPenalty: s.frequencyPenalty),
          ),
          hint: t.intermediate.chat.sessionSettings.frequencyPenaltyHint,
          enabled: !isGenerating,
        ),
      // 思考预算行：双模式可见（BYOK 成本旋钮，五档白话文案）
      IntermediateReasoningEffortSelector(
        value: _session.reasoningEffort,
        effectiveValue: _globalSnapshot.reasoningEffort,
        onChanged: _onReasoningEffortChanged,
        onReset: () => _resetFieldToGlobal(
          (s) => _session.copyWith(reasoningEffort: s.reasoningEffort),
        ),
        enabled: !isGenerating,
      ),
    ];

    return [
      for (var i = 0; i < rows.length; i++) ...[
        if (i > 0) const SizedBox(height: IntermediateSpacing.sMd),
        rows[i],
      ],
    ];
  }

  Widget _buildHandle(LmPalette colors) {
    return Padding(
      padding: const EdgeInsets.only(top: IntermediateSpacing.sSm),
      child: Container(
        width: 32,
        height: 4,
        decoration: BoxDecoration(
          color: colors.faint.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildHeader(
    Translations t,
    LmPalette colors,
    bool isGenerating,
  ) {
    return Padding(
      padding: const EdgeInsets.all(IntermediateSpacing.sLg),
      child: PanelHeading(
        title: t.intermediate.chat.sessionSettings.title,
        subtitle: isGenerating
            ? t.intermediate.chat.sessionSettings.generatingDisabled
            : null,
        actions: [
          _buildCollapseToggleButton(
            colors: colors,
            icon: Icons.unfold_less_rounded,
            tooltip: t.intermediate.chat.sessionSettings.collapseAll,
            onTap: _collapseAllSections,
          ),
          _buildCollapseToggleButton(
            colors: colors,
            icon: Icons.unfold_more_rounded,
            tooltip: t.intermediate.chat.sessionSettings.expandAll,
            onTap: _expandAllSections,
          ),
          IconButton(
            //  语义缺口：复用 common.close（不新增 i18n key）。
            tooltip: t.common.close,
            icon: Icon(Icons.close, color: colors.muted, size: 20),
            onPressed: () => Navigator.of(context).pop(),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          ),
        ],
      ),
    );
  }

  /// 标题栏的折叠/展开工具按钮（DOC-14 §3.4）。
  Widget _buildCollapseToggleButton({
    required LmPalette colors,
    required IconData icon,
    required String tooltip,
    required Future<void> Function() onTap,
  }) {
    return IconButton(
      icon: Icon(icon, color: colors.muted, size: 20),
      onPressed: onTap,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      tooltip: tooltip,
    );
  }
}

/// 重建向量索引的进度对话框（私有 widget）
///
/// 通过 [ValueNotifier] 实时更新进度（已处理 / 总数 / 失败数）。
/// `barrierDismissible` = false：重建期间禁止用户关闭，避免半完成状态。
/// 用户必须等待重建完成（无取消按钮，因为单条记忆的 embedding 调用
/// 通常很快，重建无法中途安全中断）。
class _RebuildProgressDialog extends StatelessWidget {
  const _RebuildProgressDialog({
    required this.progressNotifier,
    required this.translations,
  });

  /// 进度状态：(processed, total, failed)
  final ValueNotifier<(int, int, int)> progressNotifier;

  final Translations translations;

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: Text(
          translations
              .intermediate.chat.sessionSettings.rebuildVectorIndexTitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: ValueListenableBuilder<(int, int, int)>(
          valueListenable: progressNotifier,
          builder: (context, value, _) {
            final (processed, total, failed) = value;
            final progress = total > 0 ? processed / total : 0.0;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                LinearProgressIndicator(
                  value: progress,
                  backgroundColor: colors.divider,
                  valueColor: AlwaysStoppedAnimation(colors.primary),
                ),
                const SizedBox(height: IntermediateSpacing.sMd),
                Text(
                  translations.intermediate.chat.sessionSettings
                      .rebuildVectorIndexProgress(
                    processed: processed,
                    total: total,
                    failed: failed,
                  ),
                  style: IntermediateTextStyles.caption
                      .copyWith(color: colors.muted),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            );
          },
        ),
        actions: const [
          // 无按钮：用户必须等待完成。
          // 完成后 _runRebuild 会调 Navigator.pop() 关闭本对话框。
        ],
      ),
    );
  }
}
