import 'package:drift/drift.dart';

/// factual_relationship_migration_backup 表定义
///
/// 关系属性拆分迁移的数据级备份：迁移触碰任何 `relationships` 属性行前，
/// 先把原值整体存档一份到本表。迁移本身幂等且逐行写审计历史，但历史表
/// 的 oldValue 只覆盖单次变更；本表保留「迁移开始时」的完整原值，供
/// 数据回退与人工核对使用（git revert 不能替代数据库回退）。
///
/// 只增不改：恢复/核对由运维脚本或后续工具按 attribute_id 读取，
/// 日常读写路径不消费本表。
class FactualRelationshipMigrationBackupTable extends Table {
  @override
  String get tableName => 'factual_relationship_migration_backup';

  /// 自增主键
  IntColumn get id => integer().autoIncrement()();

  /// 被备份的属性行 ID（factual_attributes.attribute_id）
  TextColumn get attributeId => text()();

  /// 冗余定位列（与 factual_attributes 对齐，便于直接按会话/实体核对）
  TextColumn get sessionId => text()();

  TextColumn get entityId => text()();

  TextColumn get attrKey => text()();

  /// 备份时的值类型（dict / list / single）
  TextColumn get valueType => text()();

  /// 备份时的完整原值（原样存储，不做任何解析或改写）
  TextColumn get value => text()();

  /// 备份时刻
  DateTimeColumn get backedUpAt => dateTime().withDefault(currentDateAndTime)();
}
