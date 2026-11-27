import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/advanced/data/repositories/agent_event_log_repository.dart';
import 'package:lmstory/features/advanced/domain/services/engineering_context_mode.dart';
import 'package:lmstory/features/advanced/presentation/controllers/advanced_chat_controller.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session_settings.dart';
import 'package:lmstory/features/chat/domain/entities/reasoning_effort.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';
import 'package:lmstory/features/memory/data/repositories/factual_repository_impl.dart';
import 'package:lmstory/features/memory/domain/services/embedding_service.dart';
import 'package:lmstory/features/memory/domain/services/fact_applier.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/story_runtime/data/persistence_service_impl.dart';

import '../../../test_helpers/stub_failure_log_repository.dart';

/// 工程上下文模式：控制器面三态接线/切换守卫/关闭态基线。
///
/// 覆盖 true 缺纪元停轮保数据、trim 零调用异常与原子进入/通用通道拦截。
class _FakeResolver extends ConfigurationResolver {
  _FakeResolver()
      : super(
          presetRepository: _StubPresetRepo(),
          settingsRepository: _ThrowingSettingsRepo(),
          logger: const Logger('test'),
        );

  @override
  Future<({ChatSessionSettings settings, String? apiKey})>
      resolveAdvancedSettings(ChatSession session) async {
    return (
      settings: const ChatSessionSettings(
        modelId: 'test-model',
        presetId: 'test-preset',
        systemPrompt: '规则',
        temperature: 0.8,
        topP: 0.9,
        maxTokens: 4096,
        autoCompaction: true,
        compactionThreshold: 0.6,
        streamEnabled: true,
        reasoningEffort: ReasoningEffort.disabled,
      ),
      apiKey: null,
    );
  }

  @override
  Future<NamingConfig?> resolveAdvancedGeneratingNamingConfig(
    ChatSession session,
  ) async {
    return const NamingConfig(
      baseUrl: 'https://api.onward/v1',
      apiKey: 'key',
      modelId: 'test-model',
      presetId: 'test-preset',
    );
  }

  @override
  Future<int> resolveContextWindowForPhase({
    String? presetId,
    String? modelId,
    int? effectiveContextLimit,
  }) async =>
      32000;

  @override
  Future<EmbeddingApiConfig?> resolveAdvancedEmbeddingConfig() async => null;
}

class _StubPresetRepo implements ApiPresetRepository {
  @override
  Future<ApiPreset> getPreset(String presetId) async => ApiPreset(
        presetId: presetId,
        name: 'Test',
        baseUrl: 'https://api.onward/v1',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _ThrowingSettingsRepo implements SettingsRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _StubEmbeddingService implements EmbeddingService {
  @override
  Future<Float32List> embed({
    required String text,
    required EmbeddingInputKind kind,
    required String model,
    required String baseUrl,
    required String? apiKey,
    Duration? timeout,
  }) async {
    throw UnimplementedError();
  }
}

class _NoopLlmService implements LlmService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  late AppDatabase db;
  late AgentEventLogRepository eventRepo;
  late ChatRepositoryImpl chatRepo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    eventRepo = AgentEventLogRepository(database: db);
    chatRepo = ChatRepositoryImpl(database: db);
  });

  tearDown(() async => db.close());

  Future<ChatSession> seedSession({bool? engineeringEnabled}) async {
    await db.into(db.chatSessionsTable).insert(
          ChatSessionsTableCompanion.insert(
            sessionId: 's1',
            title: '会话',
            mode: const Value('advanced'),
            engineeringContextEnabled: Value(engineeringEnabled),
          ),
        );
    return chatRepo.getSession('s1');
  }

  Future<void> seedDialogue({required int rounds}) async {
    for (var i = 1; i <= rounds; i++) {
      await chatRepo.addMessage(
        ChatMessage(
          messageId: 'u$i',
          sessionId: 's1',
          role: 'user',
          content: '第$i轮输入',
          createdAt: DateTime(2026, 1, i),
        ),
      );
      await chatRepo.addMessage(
        ChatMessage(
          messageId: 'p$i',
          sessionId: 's1',
          role: 'assistant',
          content: '第$i轮正文',
          createdAt: DateTime(2026, 1, i, 1),
        ),
      );
    }
  }

  Future<AdvancedChatController> buildController(
    ChatSession session, {
    bool withSwitch = true,
  }) async {
    final experienceRepo = ExperienceRepositoryImpl(
      database: db,
      vectorEngine: const VectorEngine(),
    );
    final factualRepo = FactualRepositoryImpl(database: db);
    final controller = AdvancedChatController(
      chatRepository: chatRepo,
      configurationResolver: _FakeResolver(),
      llmService: _NoopLlmService(),
      experienceRepository: experienceRepo,
      embeddingService: _StubEmbeddingService(),
      persistenceService: StoryPersistenceServiceImpl(
        database: db,
        chatRepository: chatRepo,
        experienceRepository: experienceRepo,
        factApplier: FactApplier(repository: factualRepo),
      ),
      failureLogRepository: const StubFailureLogRepository(),
      tokenCounter: TokenCounter(),
      getConfig: () async => const AdvancedConfig(),
      logger: const Logger('test'),
      session: session,
      factualRepository: factualRepo,
      agentEventLogRepository: eventRepo,
      engineeringContextSwitch: withSwitch ? eventRepo : null,
    );
    // 构造器内 loadHistory 异步执行；等待其完成再断言
    for (var i = 0; i < 500 && controller.state.loadingHistory; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return controller;
  }

  test('repair true without epoch must create a complete enter', () async {
    final session = await seedSession(engineeringEnabled: true);
    await seedDialogue(rounds: 1);
    final controller = await buildController(session);
    addTearDown(controller.dispose);
    expect(
      controller.state.engineeringMode,
      EngineeringRuntimeMode.recoveryRequired,
    );
    expect(
      await controller.setEngineeringContextEnabled(enabled: true),
      isTrue,
    );
    expect(
      controller.state.engineeringMode,
      EngineeringRuntimeMode.normalOpen,
      reason: 'Explicit repair must leave recoveryRequired',
    );
    expect(
      (await eventRepo.readModeEpochEvents('s1'))
          .any((e) => e.data['status'] == 'complete'),
      isTrue,
    );
  });

  test('exit false with active epoch must append exit', () async {
    final session = await seedSession(engineeringEnabled: false);
    await eventRepo.appendAll('s1', [
      modeEpochEnterPendingEvent(epochId: 'e', fromTurn: 1),
      modeEpochEnterCompleteEvent(epochId: 'e', captureCount: 0),
    ]);
    final controller = await buildController(session);
    addTearDown(controller.dispose);
    expect(
      controller.state.engineeringMode,
      EngineeringRuntimeMode.recoveryRequired,
    );
    expect(
      await controller.setEngineeringContextEnabled(enabled: false),
      isTrue,
    );
    expect(
      controller.state.engineeringMode,
      EngineeringRuntimeMode.normalClosed,
    );
    expect(
      (await eventRepo.readModeEpochEvents('s1')).last.data['phase'],
      'exit',
    );
  });
}
