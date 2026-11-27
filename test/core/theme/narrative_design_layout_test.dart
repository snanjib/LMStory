import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/theme/api/lm_component_kit.dart';
import 'package:lmstory/core/theme/shared/components/memory_timeline_entry.dart';
import 'package:lmstory/core/theme/system/lm_tokens.dart';
import 'package:lmstory/core/theme/system/structures/classic/narrative/experience_memory_tab.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/chat/domain/entities/chat_mode.dart';
import 'package:lmstory/features/chat/domain/entities/chat_session.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/presentation/pages/home_page.dart';
import 'package:lmstory/features/memory/domain/entities/experiential_memory.dart';
import 'package:lmstory/features/memory/domain/repositories/experience_repository.dart';
import 'package:lmstory/features/resource_library/domain/entities/parsed_character_card.dart';
import 'package:lmstory/features/resource_library/presentation/widgets/resource_content_viewer.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/repositories/api_preset_repository.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/home_sessions_fixture.dart';
import '../../test_helpers/load_app_fonts.dart';

const _surfaceKey = ValueKey('preview-surface');

void main() {
  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.zhCn);
    await loadAppFonts(withSystemCjkFallback: true);
    final iconLoader = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await iconLoader.load();
  });

  Future<Widget> homeHost(
    LmAppearance appearance,
    Brightness brightness, {
    double scale = 1,
  }) async {
    SharedPreferences.setMockInitialValues({'intermediate_mode_enabled': true});
    final prefs = Preferences(prefs: await SharedPreferences.getInstance());
    return ProviderScope(
      overrides: [
        preferencesProvider.overrideWithValue(prefs),
        chatRepositoryProvider.overrideWithValue(_ChatRepo()),
        apiPresetRepositoryProvider.overrideWithValue(_PresetRepo()),
        settingsRepositoryProvider.overrideWithValue(_SettingsRepo()),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          theme: _previewTheme(appearance, brightness),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Builder(
            builder: (context) => RepaintBoundary(
              key: _surfaceKey,
              child: context.lmVenue(
                HomePage(
                  onNewChat: () {},
                  onNewStory: () {},
                  onNewDirector: () {},
                  onSessionSelected: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  for (final structure in ['classic', 'glass', 'brutal', 'wonder']) {
    for (final palette in ['classic', 'bordeaux']) {
      for (final brightness in Brightness.values) {
        testWidgets(
            '$structure $palette $brightness keeps every home action reachable',
            (tester) async {
          tester.view.physicalSize = const Size(390, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            await homeHost(
              LmAppearance(structureId: structure, paletteId: palette),
              brightness,
            ),
          );
          if (Platform.environment['LMSTORY_MOTION_PREVIEW_DIR'] != null &&
              palette == 'bordeaux' &&
              brightness == Brightness.dark) {
            for (var frame = 0; frame < 24; frame++) {
              await tester.pump(const Duration(milliseconds: 50));
              await _captureMotion(tester, structure, frame);
            }
          }
          await tester.pumpAndSettle();
          for (final label in ['新建对话', '新建故事', '新导演', '设置', '继续故事']) {
            expect(find.text(label), findsOneWidget);
          }
          expect(find.text('雾港来信'), findsOneWidget);
          expect(tester.takeException(), isNull);
          expect(tester.getBottomRight(find.text('设置')).dy, lessThan(844));
          final scrollable =
              tester.state<ScrollableState>(find.byType(Scrollable));
          expect(scrollable.position.maxScrollExtent, 0);
          if (structure == 'classic' && palette == 'bordeaux') {
            await _capture(tester, 'home_${brightness.name}');
          }
        });
      }
    }
    testWidgets(
        '$structure compact home accommodates large type and three modes',
        (tester) async {
      tester.view.physicalSize = const Size(320, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        await homeHost(
          LmAppearance(structureId: structure),
          Brightness.dark,
          scale: 1.6,
        ),
      );
      await tester.pumpAndSettle();
      for (final label in ['新建对话', '新建故事', '新导演', '设置']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
      expect(tester.getBottomRight(find.text('设置')).dy, lessThan(600));
    });
  }

  testWidgets('character identity preserves long names and all original fields',
      (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const name = '👩‍🚀来自遥远星系的旅人沈青';
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: _previewTheme(
            const LmAppearance(paletteId: 'bordeaux'),
            Brightness.light,
          ),
          home: RepaintBoundary(
            key: _surfaceKey,
            child: Scaffold(
              appBar: AppBar(title: const Text('角色详情')),
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Builder(
                    builder: (context) => CharacterCardViewer(
                      colors: context.lm.palette,
                      card: const ParsedCharacterCard(
                        name: name,
                        embeddedEntries: [],
                        specVersion: 'v2',
                        nickname: '阿青',
                        age: '27',
                        creator: '海风',
                        description: '港口的记录员，习惯在雨夜整理来信。',
                        personality: '冷静、敏锐。',
                        scenario: '雾港，旧码头的雨夜。',
                        firstMes: '这封信，你是从哪里找到的？',
                        tags: ['雾港', '记录员'],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(name), findsOneWidget);
    expect(find.text('👩‍🚀'), findsOneWidget);
    expect(find.text('阿青'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'character_long_name');
  });

  testWidgets(
      'experience rail follows turn order and disappears for importance sorting',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          experienceRepositoryProvider.overrideWithValue(_ExperienceRepo()),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme: _previewTheme(
              const LmAppearance(paletteId: 'bordeaux'),
              Brightness.light,
            ),
            home: RepaintBoundary(
              key: _surfaceKey,
              child: Scaffold(
                appBar: AppBar(title: const Text('经历记忆')),
                body: const ExperienceMemoryTab(sessionId: 'story'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MemoryTimelineEntry), findsNWidgets(2));
    expect(
      tester.getTopLeft(find.text('你在旧码头收到一封来信。')).dy,
      lessThan(tester.getTopLeft(find.text('沈青认出了信封上的印记。')).dy),
    );
    expect(tester.takeException(), isNull);
    await _capture(tester, 'experience');
    await tester.tap(
      find.byTooltip(
        Translations.of(tester.element(find.byType(ExperienceMemoryTab)))
            .intermediate
            .memoryBrowser
            .sortBy,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.text(
        LocaleSettings.currentLocale.translations.intermediate.memoryBrowser
            .sortByImportance,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(MemoryTimelineEntry), findsNothing);
    expect(find.byTooltip('编辑'), findsNWidgets(2));
  });
}

Future<void> _capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['LMSTORY_VISUAL_PREVIEW_DIR'];
  if (directory == null) return;
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_surfaceKey));
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
  });
}

Future<void> _captureMotion(
  WidgetTester tester,
  String structure,
  int frame,
) async {
  final directory = Platform.environment['LMSTORY_MOTION_PREVIEW_DIR'];
  if (directory == null) return;
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_surfaceKey));
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    await Directory(directory).create(recursive: true);
    await File(
      '$directory/${structure}_home_${frame.toString().padLeft(2, '0')}.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
  });
}

ThemeData _previewTheme(LmAppearance appearance, Brightness brightness) {
  final theme = ThemeCatalog.assemble(appearance, brightness);
  return theme.copyWith(
    textTheme: theme.textTheme.apply(fontFamilyFallback: kCjkFallbackFamilies),
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
        fontFamilyFallback: kCjkFallbackFamilies,
      ),
    ),
  );
}

class _ChatRepo implements ChatRepository {
  @override
  Future<HomeSessions> getHomeSessions() async =>
      homeSessionsFixture(await getAllSessions());

  @override
  Future<List<ChatSession>> getAllSessions() async => [
        ChatSession(
          sessionId: 'story',
          title: '雾港来信',
          mode: ChatMode.advanced,
          createdAt: DateTime(2026),
          lastActiveAt: DateTime(2026, 10, 7),
          messageCount: 12,
          lastMessagePreview: '码头的灯逐盏熄灭。那封没有署名的信，仍然躺在你手中。',
        ),
        ChatSession(
          sessionId: 'chat',
          title: '一些还没说完的话',
          mode: ChatMode.chat,
          createdAt: DateTime(2026),
          lastActiveAt: DateTime(2026, 10, 6),
          messageCount: 4,
          lastMessagePreview: '关于下一次出发。',
        ),
      ];
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _PresetRepo implements ApiPresetRepository {
  @override
  Future<List<ApiPreset>> getAllPresets() async => [
        ApiPreset(
          presetId: 'p',
          name: 'configured',
          baseUrl: 'https://example.com',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      ];
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _SettingsRepo implements SettingsRepository {
  @override
  Future<String?> getApiKey(String presetId) async => 'test';
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _ExperienceRepo implements ExperienceRepository {
  @override
  Future<List<ExperientialMemory>> getAllExperiences(
    String sessionId, {
    bool includeArchived = true,
  }) async =>
      [
        ExperientialMemory(
          memoryId: 'second',
          sessionId: sessionId,
          turnNumber: 2,
          importance: 5,
          tags: const ['来信'],
          createdAt: DateTime(2026),
          summary: '沈青认出了信封上的印记。',
          narrativeTime: '雨夜',
        ),
        ExperientialMemory(
          memoryId: 'first',
          sessionId: sessionId,
          turnNumber: 1,
          importance: 3,
          tags: const ['旧码头'],
          createdAt: DateTime(2026),
          summary: '你在旧码头收到一封来信。',
        ),
      ];
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
