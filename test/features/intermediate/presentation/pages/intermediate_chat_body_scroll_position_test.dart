import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/presentation/utils/scroll_position_cache.dart';
import 'package:lmstory/features/intermediate/domain/entities/intermediate_chat_state.dart';
import 'package:lmstory/features/intermediate/presentation/pages/intermediate_chat_body.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// 故事侧阅读位置记忆（复用 chat 滚动位置 LRU 缓存）。
///
/// 三路径：fresh-mount 带缓存消息→恢复缓存偏移；无缓存→贴底；
/// 同型切会话→旧会话位置入缓存。
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  ChatSession session(String id) => ChatSession(
        sessionId: id,
        title: '测试故事',
        mode: 'intermediate',
        createdAt: DateTime(2026),
        lastActiveAt: DateTime(2026),
        messageCount: 0,
      );

  List<ChatMessage> longMessages(int count) => [
        for (var i = 1; i <= count; i++)
          ChatMessage(
            messageId: 'm$i',
            sessionId: 's1',
            role: i.isOdd ? 'user' : 'assistant',
            content: '第${(i + 1) ~/ 2}轮'
                '${i.isOdd ? '用户' : '回复'}内容——补足高度的长正文，'
                '确保列表可滚动。',
            createdAt: DateTime(2026),
          ),
      ];

  IntermediateChatState stateOf(
    ChatSession s,
    List<ChatMessage> messages,
  ) =>
      IntermediateChatState(
        phase: IntermediatePhase.idle,
        messages: messages,
        retryCounts: const {},
        session: s,
      );

  Widget host(Widget child) => ProviderScope(
        child: TranslationProvider(
          child: MaterialApp(home: Scaffold(body: child)),
        ),
      );

  IntermediateChatBody bodyFor(IntermediateChatState state) =>
      IntermediateChatBody(
        state: state,
        onRetryRetrieval: () {},
        windowRounds: 10,
        canOperate: (_) => true,
        onCopy: (_) {},
        onRegenerate: (_) {},
        onEdit: (_) {},
        onDeleteRound: (_) {},
      );

  testWidgets('fresh-mount 带缓存消息 → 恢复缓存阅读位置', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    // 预存 s1 的阅读位置（列表中部偏移）
    container.read(scrollPositionCacheProvider).save('s1', 60);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: bodyFor(stateOf(session('s1'), longMessages(40))),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final bodyState = tester.state<IntermediateChatBodyState>(
      find.byType(IntermediateChatBody),
    );
    expect(
      bodyState.scrollOffsetForTest(),
      60,
      reason: '进入已读过的会话恢复上次阅读位置，而非贴底或顶部',
    );
  });

  testWidgets('无缓存 → 保持既有进入行为（不强制跳变）', (tester) async {
    await tester.pumpWidget(
      host(bodyFor(stateOf(session('s1'), longMessages(40)))),
    );
    await tester.pumpAndSettle();

    final bodyState = tester.state<IntermediateChatBodyState>(
      find.byType(IntermediateChatBody),
    );
    expect(
      bodyState.scrollOffsetForTest(),
      0,
      reason: '只做位置记忆：无缓存不接管进入定位（默认贴底属'
          'CH8-1 同族独立事项，不在本批范围）',
    );
  });

  testWidgets('同型切会话 → 旧会话位置入缓存', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: bodyFor(stateOf(session('s1'), longMessages(40))),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 上滑到中部（模拟阅读中切走）
    tester
        .state<IntermediateChatBodyState>(find.byType(IntermediateChatBody))
        .jumpToOffsetForTest(80);
    await tester.pump();

    // 同型切到 s2（didUpdateWidget 会话切换分支：保存旧位置）
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: bodyFor(stateOf(session('s2'), longMessages(6))),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      container.read(scrollPositionCacheProvider).restore('s1'),
      80,
      reason: '切走时保存旧会话阅读位置（键=旧会话真实 id）',
    );
  });
}
