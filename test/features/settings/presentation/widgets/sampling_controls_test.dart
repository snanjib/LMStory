import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/llm/reasoning_effort.dart';
import 'package:lmstory/core/network/llm_adapters/llm_adapter_factory.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/widgets/commit_slider.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/llm_protocol.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import 'package:lmstory/features/settings/presentation/utils/model_sampling_controls.dart';
import 'package:lmstory/features/settings/presentation/widgets/intermediate_generation_section.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/director_models_generation_section.dart';
import 'package:lmstory/features/settings/presentation/widgets/sections/global_generation_defaults_section.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../../test_helpers/stub_settings_notifier.dart';

ApiPreset _preset({
  String baseUrl = 'https://relay.test',
  LlmProtocol protocol = LlmProtocol.openaiCompatible,
  Map<String, dynamic>? options,
}) =>
    ApiPreset(
      presetId: 'relay',
      name: 'Relay',
      baseUrl: baseUrl,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      protocol: protocol,
      providerOptions: options,
    );

void main() {
  test('采样控件和各协议实际发送的字段一致', () {
    final cases = [
      (_preset(), 'grok-4.7', null),
      (_preset(options: {'omit_sampling_params': true}), 'grok-4.7', null),
      (_preset(), 'openai/gpt-6', null),
      (_preset(baseUrl: 'https://api.moonshot.cn'), 'moonshot-v1', null),
      (_preset(protocol: LlmProtocol.geminiNative), 'gemini-4', null),
      (_preset(protocol: LlmProtocol.anthropic), 'claude-sonnet', null),
      (
        _preset(
          protocol: LlmProtocol.anthropic,
          options: {'anthropic_send_sampling': true},
        ),
        'claude-sonnet',
        null,
      ),
      (_preset(protocol: LlmProtocol.openaiResponses), 'test-model', null),
      (
        _preset(protocol: LlmProtocol.openaiResponses),
        'test-model',
        ReasoningEffort.medium,
      ),
    ];
    final factory = LlmAdapterFactory();

    for (final (preset, modelId, effort) in cases) {
      final controls = samplingControlsForModel(
        [preset],
        (preset.presetId, modelId),
        reasoningEffort: effort,
      );
      final body = factory
          .getAdapter(
            protocol: preset.protocol,
            baseUrl: preset.baseUrl,
            modelId: modelId,
          )
          .buildRequestBody(
            LlmRequest(
              modelId: modelId,
              baseUrl: preset.baseUrl,
              protocol: preset.protocol,
              providerOptions: preset.providerOptions,
              reasoningEffort: effort,
              temperature: 0.8,
              topP: 0.95,
              presencePenalty: 0.5,
              frequencyPenalty: 0.2,
              messages: const [
                {'role': 'user', 'content': 'hello'},
              ],
            ),
            stream: false,
          );
      final samplingBody = body['generationConfig'] as Map? ?? body;
      expect(
        samplingBody.containsKey('temperature'),
        controls.showsTemperatureAndTopP,
      );
      expect(
        samplingBody.containsKey('top_p') || samplingBody.containsKey('topP'),
        controls.showsTemperatureAndTopP,
      );
      expect(body.containsKey('presence_penalty'), controls.showsPenalties);
      expect(body.containsKey('frequency_penalty'), controls.showsPenalties);
    }
  });

  testWidgets('三个模式的全局面板跟随默认模型显示采样控件', (tester) async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
    SharedPreferences.setMockInitialValues({
      ConfigLevelNotifier.prefKey: 'advanced',
    });
    final preferences =
        Preferences(prefs: await SharedPreferences.getInstance());
    final preset = _preset(options: {'omit_sampling_params': true});
    final settings = StubSettingsNotifier(presets: [preset]);
    final container = ProviderContainer(
      overrides: [
        settingsNotifierProvider.overrideWith((ref) => settings),
        configLevelProvider.overrideWith(
          (ref) => ConfigLevelNotifier(
            preferences,
            initialValue: ConfigLevel.advanced,
          ),
        ),
        intermediateConfigProvider.overrideWith(
          (ref) async => const IntermediateConfig(
            phaseModels: PhaseModelsConfig(
              generatingPresetId: 'relay',
              generatingModelId: 'grok-4.7',
            ),
          ),
        ),
        advancedConfigProvider.overrideWith(
          (ref) async => const AdvancedConfig(
            generatingPresetId: 'relay',
            generatingModelId: 'grok-4.7',
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: const MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: Column(
                  children: [
                    GlobalGenerationDefaultsSection(),
                    IntermediateGenerationSection(),
                    DirectorModelsGenerationSection(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await settings.setDefaultModel(presetId: 'relay', modelId: 'grok-4.7');
    await tester.pumpAndSettle();

    expect(find.byType(CommitSlider), findsNothing);
    expect(find.byType(TextField), findsWidgets);

    await settings.setDefaultModel(presetId: null, modelId: null);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byType(GlobalGenerationDefaultsSection),
        matching: find.byType(CommitSlider),
      ),
      findsNWidgets(2),
    );
  });
}
