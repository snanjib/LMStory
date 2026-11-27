import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/theme/system/lm_layout.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/chat/domain/entities/chat_mode.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/presentation/widgets/chat_mode_input_area.dart';
import 'package:lmstory/features/chat/presentation/widgets/chat_sidebar.dart';
import 'package:lmstory/features/help/presentation/pages/wiki_home_page.dart';
import 'package:lmstory/features/onboarding/presentation/pages/onboarding_page.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/presentation/pages/general_settings_page.dart';
import 'package:lmstory/features/settings/presentation/pages/provider_list_page.dart';
import 'package:lmstory/features/settings/presentation/pages/settings_page.dart';
import 'package:lmstory/features/story_runtime/domain/entities/story_phase_models.dart';
import 'package:lmstory/features/story_runtime/presentation/widgets/intermediate_chat_input.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';
import 'package:lmstory/features/templates/presentation/pages/template_management_page.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers/load_app_fonts.dart';

const _previewKey = ValueKey('app-visual-preview');

void main() {
  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.enUs);
    await LocaleSettings.setLocale(AppLocale.zhCn);
    await loadAppFonts(withSystemCjkFallback: true);
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  Future<void> pumpPage(
    WidgetTester tester,
    Widget page,
    LmAppearance appearance,
    Brightness brightness, {
    Size size = const Size(390, 844),
    double scale = 1,
    double keyboardHeight = 0,
    AppLocale locale = AppLocale.zhCn,
  }) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => LocaleSettings.setLocale(locale));
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final prefs = Preferences(prefs: await SharedPreferences.getInstance());
    final theme = ThemeCatalog.assemble(appearance, brightness);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          preferencesProvider.overrideWithValue(prefs),
          chatRepositoryProvider.overrideWithValue(_ChatRepo()),
          settingsRepositoryProvider.overrideWithValue(_SettingsRepo()),
          apiPresetRepositoryProvider.overrideWithValue(_PresetsRepo()),
          templateRepositoryProvider.overrideWithValue(_TemplatesRepo()),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme: withLoadedTestFonts(theme, withCjkFallback: true),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                viewInsets: EdgeInsets.only(bottom: keyboardHeight),
              ),
              child: child!,
            ),
            home: RepaintBoundary(key: _previewKey, child: page),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final structure in ThemeCatalog.structures) {
    for (final palette in ThemeCatalog.palettes) {
      for (final brightness in Brightness.values) {
        final appearance = LmAppearance(
          structureId: structure.id,
          paletteId: palette.id,
        );
        testWidgets(
            '${structure.id} ${palette.id} $brightness preserves settings navigation',
            (tester) async {
          await pumpPage(tester, const SettingsPage(), appearance, brightness);
          if (structure.id == 'classic' && palette.id == 'bordeaux') {
            await _capture(tester, 'settings_${brightness.name}');
          }
          final t = LocaleSettings.currentLocale.translations;
          await tester.tap(find.text(t.settings.general.title));
          await tester.pumpAndSettle();
          expect(find.byType(GeneralSettingsPage), findsOneWidget);
          expect(tester.takeException(), isNull);
          Navigator.of(tester.element(find.byType(GeneralSettingsPage))).pop();
          await tester.pumpAndSettle();
          final destinations = [
            t.settings.general.title,
            t.settings.chatSettings.title,
            t.settings.intermediate.title,
            t.settings.director.title,
            t.settings.template.title,
            t.settings.resourceLibrary.title,
            t.settings.data.title,
            t.settings.diagnostics.title,
            t.help.title,
          ];
          for (final label in destinations) {
            await tester.scrollUntilVisible(
              find.text(label),
              180,
              scrollable: find.byType(Scrollable),
            );
            await tester.pumpAndSettle();
            expect(find.text(label), findsOneWidget);
            expect(tester.takeException(), isNull);
          }
          await tester.tap(find.text(t.help.title));
          await tester.pumpAndSettle();
          expect(find.byType(WikiHomePage), findsOneWidget);
          await tester.enterText(find.byType(TextField), 'zzzzzzzz');
          await tester.pumpAndSettle();
          expect(find.text(t.help.wikiHome.noResults), findsOneWidget);
          expect(tester.takeException(), isNull);
        });

        testWidgets(
            '${structure.id} ${palette.id} $brightness keeps the composer usable with a keyboard',
            (tester) async {
          var sent = '';
          await pumpPage(
            tester,
            Scaffold(
              body: Column(
                children: [
                  const Expanded(child: SizedBox()),
                  IntermediateChatInput(
                    phase: IntermediatePhase.idle,
                    onSend: (text) => sent = text,
                    onCancel: () {},
                  ),
                ],
              ),
            ),
            appearance,
            brightness,
            size: const Size(320, 600),
            scale: 1.6,
            keyboardHeight: 240,
          );
          await tester.enterText(
            find.byType(TextField),
            'Return to the harbor.',
          );
          await tester.pumpAndSettle();
          await tester.tap(
            find.byTooltip(
              LocaleSettings.currentLocale.translations.intermediate.chat.send,
            ),
          );
          await tester.pumpAndSettle();
          expect(sent, 'Return to the harbor.');
          expect(tester.takeException(), isNull);
          if (structure.id == 'classic' &&
              palette.id == 'bordeaux' &&
              brightness == Brightness.dark) {
            await _capture(tester, 'composer_keyboard_dark');
          }
        });
      }
    }

    for (final locale in AppLocale.values) {
      testWidgets('${structure.id} $locale accommodates long list names',
          (tester) async {
        final appearance = LmAppearance(
          structureId: structure.id,
          paletteId: 'bordeaux',
        );
        await pumpPage(
          tester,
          const SettingsPage(),
          appearance,
          Brightness.light,
          size: const Size(320, 700),
          scale: 1.6,
          locale: locale,
        );
        await tester.scrollUntilVisible(
          find.text(LocaleSettings.currentLocale.translations.help.title),
          180,
          scrollable: find.byType(Scrollable),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await pumpPage(
          tester,
          const ProviderListPage(),
          appearance,
          Brightness.light,
          size: const Size(320, 700),
          scale: 1.6,
          locale: locale,
        );
        expect(find.text(_providerName), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (structure.id == 'classic' && locale == AppLocale.zhCn) {
          await _capture(tester, 'providers_large_type');
        }
        await pumpPage(
          tester,
          const TemplateManagementPage(),
          appearance,
          Brightness.light,
          size: const Size(320, 700),
          scale: 1.6,
          locale: locale,
        );
        final t = LocaleSettings.currentLocale.translations;
        final edit = find.widgetWithText(TextButton, t.common.edit);
        final copy = find.widgetWithText(TextButton, t.common.copy);
        expect(edit, findsOneWidget);
        expect(copy, findsOneWidget);
        expect(tester.getSize(edit).height, greaterThanOrEqualTo(44));
        expect(tester.getSize(copy).height, greaterThanOrEqualTo(44));
        expect(tester.takeException(), isNull);
        await tester.tap(edit);
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsOneWidget);
        await tester.tap(find.text(t.common.cancel));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
        if (structure.id == 'classic' && locale == AppLocale.zhCn) {
          await _capture(tester, 'templates_large_type');
        }
      });
    }

    testWidgets('${structure.id} keeps onboarding steps readable',
        (tester) async {
      await pumpPage(
        tester,
        const OnboardingPage(isReview: true),
        LmAppearance(structureId: structure.id, paletteId: 'bordeaux'),
        Brightness.light,
        size: const Size(320, 700),
        scale: 1.6,
        locale: AppLocale.enUs,
      );
      final t = LocaleSettings.currentLocale.translations;
      for (var step = 1; step <= 6; step++) {
        expect(
          find.text(t.onboarding.stepIndicator(current: step, total: 6)),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        if (step < 6) {
          await tester.tap(find.text(t.onboarding.next));
          await tester.pumpAndSettle();
        }
      }
      await pumpPage(
        tester,
        const OnboardingPage(isReview: true),
        LmAppearance(structureId: structure.id, paletteId: 'bordeaux'),
        Brightness.light,
        size: const Size(1920, 900),
        locale: AppLocale.enUs,
      );
      expect(
        tester
            .getSize(find.widgetWithText(ElevatedButton, t.onboarding.next))
            .width,
        // 底部按钮行在版心内对半展开：版心流式（1920×85%=1632）后
        // 同步放宽上界（仍守住"不得变成整窗大条"的意图）
        lessThanOrEqualTo(900),
      );
      expect(tester.takeException(), isNull);
      if (structure.id == 'classic') await _capture(tester, 'onboarding_wide');
    });

    testWidgets('${structure.id} keeps sidebar names and actions reachable',
        (tester) async {
      var selected = '';
      await pumpPage(
        tester,
        Scaffold(
          body: Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: LmLayout.sidebarWidth,
              child: ChatSidebar(
                selectedSessionId: 'story',
                onSessionSelected: (session, {focusMessageId}) =>
                    selected = session.sessionId,
                onNewChat: () {},
                onNewStory: () {},
                onNewDirector: () {},
                onSettings: () {},
                onCollapse: () {},
              ),
            ),
          ),
        ),
        LmAppearance(structureId: structure.id, paletteId: 'bordeaux'),
        Brightness.light,
      );
      await tester.tap(find.text('雾港来信：一场尚未结束的远行'));
      await tester.pumpAndSettle();
      expect(selected, 'story');
      expect(find.byIcon(Icons.more_horiz), findsNWidgets(2));
      expect(tester.takeException(), isNull);
      if (structure.id == 'classic') await _capture(tester, 'sidebar');
    });

    testWidgets('${structure.id} aligns wide chat input to the reading column',
        (tester) async {
      var sent = '';
      await pumpPage(
        tester,
        Scaffold(
          body: Column(
            children: [
              const Expanded(child: SizedBox()),
              ChatModeInputArea(
                onSend: (text, attachments) {
                  sent = text;
                  return true;
                },
                onCancel: () {},
                isSending: false,
                isStreaming: false,
                currentModelName: 'Local model',
              ),
            ],
          ),
        ),
        LmAppearance(structureId: structure.id),
        Brightness.dark,
        size: const Size(1920, 900),
      );
      await tester.enterText(find.byType(TextField), 'A new conversation.');
      await tester.pumpAndSettle();
      // 流式版心：1920 窗口下版心 = max(800, 1920×85%) = 1632
      expect(
        tester.getSize(find.byType(TextField)).width,
        lessThan(LmLayout.measureOf(1920, LmLayout.readingMeasure)),
      );
      expect(
        tester.getCenter(find.byType(TextField)).dx,
        closeTo(1920 / 2, 30),
      );
      await tester.tap(
        find.byTooltip(
          LocaleSettings.currentLocale.translations.chat.send,
        ),
      );
      await tester.pumpAndSettle();
      expect(sent, 'A new conversation.');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('help directory keeps readable sections and search results',
      (tester) async {
    await pumpPage(
      tester,
      const WikiHomePage(),
      const LmAppearance(paletteId: 'bordeaux'),
      Brightness.light,
    );
    await _capture(tester, 'help_directory');
    await tester.enterText(find.byType(TextField), '记忆');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

Future<void> _capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['LMSTORY_VISUAL_PREVIEW_DIR'];
  if (directory == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_previewKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(
      bytes!.buffer.asUint8List(),
    );
  });
}

const _providerName = 'Harbor Local Models / Writing Studio';

class _SettingsRepo implements SettingsRepository {
  @override
  Future<Map<String, dynamic>> getUserOverrides() async => {};
  @override
  Future<String?> getApiKey(String presetId) async => 'fixture';
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _PresetsRepo implements ApiPresetRepository {
  @override
  Future<int> getCustomPresetCount() async => 1;
  @override
  Future<List<ApiPreset>> getAllPresets() async => [
        ApiPreset(
          presetId: 'fixture',
          name: _providerName,
          baseUrl: 'http://localhost:11434/v1',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          cachedModels: const [ModelInfo(modelId: 'local-writing-model')],
        ),
      ];
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _TemplatesRepo implements TemplateRepository {
  @override
  Future<void> ensureBuiltInTemplates() async {}
  @override
  Future<List<Template>> getAllTemplates() async => [
        Template(
          templateId: 'fixture',
          name: '写给雾港的一封长信 / A Letter to the Harbor',
          kind: TemplateKind.systemPrompt,
          content: '让人物通过行动表达情感，让世界随着每次选择发生变化。',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      ];
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _ChatRepo implements ChatRepository {
  @override
  Future<List<ChatSession>> getAllSessions() async => [
        ChatSession(
          sessionId: 'story',
          title: '雾港来信：一场尚未结束的远行',
          mode: ChatMode.advanced,
          messageCount: 5,
          createdAt: DateTime(2026),
          lastActiveAt: DateTime(2026, 10, 7),
        ),
        ChatSession(
          sessionId: 'chat',
          title: '一些还没说完的话',
          mode: ChatMode.chat,
          messageCount: 2,
          createdAt: DateTime(2026),
          lastActiveAt: DateTime(2026, 10, 6),
        ),
      ];
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
