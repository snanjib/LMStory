import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/network/llm_adapters/anthropic_rejection.dart';

void main() {
  AnthropicDegradation? classify(
    String message, {
    String? code = 'BAD_REQUEST',
    Set<AnthropicDegradation> applied = const {},
    bool hasThinkingBlocks = false,
    bool hasSamplingParams = true,
    bool hasThinkingConfig = true,
    bool hasToolChoiceAnyOrTool = true,
  }) =>
      classifyAnthropicRejection(
        message: message,
        code: code,
        applied: applied,
        hasThinkingBlocks: hasThinkingBlocks,
        hasSamplingParams: hasSamplingParams,
        hasThinkingConfig: hasThinkingConfig,
        hasToolChoiceAnyOrTool: hasToolChoiceAnyOrTool,
      );

  test('sampling keyword -> dropSampling', () {
    expect(
      classify('temperature may only be set to 1 when thinking is enabled'),
      AnthropicDegradation.dropSampling,
    );
  });

  test('thinking config keyword -> dropThinking', () {
    expect(
      classify(
        '"thinking.type.enabled" is not supported for this model. '
        'Use "thinking.type.adaptive".',
      ),
      AnthropicDegradation.dropThinking,
    );
  });

  test('tool_choice any/tool rejection -> downgrade to auto', () {
    expect(
      classify('tool_choice: type "tool" and "any" are not supported'),
      AnthropicDegradation.downgradeToolChoiceToAuto,
    );
  });

  test('thinking block signature -> stripThinkingBlocks', () {
    expect(
      classify(
        'Invalid `signature` in `thinking` block. '
        'The block is bound to a different conversation.',
        hasThinkingBlocks: true,
      ),
      AnthropicDegradation.stripThinkingBlocks,
    );
  });

  test('block error without thinking blocks does not strip', () {
    expect(
      classify(
        'Invalid `signature` in `thinking` block.',
      ),
      isNull,
    );
  });

  test('context overflow is not degraded', () {
    expect(
      classify('prompt is too long: 205845 tokens > 200000 maximum'),
      isNull,
    );
    expect(classify('model_context_window_exceeded'), isNull);
  });

  test('non-400 / unknown code is not degraded', () {
    expect(
      classify('temperature invalid', code: 'RATE_LIMIT'),
      isNull,
    );
    expect(classify('temperature invalid', code: null), isNull);
  });

  test('already applied dimension is skipped', () {
    expect(
      classify(
        'temperature may only be set to 1',
        applied: {AnthropicDegradation.dropSampling},
      ),
      isNull,
    );
  });

  test('missing request feature is skipped', () {
    expect(
      classify(
        'temperature may only be set to 1',
        hasSamplingParams: false,
      ),
      isNull,
    );
    expect(
      classify(
        '"thinking.type.enabled" is not supported',
        hasThinkingConfig: false,
      ),
      isNull,
    );
    expect(
      classify(
        'tool_choice: type "any" is not supported',
        hasToolChoiceAnyOrTool: false,
      ),
      isNull,
    );
  });

  test('generic 400 is not degraded', () {
    expect(classify('invalid request: missing field'), isNull);
  });
}
