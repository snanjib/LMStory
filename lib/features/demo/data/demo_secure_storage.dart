import 'package:lmstory/core/storage/secure_storage.dart';

/// 演示环境 SecureStorage：纯内存实现，读永不穿透。
///
/// 生产 Key 链路（ApiKeyDatasource → FlutterSecureStorage）在演示
/// 作用域内被本类替换：真实钥匙串零读零写；配置解析的「跨 preset
/// 借 Key」逻辑也因此只能在演示环境内存 map 内打转，取不到真实 Key。
class DemoSecureStorage extends SecureStorage {
  DemoSecureStorage() : super();

  final Map<String, String> _store = <String, String>{};

  /// 测试/诊断视图（勿在生产逻辑消费）
  Map<String, String> get debugStore => Map.unmodifiable(_store);

  @override
  Future<String?> read(String key) async => _store[key];

  @override
  Future<void> write(String key, String value) async {
    _store[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _store.remove(key);
  }

  @override
  Future<bool> containsKey(String key) async => _store.containsKey(key);

  @override
  Future<void> deleteAll() async {
    _store.clear();
  }
}
