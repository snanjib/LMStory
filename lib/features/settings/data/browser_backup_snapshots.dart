import 'package:flutter/foundation.dart' show listEquals;
import 'package:lmstory/core/storage/preferences.dart';
import 'package:lmstory/features/settings/data/database_startup_recovery.dart';
import 'package:lmstory/features/settings/domain/entities/data_management_models.dart';
import 'package:lmstory/features/settings/domain/services/data_management_service.dart';

/// Pre-overwrite backups for browsers without a documents directory.
class BrowserBackupSnapshots {
  const BrowserBackupSnapshots(this._preferences);

  static const _key = 'browser_pre_import_snapshots';
  static const _keepCount = 2;
  final Preferences _preferences;

  Future<String> create(DataManagementService service) async {
    final content = await service.exportFullBackup(
      const DataExportOptions(
        includeSessions: true,
        includePresets: true,
        includePreferences: true,
      ),
    );
    DataManagementService.validatePreImportSnapshot(content);
    final previous = await _preferences.getStringList(_key) ?? const [];
    final snapshots = [content, ...previous].take(_keepCount).toList();
    if (!await _preferences.setStringList(_key, snapshots)) {
      throw StateError('Browser snapshot storage rejected the write');
    }
    await _preferences.reload();
    if (!listEquals(await _preferences.getStringList(_key), snapshots)) {
      throw StateError('Browser snapshot could not be read back');
    }
    return _name(_date(content));
  }

  Future<List<RecoveryBackup>> list() async {
    final snapshots = await _preferences.getStringList(_key) ?? const [];
    return snapshots.map((content) {
      final date = _date(content);
      return RecoveryBackup(
        name: _name(date),
        source: RecoveryBackupSource.preImport,
        modifiedAt: date,
        read: () async => content,
      );
    }).toList();
  }

  static DateTime? _date(String content) {
    try {
      return DataManagementService.validateBackup(content).exportedAt;
    } on FormatException {
      return null;
    }
  }

  static String _name(DateTime? date) =>
      'lmstory_pre_import_${date?.toIso8601String() ?? 'backup'}.json';
}
