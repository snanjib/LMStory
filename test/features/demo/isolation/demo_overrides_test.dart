import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/tutorial/spotlight_registry.dart';
import 'package:lmstory/features/advanced/presentation/controllers/director_input_lock.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/demo/data/demo_network_guard.dart';
import 'package:lmstory/features/demo/data/demo_preferences.dart';
import 'package:lmstory/features/demo/data/demo_secure_storage.dart';
import 'package:lmstory/features/demo/data/replay_llm_service.dart';
import 'package:lmstory/features/demo/presentation/demo_bridge.dart';
import 'package:lmstory/features/demo/presentation/demo_overrides.dart';
import 'package:lmstory/features/memory/domain/services/embedding_service.dart';
import 'package:lmstory/features/onboarding/presentation/controllers/onboarding_controller.dart';
import 'package:lmstory/features/settings/data/repositories/settings_repository_impl.dart';
import 'package:lmstory/features/settings/presentation/controllers/settings_controller.dart';
import '../shared/demo_pack_factory.dart';

/// T-ISO-5：buildDemoOverrides 产出的独立容器内，全部持久化/网络
/// provider 解析到隔离实例；常用解析面零远程调用企图。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase demoDb;
  late DemoBridge bridge;
  late ProviderContainer container;

  setUp(() async {
    demoDb = AppDatabase.forTesting(NativeDatabase.memory());
    bridge = DemoBridge();
    container = ProviderContainer(
      overrides: buildDemoOverrides(
        bridge: bridge,
        demoDb: demoDb,
        prefs: DemoPreferences(),
        secure: DemoSecureStorage(),
        pack: buildMinimalPack(),
      ),
    );
  });

  tearDown(() async {
    container.dispose();
    await demoDb.close();
    bridge.dispose();
  });

  test('基座 provider 全部解析到隔离实例', () {
    expect(container.read(preferencesProvider), isA<DemoPreferences>());
    expect(container.read(secureStorageProvider), isA<DemoSecureStorage>());
    expect(container.read(appDatabaseProvider), same(demoDb));
    expect(container.read(dioClientProvider), isA<GuardedDioClient>());
    expect(container.read(httpClientProvider), isA<GuardedHttpClient>());
    expect(container.read(llmServiceProvider), isA<DemoReplayLlmService>());
    expect(
      container.read(embeddingServiceProvider),
      isA<EmbeddingService>().having(
        (e) => e.runtimeType.toString(),
        'runtimeType',
        contains('DemoReplayEmbeddingService'),
      ),
    );
    expect(container.read(spotlightRegistryProvider), same(bridge.spotlights));
    expect(container.read(directorInputLockProvider), same(bridge.inputLock));
    expect(container.read(demoBridgeProvider), same(bridge));
    expect(bridge.replay, isNotNull, reason: '装配必须接通回放服务句柄');
  });

  test('onboarding stub：恒为已完成、markCompleted 不写任何存储', () async {
    final notifier = container.read(onboardingProvider.notifier);
    // _load 异步——等一拍后仍恒为 completed（桩 prefs 恒 true）
    await Future<void>.delayed(Duration.zero);
    final state = container.read(onboardingProvider);
    expect(state.isLoading, isFalse);
    expect(state.completed, isTrue);
    await notifier.markCompleted();
    expect(container.read(onboardingProvider).completed, isTrue);
  });

  test('下游 provider 在容器内全新构建并落隔离基座', () async {
    final settingsRepo = container.read(settingsRepositoryProvider);
    expect(settingsRepo, isA<SettingsRepositoryImpl>());

    final chatRepo = container.read(chatRepositoryProvider);
    expect(chatRepo, isA<ChatRepositoryImpl>());

    // settingsNotifier 可构建；等 _init（异步）完成再退出，
    // 防 dispose 后回调跨测试泄漏
    final notifier = container.read(settingsNotifierProvider.notifier);
    expect(notifier, isNotNull);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  });

  test('守卫零远程调用企图贯穿常用解析面', () async {
    await container
        .read(configurationResolverProvider)
        .resolveAdvancedEmbeddingConfig();
    await container.read(settingsRepositoryProvider).getResolvedConfig();
    expect(bridge.guard.attemptCount, 0);
  });
}
