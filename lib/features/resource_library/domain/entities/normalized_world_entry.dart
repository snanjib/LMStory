/// 归一化的世界书词条（DOC-15 §5.2 / §6.2）
///
/// 解析器将两套 SillyTavern 世界书 schema（独立导出 camelCase `entries` 字典
/// 与内嵌 V2 snake_case `entries` 数组）归一化为本结构，供字段映射器投影。
class NormalizedWorldEntry {
  const NormalizedWorldEntry({
    required this.keys,
    required this.secondaryKeys,
    required this.comment,
    required this.content,
    required this.constant,
    required this.enabled,
    required this.vectorized,
  });

  /// 主触发词（key / keys）
  final List<String> keys;

  /// 次触发词（keysecondary / secondary_keys）
  final List<String> secondaryKeys;

  /// 词条标题/备注（comment）
  final String comment;

  /// 词条正文（content）→ 映射 `lore.description`
  final String content;

  /// 常驻注入（constant）→ forceInject=world（importance=2；
  ///  与投影行为一致，旧「importance=5」口径已在迁移中改写）
  final bool constant;

  /// 是否启用（enabled；独立导出为 disable 反义）→ 反义映射 isArchived
  final bool enabled;

  /// 是否向量化（vectorized）
  final bool vectorized;

  /// 触发词全集（主 + 次），用于实体 aliases
  List<String> get allKeys => [...keys, ...secondaryKeys];
}
