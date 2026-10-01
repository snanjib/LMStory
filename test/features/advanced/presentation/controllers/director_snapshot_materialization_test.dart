import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/advanced_config.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/features/advanced/domain/entities/retrieval_profile.dart';
import 'package:lmstory/features/advanced/presentation/controllers/advanced_chat_controller.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/services/embedding_service.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/story_runtime/domain/services/persistence_service.dart';

import '../../../../test_helpers/stub_failure_log_repository.dart';

/// 导演会话配置项全量快照化验收。
///
/// 快照宪法三条：
/// 1. 新建（草稿物化）后改全局值，旧会话不变；
/// 2. 重置 = 复制按下那一刻的全局值（sheet 侧 chip 路径在
///    director_session_settings_sheet_test 覆盖）；
/// 3. 任何非 carve-out 字段无 null 态——存量 null 会话打开即物化。
void main() {
  late _MemoryChatRepository chatRepo;
  late _MutableConfigSettingsRepository settingsRepo;

  setUp(() {
    chatRepo = _MemoryChatRepository();
    settingsRepo = _MutableConfigSettingsRepository();
  });

  AdvancedChatController buildController(ChatSession session) {
    return AdvancedChatController(
      chatRepository: chatRepo,
      configurationResolver: ConfigurationResolver(
        presetRepository: _NoopPresetRepository(),
        settingsRepository: settingsRepo,
        logger: const Logger('test'),
      ),
      llmService: _NoopLlmService(),
      experienceRepository: _NoopExperienceRepository(),
      embeddingService: _NoopEmbeddingService(),
      persistenceService: _NoopPersistenceService(),
      failureLogRepository: const StubFailureLogRepository(),
      tokenCounter: TokenCounter(),
      getConfig: () async => settingsRepo.advanced,
      logger: const Logger('test'),
      session: session,
    );
  }

  ChatSession legacySession() => ChatSession(
        sessionId: 'legacy-1',
        title: '存量导演会话',
        mode: 'advanced',
        createdAt: DateTime(2026),
        lastActiveAt: DateTime(2026),
        messageCount: 0,
        // 全部配置列 NULL（快照化之前建立的会话形态）
      );

  group('D4：存量会话惰性物化', () {
    test('打开即物化：全列复制全局快照，非 carve-out 字段无 null 态', () async {
      settingsRepo.advanced = const AdvancedConfig(
        generation: GenerationConfig(temperature: 0.9),
        defaults: AdvancedDefaultsConfig(maxSteps: 12),
        narrativePacing: 'aggressive',
      );
      final controller = buildController(legacySession());
      // 构造已触发 loadHistory（fire-and-forget）——等待物化落定，
      // 不再显式调第二次（双跑竞态会双写）
      for (var i = 0;
          i < 100 && controller.state.session.maxSteps == null;
          i++) {
        await Future<void>.delayed(Duration.zero);
      }

      final session = controller.state.session;
      // 生成参数族
      expect(session.temperature, 0.9);
      expect(session.topP, isNotNull);
      expect(session.maxTokens, isNotNull);
      expect(session.presencePenalty, isNotNull);
      expect(session.frequencyPenalty, isNotNull);
      expect(session.streamEnabled, isNotNull);
      expect(session.systemPromptOverride, isNotNull, reason: '空串=「无规则」具体态');
      // 运行族
      expect(session.maxSteps, 12);
      expect(session.maxDurationMinutes, isNotNull);
      expect(session.narrativePacing, 'aggressive');
      expect(session.toolPermissions, isNotNull);
      expect(session.retrievalOverrides, RetrievalProfile.balanced.encode());
      expect(session.compactionTriggerRatioOverride, isNotNull);
      // 写回持久化（一次性）
      expect(chatRepo.updateCalls, hasLength(1));
    });

    test('物化后改全局重开：会话值保持旧快照不变（不跟随漂移）', () async {
      settingsRepo.advanced = const AdvancedConfig(
        generation: GenerationConfig(temperature: 0.9),
      );
      final first = buildController(legacySession());
      for (var i = 0; i < 100 && first.state.session.temperature == null; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(first.state.session.temperature, 0.9);

      // 全局改成 1.5——存量会话不得跟随
      settingsRepo.advanced = const AdvancedConfig(
        generation: GenerationConfig(temperature: 1.5),
      );
      final persisted = chatRepo.sessions['legacy-1']!;
      final second = buildController(persisted);
      for (var i = 0; i < 100 && second.state.loadingHistory; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(second.state.session.temperature, 0.9, reason: '快照会话不受后续全局修改影响');
      expect(chatRepo.updateCalls, hasLength(1), reason: '已物化会话重开零写入');
    });

    test('故事模式会话不经导演物化（共享表隔离）', () async {
      final storySession = ChatSession(
        sessionId: 'story-1',
        title: '故事会话',
        mode: 'intermediate',
        createdAt: DateTime(2026),
        lastActiveAt: DateTime(2026),
        messageCount: 0,
      );
      final controller = buildController(storySession);
      for (var i = 0; i < 100 && controller.state.loadingHistory; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(chatRepo.updateCalls, isEmpty, reason: '导演惰性物化仅处理 mode=advanced');
    });

    test('carve-out：reasoningEffort 不物化（null=模型自行决定的具体状态）', () async {
      final controller = buildController(legacySession());
      for (var i = 0;
          i < 100 && controller.state.session.maxSteps == null;
          i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(
        controller.state.session.reasoningEffort,
        isNull,
        reason: 'carve-out 字段不在物化范围（模型语义非跟随）',
      );
    });
  });

  group('D4：新建草稿物化补齐', () {
    test('草稿物化后全部配置列有值（含新补五列）', () async {
      settingsRepo.advanced = const AdvancedConfig(
        defaults: AdvancedDefaultsConfig(maxSteps: 6),
      );
      final draft = ChatSession(
        sessionId: '${AdvancedChatController.draftSessionIdPrefix}x',
        title: '新会话',
        mode: 'advanced',
        createdAt: DateTime(2026),
        lastActiveAt: DateTime(2026),
        messageCount: 0,
      );
      final controller = buildController(draft);
      // 草稿保存设置 → 物化为真实会话
      await controller.updateSession(draft.copyWith(temperature: 1.2));

      final session = controller.state.session;
      expect(session.sessionId, isNot(startsWith('__draft')));
      expect(session.temperature, 1.2, reason: '草稿值优先于快照');
      expect(session.maxSteps, 6, reason: 'D4 新补：maxSteps 物化');
      expect(session.maxDurationMinutes, isNotNull, reason: 'D4 新补');
      expect(session.narrativePacing, isNotNull, reason: 'D4 新补');
      expect(session.toolPermissions, isNotNull, reason: 'D4 新补');
      expect(
        session.retrievalOverrides,
        RetrievalProfile.balanced.encode(),
        reason: 'D4 新补：平衡档具体快照',
      );
    });
  });
}

class _MemoryChatRepository implements ChatRepository {
  final Map<String, ChatSession> sessions = {};
  final List<ChatSession> updateCalls = [];

  @override
  Future<ChatSession> getSession(String sessionId) async =>
      sessions[sessionId] ??
      ChatSession(
        sessionId: sessionId,
        title: '未知',
        mode: 'advanced',
        createdAt: DateTime(2026),
        lastActiveAt: DateTime(2026),
        messageCount: 0,
      );

  @override
  Future<ChatSession> createSession({
    required String title,
    String mode = 'advanced',
    String? modelId,
    String? presetId,
  }) async {
    final session = ChatSession(
      sessionId: 'real-$title-$mode',
      title: title,
      mode: mode,
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 0,
    );
    sessions[session.sessionId] = session;
    return session;
  }

  @override
  Future<ChatSession> updateSession(ChatSession session) async {
    updateCalls.add(session);
    sessions[session.sessionId] = session;
    return session;
  }

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

/// 可变全局配置 stub：快照语义测试的核心——同一测试内改全局值
class _MutableConfigSettingsRepository implements SettingsRepository {
  AdvancedConfig advanced = const AdvancedConfig();

  @override
  Future<AppConfig> getResolvedConfig() async => AppConfig(
        version: 'test',
        broadcastChat: const BroadcastChatConfig(),
        advanced: advanced,
      );

  @override
  Future<String?> getApiKey(String presetId) async => 'test-key';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _NoopPresetRepository implements ApiPresetRepository {
  @override
  Future<List<ApiPreset>> getAllPresets() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _NoopLlmService implements LlmService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _NoopExperienceRepository implements ExperienceRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _NoopEmbeddingService implements EmbeddingService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _NoopPersistenceService implements StoryPersistenceService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}
