import 'package:lmstory/core/llm/reasoning_effort.dart';
import 'package:lmstory/core/network/llm_adapters/anthropic_compat_options.dart';
import 'package:lmstory/core/network/llm_adapters/sampling_params.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';

/// The sampling fields that a selected model can receive from these controls.
enum SamplingControls {
  none,
  temperatureAndTopP,
  all;

  bool get showsTemperatureAndTopP => this != none;
  bool get showsPenalties => this == all;
}

bool hasModelSelection((String?, String?) selection) =>
    (selection.$1?.isNotEmpty ?? false) && (selection.$2?.isNotEmpty ?? false);

SamplingControls samplingControlsForModel(
  List<ApiPreset> presets,
  (String?, String?) selection, {
  ReasoningEffort? reasoningEffort,
}) {
  final (presetId, modelId) = selection;
  final preset = presets.where((p) => p.presetId == presetId).firstOrNull;
  if (preset == null || modelId == null || modelId.isEmpty) {
    return SamplingControls.all;
  }

  switch (preset.protocol) {
    case LlmProtocol.geminiNative:
      return SamplingControls.none;
    case LlmProtocol.anthropic:
      final options = AnthropicCompatOptions.resolve(
        baseUrl: preset.baseUrl,
        providerOptions: preset.providerOptions,
      );
      return options.sendSampling
          ? SamplingControls.temperatureAndTopP
          : SamplingControls.none;
    case LlmProtocol.openaiCompatible:
    case LlmProtocol.openaiResponses:
      if (shouldOmitSamplingParams(
        modelId: modelId,
        providerOptions: preset.providerOptions,
        baseUrl: preset.baseUrl,
      )) {
        return SamplingControls.none;
      }
      if (preset.protocol == LlmProtocol.openaiCompatible) {
        return SamplingControls.all;
      }
      return (reasoningEffort?.isEnabled ?? false)
          ? SamplingControls.none
          : SamplingControls.temperatureAndTopP;
  }
}

/// Story generation and review consume the same values. When review is
/// enabled, its fallback order is the extraction model and the generation model.
SamplingControls samplingControlsForStory(
  List<ApiPreset> presets, {
  required (String?, String?) generating,
  (String?, String?)? reviewing,
  (String?, String?)? extracting,
  ReasoningEffort? reasoningEffort,
}) {
  final generation = samplingControlsForModel(
    presets,
    generating,
    reasoningEffort: reasoningEffort,
  );
  if (reviewing == null) return generation;
  final reviewModel = hasModelSelection(reviewing) ? reviewing : extracting;
  if (reviewModel == null || !hasModelSelection(reviewModel)) {
    return generation;
  }
  final review = samplingControlsForModel(
    presets,
    reviewModel,
    reasoningEffort: reasoningEffort,
  );
  if (generation.showsPenalties || review.showsPenalties) {
    return SamplingControls.all;
  }
  return generation.showsTemperatureAndTopP || review.showsTemperatureAndTopP
      ? SamplingControls.temperatureAndTopP
      : SamplingControls.none;
}
