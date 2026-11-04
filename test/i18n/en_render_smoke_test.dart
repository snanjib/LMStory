import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/config/config_level.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/advanced/domain/entities/advanced_chat_state.dart';
import 'package:lmstory/features/advanced/domain/entities/agent_live_block.dart';
import 'package:lmstory/features/advanced/presentation/pages/director_chat_body.dart';
import 'package:lmstory/features/chat/domain/entities/chat_message.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/help/presentation/pages/wiki_home_page.dart';
import 'package:lmstory/features/intermediate/domain/entities/intermediate_chat_state.dart';
import 'package:lmstory/features/intermediate/presentation/pages/intermediate_chat_body.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/pages/general_language_input_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/general_settings_page.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:lmstory/i18n/strings_en_US.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// en-US 关键页面渲染冒烟：
/// 设置页/语言选择器/Wiki 首页/故事正文/导演正文在英文 locale 下
/// 渲染无异常、无中文残留（语言自称行除外）、切换即时刷新。
void main() {
  final en = TranslationsEnUs();

  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.enUs);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(const {});
  });

  group('设置页（en）', () {
    testWidgets('顶层页与语言子页渲染英文且无中文残留', (tester) async {
      final configPrefs = Preferences(
        prefs: await SharedPreferences.getInstance(),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(_StubSettings()),
            apiPresetRepositoryProvider.overrideWithValue(_StubPresets()),
            templateRepositoryProvider.overrideWithValue(_StubTemplates()),
            configLevelProvider.overrideWith(
              (ref) => ConfigLevelNotifier(
                configPrefs,
                initialValue: ConfigLevel.advanced,
              ),
            ),
          ],
          child: TranslationProvider(
            child: const MaterialApp(home: GeneralSettingsPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text(en.settings.general.title), findsOneWidget);
      expect(_cjkTexts(), findsNothing);
    });
  });

  group('语言选择器（en）', () {
    testWidgets('English 行可选、跟随系统保持 disabled 预告', (tester) async {
      await _pumpLanguagePage(tester);

      expect(tester.takeException(), isNull);
      // English 行开放后不再带 comingSoon；唯一预告来自跟随系统行
      expect(
        find.text(en.settings.general.languageOptions.comingSoon),
        findsOneWidget,
        reason: 'comingSoon 应只出现在跟随系统（disabled）行上',
      );
      // 跟随系统行仍为 disabled 占位：显示预告文案
      expect(
        find.text(en.settings.general.languageOptions.system),
        findsOneWidget,
      );
    });

    testWidgets('点击中文行立即切回中文，再点 English 行切回英文', (tester) async {
      await _pumpLanguagePage(tester);

      // 初始英文：区段标题为 Language
      expect(find.text(en.settings.general.language), findsOneWidget);

      // 切到中文（TranslationProvider 即时刷新，无需重启）
      await tester.tap(find.text('简体中文'));
      await tester.pumpAndSettle();
      expect(find.text(en.settings.general.language), findsNothing);
      expect(find.text(t.settings.general.language), findsOneWidget);

      // 再切回英文（可重复切换）
      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();
      expect(find.text(en.settings.general.language), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Help Wiki 首页（en）', () {
    testWidgets('渲染无异常且无中文残留', (tester) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: const MaterialApp(home: WikiHomePage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text(en.help.wikiHome.title), findsOneWidget);
      expect(_cjkTexts(), findsNothing);
    });
  });

  group('故事模式正文（en）', () {
    testWidgets('空状态与生成中状态渲染无异常、无中文残留', (tester) async {
      final session = _session('intermediate');
      final idle = IntermediateChatState(
        phase: IntermediatePhase.idle,
        messages: const [],
        retryCounts: const {},
        session: session,
      );
      await _pumpBody(tester, _storyBody(idle));
      expect(tester.takeException(), isNull);
      expect(_cjkTexts(), findsNothing);

      final generating = IntermediateChatState(
        phase: IntermediatePhase.generating,
        messages: const [],
        retryCounts: const {},
        session: session,
        pendingUserMessage:
            _message(session.sessionId, 'user', 'Start the story'),
      );
      await _pumpBody(tester, _storyBody(generating));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('Start the story'), findsOneWidget);
      expect(_cjkTexts(), findsNothing);
    });

    testWidgets('textScaler 1.3 下无布局溢出异常', (tester) async {
      final state = IntermediateChatState(
        phase: IntermediatePhase.idle,
        messages: const [],
        retryCounts: const {},
        session: _session('intermediate'),
      );
      await _pumpBody(
        tester,
        _storyBody(state),
        scaler: const TextScaler.linear(1.3),
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('导演模式正文（en）', () {
    testWidgets('直播分块渲染无异常、无中文残留', (tester) async {
      final state = AdvancedChatState(
        phase: IntermediatePhase.reviewing,
        messages: const [],
        retryCounts: const {},
        session: _session('advanced'),
        liveBlocks: const [
          AgentLiveBlock(
            kind: AgentLiveBlockKind.thinking,
            stepIndex: 0,
            text: 'Consulting the world setting',
          ),
          AgentLiveBlock(
            kind: AgentLiveBlockKind.text,
            stepIndex: 1,
            text: 'Chapter one, the full prose.',
            source: AgentTextSource.finishRoundProse,
          ),
        ],
      );
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            theme:
                ThemeCatalog.assemble(ThemeCatalog.defaults, Brightness.dark),
            home: Scaffold(
              body: DirectorChatBody(
                state: state,
                onCopy: (_) {},
                onRegenerate: (_) {},
                onEdit: (_) {},
                onDeleteRound: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Chapter one, the full prose.'), findsOneWidget);
      expect(_cjkTexts(), findsNothing);
    });
  });
}

// ── helpers ─────────────────────────────────────────────────────────

Finder _cjkTexts() => find.byWidgetPredicate((widget) {
      if (widget is! Text) return false;
      final data = widget.data ?? widget.textSpan?.toPlainText() ?? '';
      return RegExp(r'[\u4e00-\u9fff]').hasMatch(data);
    });

ChatSession _session(String mode) => ChatSession(
      sessionId: '$mode-1',
      title: 'Smoke $mode',
      mode: mode,
      createdAt: DateTime(2026),
      lastActiveAt: DateTime(2026),
      messageCount: 0,
    );

ChatMessage _message(String sessionId, String role, String content) =>
    ChatMessage(
      messageId: 'm-$role-${content.hashCode}',
      sessionId: sessionId,
      role: role,
      content: content,
      createdAt: DateTime(2026),
    );

IntermediateChatBody _storyBody(IntermediateChatState state) =>
    IntermediateChatBody(
      state: state,
      onRetryRetrieval: () {},
      windowRounds: 5,
      canOperate: (_) => false,
      onCopy: (_) {},
      onRegenerate: (_) {},
      onEdit: (_) {},
      onDeleteRound: (_) {},
    );

Future<void> _pumpLanguagePage(WidgetTester tester) async {
  final configPrefs = Preferences(prefs: await SharedPreferences.getInstance());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(_StubSettings()),
        apiPresetRepositoryProvider.overrideWithValue(_StubPresets()),
        templateRepositoryProvider.overrideWithValue(_StubTemplates()),
        configLevelProvider.overrideWith(
          (ref) => ConfigLevelNotifier(
            configPrefs,
            initialValue: ConfigLevel.advanced,
          ),
        ),
      ],
      child: TranslationProvider(
        child: const MaterialApp(home: _LanguagePageHost()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpBody(
  WidgetTester tester,
  Widget body, {
  TextScaler? scaler,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      child: TranslationProvider(
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: scaler == null
                ? MediaQuery.of(context)
                : MediaQuery.of(context).copyWith(textScaler: scaler),
            child: child!,
          ),
          home: Scaffold(
            body: body,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// 语言与输入子页（直接挂子页，避免顶层导航噪声）。
class _LanguagePageHost extends StatelessWidget {
  const _LanguagePageHost();

  @override
  Widget build(BuildContext context) {
    return const GeneralLanguageInputSettingsPage();
  }
}

class _StubSettings implements SettingsRepository {
  @override
  Future<Map<String, dynamic>> getUserOverrides() async => const {};

  @override
  Future<String?> getApiKey(String presetId) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _StubPresets implements ApiPresetRepository {
  @override
  Future<List<ApiPreset>> getAllPresets() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _StubTemplates implements TemplateRepository {
  @override
  Future<List<Template>> getAllTemplates() async => const [];

  @override
  Future<void> ensureBuiltInTemplates() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
