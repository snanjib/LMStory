/// 关键词分类结构（v0.2.2 架构调整）
///
/// 与记忆库分类结构对齐：
/// - **事实层实体 3 类**（characters/items/locations）：稳定世界元素，走 FTS5 精确匹配
/// - **经历层 2 类**（actions/plots）：动态剧情元素，走 Vector 语义匹配
///
/// 关联设计§4.1
class ClassifiedKeywords {
  const ClassifiedKeywords({
    this.characters = const [],
    this.items = const [],
    this.locations = const [],
    this.actions = const [],
    this.plots = const [],
  });

  /// 角色名（含主角）— FTS5 通道 1
  final List<String> characters;

  /// 关键物品/道具名 — FTS5 通道 2
  final List<String> items;

  /// 出现场景/地点名 — FTS5 通道 3
  final List<String> locations;

  /// 角色动作/行为 — Vector 通道 1
  final List<String> actions;

  /// 剧情事件/情节要点 — Vector 通道 2
  final List<String> plots;

  /// 实体类关键词合并（characters + items + locations），走 FTS5 通道
  List<String> get entityTerms => [...characters, ...items, ...locations];

  /// 事件类关键词合并（actions + plots），走 Vector 通道
  List<String> get eventTerms => [...actions, ...plots];

  /// 扁平化为单一列表（向后兼容）
  List<String> flatten() =>
      [...characters, ...items, ...locations, ...actions, ...plots];

  /// 是否全部 5 类都为空
  bool get isEmpty =>
      characters.isEmpty &&
      items.isEmpty &&
      locations.isEmpty &&
      actions.isEmpty &&
      plots.isEmpty;

  /// 是否有内容
  bool get isNotEmpty => !isEmpty;

  /// 全部 5 类总数量
  int get length => flatten().length;
}
