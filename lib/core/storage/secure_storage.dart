import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:lmstory/core/utils/logger.dart';

class SecureStorage {
  SecureStorage({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              // macOS 默认走 iOS 式数据保护钥匙串（kSecUseDataProtection
              // Keychain=true），要求应用具备 keychain-access-groups 授权
              // 与团队签名；本应用无签名基建（ad-hoc），实测 SecItem 报
              // -34018。改走传统文件钥匙链（沙盒容器内、随应用存取），
              // 不使用访问组共享与 iCloud 同步，无功能损失。
              mOptions: MacOsOptions(usesDataProtectionKeychain: false),
            );

  final FlutterSecureStorage _storage;
  final _log = const Logger('SecureStorage');

  /// 用于需要区分缺键和底层失败的导入回退。
  Future<String?> readStrict(String key) => _storage.read(key: key);

  Future<void> writeStrict(String key, String value) =>
      _storage.write(key: key, value: value);

  Future<void> deleteStrict(String key) => _storage.delete(key: key);

  Future<String?> read(String key) async {
    try {
      return await readStrict(key);
    } on PlatformException catch (e) {
      _log.warn('Read failed, key=$key', detail: '$e');
      return null;
    }
  }

  Future<void> write(String key, String value) async {
    try {
      await writeStrict(key, value);
    } on PlatformException catch (e) {
      _log.error('Write failed, key=$key', detail: '$e');
      // 不吞异常：API Key 等关键数据保存失败时调用方需感知，否则数据静默丢失
      rethrow;
    }
  }

  Future<void> delete(String key) async {
    try {
      await deleteStrict(key);
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
