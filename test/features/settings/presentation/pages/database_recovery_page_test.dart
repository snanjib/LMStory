import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/utils/db_storage_info.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/database/database_connection.dart';
import 'package:lmstory/features/demo/data/demo_preferences.dart';
import 'package:lmstory/features/demo/data/demo_secure_storage.dart';
import 'package:lmstory/features/settings/data/auto_backup_manager.dart';
import 'package:lmstory/features/settings/data/database_startup_recovery.dart';
import 'package:lmstory/features/settings/data/database_startup_recovery_native.dart';
import 'package:lmstory/features/settings/data/repositories/settings_repository_impl.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
import 'package:lmstory/features/settings/presentation/pages/database_recovery_page.dart';
import 'package:lmstory/i18n/strings.g.dart';
import 'package:lmstory/main.dart';
import 'package:path/path.dart' as p;
// Inject the documents directory without touching the host application data.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _sessionId = 'recovery-session';
const _messageId = 'recovery-message';
const _presetId = 'recovery-provider';
const _cardId = 'recovery-card';
const _cardJson = '{"name":"Synthetic card","description":"Fixture only"}';
const _factId = 'recovery-fact';
const _factName = 'Synthetic location';
const _experienceId = 'recovery-experience';
const _summary = 'Synthetic scene summary';
const _body = 'Synthetic scene preserved by recovery';
const _settingKey = 'intermediate.generation.temperature';
const _overridesKey = SettingsRepositoryImpl.userOverridesPrefKey;
const _oldOverrides = '{"intermediate.generation.temperature":0.2}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory documents;
  late PathProviderPlatform previousPaths;
  late Preferences prefs;
  late List<File> originalFiles;
  late List<List<int>> originalBytes;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('lmstory-recovery-test-');
    previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TestPaths(documents.path);
    SharedPreferences.setMockInitialValues({
      localePrefKey: 'en-US',
      _overridesKey: _oldOverrides,
    });
    FlutterSecureStorage.setMockInitialValues({});
    prefs = Preferences();
    final original = originalNativeDatabase(documents);
    originalFiles = [
      original,
      File('${original.path}-wal'),
      File('${original.path}-shm'),
    ];
    for (var i = 0; i < originalFiles.length; i++) {
      await originalFiles[i].writeAsString('synthetic damaged SQLite file $i');
    }
    originalBytes =
        await Future.wait(originalFiles.map((f) => f.readAsBytes()));
  });

  tearDown(() async {
    PathProviderPlatform.instance = previousPaths;
    await documents.delete(recursive: true);
  });

  Future<void> expectOriginal() async {
    for (var i = 0; i < originalFiles.length; i++) {
      expect(await originalFiles[i].readAsBytes(), originalBytes[i]);
    }
    expect(await prefs.getString(_overridesKey), _oldOverrides);
  }

  testWidgets('native startup can retry with an empty backup catalog', (
    tester,
  ) async {
    final startup = await tester.runAsync(() => buildStartupApplication(prefs));
    await tester.pumpWidget(startup ?? fail('Startup widget missing'));
    final strings = t.settings.data.startupRecovery;
    await _waitFor(
      tester,
      find.text(t.settings.data.autoBackup.nothingToRestore),
    );
    expect(find.byType(DatabaseRecoveryPage), findsOneWidget);
    expect(find.text(strings.chooseFile), findsOneWidget);
    final picker = _TestPicker();
    FilePicker.platform = picker;
    await tester.tap(find.text(strings.chooseFile));
    await tester.pump();
    expect(picker.calls, 1);
    expect(find.text(strings.useBackup), findsNothing);
    await tester.tap(find.text(strings.retryOpen));
    await _waitFor(tester, find.text(strings.openFailed));
    expect(find.byType(MyApp), findsNothing);
    await tester.runAsync(expectOriginal);
  });

  test('a missing main file does not initialize over surviving sidecars',
      () async {
    await originalFiles.first.delete();
    await expectLater(
      createStartupDatabaseRecovery(prefs).open(),
      throwsA(isA<DatabaseOpenFailure>()),
    );
    expect(originalFiles.first.existsSync(), isFalse);
    for (var i = 1; i < originalFiles.length; i++) {
      expect(await originalFiles[i].readAsBytes(), originalBytes[i]);
    }
  });

  testWidgets('reports the preserved file set after a writable open fails',
      (tester) async {
    final file = originalFiles.first;
    final bytes = await tester.runAsync(() async {
      for (final original in originalFiles) {
        await original.delete();
      }
      final seed = AppDatabase.connect(NativeDatabase(file));
      try {
        await seed.customSelect('SELECT id FROM chat_sessions LIMIT 1').get();
      } finally {
        await seed.close();
      }
      final buffer = await file.readAsBytes();
      buffer[100] = 0xff;
      await file.writeAsBytes(buffer);
      return buffer;
    });
    final startup = await tester.runAsync(() => buildStartupApplication(prefs));
    await tester.pumpWidget(startup ?? fail('Startup widget missing'));
    final strings = t.settings.data.startupRecovery;
    await _waitFor(tester, find.text(strings.openFailed));
    final page = tester.widget<DatabaseRecoveryPage>(
      find.byType(DatabaseRecoveryPage),
    );
    final preserved = page.failure.preservedDatabasePaths.single;
    expect(
      find.text(strings.originalLocation(path: file.path)),
      findsOneWidget,
    );
    expect(
      find.text(strings.preservedLocation(path: preserved)),
      findsOneWidget,
    );
    expect(
      await tester.runAsync(() => File(preserved).readAsBytes()),
      bytes,
    );
  });

  testWidgets(
      'native startup checks backups, preserves files and activates '
      'only after confirmation', (tester) async {
    tester.view
      ..devicePixelRatio = 1
      ..physicalSize = const Size(900, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final root = Directory(p.join(documents.path, recoveryDirectoryName));
    final marker = File(p.join(root.path, activeRecoveryFileName));
    final obstruction = Directory(marker.path);
    const validName =
        '${AutoBackupManager.preImportFileNamePrefix}fixture.json';
    const brokenName = '${AutoBackupManager.fileNamePrefix}broken.json';
    const newerName = '${AutoBackupManager.fileNamePrefix}newer.json';
    const incompleteName =
        '${AutoBackupManager.fileNamePrefix}missing-fact.json';
    final content = await tester.runAsync(_makeBackup);
    final validSource = await tester.runAsync(() async {
      final catalog = await Directory(
        p.join(documents.path, AutoBackupManager.directoryName),
      ).create();
      final valid = await File(p.join(catalog.path, validName))
          .writeAsString(content ?? fail('Missing synthetic backup'));
      await File(p.join(catalog.path, brokenName)).writeAsString('{');
      await File(p.join(catalog.path, newerName)).writeAsString(
        '{"version":900,"sessions":[]}',
      );
      final incomplete = jsonDecode(content) as Map<String, dynamic>;
      final sessions = incomplete['sessions'] as List<dynamic>;
      final story = sessions.single as Map<String, dynamic>;
      final facts = story['factualEntities'] as List<dynamic>;
      (facts.single as Map<String, dynamic>).remove('primary_name');
      await File(p.join(catalog.path, incompleteName))
          .writeAsString(jsonEncode(incomplete));
      return valid;
    });
    final source = validSource ?? fail('Backup fixture missing');
    final picker = _TestPicker(path: source.path);
    FilePicker.platform = picker;

    final startup = await tester.runAsync(() => buildStartupApplication(prefs));
    await tester.pumpWidget(startup ?? fail('Startup widget missing'));
    final strings = t.settings.data.startupRecovery;

    await _waitFor(tester, find.text(brokenName));
    expect(
      find.text(strings.originalLocation(path: originalFiles.first.path)),
      findsOneWidget,
    );
    await _tap(tester, find.text(brokenName));
    await _waitFor(tester, find.text(strings.invalidBackup));
    expect(find.text(strings.useBackup), findsNothing);
    await _tap(tester, find.text(newerName));
    await _waitFor(
      tester,
      find.text(t.settings.data.repairSchema.importVersionTooNew(version: 900)),
    );
    expect(find.text(strings.useBackup), findsNothing);
    await _tap(tester, find.text(incompleteName));
    await _waitFor(tester, find.text(strings.invalidBackup));
    expect(find.text(strings.useBackup), findsNothing);

    await _tap(
      tester,
      find.ancestor(
        of: find.text(strings.chooseFile),
        matching: find.byWidgetPredicate(
          (widget) => widget is FilledButton && widget.onPressed != null,
        ),
      ),
    );
    expect(picker.calls, 1);
    await _waitFor(tester, find.text(strings.trialReady));
    expect(find.text(strings.selectedFile), findsOneWidget);
    expect(
      find.text(
        strings.summary(
          sessions: 1,
          messages: 1,
          presets: 1,
          preferences: 1,
          assets: 1,
        ),
      ),
      findsOneWidget,
    );
    await tester.runAsync(() async {
      await expectOriginal();
      expect(marker.existsSync(), isFalse);
    });

    await _tap(tester, find.text(strings.useBackup));
    await _waitFor(tester, find.text(strings.confirmTitle));
    await _tap(
      tester,
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(t.common.cancel),
      ),
    );
    await _waitFor(tester, find.text(strings.useBackup));
    await _tap(tester, find.text(t.common.cancel));
    await _waitFor(tester, find.text(validName));
    expect(find.text(strings.trialReady), findsNothing);

    await _tap(
      tester,
      find.ancestor(
        of: find.text(validName),
        matching: find.byWidgetPredicate(
          (widget) => widget is ListTile && widget.onTap != null,
        ),
      ),
    );
    await _waitFor(tester, find.text(strings.trialReady));
    await tester.runAsync(obstruction.create);
    await _tap(tester, find.text(strings.useBackup));
    await _waitFor(tester, find.text(strings.confirmTitle));
    await _tap(tester, find.text(strings.activate));
    await _waitFor(tester, find.text(strings.activationFailed));
    expect(find.byType(MyApp), findsNothing);
    await tester.runAsync(() async {
      await expectOriginal();
      expect(marker.existsSync(), isFalse);
      expect(await source.readAsString(), content);
      await obstruction.delete();
    });

    await _tap(tester, find.text(strings.useBackup));
    await _waitFor(tester, find.text(strings.confirmTitle));
    await _tap(tester, find.text(strings.activate));
    await _waitFor(tester, find.byType(MyApp));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MyApp)),
    );
    await tester.runAsync(() async {
      final activeDb = container.read(appDatabaseProvider);
      final chat = container.read(chatRepositoryProvider);
      expect((await chat.getMessages(_sessionId)).single.content, _body);
      expect((await chat.getSession(_sessionId)).presetId, _presetId);
      final assets = await activeDb.select(activeDb.characterCardsTable).get();
      expect(assets.single.cardId, _cardId);
      expect(assets.single.rawJson, _cardJson);
      final fact =
          await activeDb.select(activeDb.factualEntitiesTable).getSingle();
      expect(
        (fact.entityId, fact.sessionId, fact.primaryName),
        (_factId, _sessionId, _factName),
      );
      final history =
          await activeDb.select(activeDb.factualMemoryHistoryTable).getSingle();
      expect((history.entityId, history.newValue), (_factId, _factName));
      final memory =
          await activeDb.select(activeDb.experientialMemoriesTable).getSingle();
      expect(
        (memory.memoryId, memory.sessionId, memory.summary),
        (_experienceId, _sessionId, _summary),
      );
      final saved =
          await container.read(settingsRepositoryProvider).getUserOverrides();
      expect(saved[_settingKey], 0.9);
      await expectOriginal();
      expect(await source.readAsString(), content);
      final (databaseFile, activeId) = await activeNativeDatabase(documents);
      expect(databaseFile.path, isNot(originalFiles.first.path));
      expect(activeId, isNotNull);
      final activeFiles = [
        databaseFile,
        File('${databaseFile.path}-wal'),
        File('${databaseFile.path}-shm'),
      ];
      expect(
        await getDatabaseFileSize(),
        activeFiles
            .where((file) => file.existsSync())
            .fold<int>(0, (sum, file) => sum + file.lengthSync()),
      );
      final reopened = AppDatabase();
      try {
        final row =
            await reopened.select(reopened.chatMessagesTable).getSingle();
        expect(row.messageId, _messageId);
        expect(row.content, _body);
      } finally {
        await reopened.close();
      }
    });
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}

Future<String> _makeBackup() async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final prefs = DemoPreferences();
  final secure = DemoSecureStorage();
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWithValue(db),
      preferencesProvider.overrideWithValue(prefs),
      secureStorageProvider.overrideWithValue(secure),
    ],
  );
  try {
    await db.into(db.chatSessionsTable).insert(
          ChatSessionsTableCompanion.insert(
            sessionId: _sessionId,
            title: 'Synthetic recovered story',
            presetId: const Value(_presetId),
            messageCount: const Value(1),
          ),
        );
    await db.into(db.chatMessagesTable).insert(
          ChatMessagesTableCompanion.insert(
            messageId: _messageId,
            sessionId: _sessionId,
            role: 'assistant',
            content: const Value(_body),
          ),
        );
    await db.into(db.characterCardsTable).insert(
          CharacterCardsTableCompanion.insert(
            cardId: _cardId,
            name: 'Synthetic card',
            rawJson: _cardJson,
          ),
        );
    await db.into(db.apiPresetsTable).insert(
          ApiPresetsTableCompanion.insert(
            presetId: _presetId,
            name: 'Synthetic provider',
          ),
        );
    await db.into(db.factualEntitiesTable).insert(
          FactualEntitiesTableCompanion.insert(
            entityId: _factId,
            sessionId: _sessionId,
            type: 'location',
            primaryName: _factName,
            createdTurn: 1,
          ),
        );
    await db.into(db.factualMemoryHistoryTable).insert(
          FactualMemoryHistoryTableCompanion.insert(
            entityId: _factId,
            action: 'create_entity',
            newValue: const Value(_factName),
            turnNumber: 1,
          ),
        );
    await db.into(db.experientialMemoriesTable).insert(
          ExperientialMemoriesTableCompanion.insert(
            memoryId: _experienceId,
            sessionId: _sessionId,
            summary: _summary,
            turnNumber: 1,
          ),
        );
    await prefs.setString(_overridesKey, jsonEncode({_settingKey: 0.9}));
    return await container.read(dataManagementServiceProvider).exportFullBackup(
          const DataExportOptions(
            includePresets: true,
            includeSessions: true,
            includePreferences: true,
          ),
        );
  } finally {
    container.dispose();
    await db.close();
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _waitFor(tester, finder);
  await tester.ensureVisible(finder.first);
  await tester.pump();
  // Native file and Drift isolate operations started by the gesture use real
  // I/O, so dispatch the tap outside the widget test's fake clock.
  await tester.runAsync(() => tester.tap(finder.first));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _waitFor(WidgetTester tester, Finder expected) async {
  for (var attempt = 0; attempt < 160; attempt++) {
    await tester.pump(const Duration(milliseconds: 25));
    if (expected.evaluate().isNotEmpty) return;
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
  }
  expect(expected, findsAtLeastNWidgets(1));
}

class _TestPaths extends PathProviderPlatform {
  _TestPaths(this.path);

  final String path;

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

class _TestPicker extends FilePicker {
  _TestPicker({this.path});

  final String? path;
  int calls = 0;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    calls++;
    final file = path;
    return file == null
        ? null
        : FilePickerResult(
            [PlatformFile(name: p.basename(file), size: 0, path: file)],
          );
  }
}
