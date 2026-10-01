import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/chat/domain/entities/chat_mode.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/presentation/pages/home_page.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 首页固定一屏布局：
/// - 内容不可上下滑动（滚动范围恒为 0，Logo 不可能被顶出屏幕）
/// - 会话行按剩余高度整行裁切，设置入口恒在屏内
/// - 内容不足一屏时下拉刷新仍可用（恒可 overscroll）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Future<Preferences> fakePrefs() async {
    SharedPreferences.setMockInitialValues({});
    return Preferences(prefs: await SharedPreferences.getInstance());
  }

  Widget wrapHome(Preferences prefs, ChatRepository chatRepo) {
    return ProviderScope(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        chatRepositoryProvider.overrideWithValue(chatRepo),
        apiPresetRepositoryProvider
            .overrideWithValue(_HomeApiPresetRepository()),
        settingsRepositoryProvider.overrideWithValue(_HomeSettingsRepository()),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: ThemeCatalog.assemble(const LmAppearance(), Brightness.light),
          home: HomePage(
            onNewChat: () {},
            onNewStory: () {},
            onSessionSelected: (_) {},
          ),
        ),
      ),
    );
  }

  _HomeChatRepository fiveSessions() {
    return _HomeChatRepository(
      List<ChatSession>.generate(
        5,
        (i) => ChatSession(
          sessionId: 's$i',
          title: '会话${i + 1}',
          mode: ChatMode.chat,
          createdAt: DateTime(2026),
          lastActiveAt: DateTime(2026, 2),
          messageCount: i + 1,
          lastMessagePreview: '预览${i + 1}',
        ),
      ),
    );
  }

  testWidgets('会话塞满列表：滚动范围恒为 0，整行裁切，设置入口在屏内', (
    tester,
  ) async {
    await tester.pumpWidget(wrapHome(await fakePrefs(), fiveSessions()));
    await tester.pumpAndSettle();

    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable),
    );
    expect(
      scrollable.position.maxScrollExtent,
      0,
      reason: '首页内容恒定一屏，不允许上下滑动',
    );

    // 首行会话可见；800x600 测试视口放不下 5 行，必须整行裁切
    expect(find.text('会话1'), findsOneWidget);
    var rendered = 0;
    for (var i = 1; i <= 5; i++) {
      if (find.text('会话$i').evaluate().isNotEmpty) {
        rendered++;
      }
    }
    expect(rendered, lessThan(5), reason: '放不下的会话行整行隐藏');

    // 设置入口恒在屏内，Logo 头部不可能被顶出
    expect(find.text('设置'), findsOneWidget);
    expect(tester.getBottomRight(find.text('设置')).dy, lessThan(600));
  });

  testWidgets('无会话（内容不足一屏）：仍可下拉触发刷新', (tester) async {
    final repo = _HomeChatRepository(const []);
    await tester.pumpWidget(wrapHome(await fakePrefs(), repo));
    await tester.pumpAndSettle();
    expect(repo.loadCount, 1);

    await tester.fling(
      find.byType(CustomScrollView),
      const Offset(0, 300),
      1000,
    );
    await tester.pump();
    expect(
      find.byType(RefreshProgressIndicator),
      findsOneWidget,
      reason: '内容不足一屏时 overscroll 下拉刷新仍可用',
    );
    // 依次走完滚动/指示器收起动画
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(repo.loadCount, greaterThan(1));
  });
}

class _HomeChatRepository implements ChatRepository {
  _HomeChatRepository(this.sessions);

  final List<ChatSession> sessions;
  int loadCount = 0;

  @override
  Future<List<ChatSession>> getAllSessions() async {
    loadCount++;
    return sessions;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _HomeApiPresetRepository implements ApiPresetRepository {
  @override
  Future<List<ApiPreset>> getAllPresets() async => <ApiPreset>[
        ApiPreset(
          presetId: 'p1',
          name: '测试供应商',
          baseUrl: 'https://example.com',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _HomeSettingsRepository implements SettingsRepository {
  @override
  Future<String?> getApiKey(String presetId) async => 'test-key';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}
