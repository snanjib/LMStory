import 'package:drift/drift.dart';

/// templates 表定义
/// 存储提示词模板（含内置模板和自定义模板）
class TemplatesTable extends Table {
  @override
  String get tableName => 'templates';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get templateId => text().withLength(min: 1).unique()();
  TextColumn get name => text().withLength(min: 1)();
  // 存活值：'systemPrompt' | 'toolUpdateWorld'；
  // 旧值 'consolidation'/'suggestReply' 行保留但被仓库过滤（CF-7）
  TextColumn get kind => text()();
  TextColumn get content => text()();
  BoolColumn get isBuiltIn => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
}
