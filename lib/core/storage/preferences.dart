import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

class Preferences {
  Preferences({SharedPreferences? prefs})
      : _initCompleter = prefs != null
            ? (Completer<SharedPreferences>()..complete(prefs))
            : Completer<SharedPreferences>();

  final Completer<SharedPreferences> _initCompleter;

  Future<SharedPreferences> get _instance async {
    if (!_initCompleter.isCompleted) {
      _initCompleter.complete(SharedPreferences.getInstance());
    }
    return _initCompleter.future;
  }

  Future<String?> getString(String key) async {
    final prefs = await _instance;
    return prefs.getString(key);
  }

  Future<bool> setString(String key, String value) async {
    final prefs = await _instance;
    return prefs.setString(key, value);
  }

  Future<bool?> getBool(String key) async {
    final prefs = await _instance;
    return prefs.getBool(key);
  }

  // ignore: avoid_positional_boolean_parameters — 与其他 setter 签名保持一致
  Future<bool> setBool(String key, bool value) async {
    final prefs = await _instance;
    return prefs.setBool(key, value);
  }

  Future<int?> getInt(String key) async {
    final prefs = await _instance;
    return prefs.getInt(key);
  }

  Future<bool> setInt(String key, int value) async {
    final prefs = await _instance;
    return prefs.setInt(key, value);
  }

  Future<double?> getDouble(String key) async {
    final prefs = await _instance;
    return prefs.getDouble(key);
  }

  Future<bool> setDouble(String key, double value) async {
    final prefs = await _instance;
    return prefs.setDouble(key, value);
  }

  Future<List<String>?> getStringList(String key) async {
    final prefs = await _instance;
    return prefs.getStringList(key);
  }

  Future<bool> setStringList(String key, List<String> value) async {
    final prefs = await _instance;
    return prefs.setStringList(key, value);
  }

  Future<bool> remove(String key) async {
    final prefs = await _instance;
    return prefs.remove(key);
  }

  Future<bool> containsKey(String key) async {
    final prefs = await _instance;
    return prefs.containsKey(key);
  }

  Future<bool> clear() async {
    final prefs = await _instance;
    return prefs.clear();
  }
}
