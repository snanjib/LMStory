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
import 'package:lmstory/features/demo/data/demo_session_handover.dart';
import 'package:lmstory/features/demo/data/replay_embedding_service.dart';
import 'package:lmstory/features/demo/data/replay_llm_service.dart';
import 'package:lmstory/features/demo/domain/demo_candidate.dart';
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

/// 中英文资产逐一经真实 Controller/AgentRunner/工具/事务走完整
/// 回合并交接（不走任何注入桩；资产字节来自仓库内真实文件）。
///
/// 每份包固定记录自己的独立语义证据（proseContains/entityNames/
/// eventSummaryContains/nextTurn），期望全部来自包内 expectations——
/// 不允许把期望改成「等于当前实际结果」来掩盖串包。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final catalogRaw =
      File('assets/demo/first_launch/catalog.json').readAsStringSync();
  final candidates = parseDemoCandidateCatalog(
    jsonDecode(catalogRaw) as Map<String, dynamic>,
  );

  test('候选目录装载：五个中文候选和一个英文样例', () {
    expect(candidates.where((c) => c.locale == 'zh-CN'), hasLength(5));
    expect(
      candidates.where((c) => c.locale == 'en-US').single.id,
      'en-us-story-sample',
    );
  });

  for (final candidate in candidates) {
    final pack = DemoPack.parse(
      jsonDecode(File(candidate.assetPath).readAsStringSync())
          as Map<String, dynamic>,
    );

    group('候选 ${candidate.id}（${candidate.sourceModelId}）全链回放', () {
      late AppDatabase db;
      late AppDatabase realDb;
      late DemoSecureStorage secure;
      late DemoPreferences prefs;
      late DemoNetworkGuard guard;
      late ChatRepositoryImpl chatRepo;
      late AdvancedChatController controller;
      late String templateContent;

      setUp(() async {
        db = AppDatabase.forTesting(NativeDatabase.memory());
        realDb = AppDatabase.forTesting(NativeDatabase.memory());
        secure = DemoSecureStorage();
        prefs = DemoPreferences();
        guard = DemoNetworkGuard();

        final seed = await seedDemoEnvironment(
          db,
          secure,
          prefs,
          localeTag: candidate.locale,
          candidates: [candidate],
        );

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
        final resolver = ConfigurationResolver(
          presetRepository: presetRepo,
          settingsRepository: settingsRepo,
          logger: const Logger('five-pack'),
        );

        chatRepo = ChatRepositoryImpl(database: db);
        final experienceRepo = ExperienceRepositoryImpl(
          database: db,
          vectorEngine: const VectorEngine(),
        );
        final factualRepo = FactualRepositoryImpl(database: db);

        // 规则步产物：内置异世界模板全文（与真实向导一致）
        final template = await TemplateRepositoryImpl(db)
            .getTemplate('builtin-isekai-narrator');
        templateContent = template.content;

        controller = AdvancedChatController(
          chatRepository: chatRepo,
          configurationResolver: resolver,
          llmService: DemoReplayLlmService(
            pack: pack,
            guard: guard,
            timing: DemoReplayTiming.immediate,
          ),
          experienceRepository: experienceRepo,
          embeddingService:
              DemoReplayEmbeddingService(pack: pack, guard: guard),
          persistenceService: StoryPersistenceServiceImpl(
            database: db,
            chatRepository: chatRepo,
            experienceRepository: experienceRepo,
            factApplier: FactApplier(repository: factualRepo),
          ),
          failureLogRepository: const StubFailureLogRepository(),
          tokenCounter: TokenCounter(),
          getConfig: () async => const AdvancedConfig(),
          logger: const Logger('five-pack'),
          session: ChatSession(
            sessionId: '__draft_intermediate_five_pack',
            title: '新导演会话',
            mode: 'advanced',
            createdAt: DateTime.now(),
            lastActiveAt: DateTime.now(),
            messageCount: 0,
            phaseModels: SessionPhaseModels(
              generatingPresetId: seed.presetId,
              generatingModelId: candidate.virtualModelId,
            ),
            systemPromptOverride: templateContent,
          ),
          factualRepository: factualRepo,
          agentEventLogRepository: AgentEventLogRepository(database: db),
          capabilitiesOverride:
              pack.manifest.replayProfile?.resolveCapabilities(),
        );
      });

      tearDown(() async {
        controller.dispose();
        await db.close();
        await realDb.close();
      });

      test('真实工具链回合 + 候选独立语义证据 + 零远程调用企图', () async {
        expect(controller.state.phase, IntermediatePhase.idle);

        // 用户亲自点击发送（固定提示词原文）
        await controller.sendMessage(pack.prompt);

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

        expect(
          guard.attemptCount,
          0,
          reason: '存在远程调用企图：${guard.attempts.take(5).toList()}',
        );

        // —— 会话物化与轮次状态（nextTurn 期望来自包内契约）——
        final sessions = await chatRepo.getAllSessions();
        expect(sessions, hasLength(1));
        final session = sessions.single;
        expect(session.mode, 'advanced');
        expect(
          session.nextTurn,
          pack.expectations.nextTurn,
          reason: '候选 ${candidate.id} next_turn 契约',
        );

        // —— 消息：user + assistant 正文（候选独立语义证据）——
        final messages = await chatRepo.getMessages(session.sessionId);
        final roles = messages.map((m) => m.role).toList();
        expect(roles, containsAll(pack.expectations.messageRoles));
        final assistant = messages.lastWhere((m) => m.role == 'assistant');
        for (final expected in pack.expectations.proseContains) {
          expect(
            assistant.content,
            contains(expected),
            reason: '候选 ${candidate.id} 独立正文证据必须由真实回放产出',
          );
        }

        // —— 实体：候选各自形态（glm-5.3-flash 零实体必须为空，不造实体）——
        final entityRows = await db.customSelect(
          'SELECT primary_name FROM factual_entities WHERE session_id = ?',
          variables: [driftVar(session.sessionId)],
        ).get();
        final entityNames =
            entityRows.map((r) => r.read<String>('primary_name')).toSet();
        for (final expected in pack.expectations.entityNames) {
          expect(
            entityNames,
            contains(expected),
            reason: '候选 ${candidate.id} 期望实体未由真实工具链创建（实际：'
                '$entityNames）',
          );
        }
        if (pack.expectations.entityNames.isEmpty) {
          expect(
            entityNames,
            isEmpty,
            reason: '零实体候选不得虚构实体条目',
          );
        }

        // —— 事件记忆经 record_event_memory 真实落库 ——
        final memories = await db.customSelect(
          'SELECT summary, what_text, who_text, where_text '
          'FROM experiential_memories WHERE session_id = ?',
          variables: [driftVar(session.sessionId)],
        ).get();
        expect(memories, isNotEmpty, reason: '事件记忆未落库');
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
          expect(
            summaries,
            contains(needle),
            reason: '候选 ${candidate.id} 独立事件证据',
          );
        }

        // —— FTS 可查 + 回合产物 + 事件日志 ——
        final fts = await db.customSelect(
          'SELECT COUNT(*) AS n FROM memories_fts WHERE session_id = ?',
          variables: [driftVar(session.sessionId)],
        ).get();
        expect(fts.first.read<int>('n'), greaterThan(0));
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

        // —— 交接：demo → 正式库，虚拟引用全列清理 ——
        final result = await DemoSessionHandover().run(
          demoDb: db,
          realDb: realDb,
          sourceSessionId: session.sessionId,
        );
        expect(result, DemoHandoverResult.imported);

        final realSessions = await realDb
            .customSelect(
              'SELECT session_id, preset_id, model_id, '
              'generating_preset_id, generating_model_id, '
              'extracting_preset_id, extracting_model_id, '
              'reviewing_preset_id, reviewing_model_id, '
              'summarizing_preset_id, summarizing_model_id, '
              'suggest_reply_preset_id, suggest_reply_model_id, '
              'draft_input FROM chat_sessions',
            )
            .get();
        expect(realSessions, hasLength(1));
        final imported = realSessions.single;
        for (final col in [
          'preset_id',
          'model_id',
          'generating_preset_id',
          'generating_model_id',
          'extracting_preset_id',
          'extracting_model_id',
          'reviewing_preset_id',
          'reviewing_model_id',
          'summarizing_preset_id',
          'summarizing_model_id',
          'suggest_reply_preset_id',
          'suggest_reply_model_id',
        ]) {
          expect(
            imported.data[col],
            '',
            reason: '交接必须清空虚拟模型引用列 $col（候选 '
                '${candidate.id}）',
          );
        }
        expect(imported.data['draft_input'], isNull);

        // 虚拟 preset 不进正式库；正文/实体/事件保留
        final realPresets = await realDb
            .customSelect('SELECT COUNT(*) n FROM api_presets')
            .get();
        expect(realPresets.first.read<int>('n'), 0);
        final realMessages = await realDb.customSelect(
          'SELECT content FROM chat_messages WHERE session_id = ? '
          "AND role = 'assistant'",
          variables: [driftVar(session.sessionId)],
        ).get();
        expect(realMessages, isNotEmpty);
        expect(
          (realMessages.last.data['content'] as String?) ?? '',
          contains(pack.expectations.proseContains.first),
        );
        final realEntities = await realDb.customSelect(
          'SELECT COUNT(*) n FROM factual_entities WHERE session_id = ?',
          variables: [driftVar(session.sessionId)],
        ).get();
        expect(
          realEntities.first.read<int>('n'),
          entityRows.length,
          reason: '实体随会话原样交接（数量保持）',
        );
        final realMemories = await realDb.customSelect(
          'SELECT has_embedding FROM experiential_memories '
          'WHERE session_id = ?',
          variables: [driftVar(session.sessionId)],
        ).get();
        for (final row in realMemories) {
          expect(
            row.data['has_embedding'],
            anyOf(0, isNull),
            reason: '演示向量不进真实嵌入空间（交接剥离）',
          );
        }
      });
    });
  }
}
