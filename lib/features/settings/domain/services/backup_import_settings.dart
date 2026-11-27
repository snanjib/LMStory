part of 'data_management_service.dart';

/// 独立于 SQLite 的偏好与密钥的补偿记录，只保存本次可能写入的值。
final class _BackupImportSettings {
  _BackupImportSettings(this._repository)
      : _storage = switch (_repository) {
          final SettingsImportStorage storage => storage,
          _ => null,
        };

  final SettingsRepository _repository;
  final SettingsImportStorage? _storage;
  Map<String, dynamic> previousPreferences = const {};
  Future<bool> Function()? _restorePreferences;
  var _preferencesWritten = false;
  final _oldKeys = <String, String?>{};
  final _writtenKeys = <String>{};
  bool hasSnapshot = false;

  bool get hasPriorValues =>
      previousPreferences.isNotEmpty ||
      _oldKeys.values.any((key) => key != null);

  Future<void> capturePreferences() async {
    final storage = _storage;
    if (storage != null) {
      final captured = await storage.captureUserOverridesForImport();
      previousPreferences = captured.values;
      _restorePreferences = captured.restore;
    } else {
      previousPreferences = Map.of(await _repository.getUserOverrides());
      _restorePreferences = () async {
        try {
          await _repository.clearAllUserOverrides();
        } catch (_) {
          // 继续尝试逐项恢复，由读回确认是否已恢复。
        }
        for (final entry in previousPreferences.entries) {
          try {
            await _repository.setUserOverride(entry.key, entry.value);
          } catch (_) {
            // 一项失败也继续恢复其他原值。
          }
        }
        return const DeepCollectionEquality().equals(
          await _repository.getUserOverrides(),
          previousPreferences,
        );
      };
    }
  }

  Future<void> captureKey(String presetId) async {
    if (!_oldKeys.containsKey(presetId)) {
      _oldKeys[presetId] = await _readKey(presetId);
    }
  }

  Future<void> writePreferences(Map<String, dynamic> preferences) async {
    _preferencesWritten = true;
    final storage = _storage;
    if (storage != null) {
      await storage.replaceUserOverridesForImport(preferences);
    } else {
      await _repository.clearAllUserOverrides();
      for (final entry in preferences.entries) {
        await _repository.setUserOverride(entry.key, entry.value);
      }
    }
  }

  Future<void> writeKey(String presetId, String key) async {
    // v1 的新预设 ID 到创建时才可知，仍在第一次写密钥之前保存原值。
    await captureKey(presetId);
    if (!hasSnapshot && _oldKeys[presetId] != null) {
      throw const BackupSnapshotException();
    }

    _writtenKeys.add(presetId);
    await _writeKey(presetId, key);
    if (await _readKey(presetId) != key) {
      throw StateError('Could not persist imported credential');
    }
  }

  Future<bool> restore() async {
    var restored = true;
    final restorePreferences = _restorePreferences;
    if (_preferencesWritten && restorePreferences != null) {
      try {
        restored = await restorePreferences();
      } catch (_) {
        restored = false;
      }
    }
    // 一个键补偿失败不影响剩余键的补偿。失败之后仍以再次读回为准。
    for (final id in _writtenKeys) {
      final old = _oldKeys[id];
      try {
        if (old == null) {
          await _deleteKey(id);
        } else {
          await _writeKey(id, old);
        }
      } catch (_) {
        // 写入可能已生效。以下面读回的值判定。
      }
      try {
        if (await _readKey(id) != old) restored = false;
      } catch (_) {
        restored = false;
      }
    }
    return restored;
  }

  Future<String?> _readKey(String id) =>
      _storage?.readApiKeyForImport(id) ?? _repository.getApiKey(id);

  Future<void> _writeKey(String id, String value) =>
      _storage?.writeApiKeyForImport(id, value) ??
      _repository.saveApiKey(id, value);

  Future<void> _deleteKey(String id) =>
      _storage?.deleteApiKeyForImport(id) ?? _repository.deleteApiKey(id);
}
