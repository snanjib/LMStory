import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 滚动位置 LRU 缓存（纯内存，不持久化）。
///
/// 切换会话时保存/恢复滚动偏移量，使再次进入会话时能回到上次查看的位置。
/// 首次进入（无缓存）时由调用方决定默认位置（通常为底部，显示最新消息）。
class ScrollPositionCache {
  static const int maxEntries = 100;

  final _cache =
      <String, double>{}; // sessionId → scrollOffset（默认 LinkedHashMap，保持插入顺序）

  /// 保存滚动位置。
  void save(String sessionId, double offset) {
    _cache.remove(sessionId); // 先移除以保证 LRU 顺序
    _cache[sessionId] = offset;
    if (_cache.length > maxEntries) {
      _cache.remove(_cache.keys.first);
    }
  }

  /// 读取滚动位置（不存在返回 null）。
  /// 读取会更新 LRU 顺序，使最近访问的会话不会被优先淘汰。
  double? restore(String sessionId) {
    final offset = _cache.remove(sessionId);
    if (offset != null) {
      _cache[sessionId] = offset; // 重新插入到末尾
    }
    return offset;
  }

  /// 清除指定会话的缓存。
  void remove(String sessionId) {
    _cache.remove(sessionId);
  }
}

/// 全局滚动位置缓存 Provider（纯内存，应用生命周期内有效）。
final scrollPositionCacheProvider = Provider<ScrollPositionCache>((ref) {
  return ScrollPositionCache();
});
