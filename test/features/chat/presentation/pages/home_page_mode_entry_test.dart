import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/presentation/pages/home_page.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  Widget wrapHome(Preferences prefs, {VoidCallback? onNewDirector}) {
    return ProviderScope(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        chatRepositoryProvider.overrideWithValue(_StubChatRepository()),
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
}

/// 首页空态替身：`getAllSessions` 返回空列表，其余方法显式报错。
class _StubChatRepository implements ChatRepository {
  @override
  Future<List<ChatSession>> getAllSessions() async => const [];

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
