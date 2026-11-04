import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/presentation/widgets/chat_sidebar.dart';
import 'package:lmstory/i18n/strings.g.dart';

/// ChatSidebar 删除会话行为测试
///
/// 覆盖：
/// 1. 生成中的会话禁止删除（否则轮次继续向已删会话回写孤儿数据）
/// 2. 删除成功后通知父级（onSessionUpdated 刷新数据 + 删除的是当前
///    选中会话时 onSessionDeleted 让 MainLayout 导航回主页——此前删除
///    当前会话后主区仍停留在已删会话，继续发消息写入不存在的会话）
void main() {
  setUpAll(() {
    LocaleSettings.setLocale(AppLocale.zhCn);
  });

  late _SidebarRepo fakeRepo;

  setUp(() {
    fakeRepo = _SidebarRepo();
  });

  Future<void> pumpSidebar(
    WidgetTester tester, {
    String? selectedSessionId,
    Set<String> generating = const {},
    VoidCallback? onSessionUpdated,
    void Function(ChatSession session)? onSessionDeleted,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(fakeRepo),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: Row(
                children: [
                  SizedBox(
                    width: 260,
                    child: ChatSidebar(
                      selectedSessionId: selectedSessionId,
                      onSessionSelected: (session, {focusMessageId}) {},
                      onNewChat: () {},
                      onNewStory: () {},
                      onSettings: () {},
                      onCollapse: () {},
                      onSessionUpdated: onSessionUpdated,
                      onSessionDeleted: onSessionDeleted,
                      generatingSessionIds: generating,
                    ),
                  ),
                  const Expanded(child: SizedBox()),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    // 生成中的会话带呼吸点动画（无限循环），不能用 pumpAndSettle
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> deleteSessionViaMenu(
    WidgetTester tester,
    String sessionId, {
    bool confirm = true,
  }) async {
    final item = find.byKey(ValueKey(sessionId));
    expect(item, findsOneWidget);
    await tester.ensureVisible(item);
    await tester.pump();
    // 打开会话项的更多菜单（more_horiz 图标在会话项内）
    final menuButton = find.descendant(
      of: item,
      matching: find.byIcon(Icons.more_horiz),
    );
    await tester.tap(menuButton, warnIfMissed: false);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    // 直接 tap Text 不会命中 PopupMenuItem 的 InkWell，点条目本体
    final menuItem = find.ancestor(
      of: find.text('删除会话'),
      matching: find.byType(PopupMenuItem<String>),
    );
    await tester.tap(menuItem.last);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    // 确认对话框
    if (confirm) {
      await tester.tap(find.text('删除'));
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  testWidgets('生成中的会话禁止删除并给出提示', (tester) async {
    await pumpSidebar(
      tester,
      selectedSessionId: 's1',
      generating: const {'s1'},
    );

    await deleteSessionViaMenu(tester, 's1');

    expect(fakeRepo.deletedIds, isEmpty, reason: '生成中不得删除会话');
    expect(find.text('该会话正在生成，请先停止后再删除'), findsOneWidget);
  });

  testWidgets('删除当前选中会话成功后通知父级刷新与导航', (tester) async {
    var updatedCalled = false;
    ChatSession? deletedSession;
    await pumpSidebar(
      tester,
      selectedSessionId: 's2',
      onSessionUpdated: () => updatedCalled = true,
      onSessionDeleted: (s) => deletedSession = s,
    );

    await deleteSessionViaMenu(tester, 's2');

    expect(fakeRepo.deletedIds, ['s2']);
    expect(updatedCalled, isTrue, reason: '删除后须通知父级刷新会话数据');
    expect(deletedSession?.sessionId, 's2', reason: '删除的是当前选中会话时须通知父级导航回主页');
  });
}

ChatSession _session(String id) => ChatSession(
      sessionId: id,
      title: '会话$id',
      mode: 'simple',
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 0,
    );

class _SidebarRepo implements ChatRepository {
  final deletedIds = <String>[];

  @override
  Future<List<ChatSession>> getAllSessions() async =>
      [_session('s1'), _session('s2')];

  @override
  Future<void> deleteSession(String sessionId) async {
    deletedIds.add(sessionId);
  }

  @override
  Future<ChatSession> updateSession(ChatSession session) async => session;

  @override
  Future<void> updateSessionLastActive(String sessionId) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}
