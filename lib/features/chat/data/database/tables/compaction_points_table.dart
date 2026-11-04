import 'package:drift/drift.dart';

/// compaction_points 表定义
/// 存储上下文压缩检查点，记录摘要消息和边界消息
class CompactionPointsTable extends Table {
  @override
  String get tableName => 'compaction_points';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get sessionId => text()();
  TextColumn get summaryMessageId => text()();
  TextColumn get boundaryMessageId => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}
