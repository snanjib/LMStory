import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lmstory/core/storage/native_database_paths.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/demo/data/demo_preferences.dart';
import 'package:lmstory/features/settings/data/database_startup_recovery.dart';
import 'package:lmstory/features/settings/data/database_startup_recovery_native.dart';
import 'package:path/path.dart' as p;
// Drift supplies the raw SQLite engine used to construct file fixtures.
// ignore: depend_on_referenced_packages
import 'package:sqlite3/sqlite3.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory documents;
  late File original;
  late NativeDatabaseStartupRecovery recovery;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('lmstory-open-fixture-');
    original = originalNativeDatabase(documents);
    recovery = NativeDatabaseStartupRecovery(
      DemoPreferences(),
      documentsDirectory: () async => documents,
    );
    addTearDown(() => documents.delete(recursive: true));
  });

  for (final withWal in [false, true]) {
    test(
        'failed migration preserves the existing SQLite file set (WAL=$withWal)',
        () async {
      final source = File(p.join(documents.path, 'fixture.db'));
      final writer = sqlite3.open(source.path);
      final suffixes = [
        '',
        if (withWal) ...['-wal', '-shm'],
      ];
      try {
        writer
          ..execute('CREATE VIEW chat_sessions AS SELECT 1 AS placeholder')
          ..execute('PRAGMA user_version = 54');
        if (withWal) {
          writer
            ..execute('PRAGMA journal_mode = WAL')
            ..execute('PRAGMA wal_autocheckpoint = 0')
            ..execute('CREATE TABLE retained_fixture (value TEXT)')
            ..execute("INSERT INTO retained_fixture VALUES ('in the WAL')");
        }
        for (final suffix in suffixes) {
          await File('${source.path}$suffix').copy('${original.path}$suffix');
        }
      } finally {
        writer.close();
      }

      final before = {
        for (final suffix in suffixes)
          suffix: await File('${original.path}$suffix').readAsBytes(),
      };
      final failure = await _failedOpen(recovery);
      expect(failure.databasePath, original.path);
      expect(failure.preservationFailed, isFalse);
      final preservedPath = failure.preservedDatabasePaths.single;
      expect(preservedPath, isNot(original.path));
      // A fresh instance must still find the files captured before the first
      // failure, even after SQLite has had a chance to change the active set.
      final retry = await _failedOpen(
        NativeDatabaseStartupRecovery(
          DemoPreferences(),
          documentsDirectory: () async => documents,
        ),
      );
      expect(retry.preservedDatabasePaths, hasLength(2));
      expect(retry.preservedDatabasePaths.last, preservedPath);
      expect(retry.preservedDatabasePath, isNot(preservedPath));
      for (final entry in before.entries) {
        final protected = File('$preservedPath${entry.key}');
        expect(await protected.readAsBytes(), entry.value);
      }
      if (withWal) {
        // Inspect a derivative to keep the preserved SQLite files untouched.
        final readback = p.join(documents.path, 'readback.db');
        for (final suffix in suffixes) {
          await File('$preservedPath$suffix').copy('$readback$suffix');
        }
        final reader = sqlite3.open(readback);
        try {
          expect(
            reader.select('SELECT value FROM retained_fixture').single['value'],
            'in the WAL',
          );
        } finally {
          reader.close();
        }
      }
    });
  }

  test('an internally corrupt SQLite file keeps its bytes after failed open',
      () async {
    final writer = sqlite3.open(original.path);
    try {
      writer.execute('CREATE TABLE synthetic (value TEXT)');
    } finally {
      writer.close();
    }
    final bytes = await original.readAsBytes();
    // Corrupt the first B-tree page after the 100-byte SQLite file header.
    bytes[100] = 0xff;
    await original.writeAsBytes(bytes);
    final failure = await _failedOpen(recovery);
    final preservedPath = failure.preservedDatabasePaths.single;
    expect(await File(preservedPath).readAsBytes(), bytes);
  });

  test('failed startup leaves an existing SQLite writer able to commit',
      () async {
    final writer = sqlite3.open(original.path);
    try {
      writer
        ..execute('CREATE TABLE synthetic (value TEXT)')
        ..execute('BEGIN EXCLUSIVE');
      final failure = await _failedOpen(recovery);
      expect(failure.preservedDatabasePaths, isNotEmpty);
      writer
        ..execute("INSERT INTO synthetic VALUES ('after failed startup')")
        ..execute('COMMIT');
    } finally {
      writer.close();
    }
    final reader = sqlite3.open(original.path);
    try {
      expect(
        reader.select('SELECT value FROM synthetic').single['value'],
        'after failed startup',
      );
    } finally {
      reader.close();
    }
  });

  test('a failed copy reports a storage problem and can retry unchanged',
      () async {
    final seed = AppDatabase.connect(NativeDatabase(original));
    try {
      await seed.into(seed.chatSessionsTable).insert(
            ChatSessionsTableCompanion.insert(
              sessionId: 'keep-after-retry',
              title: 'Synthetic story',
            ),
          );
    } finally {
      await seed.close();
    }
    final before = await original.readAsBytes();
    final obstruction = await Directory('${original.path}-wal').create();
    final failure = await _failedOpen(recovery);
    expect(failure.databasePath, original.path);
    expect(failure.preservationFailed, isTrue);
    expect(failure.preservedDatabasePaths, isEmpty);
    expect(await original.readAsBytes(), before);
    _expectNoOpeningCopy(documents);
    await obstruction.delete();

    final reopened = await recovery.open();
    try {
      final db = reopened.database;
      expect(
        (await db.select(db.chatSessionsTable).getSingle()).sessionId,
        'keep-after-retry',
      );
      _expectNoOpeningCopy(documents);
    } finally {
      await reopened.database.close();
    }
  });

  test('fresh startup opens the usual path without a retained opening copy',
      () async {
    final opened = await recovery.open();
    try {
      expect(
        await opened.database.select(opened.database.chatSessionsTable).get(),
        isEmpty,
      );
      expect(original.existsSync(), isTrue);
      _expectNoOpeningCopy(documents);
    } finally {
      await opened.database.close();
    }
  });

  for (final version in [54, AppDatabase.currentSchemaVersion]) {
    test('an existing v$version database opens at its original path', () async {
      final seed = AppDatabase.connect(NativeDatabase(original));
      try {
        await seed.into(seed.chatSessionsTable).insert(
              ChatSessionsTableCompanion.insert(
                sessionId: 'keep-existing',
                title: 'Existing synthetic story',
              ),
            );
        await seed.customStatement('PRAGMA user_version = $version');
      } finally {
        await seed.close();
      }
      final opened = await recovery.open();
      try {
        final db = opened.database;
        expect(
          (await db.select(db.chatSessionsTable).getSingle()).sessionId,
          'keep-existing',
        );
        expect(
          (await db.customSelect('PRAGMA user_version').getSingle())
              .data
              .values
              .single,
          AppDatabase.currentSchemaVersion,
        );
        final (activeFile, recoveredId) = await activeNativeDatabase(documents);
        expect(activeFile.path, original.path);
        expect(recoveredId, isNull);
        _expectNoOpeningCopy(documents);
      } finally {
        await opened.database.close();
      }
    });
  }
}

Future<DatabaseOpenFailure> _failedOpen(
  NativeDatabaseStartupRecovery recovery,
) async {
  try {
    final unexpected = await recovery.open();
    await unexpected.database.close();
  } on DatabaseOpenFailure catch (failure) {
    return failure;
  }
  fail('Expected a failed database open');
}

void _expectNoOpeningCopy(Directory documents) {
  expect(
    documents.listSync().map((entry) => p.basename(entry.path)),
    isNot(
      contains(
        anyOf(
          startsWith('.lmstory-opening-'),
          startsWith('lmstory-preserved-'),
        ),
      ),
    ),
  );
}
