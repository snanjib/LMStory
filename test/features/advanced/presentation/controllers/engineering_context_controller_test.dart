import 'dart:async';

import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/core/vector/vector_engine.dart';
import 'package:lmstory/features/advanced/data/repositories/agent_event_log_repository.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_durable_event.dart';
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

import '../../../../test_helpers/stub_failure_log_repository.dart';

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
    EngineeringContextSwitchStore? switchOverride,
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
      engineeringContextSwitch:
          switchOverride ?? (withSwitch ? eventRepo : null),
    );
    // 构造器内 loadHistory 异步执行；等待其完成再断言
    for (var i = 0; i < 500 && controller.state.loadingHistory; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return controller;
  }

  test('普通关闭会话（无纪元证据）→ 正常关闭，冷路径 trim 照旧', () async {
    final session = await seedSession();
    await seedDialogue(rounds: 2);
    // 30 轮旧事件（远超默认 20 轮保留窗）
    await eventRepo.appendAll(
      's1',
      [
        for (var turn = 1; turn <= 30; turn++)
          AgentDurableEvent(
            type: AgentEventTypes.assistantMessage,
            surfaceOp: AgentSurfaceOpKind.append,
            data: {'text': '旧轮$turn', 'turn': turn},
          ),
      ],
    );

    final controller = await buildController(session);

    expect(
      controller.state.engineeringMode,
      EngineeringRuntimeMode.normalClosed,
    );
    // 关闭态冷路径 trim 保持基线行为：早期轮事件已被裁
    final remaining = await eventRepo.readEvents('s1');
    expect(
      remaining.any(
        (e) =>
            e.type == AgentEventTypes.assistantMessage &&
            e.data['text'] == '旧轮1',
      ),
      isFalse,
    );
  });

  test('true 列缺纪元（含旧诊断事件）→ 需要修复：停轮、trim 零调用', () async {
    final session = await seedSession(engineeringEnabled: true);
    // 账本只有关闭期旧事件（含 30 轮旧轮次）——修复态下不得裁剪
    await eventRepo.appendAll(
      's1',
      [
        for (var turn = 1; turn <= 30; turn++)
          AgentDurableEvent(
            type: AgentEventTypes.assistantMessage,
            surfaceOp: AgentSurfaceOpKind.append,
            data: {'text': '旧轮$turn', 'turn': turn},
          ),
      ],
    );

    final controller = await buildController(session);

    expect(
      controller.state.engineeringMode,
      EngineeringRuntimeMode.recoveryRequired,
    );
    expect(controller.state.engineeringModeReason, 'enabled-without-epoch');
    // 数据保护铁律：事件全量保留（trim 零调用）
    final remaining = await eventRepo.readEvents('s1');
    expect(remaining, hasLength(30));
    // 停轮：发送入口被拦截，输入退回输入框
    expect(await controller.sendMessage('新消息'), isFalse);
    // 通用 updateSession 拦截开关旁路
    expect(
      await controller.updateSession(
        controller.state.session.copyWith(engineeringContextEnabled: false),
      ),
      isFalse,
    );
    expect(
      (await chatRepo.getSession('s1')).engineeringContextEnabled,
      isTrue,
    );
  });

  test('setEngineeringContextEnabled(true)：原子进入 + 捕获镜像可见历史', () async {
    final session = await seedSession();
    await seedDialogue(rounds: 2);
    final controller = await buildController(session);
    expect(
      controller.state.engineeringMode,
      EngineeringRuntimeMode.normalClosed,
    );

    final ok = await controller.setEngineeringContextEnabled(enabled: true);
    expect(ok, isTrue);
    expect(
      (await chatRepo.getSession('s1')).engineeringContextEnabled,
      isTrue,
    );
    expect(
      controller.state.engineeringMode,
      EngineeringRuntimeMode.normalOpen,
    );
    expect(controller.state.session.engineeringContextEnabled, isTrue);

    // 账本：pending → 捕获（镜像 u/p 正文）→ complete
    final events = await eventRepo.readEvents('s1');
    final epochEvents = await eventRepo.readModeEpochEvents('s1');
    expect(epochEvents.first.data['status'], 'pending');
    expect(epochEvents.last.data['status'], 'complete');
    expect(epochEvents.last.data['captureCount'], 4);
    final captures =
        events.where((e) => e.type == AgentEventTypes.modeCapture).toList();
    expect(captures, hasLength(4));
    final capturedText = captures.map((e) => e.data['content']).toList();
    expect(capturedText, containsAll(['第1轮输入', '第1轮正文', '第2轮输入', '第2轮正文']));
    // 捕获投影逐字节还原可见历史（关闭→开启边界表示不变）
    final projection = deriveAgentSurface(captures);
    expect(
      projection.messages.map((m) => m.content).toList(),
      capturedText,
    );

    // 开启态再次进入是幂等拒绝（已开启）
    expect(
      await controller.setEngineeringContextEnabled(enabled: true),
      isTrue,
    );
  });

  test('setEngineeringContextEnabled(false)：原子退出 + 解析回正常关闭', () async {
    final session = await seedSession();
    await seedDialogue(rounds: 1);
    final controller = await buildController(session);
    await controller.setEngineeringContextEnabled(enabled: true);
    expect(
      controller.state.engineeringMode,
      EngineeringRuntimeMode.normalOpen,
    );

    final ok = await controller.setEngineeringContextEnabled(enabled: false);
    expect(ok, isTrue);
    expect(
      (await chatRepo.getSession('s1')).engineeringContextEnabled,
      isFalse,
    );
    expect(
      controller.state.engineeringMode,
      EngineeringRuntimeMode.normalClosed,
    );
    final events = await eventRepo.readEvents('s1');
    expect(events.last.type, AgentEventTypes.modeEpoch);
    expect(events.last.data['phase'], kModeEpochPhaseExit);
    // 捕获与纪元事件原样保留（史料不删）
    expect(
      events.any((e) => e.type == AgentEventTypes.modeCapture),
      isTrue,
    );
  });

  test('模式转换在途：第二次切换与新轮发送被拒，旧操作以一致快照提交', () async {
    final session = await seedSession();
    await seedDialogue(rounds: 1);
    final entered = Completer<void>();
    final gate = Completer<void>();
    final store = _PausingSwitchStore(eventRepo, entered, gate);
    final controller = await buildController(session, switchOverride: store);
    addTearDown(controller.dispose);

    final first = controller.setEngineeringContextEnabled(enabled: true);
    await entered.future; // 事务已开启、捕获读取暂停中

    // 期间第二次切换：串行化拒绝，零库写入
    expect(
      await controller.setEngineeringContextEnabled(enabled: false),
      isFalse,
    );
    // 期间新轮发送：同样被拒（转换未结束，无可插入窗口）
    expect(await controller.sendMessage('转换中的消息'), isFalse);

    gate.complete();
    expect(await first, isTrue);
    expect(
      controller.state.engineeringMode,
      EngineeringRuntimeMode.normalOpen,
    );
    // 只有一次进入：pending+complete 各一条（无被拒操作的残留）
    final epochEvents = await eventRepo.readModeEpochEvents('s1');
    expect(epochEvents, hasLength(2));
    expect(epochEvents.first.data['status'], 'pending');
    expect(epochEvents.last.data['status'], 'complete');
    expect(epochEvents.last.data['captureCount'], 2);
  });

  test('普通设置保存在进入事务在途期间不覆回开关（竞态）', () async {
    final session = await seedSession(engineeringEnabled: false);
    await seedDialogue(rounds: 1);
    final entered = Completer<void>();
    final gate = Completer<void>();
    final controller = await buildController(
      session,
      switchOverride: _PausingSwitchStore(eventRepo, entered, gate),
    );
    addTearDown(controller.dispose);

    final entering = controller.setEngineeringContextEnabled(enabled: true);
    await entered.future; // 事务已开启、捕获读取暂停中
    // 期间普通设置保存：带着旧快照（开关=false）的整会话对象
    final saving = controller.updateSession(
      controller.state.session.copyWith(maxSteps: 12),
    );
    gate.complete();
    final results = await Future.wait([entering, saving]);
    // 两个操作都成功：设置保存不被整体拒绝（不能靠禁保存替代正常功能）
    expect(results, [isTrue, isTrue]);
    // 库内开关=开启事务的原子提交值，未被旧快照覆回
    final persisted = await chatRepo.getSession('s1');
    expect(
      persisted.engineeringContextEnabled,
      isTrue,
      reason: 'An unrelated settings save must not undo the atomic mode enter',
    );
    expect(persisted.maxSteps, 12);
    // 生产解析=正常开启（不是 false+完整 enter 的修复态）
    final events = await eventRepo.readEvents('s1');
    expect(
      resolveEngineeringMode(
        enabled: persisted.engineeringContextEnabled,
        events: events,
      ).mode,
      EngineeringRuntimeMode.normalOpen,
    );
    // 控制器内存回填与库一致（回填以库内重读为准）
    expect(controller.state.session.engineeringContextEnabled, isTrue);
    expect(controller.state.session.maxSteps, 12);
  });

  test('切换通道缺失（withSwitch=false）→ 进入失败且零库写入', () async {
    final session = await seedSession();
    await seedDialogue(rounds: 1);
    final controller = await buildController(session, withSwitch: false);

    expect(
      await controller.setEngineeringContextEnabled(enabled: true),
      isFalse,
    );
    expect(
      (await chatRepo.getSession('s1')).engineeringContextEnabled,
      isNull,
    );
    expect(await eventRepo.readModeEpochEvents('s1'), isEmpty);
  });

  test('复制会话不携带开关：副本明确初始化为关闭态', () async {
    final session = await seedSession(engineeringEnabled: false);
    await seedDialogue(rounds: 1);
    final controller = await buildController(session);
    await controller.setEngineeringContextEnabled(enabled: true);

    await chatRepo.copySession('s1', copySuffix: '(副本)');
    final sessions = await chatRepo.getAllSessions();
    final copy = sessions.firstWhere((s) => s.title.contains('(副本)'));
    expect(copy.engineeringContextEnabled, isNull);
  });
}

/// 原子进入通道包装：在事务内的捕获读取前暂停（entered 通知 / gate 放行），
/// 用于构造「转换在途」窗口。
class _PausingSwitchStore implements EngineeringContextSwitchStore {
  _PausingSwitchStore(this._inner, this.entered, this.gate);

  final AgentEventLogRepository _inner;
  final Completer<void> entered;
  final Completer<void> gate;

  @override
  Future<void> applyEngineeringContextEnter({
    required String sessionId,
    required String epochId,
    required int fromTurn,
    required List<AgentDurableEvent> captureEvents,
  }) =>
      _inner.applyEngineeringContextEnter(
        sessionId: sessionId,
        epochId: epochId,
        fromTurn: fromTurn,
        captureEvents: captureEvents,
      );

  @override
  Future<void> applyEngineeringContextEnterAtomic({
    required String sessionId,
    required String epochId,
    required Future<EngineeringEnterCapture> Function() prepare,
  }) =>
      _inner.applyEngineeringContextEnterAtomic(
        sessionId: sessionId,
        epochId: epochId,
        prepare: () async {
          entered.complete();
          await gate.future;
          return prepare();
        },
      );

  @override
  Future<void> applyEngineeringContextExit({
    required String sessionId,
    String? epochId,
  }) =>
      _inner.applyEngineeringContextExit(
        sessionId: sessionId,
        epochId: epochId,
      );
}
