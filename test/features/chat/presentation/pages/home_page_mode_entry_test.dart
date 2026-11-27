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

/// 首页模式入口卡布局：故事模式入口默认隐藏、导演升为并排主推卡；
/// 故事开关打开后回到「对话+故事双卡 + 导演横卡」的既有布局。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
  });

  Future<Preferences> fakePrefs([Map<String, Object> values = const {}]) async {
    SharedPreferences.setMockInitialValues(values);
    return Preferences(prefs: await SharedPreferences.getInstance());
  }

  Widget wrapHome(
    Preferences prefs, {
    VoidCallback? onNewDirector,
    VoidCallback? onDirectorWizard,
    ChatRepository? chatRepo,
  }) {
    return ProviderScope(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        chatRepositoryProvider.overrideWithValue(
          chatRepo ?? _StubChatRepository(),
        ),
        apiPresetRepositoryProvider
            .overrideWithValue(_StubApiPresetRepository()),
        settingsRepositoryProvider.overrideWithValue(_StubSettingsRepository()),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: ThemeCatalog.assemble(const LmAppearance(), Brightness.light),
          home: HomePage(
            onNewChat: () {},
            onNewStory: () {},
            onNewDirector: onNewDirector,
            onDirectorWizard: onDirectorWizard,
            onSessionSelected: (_) {},
          ),
        ),
      ),
    );
  }

  testWidgets('默认（无存储值）：故事卡隐藏，导演升为并排第二卡', (tester) async {
    await tester.pumpWidget(
      wrapHome(await fakePrefs(), onNewDirector: () {}),
    );
    await tester.pumpAndSettle();

    expect(find.text('新建对话'), findsOneWidget);
    expect(find.text('新建故事'), findsNothing, reason: '故事模式入口默认隐藏');
    expect(find.text('新导演'), findsOneWidget, reason: '导演顶替第二卡位');
  });

  testWidgets('故事开关开启：故事卡回归，导演退回第三横卡', (tester) async {
    await tester.pumpWidget(
      wrapHome(
        await fakePrefs({'intermediate_mode_enabled': true}),
        onNewDirector: () {},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('新建对话'), findsOneWidget);
    expect(find.text('新建故事'), findsOneWidget, reason: '开关开启恢复故事入口');
    expect(find.text('新导演'), findsOneWidget, reason: '导演回到横卡，不重复出现');
  });

  testWidgets('故事隐藏且无导演回调：对话卡独占，无第二卡', (tester) async {
    await tester.pumpWidget(wrapHome(await fakePrefs()));
    await tester.pumpAndSettle();

    expect(find.text('新建对话'), findsOneWidget);
    expect(find.text('新建故事'), findsNothing);
    expect(find.text('新导演'), findsNothing, reason: '接线方未提供导演回调时不渲染');
  });

  testWidgets('向导引导卡：默认出现（导演 flag 开 + 回调提供），点按触发回调', (
    tester,
  ) async {
    // 720 高：扣 AppBar 后 body ≥ 600，走非 compact 布局（600 测试面
    // 的 body 实际 ~544 恒 compact，引导卡按设计渲染于非 compact 分支）
    tester.view.physicalSize = const Size(800, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var tapped = false;
    await tester.pumpWidget(
      wrapHome(await fakePrefs(), onDirectorWizard: () => tapped = true),
    );
    await tester.pumpAndSettle();

    expect(find.text('导演模式创建向导'), findsOneWidget, reason: '创建区下方独立引导卡');
    await tester.tap(find.text('导演模式创建向导'));
    await tester.pumpAndSettle();
    expect(tapped, isTrue);
  });

  testWidgets('向导引导卡：回调未提供时不渲染', (tester) async {
    tester.view.physicalSize = const Size(800, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(wrapHome(await fakePrefs()));
    await tester.pumpAndSettle();

    expect(find.text('导演模式创建向导'), findsNothing);
  });

  testWidgets('向导引导卡：导演 flag 关闭时不渲染', (tester) async {
    tester.view.physicalSize = const Size(800, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      wrapHome(
        await fakePrefs({'advanced_mode_enabled': false}),
        onDirectorWizard: () {},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('新导演'), findsNothing);
    expect(find.text('导演模式创建向导'), findsNothing);
  });

  testWidgets('向导引导卡：compact 布局渲染于小卡行之后（短屏）', (tester) async {
    tester.view.physicalSize = const Size(800, 550);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var tapped = false;
    await tester.pumpWidget(
      wrapHome(await fakePrefs(), onDirectorWizard: () => tapped = true),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('导演模式创建向导'),
      findsOneWidget,
      reason: 'compact 小卡行之后渲染引导卡',
    );
    await tester.tap(find.text('导演模式创建向导'));
    await tester.pumpAndSettle();
    expect(tapped, isTrue);
  });

  testWidgets('向导引导卡：新版主页（有继续故事会话恒 compact）引导卡可见可点', (
    tester,
  ) async {
    // 老用户日常形态：存在导演会话 → 继续故事大卡 + compact 小卡行 + 引导卡
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final chatRepo = _StubChatRepository([
      ChatSession(
        sessionId: 'director-1',
        title: '旧导演会话',
        mode: ChatMode.advanced,
        createdAt: DateTime(2026),
        lastActiveAt: DateTime(2026, 2),
        messageCount: 3,
      ),
    ]);
    var tapped = false;
    await tester.pumpWidget(
      wrapHome(
        await fakePrefs(),
        onDirectorWizard: () => tapped = true,
        chatRepo: chatRepo,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('继续故事'), findsOneWidget, reason: '新版主页形态成立');
    expect(find.text('导演模式创建向导'), findsOneWidget, reason: '继续故事形态下向导引导卡仍可达');
    await tester.tap(find.text('导演模式创建向导'));
    await tester.pumpAndSettle();
    expect(tapped, isTrue);
  });
  testWidgets('向导引导卡：故事开关全开时 compact 三小卡+引导卡不溢出', (tester) async {
    tester.view.physicalSize = const Size(800, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final chatRepo = _StubChatRepository([
      ChatSession(
        sessionId: 'story-1',
        title: '旧故事会话',
        mode: ChatMode.intermediate,
        createdAt: DateTime(2026),
        lastActiveAt: DateTime(2026, 2),
        messageCount: 3,
      ),
    ]);
    await tester.pumpWidget(
      wrapHome(
        await fakePrefs({'intermediate_mode_enabled': true}),
        onNewDirector: () {},
        onDirectorWizard: () {},
        chatRepo: chatRepo,
      ),
    );
    await tester.pumpAndSettle();

    // 三小卡齐备（对话/故事/导演）= compact 小卡行最高密度形态 + 引导卡
    expect(find.text('新建对话'), findsOneWidget);
    expect(find.text('新建故事'), findsOneWidget);
    expect(find.text('新导演'), findsOneWidget);
    expect(find.text('导演模式创建向导'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: '三小卡+引导卡不溢出');
  });
}

/// 首页替身返回注入的会话，缺省为空。
class _StubChatRepository implements ChatRepository {
  _StubChatRepository([this.sessions = const []]);

  final List<ChatSession> sessions;

  @override
  Future<HomeSessions> getHomeSessions() async => homeSessionsFixture(sessions);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubApiPresetRepository implements ApiPresetRepository {
  @override
  Future<List<ApiPreset>> getAllPresets() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}

class _StubSettingsRepository implements SettingsRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('Not implemented: ${invocation.memberName}');
}
