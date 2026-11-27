import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_loader.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/theme/system/structures/classic/conversation/simple_message_bubble.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/core/utils/token_counter.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/entities/fork_anchor.dart';
import 'package:lmstory/features/chat/domain/entities/search_result.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/domain/services/compaction_service.dart';
import 'package:lmstory/features/chat/domain/services/compaction_streamer.dart';
import 'package:lmstory/features/chat/domain/services/llm_service.dart';
import 'package:lmstory/features/chat/presentation/controllers/chat_mode_controller.dart';
import 'package:lmstory/features/chat/presentation/pages/chat/chat_mode_page.dart';
import 'package:lmstory/features/chat/presentation/widgets/in_session_search_bar.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';

import '../../../../test_helpers/stub_failure_log_repository.dart';

/// ChatModePage 会话内搜索页面级集成测试
///
/// 批 K 的仓库/组件层测试绿，但页面接线层零覆盖——/2/3 全部落在这层：
/// 1. 长会话定位：命中视口外消息必须真的滚动过去（估算定位兜底）
/// 2. 无结果按 Enter 不得对 0 取模抛异常
/// 3. Enter/Shift+Enter 键盘导航与环绕语义
/// 4. 同型页面原地复用切换会话时搜索态归零、防抖取消
/// 5. Ctrl+F / Cmd+F 双变体呼出
/// 6. 请求序号守卫：过期慢响应不回写（对照全局搜索）
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  final sessionA = ChatSession(
    sessionId: 'search-a',
    title: '搜索会话A',
    mode: 'chat',
    createdAt: DateTime(2026),
    lastActiveAt: DateTime(2026),
    messageCount: 0,
    presetId: 'p1',
    modelId: 'm1',
  );
  final sessionB = ChatSession(
    sessionId: 'search-b',
    title: '搜索会话B',
    mode: 'chat',
    createdAt: DateTime(2026),
    lastActiveAt: DateTime(2026),
    messageCount: 0,
    presetId: 'p1',
    modelId: 'm1',
  );

  late _SearchableChatRepository repo;

  setUp(() {
    repo = _SearchableChatRepository();
    // A：12 轮长会话（撑出可滚动高度）；首轮用户消息带唯一词「雪夜独行」
    for (var i = 0; i < 12; i++) {
      final unique = i == 0 ? '雪夜独行 ' : '';
      repo.seed(sessionA.sessionId, [
        ChatMessage(
          messageId: 'a-u$i',
          sessionId: 'search-a',
          role: 'user',
          content: '$unique用户输入 第$i 轮：${'这是一段较长的用户输入内容。' * 6}',
          createdAt: DateTime(2026, 1, 1, 1, i),
        ),
        ChatMessage(
          messageId: 'a-s$i',
          sessionId: 'search-a',
          role: 'assistant',
          content: '助手回复 第$i 轮：${'这是一段较长的助手回复正文内容。' * 6}',
          createdAt: DateTime(2026, 1, 1, 1, i, 30),
        ),
      ]);
    }
    // B：2 轮普通会话（无「雪夜独行」）
    for (var i = 0; i < 2; i++) {
      repo.seed(sessionB.sessionId, [
        ChatMessage(
          messageId: 'b-u$i',
          sessionId: 'search-b',
          role: 'user',
          content: '会话B用户输入 第$i 轮：${'这是另一段内容。' * 6}',
          createdAt: DateTime(2026, 1, 1, 1, i),
        ),
      ]);
    }
  });

  Future<void> pumpPage(
    WidgetTester tester,
    ChatSession session, {
    String? focusMessageId,
  }) async {
    final c = ProviderContainer(
      overrides: [
        chatRepositoryProvider.overrideWithValue(repo),
        chatModeControllerProvider(sessionA).overrideWith((ref) {
          return _controllerFor(repo, sessionA);
        }),
        chatModeControllerProvider(sessionB).overrideWith((ref) {
          return _controllerFor(repo, sessionB);
        }),
        settingsRepositoryProvider.overrideWithValue(
          _FakeSettingsRepository(),
        ),
        apiPresetRepositoryProvider.overrideWithValue(
          _NoopPresetRepository(),
        ),
        templateRepositoryProvider.overrideWithValue(
          _NoopTemplateRepository(),
        ),
      ],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: TranslationProvider(
          child: MaterialApp(
            home: SizedBox(
              width: 800,
              height: 600,
              // 无 key：复刻生产桌面端同型页面原地复用（State 不随会话重建，
              //  的跨会话泄漏正是在 didUpdateWidget 路径上）
              child: ChatModePage(
                session: session,
                initialFocusMessageId: focusMessageId,
              ),
            ),
          ),
        ),
      ),
    );
    // 等待消息加载 + 首帧对齐（定时 pump：页面存在常驻动画，禁 pumpAndSettle）
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// 通过 AppBar 菜单打开会话内搜索（页面入口之一，比合成按键稳定）
  Future<void> openSearchViaMenu(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.chat.inSessionSearch.menuTitle));
    await tester.pump(const Duration(milliseconds: 250));
  }

  /// 消息列表的主 Scrollable（气泡内可能有嵌套滚动体，取第一个）
  final primaryScrollableFinder = find
      .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
      .first;

  ScrollPosition positionOf(WidgetTester tester) =>
      tester.state<ScrollableState>(primaryScrollableFinder).position;

  /// 搜索条的可见性以其占位文案为准（页面底部还有输入框 TextField，
  /// 不能用 byType(TextField) 判定）
  Finder searchBarFinder() => find.text(t.chat.inSessionSearch.placeholder);

  /// 搜索条内的输入框（页面底部聊天输入框也是 TextField，须限定祖先）
  Finder searchFieldFinder() => find.descendant(
        of: find.byType(InSessionSearchBar),
        matching: find.byType(TextField),
      );

  Future<void> flushTimers(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
  }

  testWidgets('无结果态按 Enter 不抛取模异常', (tester) async {
    await pumpPage(tester, sessionA);
    await openSearchViaMenu(tester);

    await tester.enterText(searchFieldFinder(), '不存在的词');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text(t.chat.inSessionSearch.noResults), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester.takeException(),
      isNull,
      reason: '空命中列表按 Enter 曾对 0 取模抛 IntegerDivisionByZeroException',
    );
    await flushTimers(tester);
  });

  testWidgets('长会话命中视口外消息须滚动定位并显示 1/1', (tester) async {
    await pumpPage(tester, sessionA);
    final position = positionOf(tester);
    expect(position.maxScrollExtent, greaterThan(0));
    expect(
      position.pixels,
      closeTo(position.maxScrollExtent, 8),
      reason: '前置：打开时贴底（最旧命中在视口外）',
    );

    // Ctrl+F 呼出（control 变体真实路径）
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.enterText(searchFieldFinder(), '雪夜独行');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('1/1'), findsOneWidget);
    expect(
      position.pixels,
      lessThan(position.maxScrollExtent / 2),
      reason: '命中首轮（最旧）消息必须真的滚出底部——旧路径 '
          '_scrollToMessage 对未构建消息静默 return，此断言失败',
    );
    await flushTimers(tester);
  });

  testWidgets('Enter/Shift+Enter 键盘导航与首尾环绕', (tester) async {
    await pumpPage(tester, sessionA);
    await openSearchViaMenu(tester);

    // 「用户输入」仅命中 12 条用户消息（助手回复不含该词）
    await tester.enterText(searchFieldFinder(), '用户输入');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('1/12'), findsOneWidget, reason: '搜索完成即定位第一条（升序=最旧）');

    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('2/12'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('1/12'), findsOneWidget);

    // 首条再 Shift+Enter：环绕到末条（旧实现错跳 len-2=10/12）
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.text('12/12'),
      findsOneWidget,
      reason: '尚未定位/位于首条时 Prev 应语义化落到末条',
    );
    expect(tester.takeException(), isNull);
    await flushTimers(tester);
  });

  testWidgets('同型页面复用切换会话，搜索态与防抖一并重置', (tester) async {
    await pumpPage(tester, sessionA);
    await openSearchViaMenu(tester);

    // 输入后立即（防抖 300ms 内）切到会话 B：防抖必须被取消
    await tester.enterText(searchFieldFinder(), '雪夜独行');
    await tester.pump(const Duration(milliseconds: 50));
    repo.searchCalls.clear();

    // 同一树位换入会话 B 的页面（同型无 key→State 复用→didUpdateWidget）
    await pumpPage(tester, sessionB);
    await tester.pump(const Duration(milliseconds: 400));

    expect(searchBarFinder(), findsNothing, reason: '切会话后搜索条不得残留 A 的查询');
    expect(
      repo.searchCalls.where((c) => c.$1 == sessionB.sessionId),
      isEmpty,
      reason: 'A 的挂起防抖不得以 A 的查询在 B 会话上执行',
    );

    // 结果态也不得残留：先在 A 搜出结果再切换
    await pumpPage(tester, sessionA);
    await openSearchViaMenu(tester);
    await tester.enterText(searchFieldFinder(), '雪夜独行');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('1/1'), findsOneWidget, reason: '前置：A 中已有命中');

    await pumpPage(tester, sessionB);
    await tester.pump(const Duration(milliseconds: 100));
    expect(searchBarFinder(), findsNothing, reason: '已出的结果态同样归零');
    expect(find.text('1/1'), findsNothing);
    await flushTimers(tester);
  });

  testWidgets('Cmd+F（meta 变体）呼出搜索，Esc 收起', (tester) async {
    await pumpPage(tester, sessionA);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      searchBarFinder(),
      findsOneWidget,
      reason: 'macOS Cmd+F 必须与 Ctrl+F 同效（control 变体走  用例）',
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 250));
    expect(searchBarFinder(), findsNothing);
    await flushTimers(tester);
  });

  testWidgets('过期慢响应不回写新结果（请求序号守卫）', (tester) async {
    final gate = Completer<void>();
    repo.gateFirstSearch = gate;

    await pumpPage(tester, sessionA);
    await openSearchViaMenu(tester);

    // 第 1 个查询：被门控挂起（慢响应）
    await tester.enterText(searchFieldFinder(), '雪夜独行');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));

    // 第 2 个查询：无命中，快速返回
    await tester.enterText(searchFieldFinder(), '不存在的词');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text(t.chat.inSessionSearch.noResults), findsOneWidget);

    // 慢响应此时才返回：不得覆盖新结果
    gate.complete();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.text(t.chat.inSessionSearch.noResults),
      findsOneWidget,
      reason: '先发慢查询晚归不得覆盖新结果',
    );
    expect(find.text('1/1'), findsNothing);
    expect(tester.takeException(), isNull);
    await flushTimers(tester);
  });

  // 2026-09-08 搜索体验修复：命中消息不再只有整条闪示——搜索条可见期间
  // 常驻「命中上下文条」（片段 + 关键字高亮），关键字位置直接可见。
  testWidgets('命中消息渲染关键字高亮上下文条（不只闪整条消息）', (tester) async {
    await pumpPage(tester, sessionA);
    await openSearchViaMenu(tester);

    await tester.enterText(searchFieldFinder(), '雪夜独行');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));
    // 命中 1 条：a-u0
    expect(find.text('1/1'), findsOneWidget);

    // 命中条：气泡内的 search 图标 + 含关键字的 RichText 高亮 span
    final stripIcon = find.descendant(
      of: find.byType(SimpleMessageBubble),
      matching: find.byIcon(Icons.search),
    );
    expect(stripIcon, findsOneWidget, reason: '命中消息顶部应有搜索命中条');

    final richTexts = find.descendant(
      of: find.byType(SimpleMessageBubble),
      matching: find.byType(RichText),
    );
    var highlighted = false;
    for (final element in richTexts.evaluate()) {
      final widget = element.widget as RichText;
      void walk(InlineSpan span) {
        if (span is TextSpan) {
          final bg = span.style?.backgroundColor;
          if ((span.text?.contains('雪夜独行') ?? false) && bg != null) {
            highlighted = true;
          }
          span.children?.forEach(walk);
        }
      }

      walk(widget.text);
    }
    expect(
      highlighted,
      isTrue,
      reason: '命中条内关键字必须有背景高亮（此前只有整条消息闪示）',
    );
    await flushTimers(tester);
  });

  // 2026-09-08：关闭搜索后命中条随之消失（非常驻装饰）。
  testWidgets('关闭搜索后命中上下文条消失', (tester) async {
    await pumpPage(tester, sessionA);
    await openSearchViaMenu(tester);

    await tester.enterText(searchFieldFinder(), '雪夜独行');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.descendant(
        of: find.byType(SimpleMessageBubble),
        matching: find.byIcon(Icons.search),
      ),
      findsOneWidget,
    );

    // Esc 关闭搜索条（与  同法）
    await tester.sendKeyDownEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      find.descendant(
        of: find.byType(SimpleMessageBubble),
        matching: find.byIcon(Icons.search),
      ),
      findsNothing,
      reason: '关闭搜索后不应残留命中条',
    );
    await flushTimers(tester);
  });
}

ChatModeController _controllerFor(
  _SearchableChatRepository repo,
  ChatSession session,
) =>
    ChatModeController(
      chatRepository: repo,
      presetRepository: _NoopPresetRepository(),
      settingsRepository: _FakeSettingsRepository(),
      compactionService: CompactionService(
        chatRepository: repo,
        tokenCounter: TokenCounter(),
        settingsRepository: _FakeSettingsRepository(),
        presetRepository: _NoopPresetRepository(),
        streamer: CompactionStreamer(llmService: _NoopLlmService()),
        llmService: _NoopLlmService(),
      ),
      llmService: _NoopLlmService(),
      logger: const Logger('test'),
      failureLogRepository: const StubFailureLogRepository(),
      session: session,
    );

/// 支持按会话播种与可门控的会话内搜索仓库桩
class _SearchableChatRepository implements ChatRepository {
  final Map<String, List<ChatMessage>> _bySession = {};

  /// 搜索调用记录（sessionId, query），供跨会话误执行断言
  final List<(String, String)> searchCalls = [];

  /// 非空时第一次 searchMessagesInSession 挂起直到 complete
  Completer<void>? gateFirstSearch;
  bool _gatedCallDone = false;

  void seed(String sessionId, List<ChatMessage> messages) {
    _bySession.putIfAbsent(sessionId, () => []).addAll(messages);
  }

  List<ChatMessage> _messagesOf(String sessionId) =>
      _bySession[sessionId] ?? const [];

  @override
  Future<List<ChatMessage>> getMessages(String sessionId) async =>
      List.of(_messagesOf(sessionId));

  @override
  Future<List<SearchResult>> searchMessagesInSession(
    String sessionId,
    String query,
  ) async {
    searchCalls.add((sessionId, query));
    final gated = gateFirstSearch;
    if (gated != null && !_gatedCallDone) {
      _gatedCallDone = true;
      await gated.future;
    }
    final hits = _messagesOf(sessionId)
        .where((m) => (m.content ?? '').contains(query))
        .toList();
    return [
      for (final m in hits)
        SearchResult(
          sessionId: sessionId,
          sessionName: 'stub',
          messageId: m.messageId,
          content: m.content ?? '',
          role: m.role,
          createdAt: m.createdAt,
        ),
    ];
  }

  @override
  Future<ChatMessage> addMessage(ChatMessage message) async {
    _bySession.putIfAbsent(message.sessionId, () => []).add(message);
    return message;
  }

  @override
  Future<ChatSession> createSession({
    required String title,
    String? sessionId,
    String mode = 'chat',
    String? modelId,
    String? presetId,
  }) async =>
      throw UnimplementedError();

  @override
  Future<ChatSession> getSession(String sessionId) async =>
      throw UnimplementedError();

  @override
  Future<ChatSession> updateSession(ChatSession session) async => session;

  @override
  Future<int> getMessageCount(String sessionId) async =>
      _messagesOf(sessionId).length;

  @override
  Future<void> updateSessionMessageCount(String sessionId, int count) async {}

  @override
  Future<void> updateSessionLastActive(String sessionId) async {}

  @override
  Future<void> deleteSession(String sessionId) async {}

  @override
  Future<void> deleteAllSessions() async {}

  @override
  Future<void> recreateConversationTables() async {}

  @override
  Future<void> deleteMessage(String messageId) async {
    for (final list in _bySession.values) {
      list.removeWhere((m) => m.messageId == messageId);
    }
  }

  @override
  Future<void> updateMessageContent(String messageId, String content) async {
    for (final list in _bySession.values) {
      final i = list.indexWhere((m) => m.messageId == messageId);
      if (i >= 0) list[i] = list[i].copyWith(content: content);
    }
  }

  @override
  Future<List<ForkAnchor>> getForkAnchors(String sessionId) async => [];

  @override
  Future<void> updateMessageTokensUsed(
    String messageId,
    int? tokensUsed,
  ) async {}

  @override
  Future<int> updateMessageError(String messageId, String? error) async => 0;

  @override
  Future<void> addCompactionPoint({
    required String sessionId,
    required String summaryMessageId,
    required String boundaryMessageId,
    required DateTime createdAt,
  }) async {}

  @override
  Future<List<Map<String, dynamic>>> getCompactionPoints(
    String sessionId,
  ) async =>
      [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _NoopLlmService implements LlmService {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _FakeSettingsRepository implements SettingsRepository {
  @override
  Future<AppConfig> getResolvedConfig() async => const AppConfig(
        version: 'test',
        broadcastChat: BroadcastChatConfig(
          presetId: 'preset-test',
          modelId: 'model-test',
          autoCompaction: false,
        ),
      );

  @override
  Future<Map<String, dynamic>> getUserOverrides() async => const {};

  @override
  Future<void> setUserOverride(String key, dynamic value) async {}

  @override
  Future<void> clearAllUserOverrides() async {}

  @override
  Future<String?> getApiKey(String presetId) async => 'test-key';

  @override
  Future<void> saveApiKey(String presetId, String apiKey) async {}

  @override
  Future<int> getUserOverrideCount() async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _NoopTemplateRepository implements TemplateRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
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
  Future<List<ApiPreset>> getAllPresets() async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
