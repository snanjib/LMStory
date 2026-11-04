/// 事实层来源（DOC-15 §3.1）
///
/// 区分事实层实体的三类来源，决定其只读性：
/// - [auto]：summarizing 阶段 AI 自动提取，全程可演化。
/// - [worldbook]：世界书导入，属性级只读基线（基线不可改写；可新增 auto
///   演变行/别名/归档，与角色卡同规，只读基线）。
/// - [card]：角色卡导入，基线属性只读、实体本身可演化。
///
/// 只读性以**属性级** `source` 为准：`source != auto` 即只读基线。
enum FactualSource {
  auto,
  worldbook,
  card;

  /// 从数据库字符串解析（兼容未知/空值，兜底为 auto）
  static FactualSource fromString(String value) {
    switch (value) {
      case 'worldbook':
        return FactualSource.worldbook;
      case 'card':
        return FactualSource.card;
      case 'auto':
      default:
        return FactualSource.auto;
    }
  }

  /// 序列化为数据库字符串
  String toDbString() => name;

  /// 是否为只读基线（worldbook 实体 / card 基线属性）
  bool get isReadOnly => this != FactualSource.auto;
}
