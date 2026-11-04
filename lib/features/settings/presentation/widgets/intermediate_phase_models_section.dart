import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_spacing.dart';
import 'package:lmstory/core/theme/intermediate/intermediate_text_styles.dart';
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/session_phase_models.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/widgets/intermediate_model_picker_sheet.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事模式分步骤模型配置区块（夜航主题，可复用）。
///
/// **2026-07-21 配置架构重构**：
/// - 删除原"故事模式默认模型"层（intermediate.modelId/presetId）
/// - 故事模式仅保留两层模型配置：会话级 phaseModels + 全局级 phaseModels
/// - 优先级：会话级 > 全局级；都没配 → 报错（不再回退到 broadcastChat）
///
/// **2026-07-24 双菜单→单菜单改造**：
/// - 删除原"供应商 dropdown + 模型 dropdown"双 dropdown 设计
/// - 改为每个阶段一个 叙事设置卡（context.lmUi.settingCard）入口，点击弹出
///   [IntermediateModelPickerSheet]（夜航主题，按供应商分组 + 折叠）
/// - 卡片副标题显示当前生效模型：会话级 > 全局级回退 > "未配置"
/// - 两种模式均提供清除按钮（：全局模式配后无清除路径）：
///   会话级"使用全局配置"写 null；全局"未配置"移除 user_overrides 双键
///
/// 此组件支持两种使用模式：
/// - **全局模式**（默认）：在「故事模式设置 → 模型」子页中，
///   读写 `intermediate.phase_models.*` 到 user_overrides
/// - **会话级模式**：在会话设置面板中，读写 [ChatSession.phaseModels]，
///   通过 [onPhaseModelsChanged] 回调推送变更
///
/// 持久化（全局模式）：SettingsRepository.user_overrides
/// - `intermediate.phase_models.<phase>_preset_id`
/// - `intermediate.phase_models.<phase>_model_id`
class IntermediatePhaseModelsSection extends ConsumerStatefulWidget {
  const IntermediatePhaseModelsSection({
    this.session,
    this.onPhaseModelsChanged,
    this.enabled = true,
    super.key,
  }) : assert(
          session == null || onPhaseModelsChanged != null,
          '会话级模式必须提供 onPhaseModelsChanged 回调',
        );

  /// 会话级模式时传入的会话对象。null = 全局模式。
  final ChatSession? session;

  /// 会话级模式时的变更回调。全局模式忽略此参数。
  final void Function(SessionPhaseModels phaseModels)? onPhaseModelsChanged;

  /// 是否启用所有控件（生成中应传 false）。
  final bool enabled;

  @override
  ConsumerState<IntermediatePhaseModelsSection> createState() =>
      _IntermediatePhaseModelsSectionState();
}

class _IntermediatePhaseModelsSectionState
    extends ConsumerState<IntermediatePhaseModelsSection> {
  /// 四个阶段的元数据（key + 全局持久化 key 前缀 + i18n 标签）
  static const _phases = <_PhaseMeta>[
    _PhaseMeta(
      key: 'generating',
      presetIdKey: 'intermediate.phase_models.generating_preset_id',
      modelIdKey: 'intermediate.phase_models.generating_model_id',
    ),
    _PhaseMeta(
      key: 'extracting',
      presetIdKey: 'intermediate.phase_models.extracting_preset_id',
      modelIdKey: 'intermediate.phase_models.extracting_model_id',
    ),
    _PhaseMeta(
      key: 'reviewing',
      presetIdKey: 'intermediate.phase_models.reviewing_preset_id',
      modelIdKey: 'intermediate.phase_models.reviewing_model_id',
    ),
    _PhaseMeta(
      key: 'summarizing',
      presetIdKey: 'intermediate.phase_models.summarizing_preset_id',
      modelIdKey: 'intermediate.phase_models.summarizing_model_id',
    ),
  ];

  List<ApiPreset> _presets = const [];
  bool _isLoading = true;
  bool _hasError = false;

  /// 2026-07-21 修复 stale bug：把清理逻辑移到 _isLoading == false 之后。
  /// 原实现：initState 同步调度 _loadPresets 异步加载 → 首次 build() 同步执行时
  /// _presets = const [] → selectedPreset = null → presetExists = false →
  /// 触发 _clearStalePhaseConfig() → 永久删除用户配置。
  /// 现修复：stale 清理仅在 _presets 已加载（_isLoading == false）后触发。
  bool _staleCleared = false;

  bool get _isSessionMode => widget.session != null;

  @override
  void initState() {
    super.initState();
    Future.microtask(_loadPresets);
  }

  Future<void> _loadPresets() async {
    try {
      final presets =
          await ref.read(apiPresetRepositoryProvider).getAllPresets();
      if (!mounted) return;
      setState(() {
        _presets = presets;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _hasError = true;
        _isLoading = false;
      });
    }
  }

  /// 读取当前阶段配置（统一接口，区分全局/会话级模式）
  ///
  /// 2026-07-22 修复：会话级模式下，会话级值为 null 时回退到全局配置值，
  /// 让用户第一次打开就能看到当前生效的具体模型名（而非"使用全局配置"文字）。
  /// 底层会话字段仍保持 null 语义（表示"跟随全局"），物化时才快照填充。
  (String, String) _readPhase(_PhaseMeta phase) {
    if (_isSessionMode) {
      final (presetId, modelId) =
          widget.session!.phaseModels.forPhase(phase.key);
      if (presetId != null && presetId.isNotEmpty) {
        return (presetId, modelId ?? '');
      }
      // 会话级未配置 → 回退到全局配置值（仅用于 UI 显示，不写入会话字段）
      return _readGlobalPhase(phase);
    }
    return _readGlobalPhase(phase);
  }

  /// 从全局配置读取阶段模型配置
  (String, String) _readGlobalPhase(_PhaseMeta phase) {
    final config = ref.read(intermediateConfigProvider).valueOrNull;
    final pm = config?.phaseModels ?? const PhaseModelsConfig();
    switch (phase.key) {
      case 'generating':
        return (pm.generatingPresetId, pm.generatingModelId);
      case 'extracting':
        return (pm.extractingPresetId, pm.extractingModelId);
      case 'reviewing':
        return (pm.reviewingPresetId, pm.reviewingModelId);
      case 'summarizing':
        return (pm.summarizingPresetId, pm.summarizingModelId);
      default:
        return ('', '');
    }
  }

  /// 持久化阶段模型选择（区分全局/会话级模式）。
  ///
  /// 接受 null 表示"清除选择/跟随全局"：
  /// - 会话级模式：写入 null 到 phaseModels 对应字段（表示跟随全局）
  /// - 全局模式：移除 user_overrides 中的 preset_id 和 model_id
  Future<void> _persistPhase(
    _PhaseMeta phase,
    String? presetId,
    String? modelId,
  ) async {
    if (_isSessionMode) {
      // 清除 (null,null) 写全局当前阶段的快照——分步模型
      // 的 null 是「跟随全局」值态；全局未配该阶段时保持会话原值
      //（同为「未配置」具体态）。
      var effectivePreset = presetId;
      var effectiveModel = modelId;
      if (presetId == null && modelId == null) {
        final config = ref.read(intermediateConfigProvider).valueOrNull;
        final globalPhase = config?.phaseModels;
        final presetForPhase = switch (phase.key) {
          'generating' => globalPhase?.generatingPresetId,
          'extracting' => globalPhase?.extractingPresetId,
          'reviewing' => globalPhase?.reviewingPresetId,
          _ => globalPhase?.summarizingPresetId,
        };
        final modelForPhase = switch (phase.key) {
          'generating' => globalPhase?.generatingModelId,
          'extracting' => globalPhase?.extractingModelId,
          'reviewing' => globalPhase?.reviewingModelId,
          _ => globalPhase?.summarizingModelId,
        };
        effectivePreset = (presetForPhase != null && presetForPhase.isNotEmpty)
            ? presetForPhase
            : widget.session!.phaseModels.forPhase(phase.key).$1;
        effectiveModel = (modelForPhase != null && modelForPhase.isNotEmpty)
            ? modelForPhase
            : widget.session!.phaseModels.forPhase(phase.key).$2;
      }
      final newPhaseModels = widget.session!.phaseModels.copyWithPhase(
        phase: phase.key,
        presetId: effectivePreset,
        modelId: effectiveModel,
      );
      widget.onPhaseModelsChanged!(newPhaseModels);
      return;
    }
    final repo = ref.read<SettingsRepository>(settingsRepositoryProvider);
    if (presetId == null) {
      await repo.removeUserOverride(phase.presetIdKey);
    } else {
      await repo.setUserOverride(phase.presetIdKey, presetId);
    }
    if (modelId == null) {
      await repo.removeUserOverride(phase.modelIdKey);
    } else {
      await repo.setUserOverride(phase.modelIdKey, modelId);
    }
    ref.invalidate(intermediateConfigProvider);
    if (!mounted) return;
    _showSnackbar(
      presetId == null
          ? Translations.of(context).settings.intermediate.defaultModelCleared
          : Translations.of(context).settings.intermediate.defaultModelSaved,
    );
  }

  void _showSnackbar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(
          message,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        duration: const Duration(seconds: 1),
      ),
    );
  }

  /// 获取指定阶段的 i18n 标签
  String _phaseLabel(Translations t, String key) {
    final pm = t.settings.intermediate.phaseModels;
    switch (key) {
      case 'generating':
        return pm.generating;
      case 'extracting':
        return pm.extracting;
      case 'reviewing':
        return pm.reviewing;
      case 'summarizing':
        return pm.summarizing;
      default:
        return key;
    }
  }

  /// 全局模式下读取 intermediateConfigProvider；会话级模式下不需要 watch。
  /// 此处统一 watch 以保持全局模式的即时刷新。
  PhaseModelsConfig get _globalPhaseModels {
    final config = ref.watch(intermediateConfigProvider).valueOrNull;
    return config?.phaseModels ?? const PhaseModelsConfig();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.lm.palette;
    final t = Translations.of(context);
    // 全局模式 watch（会话级模式不依赖此值，但 watch 不影响行为）
    _globalPhaseModels;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          t.settings.intermediate.phaseModels.title,
          style: IntermediateTextStyles.title.copyWith(color: colors.ink),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: IntermediateSpacing.s2xs),
        Text(
          t.settings.intermediate.phaseModels.desc,
          style: IntermediateTextStyles.caption.copyWith(color: colors.muted),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: IntermediateSpacing.sMd),
        Container(
          padding: const EdgeInsets.all(IntermediateSpacing.sLg),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius:
                BorderRadius.circular(context.lmUi.radius(LmCorner.lg)),
          ),
          child: _buildBody(colors, t),
        ),
      ],
    );
  }

  Widget _buildBody(LmPalette colors, Translations t) {
    if (_isLoading) {
      return _loadingHint(colors, t);
    }
    if (_hasError) {
      return _errorHint(colors, t);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < _phases.length; i++) ...[
          if (i > 0) ...[
            const SizedBox(height: IntermediateSpacing.sMd),
            Divider(height: 1, color: colors.divider),
            const SizedBox(height: IntermediateSpacing.sMd),
          ],
          _buildPhaseCard(_phases[i], colors, t),
        ],
      ],
    );
  }

  /// 单个阶段的模型选择卡片入口。
  ///
  /// 卡片副标题显示规则：
  /// - 已配 preset+model → "供应商名 · 模型名"
  /// - 都未配 → "未配置"（全局模式）/ "使用全局配置"（会话级模式且全局未配）
  /// - 会话级模式 + 会话级未配但全局已配 → 显示"全局：xxx · yyy"（仅 UI 显示，底层字段仍 null）
  Widget _buildPhaseCard(
    _PhaseMeta phase,
    LmPalette colors,
    Translations t,
  ) {
    final (currentPresetId, currentModelId) = _readPhase(phase);
    final selectedPreset =
        _presets.where((p) => p.presetId == currentPresetId).firstOrNull;
    final presetExists = currentPresetId.isEmpty || selectedPreset != null;
    // 2026-07-21 修复：仅在 _presets 已加载后清理 stale 引用，
    // 避免首次 build 误判触发清理。
    if (!presetExists && !_staleCleared) {
      _staleCleared = true;
      _clearStalePhaseConfig(phase);
    }
    final selectedModel = selectedPreset?.cachedModels
        .where((m) => m.modelId == currentModelId)
        .firstOrNull;

    // 判断是否是会话级模式下"会话级未配但全局已配"的情况
    // 会话级模式下，readPhase 已回退到全局值，需要判断 session 字段本身是否为空
    var isSessionNullButGlobalConfigured = false;
    if (_isSessionMode) {
      final (sessionPresetId, _) =
          widget.session!.phaseModels.forPhase(phase.key);
      final (globalPresetId, _) = _readGlobalPhase(phase);
      if ((sessionPresetId == null || sessionPresetId.isEmpty) &&
          globalPresetId.isNotEmpty) {
        isSessionNullButGlobalConfigured = true;
      }
    }

    final String subtitle;
    if (presetExists &&
        currentPresetId.isNotEmpty &&
        selectedPreset != null &&
        selectedModel != null) {
      final modelDesc = selectedModel.displayName ?? selectedModel.modelId;
      if (isSessionNullButGlobalConfigured) {
        // 会话级未配但全局已配 → 显示"全局：xxx · yyy"
        final globalDesc = '${selectedPreset.name} · $modelDesc';
        subtitle = t.chat.sessionSettings.usingGlobalPrefix(prefix: globalDesc);
      } else {
        subtitle = '${selectedPreset.name} · $modelDesc';
      }
    } else if (isSessionNullButGlobalConfigured) {
      // 全局配了 preset 但 model 缺失（异常情况）→ 仍按全局回退显示
      if (selectedPreset != null) {
        subtitle = t.chat.sessionSettings.usingGlobalPrefix(
          prefix: selectedPreset.name,
        );
      } else {
        subtitle = t.chat.sessionSettings.notConfigured;
      }
    } else if (_isSessionMode) {
      // 会话级未配时统一带出全局当前值——此前这里显示
      // 裸「使用全局配置」，而 isSessionNullButGlobalConfigured 分支显示
      // 「全局：xxx」，同一面板四种会话级覆盖为空时两种文案并存，用户会
      // 误读为各阶段配置状态不同
      final (globalPresetId, globalModelId) = _readGlobalPhase(phase);
      final globalPreset =
          _presets.where((p) => p.presetId == globalPresetId).firstOrNull;
      final globalModel = globalPreset?.cachedModels
          .where((m) => m.modelId == globalModelId)
          .firstOrNull;
      if (globalPreset != null && globalModel != null) {
        subtitle = t.chat.sessionSettings.usingGlobalPrefix(
          prefix:
              '${globalPreset.name} · ${globalModel.displayName ?? globalModel.modelId}',
        );
      } else {
        subtitle = t.settings.intermediate.phaseModels.notConfigured;
      }
    } else {
      subtitle = t.settings.intermediate.phaseModels.notConfigured;
    }

    final consumers = phase.consumers(t);
    final consumerText = t.settings.intermediate.phaseModels.consumers(
      items: consumers.join('、'),
    );

    return context.lmUi.settingCard(
      context,
      narrative: true,
      icon: Icons.smart_toy_outlined,
      title: _phaseLabel(t, phase.key),
      subtitle: '$subtitle\n$consumerText',
      enabled: widget.enabled,
      onTap: () => _showPhaseModelPicker(phase, t),
    );
  }

  /// 弹出 IntermediateModelPickerSheet 选择阶段模型。
  ///
  /// - 会话级模式：提供"使用全局配置"清除按钮，选中后通过回调写会话字段
  /// - 全局模式：提供"未配置"清除按钮，清除/选中后写
  ///   user_overrides（清除 = removeUserOverride 双键，见 [_persistPhase]）
  void _showPhaseModelPicker(_PhaseMeta phase, Translations t) {
    final (currentPresetId, currentModelId) = _readPhase(phase);
    // 会话级模式下，sheet 的 selectedPresetId 应反映会话字段本身（非回退值），
    // 这样 sheet 高亮的就是会话级实际选中的模型，而不是全局回退值。
    final String? selectedPresetId;
    final String? selectedModelId;
    if (_isSessionMode) {
      final (sessionPresetId, sessionModelId) =
          widget.session!.phaseModels.forPhase(phase.key);
      selectedPresetId = (sessionPresetId == null || sessionPresetId.isEmpty)
          ? null
          : sessionPresetId;
      selectedModelId = (sessionModelId == null || sessionModelId.isEmpty)
          ? null
          : sessionModelId;
    } else {
      selectedPresetId = currentPresetId.isEmpty ? null : currentPresetId;
      selectedModelId = currentModelId.isEmpty ? null : currentModelId;
    }

    showLmSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => IntermediateModelPickerSheet(
        selectedPresetId: selectedPresetId,
        selectedModelId: selectedModelId,
        title: _phaseLabel(t, phase.key),
        successMessage: t.settings.intermediate.defaultModelSaved,
        // 全局模式配后无清除路径——controller 的 null
        // 分支（removeUserOverride 双键）早已就绪但 UI 从未传 clearLabel。
        // 全局模式清除 tile 文案用「未配置」（与副标题空态一致）。
        clearLabel: _isSessionMode
            // 会话清除=写全局当前快照（不再置 null 跟随态）
            ? t.intermediate.chat.sessionSettings.resetToGlobal
            : t.settings.intermediate.phaseModels.notConfigured,
        clearSuccessMessage: t.settings.intermediate.defaultModelCleared,
        onModelSelected: (presetId, modelId) =>
            _persistPhase(phase, presetId, modelId),
      ),
    );
  }

  /// 异步清理指定阶段的悬空配置（仅全局模式生效）。
  ///
  /// 会话级模式不涉及 user_overrides，悬空引用由 ChatSession 自身管理，
  /// 不需要清理（用户切换/删除供应商时由上层处理）。
  Future<void> _clearStalePhaseConfig(_PhaseMeta phase) async {
    if (_isSessionMode) return;
    await Future.microtask(() async {
      if (!mounted) return;
      final repo = ref.read<SettingsRepository>(settingsRepositoryProvider);
      await repo.removeUserOverride(phase.presetIdKey);
      await repo.removeUserOverride(phase.modelIdKey);
      ref.invalidate(intermediateConfigProvider);
    });
  }

  Widget _loadingHint(LmPalette colors, Translations t) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: IntermediateSpacing.sMd),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.faint,
            ),
          ),
          const SizedBox(width: IntermediateSpacing.sSm),
          Expanded(
            child: Text(
              t.settings.intermediate.loading,
              style:
                  IntermediateTextStyles.caption.copyWith(color: colors.faint),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorHint(LmPalette colors, Translations t) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: IntermediateSpacing.sMd),
      child: Text(
        t.settings.intermediate.presetsLoadFailed,
        style: IntermediateTextStyles.caption.copyWith(color: colors.error),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// 阶段元数据（内部使用）
class _PhaseMeta {
  const _PhaseMeta({
    required this.key,
    required this.presetIdKey,
    required this.modelIdKey,
  });

  /// 阶段标识：'generating' | 'extracting' | 'reviewing' | 'summarizing'
  final String key;

  /// 持久化 key：供应商 ID（仅全局模式使用）
  final String presetIdKey;

  /// 持久化 key：模型 ID（仅全局模式使用）
  final String modelIdKey;

  /// 该槽位的消费者清单（静态映射，解析调用点核对于
  /// 2026-09-02）。换模型前看一眼「影响：XX」——帮助用户理解各阶段
  /// 模型不是摆设；summarizing 双用途（摘要 + 压缩）在此明示。
  List<String> consumers(Translations t) => switch (key) {
        'generating' => [t.settings.intermediate.phaseModels.useStoryMain],
        'extracting' => [t.settings.intermediate.phaseModels.useExtract],
        'reviewing' => [t.settings.intermediate.phaseModels.useReview],
        'summarizing' => [
            t.settings.intermediate.phaseModels.useSummarize,
            t.settings.intermediate.phaseModels.useCompaction,
          ],
        _ => const [],
      };
}
