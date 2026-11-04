import 'package:lmstory/core/config/intermediate_config.dart'
    show PhaseModelsConfig;
import 'package:meta/meta.dart';

/// 故事模式会话级分步骤模型配置（schemaVersion ≥ 23，2026-07-21 新增）
///
/// 4 个生成步骤（generating/extracting/reviewing/summarizing）各自独立的
/// preset+model 覆盖。所有字段 nullable，null = 使用全局步骤配置
/// （`intermediate.phase_models.*`）。
///
/// 设计变更背景：删除原 `intermediate.model_id`/`preset_id` 中间层后，
/// 故事模式模型配置优先级简化为：**会话级 phase > 全局 phase**。
/// 没配就报错或走降级，不再回退到 Simple 模式默认。
///
/// 与 [PhaseModelsConfig]（全局配置）的区别：
/// - 全局 `PhaseModelsConfig` 字段为 `String`（空串 = 未配置）
/// - 会话级 `SessionPhaseModels` 字段为 `String?`（null = 未配置）
///
/// 持久化：`chat_sessions.{phase}_preset_id` / `{phase}_model_id` 8 列。
@immutable
class SessionPhaseModels {
  const SessionPhaseModels({
    this.generatingPresetId,
    this.generatingModelId,
    this.extractingPresetId,
    this.extractingModelId,
    this.reviewingPresetId,
    this.reviewingModelId,
    this.summarizingPresetId,
    this.summarizingModelId,
  });

  /// 全空实例（所有步骤均未配置，回退到全局步骤配置）。
  const SessionPhaseModels.empty()
      : generatingPresetId = null,
        generatingModelId = null,
        extractingPresetId = null,
        extractingModelId = null,
        reviewingPresetId = null,
        reviewingModelId = null,
        summarizingPresetId = null,
        summarizingModelId = null;

  final String? generatingPresetId;
  final String? generatingModelId;
  final String? extractingPresetId;
  final String? extractingModelId;
  final String? reviewingPresetId;
  final String? reviewingModelId;
  final String? summarizingPresetId;
  final String? summarizingModelId;

  /// 所有步骤均未配置（全部回退到全局步骤配置）
  bool get isAllEmpty =>
      generatingPresetId == null &&
      generatingModelId == null &&
      extractingPresetId == null &&
      extractingModelId == null &&
      reviewingPresetId == null &&
      reviewingModelId == null &&
      summarizingPresetId == null &&
      summarizingModelId == null;

  /// 获取指定阶段的 (presetId, modelId) 元组
  ///
  /// [phase] 取值：'generating' | 'extracting' | 'reviewing' | 'summarizing'。
  /// 非法 phase 返回 (null, null)。
  (String?, String?) forPhase(String phase) {
    switch (phase) {
      case 'generating':
        return (generatingPresetId, generatingModelId);
      case 'extracting':
        return (extractingPresetId, extractingModelId);
      case 'reviewing':
        return (reviewingPresetId, reviewingModelId);
      case 'summarizing':
        return (summarizingPresetId, summarizingModelId);
      default:
        return (null, null);
    }
  }

  /// 创建副本，更新指定阶段的 preset/model。
  ///
  /// 传 null 表示清除该字段；传值表示更新该字段。
  /// 不传（默认 _sentinel）表示保持原值。
  SessionPhaseModels copyWithPhase({
    required String phase,
    Object? presetId = _sentinel,
    Object? modelId = _sentinel,
  }) {
    final newPreset = presetId == _sentinel ? null : presetId as String?;
    final newModel = modelId == _sentinel ? null : modelId as String?;
    switch (phase) {
      case 'generating':
        return SessionPhaseModels(
          generatingPresetId:
              presetId == _sentinel ? generatingPresetId : newPreset,
          generatingModelId:
              modelId == _sentinel ? generatingModelId : newModel,
          extractingPresetId: extractingPresetId,
          extractingModelId: extractingModelId,
          reviewingPresetId: reviewingPresetId,
          reviewingModelId: reviewingModelId,
          summarizingPresetId: summarizingPresetId,
          summarizingModelId: summarizingModelId,
        );
      case 'extracting':
        return SessionPhaseModels(
          generatingPresetId: generatingPresetId,
          generatingModelId: generatingModelId,
          extractingPresetId:
              presetId == _sentinel ? extractingPresetId : newPreset,
          extractingModelId:
              modelId == _sentinel ? extractingModelId : newModel,
          reviewingPresetId: reviewingPresetId,
          reviewingModelId: reviewingModelId,
          summarizingPresetId: summarizingPresetId,
          summarizingModelId: summarizingModelId,
        );
      case 'reviewing':
        return SessionPhaseModels(
          generatingPresetId: generatingPresetId,
          generatingModelId: generatingModelId,
          extractingPresetId: extractingPresetId,
          extractingModelId: extractingModelId,
          reviewingPresetId:
              presetId == _sentinel ? reviewingPresetId : newPreset,
          reviewingModelId: modelId == _sentinel ? reviewingModelId : newModel,
          summarizingPresetId: summarizingPresetId,
          summarizingModelId: summarizingModelId,
        );
      case 'summarizing':
        return SessionPhaseModels(
          generatingPresetId: generatingPresetId,
          generatingModelId: generatingModelId,
          extractingPresetId: extractingPresetId,
          extractingModelId: extractingModelId,
          reviewingPresetId: reviewingPresetId,
          reviewingModelId: reviewingModelId,
          summarizingPresetId:
              presetId == _sentinel ? summarizingPresetId : newPreset,
          summarizingModelId:
              modelId == _sentinel ? summarizingModelId : newModel,
        );
      default:
        return this;
    }
  }

  static const _sentinel = Object();
}
