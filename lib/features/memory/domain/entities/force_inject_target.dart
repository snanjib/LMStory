/// 实体强制注入去向（doc/design/v0.2.3/实体强制注入开关设计.md §2.1）
///
/// 与「评分等级 5 强制注入」解耦的三态开关：
/// - [none]：不强制注入，走 importance 评分 + 关键词命中逻辑
/// - [world]：始终注入到【世界设定】区块
/// - [directive]：始终注入到【常驻指令】区块
enum ForceInjectTarget {
  none,
  world,
  directive;

  /// 从数据库字符串解析（兼容未知/空值，兜底为 none）
  static ForceInjectTarget fromString(String value) {
    switch (value) {
      case 'world':
        return ForceInjectTarget.world;
      case 'directive':
        return ForceInjectTarget.directive;
      case 'none':
      default:
        return ForceInjectTarget.none;
    }
  }

  /// 序列化为数据库字符串
  String toDbString() => name;
}
