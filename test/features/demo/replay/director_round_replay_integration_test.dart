import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/config_loader.dart';
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
import 'package:lmstory/features/demo/domain/demo_replay_timing.dart';
import 'package:lmstory/features/demo/domain/demo_scene.dart';
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

Variable<String> driftVar(String v) => Variable.withString(v);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late DemoSecureStorage secure;
  late DemoPreferences prefs;
  late DemoNetworkGuard guard;
  late DemoPack pack;
  late ConfigurationResolver resolver;
  late ChatRepositoryImpl chatRepo;
  late AdvancedChatController controller;

  Future<DemoPack> loadSamplePack() async {
    final raw = File('assets/demo/first_launch/zh-CN.json').readAsStringSync();
    return DemoPack.parse(jsonDecode(raw) as Map<String, dynamic>);
  }

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    secure = DemoSecureStorage();
    prefs = DemoPreferences();
    guard = DemoNetworkGuard();
    pack = await loadSamplePack();

    final seed =
        await seedDemoEnvironment(db, secure, prefs, localeTag: 'zh-CN');

    // 向导完成后的全局配置形态（嵌入两键写入 overlay；GM 走会话级覆盖）
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
      logger: const Logger('crown'),
    );

    chatRepo = ChatRepositoryImpl(database: db);
    final experienceRepo = ExperienceRepositoryImpl(
      database: db,
      vectorEngine: const VectorEngine(),
    );
    final factualRepo = FactualRepositoryImpl(database: db);

    // 规则步产物：内置异世界模板全文（与真实向导一致）
    final template =
        await TemplateRepositoryImpl(db).getTemplate('builtin-isekai-narrator');

    controller = AdvancedChatController(
      chatRepository: chatRepo,
      configurationResolver: resolver,
      llmService: DemoReplayLlmService(
        pack: pack,
        guard: guard,
        timing: DemoReplayTiming.immediate,
      ),
      experienceRepository: experienceRepo,
      embeddingService: DemoReplayEmbeddingService(pack: pack, guard: guard),
      persistenceService: StoryPersistenceServiceImpl(
        database: db,
        chatRepository: chatRepo,
        experienceRepository: experienceRepo,
        factApplier: FactApplier(repository: factualRepo),
      ),
      failureLogRepository: const StubFailureLogRepository(),
      tokenCounter: TokenCounter(),
      getConfig: () async => const AdvancedConfig(),
      logger: const Logger('crown'),
      session: ChatSession(
        sessionId: '__draft_intermediate_crown',
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
      capabilitiesOverride: pack.manifest.replayProfile?.resolveCapabilities(),
    );
  });

  tearDown(() async {
    controller.dispose();
    await db.close();
  });

  test('完整回合回放：真实工具链落库 + 零远程调用企图', () async {
    expect(controller.state.phase, IntermediatePhase.idle);

    // 用户亲自点击发送（固定提示词原文）
    await controller.sendMessage(pack.prompt);

    // 轮次推进到 idle（超时上限兜底；回放零延迟应远快于上限）
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (controller.state.phase != IntermediatePhase.idle &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(
      controller.state.phase,
      IntermediatePhase.idle,
      reason: '回合应在超时前完成；失败态=${controller.state.failureContext}',
    );

    // —— 零远程调用企图（守卫计数而非断网）——
    expect(
      guard.attemptCount,
      0,
      reason: '存在远程调用企图：${guard.attempts.take(5).toList()}',
    );

    // —— 会话物化与轮次状态 ——
    final sessions = await chatRepo.getAllSessions();
    expect(sessions, hasLength(1));
    final session = sessions.single;
    expect(session.mode, 'advanced');
    expect(session.nextTurn, 2, reason: 'finish_round 提交后 next_turn=2');
    expect(session.systemPromptOverride, contains('异世界'));
    expect(
      session.title,
      isNotEmpty,
      reason: '标题生成走 title 回放或保留默认，二者皆真实行为',
    );

    // —— 消息：user + assistant 正文 ——
    final messages = await chatRepo.getMessages(session.sessionId);
    final roles = messages.map((m) => m.role).toList();
    expect(roles, containsAll(['user', 'assistant']));
    final assistant = messages.lastWhere((m) => m.role == 'assistant');
    for (final expected in pack.expectations.proseContains) {
      expect(assistant.content, contains(expected));
    }

    // —— 实体来自真实 update_facts → FactApplier 事务落库 ——
    final entityNames = (await db.customSelect(
      'SELECT primary_name FROM factual_entities WHERE session_id = ?',
      variables: [driftVar(session.sessionId)],
    ).get())
        .map((r) => r.read<String>('primary_name'))
        .toSet();
    for (final expected in pack.expectations.entityNames) {
      expect(
        entityNames,
        contains(expected),
        reason: '期望实体 $expected 未由真实工具链创建（实际：$entityNames）',
      );
    }

    // —— 事件记忆经 record_event_memory → 持久化事务 ——
    final memories = await db.customSelect(
      'SELECT summary, what_text, who_text, where_text '
      'FROM experiential_memories WHERE session_id = ?',
      variables: [driftVar(session.sessionId)],
    ).get();
    expect(memories, isNotEmpty, reason: '事件记忆未落库');
    // record_event_memory 的 5W1E 存独立列（summary 列可为空）
    final summaries = memories
        .map(
          (m) => [
            m.read<String>('summary'),
            m.read<String>('what_text'),
            m.read<String>('who_text'),
            m.read<String>('where_text'),
          ].where((s) => s != '').join(' '),
        )
        .join(' ');
    for (final needle in pack.expectations.eventSummaryContains) {
      expect(summaries, contains(needle));
    }

    // —— FTS 可查 ——
    final fts = await db.customSelect(
      'SELECT COUNT(*) AS n FROM memories_fts WHERE session_id = ?',
      variables: [driftVar(session.sessionId)],
    ).get();
    expect(fts.first.read<int>('n'), greaterThan(0));

    // —— 轮次产物与事件日志 ——
    final artifacts = await db.customSelect(
      'SELECT COUNT(*) AS n FROM intermediate_round_artifacts '
      'WHERE session_id = ? AND turn_number = 1',
      variables: [driftVar(session.sessionId)],
    ).get();
    expect(artifacts.first.read<int>('n'), 1);
    final events = await db.customSelect(
      'SELECT COUNT(*) AS n FROM agent_events WHERE session_id = ?',
      variables: [driftVar(session.sessionId)],
    ).get();
    expect(events.first.read<int>('n'), greaterThan(0));

    // —— 样本正文断言（期望来自包内 expectations，而非硬编码）——
    final prose = assistant.content ?? '';
    for (final needle in pack.expectations.proseContains) {
      expect(prose, contains(needle));
    }
  });
}
