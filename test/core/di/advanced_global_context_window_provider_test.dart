import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';

/// advancedGlobalContextWindowProvider 此前 0 覆盖：三分支钉死
/// - 配置未装载（AsyncLoading）→ 默认窗口
/// - GM 已配置 → 透传 presetId/modelId/effectiveContextLimit 给 resolver
/// - GM 未配置（空串）→ presetId/modelId 传 null（回退链在 resolver 内）
void main() {
  test('配置未装载 → 回退默认窗口 96000', () async {
    final container = ProviderContainer(
      overrides: [
        // 永不完成的配置读取：provider 处于 loading，valueOrNull 为 null
        settingsRepositoryProvider.overrideWithValue(
          _HangingSettingsRepository(),
        ),
      ],
    );
    addTearDown(container.dispose);

    // autoDispose：listen 挂住生命周期，future 完成前不被销毁
    final sub = container.listen(
      advancedGlobalContextWindowProvider,
      (_, __) {},
    );
    final window =
        await container.read(advancedGlobalContextWindowProvider.future);
    sub.close();
    expect(window, ConfigurationResolver.defaultContextWindow);
  });

  test('GM 已配置 → 三参透传 resolver，返回其解析值', () async {
    final resolver = _StubWindowResolver()..window = 128000;
    final container = ProviderContainer(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(
          _FixedSettingsRepository(
            const AppConfig(
              version: '0.1',
              broadcastChat: BroadcastChatConfig(),
              advanced: AdvancedConfig(
                generatingPresetId: 'p-gm',
                generatingModelId: 'm-gm',
                context: ContextConfig(effectiveContextLimit: 64000),
              ),
            ),
          ),
        ),
        configurationResolverProvider.overrideWithValue(resolver),
      ],
    );
    addTearDown(container.dispose);

    final sub = container.listen(
      advancedGlobalContextWindowProvider,
      (_, __) {},
    );
    final window = await container.read(
      advancedGlobalContextWindowProvider.future,
    );
    sub.close();
    expect(window, 128000);
    expect(resolver.lastPresetId, 'p-gm');
    expect(resolver.lastModelId, 'm-gm');
    expect(resolver.lastEffectiveContextLimit, 64000);
  });

  test('GM 未配置 → presetId/modelId 传 null', () async {
    final resolver = _StubWindowResolver()..window = 96000;
    final container = ProviderContainer(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(
          _FixedSettingsRepository(
            const AppConfig(
              version: '0.1',
              broadcastChat: BroadcastChatConfig(),
            ),
          ),
        ),
        configurationResolverProvider.overrideWithValue(resolver),
      ],
    );
    addTearDown(container.dispose);

    final sub = container.listen(
      advancedGlobalContextWindowProvider,
      (_, __) {},
    );
    await container.read(advancedGlobalContextWindowProvider.future);
    sub.close();
    expect(resolver.lastPresetId, isNull);
    expect(resolver.lastModelId, isNull);
  });
}

class _StubWindowResolver extends ConfigurationResolver {
  _StubWindowResolver()
      : super(
          presetRepository: _StubPresetRepo(),
          settingsRepository: _FixedSettingsRepository(
            const AppConfig(
              version: '0.1',
              broadcastChat: BroadcastChatConfig(),
            ),
          ),
          logger: const Logger('test'),
        );
  int window = 0;
  String? lastPresetId;
  String? lastModelId;
  int? lastEffectiveContextLimit;

  @override
  Future<int> resolveContextWindowForPhase({
    String? presetId,
    String? modelId,
    int? effectiveContextLimit,
  }) async {
    lastPresetId = presetId;
    lastModelId = modelId;
    lastEffectiveContextLimit = effectiveContextLimit;
    return window;
  }
}

class _FixedSettingsRepository implements SettingsRepository {
  _FixedSettingsRepository(this.config);

  final AppConfig config;

  @override
  Future<AppConfig> getResolvedConfig() async => config;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _HangingSettingsRepository implements SettingsRepository {
  final _never = Completer<AppConfig>().future;

  @override
  Future<AppConfig> getResolvedConfig() => _never;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubPresetRepo implements ApiPresetRepository {
  @override
  Future<List<ApiPreset>> getAllPresets() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}
