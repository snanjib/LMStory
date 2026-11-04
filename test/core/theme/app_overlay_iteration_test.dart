import 'dart:async';
import 'dart:convert';
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
import 'package:lmstory/core/theme/system/lm_overlays.dart';
import 'package:lmstory/core/theme/system/theme_catalog.dart';
import 'package:lmstory/features/chat/domain/entities/search_result.dart';
import 'package:lmstory/features/chat/domain/repositories/chat_repository.dart';
import 'package:lmstory/features/chat/presentation/widgets/global_search_dialog.dart';
import 'package:lmstory/features/diagnostics/domain/entities/failure_log_entry.dart';
import 'package:lmstory/features/diagnostics/domain/repositories/failure_log_repository.dart';
import 'package:lmstory/features/diagnostics/presentation/pages/diagnostics_page.dart';
import 'package:lmstory/features/resource_library/presentation/widgets/resource_content_viewer.dart';
import 'package:lmstory/features/settings/data/auto_backup_manager.dart';
import 'package:lmstory/features/settings/domain/entities/api_preset.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
import 'package:lmstory/features/settings/domain/entities/model_capability.dart';
import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';
import 'package:lmstory/features/settings/domain/services/data_management_service.dart';
import 'package:lmstory/features/settings/presentation/pages/data_management_page.dart';
import 'package:lmstory/features/settings/presentation/widgets/create_preset_sheet.dart';
import 'package:lmstory/features/settings/presentation/widgets/model_edit_dialog.dart';
import 'package:lmstory/features/settings/presentation/widgets/model_picker_dialog.dart';
import 'package:lmstory/features/templates/domain/entities/template.dart';
import 'package:lmstory/features/templates/domain/repositories/template_repository.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../test_helpers/load_app_fonts.dart';

const _previewKey = ValueKey('overlay-preview');
const _openKey = ValueKey('open-overlay');
const _longName = 'Harbor / A Writing Model With A Long Display Name';
const _model = ModelInfo(
  modelId: 'harbor/writing-studio-reasoning',
  displayName: _longName,
  capabilities: ModelCapability.values,
  contextWindow: 1048576,
  maxOutput: 65536,
);

void main() {
  setUpAll(() async {
    await LocaleSettings.setLocale(AppLocale.enUs);
    await LocaleSettings.setLocale(AppLocale.zhCn);
    await loadAppFonts(withSystemCjkFallback: true);
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  Future<_DataService> pumpHost(
    WidgetTester tester,
    String structure,
    AppLocale locale,
    void Function(BuildContext) open, {
    Size size = const Size(320, 700),
    double scale = 1.6,
    double keyboard = 0,
    Widget? page,
  }) async {
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => LocaleSettings.setLocale(locale));
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({
      'diagnostics.dev_gate_unlocked': true,
      'ui_config_level': 'advanced',
    });
    final prefs = Preferences(prefs: await SharedPreferences.getInstance());
    final dataService = _DataService();
    final theme = ThemeCatalog.assemble(
      LmAppearance(structureId: structure, paletteId: 'bordeaux'),
      locale == AppLocale.zhCn ? Brightness.light : Brightness.dark,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatRepositoryProvider.overrideWithValue(_SearchRepo()),
          preferencesProvider.overrideWithValue(prefs),
          settingsRepositoryProvider.overrideWithValue(_SettingsRepo()),
          templateRepositoryProvider.overrideWithValue(_TemplatesRepo()),
          dataManagementServiceProvider.overrideWithValue(dataService),
          autoBackupManagerProvider.overrideWithValue(_BackupManager()),
          failureLogRepositoryProvider.overrideWithValue(_FailuresRepo()),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            theme: withLoadedTestFonts(theme, withCjkFallback: true),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                viewInsets: EdgeInsets.only(bottom: keyboard),
              ),
              child: RepaintBoundary(key: _previewKey, child: child),
            ),
            home: page ??
                Scaffold(
                  body: Builder(
                    builder: (context) => TextButton(
                      key: _openKey,
                      onPressed: () => open(context),
                      child: const Text('Open'),
                    ),
                  ),
                ),
          ),
        ),
      ),
    );
    if (page == null) await tester.tap(find.byKey(_openKey));
    if (page is DataManagementPage) {
      await tester.pump();
      await _settleStorage(tester, dataService);
    }
    await tester.pumpAndSettle();
    return dataService;
  }

  for (final locale in AppLocale.values) {
    testWidgets('classic ${locale.languageCode} normal-size task surfaces',
        (tester) async {
      await pumpHost(
        tester,
        'classic',
        locale,
        (context) {
          showLmDialog<void>(
            context: context,
            builder: (_) => const ModelPickerDialog(
              fetchedModels: [_model, ModelInfo(modelId: 'harbor-chat')],
              existingModelIds: {},
            ),
          );
        },
        size: const Size(390, 844),
        scale: 1,
      );
      expect(tester.takeException(), isNull);
      await _capture(tester, 'models_${locale.languageCode}_normal');
      await pumpHost(
        tester,
        'classic',
        locale,
        (context) {
          showLmDialog<void>(
            context: context,
            builder: (_) => const ModelEditDialog(
              presetId: 'fixture',
              existingModel: _model,
            ),
          );
        },
        size: const Size(390, 844),
        scale: 1,
      );
      expect(tester.takeException(), isNull);
      await _capture(tester, 'model_edit_${locale.languageCode}_normal');
      final service = await pumpHost(
        tester,
        'classic',
        locale,
        (_) {},
        page: const DataManagementPage(),
        size: const Size(390, 844),
        scale: 1,
      );
      await _settleStorage(tester, service);
      final t = LocaleSettings.currentLocale.translations;
      await tester.scrollUntilVisible(
        find.text(t.settings.data.storageInfo.title),
        180,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _capture(tester, 'data_${locale.languageCode}_normal');
      await pumpHost(
        tester,
        'classic',
        locale,
        (_) {},
        page: const DiagnosticsPage(),
        size: const Size(390, 844),
        scale: 1,
      );
      expect(tester.takeException(), isNull);
      await _capture(tester, 'diagnostics_${locale.languageCode}_normal');
    });
  }

  for (final structure in ThemeCatalog.structures) {
    for (final locale in AppLocale.values) {
      final name = '${structure.id} ${locale.languageCode}';
      testWidgets('$name reads storage counts at large text size',
          (tester) async {
        final service = await pumpHost(
          tester,
          structure.id,
          locale,
          (_) {},
          page: const DataManagementPage(),
        );
        await _settleStorage(tester, service);
        final t = LocaleSettings.currentLocale.translations;
        await tester.scrollUntilVisible(
          find.text(t.settings.data.storageInfo.title),
          240,
        );
        await tester.pumpAndSettle();
        if (structure.id == 'classic') {
          await _capture(tester, 'data_${locale.languageCode}_large');
        }
        await tester.scrollUntilVisible(find.text('123456789'), 120);
        await tester.pumpAndSettle();
        expect(find.text('123456789'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('$name changes diagnostics level at large text size',
          (tester) async {
        await pumpHost(
          tester,
          structure.id,
          locale,
          (_) {},
          page: const DiagnosticsPage(),
        );
        if (structure.id == 'classic') {
          await _capture(tester, 'diagnostics_${locale.languageCode}_large');
        }
        final t = LocaleSettings.currentLocale.translations;
        await tester.scrollUntilVisible(
          find.text(t.settings.diagnostics.logLevel.warn),
          180,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(t.settings.diagnostics.logLevel.warn));
        await tester.pumpAndSettle();
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('log_level'), 'warn');
        expect(tester.takeException(), isNull);
      });

      testWidgets('$name selects filtered models at large text size',
          (tester) async {
        List<ModelInfo>? result;
        await pumpHost(tester, structure.id, locale, (context) async {
          result = await showLmDialog<List<ModelInfo>>(
            context: context,
            builder: (_) => const ModelPickerDialog(
              fetchedModels: [_model, ModelInfo(modelId: 'other-model')],
              existingModelIds: {},
            ),
          );
        });
        expect(tester.takeException(), isNull);
        await tester.enterText(find.byType(TextField), 'harbor');
        await tester.pumpAndSettle();
        expect(find.text('other-model'), findsNothing);
        await tester.tap(find.text(_longName));
        await tester.pumpAndSettle();
        if (structure.id == 'classic') {
          await _capture(tester, 'models_${locale.languageCode}_large');
        }
        await tester.tap(
          find.text(LocaleSettings.currentLocale.translations.common.save),
        );
        await tester.pumpAndSettle();
        expect(result?.map((m) => m.modelId), [_model.modelId]);
        expect(result?.single.capabilities, _model.capabilities);
        expect(tester.takeException(), isNull);
      });

      testWidgets('$name edits model metadata with a keyboard', (tester) async {
        ModelInfo? result;
        await pumpHost(
          tester,
          structure.id,
          locale,
          (context) async {
            result = await showLmDialog<ModelInfo>(
              context: context,
              builder: (_) => const ModelEditDialog(
                presetId: 'fixture',
                existingModel: _model,
              ),
            );
          },
          keyboard: 240,
        );
        expect(tester.takeException(), isNull);
        final fields = find.byType(TextField);
        expect(tester.widget<TextField>(fields.at(0)).enabled, isFalse);
        await tester.ensureVisible(fields.at(1));
        await tester.enterText(fields.at(1), 'Harbor revised');
        await tester.pumpAndSettle();
        await tester.ensureVisible(fields.at(2));
        await tester.enterText(fields.at(2), '131072');
        await tester.pumpAndSettle();
        if (structure.id == 'classic') {
          await _capture(tester, 'model_edit_${locale.languageCode}_keyboard');
        }
        await tester.tap(
          find.text(LocaleSettings.currentLocale.translations.common.save),
        );
        await tester.pumpAndSettle();
        expect(result?.modelId, _model.modelId);
        expect(result?.displayName, 'Harbor revised');
        expect(result?.contextWindow, 131072);
        expect(result?.maxOutput, _model.maxOutput);
        expect(result?.capabilities, _model.capabilities);
        expect(tester.takeException(), isNull);
      });

      testWidgets('$name preserves provider creation and back navigation',
          (tester) async {
        CreatePresetResult? result;
        await pumpHost(
          tester,
          structure.id,
          locale,
          (context) async {
            result = await showLmSheet<CreatePresetResult>(
              context: context,
              isScrollControlled: true,
              useSafeArea: true,
              backgroundColor: Colors.transparent,
              glassHandle: false,
              builder: (context) => Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.viewInsetsOf(context).bottom,
                ),
                child: const CreatePresetSheet(),
              ),
            );
          },
          keyboard: 240,
        );
        await tester.tap(find.text('OpenAI'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Harbor draft');
        final t = LocaleSettings.currentLocale.translations;
        await tester
            .tap(find.byTooltip(t.settings.provider.templatePicker.back));
        await tester.pumpAndSettle();
        await tester.tap(find.text('OpenAI'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller?.text,
          'OpenAI',
        );
        await tester.enterText(find.byType(TextField), 'Harbor writing');
        await tester.pumpAndSettle();
        if (structure.id == 'classic') {
          await _capture(
            tester,
            'provider_create_${locale.languageCode}_keyboard',
          );
        }
        await tester.tap(find.text(t.settings.provider.templatePicker.create));
        await tester.pumpAndSettle();
        expect(result?.name, 'Harbor writing');
        expect(result?.templateId, 'tpl-openai');
        expect(tester.takeException(), isNull);
      });

      testWidgets('$name searches scaled previews and selects by keyboard',
          (tester) async {
        SearchResult? selected;
        await pumpHost(
          tester,
          structure.id,
          locale,
          (context) {
            showLmDialog<void>(
              context: context,
              builder: (_) =>
                  GlobalSearchDialog(onResultSelected: (r) => selected = r),
            );
          },
          keyboard: 240,
        );
        await tester.enterText(find.byType(TextField), 'harbor');
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pumpAndSettle();
        expect(find.text(_longName), findsOneWidget);
        final preview = tester
            .widgetList<RichText>(find.byType(RichText))
            .where(
              (w) =>
                  w.text.toPlainText().contains('harbor') && w.text is TextSpan,
            );
        expect(preview.any((w) => w.textScaler.scale(10) == 16), isTrue);
        if (structure.id == 'classic') {
          await _capture(tester, 'search_${locale.languageCode}_keyboard');
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pumpAndSettle();
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        expect(selected?.messageId, 'second');
        expect(tester.takeException(), isNull);
      });

      testWidgets('$name reads long resource content and closes the sheet',
          (tester) async {
        final raw = jsonEncode({
          'entries': {
            for (var i = 0; i < 24; i++)
              '$i': {
                'uid': i,
                'key': ['harbor'],
                'comment': 'Harbor district $i',
                'content': 'A harbor street where the story continues. ' * 12,
              },
          },
        });
        await pumpHost(tester, structure.id, locale, (context) {
          showBookContentSheet(context, name: _longName, rawJson: raw);
        });
        expect(find.text(_longName), findsOneWidget);
        expect(find.text('Harbor district 0'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (structure.id == 'classic') {
          await _capture(tester, 'resource_${locale.languageCode}_large');
        }
        final t = LocaleSettings.currentLocale.translations;
        await tester.tap(find.byTooltip(t.common.close));
        await tester.pumpAndSettle();
        expect(find.text(_longName), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('${structure.id} constrains model edit on a desktop',
        (tester) async {
      await pumpHost(
        tester,
        structure.id,
        AppLocale.zhCn,
        (context) {
          showLmDialog<void>(
            context: context,
            builder: (_) => const ModelEditDialog(
              presetId: 'fixture',
              existingModel: _model,
            ),
          );
        },
        size: const Size(1440, 900),
        scale: 1,
      );
      final dialog = tester.widget<Dialog>(find.byType(Dialog));
      expect(
        tester.getSize(find.byWidget(dialog.child!)).width,
        lessThanOrEqualTo(LmLayout.dialogNarrowWidth),
      );
      expect(tester.takeException(), isNull);
    });
  }
}

Future<void> _settleStorage(WidgetTester tester, _DataService service) async {
  // Native directory lookup needs real time and fake-clock microtasks to settle.
  for (var attempt = 0;
      attempt < 100 && !service.statsLoaded.isCompleted;
      attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  expect(service.statsLoaded.isCompleted, isTrue);
}

Future<void> _capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['LMSTORY_VISUAL_PREVIEW_DIR'];
  if (directory == null) return;
  final boundary =
      tester.renderObject<RenderRepaintBoundary>(find.byKey(_previewKey));
  await tester.runAsync(() async {
    final rendered = await boundary.toImage();
    final bytes = await rendered.toByteData(format: ui.ImageByteFormat.png);
    rendered.dispose();
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
  });
}

class _SearchRepo implements ChatRepository {
  @override
  Future<List<SearchResult>> searchMessages(String query) async => [
        for (final id in ['first', 'second'])
          SearchResult(
            sessionId: 'fixture',
            sessionName: _longName,
            messageId: id,
            content:
                'The harbor is still waiting. Another chapter starts here.',
            role: 'assistant',
            createdAt: DateTime(2026, 10, 8),
          ),
      ];

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _SettingsRepo implements SettingsRepository {
  @override
  Future<Map<String, dynamic>> getUserOverrides() async => {};
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _TemplatesRepo implements TemplateRepository {
  @override
  Future<List<Template>> getAllTemplates() async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _DataService implements DataManagementService {
  final statsLoaded = Completer<void>();
  @override
  Future<StorageStats> getStorageStats({
    required int dbSizeBytes,
    int templateCount = 0,
  }) async {
    if (!statsLoaded.isCompleted) statsLoaded.complete();
    return const StorageStats(
      dbSizeBytes: 123456789,
      sessionCount: 1234,
      messageCount: 123456789,
      presetCount: 12,
      templateCount: 34,
      preferenceCount: 56,
      agentEventCount: 54321,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _BackupManager implements AutoBackupManager {
  @override
  Future<bool> isEnabled() async => false;
  @override
  Future<List<File>> listBackups() async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _FailuresRepo implements FailureLogRepository {
  @override
  Future<List<FailureLogEntry>> getRecentLogs({
    int limit = 50,
    String? mode,
    String? sessionId,
  }) async =>
      [];
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
