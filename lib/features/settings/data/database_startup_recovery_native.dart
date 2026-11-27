import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lmstory/core/di/providers.dart';
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/chat/data/database/database_connection.dart';
import 'package:lmstory/features/demo/data/demo_preferences.dart';
import 'package:lmstory/features/demo/data/demo_secure_storage.dart';
import 'package:lmstory/features/settings/data/auto_backup_manager.dart';
import 'package:lmstory/features/settings/data/database_open_snapshot.dart';
import 'package:lmstory/features/settings/data/database_startup_recovery.dart';
import 'package:lmstory/features/settings/data/repositories/settings_repository_impl.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
import 'package:lmstory/features/settings/domain/services/data_management_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

DatabaseStartupRecovery createStartupDatabaseRecovery(
  Preferences preferences,
) =>
    NativeDatabaseStartupRecovery(preferences);

class NativeDatabaseStartupRecovery implements DatabaseStartupRecovery {
  NativeDatabaseStartupRecovery(
    this._preferences, {
    Future<Directory> Function()? documentsDirectory,
  }) : _documentsDirectory =
            documentsDirectory ?? getApplicationDocumentsDirectory;

  static const _log = Logger('DatabaseStartup');
  static const _overridesKey = SettingsRepositoryImpl.userOverridesPrefKey;
  static const _corruptOverridesKey =
      SettingsRepositoryImpl.corruptOverridesBackupPrefKey;

  final Preferences _preferences;
  final Future<Directory> Function() _documentsDirectory;

  @override
  bool get supportsActivation => true;

  Preferences _preferencesFor(String? id) {
    if (id == null) return _preferences;
    return _preferences.withKeyAliases({
      _overridesKey: 'database_recovery.$id.$_overridesKey',
      _corruptOverridesKey: 'database_recovery.$id.$_corruptOverridesKey',
    });
  }

  @override
  Future<OpenedDatabase> open() async {
    File? attemptedFile;
    DatabaseOpenSnapshot? snapshot;
    var preservationFailed = false;
    try {
      final documents = await _documentsDirectory();
      attemptedFile = originalNativeDatabase(documents);
      final (file, id) = await activeNativeDatabase(documents);
      attemptedFile = file;
      await validateNativeDatabaseHeader(file);
      try {
        snapshot = await DatabaseOpenSnapshot.capture(file);
      } on FileSystemException {
        preservationFailed = true;
        rethrow;
      }
      final database = await _openFile(file);
      await snapshot?.discard();
      return OpenedDatabase(database, _preferencesFor(id));
    } on Object catch (error) {
      _log.warn(
        preservationFailed
            ? 'Could not preserve database before opening'
            : 'Failed to open database',
        detail: error.runtimeType.toString(),
      );
      final reportedPath = !preservationFailed && error is FileSystemException
          ? error.path
          : null;
      final original =
          reportedPath == null ? attemptedFile : File(reportedPath);
      final preserved = <String>[];
      if (original != null) {
        final current = snapshot?.pathFor(original);
        if (current != null) preserved.add(current);
        final earlier = await DatabaseOpenSnapshot.preservedPaths(original);
        preserved.addAll(earlier.where((path) => path != current));
      }
      throw DatabaseOpenFailure(
        databasePath: original?.path,
        preservedDatabasePaths: preserved,
        preservationFailed: preservationFailed,
      );
    }
  }

  @override
  Future<List<RecoveryBackup>> listBackups() async {
    final documents = await _documentsDirectory();
    final dir =
        Directory(p.join(documents.path, AutoBackupManager.directoryName));
    if (!dir.existsSync()) return const [];
    final backups = <RecoveryBackup>[];
    await for (final file in dir.list(followLinks: false)) {
      if (file is! File || p.extension(file.path) != '.json') continue;
      final name = p.basename(file.path);
      final RecoveryBackupSource source;
      if (name.startsWith(AutoBackupManager.fileNamePrefix)) {
        source = RecoveryBackupSource.automatic;
      } else if (name.startsWith(AutoBackupManager.preImportFileNamePrefix)) {
        source = RecoveryBackupSource.preImport;
      } else {
        continue;
      }
      final stat = file.statSync();
      if (stat.type != FileSystemEntityType.file) continue;
      backups.add(
        RecoveryBackup(
          name: name,
          source: source,
          read: file.readAsString,
          modifiedAt: stat.modified,
        ),
      );
    }
    return backups
      ..sort(
        (a, b) => (b.modifiedAt?.millisecondsSinceEpoch ?? 0)
            .compareTo(a.modifiedAt?.millisecondsSinceEpoch ?? 0),
      );
  }

  @override
  Future<PreparedDatabaseRecovery> prepare(String backup) async {
    DataManagementService.inspectRecoveryBackup(backup);
    final documents = await _documentsDirectory();
    final root = Directory(p.join(documents.path, recoveryDirectoryName));
    final id = const Uuid().v4();
    final trial =
        await Directory(p.join(root.path, id)).create(recursive: true);
    try {
      final file = recoveredNativeDatabase(trial);
      final (result, settings) = await _restoreAndVerify(file, backup);
      return _NativePreparedRecovery(
        trial,
        result,
        () => _activate(root, id, file, settings),
      );
    } on Object {
      await _discardTrial(trial);
      rethrow;
    }
  }

  Future<AppDatabase> _openFile(File file) async {
    AppDatabase? db;
    try {
      db = AppDatabase.connect(await openNativeDatabase(file));
      await probeStartupDatabase(db);
      return db;
    } on Object {
      if (db != null) await closeStartupDatabase(db);
      rethrow;
    }
  }

  Future<(ImportResult, String?)> _restoreAndVerify(
    File file,
    String backup,
  ) async {
    final database = await _openFile(file);
    final isolatedPreferences = DemoPreferences();
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWithValue(database),
        preferencesProvider.overrideWithValue(isolatedPreferences),
        secureStorageProvider.overrideWithValue(DemoSecureStorage()),
      ],
    );
    try {
      final service = container.read(dataManagementServiceProvider);
      final result = await service.importRecoveryTrial(backup);
      if (result.importedSessions +
              result.importedPresets +
              result.importedPreferences +
              result.importedAssets ==
          0) {
        throw const BackupNoRestorableDataException();
      }
      final rows = await database.customSelect('PRAGMA quick_check').get();
      if (rows.length != 1 || rows.single.data.values.single != 'ok') {
        throw StateError('Temporary database failed integrity check');
      }
      await service.verifyRecoveryReadback(backup);
      final sessions = await service.chatRepository.getAllSessions();
      final messages = await service.chatRepository.getTotalMessageCount();
      final presets = await service.presetRepository.getAllPresets();
      final overrides = await service.settingsRepository.getUserOverrides();
      final assets = await service.backupRepository.exportGlobalAssets();
      final assetCount =
          assets.values.fold(0, (sum, rows) => sum + rows.length);
      if (sessions.length != result.importedSessions ||
          messages != result.importedMessages ||
          presets.length != result.importedPresets ||
          overrides.length != result.importedPreferences ||
          assetCount < result.importedAssets) {
        throw StateError(
          'Temporary database contents did not match the import',
        );
      }
      return (result, await isolatedPreferences.getString(_overridesKey));
    } finally {
      container.dispose();
      // Closing checkpoints the isolated database before it can be activated.
      await database.close();
    }
  }

  Future<OpenedDatabase> _activate(
    Directory root,
    String id,
    File file,
    String? restoredOverrides,
  ) async {
    if (!file.existsSync()) {
      throw const FileSystemException('Prepared database is missing');
    }
    final db = await _openFile(file);
    final prefs = _preferencesFor(id);
    final pending = File(p.join(root.path, '$id.active.tmp'));
    try {
      // An omitted preferences domain carries over the current overrides.
      final overrides = restoredOverrides ?? await _previousOverrides(root);
      if (overrides != null) {
        if (!await prefs.setString(_overridesKey, overrides)) {
          throw StateError('Could not save recovered preferences');
        }
        await prefs.reload();
        if (await prefs.getString(_overridesKey) != overrides) {
          throw StateError('Recovered preferences could not be read back');
        }
      }
      await pending.writeAsString(id, flush: true);
      await pending.rename(p.join(root.path, activeRecoveryFileName));
      return OpenedDatabase(db, prefs);
    } on Object {
      await closeStartupDatabase(db);
      rethrow;
    }
  }

  Future<String?> _previousOverrides(Directory root) async {
    String? previousId;
    try {
      previousId = await activeNativeRecoveryId(root.parent);
    } on FormatException {
      // An invalid activation record has no preference namespace to carry over.
    }
    final active = _preferencesFor(previousId);
    await active.reload();
    return active.getString(_overridesKey);
  }
}

class _NativePreparedRecovery implements PreparedDatabaseRecovery {
  _NativePreparedRecovery(this._trial, this.result, this._activate);

  final Directory _trial;
  final Future<OpenedDatabase> Function() _activate;
  Future<OpenedDatabase>? _activation;
  bool _activated = false;
  bool _discarded = false;

  @override
  final ImportResult result;

  @override
  Future<OpenedDatabase> activate() async {
    if (_discarded || _activated || _activation != null) {
      throw StateError('Recovery trial is not available for activation');
    }
    final activation = _activation = _activate();
    try {
      final opened = await activation;
      _activated = true;
      return opened;
    } finally {
      _activation = null;
    }
  }

  @override
  Future<void> discard() async {
    if (_discarded) return;
    _discarded = true;
    try {
      await _activation;
    } on Object {
      // Failed activation leaves an isolated trial that can be discarded.
    }
    if (!_activated) await _discardTrial(_trial);
  }
}

Future<void> _discardTrial(Directory trial) async {
  try {
    await trial.delete(recursive: true);
  } on FileSystemException catch (error) {
    const Logger('DatabaseStartup').warn(
      'Failed to discard recovery trial',
      detail: error.runtimeType.toString(),
    );
  }
}
