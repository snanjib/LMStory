import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

class Preferences {
  Preferences({SharedPreferences? prefs})
      : _initCompleter = prefs != null
            ? (Completer<SharedPreferences>()..complete(prefs))
            : Completer<SharedPreferences>(),
        _keyAliases = const {};

  Preferences._scoped(this._initCompleter, this._keyAliases);

  final Completer<SharedPreferences> _initCompleter;
  final Map<String, String> _keyAliases;

  /// Shares the same platform store, with alternate slots for selected keys.
  Preferences withKeyAliases(Map<String, String> aliases) =>
      Preferences._scoped(_initCompleter, Map.unmodifiable(aliases));

  String _key(String key) => _keyAliases[key] ?? key;

  Future<SharedPreferences> get _instance async {
    if (!_initCompleter.isCompleted) {
      _initCompleter.complete(SharedPreferences.getInstance());
    }
    return _initCompleter.future;
  }

  Future<String?> getString(String key) async {
    final prefs = await _instance;
    return prefs.getString(_key(key));
  }

  Future<bool> setString(String key, String value) async {
    final prefs = await _instance;
    return prefs.setString(_key(key), value);
  }

  Future<bool?> getBool(String key) async {
    final prefs = await _instance;
    return prefs.getBool(_key(key));
  }

  // ignore: avoid_positional_boolean_parameters — 与其他 setter 签名保持一致
  Future<bool> setBool(String key, bool value) async {
    final prefs = await _instance;
    return prefs.setBool(_key(key), value);
  }

  Future<int?> getInt(String key) async {
    final prefs = await _instance;
    return prefs.getInt(_key(key));
  }

  Future<bool> setInt(String key, int value) async {
    final prefs = await _instance;
    return prefs.setInt(_key(key), value);
  }

  Future<double?> getDouble(String key) async {
    final prefs = await _instance;
    return prefs.getDouble(_key(key));
  }

  Future<bool> setDouble(String key, double value) async {
    final prefs = await _instance;
    return prefs.setDouble(_key(key), value);
  }

  Future<List<String>?> getStringList(String key) async {
    final prefs = await _instance;
    return prefs.getStringList(_key(key));
  }

  Future<bool> setStringList(String key, List<String> value) async {
    final prefs = await _instance;
    return prefs.setStringList(_key(key), value);
  }

  Future<bool> remove(String key) async {
    final prefs = await _instance;
    return prefs.remove(_key(key));
  }

  Future<bool> containsKey(String key) async {
    final prefs = await _instance;
    return prefs.containsKey(_key(key));
  }

  /// Refreshes the cache before verifying a write or reading a rollback value.
  Future<void> reload() async {
    final prefs = await _instance;
    await prefs.reload();
  }

  Future<bool> clear() async {
    final prefs = await _instance;
    return prefs.clear();
  }
}
