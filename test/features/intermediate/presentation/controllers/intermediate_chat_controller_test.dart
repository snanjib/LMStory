import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/config/intermediate_config.dart';
import 'package:lmstory/core/llm/llm_usage.dart';
import 'package:lmstory/core/network/http_client.dart';
import 'package:lmstory/core/network/llm_adapters/llm_adapter_factory.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/features/chat/data/datasources/llm_remote_datasource.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_mode.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/story_anchor.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/domain/services/configuration_resolver.dart';
import 'package:lmstory/features/intermediate/domain/entities/intermediate_chat_state.dart';
import 'package:lmstory/features/intermediate/presentation/controllers/intermediate_chat_controller.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/memory/domain/services/embedding_service.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/story_runtime/domain/entities/message_variant_record.dart';
import 'package:lmstory/features/story_runtime/domain/entities/round_artifacts.dart';
import 'package:lmstory/features/story_runtime/domain/services/persistence_service.dart';
import '../../../../test_helpers/stub_failure_log_repository.dart';

/// IntermediateChatController 单元测试
///
/// 验证新增的会话管理逻辑：
/// - isDraftSession：草稿前缀判断
/// - loadHistory：非草稿会话加载消息、草稿会话跳过、异常容错
///
/// 注：sendMessage 完整流程需 HTTP/SSE/Config，属集成测试范畴，此处不覆盖。
/// _materializeDraftSession 为私有方法，通过 loadHistory/isDraftSession 间接验证。

// ── Fake / Stub ─────────────────────────────────────────────────────

class _FakeChatRepository implements ChatRepository {
  _FakeChatRepository({
    this.messages = const [],
    this.throwOnUpdateSession = false,
  });

  final List<ChatMessage> messages;
  final bool throwOnUpdateSession;

  /// 记录 createSession 调用参数
  final List<({String title, String mode, String? modelId, String? presetId})>
      createSessionCalls = [];

  /// 记录 updateSession 调用参数
  final List<ChatSession> updateSessionCalls = [];
  final List<String> getMessagesCalls = [];

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async {
    getMessagesCalls.add(sessionId);
    return messages;
  }

  @override
  Future<ChatSession> createSession({
    required String title,
    String mode = ChatMode.chat,
    String? modelId,
    String? presetId,
  }) async {
    createSessionCalls.add(
      (title: title, mode: mode, modelId: modelId, presetId: presetId),
    );
    return ChatSession(
      sessionId: 'real-${createSessionCalls.length}',
      title: title,
      mode: mode,
      modelId: modelId,
      presetId: presetId,
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 0,
    );
  }

  @override
  Future<ChatSession> updateSession(ChatSession session) async {
    if (throwOnUpdateSession) throw Exception('DB update error');
    updateSessionCalls.add(session);
    return session;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _ThrowingChatRepository implements ChatRepository {
  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async {
    throw Exception('DB error');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubApiPresetRepository implements ApiPresetRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubSettingsRepository implements SettingsRepository {
  /// 默认返回最小 AppConfig（物化时 snapshotIntermediateDefaults 使用默认值）
  @override
  Future<AppConfig> getResolvedConfig() async => const AppConfig(
        version: '0.1',
        broadcastChat: BroadcastChatConfig(),
      );

  /// 默认返回空 overrides（无用户自定义配置）
  @override
  Future<Map<String, dynamic>> getUserOverrides() async => {};

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubHttpClient implements HttpClient {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubExperienceRepository implements ExperienceRepository {
  @override
  Future<List<ExperientialMemory>> searchExperiencesBySubstring(
    String sessionId,
    List<String> terms, {
    int limit = 5,
    bool includeArchived = false,
  }) async =>
      const [];

  @override
  Future<List<ExperientialMemory>> getAllExperiences(
    String sessionId, {
    bool includeArchived = true,
  }) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

/// 返回受控记忆列表的 stub。
///
/// 模拟 getAllExperiences 仅按 turnNumber 排序的真实行为：同轮号并列时
/// 后插入的 macro（无 narrativeTime）排在同轮 micro 之后（rowid 序）。
class _ScriptedExperienceRepository extends _StubExperienceRepository {
  _ScriptedExperienceRepository(this.experiences);

  final List<ExperientialMemory> experiences;

  @override
  Future<List<ExperientialMemory>> getAllExperiences(
    String sessionId, {
    bool includeArchived = true,
  }) async =>
      experiences;
}

class _StubEmbeddingService implements EmbeddingService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubPersistenceService implements StoryPersistenceService {
  _StubPersistenceService({this.throwOnDelete = false});

  /// 是否在 deleteRoundAndDownstream 时抛异常（测试容错）
  final bool throwOnDelete;

  /// 记录 deleteRoundAndDownstream 调用参数
  final List<({String sessionId, int fromTurnNumber, List<String> messageIds})>
      deleteCalls = [];

  @override
  Future<StoryAnchor?> deleteRoundAndDownstream({
    required String sessionId,
    required int fromTurnNumber,
    required List<String> messageIdsToDelete,
    bool keepVariantsAtFromTurn = false,
  }) async {
    if (throwOnDelete) throw Exception('Delete failed');
    deleteCalls.add(
      (
        sessionId: sessionId,
        fromTurnNumber: fromTurnNumber,
        messageIds: messageIdsToDelete,
      ),
    );
    return null;
  }

  /// 返回空 Map（stub 不持久化 artifacts，loadHistory 应正常完成）
  @override
  Future<Map<int, StoryRoundArtifacts>> loadArtifactsBySession(
    String sessionId,
  ) async =>
      const {};

  /// 变体三方法兜底——loadHistory 现第三路并行
  /// 装载变体表，regenerate/editAndResend 前置快照；空实现保既有用例绿。
  @override
  Future<Map<int, List<MessageVariantRecord>>> loadMessageVariants(
    String sessionId,
  ) async =>
      const {};

  @override
  Future<int> snapshotMessageVariant({
    required String sessionId,
    required int turnNumber,
    required String? content,
    String? thinkingContent,
    String? sourceInput,
    StoryRoundArtifacts? process,
  }) async =>
      0;

  @override
  Future<void> deleteMessageVariant({
    required String sessionId,
    required int turnNumber,
    required int variantIndex,
  }) async {}

  /// 撤销压缩脚本（U2，2026-09-04）：非 null 时返回该值并计数
  bool? undoResult;
  int undoCalls = 0;

  @override
  Future<bool> undoCompaction({required String sessionId}) async {
    undoCalls++;
    return undoResult ?? false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

// ── 测试数据 ────────────────────────────────────────────────────────

ChatSession _draftSession() => ChatSession(
      sessionId: '${IntermediateChatController.draftSessionIdPrefix}abc',
      title: '草稿故事',
      mode: 'intermediate',
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 0,
    );

ChatSession _realSession() => ChatSession(
      sessionId: 'real-session-1',
      title: '真实故事',
      mode: 'intermediate',
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 2,
    );

IntermediateChatController _buildController({
  required ChatSession session,
  required ChatRepository chatRepo,
  StoryPersistenceService? persistenceService,
  ExperienceRepository? experienceRepository,
}) {
  return IntermediateChatController(
    chatRepository: chatRepo,
    configurationResolver: ConfigurationResolver(
      presetRepository: _StubApiPresetRepository(),
      settingsRepository: _StubSettingsRepository(),
      logger: const Logger('test'),
    ),
    llmService: LlmRemoteDataSource(
      httpClient: _StubHttpClient(),
      adapterFactory: LlmAdapterFactory(),
    ),
    experienceRepository: experienceRepository ?? _StubExperienceRepository(),
    embeddingService: _StubEmbeddingService(),
    persistenceService: persistenceService ?? _StubPersistenceService(),
    failureLogRepository: const StubFailureLogRepository(),
    tokenCounter: TokenCounter(),
    getConfig: () async => const IntermediateConfig(),
    logger: const Logger('test'),
    session: session,
  );
}

// ── 测试 ────────────────────────────────────────────────────────────

void main() {
  group('IntermediateChatController - isDraftSession', () {
    test('1. 草稿会话（__draft_intermediate_ 前缀）→ true', () {
      final controller = _buildController(
        session: _draftSession(),
        chatRepo: _FakeChatRepository(),
      );
      expect(controller.isDraftSession, isTrue);
    });

    test('2. 真实会话（无草稿前缀）→ false', () {
      final controller = _buildController(
        session: _realSession(),
        chatRepo: _FakeChatRepository(),
      );
      expect(controller.isDraftSession, isFalse);
    });

    test('3. draftSessionIdPrefix 为 __draft_intermediate_', () {
      expect(
        IntermediateChatController.draftSessionIdPrefix,
        '__draft_intermediate_',
      );
    });
  });

  group('IntermediateChatController - loadHistory', () {
    test('4. 草稿会话：跳过加载，不调用 getMessages', () async {
      final chatRepo = _FakeChatRepository(
        messages: [
          ChatMessage(
            messageId: 'm1',
            sessionId: 'real-session-1',
            role: 'user',
            content: '历史消息',
            createdAt: DateTime(2026),
          ),
        ],
      );
      final controller = _buildController(
        session: _draftSession(),
        chatRepo: chatRepo,
      );

      await controller.loadHistory();

      expect(chatRepo.getMessagesCalls, isEmpty);
      expect(controller.state.messages, isEmpty);
    });

    test('5. 真实会话：加载历史消息到 state.messages', () async {
      final historyMessages = [
        ChatMessage(
          messageId: 'm1',
          sessionId: 'real-session-1',
          role: 'user',
          content: '勇者前往后山',
          createdAt: DateTime(2026),
        ),
        ChatMessage(
          messageId: 'm2',
          sessionId: 'real-session-1',
          role: 'assistant',
          content: '勇者穿过密林，发现了一座古碑。',
          createdAt: DateTime(2026, 1, 2),
        ),
      ];
      final chatRepo = _FakeChatRepository(messages: historyMessages);
      final controller = _buildController(
        session: _realSession(),
        chatRepo: chatRepo,
      );

      // 2026-07-22 修复：构造函数已自动调用 loadHistory()，等待完成
      await Future<void>.delayed(Duration.zero);

      expect(chatRepo.getMessagesCalls, ['real-session-1']);
      expect(controller.state.messages.length, 2);
      expect(controller.state.messages.first.content, '勇者前往后山');
    });

    test('6. 真实会话：getMessages 抛异常时不崩溃，messages 保持空', () async {
      final controller = _buildController(
        session: _realSession(),
        chatRepo: _ThrowingChatRepository(),
      );

      await controller.loadHistory();

      expect(controller.state.messages, isEmpty);
    });

    test('7. 生成中（phase!=idle）跳过 reload，不覆盖 state（P2.7 边界修复）', () async {
      // 模拟后台生成中：手动置 phase=drafting，并预设 state.messages
      final existingMessages = [
        ChatMessage(
          messageId: 'streaming-msg',
          sessionId: 'real-session-1',
          role: 'user',
          content: '正在生成的消息',
          createdAt: DateTime(2026),
        ),
      ];
      final chatRepo = _FakeChatRepository(
        messages: [
          ChatMessage(
            messageId: 'old-msg',
            sessionId: 'real-session-1',
            role: 'user',
            content: '数据库里的旧消息',
            createdAt: DateTime(2025),
          ),
        ],
      );
      final controller = _buildController(
        session: _realSession(),
        chatRepo: chatRepo,
      );
      // 2026-07-22 修复：构造函数已自动调用 loadHistory()，等待完成
      await Future<void>.delayed(Duration.zero);
      // 清除构造函数中的调用记录，便于后续断言
      chatRepo.getMessagesCalls.clear();
      // 手动进入生成中状态 + 预设 messages
      controller.state = controller.state.copyWith(
        phase: IntermediatePhase.generating,
        messages: existingMessages,
      );

      await controller.loadHistory();

      // 不调用 getMessages，不覆盖 state
      expect(chatRepo.getMessagesCalls, isEmpty);
      expect(controller.state.phase, IntermediatePhase.generating);
      expect(controller.state.messages, existingMessages);
      expect(controller.state.messages.first.content, '正在生成的消息');
    });
  });

  group('IntermediateChatController - undoCompaction (U2, 2026-09-04)', () {
    test('撤销成功：持久层回剥 + 过滤历史重载，返回 true', () async {
      final historyMessages = [
        ChatMessage(
          messageId: 'm1',
          sessionId: 'real-session-1',
          role: 'user',
          content: '勇者前往后山',
          createdAt: DateTime(2026),
        ),
        ChatMessage(
          messageId: 'm2',
          sessionId: 'real-session-1',
          role: 'assistant',
          content: '勇者穿过密林，发现了一座古碑。',
          createdAt: DateTime(2026, 1, 2),
        ),
      ];
      final chatRepo = _FakeChatRepository(messages: historyMessages);
      final persistence = _StubPersistenceService()..undoResult = true;
      final controller = _buildController(
        session: _realSession(),
        chatRepo: chatRepo,
        persistenceService: persistence,
      );
      await Future<void>.delayed(Duration.zero);

      expect(await controller.undoCompaction(), isTrue);
      expect(persistence.undoCalls, 1);
      // 重载后 state.messages 来自仓库（模拟压缩点回剥后全量可见）
      expect(controller.state.messages.length, 2);
      expect(controller.state.messages.first.messageId, 'm1');
      // 撤销压缩后重载视图同步镜像到
      // session.messageCount（口径同 persist 路径；初始镜像为 0）
      expect(controller.state.session.messageCount, 2);
    });

    test('无压缩点（持久层返回 false）：返回 false，不动 state', () async {
      final chatRepo = _FakeChatRepository();
      final persistence = _StubPersistenceService();
      final controller = _buildController(
        session: _realSession(),
        chatRepo: chatRepo,
        persistenceService: persistence,
      );
      await Future<void>.delayed(Duration.zero);

      expect(await controller.undoCompaction(), isFalse);
      expect(persistence.undoCalls, 1);
      expect(controller.state.messages, isEmpty);
    });
  });

  group('IntermediateChatController - state.session', () {
    test('7. 初始 state.session = 构造函数传入的 session', () {
      final session = _realSession();
      final controller = _buildController(
        session: session,
        chatRepo: _FakeChatRepository(),
      );
      expect(controller.state.session, session);
      expect(controller.state.session.sessionId, 'real-session-1');
    });
  });

  // ──  简化 Fork：canOperateMessage / deleteRound ────────────────

  /// 构造 N 轮对话的消息列表（user_1, assistant_1, ..., user_N, assistant_N）
  List<ChatMessage> buildRoundsMessages(int rounds, String sessionId) {
    final list = <ChatMessage>[];
    for (var r = 1; r <= rounds; r++) {
      list
        ..add(
          ChatMessage(
            messageId: 'u$r',
            sessionId: sessionId,
            role: 'user',
            content: '用户输入$r',
            createdAt: DateTime(2026, 1, r),
          ),
        )
        ..add(
          ChatMessage(
            messageId: 'a$r',
            sessionId: sessionId,
            role: 'assistant',
            content: '助手回复$r',
            createdAt: DateTime(2026, 1, r, 12),
          ),
        );
    }
    return list;
  }

  ChatSession sessionWithRounds(int rounds) => ChatSession(
        sessionId: 'real-session-1',
        title: '测试故事',
        mode: 'intermediate',
        createdAt: DateTime(2026),
        lastActiveAt: DateTime(2026),
        messageCount: rounds * 2,
      );

  group('IntermediateChatController - canOperateMessage (P2.6)', () {
    test('8. 5轮对话 windowRounds=5：第1轮user在窗口边界内 → true', () async {
      final messages = buildRoundsMessages(5, 'real-session-1');
      final controller = _buildController(
        session: sessionWithRounds(5),
        chatRepo: _FakeChatRepository(messages: messages),
      );
      await controller.loadHistory();

      // turn 1, totalRounds=5, window=5 → 1 >= 5-5+1=1 → true
      expect(
        controller.canOperateMessage(
          messages.first,
          windowRounds: 5,
        ),
        isTrue,
      );
    });

    test('9. 6轮对话 windowRounds=5：第1轮user在窗口外 → false', () async {
      final messages = buildRoundsMessages(6, 'real-session-1');
      final controller = _buildController(
        session: sessionWithRounds(6),
        chatRepo: _FakeChatRepository(messages: messages),
      );
      await controller.loadHistory();

      // turn 1, totalRounds=6, window=5 → 1 >= 6-5+1=2 → false
      expect(
        controller.canOperateMessage(
          messages.first,
          windowRounds: 5,
        ),
        isFalse,
      );
    });

    test('10. 6轮对话 windowRounds=5：第2轮user在窗口边界 → true', () async {
      final messages = buildRoundsMessages(6, 'real-session-1');
      final controller = _buildController(
        session: sessionWithRounds(6),
        chatRepo: _FakeChatRepository(messages: messages),
      );
      await controller.loadHistory();

      // messages[2] = u2, turn = (2+2)~/2 = 2, 2 >= 2 → true
      expect(
        controller.canOperateMessage(
          messages[2],
          windowRounds: 5,
        ),
        isTrue,
      );
    });

    test('11. 6轮对话 windowRounds=5：第6轮assistant在窗口内 → true', () async {
      final messages = buildRoundsMessages(6, 'real-session-1');
      final controller = _buildController(
        session: sessionWithRounds(6),
        chatRepo: _FakeChatRepository(messages: messages),
      );
      await controller.loadHistory();

      // messages[11] = a6, turn = (11+1)~/2 = 6, 6 >= 2 → true
      expect(
        controller.canOperateMessage(
          messages[11],
          windowRounds: 5,
        ),
        isTrue,
      );
    });

    test('12. 消息不在 state.messages → false', () async {
      final messages = buildRoundsMessages(3, 'real-session-1');
      final controller = _buildController(
        session: sessionWithRounds(3),
        chatRepo: _FakeChatRepository(messages: messages),
      );
      await controller.loadHistory();

      final orphanMessage = ChatMessage(
        messageId: 'orphan',
        sessionId: 'real-session-1',
        role: 'user',
        content: '不在列表',
        createdAt: DateTime(2026),
      );
      expect(
        controller.canOperateMessage(
          orphanMessage,
          windowRounds: 5,
        ),
        isFalse,
      );
    });
  });

  group('IntermediateChatController - deleteRound (P2.6)', () {
    test('13. user触发删除整轮：删user_N+assistant_N+下游，state正确更新', () async {
      final messages = buildRoundsMessages(6, 'real-session-1');
      final fakePersistence = _StubPersistenceService();
      final controller = _buildController(
        session: sessionWithRounds(6),
        chatRepo: _FakeChatRepository(messages: messages),
        persistenceService: fakePersistence,
      );
      await controller.loadHistory();

      // 删除第5轮 user（messages[8] = u5）
      await controller.deleteRound(messages[8]);

      // 验证 persistenceService 调用
      expect(fakePersistence.deleteCalls.length, 1);
      expect(fakePersistence.deleteCalls.single.sessionId, 'real-session-1');
      expect(fakePersistence.deleteCalls.single.fromTurnNumber, 5);
      expect(
        fakePersistence.deleteCalls.single.messageIds,
        ['u5', 'a5', 'u6', 'a6'],
      );

      // 验证 state：保留前 4 轮（8 条消息）
      expect(controller.state.messages.length, 8);
      expect(controller.state.messages.last.messageId, 'a4');
      expect(controller.state.session.messageCount, 8);
      expect(controller.state.phase, IntermediatePhase.idle);
    });

    test('14. assistant触发删除整轮：回退到user_N开始删除', () async {
      final messages = buildRoundsMessages(6, 'real-session-1');
      final fakePersistence = _StubPersistenceService();
      final controller = _buildController(
        session: sessionWithRounds(6),
        chatRepo: _FakeChatRepository(messages: messages),
        persistenceService: fakePersistence,
      );
      await controller.loadHistory();

      // 删除第5轮 assistant（messages[9] = a5）
      await controller.deleteRound(messages[9]);

      // startIndex = 9-1 = 8（u5 的索引），删除范围同测试 13
      expect(fakePersistence.deleteCalls.single.fromTurnNumber, 5);
      expect(
        fakePersistence.deleteCalls.single.messageIds,
        ['u5', 'a5', 'u6', 'a6'],
      );
      expect(controller.state.messages.length, 8);
      expect(controller.state.session.messageCount, 8);
    });

    test('15. 删除最后一轮：只删user_N+assistant_N', () async {
      final messages = buildRoundsMessages(6, 'real-session-1');
      final fakePersistence = _StubPersistenceService();
      final controller = _buildController(
        session: sessionWithRounds(6),
        chatRepo: _FakeChatRepository(messages: messages),
        persistenceService: fakePersistence,
      );
      await controller.loadHistory();

      // 删除第6轮 user（messages[10] = u6）
      await controller.deleteRound(messages[10]);

      expect(fakePersistence.deleteCalls.single.fromTurnNumber, 6);
      expect(
        fakePersistence.deleteCalls.single.messageIds,
        ['u6', 'a6'],
      );
      expect(controller.state.messages.length, 10);
      expect(controller.state.messages.last.messageId, 'a5');
    });

    test('16. persistenceService抛异常：不崩溃，state不变', () async {
      final messages = buildRoundsMessages(3, 'real-session-1');
      final controller = _buildController(
        session: sessionWithRounds(3),
        chatRepo: _FakeChatRepository(messages: messages),
        persistenceService: _StubPersistenceService(throwOnDelete: true),
      );
      await controller.loadHistory();

      // 删除第2轮 user（messages[2] = u2）
      await controller.deleteRound(messages[2]);

      // 异常被捕获，state.messages 保持不变
      expect(controller.state.messages.length, 6);
      expect(controller.state.session.messageCount, 6);
    });
  });

  group('IntermediateChatController - updateSession (P2.7)', () {
    test('17. 草稿会话：首次修改配置 → 触发物化（createSession + updateSession）', () async {
      final chatRepo = _FakeChatRepository();
      final controller = _buildController(
        session: _draftSession(),
        chatRepo: chatRepo,
      );
      // 草稿会话原始 modelId 为 null
      expect(controller.state.session.modelId, isNull);
      // 草稿会话 sessionId 以 __draft_intermediate_ 前缀
      expect(
        controller.state.session.sessionId,
        startsWith(IntermediateChatController.draftSessionIdPrefix),
      );

      final updated = _draftSession().copyWith(
        modelId: 'new-model',
        presetId: 'new-preset',
      );
      final result = await controller.updateSession(updated);

      expect(result, isTrue);
      // 物化后 sessionId 变为真实 ID（不再以草稿前缀开头）
      expect(
        controller.state.session.sessionId,
        isNot(startsWith(IntermediateChatController.draftSessionIdPrefix)),
      );
      // 物化时 createSession 被调用一次
      expect(chatRepo.createSessionCalls, hasLength(1));
      // 物化时 updateSession 被调用一次（写入快照后的完整配置）
      expect(chatRepo.updateSessionCalls, hasLength(1));
      // 物化后的会话保留了用户修改的 modelId/presetId
      expect(controller.state.session.modelId, 'new-model');
      expect(controller.state.session.presetId, 'new-preset');
      // 物化后会话不再是草稿
      expect(controller.isDraftSession, isFalse);
    });

    test('17b. 草稿物化：jsonModeOverride 从全局快照填充（C2 修复）', () async {
      final chatRepo = _FakeChatRepository();
      final controller = _buildController(
        session: _draftSession(),
        chatRepo: chatRepo,
      );

      // 草稿会话 jsonModeOverride 为 null
      expect(controller.state.session.jsonModeOverride, isNull);

      // 物化时不修改 jsonModeOverride（保持 null，应由全局快照填充）
      final updated = _draftSession().copyWith(
        modelId: 'new-model',
        presetId: 'new-preset',
      );
      await controller.updateSession(updated);

      //  修复验证：jsonModeOverride 应从 snapshot.jsonMode 填充
      // 默认配置 intermediate.stream.tool_calling_enabled = true
      expect(
        controller.state.session.jsonModeOverride,
        isNotNull,
        reason: 'jsonModeOverride 应从全局快照填充，而非保持 null',
      );
      expect(
        controller.state.session.jsonModeOverride,
        true,
        reason: '默认 tool_calling_enabled=true',
      );
    });

    test('17c. 草稿物化：temperature/topP 等字段从全局快照填充', () async {
      final chatRepo = _FakeChatRepository();
      final controller = _buildController(
        session: _draftSession(),
        chatRepo: chatRepo,
      );

      // 草稿会话所有生成参数为 null
      expect(controller.state.session.temperature, isNull);
      expect(controller.state.session.topP, isNull);
      expect(controller.state.session.streamEnabled, isNull);

      final updated = _draftSession().copyWith(
        modelId: 'new-model',
        presetId: 'new-preset',
      );
      await controller.updateSession(updated);

      // 物化后所有字段应从全局快照填充（非 null）
      expect(
        controller.state.session.temperature,
        isNotNull,
        reason: 'temperature 应从全局快照填充',
      );
      expect(controller.state.session.topP, isNotNull, reason: 'topP 应从全局快照填充');
      expect(
        controller.state.session.streamEnabled,
        isNotNull,
        reason: 'streamEnabled 应从全局快照填充',
      );
    });

    test('18. 真实会话 idle：持久化 + state 更新', () async {
      final chatRepo = _FakeChatRepository();
      final controller = _buildController(
        session: _realSession(),
        chatRepo: chatRepo,
      );
      expect(controller.state.session.modelId, isNull);

      final updated = _realSession().copyWith(
        modelId: 'real-model',
        presetId: 'real-preset',
        temperature: 0.5,
      );
      final result = await controller.updateSession(updated);

      expect(result, isTrue);
      expect(controller.state.session.modelId, 'real-model');
      expect(controller.state.session.presetId, 'real-preset');
      expect(controller.state.session.temperature, 0.5);
      // 持久化被调用一次
      expect(chatRepo.updateSessionCalls.length, 1);
      expect(chatRepo.updateSessionCalls.single.modelId, 'real-model');
    });

    test('19. 真实会话 updateSession 抛异常：返回 false，state 不变', () async {
      final chatRepo = _FakeChatRepository(throwOnUpdateSession: true);
      final controller = _buildController(
        session: _realSession(),
        chatRepo: chatRepo,
      );
      final originalModelId = controller.state.session.modelId;

      final updated = _realSession().copyWith(modelId: 'failed-model');
      final result = await controller.updateSession(updated);

      expect(result, isFalse);
      // state 未变更
      expect(controller.state.session.modelId, originalModelId);
    });
  });

  // ── 删除/回滚后叙事时间不被无时间的 macro 冲掉 ──
  group('IntermediateChatController - _rollbackNarrativeTime', () {
    ExperientialMemory memory({
      required String id,
      required int turn,
      String? narrativeTime,
      MemoryLevel level = MemoryLevel.micro,
    }) {
      return ExperientialMemory(
        memoryId: id,
        sessionId: 'real-session-1',
        summary: '记忆$id',
        importance: 3,
        tags: const [],
        turnNumber: turn,
        createdAt: DateTime(2026, 1, turn),
        narrativeTime: narrativeTime,
        memoryLevel: level,
      );
    }

    test('20. 同轮 macro（无 narrativeTime）排在末位：叙事时间取最后一条有时间的记忆', () async {
      // 场景：手动压缩在最后一轮 micro 之后插入同轮号 macro（无叙事时间）；
      // 用户删除压缩点之后的更新轮次 → macro 幸存并排在 getAllExperiences
      // 末位。修复前 .last 命中 macro → currentNarrativeTime 被清空。
      final messages = buildRoundsMessages(6, 'real-session-1');
      final chatRepo = _FakeChatRepository(messages: messages);
      final experienceRepo = _ScriptedExperienceRepository([
        memory(id: 'micro-9', turn: 9, narrativeTime: '第二天黄昏'),
        memory(id: 'micro-10', turn: 10, narrativeTime: '第三天夜里'),
        // 手动压缩 macro：同轮号、后插入、无 narrativeTime
        memory(id: 'macro-10', turn: 10, level: MemoryLevel.macro),
      ]);
      final controller = _buildController(
        session: sessionWithRounds(6),
        chatRepo: chatRepo,
        experienceRepository: experienceRepo,
      );
      await controller.loadHistory();

      // 删除第 6 轮（压缩点之后）→ 触发 _rollbackNarrativeTime
      await controller.deleteRound(messages[10]);

      expect(controller.state.session.currentNarrativeTime, '第三天夜里');
      expect(chatRepo.updateSessionCalls, isNotEmpty);
      expect(
        chatRepo.updateSessionCalls.last.currentNarrativeTime,
        '第三天夜里',
        reason: '回写库的叙事时间也不得被 macro 清空',
      );
    });

    test('21. 全部记忆无 narrativeTime：重置 null（既有语义保留）', () async {
      final messages = buildRoundsMessages(2, 'real-session-1');
      final chatRepo = _FakeChatRepository(messages: messages);
      final experienceRepo = _ScriptedExperienceRepository([
        memory(id: 'micro-1', turn: 1),
        memory(id: 'micro-2', turn: 2),
      ]);
      final controller = _buildController(
        session: sessionWithRounds(2),
        chatRepo: chatRepo,
        experienceRepository: experienceRepo,
      );
      await controller.loadHistory();

      await controller.deleteRound(messages[2]);

      expect(controller.state.session.currentNarrativeTime, isNull);
    });
  });

  group('IntermediateChatController - 上下文用量估算兜底（端点未回 usage）', () {
    test('端点真实 usage：分项落 state、估算标记 false、命中率累计累加', () async {
      final controller = _buildController(
        session: _realSession(),
        chatRepo: _FakeChatRepository(),
      );
      await controller.recordRequestUsageForTest(
        const LlmUsage(
          promptTokens: 100,
          completionTokens: 20,
          cacheReadTokens: 60,
        ),
      );

      expect(controller.state.lastPromptTokens, 100);
      expect(controller.state.lastCompletionTokens, 20);
      expect(controller.state.lastCacheReadTokens, 60);
      expect(controller.state.lastUsageIsEstimated, isFalse);
      expect(controller.state.contextPromptTokensTotal, 100);
      expect(controller.state.contextCacheReadTokensTotal, 60);
    });

    test('端点未回 usage：本地估算 prompt/completion，缓存清 null，命中率累计不动', () async {
      final controller = _buildController(
        session: _realSession(),
        chatRepo: _FakeChatRepository(),
      );
      await controller.recordRequestUsageForTest(
        null,
        promptTexts: [
          '系统提示词：你是一名叙事引擎。',
          '用户：主角推门进入北境的暴风雪。',
        ],
        completionText: '门在风中呻吟着合上了，火把的光摇曳不定。',
      );

      expect(controller.state.lastPromptTokens, greaterThan(0));
      expect(controller.state.lastCompletionTokens, greaterThan(0));
      // 缓存分项本地不可估算：显式清 null（面板「—」）
      expect(controller.state.lastCacheReadTokens, isNull);
      expect(controller.state.lastUsageIsEstimated, isTrue);
      // 命中率口径只吃端点真实数据
      expect(controller.state.contextPromptTokensTotal, 0);
      expect(controller.state.contextCacheReadTokensTotal, 0);
    });

    test('估算轮覆盖上一轮真实缓存分项（口径不混排）；无可估来源保持现状', () async {
      final controller = _buildController(
        session: _realSession(),
        chatRepo: _FakeChatRepository(),
      );
      await controller.recordRequestUsageForTest(
        const LlmUsage(promptTokens: 500, cacheReadTokens: 300),
      );
      // 下一轮端点没回 usage：估算值不得与上一轮真实缓存分项混排
      await controller.recordRequestUsageForTest(null, completionText: '新的一轮输出');

      expect(controller.state.lastUsageIsEstimated, isTrue);
      expect(controller.state.lastPromptTokens, isNull);
      expect(controller.state.lastCacheReadTokens, isNull);

      // payload 与正文都缺失（流异常截断）：state 原样不动
      final before = controller.state;
      await controller.recordRequestUsageForTest(null);
      expect(identical(before, controller.state), isTrue);
    });
  });
}
