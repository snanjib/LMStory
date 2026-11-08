import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/llm/tool_calling/provider_tool_capabilities.dart';
import 'package:lmstory/core/network/dio_client.dart';
import 'package:lmstory/core/network/llm_adapters/llm_adapter_factory.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/advanced/data/repositories/agent_event_log_repository.dart';
import 'package:lmstory/features/advanced/presentation/controllers/advanced_chat_controller.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/session_phase_models.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/demo/data/demo_network_guard.dart';
import 'package:lmstory/features/demo/data/demo_preferences.dart';
import 'package:lmstory/features/demo/data/demo_secure_storage.dart';
import 'package:lmstory/features/demo/data/demo_seeder.dart';
import 'package:lmstory/features/demo/data/replay_embedding_service.dart';
import 'package:lmstory/features/demo/data/replay_llm_service.dart';
import 'package:lmstory/features/demo/domain/demo_pack.dart';
import 'package:lmstory/features/demo/domain/demo_replay_profile.dart';
import 'package:lmstory/features/demo/domain/demo_replay_timing.dart';
import 'package:lmstory/features/demo/domain/demo_scene.dart';
import 'package:lmstory/features/demo/presentation/demo_bridge.dart';
import 'package:lmstory/features/demo/presentation/demo_overrides.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';
import 'package:lmstory/features/memory/data/repositories/factual_repository_impl.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';
import 'package:lmstory/features/settings/data/datasources/api_key_datasource.dart';
import 'package:lmstory/features/settings/data/repositories/api_preset_repository_impl.dart';
import 'package:lmstory/features/settings/data/repositories/settings_repository_impl.dart';
import 'package:lmstory/features/story_runtime/data/persistence_service_impl.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/features/templates/data/repositories/template_repository_impl.dart';
import '../../../test_helpers/stub_failure_log_repository.dart';

/// 构造将现有样本包转换为 v2 流式画像（zhipu）的合法数据包
DemoPack buildV2ZhipuStreamingPack() {
  final raw = File('assets/demo/first_launch/zh-CN.json').readAsStringSync();
  final json = jsonDecode(raw) as Map<String, dynamic>;

  if ((json['manifest'] as Map)['formatVersion'] == 2 &&
      ((json['responses'] as Map)['stream'] as List).isNotEmpty) {
    return DemoPack.parse(json);
  }

  final manifest = Map<String, dynamic>.from(json['manifest'] as Map);
  manifest['formatVersion'] = 2;
  manifest['replayProfile'] = DemoReplayProfile.zhipu.toJson();

  final chatList = List<Map<String, dynamic>>.from(
    (json['responses'] as Map<String, dynamic>)['chat'] as List,
  );

  final streamSteps = <Map<String, dynamic>>[];
  final remainingChat = <Map<String, dynamic>>[];

  for (final item in chatList) {
    if (item['purpose'] == 'agent_step') {
      final resp = item['response'] as Map<String, dynamic>;
      final toolCalls = resp['toolCalls'] as List? ?? [];
      final finishReason = resp['finishReason'] as String? ?? 'tool_calls';

      final events = <Map<String, dynamic>>[];
      final content = resp['content'] as String? ?? '';
      if (content.isNotEmpty) {
        events.add({
          'type': 'text_delta',
          'content': content,
        });
      }
      for (final tc in toolCalls) {
        final m = tc as Map<String, dynamic>;
        final callId = m['toolCallId'] as String;
        final name = m['name'] as String;
        final args = m['arguments'] as Map<String, dynamic>;
        events
          ..add({
            'type': 'tool_call_start',
            'toolCallId': callId,
            'name': name,
          })
          ..add({
            'type': 'tool_call_args',
            'toolCallId': callId,
            'argsDelta': jsonEncode(args),
          })
          ..add({
            'type': 'tool_call_complete',
            'toolCallId': callId,
            'name': name,
            'arguments': args,
          });
      }
      events.add({
        'type': 'done',
        'usage': resp['usage'],
        'finishReason': finishReason,
      });

      streamSteps.add({
        'purpose': 'agent_step',
        'turn': item['turn'] ?? 1,
        'events': events,
      });
    } else {
      remainingChat.add(item);
    }
  }

  final v2Json = <String, dynamic>{
    'manifest': manifest,
    'prompt': json['prompt'],
    'responses': {
      'stream': streamSteps,
      'chat': remainingChat,
    },
    'embeddings': json['embeddings'],
    'expectations': json['expectations'],
  };

  return DemoPack.parse(v2Json);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Demo v2 流式画像（zhipu）端到端回放与容器隔离', () {
    late AppDatabase db;
    late DemoSecureStorage secure;
    late DemoPreferences prefs;
    late DemoNetworkGuard guard;
    late DemoPack v2Pack;
    late ConfigurationResolver resolver;
    late ChatRepositoryImpl chatRepo;
    late FactualRepositoryImpl factualRepo;
    late AdvancedChatController controller;

    setUp(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      secure = DemoSecureStorage();
      prefs = DemoPreferences();
      guard = DemoNetworkGuard();
      v2Pack = buildV2ZhipuStreamingPack();

      final seed = await seedDemoEnvironment(
        db,
        secure,
        prefs,
        localeTag: 'zh-CN',
      );

      final settingsRepo = SettingsRepositoryImpl(
        preferences: prefs,
        configLoader: ConfigLoader(),
        apiKeyDatasource: ApiKeyDatasource(secureStorage: secure),
      );
      await settingsRepo.setUserOverride(
        'advanced.embedding_preset_id',
        seed.presetId,
      );
      await settingsRepo.setUserOverride(
        'advanced.embedding_model_id',
        DemoSeedIds.embeddingModelId,
      );

      final presetRepo = ApiPresetRepositoryImpl(
        database: db,
        apiKeyDatasource: ApiKeyDatasource(secureStorage: secure),
        dioClient: DioClient(),
        adapterFactory: LlmAdapterFactory(),
      );
      resolver = ConfigurationResolver(
        presetRepository: presetRepo,
        settingsRepository: settingsRepo,
        logger: const Logger('demo_v2_test'),
      );

      chatRepo = ChatRepositoryImpl(database: db);
      factualRepo = FactualRepositoryImpl(database: db);
      final experienceRepo = ExperienceRepositoryImpl(
        database: db,
        vectorEngine: const VectorEngine(),
      );

      final template = await TemplateRepositoryImpl(db)
          .getTemplate('builtin-isekai-narrator');

      final profile = v2Pack.manifest.replayProfile!;
      final capabilities = profile.resolveCapabilities();

      controller = AdvancedChatController(
        chatRepository: chatRepo,
        configurationResolver: resolver,
        llmService: DemoReplayLlmService(
          pack: v2Pack,
          guard: guard,
          timing: DemoReplayTiming.immediate,
        ),
        experienceRepository: experienceRepo,
        embeddingService: DemoReplayEmbeddingService(
          pack: v2Pack,
          guard: guard,
        ),
        persistenceService: StoryPersistenceServiceImpl(
          database: db,
          chatRepository: chatRepo,
          experienceRepository: experienceRepo,
          factApplier: FactApplier(repository: factualRepo),
        ),
        failureLogRepository: const StubFailureLogRepository(),
        tokenCounter: TokenCounter(),
        getConfig: () async => const AdvancedConfig(),
        logger: const Logger('demo_v2_test'),
        session: ChatSession(
          sessionId: '__draft_intermediate_v2',
          title: '新导演会话',
          mode: 'advanced',
          createdAt: DateTime.now(),
          lastActiveAt: DateTime.now(),
          messageCount: 0,
          phaseModels: SessionPhaseModels(
            generatingPresetId: seed.presetId,
            generatingModelId: DemoSeedIds.chatModelId,
          ),
          systemPromptOverride: template.content,
        ),
        factualRepository: factualRepo,
        agentEventLogRepository: AgentEventLogRepository(database: db),
        capabilitiesOverride: capabilities,
      );
    });

    tearDown(() async {
      controller.dispose();
      await db.close();
    });

    test('v2 数据包成功驱动流式工具调用回放：零远程调用、落库正确、nextTurn 推进', () async {
      expect(controller.capabilitiesOverride, ProviderToolCapabilities.zhipu);
      expect(
        controller.capabilitiesOverride?.streamingToolCallsReliable,
        isTrue,
      );
      expect(controller.state.phase, IntermediatePhase.idle);

      await controller.sendMessage(v2Pack.prompt);

      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (controller.state.phase != IntermediatePhase.idle &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(
        controller.state.phase,
        IntermediatePhase.idle,
        reason:
            '回合应在超时前完成；失败态=${controller.state.failureContext?.errorMessage} '
            'code=${controller.state.failureContext?.errorCode} '
            'raw=${controller.state.failureContext?.rawError} '
            'guardAttempts=${guard.attempts}',
      );

      // 1. 守卫断言：零远程调用企图
      expect(
        guard.attemptCount,
        0,
        reason: '存在远程调用企图：${guard.attempts}',
      );

      // 2. 会话状态与 nextTurn 推进
      final sessions = await chatRepo.getAllSessions();
      expect(sessions, hasLength(1));
      final session = sessions.single;
      expect(session.nextTurn, 2);

      // 3. 实体落库断言
      final entities = await factualRepo.getEntities(session.sessionId);
      final names = entities.map((e) => e.primaryName).toSet();
      expect(names, containsAll(v2Pack.expectations.entityNames));
    });

    test('双容器隔离：Demo 作用域注入覆盖画像，生产容器保持默认 resolve (null)', () {
      final bridge = DemoBridge();
      final demoOverrides = buildDemoOverrides(
        bridge: bridge,
        demoDb: db,
        prefs: prefs,
        secure: secure,
        pack: v2Pack,
      );

      // Demo 容器
      final demoContainer = ProviderContainer(overrides: demoOverrides);
      addTearDown(demoContainer.dispose);

      final demoCaps =
          demoContainer.read(agentCapabilitiesOverrideProvider);
      expect(demoCaps, equals(ProviderToolCapabilities.zhipu));
      expect(bridge.replayProfile?.id, DemoReplayProfile.zhipuId);
      expect(bridge.pack, equals(v2Pack));

      // 生产容器（零 override）
      final prodContainer = ProviderContainer();
      addTearDown(prodContainer.dispose);

      final prodCaps =
          prodContainer.read(agentCapabilitiesOverrideProvider);
      expect(
        prodCaps,
        isNull,
        reason: '生产容器必须保持 agentCapabilitiesOverrideProvider 为 null',
      );
    });
  });
}
