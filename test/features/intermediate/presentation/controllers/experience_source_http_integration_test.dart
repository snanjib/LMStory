import 'dart:convert';
import 'dart:io' as io;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/network/http_client.dart';
import 'package:lmstory/core/network/llm_adapters/llm_adapter_factory.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/datasources/llm_remote_datasource.dart';
import 'package:lmstory/features/chat/data/repositories/chat_repository_impl.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session_settings.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/intermediate/domain/entities/intermediate_chat_state.dart';
import 'package:lmstory/features/intermediate/presentation/controllers/intermediate_chat_controller.dart';
import 'package:lmstory/features/memory/data/repositories/experience_repository_impl.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';
import 'package:lmstory/features/memory/domain/services/embedding_service.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/story_runtime/data/persistence_service_impl.dart';
import 'package:lmstory/features/story_runtime/domain/services/compaction_service.dart';
import 'package:lmstory/features/story_runtime/domain/services/persistence_service.dart';

import '../../../../test_helpers/stub_failure_log_repository.dart';

class _UnusedPresetRepository implements ApiPresetRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnusedSettingsRepository implements SettingsRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _UnusedEmbeddingService implements EmbeddingService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// 本用例只验证记忆流转，小上下文使用确定性计数。
class _LocalTokenCounter extends TokenCounter {
  @override
  Future<int> countTokens(String text) async => text.length;

  @override
  Future<int> countTokensForMessages(List<String> messages) async =>
      messages.join(' ').length;

  @override
  Future<List<int>> countTokensForEach(List<String> texts) async =>
      texts.map((text) => text.length).toList();
}

/// 只固定本地端点和模型配置，故事写入、检索、装配及 HTTP 传输均用真实实现。
class _LocalConfigurationResolver extends ConfigurationResolver {
  _LocalConfigurationResolver(this.baseUrl)
      : super(
          presetRepository: _UnusedPresetRepository(),
          settingsRepository: _UnusedSettingsRepository(),
          logger: const Logger('experience_source_http_test'),
        );

  final String baseUrl;

  @override
  Future<({ChatSessionSettings settings, String? apiKey})>
      resolveIntermediateSettings(ChatSession session) async => (
            settings: const ChatSessionSettings(
              modelId: 'generating',
              presetId: 'local',
              systemPrompt: '',
              temperature: 0.8,
              topP: 0.9,
              maxTokens: 4096,
              autoCompaction: true,
              compactionThreshold: 0.6,
              streamEnabled: true,
            ),
            apiKey: 'local-test-key',
          );

  @override
  Future<NamingConfig?> resolveIntermediatePhaseNamingConfig(
    ChatSession session,
    String phase,
  ) async =>
      NamingConfig(baseUrl: baseUrl, apiKey: 'local-test-key', modelId: phase);

  @override
  Future<int> resolveContextWindowForPhase({
    String? presetId,
    String? modelId,
    int? effectiveContextLimit,
  }) async =>
      96000;

  @override
  Future<EmbeddingApiConfig?> resolveEmbeddingConfig() async => null;

  @override
  Future<GlobalDefaultsSnapshot> snapshotIntermediateDefaults() async =>
      const GlobalDefaultsSnapshot();
}

String _sse(String content) {
  final event = jsonEncode({
    'choices': [
      {
        'delta': {'content': content},
      },
    ],
  });
  return 'data: $event\n\ndata: [DONE]\n\n';
}

void main() {
  test('生产写入的第 37 轮往事经检索进入生成和审查 HTTP 请求', () async {
    final server = await io.HttpServer.bind(io.InternetAddress.loopbackIPv4, 0);
    final requests = <String, List<Map<String, dynamic>>>{};
    final paths = <String>[];
    final keywords = jsonEncode({
      'characters': <String>[],
      'items': ['SAPPHIRE'],
      'locations': <String>[],
      'actions': <String>[],
      'plots': <String>[],
    });
    final responseByModel = <String, List<String>>{
      'extracting': [keywords, keywords],
      'generating': ['阿宁收下了蓝色宝石。', '阿宁打开了木盒。'],
      'reviewing': ['阿宁收下 SAPPHIRE 宝石，然后把它放进木盒。', '阿宁小心地打开了木盒。'],
      'summarizing': [
        jsonEncode({
          'what': '阿宁收下 SAPPHIRE 宝石',
          'importance': 4,
          'tags': ['SAPPHIRE'],
          'narrativeTime': '来公寓第三天',
          'event_ended': false,
        }),
        jsonEncode({
          'what': '阿宁打开木盒',
          'importance': 3,
          'tags': ['木盒'],
          'event_ended': false,
        }),
      ],
    };
    final subscription = server.listen((request) async {
      paths.add(request.uri.path);
      final body = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      final model = body['model'] as String;
      final stageRequests = requests.putIfAbsent(model, () => [])..add(body);
      final responses = responseByModel[model];
      if (responses == null || stageRequests.length > responses.length) {
        request.response.statusCode = io.HttpStatus.badRequest;
      } else {
        request.response.headers.contentType =
            io.ContentType('text', 'event-stream', charset: 'utf-8');
        request.response.write(_sse(responses[stageRequests.length - 1]));
      }
      await request.response.close();
    });

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final chatRepository = ChatRepositoryImpl(database: db);
    final experienceRepository = ExperienceRepositoryImpl(
      database: db,
      vectorEngine: const VectorEngine(),
    );
    final persistence = StoryPersistenceServiceImpl(
      database: db,
      chatRepository: chatRepository,
      experienceRepository: experienceRepository,
    );
    IntermediateChatController? controller;

    try {
      final session = await chatRepository.createSession(
        title: '合成故事',
        mode: 'intermediate',
      );
      // 生产事务建立前 36 轮短历史，避免直接改会话计数或注入来源标记。
      final mergeInputIds = <String>[];
      for (var turn = 1; turn <= 36; turn++) {
        final createdAt = DateTime(2026).add(Duration(seconds: turn * 2));
        final previous = await persistence.persistRound(
          userMessage: ChatMessage(
            messageId: 'synthetic-user-$turn',
            sessionId: session.sessionId,
            role: 'user',
            content: '此前的指令 $turn',
            createdAt: createdAt,
          ),
          assistantMessage: ChatMessage(
            messageId: 'synthetic-assistant-$turn',
            sessionId: session.sessionId,
            role: 'assistant',
            content: '此前的故事 $turn',
            createdAt: createdAt.add(const Duration(seconds: 1)),
          ),
          eventSummary: EventSummary(
            summary: switch (turn) {
              30 => '阿宁将 SAPPHIRE 宝石放下',
              36 => '阿宁又拿起 SAPPHIRE 宝石',
              _ => '此前的片段 $turn',
            },
            importance: 1,
            tags: const [],
            turnNumber: turn,
          ),
          embedding: null,
          artifacts: null,
          indexForRetrieval: false,
        );
        if (turn == 30 || turn == 36) {
          mergeInputIds.add(previous.memory.memoryId);
        }
      }
      expect((await chatRepository.getSession(session.sessionId)).nextTurn, 37);
      expect(mergeInputIds, hasLength(2));

      final llmService = LlmRemoteDataSource(
        httpClient: HttpClient(),
        adapterFactory: LlmAdapterFactory(),
      );
      final tokenCounter = _LocalTokenCounter();
      controller = IntermediateChatController(
        chatRepository: chatRepository,
        configurationResolver:
            _LocalConfigurationResolver('http://127.0.0.1:${server.port}'),
        llmService: llmService,
        experienceRepository: experienceRepository,
        embeddingService: _UnusedEmbeddingService(),
        persistenceService: persistence,
        failureLogRepository: const StubFailureLogRepository(),
        tokenCounter: tokenCounter,
        getConfig: () async => const IntermediateConfig(reviewEnabled: true),
        logger: const Logger('experience_source_http_test'),
        session: await chatRepository.getSession(session.sessionId),
        compactionService: StoryCompactionService(
          tokenCounter: tokenCounter,
          llmService: llmService,
        ),
      );
      await controller.loadHistory();
      await controller.sendMessage('旅人把蓝色宝石交给阿宁。');
      expect(
        controller.state.phase,
        IntermediatePhase.idle,
        reason: '第 37 轮失败：${controller.state.failureContext}',
      );
      expect((await chatRepository.getSession(session.sessionId)).nextTurn, 38);
      final written = (await experienceRepository.getRecentExperiences(
        session.sessionId,
        limit: 1,
      ))
          .single;
      expect(written.turnNumber, 37);
      expect(written.what, '阿宁收下 SAPPHIRE 宝石');
      expect(written.narrativeTime, '来公寓第三天');
      expect(written.importance, 4);

      // 真实合并写入会删除原来的低重要性记忆，两条结果共享最大轮号。
      final mergeInputs = (await experienceRepository.getAllExperiences(
        session.sessionId,
      ))
          .where((memory) => mergeInputIds.contains(memory.memoryId))
          .toList();
      expect(mergeInputs, hasLength(mergeInputIds.length));
      await persistence.persistConsolidatedMemories(
        sessionId: session.sessionId,
        records: const [
          ConsolidatedMemoryRecord(
            summary: '阿宁放下 SAPPHIRE 宝石',
            tags: ['SAPPHIRE'],
            importance: 4,
            turnNumber: 36,
          ),
          ConsolidatedMemoryRecord(
            summary: '阿宁拿起 SAPPHIRE 宝石',
            tags: ['SAPPHIRE'],
            importance: 4,
            turnNumber: 36,
          ),
        ],
        originalMemories: mergeInputs,
      );
      final recent = await experienceRepository.getRecentExperiences(
        session.sessionId,
        limit: 50,
      );
      final consolidated = recent.where(
        (memory) =>
            memory.summary == '阿宁放下 SAPPHIRE 宝石' ||
            memory.summary == '阿宁拿起 SAPPHIRE 宝石',
      );
      expect(consolidated, hasLength(2));
      expect(consolidated.map((memory) => memory.turnNumber), everyElement(36));
      expect(
        consolidated.map((memory) => memory.hasVerifiedSourceTurn),
        everyElement(isFalse),
      );
      for (final id in mergeInputIds) {
        expect(recent.map((memory) => memory.memoryId), isNot(contains(id)));
      }

      await controller.sendMessage('阿宁再次查看那颗宝石。');

      expect(
        controller.state.phase,
        IntermediatePhase.idle,
        reason: '本轮失败：${controller.state.failureContext}',
      );
      expect((await chatRepository.getSession(session.sessionId)).nextTurn, 39);
      expect(
        controller.state.artifactsByTurnNumber?[38]?.retrievedMemories
            .map((memory) => memory.memoryId),
        containsAll([
          written.memoryId,
          ...consolidated.map((memory) => memory.memoryId),
        ]),
      );
      expect(
        requests.keys,
        containsAll(['extracting', 'generating', 'reviewing', 'summarizing']),
      );
      expect(paths, everyElement('/v1/chat/completions'));

      Map<String, dynamic> latestRequestFor(String stage) {
        final stageRequests = requests[stage] ?? fail('$stage 没有收到请求');
        expect(stageRequests, hasLength(2), reason: '$stage 每轮应发送一次');
        return stageRequests.last;
      }

      String contentFor(String stage) {
        final messages = latestRequestFor(stage)['messages'] as List<dynamic>;
        final memoryBlocks = messages
            .cast<Map<String, dynamic>>()
            .where((message) => message['role'] == 'system')
            .map((message) => message['content'])
            .whereType<String>()
            .where((content) => content.startsWith('【经历摘要类记忆检索结果】'));
        expect(memoryBlocks, hasLength(1), reason: '$stage 应有一段检索记忆');
        return memoryBlocks.single;
      }

      // 两个断言分别绑定实际收到的生成与审查请求，标签和正文属于同一条往事。
      const expectedMemory = '[来公寓第三天·来源第37轮·重要性4]\n· 何事：阿宁收下 SAPPHIRE 宝石';
      final generating = contentFor('generating');
      final reviewing = contentFor('reviewing');
      expect(generating, contains(expectedMemory));
      expect(reviewing, contains(expectedMemory));
      for (final request in [generating, reviewing]) {
        expect(request, contains('[2轮前·重要性4]\n· 阿宁放下 SAPPHIRE 宝石'));
        expect(request, contains('[2轮前·重要性4]\n· 阿宁拿起 SAPPHIRE 宝石'));
        expect(request, isNot(contains('来源第36轮')));
      }

      final capturePath = io.Platform.environment['LMSTORY_RAG_CAPTURE_DIR'];
      if (capturePath != null && capturePath.isNotEmpty) {
        final directory = io.Directory(capturePath);
        if (!directory.isAbsolute) {
          throw ArgumentError('LMSTORY_RAG_CAPTURE_DIR 必须是绝对路径');
        }
        await directory.create(recursive: true);
        final generatingFile =
            io.File('${directory.path}/turn_38_generating_request.json');
        final reviewingFile =
            io.File('${directory.path}/turn_38_reviewing_request.json');
        if (generatingFile.existsSync() || reviewingFile.existsSync()) {
          throw StateError('请求证据文件已存在，请使用新目录');
        }
        const encoder = JsonEncoder.withIndent('  ');
        await generatingFile.writeAsString(
          '${encoder.convert(latestRequestFor('generating'))}\n',
        );
        await reviewingFile.writeAsString(
          '${encoder.convert(latestRequestFor('reviewing'))}\n',
        );
      }
    } finally {
      controller?.dispose();
      await db.close();
      await subscription.cancel();
      await server.close(force: true);
    }
  });
}
