import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/fork_anchor.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/domain/services/compaction_service.dart';
import 'package:lmstory/features/chat/domain/services/compaction_streamer.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/chat/presentation/controllers/chat_mode_controller.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';

import '../../../../test_helpers/stub_failure_log_repository.dart';

/// 压缩收尾窗迟到取消回归：
///
/// onComplete 的多个 await（flushDbWrite/updateMessageTokensUsed/
/// addCompactionPoint/_loadMessages）期间用户仍可按停止。此前流收尾后仅凭
/// `cancelToken.isCancelled` 判取消，会删掉已被压缩点引用的摘要——孤儿
/// 压缩点使 getCompressedMessages 落 summaryUnavailableContent 哨兵，
/// boundary 前全部历史从 API 上下文消失（永久损坏且零提示）。
///
/// 修复后：摘要已完整落库（压缩点已建）的迟到取消按成功收口，不删摘要。
void main() {
  late _CompactionRepo repo;
  late _ScriptedLlmService llmService;
  late StreamController<LlmStreamEvent> events;

  setUp(() {
    repo = _CompactionRepo();
    llmService = _ScriptedLlmService();
    events = StreamController<LlmStreamEvent>();
    llmService.stream = events.stream;
  });

  tearDown(() {
    if (!events.isClosed) unawaited(events.close());
  });

  ChatModeController build() {
    final compaction = CompactionService(
      chatRepository: repo,
      tokenCounter: TokenCounter(),
      settingsRepository: _FakeSettingsRepository(),
      presetRepository: _NoopPresetRepository(),
      streamer: CompactionStreamer(llmService: llmService),
      llmService: llmService,
    );
    return ChatModeController(
      chatRepository: repo,
      presetRepository: _NoopPresetRepository(),
      settingsRepository: _FakeSettingsRepository(),
      compactionService: compaction,
      llmService: llmService,
      logger: const Logger('test'),
      failureLogRepository: const StubFailureLogRepository(),
      session: _session(),
    );
  }

  Future<void> until(bool Function() cond) async {
    for (var i = 0; i < 300 && !cond(); i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(cond(), isTrue, reason: '等待条件超时');
  }

  ChatMessage msg(String id, String role, String content) => ChatMessage(
        messageId: id,
        sessionId: 's1',
        role: role,
        content: content,
        createdAt: DateTime(2026),
      );

  bool summaryDeleted() => repo.deletedMessageIds.any(
        (id) => repo.addMessageCalls.any(
          (m) => m.messageId == id && m.isSummary,
        ),
      );

  test('收尾窗迟到取消（摘要已落库）按成功收口，不删占位摘要', () async {
    repo.messages = [
      msg('u1', 'user', '第一问'),
      msg('a1', 'assistant', '第一答'),
      msg('u2', 'user', '第二问'),
    ];
    final controller = build();
    await until(
      () =>
          !controller.state.isLoading && controller.state.messages.length == 3,
    );

    // 第 3 次 getMessages = onComplete 内 _loadMessages（addCompactionPoint
    // 之后）——在该 await 点注入「用户按停止」。
    repo.onGetMessagesCall = (count) {
      if (count == 3) controller.cancelCompaction();
    };

    final future = controller.compressHistory();
    await until(() => repo.addMessageCalls.any((m) => m.isSummary));
    events
      ..add(const LlmTextDelta('这是摘要'))
      ..add(const LlmStreamDone());
    // await for 要等流关闭才收尾
    await events.close();

    final result = await future;
    expect(result, CompressResult.success, reason: '摘要已完整落库，迟到取消不算取消');
    expect(summaryDeleted(), isFalse, reason: '不得删除已被压缩点引用的摘要');
    expect(repo.compactionPointCalls, hasLength(1), reason: '压缩点恰好建了一个');
  });

  test('流中取消（摘要未落库）仍按取消清理占位', () async {
    repo.messages = [
      msg('u1', 'user', '第一问'),
      msg('a1', 'assistant', '第一答'),
      msg('u2', 'user', '第二问'),
    ];
    final controller = build();
    await until(
      () =>
          !controller.state.isLoading && controller.state.messages.length == 3,
    );

    final future = controller.compressHistory();
    await until(() => repo.addMessageCalls.any((m) => m.isSummary));
    // 流中取消——checkpoint ① 命中，onComplete 不执行
    controller.cancelCompaction();
    events
      ..add(const LlmTextDelta('半截'))
      ..add(const LlmStreamDone());
    await events.close();

    final result = await future;
    expect(result, CompressResult.cancelled);
    expect(repo.compactionPointCalls, isEmpty);
    expect(summaryDeleted(), isTrue, reason: '占位摘要被清理');
  });
}

class _CompactionRepo implements ChatRepository {
  List<ChatMessage> messages = [];
  final List<ChatMessage> addMessageCalls = [];
  final List<String> deletedMessageIds = [];
  final List<Map<String, dynamic>> compactionPointCalls = [];

  /// 每次 getMessages 调用后回调（1 起）——用于在指定 await 点注入副作用。
  void Function(int count)? onGetMessagesCall;
  int _getMessagesCount = 0;

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async {
    _getMessagesCount++;
    final hook = onGetMessagesCall;
    if (hook != null) {
      // 微任务边界注入副作用，保证取消发生在本次 await 完成之后、
      // 后续 await 之前
      scheduleMicrotask(() => hook(_getMessagesCount));
    }
    return messages;
  }

  @override
  Future<ChatMessage> addMessage(ChatMessage message) async {
    addMessageCalls.add(message);
    messages = [...messages, message];
    return message;
  }

  @override
  Future<void> deleteMessage(String messageId) async {
    deletedMessageIds.add(messageId);
  }

  @override
  Future<void> updateMessageContent(String messageId, String content) async {}

  @override
  Future<void> updateMessageTokensUsed(
    String messageId,
    int? tokensUsed,
  ) async {}

  @override
  Future<void> addCompactionPoint({
    required String sessionId,
    required String summaryMessageId,
    required String boundaryMessageId,
    required DateTime createdAt,
  }) async {
    compactionPointCalls.add({
      'summaryMessageId': summaryMessageId,
      'boundaryMessageId': boundaryMessageId,
    });
  }

  @override
  Future<List<Map<String, dynamic>>> getCompactionPoints(String sessionId) =>
      Future.value(const []);

  @override
  Future<ChatSession> getSession(String sessionId) async => _session();

  @override
  Future<List<ForkAnchor>> getForkAnchors(String sessionId) async => [];

  @override
  Future<ChatSession> updateSession(ChatSession session) async => session;

  @override
  Future<void> updateSessionLastActive(String sessionId) async {}

  @override
  Future<void> updateSessionMessageCount(String sessionId, int count) async {}

  @override
  Future<int> getMessageCount(String sessionId) async => messages.length;

  @override
  Future<int> updateMessageError(String messageId, String? error) async =>
      messages.any((m) => m.messageId == messageId) ? 1 : 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _ScriptedLlmService implements LlmService {
  Stream<LlmStreamEvent>? stream;

  @override
  Stream<LlmStreamEvent> streamChat(LlmRequest request) => stream!;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _FakeSettingsRepository implements SettingsRepository {
  @override
  Future<AppConfig> getResolvedConfig() async =>
      const AppConfig(version: 'test', broadcastChat: BroadcastChatConfig());

  @override
  Future<String?> getApiKey(String presetId) async => 'test-key';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _NoopPresetRepository implements ApiPresetRepository {
  @override
  Future<ApiPreset> getPreset(String presetId) async => ApiPreset(
        presetId: presetId,
        name: 'Test Provider',
        baseUrl: 'https://api.test.com/v1',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      );

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

ChatSession _session() => ChatSession(
      sessionId: 's1',
      title: '测试',
      mode: 'simple',
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 0,
      presetId: 'p1',
      modelId: 'm1',
    );
