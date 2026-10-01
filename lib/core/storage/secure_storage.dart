import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:lmstory/core/utils/logger.dart';

class SecureStorage {
  SecureStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  final _log = const Logger('SecureStorage');

  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: key);
    } on PlatformException catch (e) {
      _log.warn('Read failed, key=$key', detail: '$e');
      return null;
    }
  }

  Future<void> write(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
    } on PlatformException catch (e) {
      _log.error('Write failed, key=$key', detail: '$e');
      // 不吞异常：API Key 等关键数据保存失败时调用方需感知，否则数据静默丢失
      rethrow;
    }
  }

  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: key);
    } on PlatformException catch (e) {
      _log.warn('Delete failed, key=$key', detail: '$e');
    }
  }

  Future<bool> containsKey(String key) async {
    try {
      return await _storage.containsKey(key: key);
    } on PlatformException catch (e) {
      _log.warn('ContainsKey failed, key=$key', detail: '$e');
      return false;
    }
  }

  Future<void> deleteAll() async {
    try {
      await _storage.deleteAll();
    } on PlatformException catch (e) {
      _log.warn('DeleteAll failed', detail: '$e');
    }
  }
}
