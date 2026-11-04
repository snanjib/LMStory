import 'package:lmstory/core/llm/context_overflow.dart';

/// 400 报文命中的可降级维度。
enum AnthropicDegradation {
  /// 去掉 temperature/top_p。
  dropSampling,

  /// 去掉 thinking / output_config。
  dropThinking,

  /// tool_choice any/tool 降级为 auto。
  downgradeToolChoiceToAuto,

  /// 剥离历史 assistant 的 thinking/redacted_thinking block。
  stripThinkingBlocks,
}

/// 判定 400 报文是否指向某个可降级参数。
///
/// 只在请求尚未产出任何内容时由降级装饰器调用；每个维度
/// 只应用一次。匹配必须尽量具体，避免把中转站回显的请求体误判为参数错误。
AnthropicDegradation? classifyAnthropicRejection({
  required String message,
  required String? code,
  required Set<AnthropicDegradation> applied,
  bool hasThinkingBlocks = false,
  bool hasSamplingParams = true,
  bool hasThinkingConfig = true,
  bool hasToolChoiceAnyOrTool = true,
}) {
  if (isContextOverflowText(message, code)) return null;
  if (!_isBadRequest(code, message)) return null;

  final lower = message.toLowerCase();

  // block/signature 错误先于参数错误：它们不能被 dropThinking 修复。
  if (hasThinkingBlocks &&
      !applied.contains(AnthropicDegradation.stripThinkingBlocks) &&
      _looksLikeThinkingBlockError(lower)) {
    return AnthropicDegradation.stripThinkingBlocks;
  }

  if (hasSamplingParams &&
      !applied.contains(AnthropicDegradation.dropSampling) &&
      _looksLikeSamplingError(lower)) {
    return AnthropicDegradation.dropSampling;
  }

  if (hasToolChoiceAnyOrTool &&
      !applied.contains(AnthropicDegradation.downgradeToolChoiceToAuto) &&
      _looksLikeToolChoiceError(lower)) {
    return AnthropicDegradation.downgradeToolChoiceToAuto;
  }

  if (hasThinkingConfig &&
      !applied.contains(AnthropicDegradation.dropThinking) &&
      !_looksLikeThinkingBlockError(lower) &&
      _looksLikeThinkingConfigError(lower)) {
    return AnthropicDegradation.dropThinking;
  }

  return null;
}

bool _isBadRequest(String? code, String message) {
  if (code == 'BAD_REQUEST' || code == '400') return true;
  final numeric = int.tryParse(code ?? '');
  if (numeric != null) return numeric == 400;
  final lower = message.toLowerCase();
  return lower.contains('status 400') || lower.contains('400 bad request');
}

bool _looksLikeThinkingBlockError(String lower) {
  const markers = [
    'redacted_thinking',
    'redacted thinking',
    'thinking block',
    'thinking blocks',
    'thinking.blocks',
    'signature',
    'block is bound',
    'bound to a different conversation',
    'blocks cannot be modified',
    'block cannot be modified',
  ];
  return markers.any(lower.contains);
}

bool _looksLikeSamplingError(String lower) {
  const markers = [
    'temperature',
    'top_p',
    'top p',
    'top_k',
    'top k',
    'sampling',
  ];
  return markers.any(lower.contains);
}

bool _looksLikeToolChoiceError(String lower) {
  if (!lower.contains('tool_choice') && !lower.contains('tool choice')) {
    return false;
  }
  const markers = [
    'any',
    'not supported',
    'does not support',
    'not permitted',
    'extra inputs',
    'unsupported',
  ];
  return markers.any(lower.contains);
}

bool _looksLikeThinkingConfigError(String lower) {
  const markers = [
    'adaptive thinking',
    'thinking.type',
    'budget_tokens',
    'budget tokens',
    'extended thinking',
    'thinking is not supported',
    'does not support thinking',
    'output_config',
    'effort',
  ];
  return markers.any(lower.contains);
}
