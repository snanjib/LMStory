import 'dart:async';

import 'package:lmstory/core/exceptions/app_exceptions.dart';
import 'package:lmstory/core/llm/tool_calling/tool_choice.dart';
import 'package:lmstory/core/network/llm_adapters/anthropic_compat_options.dart';
import 'package:lmstory/core/network/llm_adapters/anthropic_rejection.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';

/// Anthropic 请求级一次性降级。
///
/// 第三方 Anthropic 兼容端点的能力无法可靠预知，且模型名不可信；这里只在
/// **400 报文明确点名某个参数、且尚未产出任何内容事件**时，按维度降级并
/// 重发一次。每个维度只应用一次，最多 [_maxDegradations] 次。
///
/// 非 Anthropic 协议完全直通，不改变既有行为。
class NegotiatingLlmService implements LlmService {
  NegotiatingLlmService({required LlmService inner, Logger? logger})
      : _inner = inner,
        _logger = logger;

  final LlmService _inner;
  final Logger? _logger;

  static const int _maxDegradations = 4;

  @override
  Stream<LlmStreamEvent> streamChat(LlmRequest request) async* {
    if (request.protocol != LlmProtocol.anthropic) {
      yield* _inner.streamChat(request);
      return;
    }

    var current = request;
    final applied = <AnthropicDegradation>{};

    for (var attempt = 0; attempt <= _maxDegradations; attempt++) {
      var sawPayload = false;
      var retry = false;

      await for (final event in _inner.streamChat(current)) {
        if (event is LlmStreamError &&
            !sawPayload &&
            !(current.cancelToken?.isCancelled ?? false)) {
          final degradation = _classify(
            current,
            message: event.message,
            code: event.code,
            applied: applied,
          );
          if (degradation != null && attempt < _maxDegradations) {
            applied.add(degradation);
            current = _apply(current, degradation);
            _logDegradation(current, degradation, applied);
            retry = true;
            break;
          }
        }

        if (_isPayloadEvent(event)) sawPayload = true;
        yield event;
      }

      if (!retry) return;
    }
  }

  @override
  Future<LlmResponse> chat(LlmRequest request) async {
    if (request.protocol != LlmProtocol.anthropic) {
      return _inner.chat(request);
    }

    var current = request;
    final applied = <AnthropicDegradation>{};

    for (var attempt = 0; attempt <= _maxDegradations; attempt++) {
      try {
        return await _inner.chat(current);
      } on AppHttpException catch (e) {
        final degradation = _classify(
          current,
          message: '${e.message} ${e.responseBody ?? ''}',
          code: e.statusCode?.toString(),
          applied: applied,
        );
        if (degradation == null || attempt >= _maxDegradations) rethrow;
        applied.add(degradation);
        current = _apply(current, degradation);
        _logDegradation(current, degradation, applied);
      }
    }

    // 理论不可达；保留一次真实调用让上层拿到最终错误。
    return _inner.chat(current);
  }

  AnthropicDegradation? _classify(
    LlmRequest request, {
    required String message,
    required String? code,
    required Set<AnthropicDegradation> applied,
  }) {
    final compat = AnthropicCompatOptions.resolve(
      baseUrl: request.baseUrl,
      providerOptions: request.providerOptions,
      reasoningEffort: request.reasoningEffort,
      requestedMaxTokens: request.maxTokens,
      modelMaxOutputTokens: request.modelMaxOutputTokens,
    );
    return classifyAnthropicRejection(
      message: message,
      code: code,
      applied: applied,
      hasThinkingBlocks: _hasThinkingBlocks(request.messages),
      hasSamplingParams: compat.sendSampling &&
          (request.temperature != null || request.topP != null),
      hasThinkingConfig: compat.thinking != AnthropicThinkingDirective.omit,
      hasToolChoiceAnyOrTool: request.toolChoice == ToolChoice.required ||
          request.toolChoice == ToolChoice.none,
    );
  }

  LlmRequest _apply(LlmRequest request, AnthropicDegradation degradation) {
    switch (degradation) {
      case AnthropicDegradation.dropSampling:
        return request.copyWith(
          providerOptions: _withKey(
            request.providerOptions,
            kAnthropicDropSamplingInternal,
            true,
          ),
        );
      case AnthropicDegradation.dropThinking:
        return request.copyWith(
          providerOptions: _withKey(
            request.providerOptions,
            kAnthropicDropThinkingInternal,
            true,
          ),
        );
      case AnthropicDegradation.downgradeToolChoiceToAuto:
        return request.copyWith(
          providerOptions: _withKey(
            request.providerOptions,
            kAnthropicToolChoiceAutoInternal,
            true,
          ),
        );
      case AnthropicDegradation.stripThinkingBlocks:
        return request.copyWith(
          messages: _stripThinkingBlocks(request.messages),
        );
    }
  }

  Map<String, dynamic> _withKey(
    Map<String, dynamic>? options,
    String key,
    Object value,
  ) {
    final copy = Map<String, dynamic>.from(options ?? const {});
    copy[key] = value;
    return copy;
  }

  bool _hasThinkingBlocks(List<Map<String, dynamic>> messages) {
    for (final message in messages) {
      if (message['role'] != 'assistant') continue;
      final thinkingBlocks = message['thinkingBlocks'];
      if (thinkingBlocks is List && thinkingBlocks.isNotEmpty) return true;

      final ordered = message['anthropicBlocks'];
      if (ordered is List && _containsThinkingBlock(ordered)) return true;

      final content = message['content'];
      if (content is List && _containsThinkingBlock(content)) return true;
    }
    return false;
  }

  bool _containsThinkingBlock(List<dynamic> blocks) {
    for (final block in blocks) {
      if (block is! Map<String, dynamic>) continue;
      final type = block['type'];
      if (type == 'thinking' || type == 'redacted_thinking') return true;
    }
    return false;
  }

  List<Map<String, dynamic>> _stripThinkingBlocks(
    List<Map<String, dynamic>> messages,
  ) {
    final result = <Map<String, dynamic>>[];
    for (final message in messages) {
      if (message['role'] != 'assistant') {
        result.add(message);
        continue;
      }

      final copy = Map<String, dynamic>.from(message)
        ..remove('thinkingBlocks')
        ..remove('reasoningContent');

      final ordered = copy['anthropicBlocks'];
      if (ordered is List) {
        final filtered = _withoutThinkingBlocks(ordered);
        if (filtered.isEmpty) {
          copy.remove('anthropicBlocks');
        } else {
          copy['anthropicBlocks'] = filtered;
        }
      }

      final content = copy['content'];
      if (content is List) {
        copy['content'] = _withoutThinkingBlocks(content);
      }

      if (!_hasRemainingAssistantContent(copy)) continue;
      result.add(copy);
    }
    return result;
  }

  List<dynamic> _withoutThinkingBlocks(List<dynamic> blocks) {
    return [
      for (final block in blocks)
        if (!(block is Map<String, dynamic> &&
            (block['type'] == 'thinking' ||
                block['type'] == 'redacted_thinking')))
          block,
    ];
  }

  bool _hasRemainingAssistantContent(Map<String, dynamic> message) {
    final content = message['content'];
    if (content is String && content.isNotEmpty) return true;
    if (content is List && content.isNotEmpty) return true;
    final ordered = message['anthropicBlocks'];
    if (ordered is List && ordered.isNotEmpty) return true;
    final toolCalls = message['tool_calls'];
    return toolCalls is List && toolCalls.isNotEmpty;
  }

  bool _isPayloadEvent(LlmStreamEvent event) {
    return switch (event) {
      LlmTextDelta() ||
      LlmThinkingDelta() ||
      LlmThinkingBlockComplete() ||
      LlmContentBlockComplete() ||
      LlmToolCallStart() ||
      LlmToolCallArgs() ||
      LlmToolCallComplete() ||
      LlmStreamDone() =>
        true,
      LlmStreamError() => false,
    };
  }

  void _logDegradation(
    LlmRequest request,
    AnthropicDegradation degradation,
    Set<AnthropicDegradation> applied,
  ) {
    final compat = AnthropicCompatOptions.resolve(
      baseUrl: request.baseUrl,
      providerOptions: request.providerOptions,
      reasoningEffort: request.reasoningEffort,
      requestedMaxTokens: request.maxTokens,
      modelMaxOutputTokens: request.modelMaxOutputTokens,
    );
    final appliedNames = applied.map((d) => d.name).join(',');
    _logger?.info(
      'Anthropic request degraded',
      detail: 'model=${request.modelId}, '
          'endpoint=${compat.endpointKind.name}, '
          'degradation=${degradation.name}, applied=$appliedNames',
    );
  }
}
