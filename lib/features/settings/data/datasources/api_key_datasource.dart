import 'package:lmstory/core/storage/secure_storage.dart';

/// API Key 数据源
///
/// 对 SecureStorage 的薄封装，为 API Key 操作添加前缀以避免键名冲突。
class ApiKeyDatasource {
  ApiKeyDatasource({required SecureStorage secureStorage})
      : _secureStorage = secureStorage;

  final SecureStorage _secureStorage;
  static const _keyPrefix = 'api_key_';

  Future<void> save(String presetId, String apiKey) =>
      _secureStorage.write('$_keyPrefix$presetId', apiKey);

  Future<String?> read(String presetId) =>
      _secureStorage.read('$_keyPrefix$presetId');

  Future<void> delete(String presetId) =>
      _secureStorage.delete('$_keyPrefix$presetId');
}
