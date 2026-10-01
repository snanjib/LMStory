import 'package:drift/drift.dart';

/// worldbooks 表定义（DOC-15 §9.1）
///
/// 世界书资源库（全局、跨会话复用）：存 SillyTavern 世界书的**完整原始 JSON**
/// （无损，词条存 rawJson 内，按需解析；投影到会话事实层 source=worldbook）。
class WorldbooksTable extends Table {
  @override
  String get tableName => 'worldbooks';

  /// 自增主键（内部使用，不暴露）
  IntColumn get id => integer().autoIncrement()();

  /// 业务主键（uuid）
  TextColumn get bookId => text().withLength(min: 1).unique()();

  /// 反规范化展示名（列表展示用）
  TextColumn get name => text().withLength(min: 1)();

  /// 完整原始书 JSON（无损）
  TextColumn get rawJson => text()();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}
