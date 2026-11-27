import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/llm/reasoning_effort.dart';
import 'package:lmstory/core/network/llm_adapters/anthropic_compat_options.dart';

void main() {
  AnthropicCompatOptions resolve({
    String baseUrl = 'https://api.anthropic.com',
    Map<String, dynamic>? providerOptions,
    ReasoningEffort? reasoningEffort,
    int? requestedMaxTokens,
    int? modelMaxOutputTokens,
  }) =>
      AnthropicCompatOptions.resolve(
        baseUrl: baseUrl,
        providerOptions: providerOptions,
        reasoningEffort: reasoningEffort,
        requestedMaxTokens: requestedMaxTokens,
        modelMaxOutputTokens: modelMaxOutputTokens,
      );

  group('endpoint kind / api version', () {
    test('official host gets 2026-10-21', () {
      final options = resolve();
      expect(options.endpointKind, AnthropicEndpointKind.official);
      expect(options.apiVersion, AnthropicCompatOptions.officialApiVersion);
    });

    test('third-party host gets 2023-06-01', () {
      final options = resolve(baseUrl: 'https://relay.example.com/v1');
      expect(options.endpointKind, AnthropicEndpointKind.thirdParty);
      expect(options.apiVersion, AnthropicCompatOptions.thirdPartyApiVersion);
    });

    test('raw: official host still recognized', () {
      final options = resolve(baseUrl: 'raw:https://api.anthropic.com/v1');
      expect(options.endpointKind, AnthropicEndpointKind.official);
    });

    test('providerOptions can override version', () {
      final options = resolve(
        providerOptions: const {kAnthropicVersionOption: '2023-06-01'},
      );
      expect(options.apiVersion, '2023-06-01');
    });
  });

  group('sampling', () {
    test('all endpoints omit sampling by default', () {
      expect(resolve().sendSampling, isFalse);
      expect(
        resolve(baseUrl: 'https://relay.example.com').sendSampling,
        isFalse,
      );
    });

    test('third-party opt-in sends sampling under old version', () {
      final options = resolve(
        baseUrl: 'https://relay.example.com',
        providerOptions: const {kAnthropicSendSamplingOption: true},
      );
      expect(options.sendSampling, isTrue);
    });

    test('official 2026-10-21 suppresses sampling even when opted in', () {
      final options = resolve(
        providerOptions: const {kAnthropicSendSamplingOption: true},
      );
      expect(options.sendSampling, isFalse);
    });

    test('official opt-in works after version override', () {
      final options = resolve(
        providerOptions: const {
          kAnthropicVersionOption: '2023-06-01',
          kAnthropicSendSamplingOption: true,
        },
      );
      expect(options.sendSampling, isTrue);
    });

    test('omit_sampling_params and internal drop win', () {
      expect(
        resolve(
          baseUrl: 'https://relay.example.com',
          providerOptions: const {
            kAnthropicSendSamplingOption: true,
            'omit_sampling_params': true,
          },
        ).sendSampling,
        isFalse,
      );
      expect(
        resolve(
          baseUrl: 'https://relay.example.com',
          providerOptions: const {
            kAnthropicSendSamplingOption: true,
            kAnthropicDropSamplingInternal: true,
          },
        ).sendSampling,
        isFalse,
      );
    });
  });

  group('thinking', () {
    test('official low/medium/high -> adaptive + effort', () {
      for (final (effort, value) in [
        (ReasoningEffort.low, 'low'),
        (ReasoningEffort.medium, 'medium'),
        (ReasoningEffort.high, 'high'),
      ]) {
        final options = resolve(reasoningEffort: effort);
        expect(options.thinking, AnthropicThinkingDirective.adaptive);
        expect(options.effort, value);
      }
    });

    test('official disabled -> disabled without effort', () {
      final options = resolve(reasoningEffort: ReasoningEffort.disabled);
      expect(options.thinking, AnthropicThinkingDirective.disabled);
      expect(options.effort, isNull);
    });

    test('official null -> omit', () {
      expect(resolve().thinking, AnthropicThinkingDirective.omit);
    });

    test('third-party defaults to omit even with reasoning effort', () {
      final options = resolve(
        baseUrl: 'https://relay.example.com',
        reasoningEffort: ReasoningEffort.high,
      );
      expect(options.thinking, AnthropicThinkingDirective.omit);
      expect(options.effort, isNull);
    });

    test('third-party can opt into adaptive', () {
      final options = resolve(
        baseUrl: 'https://relay.example.com',
        reasoningEffort: ReasoningEffort.medium,
        providerOptions: const {kAnthropicThinkingModeOption: 'adaptive'},
      );
      expect(options.thinking, AnthropicThinkingDirective.adaptive);
      expect(options.effort, 'medium');
    });

    test('explicit thinking JSON wins', () {
      final options = resolve(
        providerOptions: const {
          'thinking': {'type': 'enabled', 'budget_tokens': 2000},
        },
      );
      expect(options.thinking, AnthropicThinkingDirective.providerJson);
      expect(
        options.providerThinking,
        {'type': 'enabled', 'budget_tokens': 2000},
      );
    });

    test('internal drop wins over explicit thinking', () {
      final options = resolve(
        providerOptions: const {
          'thinking': {'type': 'enabled', 'budget_tokens': 2000},
          kAnthropicDropThinkingInternal: true,
        },
      );
      expect(options.thinking, AnthropicThinkingDirective.omit);
      expect(options.providerThinking, isNull);
    });

    test('effort provider option overrides reasoning effort', () {
      final options = resolve(
        reasoningEffort: ReasoningEffort.low,
        providerOptions: const {kAnthropicEffortOption: 'xhigh'},
      );
      expect(options.effort, 'xhigh');
    });
  });

  group('tool_choice none', () {
    test('official allows none; third-party defaults false', () {
      expect(resolve().allowToolChoiceNone, isTrue);
      expect(
        resolve(baseUrl: 'https://relay.example.com').allowToolChoiceNone,
        isFalse,
      );
    });

    test('third-party can declare support', () {
      final options = resolve(
        baseUrl: 'https://relay.example.com',
        providerOptions: const {
          kAnthropicCapabilitiesOption: {'tool_choice_none': true},
        },
      );
      expect(options.allowToolChoiceNone, isTrue);
    });
  });

  group('stable system cache capability', () {
    test('official defaults to enabled; third-party defaults to disabled', () {
      expect(resolve().allowStableSystemCache, isTrue);
      expect(
        resolve(baseUrl: 'https://relay.example.com').allowStableSystemCache,
        isFalse,
      );
    });

    test('explicit true enables on third-party', () {
      final options = resolve(
        baseUrl: 'https://relay.example.com',
        providerOptions: const {
          kAnthropicCapabilitiesOption: {'stable_system_cache': true},
        },
      );
      expect(options.allowStableSystemCache, isTrue);
    });

    test('explicit false disables on official', () {
      final options = resolve(
        providerOptions: const {
          kAnthropicCapabilitiesOption: {'stable_system_cache': false},
        },
      );
      expect(options.allowStableSystemCache, isFalse);
    });

    test('non-bool falls back to endpoint default', () {
      expect(
        resolve(
          baseUrl: 'https://relay.example.com',
          providerOptions: const {
            kAnthropicCapabilitiesOption: {'stable_system_cache': 'yes'},
          },
        ).allowStableSystemCache,
        isFalse,
      );
      expect(
        resolve(
          providerOptions: const {
            kAnthropicCapabilitiesOption: {'stable_system_cache': 1},
          },
        ).allowStableSystemCache,
        isTrue,
      );
    });

    test('non-map capabilities falls back to endpoint default', () {
      expect(
        resolve(
          providerOptions: const {kAnthropicCapabilitiesOption: 'invalid'},
        ).allowStableSystemCache,
        isTrue,
      );
      expect(
        resolve(
          baseUrl: 'https://relay.example.com',
          providerOptions: const {kAnthropicCapabilitiesOption: <String>[]},
        ).allowStableSystemCache,
        isFalse,
      );
    });
  });

  group('max tokens', () {
    test('positive is clamped to model max', () {
      final options = resolve(
        requestedMaxTokens: 16384,
        modelMaxOutputTokens: 8192,
      );
      expect(options.maxTokens, 8192);
      expect(options.maxTokensSource, AnthropicMaxTokensSource.configured);
    });

    test('zero without metadata falls back to 8192', () {
      final options = resolve(requestedMaxTokens: 0);
      expect(options.maxTokens, 8192);
      expect(
        options.maxTokensSource,
        AnthropicMaxTokensSource.defaultFallback,
      );
    });

    test('null without metadata falls back to 8192', () {
      expect(resolve().maxTokens, 8192);
    });

    test('zero with metadata uses model max', () {
      final options = resolve(
        requestedMaxTokens: 0,
        modelMaxOutputTokens: 32768,
      );
      expect(options.maxTokens, 32768);
      expect(options.maxTokensSource, AnthropicMaxTokensSource.modelMax);
    });
  });
}
