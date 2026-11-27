import 'package:lmstory/core/storage/preferences.dart';

/// 演示环境 Preferences：读穿透 + 写隔离。
///
/// - 读：先查内存 overlay。命中「删除标记」（显式 [remove] 后的 null
///   占位）返回 null；命中值类型不符按未命中处理；未命中穿透到
///   `fallback`（生产=真实 Preferences，只读——保证主题/语言等观感
///   与用户真实设置一致）。API Key 不存储于 Preferences，无泄漏面。
/// - 写/删/clear：只动 overlay，真实 SharedPreferences 全程零写入。
///
/// 顶层公开方法与 `Preferences` 一一对应；后续基座新增方法由
/// 完备性守卫测试对账（防止未来新增方法静默穿透）。
class DemoPreferences extends Preferences {
  DemoPreferences({Preferences? fallback})
      : _fallback = fallback,
        super();

  final Preferences? _fallback;

  /// overlay 存储；值为 null 表示显式删除标记（遮蔽真实值）。
  final Map<String, Object?> _overlay = <String, Object?>{};

  /// 测试/诊断视图（勿在生产逻辑消费）
  Map<String, Object?> get debugOverlay => Map.unmodifiable(_overlay);

  /// overlay 命中返回（含删除标记 null），未命中返回 [_absent]。
  Object? _lookup(String key) =>
      _overlay.containsKey(key) ? _overlay[key] : _absent;

  static const Object _absent = Object();

  Future<T?> _typed<T>(String key, Future<T?> Function() onFallback) async {
    final v = _lookup(key);
    if (identical(v, _absent) || v is! T) {
      // 删除标记（null）必须在此截断：返回 null，不再穿透真实值
      if (!identical(v, _absent) && v == null) return null;
      return onFallback();
    }
    return v;
  }

  @override
  Future<String?> getString(String key) =>
      _typed<String>(key, () => _fallback?.getString(key) ?? Future.value());

  @override
  Future<bool?> getBool(String key) =>
      _typed<bool>(key, () => _fallback?.getBool(key) ?? Future.value());

  @override
  Future<int?> getInt(String key) =>
      _typed<int>(key, () => _fallback?.getInt(key) ?? Future.value());

  @override
  Future<double?> getDouble(String key) =>
      _typed<double>(key, () => _fallback?.getDouble(key) ?? Future.value());

  @override
  Future<List<String>?> getStringList(String key) => _typed<List<String>>(
        key,
        () => _fallback?.getStringList(key) ?? Future.value(),
      );

  @override
  Future<bool> setString(String key, String value) async {
    _overlay[key] = value;
    return true;
  }

  @override
  Future<bool> setBool(String key, bool value) async {
    _overlay[key] = value;
    return true;
  }

  @override
  Future<bool> setInt(String key, int value) async {
    _overlay[key] = value;
    return true;
  }

  @override
  Future<bool> setDouble(String key, double value) async {
    _overlay[key] = value;
    return true;
  }

  @override
  Future<bool> setStringList(String key, List<String> value) async {
    _overlay[key] = List<String>.of(value);
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    _overlay[key] = null;
    return true;
  }

  @override
  Future<bool> containsKey(String key) async {
    final v = _lookup(key);
    if (!identical(v, _absent)) return v != null;
    return _fallback?.containsKey(key) ?? Future.value(false);
  }

  @override
  Future<void> reload() async {}

  @override
  Preferences withKeyAliases(Map<String, String> aliases) {
    throw UnsupportedError('Storage aliases are unavailable in a demo scope');
  }

  @override
  Future<bool> clear() async {
    _overlay.clear();
    return true;
  }
}
