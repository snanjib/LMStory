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

import '../../../../helpers/home_sessions_fixture.dart';

/// 首页固定一屏布局：
/// - 内容不可上下滑动（滚动范围恒为 0，Logo 不可能被顶出屏幕）
/// - 会话行按剩余高度整行裁切，设置入口恒在屏内
/// - 内容不足一屏时下拉刷新仍可用（恒可 overscroll）
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Future<Preferences> fakePrefs({Map<String, Object> values = const {}}) async {
    SharedPreferences.setMockInitialValues(values);
    return Preferences(prefs: await SharedPreferences.getInstance());
  }

  Widget wrapHome(
    Preferences prefs,
    ChatRepository chatRepo, {
    ValueChanged<ChatSession>? onSessionSelected,
    VoidCallback? onDirectorWizard,
  }) {
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
            onDirectorWizard: onDirectorWizard,
            onSessionSelected: onSessionSelected ?? (_) {},
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

  testWidgets('recent activity selects the story independently of pinned order',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    ChatSession story(String id, String mode, int day) => ChatSession(
          sessionId: id,
          title: id,
          mode: mode,
          createdAt: DateTime(2026),
          lastActiveAt: DateTime(2026, 10, day),
          messageCount: 2,
        );
    final repo = _HomeChatRepository([
      story('pinned chat', ChatMode.chat, 7),
      story('older story', ChatMode.intermediate, 2),
      story('latest director', ChatMode.advanced, 6),
    ]);
    ChatSession? selected;
    await tester.pumpWidget(
      wrapHome(
        await fakePrefs(),
        repo,
        onSessionSelected: (session) => selected = session,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('继续故事'), findsOneWidget);
    expect(find.text('latest director'), findsOneWidget);
    expect(find.text('新建故事'), findsNothing);
    await tester.tap(find.text('回到故事'));
    expect(selected?.sessionId, 'latest director');
    expect(tester.takeException(), isNull);
  });

  testWidgets('short screen retains the narrative session in recent sessions',
      (tester) async {
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repo = _HomeChatRepository([
      ChatSession(
        sessionId: 'story',
        title: 'Existing story',
        mode: ChatMode.intermediate,
        createdAt: DateTime(2026),
        lastActiveAt: DateTime(2026),
        messageCount: 2,
      ),
    ]);
    await tester.pumpWidget(wrapHome(await fakePrefs(), repo));
    await tester.pumpAndSettle();
    expect(find.text('Existing story'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(tester.takeException(), isNull);
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(scrollable.position.maxScrollExtent, 0);
  });

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

  testWidgets('故事入口开+三卡最高布局：滚动范围仍恒 0，无溢出', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrapHome(
        await fakePrefs(values: {'intermediate_mode_enabled': true}),
        fiveSessions(),
      ),
    );
    await tester.pumpAndSettle();

    // 三卡齐备（对话/故事/导演）= 固定一屏最高布局形态
    final cards = find.byType(IntrinsicHeight);
    expect(cards, findsWidgets);
    expect(find.text('新建对话'), findsOneWidget);
    expect(find.text('新建故事'), findsOneWidget);

    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable),
    );
    expect(
      scrollable.position.maxScrollExtent,
      0,
      reason: '三卡最高布局下内容仍恒定一屏',
    );
    expect(tester.takeException(), isNull, reason: '不溢出');
  });

  testWidgets('短屏把最近会话全裁掉（可见行=0）：显示侧边栏指路行', (
    tester,
  ) async {
    // 高度压到非弹性内容几乎占满：剩余空间不足一行 → 5 条全裁
    tester.view.physicalSize = const Size(800, 420);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(wrapHome(await fakePrefs(), fiveSessions()));
    await tester.pumpAndSettle();

    expect(find.text('会话较多，打开侧边栏查看全部'), findsOneWidget);
    for (var i = 1; i <= 5; i++) {
      expect(find.text('会话$i'), findsNothing, reason: '零行时一行也不渲染');
    }
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

  testWidgets('向导引导卡加入后：滚动范围仍恒 0，无溢出，设置入口在屏内', (
    tester,
  ) async {
    // 故事开+双回调 = 最高布局（对话+故事双卡 + 导演横卡 + 向导引导卡）；
    // 720 高确保非 compact 分支
    tester.view.physicalSize = const Size(800, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      wrapHome(
        await fakePrefs(values: {'intermediate_mode_enabled': true}),
        fiveSessions(),
        onDirectorWizard: () {},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('导演模式创建向导'), findsOneWidget);
    expect(find.text('新建对话'), findsOneWidget);
    expect(find.text('新建故事'), findsOneWidget);

    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scrollable.position.maxScrollExtent, 0, reason: '恒定一屏不可滑动');
    expect(tester.takeException(), isNull, reason: '不溢出');
    expect(find.text('设置'), findsOneWidget);
    expect(tester.getBottomRight(find.text('设置')).dy, lessThan(720));
  });

  testWidgets('向导引导卡加入 compact 形态后：滚动范围仍恒 0，设置入口在屏内', (
    tester,
  ) async {
    // 继续故事大卡 + 对话/故事小卡行 + 引导卡 = compact 最高布局形态
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final repo = _HomeChatRepository([
      ChatSession(
        sessionId: 'director-1',
        title: '旧导演会话',
        mode: ChatMode.advanced,
        createdAt: DateTime(2026),
        lastActiveAt: DateTime(2026, 2),
        messageCount: 3,
      ),
    ]);
    await tester.pumpWidget(
      wrapHome(
        await fakePrefs(values: {'intermediate_mode_enabled': true}),
        repo,
        onDirectorWizard: () {},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('继续故事'), findsOneWidget, reason: 'compact 形态成立');
    expect(find.text('导演模式创建向导'), findsOneWidget, reason: '小卡行之后渲染引导卡');

    final scrollable = tester.state<ScrollableState>(
      find.descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      ),
    );
    expect(scrollable.position.maxScrollExtent, 0, reason: '恒定一屏不可滑动');
    expect(tester.takeException(), isNull, reason: '不溢出');
    expect(find.text('设置'), findsOneWidget);
    expect(tester.getBottomRight(find.text('设置')).dy, lessThan(800));
  });

  testWidgets('无 Key 黄条 + 向导引导卡 + 故事卡同时存在：高度 800 下 compact 故事卡不溢出，设置在屏内', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final repo = _HomeChatRepository([
      ChatSession(
        sessionId: 'director-overflow-check',
        title:
            '(我叫南极，刚从超市出来就被泥头车创到了异世界。看了很多动漫的我费尽千辛万苦，终于找到最近的冒险者公会，我推开大门来到前台) 你好，请问是在这里注册冒险者吗？',
        mode: ChatMode.advanced,
        createdAt: DateTime(2026),
        lastActiveAt: DateTime(2026, 2),
        messageCount: 3,
        lastMessagePreview: '(门轴响了一声，比想象中沉。热气和声音一起扑上来，麦酒放了夜的那种酸，混着...)',
      ),
    ]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesProvider.overrideWithValue(await fakePrefs()),
          chatRepositoryProvider.overrideWithValue(repo),
          apiPresetRepositoryProvider
              .overrideWithValue(_HomeApiPresetRepository()),
          settingsRepositoryProvider
              .overrideWithValue(_HomeEmptySettingsRepository()),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme:
                ThemeCatalog.assemble(const LmAppearance(), Brightness.light),
            home: HomePage(
              onNewChat: () {},
              onNewStory: () {},
              onDirectorWizard: () {},
              onSessionSelected: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('尚未配置 API Key'), findsOneWidget);
    expect(find.text('导演模式创建向导'), findsOneWidget);
    expect(find.text('继续故事'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '绝无 RenderFlex 底部溢出异常');
    expect(tester.getBottomRight(find.text('设置')).dy, lessThanOrEqualTo(800));
  });
}

class _HomeEmptySettingsRepository implements SettingsRepository {
  @override
  Future<String?> getApiKey(String presetId) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _HomeChatRepository implements ChatRepository {
  _HomeChatRepository(this.sessions);

  final List<ChatSession> sessions;
  int loadCount = 0;

  @override
  Future<HomeSessions> getHomeSessions() async {
    loadCount++;
    return homeSessionsFixture(sessions);
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
