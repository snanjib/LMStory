import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/advanced/presentation/controllers/advanced_chat_controller.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';
import 'package:lmstory/features/memory/domain/services/embedding_service.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/story_runtime/data/persistence_service_impl.dart';
import 'package:lmstory/features/story_runtime/domain/entities/auxiliary_generation_failure.dart';
import 'package:lmstory/features/story_runtime/domain/services/session_title_generator.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../../../test_helpers/stub_failure_log_repository.dart';

class _StubPresetRepo implements ApiPresetRepository {
  @override
  Future<List<ApiPreset>> getAllPresets() async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _StubSettingsRepo implements SettingsRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakeResolver extends ConfigurationResolver {
  _FakeResolver()
      : super(
          presetRepository: _StubPresetRepo(),
          settingsRepository: _StubSettingsRepo(),
          logger: const Logger('test'),
        );

  static const _naming = NamingConfig(
    baseUrl: 'https://api.openai.com/v1',
    apiKey: 'test-key',
    modelId: 'test-model',
  );

  @override
  Future<NamingConfig?> resolveTitleNamingConfig() async => _naming;

  @override
  Future<NamingConfig?> resolveAdvancedGeneratingNamingConfig(
    ChatSession session,
  ) async =>
      _naming;

  @override
  Future<({Duration connectTimeout, Duration readTimeout})>
      resolveTimeouts() async => (
            connectTimeout: const Duration(seconds: 5),
            readTimeout: const Duration(seconds: 15),
          );
}

class _DummyLlmService implements LlmService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FakeTitleGenerator extends SessionTitleGenerator {
  _FakeTitleGenerator({this.resultTitle})
      : super(llmService: _DummyLlmService());

  String? resultTitle;
  int callCount = 0;
  String? lastUserMessage;
  String? lastAssistantReply;

  @override
  Future<AuxiliaryGenerationResult<String>> generateWithResult({
    required String userMessage,
    required String assistantReply,
    required NamingConfig namingConfig,
    Duration? connectTimeout,
    Duration? readTimeout,
  }) async {
    callCount++;
    lastUserMessage = userMessage;
    lastAssistantReply = assistantReply;
    return (
      value: resultTitle,
      failure: resultTitle == null
          ? const AuxiliaryGenerationFailure(
              AuxiliaryGenerationFailureKind.emptyOutput,
            )
          : null,
    );
  }
}

class _StubEmbeddingService implements EmbeddingService {
  int get dimension => 1536;
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  late AppDatabase db;
  late ChatRepositoryImpl chatRepo;
  late _FakeResolver resolver;
  late _FakeTitleGenerator titleGen;

  setUp(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
    db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    chatRepo = ChatRepositoryImpl(database: db);
    resolver = _FakeResolver();
    titleGen = _FakeTitleGenerator(resultTitle: '深海探险记');
  });

  tearDown(() async {
    await db.close();
  });

  AdvancedChatController createController({
    required ChatSession session,
  }) {
    final experienceRepo = ExperienceRepositoryImpl(
      database: db,
      vectorEngine: const VectorEngine(),
    );
    return AdvancedChatController(
      chatRepository: chatRepo,
      configurationResolver: resolver,
      llmService: _DummyLlmService(),
      experienceRepository: experienceRepo,
      embeddingService: _StubEmbeddingService(),
      persistenceService: StoryPersistenceServiceImpl(
        database: db,
        chatRepository: chatRepo,
        experienceRepository: experienceRepo,
      ),
      failureLogRepository: const StubFailureLogRepository(),
      tokenCounter: TokenCounter(),
      getConfig: () async => const AdvancedConfig(),
      logger: const Logger('test'),
      session: session,
      titleGenerator: titleGen,
    );
  }

  test('force: true 手动更新标题：成功生成并通过 CAS 写入 DB 与 state', () async {
    await db.customStatement(
      '''INSERT INTO chat_sessions (session_id, mode, title) VALUES ('s1', 'advanced', '旧导演标题')''',
    );
    await db.customStatement(
      '''INSERT INTO chat_messages (message_id, session_id, role, content, created_at) VALUES '''
      '''('m1', 's1', 'user', '我们去深海探险吧', '2026-01-01T00:00:00.000Z'), '''
      '''('m2', 's1', 'assistant', '潜水艇启动了，海水泛着蓝光。', '2026-01-01T00:00:01.000Z')''',
    );

    final session = await chatRepo.getSession('s1');
    final controller = createController(session: session);
    await controller.loadHistory();

    final result = await controller.updateTitle(force: true);

    expect(result, isTrue);
    expect(titleGen.callCount, 1);
    expect(titleGen.lastUserMessage, '我们去深海探险吧');
    expect(titleGen.lastAssistantReply, '潜水艇启动了，海水泛着蓝光。');
    expect(controller.state.session.title, '深海探险记');

    final updatedSession = await chatRepo.getSession('s1');
    expect(updatedSession.title, '深海探险记');
  });

  test('手动更新标题时返回空输出原因并保留原标题', () async {
    await db.customStatement(
      '''INSERT INTO chat_sessions (session_id, mode, title) VALUES ('s1', 'advanced', '不可改变的标题')''',
    );
    await db.customStatement(
      '''INSERT INTO chat_messages (message_id, session_id, role, content, created_at) VALUES '''
      '''('m1', 's1', 'user', '第一句话', '2026-01-01T00:00:00.000Z'), '''
      '''('m2', 's1', 'assistant', '第一句回复', '2026-01-01T00:00:01.000Z')''',
    );

    titleGen.resultTitle = null; // 模拟 LLM 失败

    final session = await chatRepo.getSession('s1');
    final controller = createController(session: session);
    await controller.loadHistory();

    final result = await controller.updateTitleWithResult(force: true);

    expect(result.updated, isFalse);
    expect(result.failure?.kind, AuxiliaryGenerationFailureKind.emptyOutput);
    expect(controller.state.session.title, '不可改变的标题');
    final sessionInDb = await chatRepo.getSession('s1');
    expect(sessionInDb.title, '不可改变的标题');
  });

  test('无任何对话消息时调用 updateTitle 返回 false', () async {
    await db.customStatement(
      '''INSERT INTO chat_sessions (session_id, mode, title) VALUES ('s1', 'advanced', '新导演会话')''',
    );

    final session = await chatRepo.getSession('s1');
    final controller = createController(session: session);
    await controller.loadHistory();

    final result = await controller.updateTitleWithResult(force: true);

    expect(result.updated, isFalse);
    expect(result.failure?.kind, AuxiliaryGenerationFailureKind.noConversation);
    expect(titleGen.callCount, 0);
  });

  test('命名期间用户在侧边栏抢先重命名：CAS 拦截，保全用户修改', () async {
    await db.customStatement(
      '''INSERT INTO chat_sessions (session_id, mode, title) VALUES ('s1', 'advanced', '旧标题')''',
    );
    await db.customStatement(
      '''INSERT INTO chat_messages (message_id, session_id, role, content, created_at) VALUES '''
      '''('m1', 's1', 'user', '消息一', '2026-01-01T00:00:00.000Z'), '''
      '''('m2', 's1', 'assistant', '回复一', '2026-01-01T00:00:01.000Z')''',
    );

    final session = await chatRepo.getSession('s1');
    final controller = createController(session: session);
    await controller.loadHistory();

    // 模拟在 LLM 生成期间，用户在侧边栏手动改名为「用户独家命名」
    await db.customStatement(
      '''UPDATE chat_sessions SET title = '用户独家命名' WHERE session_id = 's1' ''',
    );

    final result = await controller.updateTitleWithResult(force: true);

    expect(result.updated, isFalse);
    expect(result.failure?.kind, AuxiliaryGenerationFailureKind.titleChanged);
    final finalSession = await chatRepo.getSession('s1');
    expect(finalSession.title, '用户独家命名');
  });

  test('updateTitleFromSummary 别名方法与 updateTitle 行为一致', () async {
    await db.customStatement(
      '''INSERT INTO chat_sessions (session_id, mode, title) VALUES ('s1', 'advanced', '旧标题')''',
    );
    await db.customStatement(
      '''INSERT INTO chat_messages (message_id, session_id, role, content, created_at) VALUES '''
      '''('m1', 's1', 'user', '消息一', '2026-01-01T00:00:00.000Z'), '''
      '''('m2', 's1', 'assistant', '回复一', '2026-01-01T00:00:01.000Z')''',
    );

    final session = await chatRepo.getSession('s1');
    final controller = createController(session: session);
    await controller.loadHistory();

    final result = await controller.updateTitleFromSummary(force: true);

    expect(result, isTrue);
    expect(controller.state.session.title, '深海探险记');
  });

  test('force: false（自动命名场景）：非草稿标题直接拒绝', () async {
    await db.customStatement(
      '''INSERT INTO chat_sessions (session_id, mode, title) VALUES ('s1', 'advanced', '已有正经标题')''',
    );
    await db.customStatement(
      '''INSERT INTO chat_messages (message_id, session_id, role, content, created_at) VALUES '''
      '''('m1', 's1', 'user', '消息一', '2026-01-01T00:00:00.000Z'), '''
      '''('m2', 's1', 'assistant', '回复一', '2026-01-01T00:00:01.000Z')''',
    );

    final session = await chatRepo.getSession('s1');
    final controller = createController(session: session);
    await controller.loadHistory();

    final result = await controller.updateTitle();

    expect(result, isFalse);
    expect(titleGen.callCount, 0);
  });
}
