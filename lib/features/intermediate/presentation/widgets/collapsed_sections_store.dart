import 'package:lmstory/features/settings/domain/repositories/settings_repository.dart';

/// 会话/全局设置折叠状态持久化（DOC-14 §3.4，参数化复用）。
///
/// **全局记忆**：按分组 id 记录被折叠的分区，所有会话共享同一份偏好（折叠
/// 历史属于 UI 偏好而非会话数据）。存于 `user_overrides` 的扁平 key
/// （默认 `ui.storySession.collapsedSections`，导演侧经 [storageKey]
/// 参数化：`ui.directorSession.collapsedSections` /
/// `ui.directorSettings.collapsedSections`），无需数据库迁移。
class CollapsedSectionsStore {
  const CollapsedSectionsStore(
    this._repository, {
    this.storageKey = key,
  });

  final SettingsRepository _repository;

  /// 存储键（默认故事会话面板；调用方可参数化为导演侧键）。
  final String storageKey;

  /// 故事会话面板存储键（历史默认值）。
  static const String key = 'ui.storySession.collapsedSections';

  /// 读取被折叠的分区 id 集合；无记录时返回空集。
  Future<Set<String>> load() async => await loadOrNull() ?? <String>{};

  /// 读取被折叠的分区 id 集合；无任何记录时返回 null。
  ///
  /// 「默认态仅首次生效」（DOC-14 §3.4）需要区分"从未保存"（用默认态表）
  /// 与"用户已保存偏好"（按记忆渲染）：首次保存发生在用户显式
  /// 折叠/展开动作时，此后不再重置。
  Future<Set<String>?> loadOrNull() async {
    final overrides = await _repository.getUserOverrides();
    final raw = overrides[storageKey];
    if (raw is List) {
      return raw.whereType<String>().toSet();
    }
    return null;
  }

  /// 写入被折叠的分区 id 集合。
  Future<void> save(Set<String> collapsed) async {
    await _repository.setUserOverride(storageKey, collapsed.toList());
  }
}
