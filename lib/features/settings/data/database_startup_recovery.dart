import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';

enum RecoveryBackupSource { automatic, preImport, selectedFile }

class RecoveryBackup {
  const RecoveryBackup({
    required this.name,
    required this.source,
    required this.read,
    this.modifiedAt,
  });

  final String name;
  final RecoveryBackupSource source;
  final Future<String> Function() read;
  final DateTime? modifiedAt;
}

class OpenedDatabase {
  const OpenedDatabase(this.database, this.preferences);

  final AppDatabase database;
  final Preferences preferences;
}

class DatabaseOpenFailure implements Exception {
  const DatabaseOpenFailure({
    this.databasePath,
    this.preservedDatabasePaths = const [],
    this.preservationFailed = false,
  });

  final String? databasePath;
  final List<String> preservedDatabasePaths;
  final bool preservationFailed;

  String? get preservedDatabasePath =>
      preservedDatabasePaths.isEmpty ? null : preservedDatabasePaths.first;
}

abstract interface class DatabaseStartupRecovery {
  bool get supportsActivation;

  Future<OpenedDatabase> open();
  Future<List<RecoveryBackup>> listBackups();
  Future<PreparedDatabaseRecovery> prepare(String backup);
}

abstract interface class PreparedDatabaseRecovery {
  ImportResult get result;

  Future<OpenedDatabase> activate();
  Future<void> discard();
}

/// First query drives Drift's lazy executor, including onCreate and onUpgrade.
Future<void> probeStartupDatabase(AppDatabase db) async {
  await db.customSelect('SELECT id FROM chat_sessions LIMIT 1').get();
}

Future<void> closeStartupDatabase(AppDatabase db) async {
  try {
    await db.close();
  } on Object catch (error) {
    const Logger('DatabaseStartup').warn(
      'Failed to close database executor',
      detail: error.runtimeType.toString(),
    );
  }
}
