import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/intermediate/domain/entities/intermediate_chat_state.dart';
import 'package:lmstory/features/memory/domain/entities/event_summary.dart';

/// IntermediateChatState 单元测试（计划 §6.2 +  session 字段）
///
/// 验证：
/// - 初始状态字段（含 session）
/// - copyWith sentinel 区分"未提供"与"显式 null"
/// - copyWith 保留/更新 session
/// - clearTemporary 清理临时字段但保留 messages/userInput/session
ChatSession _testSession({
  String sessionId = 'session-1',
  String mode = 'intermediate',
}) =>
    ChatSession(
      sessionId: sessionId,
      title: '测试故事',
      mode: mode,
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 0,
    );

void main() {
  group('IntermediateChatState', () {
    test('1. initial：phase=idle，临时字段全 null，messages 空，session 保留', () {
      final session = _testSession();
      final state = IntermediateChatState.initial(session);

      expect(state.phase, IntermediatePhase.idle);
      expect(state.messages, isEmpty);
      expect(state.retryCounts, isEmpty);
      expect(state.streamingGenerated, isNull);
      expect(state.extractedKeywords, isNull);
      expect(state.retrievedMemories, isNull);
      expect(state.streamingReply, isNull);
      expect(state.currentEventSummary, isNull);
      expect(state.failureContext, isNull);
      expect(state.userInput, isNull);
      expect(state.generatedText, isNull);
      expect(state.pendingUserMessage, isNull); // Stage 3：默认 null
      expect(state.session, session);
    });

    test('2. copyWith：sentinel 区分"未提供"与"显式 null"', () {
      final session = _testSession();
      // 先填充一个非 idle 状态，带若干临时字段
      final state = IntermediateChatState(
        phase: IntermediatePhase.reviewing,
        messages: [],
        retryCounts: {},
        session: session,
        streamingGenerated: '草稿内容',
        extractedKeywords: ['关键词'],
        streamingReply: '回复内容',
        userInput: '用户输入',
      );

      // 不传 streamingGenerated → 保留原值
      final kept = state.copyWith(phase: IntermediatePhase.persisting);
      expect(kept.streamingGenerated, '草稿内容');
      expect(kept.extractedKeywords, ['关键词']);
      expect(kept.streamingReply, '回复内容');
      expect(kept.userInput, '用户输入');
      expect(kept.phase, IntermediatePhase.persisting);
      // session 也保留
      expect(kept.session, session);

      // 显式传 null → 清空（sentinel 生效）
      final cleared = state.copyWith(
        streamingGenerated: null,
        extractedKeywords: null,
        streamingReply: null,
      );
      expect(cleared.streamingGenerated, isNull);
      expect(cleared.extractedKeywords, isNull);
      expect(cleared.streamingReply, isNull);
      // 未传的 userInput 仍保留
      expect(cleared.userInput, '用户输入');
      // 未传的 phase 也保留
      expect(cleared.phase, IntermediatePhase.reviewing);
    });

    test('3. copyWith：session 可更新（草稿物化场景）', () {
      final draftSession = _testSession(sessionId: '__draft_intermediate_x');
      final realSession = _testSession(sessionId: 'real-session-1');

      final state = IntermediateChatState.initial(draftSession);
      final updated = state.copyWith(session: realSession);

      expect(updated.session, realSession);
      expect(updated.session.sessionId, 'real-session-1');
      // 其他字段不变
      expect(updated.phase, IntermediatePhase.idle);
    });

    test('4. clearTemporary：清理临时字段，保留 messages/userInput/session', () {
      final session = _testSession();
      final state = IntermediateChatState(
        phase: IntermediatePhase.failed,
        messages: [],
        retryCounts: {},
        session: session,
        streamingGenerated: '草稿',
        extractedKeywords: ['kw'],
        streamingReply: '半截回复',
        currentEventSummary: const EventSummary(
          summary: '事件',
          importance: 3,
          tags: ['tag'],
          turnNumber: 1,
        ),
        failureContext: const FailureContext(
          errorCode: 'E014',
          failedPhase: IntermediatePhase.reviewing,
          errorMessage: '审查失败',
          retryable: true,
        ),
        userInput: '用户输入',
        generatedText: '草稿全文',
      );

      final cleared = state.clearTemporary();

      // phase 回到 idle
      expect(cleared.phase, IntermediatePhase.idle);
      // 临时字段全部清空
      expect(cleared.streamingGenerated, isNull);
      expect(cleared.extractedKeywords, isNull);
      expect(cleared.retrievedMemories, isNull);
      expect(cleared.streamingReply, isNull);
      expect(cleared.currentEventSummary, isNull);
      expect(cleared.failureContext, isNull);
      expect(cleared.generatedText, isNull);
      // messages、userInput、session 保留
      expect(cleared.messages, isEmpty);
      expect(cleared.userInput, '用户输入');
      expect(cleared.session, session);
    });

    // ── Stage 3：pendingUserMessage 行为验证 ──────────────────────────

    test('5. pendingUserMessage：copyWith sentinel 保留原值，显式 null 清空', () {
      final session = _testSession();
      final userMsg = ChatMessage(
        messageId: 'msg-1',
        sessionId: session.sessionId,
        role: 'user',
        content: 'hello',
        createdAt: DateTime(2026),
      );
      final state = IntermediateChatState(
        phase: IntermediatePhase.generating,
        messages: const [],
        retryCounts: const {},
        session: session,
        pendingUserMessage: userMsg,
      );

      // 不传 pendingUserMessage → 保留原值（sentinel 生效）
      final kept = state.copyWith(phase: IntermediatePhase.reviewing);
      expect(kept.pendingUserMessage, same(userMsg));
      expect(kept.phase, IntermediatePhase.reviewing);

      // 显式传 null → 清空（sentinel 区分）
      final cleared = state.copyWith(pendingUserMessage: null);
      expect(cleared.pendingUserMessage, isNull);
      // 其他字段保留
      expect(cleared.phase, IntermediatePhase.generating);
    });

    test('6. clearTemporary：保留 pendingUserMessage（失败时保留用户消息显示）', () {
      final session = _testSession();
      final userMsg = ChatMessage(
        messageId: 'msg-1',
        sessionId: session.sessionId,
        role: 'user',
        content: '我发送的消息',
        createdAt: DateTime(2026),
      );
      final state = IntermediateChatState(
        phase: IntermediatePhase.failed,
        messages: const [],
        retryCounts: const {},
        session: session,
        streamingGenerated: '半截草稿',
        userInput: '我发送的消息',
        pendingUserMessage: userMsg,
      );

      final cleared = state.clearTemporary();

      // phase 回 idle，临时字段清空
      expect(cleared.phase, IntermediatePhase.idle);
      expect(cleared.streamingGenerated, isNull);
      // Stage 3：pendingUserMessage 保留（对齐 DOC-09A-2 §6.5"失败时 UI 保留用户消息显示"）
      expect(cleared.pendingUserMessage, same(userMsg));
      expect(cleared.pendingUserMessage?.content, '我发送的消息');
      // userInput 也保留
      expect(cleared.userInput, '我发送的消息');
    });

    test('缓存命中率：分母为累计完整输入（非 prompt+cache 相加）', () {
      final state = IntermediateChatState(
        phase: IntermediatePhase.idle,
        messages: const [],
        retryCounts: const {},
        session: _testSession(),
        contextPromptTokensTotal: 200,
        contextCacheReadTokensTotal: 800,
        contextInputTokensTotal: 1000,
      );

      expect(state.averageCacheHit, 0.8);
    });

    test('缓存命中率：旧累计缺完整输入面 → null（不得当 0 命中）', () {
      final state = IntermediateChatState(
        phase: IntermediatePhase.idle,
        messages: const [],
        retryCounts: const {},
        session: _testSession(),
        contextPromptTokensTotal: 200,
        contextCacheReadTokensTotal: 800,
      );

      expect(state.averageCacheHit, isNull);
    });
  });

  // ── ：ErrorCategory + FailureContext 扩展 ──────────────────────

  group('ErrorCategory', () {
    test('5. 枚举完整性：11 个值按预期顺序', () {
      // 验证 ErrorCategory 枚举值数量和顺序（DOC-09B §9 扩展；
      //  新增 contextOverflow 置于 format 之后、persist 之前；
      //  新增 request 置于 server 之后，表示 400 请求被拒的确定性错误）
      expect(ErrorCategory.values.length, 11);
      expect(ErrorCategory.values, <ErrorCategory>[
        ErrorCategory.config,
        ErrorCategory.network,
        ErrorCategory.auth,
        ErrorCategory.rateLimit,
        ErrorCategory.server,
        ErrorCategory.request,
        ErrorCategory.timeout,
        ErrorCategory.format,
        ErrorCategory.contextOverflow,
        ErrorCategory.persist,
        ErrorCategory.unknown,
      ]);
    });
  });

  group('FailureContext', () {
    test('6. 默认值：errorCategory=unknown，httpStatus=null，rawError=null', () {
      // 仅传原有 4 个必填字段，新字段应取默认值（向后兼容）
      const ctx = FailureContext(
        errorCode: 'E014',
        failedPhase: IntermediatePhase.reviewing,
        errorMessage: '审查失败',
        retryable: true,
      );

      //  新字段默认值
      expect(ctx.errorCategory, ErrorCategory.unknown);
      expect(ctx.httpStatus, isNull);
      expect(ctx.rawError, isNull);
      // 原有字段保持
      expect(ctx.errorCode, 'E014');
      expect(ctx.failedPhase, IntermediatePhase.reviewing);
      expect(ctx.errorMessage, '审查失败');
      expect(ctx.retryable, isTrue);
    });

    test('7. 全字段构造：errorCategory + httpStatus + rawError', () {
      const ctx = FailureContext(
        errorCode: 'E010',
        failedPhase: IntermediatePhase.generating,
        errorMessage: '网络连接失败',
        retryable: true,
        errorCategory: ErrorCategory.network,
        httpStatus: 503,
        rawError: 'SocketException: Connection failed',
      );

      expect(ctx.errorCategory, ErrorCategory.network);
      expect(ctx.httpStatus, 503);
      expect(ctx.rawError, 'SocketException: Connection failed');
      // 原有字段也正确
      expect(ctx.errorCode, 'E010');
      expect(ctx.failedPhase, IntermediatePhase.generating);
    });
  });
}
