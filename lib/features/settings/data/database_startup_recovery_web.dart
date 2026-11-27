import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/core/utils/logger.dart';
import 'package:lmstory/features/chat/data/database/app_database.dart';
import 'package:lmstory/features/settings/data/browser_backup_snapshots.dart';
import 'package:lmstory/features/settings/data/database_startup_recovery.dart';

DatabaseStartupRecovery createStartupDatabaseRecovery(
  Preferences preferences,
) =>
    _WebDatabaseStartupRecovery(preferences);

class _WebDatabaseStartupRecovery implements DatabaseStartupRecovery {
  const _WebDatabaseStartupRecovery(this._preferences);

  final Preferences _preferences;

  @override
  bool get supportsActivation => false;

  @override
  Future<OpenedDatabase> open() async {
    final db = AppDatabase();
    try {
      await probeStartupDatabase(db);
      return OpenedDatabase(db, _preferences);
    } on Object catch (error) {
      await closeStartupDatabase(db);
      const Logger('DatabaseStartup').warn(
        'Failed to open browser database',
        detail: error.runtimeType.toString(),
      );
      throw const DatabaseOpenFailure();
    }
  }

  @override
  Future<List<RecoveryBackup>> listBackups() =>
      BrowserBackupSnapshots(_preferences).list();

  @override
  Future<PreparedDatabaseRecovery> prepare(String backup) async {
    throw UnsupportedError('Browser storage recovery supports inspection only');
  }
}
